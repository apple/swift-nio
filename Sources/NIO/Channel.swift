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

import Foundation
import Sockets
import ConcurrencyHelpers

#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum IOData {
    case byteBuffer(ByteBuffer)
    case other(Any)

    public func tryAsByteBuffer() -> ByteBuffer? {
        if case .byteBuffer(let bb) = self {
            return bb
        } else {
            return nil
        }
    }

    public func forceAsByteBuffer() -> ByteBuffer {
        return tryAsByteBuffer()!
    }

    public func tryAsOther<T>(type: T.Type = T.self) -> T? {
        if case .other(let any) = self {
            return any as? T
        } else {
            return nil
        }
    }

    public func forceAsOther<T>(type: T.Type = T.self) -> T {
        return tryAsOther(type: type)!
    }
}

final class PendingWrite {
    var next: PendingWrite?
    var buffer: ByteBuffer
    var promise: Promise<Void>?

    init(buffer: ByteBuffer, promise: Promise<Void>?) {
        self.buffer = buffer
        self.promise = promise
    }
}

func doPendingWriteVectorOperation(pending: PendingWrite?,
                                   count: Int,
                                   iovecs: UnsafeMutableBufferPointer<IOVector>,
                                   storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>,
                                   _ fn: (UnsafeBufferPointer<IOVector>) throws -> IOResult<Int>) throws -> IOResult<Int> {
    var next = pending
    for i in 0..<count {
        if let p = next {
            p.buffer.withUnsafeReadableBytesWithStorageManagement { ptr, storageRef in
                storageRefs[i] = storageRef.retain()
                iovecs[i] = iovec(iov_base: UnsafeMutableRawPointer(mutating: ptr.baseAddress!), iov_len: ptr.count)
            }
            next = p.next
        } else {
            fatalError("can't find \(count) nodes in \(pending.debugDescription)")
            break
        }
    }
    defer {
        for i in 0..<count {
            storageRefs[i].release()
        }
    }
    let result = try fn(UnsafeBufferPointer(start: iovecs.baseAddress!, count: count))
    return result
}

private enum WriteResult {
    case writtenCompletely
    case writtenPartially
    case nothingToBeWritten
    case wouldBlock
    case closed
}

final fileprivate class PendingWrites {

    private var head: PendingWrite?
    private var tail: PendingWrite?
    // Marks the last PendingWrite that should be written by consume(...)
    private var flushCheckpoint: PendingWrite?
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
        return tail == nil
    }

    func add(buffer: ByteBuffer, promise: Promise<Void>?) -> Bool {
        assert(!closed)
        let pending: PendingWrite = PendingWrite(buffer: buffer, promise: promise)
        if let last = tail {
            assert(head != nil)
            last.next = pending
            tail = pending
        } else {
            assert(tail == nil)
            head = pending
            tail = pending
        }
        outstanding = (chunks: outstanding.chunks + 1,
                       bytes: outstanding.bytes + buffer.readableBytes)
        if outstanding.bytes > Int(waterMark.upperBound) && writable.compareAndExchange(expected: true, desired: false) {
            // Returns false to signal the Channel became non-writable and we need to notify the user
            return false
        }
        return true
    }

    private var hasMultiple: Bool {
        return head?.next != nil
    }

    func markFlushCheckpoint(promise: Promise<Void>?) {
        flushCheckpoint = tail
        if let promise = promise {
            if let checkpoint = flushCheckpoint {
                if let p = checkpoint.promise {
                    p.futureResult.cascade(promise: promise)
                } else {
                    checkpoint.promise = promise
                }
            }
        }
    }

    /*
     Function that takes two closures and based on if there are more then one ByteBuffer pending calls either one or the other.
    */
    func consume(oneBody: (UnsafePointer<UInt8>, Int) throws -> IOResult<Int>, multipleBody: (UnsafeBufferPointer<IOVector>) throws -> IOResult<Int>) throws -> (writeResult: WriteResult, writable: Bool) {
        let wasWritable = writable.load()
        let result = try hasMultiple ? consumeMultiple(multipleBody) : consumeOne(oneBody)

        if !wasWritable {
            // Was not writable before so signal back to the caller the possible state change
            return (result, writable.load())
        }
        return (result, false)
    }

    private func updateNodes(pending: PendingWrite) {
        head = pending.next
        if head == nil {
            tail = nil
            flushCheckpoint = nil
        } else if pending === flushCheckpoint {
            // pending was the flush checkpoint so reset it
            flushCheckpoint = nil
        }
    }

    var isFlushPending: Bool {
        return flushCheckpoint != nil
    }

    private func consumeOne(_ body: (UnsafePointer<UInt8>, Int) throws -> IOResult<Int>) rethrows -> WriteResult {
        if let pending = head, isFlushPending {
            for _ in 0..<writeSpinCount + 1 {
                guard !closed else {
                    return .closed
                }
                switch try pending.buffer.withReadPointer(body: body) {
                case .processed(let written):
                    outstanding = (outstanding.chunks, outstanding.bytes - written)

                    if outstanding.bytes < Int(waterMark.lowerBound) {
                        writable.store(true)
                    }

                    if pending.buffer.readableBytes == written {

                        outstanding = (outstanding.chunks-1, outstanding.bytes)

                        // Directly update nodes as a promise may trigger a callback that will access the PendingWrites class.
                        updateNodes(pending: pending)

                        // buffer was completely written
                        pending.promise?.succeed(result: ())
                        
                        return isFlushPending ? .writtenCompletely : .nothingToBeWritten
                    } else {
                        // Update readerIndex of the buffer
                        pending.buffer.moveReaderIndex(forwardBy: written)
                    }
                case .wouldBlock:
                    return .wouldBlock
                }
            }
            return .writtenPartially
        }

        return .nothingToBeWritten
    }

    private func consumeMultiple(_ body: (UnsafeBufferPointer<IOVector>) throws -> IOResult<Int>) throws -> WriteResult {
        if var pending = head, isFlushPending {
            writeLoop: for _ in 0..<writeSpinCount + 1 {
                guard !closed else {
                    return .closed
                }
                var expected = 0
                switch try doPendingWriteVectorOperation(pending: pending,
                                                         count: outstanding.chunks,
                                                         iovecs: self.iovecs,
                                                         storageRefs: self.storageRefs,
                                                         { pointer in
                                                            expected += pointer.count
                                                            return try body(pointer)
                }) {
                case .processed(let written):
                    outstanding = (outstanding.chunks, outstanding.bytes - written)

                    if outstanding.bytes < Int(waterMark.lowerBound) {
                        writable.store(true)
                    }

                    var w = written
                    while let p = head {
                        if w >= p.buffer.readableBytes {
                            w -= p.buffer.readableBytes

                            outstanding = (outstanding.chunks-1, outstanding.bytes)

                            // Directly update nodes as a promise may trigger a callback that will access the PendingWrites class.
                            updateNodes(pending: p)

                            // buffer was completely written
                            p.promise?.succeed(result: ())

                            if w == 0 {
                                return isFlushPending ? .writtenCompletely : .nothingToBeWritten
                            }

                        } else {
                            // Only partly written, so update the readerIndex.
                            p.buffer.moveReaderIndex(forwardBy: w)

                            // update pending so we not need to process the old PendingWrites that we already processed and completed
                            pending = p

                            // may try again depending on the writeSpinCount
                            continue writeLoop
                        }
                    }
                case .wouldBlock:
                    return .wouldBlock
                }
            }
            return .writtenPartially
        }

        return .nothingToBeWritten
    }


    private func killAll(node: PendingWrite?, deconstructor: (PendingWrite) -> ()) {
        var link = node
        while link != nil {
            let curr = link!
            link = curr.next
            curr.next = nil
            deconstructor(curr)
        }
    }

    func failAll(error: Error) {
        closed = true

        /*
         Workaround for https://bugs.swift.org/browse/SR-5145 which is that this linked list can cause a
         stack overflow when released as the `deinit`s will get called with recursion.
        */

        killAll(node: head, deconstructor: { pending in
            outstanding = (outstanding.chunks-1, outstanding.bytes - pending.buffer.readableBytes)

            pending.promise?.fail(error: error)
        })

        // Remove references.
        head = nil
        tail = nil
        flushCheckpoint = nil

        assert(outstanding == (0, 0))
    }

    init(iovecs: UnsafeMutableBufferPointer<IOVector>, storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>) {
        self.iovecs = iovecs
        self.storageRefs = storageRefs
    }
}

// MARK: Compatibility
extension ByteBuffer {
    public func withReadPointer<T>(body: (UnsafePointer<UInt8>, Int) throws -> T) rethrows -> T {
        return try self.withUnsafeReadableBytes { ptr in
            try body(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), ptr.count)
        }
    }

    public mutating func withMutableWritePointer(body: (UnsafeMutablePointer<UInt8>, Int) throws -> IOResult<Int>) rethrows -> IOResult<Int> {
        var writeResult: IOResult<Int>!
        _ = try self.writeWithUnsafeMutableBytes { ptr in
            let localWriteResult = try body(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), ptr.count)
            writeResult = localWriteResult
            switch localWriteResult {
            case .processed(let written):
                return written
            case .wouldBlock:
                return 0
            }
        }
        return writeResult
    }
}

/*
 All operations on SocketChannel are thread-safe
 */
final class SocketChannel : BaseSocketChannel<Socket> {

    init(eventLoop: SelectableEventLoop) throws {
        let socket = try Socket()
        do {
            try socket.setNonBlocking()
        } catch let err {
            let _ = try? socket.close()
            throw err
        }

        try super.init(socket: socket, eventLoop: eventLoop)
    }

    public override func registrationFor(interested: InterestedEvent) -> NIORegistration {
        return .socketChannel(self, interested)
    }

    fileprivate override init(socket: Socket, eventLoop: SelectableEventLoop) throws {
        try socket.setNonBlocking()
        try super.init(socket: socket, eventLoop: eventLoop)
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
                    pipeline.fireChannelRead0(data: .byteBuffer(buffer))

                    // Reset reader and writerIndex and so allow to have the buffer filled again
                    buffer.clear()
                } else {
                    // end-of-file
                    throw ChannelError.eof
                }
            case .wouldBlock:
                return
            }
        }
    }

    override fileprivate func writeToSocket(pendingWrites: PendingWrites) throws -> WriteResult {
        repeat {
            let result = try pendingWrites.consume(oneBody: { ptr, length in
                guard length > 0 else {
                    // No need to call write if the buffer is empty.
                    return .processed(0)
                }
                // normal write
                return try self.socket.write(pointer: ptr, size: length)
            }, multipleBody: { ptrs in
                switch ptrs.count {
                case 0:
                    // No need to call write if the buffer is empty.
                    return .processed(0)
                case 1:
                    let p = ptrs[0]
                    return try self.socket.write(pointer: p.iov_base.assumingMemoryBound(to: UInt8.self), size: p.iov_len)
                default:
                    // Gathering write
                    return try self.socket.writev(iovecs: ptrs)
                }
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
    }
}

/*
 All operations on ServerSocketChannel are thread-safe
 */
final class ServerSocketChannel : BaseSocketChannel<ServerSocket> {

    private var backlog: Int32 = 128
    private let group: EventLoopGroup

    init(eventLoop: SelectableEventLoop, group: EventLoopGroup) throws {
        let serverSocket = try ServerSocket()
        do {
            try serverSocket.setNonBlocking()
        } catch let err {
            let _ = try? serverSocket.close()
            throw err
        }
        self.group = group
        try super.init(socket: serverSocket, eventLoop: eventLoop)
    }

    public override func registrationFor(interested: InterestedEvent) -> NIORegistration {
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
            pipeline.fireChannelActive0()
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
                    pipeline.fireChannelRead0(data: .other(try SocketChannel(socket: accepted, eventLoop: group.next() as! SelectableEventLoop)))
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

    override public func channelRead0(data: IOData) {
        assert(eventLoop.inEventLoop)

        let ch = data.forceAsOther() as SocketChannel
        let f = ch.register()
        f.whenFailure(callback: { err in
            _ = ch.close()
        })
        f.whenSuccess { () -> Void in
            ch.pipeline.fireChannelActive0()
            ch.readIfNeeded0()
        }
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
    func channelRead0(data: IOData)
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

    func setOption<T: ChannelOption>(option: T, value: T.OptionType) throws
    func getOption<T: ChannelOption>(option: T) throws -> T.OptionType

    var isWritable: Bool { get }

    var _unsafe: ChannelCore { get }
}

protocol SelectableChannel : Channel {
    associatedtype SelectableType: Selectable

    var selectable: SelectableType { get }
    var interestedEvent: InterestedEvent { get }

    func writable()
    func readable()

    func registrationFor(interested: InterestedEvent) -> NIORegistration
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

    public func write(data: IOData, promise: Promise<Void>?) {
        pipeline.write(data: data, promise: promise)
    }

    public func flush(promise: Promise<Void>?) {
        pipeline.flush(promise: promise)
    }
    
    public func writeAndFlush(data: IOData, promise: Promise<Void>?) {
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

    func registrationFor(interested: InterestedEvent) -> NIORegistration {
        fatalError("must override")
    }

    var selectable: T {
        return self.socket
    }

    public final var _unsafe: ChannelCore { return self }

    // Visible to access from EventLoop directly
    let socket: T
    public var interestedEvent: InterestedEvent = .none

    public final var closed: Bool {
        return pendingWrites.closed
    }

    private let pendingWrites: PendingWrites
    fileprivate var readPending = false
    private var neverRegistered = true
    private var pendingConnect: Promise<Void>?
    private let closePromise: Promise<Void>

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
            promise?.fail(error: ChannelError.closed)
            return
        }
        if let buffer = data.tryAsByteBuffer() {
            if !pendingWrites.add(buffer: buffer, promise: promise) {
                pipeline.fireChannelWritabilityChanged0()
            }
        } else {
            // Only support ByteBuffer for now.
            promise?.fail(error: ChannelError.messageUnsupported)
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

    public final func flush0(promise: Promise<Void>?) {
        assert(eventLoop.inEventLoop)

        // Even if writable() will be called later by the EVentLoop we still need to mark the flush checkpoint so we are sure all the flushed messages
        // are actual written once writable() is called.
        pendingWrites.markFlushCheckpoint(promise: promise)
        
        if !isWritePending() && !flushNow() && !closed {
            registerForWritable()
        }
    }

    public final func read0(promise: Promise<Void>?) {
        assert(eventLoop.inEventLoop)

        defer {
            promise?.succeed(result: ())
        }
        guard !closed else {
            return
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
            promise?.succeed(result: ())
            return
        }

        safeDeregister()

        do {
            try socket.close()
            promise?.succeed(result: ())
        } catch let err {
            promise?.fail(error: err)
        }
        if !neverRegistered {
            pipeline.fireChannelUnregistered0()
        }
        pipeline.fireChannelInactive0()

        eventLoop.execute {
            // ensure this is executed in a delayed fashion as the users code may still traverse the pipeline
            self.pipeline.removeHandlers()
            
            // Fail all pending writes and so ensure all pending promises are notified
            self.pendingWrites.failAll(error: error)
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

        if finishConnect() || flushNow() {
            // Everything was written or connect was complete
            finishWritable()
        }
    }

    private func finishConnect() -> Bool {
        if let connectPromise = pendingConnect {
            pendingConnect = nil
            do {
                try finishConnectSocket()
                connectPromise.succeed(result: ())
            } catch let error {
                connectPromise.fail(error: error)
            }
            return true
        }
        return false
    }

    private func finishWritable() {
        assert(eventLoop.inEventLoop)

        guard !closed else {
            return
        }

        if readPending {
            // Start reading again
            safeReregister(interested: .read)
        } else {
            // No read pending so just set the interested event to .none
            safeReregister(interested: .none)
        }
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
                registerForWritable()
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

    public func channelRead0(data: IOData) {
        // Do nothing by default
    }

    private func isWritePending() -> Bool {
        return interestedEvent == .write || interestedEvent == .all
    }

    // Methods only used from within this class
    private func safeDeregister() {
        interestedEvent = .none
        do {
            try selectableEventLoop.deregister(channel: self)
        } catch let err {
            pipeline.fireErrorCaught0(error: err)
            close0(error: err, promise: nil)
        }
    }

    private func safeReregister(interested: InterestedEvent) {
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

    private func safeRegister(interested: InterestedEvent) -> Bool {
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

    fileprivate init(socket: T, eventLoop: SelectableEventLoop) throws {
        self.socket = socket
        self.selectableEventLoop = eventLoop
        self.closePromise = eventLoop.newPromise()
        self.pendingWrites = PendingWrites(iovecs: eventLoop.iovecs, storageRefs: eventLoop.storageRefs)
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
    case closed
    case eof
}
