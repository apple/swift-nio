//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ConcurrencyHelpers

#if os(Linux)
import Glibc
#else
import Darwin
#endif

private extension IOData {
    var size: Int {
        switch self {
        case .byteBuffer(let buffer):
            return buffer.readableBytes
        case .fileRegion(_):
            // We don't want to account for the number of bytes in the file as these not add up to the memory used.
            return 0
        }
    }
}
private typealias PendingWrite = (data: IOData, promise: Promise<Void>?)

// We need to know the maximum value of a 32-bit int, but in Swift's regular int size. Store it here.
private let maxInt = Int(INT32_MAX)

private func doPendingWriteVectorOperation(pending: MarkedCircularBuffer<PendingWrite>,
                                           count: Int,
                                           iovecs: UnsafeMutableBufferPointer<IOVector>,
                                           storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>,
                                           _ fn: (UnsafeBufferPointer<IOVector>) throws -> IOResult<Int>) throws -> IOResult<Int> {
    assert(count <= pending.count, "requested to write \(count) pending writes but only \(pending.count) available")
    assert(iovecs.count >= Socket.writevLimit, "Insufficiently sized buffer for a maximal writev")

    // Clamp the number of writes we're willing to issue to the limit for writev.
    let count = min(count, Socket.writevLimit)
    
    // the numbers of storage refs that we need to decrease later.
    var c = 0

    // Must not write more than INT32_MAX in one go.
    var toWrite = 0

    loop: for i in 0..<count {
        let p = pending[i]
        switch p.data {
        case .byteBuffer(let buffer):
            guard maxInt - toWrite >= buffer.readableBytes else {
                break loop
            }
            toWrite += buffer.readableBytes

            buffer.withUnsafeReadableBytesWithStorageManagement { ptr, storageRef in
                storageRefs[i] = storageRef.retain()
                iovecs[i] = iovec(iov_base: UnsafeMutableRawPointer(mutating: ptr.baseAddress!), iov_len: ptr.count)
            }
            c += 1
        case .fileRegion(_):
            // We found a FileRegion so stop collecting
            break loop
        }
    }
    defer {
        for i in 0..<c {
            storageRefs[i].release()
        }
    }
    let result = try fn(UnsafeBufferPointer(start: iovecs.baseAddress!, count: c))
    return result
}

private enum WriteResult {
    case writtenCompletely
    case writtenPartially
    case nothingToBeWritten
    case wouldBlock
    case closed
}

private final class PendingWrites {
    private var pendingWrites = MarkedCircularBuffer<PendingWrite>(initialRingCapacity: 16, expandSize: 3)
    // Marks the last PendingWrite that should be written by consume(...)
    private var iovecs: UnsafeMutableBufferPointer<IOVector>
    private var storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>

    fileprivate var waterMark: WriteBufferWaterMark = WriteBufferWaterMark(32 * 1024..<64 * 1024)
    private var writable: Atomic<Bool> = Atomic(value: true)

    fileprivate var writeSpinCount: UInt = 16
    private(set) var outstanding: (chunks: Int, bytes: Int) = (0, 0)

    private(set) var closed = false

    var isWritable: Bool {
        return writable.load()
    }

    var isEmpty: Bool {
        return self.pendingWrites.isEmpty
    }
    
    func add(data: IOData, promise: Promise<Void>?) -> Bool {
        assert(!closed)
        self.pendingWrites.append((data: data, promise: promise))

        outstanding = (chunks: outstanding.chunks + 1,
                       bytes: outstanding.bytes + data.size)
        if outstanding.bytes > Int(waterMark.upperBound) && writable.compareAndExchange(expected: true, desired: false) {
            // Returns false to signal the Channel became non-writable and we need to notify the user
            return false
        }
        return true
    }

    private var hasMultipleByteBuffer: Bool {
        guard self.pendingWrites.count > 1 else {
            return false
        }

        if case .byteBuffer(_) = self.pendingWrites[0].data, case .byteBuffer(_) = self.pendingWrites[1].data {
            // We have at least two ByteBuffer in the PendingWrites
            return true
        }
        return false
    }

    func markFlushCheckpoint(promise: Promise<Void>?) {
        self.pendingWrites.mark()
        let checkpointIdx = self.pendingWrites.markedElementIndex()
        if let promise = promise, let checkpoint = checkpointIdx {
            if let p = self.pendingWrites[checkpoint].promise {
                p.futureResult.cascade(promise: promise)
            } else {
                self.pendingWrites[checkpoint].promise = promise
            }
        } else if let promise = promise {
            // No checkpoint index means this is a flush on empty, so we can
            // satisfy it immediately.
            promise.succeed(result: ())
        }
    }

    /*
     Function that takes two closures and based on if there are more then one ByteBuffer pending calls either one or the other.
    */
    func consume(oneBody: (UnsafeRawBufferPointer) throws -> IOResult<Int>,
                 multipleBody: (UnsafeBufferPointer<IOVector>) throws -> IOResult<Int>,
                 fileRegionBody: (Int32, Int, Int) throws -> IOResult<Int>) throws -> (writeResult: WriteResult, writable: Bool) {
        let wasWritable = writable.load()
        let result = try hasMultipleByteBuffer ? consumeMultiple(multipleBody) : consumeOne(oneBody, fileRegionBody)

        if !wasWritable {
            // Was not writable before so signal back to the caller the possible state change
            return (result, writable.load())
        }
        return (result, false)
    }

    @discardableResult
    private func popFirst() -> PendingWrite {
        return self.pendingWrites.removeFirst()
    }

    var isFlushPending: Bool {
        return self.pendingWrites.hasMark()
    }

    private func consumeOne(_ body: (UnsafeRawBufferPointer) throws -> IOResult<Int>, _ fileRegionBody: (Int32, Int, Int) throws -> IOResult<Int>) rethrows -> WriteResult {

        if self.isFlushPending && !self.pendingWrites.isEmpty {
            for _ in 0..<writeSpinCount + 1 {
                guard !closed else {
                    return .closed
                }
                let pending = self.pendingWrites[0]
                switch pending.data {
                case .byteBuffer(var buffer):
                    switch try buffer.withUnsafeReadableBytes(body) {
                    case .processed(let written):
                        assert(outstanding.bytes >= written)
                        outstanding = (outstanding.chunks, outstanding.bytes - written)
                        
                        if outstanding.bytes < Int(waterMark.lowerBound) {
                            writable.store(true)
                        }
                        
                        if buffer.readableBytes == written {
                            
                            outstanding = (outstanding.chunks-1, outstanding.bytes)
                            
                            // Directly update nodes as a promise may trigger a callback that will access the PendingWrites class.
                            popFirst()
                            
                            // buffer was completely written
                            pending.promise?.succeed(result: ())
                            
                            return self.isFlushPending ? .writtenCompletely : .nothingToBeWritten
                        } else {
                            // Update readerIndex of the buffer
                            buffer.moveReaderIndex(forwardBy: written)
                            self.pendingWrites[0] = (.byteBuffer(buffer), pending.promise)
                        }
                    case .wouldBlock(let written):
                        assert(written == 0)
                        return .wouldBlock
                    }
                case .fileRegion(let file):
                    switch try file.withMutableReader(body: fileRegionBody) {
                    case .processed(_):
                        if file.readableBytes == 0 {
                            
                            outstanding = (outstanding.chunks-1, outstanding.bytes)
                            
                            // Directly update nodes as a promise may trigger a callback that will access the PendingWrites class.
                            popFirst()

                            
                            // buffer was completely written
                            pending.promise?.succeed(result: ())
                            
                            return isFlushPending ? .writtenCompletely : .nothingToBeWritten
                        } else {
                            self.pendingWrites[0] = (.fileRegion(file), pending.promise)
                        }
                    case .wouldBlock(_):
                        self.pendingWrites[0] = (.fileRegion(file), pending.promise)

                        return .wouldBlock
                    }
                }
                
            }
            return .writtenPartially
        }

        return .nothingToBeWritten
    }

    private func consumeMultiple(_ body: (UnsafeBufferPointer<IOVector>) throws -> IOResult<Int>) throws -> WriteResult {
        if self.isFlushPending && !self.pendingWrites.isEmpty {
            writeLoop: for _ in 0..<writeSpinCount + 1 {
                guard !closed else {
                    return .closed
                }
                var expected = 0
                switch try doPendingWriteVectorOperation(pending: self.pendingWrites,
                                                         count: outstanding.chunks,
                                                         iovecs: self.iovecs,
                                                         storageRefs: self.storageRefs,
                                                         { pointer in
                                                            expected += pointer.count
                                                            return try body(pointer)
                }) {
                case .processed(let written):
                    assert(outstanding.bytes >= written)
                    outstanding = (outstanding.chunks, outstanding.bytes - written)

                    if outstanding.bytes < Int(waterMark.lowerBound) {
                        writable.store(true)
                    }

                    var w = written
                    while !self.pendingWrites.isEmpty {
                        let p = self.pendingWrites[0]
                        switch p.data {
                        case .byteBuffer(var buffer):
                            if w >= buffer.readableBytes {
                                w -= buffer.readableBytes

                                outstanding = (outstanding.chunks-1, outstanding.bytes)

                                // Directly update nodes as a promise may trigger a callback that will access the PendingWrites class.
                                popFirst()

                                // buffer was completely written
                                p.promise?.succeed(result: ())

                                if w == 0 && buffer.readableBytes > 0 {
                                    return isFlushPending ? .writtenCompletely : .nothingToBeWritten
                                }

                            } else {
                                // Only partly written, so update the readerIndex.
                                buffer.moveReaderIndex(forwardBy: w)
                                self.pendingWrites[0] = (.byteBuffer(buffer), p.promise)
                    
                                // may try again depending on the writeSpinCount
                                continue writeLoop
                        }
                        case .fileRegion(_):
                             // We found a FileRegion so we can not continue with gathering writes but will need to use sendfile. Let the user call us again so we can use sendfile.
                            return .writtenCompletely
                        }
                    }
                case .wouldBlock(let written):
                    assert(written == 0)
                    return .wouldBlock
                }
            }
            return .writtenPartially
        }

        return .nothingToBeWritten
    }

    func failAll(error: Error) {
        closed = true

        while !self.pendingWrites.isEmpty {
            let pending = self.pendingWrites[0]
            assert(outstanding.bytes >= pending.data.size)
            outstanding = (outstanding.chunks-1, outstanding.bytes - pending.data.size)

            popFirst()
            pending.promise?.fail(error: error)
        }

        assert(self.pendingWrites.isEmpty)
        assert(self.pendingWrites.markedElement() == nil)
        assert(outstanding == (0, 0))
    }

    init(iovecs: UnsafeMutableBufferPointer<IOVector>, storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>) {
        self.iovecs = iovecs
        self.storageRefs = storageRefs
    }
}

// MARK: Compatibility
extension ByteBuffer {
    public mutating func withMutableWritePointer(body: (UnsafeMutablePointer<UInt8>, Int) throws -> IOResult<Int>) rethrows -> IOResult<Int> {
        var writeResult: IOResult<Int>!
        _ = try self.writeWithUnsafeMutableBytes { ptr in
            let localWriteResult = try body(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), ptr.count)
            writeResult = localWriteResult
            switch localWriteResult {
            case .processed(let written):
                return written
            case .wouldBlock(let written):
                return written
            }
        }
        return writeResult
    }
}

extension FileRegion {
    public func withMutableReader(body: (Int32, Int, Int) throws -> IOResult<Int>) rethrows -> IOResult<Int>  {
        var writeResult: IOResult<Int>!

        _ = try self.withMutableReader { (fd, offset, limit) -> Int in
            let localWriteResult = try body(fd, offset, limit)
            writeResult = localWriteResult
            switch localWriteResult {
            case .processed(let written):
                return written
            case .wouldBlock(let written):
                return written
            }
        }
        return writeResult
    }
}

/*
 All operations on SocketChannel are thread-safe
 */
final class SocketChannel : BaseSocketChannel<Socket> {

    init(eventLoop: SelectableEventLoop, protocolFamily: Int32) throws {
        let socket = try Socket(protocolFamily: protocolFamily)
        do {
            try socket.setNonBlocking()
        } catch let err {
            let _ = try? socket.close()
            throw err
        }
        try super.init(socket: socket, eventLoop: eventLoop)
    }

    public override func registrationFor(interested: IOEvent) -> NIORegistration {
        return .socketChannel(self, interested)
    }

    fileprivate override init(socket: Socket, eventLoop: SelectableEventLoop) throws {
        try socket.setNonBlocking()
        try super.init(socket: socket, eventLoop: eventLoop)
    }

    fileprivate convenience init(socket: Socket, eventLoop: SelectableEventLoop, parent: Channel) throws {
        try self.init(socket: socket, eventLoop: eventLoop)
        self.parent = parent
    }

    override fileprivate func readFromSocket() throws {
        // Just allocate one time for the while read loop. This is fine as ByteBuffer is a struct and uses COW.
        var buffer = try recvAllocator.buffer(allocator: allocator)
        for _ in 1...maxMessagesPerRead {
            guard !closed else {
                return
            }
            switch try buffer.withMutableWritePointer(body: self.socket.read(pointer:size:)) {
            case .processed(let bytesRead):
                if bytesRead > 0 {
                    recvAllocator.record(actualReadBytes: bytesRead)

                    readPending = false

                    assert(!closed)
                    pipeline.fireChannelRead0(data: NIOAny(buffer))

                    // Reset reader and writerIndex and so allow to have the buffer filled again
                    buffer.clear()
                } else {
                    // end-of-file
                    throw ChannelError.eof
                }
            case .wouldBlock(let bytesRead):
                assert(bytesRead == 0)
                return
            }
        }
    }

    override fileprivate func writeToSocket(pendingWrites: PendingWrites) throws -> WriteResult {
        repeat {
            let result = try pendingWrites.consume(oneBody: { ptr in
                guard ptr.count > 0 else {
                    // No need to call write if the buffer is empty.
                    return .processed(0)
                }
                // normal write
                return try self.socket.write(pointer: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), size: ptr.count)
            }, multipleBody: { ptrs in
                switch ptrs.count {
                case 0:
                    // No need to call write if the buffer is empty.
                    return .processed(0)
                case 1:
                    let p = ptrs[0]
                    guard p.iov_len > 0 else {
                        // No need to call write if the buffer is empty.
                        return .processed(0)
                    }
                    return try self.socket.write(pointer: p.iov_base.assumingMemoryBound(to: UInt8.self), size: p.iov_len)
                default:
                    // Gathering write
                    return try self.socket.writev(iovecs: ptrs)
                }
            }, fileRegionBody: { descriptor, index, endIndex in
                return try self.socket.sendFile(fd: descriptor, offset: index, count: endIndex - index)
            })
            if result.writable {
                // writable again
                self.pipeline.fireChannelWritabilityChanged0()
            }
            if result.writeResult == .writtenCompletely && pendingWrites.isFlushPending {
                // there are more buffers to process, so continue
                continue
            }
            return result.writeResult
        } while true
    }

    override fileprivate func connectSocket(to address: SocketAddress) throws -> Bool {
        return try self.socket.connect(to: address)
    }

    override fileprivate func finishConnectSocket() throws {
        try self.socket.finishConnect()
        becomeActive0()
    }
}

/*
 All operations on ServerSocketChannel are thread-safe
 */
final class ServerSocketChannel : BaseSocketChannel<ServerSocket> {

    private var backlog: Int32 = 128
    private let group: EventLoopGroup

    init(eventLoop: SelectableEventLoop, group: EventLoopGroup, protocolFamily: Int32) throws {
        let serverSocket = try ServerSocket(protocolFamily: protocolFamily)
        do {
            try serverSocket.setNonBlocking()
        } catch let err {
            let _ = try? serverSocket.close()
            throw err
        }
        self.group = group
        try super.init(socket: serverSocket, eventLoop: eventLoop)
    }

    public override func registrationFor(interested: IOEvent) -> NIORegistration {
        return .serverSocketChannel(self, interested)
    }

    override fileprivate func setOption0<T: ChannelOption>(option: T, value: T.OptionType) throws {
        assert(eventLoop.inEventLoop)
        if option is BacklogOption {
            backlog = value as! Int32
        } else {
            try super.setOption0(option: option, value: value)
        }
    }

    override fileprivate func getOption0<T: ChannelOption>(option: T) throws -> T.OptionType {
        assert(eventLoop.inEventLoop)
        if option is BacklogOption {
            return backlog as! T.OptionType
        }
        return try super.getOption0(option: option)
    }

    override public func bind0(to address: SocketAddress, promise: Promise<Void>?) {
        assert(eventLoop.inEventLoop)
        do {
            try socket.bind(to: address)
            try self.socket.listen(backlog: backlog)
            promise?.succeed(result: ())
            becomeActive0()
            readIfNeeded0()
        } catch let err {
            promise?.fail(error: err)
        }
    }

    override fileprivate func connectSocket(to address: SocketAddress) throws -> Bool {
        throw ChannelError.operationUnsupported
    }

    override fileprivate func finishConnectSocket() throws {
        throw ChannelError.operationUnsupported
    }

    override fileprivate func readFromSocket() throws {
        for _ in 1...maxMessagesPerRead {
            guard !closed else {
                return
            }
            if let accepted =  try self.socket.accept() {
                readPending = false

                do {
                    let chan = try SocketChannel(socket: accepted, eventLoop: group.next() as! SelectableEventLoop, parent: self)
                    pipeline.fireChannelRead0(data: NIOAny(chan))
                } catch let err {
                    let _ = try? accepted.close()
                    throw err
                }
            } else {
                return
            }
        }
    }

    override fileprivate func writeToSocket(pendingWrites: PendingWrites) throws -> WriteResult {
        pendingWrites.failAll(error: ChannelError.operationUnsupported)
        return .writtenCompletely
    }

    override public func channelRead0(data: NIOAny) {
        assert(eventLoop.inEventLoop)

        let ch = data.forceAsOther() as SocketChannel
        let f = ch.register()
        f.whenComplete(callback: { v in
            switch v {
            case .failure(_):
                ch.close(promise: nil)
            case .success(_):
                ch.becomeActive0()
                ch.readIfNeeded0()
            }
        })
    }
}


/*
 All methods must be called from the EventLoop thread
 */
public protocol ChannelCore : class {
    func register0(promise: Promise<Void>?)
    func bind0(to: SocketAddress, promise: Promise<Void>?)
    func connect0(to: SocketAddress, promise: Promise<Void>?)
    func write0(data: IOData, promise: Promise<Void>?)
    func flush0(promise: Promise<Void>?)
    func read0(promise: Promise<Void>?)
    func close0(error: Error, promise: Promise<Void>?)
    func triggerUserOutboundEvent0(event: Any, promise: Promise<Void>?)
    func channelRead0(data: NIOAny)
    func errorCaught0(error: Error)
}

/*
 All methods exposed by Channel are thread-safe
 */
public protocol Channel : class, ChannelOutboundInvoker {
    var allocator: ByteBufferAllocator { get }

    var closeFuture: Future<Void> { get }

    var pipeline: ChannelPipeline { get }
    var localAddress: SocketAddress? { get }
    var remoteAddress: SocketAddress? { get }

    var parent: Channel? { get }

    func setOption<T: ChannelOption>(option: T, value: T.OptionType) throws
    func getOption<T: ChannelOption>(option: T) throws -> T.OptionType

    var isWritable: Bool { get }
    var isActive: Bool { get }

    var _unsafe: ChannelCore { get }
}

protocol SelectableChannel : Channel {
    associatedtype SelectableType: Selectable

    var selectable: SelectableType { get }
    var interestedEvent: IOEvent { get }

    func writable()
    func readable()

    func registrationFor(interested: IOEvent) -> NIORegistration
}

extension Channel {
    public var open: Bool {
        return !closeFuture.fulfilled
    }

    public func bind(to address: SocketAddress, promise: Promise<Void>?) {
        pipeline.bind(to: address, promise: promise)
    }

    // Methods invoked from the HeadHandler of the ChannelPipeline
    // By default, just pass through to pipeline

    public func connect(to address: SocketAddress, promise: Promise<Void>?) {
        pipeline.connect(to: address, promise: promise)
    }

    public func write(data: NIOAny, promise: Promise<Void>?) {
        pipeline.write(data: data, promise: promise)
    }

    public func flush(promise: Promise<Void>?) {
        pipeline.flush(promise: promise)
    }
    
    public func writeAndFlush(data: NIOAny, promise: Promise<Void>?) {
        pipeline.writeAndFlush(data: data, promise: promise)
    }

    public func read(promise: Promise<Void>?) {
        pipeline.read(promise: promise)
    }

    public func close(promise: Promise<Void>?) {
        pipeline.close(promise: promise)
    }

    public func register(promise: Promise<Void>?) {
        pipeline.register(promise: promise)
    }
    
    public func triggerUserOutboundEvent(event: Any, promise: Promise<Void>?) {
        pipeline.triggerUserOutboundEvent(event: event, promise: promise)
    }
}

class BaseSocketChannel<T : BaseSocket> : SelectableChannel, ChannelCore {
    typealias SelectableType = T

    func registrationFor(interested: IOEvent) -> NIORegistration {
        fatalError("must override")
    }

    var selectable: T {
        return self.socket
    }

    public final var _unsafe: ChannelCore { return self }

    // Visible to access from EventLoop directly
    let socket: T
    public var interestedEvent: IOEvent = .none

    public final var closed: Bool {
        return pendingWrites.closed
    }

    private let pendingWrites: PendingWrites
    fileprivate var readPending = false
    private var neverRegistered = true
    private var pendingConnect: Promise<Void>?
    private let closePromise: Promise<Void>
    private var active: Atomic<Bool> = Atomic(value: false)
    public var isActive: Bool {
        return active.load()
    }

    public var parent: Channel? = nil

    public final var closeFuture: Future<Void> {
        return closePromise.futureResult
    }

    private let selectableEventLoop: SelectableEventLoop

    public final var eventLoop: EventLoop {
        return selectableEventLoop
    }

    public final var isWritable: Bool {
        return pendingWrites.isWritable
    }

    public final var allocator: ByteBufferAllocator {
        if eventLoop.inEventLoop {
            return bufferAllocator
        } else {
            return try! eventLoop.submit{ self.bufferAllocator }.wait()
        }
    }

    private var bufferAllocator: ByteBufferAllocator = ByteBufferAllocator()
    fileprivate var recvAllocator: RecvByteBufferAllocator = AdaptiveRecvByteBufferAllocator()
    fileprivate var autoRead: Bool = true
    fileprivate var maxMessagesPerRead: UInt = 4

    // We don't use lazy var here as this is more expensive then doing this :/
    public final var pipeline: ChannelPipeline {
        return _pipeline
    }

    private var _pipeline: ChannelPipeline!

    public final func setOption<T: ChannelOption>(option: T, value: T.OptionType) throws {
        if eventLoop.inEventLoop {
            try setOption0(option: option, value: value)
        } else {
            let _ = try eventLoop.submit { try self.setOption0(option: option, value: value)}.wait()
        }
    }

    fileprivate func setOption0<T: ChannelOption>(option: T, value: T.OptionType) throws {
        assert(eventLoop.inEventLoop)

        if option is SocketOption {
            let (level, name) = option.value as! (SocketOptionLevel, SocketOptionName)
            try socket.setOption(level: Int32(level), name: name, value: value)
        } else if option is AllocatorOption {
            bufferAllocator = value as! ByteBufferAllocator
        } else if option is RecvAllocatorOption {
            recvAllocator = value as! RecvByteBufferAllocator
        } else if option is AutoReadOption {
            let auto = value as! Bool
            autoRead = auto
            if auto {
                read0(promise: nil)
            } else {
                pauseRead0()
            }
        } else if option is MaxMessagesPerReadOption {
            maxMessagesPerRead = value as! UInt
        } else if option is WriteSpinOption {
            pendingWrites.writeSpinCount = value as! UInt
        } else if option is WriteBufferWaterMark {
            pendingWrites.waterMark = value as! WriteBufferWaterMark
        } else {
            fatalError("option \(option) not supported")
        }
    }

    public final func getOption<T: ChannelOption>(option: T) throws -> T.OptionType {
        if eventLoop.inEventLoop {
            return try getOption0(option: option)
        } else {
            return try eventLoop.submit{ try self.getOption0(option: option) }.wait()
        }
    }

    fileprivate func getOption0<T: ChannelOption>(option: T) throws -> T.OptionType {
        assert(eventLoop.inEventLoop)

        if option is SocketOption {
            let (level, name) = option.value as! (SocketOptionLevel, SocketOptionName)
            return try socket.getOption(level: Int32(level), name: name)
        }
        if option is AllocatorOption {
            return bufferAllocator as! T.OptionType
        }
        if option is RecvAllocatorOption {
            return recvAllocator as! T.OptionType
        }
        if option is AutoReadOption {
            return autoRead as! T.OptionType
        }
        if option is MaxMessagesPerReadOption {
            return maxMessagesPerRead as! T.OptionType
        }
        if option is WriteSpinOption {
            return pendingWrites.writeSpinCount as! T.OptionType
        }
        if option is WriteBufferWaterMarkOption {
            return pendingWrites.waterMark as! T.OptionType
        }
        fatalError("option \(option) not supported")
    }

    public final var localAddress: SocketAddress? {
        get {
            return socket.localAddress
        }
    }

    public final var remoteAddress: SocketAddress? {
        get {
            return socket.remoteAddress
        }
    }

    final func readIfNeeded0() {
        if autoRead {
            pipeline.read0(promise: nil)
        }
    }

    // Methods invoked from the HeadHandler of the ChannelPipeline
    public func bind0(to address: SocketAddress, promise: Promise<Void>?) {
        assert(eventLoop.inEventLoop)

        do {
            try socket.bind(to: address)
            promise?.succeed(result: ())
        } catch let err {
            promise?.fail(error: err)
        }
    }

    public func write0(data: IOData, promise: Promise<Void>?) {
        assert(eventLoop.inEventLoop)

        guard !closed else {
            // Channel was already closed, fail the promise and not even queue it.
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }
        if !self.pendingWrites.add(data: data, promise: promise) {
            pipeline.fireChannelWritabilityChanged0()
        }
    }
    
    private func registerForWritable() {
        switch interestedEvent {
        case .read:
            safeReregister(interested: .all)
        case .none:
            safeReregister(interested: .write)
        default:
            break
        }
    }

    private func unregisterForWritable() {
        switch interestedEvent {
        case .all:
            safeReregister(interested: .read)
        case .write:
            safeReregister(interested: .none)
        default:
            break
        }
    }

    public final func flush0(promise: Promise<Void>?) {
        assert(eventLoop.inEventLoop)

        guard !closed else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return;
        }
        // Even if writable() will be called later by the EVentLoop we still need to mark the flush checkpoint so we are sure all the flushed messages
        // are actually written once writable() is called.
        pendingWrites.markFlushCheckpoint(promise: promise)
        
        if !isWritePending() && !flushNow() && !closed {
            registerForWritable()
        }
    }

    public final func read0(promise: Promise<Void>?) {
        assert(eventLoop.inEventLoop)

     
        guard !closed else {
            promise?.fail(error:ChannelError.ioOnClosedChannel)
            return
        }
        defer {
            promise?.succeed(result: ())
        }
        readPending = true

        registerForReadable()
    }

    private final func pauseRead0() {
        assert(eventLoop.inEventLoop)

        guard !closed else {
            return
        }
        unregisterForReadable()
    }

    private func registerForReadable() {
        switch interestedEvent {
        case .write:
            safeReregister(interested: .all)
        case .none:
            safeReregister(interested: .read)
        default:
            break
        }
    }

    private func unregisterForReadable() {
        switch interestedEvent {
        case .read:
            safeReregister(interested: .none)
        case .all:
            safeReregister(interested: .write)
        default:
            break
        }
    }

    public final func close0(error: Error, promise: Promise<Void>?) {
        assert(eventLoop.inEventLoop)

        guard !closed else {
            // Already closed
            promise?.fail(error: ChannelError.alreadyClosed)
            return
        }

        interestedEvent = .none
        do {
            try selectableEventLoop.deregister(channel: self)
        } catch let err {
            pipeline.fireErrorCaught0(error: err)
        }

        do {
            try socket.close()
            promise?.succeed(result: ())
        } catch let err {
            promise?.fail(error: err)
        }

        // Fail all pending writes and so ensure all pending promises are notified
        self.pendingWrites.failAll(error: error)

        becomeInactive0()

        if !neverRegistered {
            pipeline.fireChannelUnregistered0()
        }
        
        eventLoop.execute {
            // ensure this is executed in a delayed fashion as the users code may still traverse the pipeline
            self.pipeline.removeHandlers()
            
            self.closePromise.succeed(result: ())
        }

        if let connectPromise = pendingConnect {
            pendingConnect = nil
            connectPromise.fail(error: error)
        }
    }


    public final func register0(promise: Promise<Void>?) {
        assert(eventLoop.inEventLoop)

        // Was not registered yet so do it now.
        if safeRegister(interested: .read) {
            neverRegistered = false
            promise?.succeed(result: ())
            pipeline.fireChannelRegistered0()
        } else {
            promise?.succeed(result: ())
        }
    }
    
    public final func triggerUserOutboundEvent0(event: Any, promise: Promise<Void>?) {
        promise?.succeed(result: ())
    }
    
    // Methods invoked from the EventLoop itself
    public final func writable() {
        assert(eventLoop.inEventLoop)
        assert(!closed)

        finishConnect()  // If we were connecting, that has finished.
        if flushNow() {
            // Everything was written or connect was complete
            finishWritable()
        }
    }

    private func finishConnect() {
        if let connectPromise = pendingConnect {
            pendingConnect = nil
            do {
                try finishConnectSocket()
                connectPromise.succeed(result: ())
            } catch let error {
                connectPromise.fail(error: error)
            }
        }
    }

    private func finishWritable() {
        assert(eventLoop.inEventLoop)

        guard !closed else {
            return
        }

        unregisterForWritable()
    }

    public final func readable() {
        assert(eventLoop.inEventLoop)
        assert(!closed)

        defer {
            if !closed, !readPending {
                unregisterForReadable()
            }
        }

        do {
            try readFromSocket()
        } catch let err {
            if let channelErr = err as? ChannelError {
                // EOF is not really an error that should be forwarded to the user
                if channelErr != ChannelError.eof {
                    pipeline.fireErrorCaught0(error: err)
                }
            } else {
                pipeline.fireErrorCaught0(error: err)
            }

            // Call before triggering the close of the Channel.
            pipeline.fireChannelReadComplete0()
            close0(error: err, promise: nil)

            return
        }
        pipeline.fireChannelReadComplete0()
        readIfNeeded0()
    }

    fileprivate func connectSocket(to address: SocketAddress) throws -> Bool {
        fatalError("this must be overridden by sub class")
    }

    fileprivate func finishConnectSocket() throws {
        fatalError("this must be overridden by sub class")
    }

    public final func connect0(to address: SocketAddress, promise: Promise<Void>?) {
        assert(eventLoop.inEventLoop)

        guard pendingConnect == nil else {
            promise?.fail(error: ChannelError.connectPending)
            return
        }
        do {
            if try !connectSocket(to: address) {
                if promise != nil {
                    pendingConnect = promise
                } else {
                    pendingConnect = eventLoop.newPromise()
                }
                registerForWritable()
            } else {
                promise?.succeed(result: ())
            }
        } catch let error {
            promise?.fail(error: error)
        }
    }

    fileprivate func readFromSocket() throws {
        fatalError("this must be overridden by sub class")
    }


    fileprivate func writeToSocket(pendingWrites: PendingWrites) throws -> WriteResult {
        fatalError("this must be overridden by sub class")
    }

    public func channelRead0(data: NIOAny) {
        // Do nothing by default
    }
    
    public func errorCaught0(error: Error) {
        // Do nothing
    }
    
    private func isWritePending() -> Bool {
        return interestedEvent == .write || interestedEvent == .all
    }

    private func safeReregister(interested: IOEvent) {
        guard !closed else {
            interestedEvent = .none
            return
        }
        guard interested != interestedEvent && interestedEvent != .none else {
            // we not need to update and so cause a syscall if we already are registered with the correct event
            return
        }
        interestedEvent = interested
        do {
            try selectableEventLoop.reregister(channel: self)
        } catch let err {
            pipeline.fireErrorCaught0(error: err)
            close0(error: err, promise: nil)
        }
    }

    private func safeRegister(interested: IOEvent) -> Bool {
        guard !closed else {
            interestedEvent = .none
            return false
        }
        interestedEvent = interested
        do {
            try selectableEventLoop.register(channel: self)
            return true
        } catch let err {
            pipeline.fireErrorCaught0(error: err)
            close0(error: err, promise: nil)
            return false
        }
    }

    private func flushNow() -> Bool {
        while !closed {
            do {
                switch try self.writeToSocket(pendingWrites: pendingWrites) {
                case .writtenPartially:
                    // Could not write the next buffer(s) completely
                    return false
                case .wouldBlock:
                    return false
                case .writtenCompletely:
                    return true
                case .closed:
                    return true
                case .nothingToBeWritten:
                    return true
                }
            } catch let err {
                close0(error: err, promise: nil)

                // we handled all writes
                return true
            }
        }
        return true
    }

    fileprivate func becomeActive0() {
        assert(eventLoop.inEventLoop)
        active.store(true)
        pipeline.fireChannelActive0()
    }

    fileprivate func becomeInactive0() {
        assert(eventLoop.inEventLoop)
        active.store(false)
        pipeline.fireChannelInactive0()
    }

    fileprivate init(socket: T, eventLoop: SelectableEventLoop) throws {
        self.socket = socket
        self.selectableEventLoop = eventLoop
        self.closePromise = eventLoop.newPromise()
        self.pendingWrites = PendingWrites(iovecs: eventLoop.iovecs, storageRefs: eventLoop.storageRefs)
        active.store(false)
        self._pipeline = ChannelPipeline(channel: self)
    }

    deinit {
        // We should never have any pending writes left as otherwise we may leak callbacks
        assert(pendingWrites.isEmpty)
    }
}

public enum ChannelError: Error {
    case connectPending
    case messageUnsupported
    case operationUnsupported
    /* read, write or flush was called on a channel that is already closed */
    case ioOnClosedChannel
    /* close was called on a channel that is already closed */
    case alreadyClosed
    case eof
}
