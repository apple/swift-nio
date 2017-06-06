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
import Future
import Sockets

#if os(Linux)
import Glibc
#else
import Darwin
#endif

fileprivate class PendingWrites {
    
    private var head: PendingWrite?
    private var tail: PendingWrite?
    // Marks the last PendingWrite that should be written by consume(...)
    private var flushCheckpoint: PendingWrite?

    private(set) var outstanding: UInt64 = 0
    
    var isEmpty: Bool {
        return tail == nil
    }
    
    func add(buffer: ByteBuffer, promise: Promise<Void>) {
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
        outstanding += UInt64(buffer.readableBytes)
    }
    
    private var hasMultiple: Bool {
        return head?.next != nil
    }
    
    func markFlushCheckpoint() {
        flushCheckpoint = tail
    }
    
    /*
     Function that takes two closures and based on if there are more then one ByteBuffer pending calls either one or the other.
    */
    func consume(oneBody: (UnsafePointer<UInt8>, Int) throws -> Int?, multipleBody: ([(UnsafePointer<UInt8>, Int)]) throws -> Int?) rethrows -> Bool? {
        
        if hasMultiple {
            // Holds multiple pending writes, use consumeMultiple which will allow us to us writev (a.k.a gathering writes)
            return try consumeMultiple(body: multipleBody)
        }
        return try consumeOne(body: oneBody)
    }
    
    private func updateNodes(pending: PendingWrite) {
        head = pending.next
        if head == nil {
            tail = nil
            flushCheckpoint = nil
        }
    }
    
    private func isFlushCheckpoint(_ pending: PendingWrite) -> Bool {
        return pending === flushCheckpoint
    }
    
    private func checkFlushCheckpoint(pending: PendingWrite) -> Bool {
        if isFlushCheckpoint(pending) {
            flushCheckpoint = nil
            return true
        }
        return false
    }
    
    private func isFlushPending() -> Bool {
        return flushCheckpoint != nil
    }
    
    private func consumeOne(body: (UnsafePointer<UInt8>, Int) throws -> Int?) rethrows -> Bool? {
        if let pending = head, isFlushPending() {
            if let written = try pending.buffer.withReadPointer(body: body) {
                outstanding -= UInt64(written)
                
                if (pending.buffer.readableBytes == written) {
                    
                    // Directly update nodes as a promise may trigger a callback that will access the PendingWrites class.
                    updateNodes(pending: pending)
                    
                    let allFlushed = checkFlushCheckpoint(pending: pending)

                    // buffer was completely written
                    pending.promise.succeed(result: ())

                    if (isEmpty || allFlushed) {
                        // return nil to signal to the caller that there are no more buffers to consume
                        return nil
                    }
                    return true
                } else {
                    pending.buffer.skipBytes(num: written)
                }
            }
            // could not write the complete buffer
            return false
        }
        
        // empty or flushed everything that is marked to be flushable
        return nil
    }
    
    private func consumeMultiple(body: ([(UnsafePointer<UInt8>, Int)]) throws -> Int?) rethrows -> Bool? {
        if let pending = head, isFlushPending() {
            var pointers: [(UnsafePointer<UInt8>, Int)] = []
            
            func consumeNext0(pendingWrite: PendingWrite?, count: Int, body: ([(UnsafePointer<UInt8>, Int)]) throws -> Int?) rethrows -> Int? {
                if let pending = pendingWrite, !isFlushCheckpoint(pending), count <= Socket.writevLimit {
                    
                    // Using withReadPointer as we not want to adjust the readerIndex yet. We will do this at a higher level
                    let written = try pending.buffer.withReadPointer(body: { (pointer: UnsafePointer<UInt8>, size: Int) -> Int? in
                        if size > 0 {
                            // Only include if its not empty
                            pointers.append((pointer, size))
                        }
                        return try consumeNext0(pendingWrite: pending.next, count: count + 1, body: body)
                    })
                    return written
                }
                return try body(pointers)
            }

            if let written = try consumeNext0(pendingWrite: pending, count: 0, body: body) {
                
                // Calculate the amount of data we expect to write with one syscall.
                var expected = 0
                for p in pointers {
                    expected += p.1
                }
                
                outstanding -= UInt64(written)
                assert(head != nil)
                
                var allFlushed = false
                var w = written
                while let p = head {
                    assert(!allFlushed)
                    
                    if w >= p.buffer.readableBytes {
                        w -= p.buffer.readableBytes
                        
                        // Directly update nodes as a promise may trigger a callback that will access the PendingWrites class.
                        updateNodes(pending: p)
                        
                        allFlushed = checkFlushCheckpoint(pending: p)

                        // buffer was completely written
                        p.promise.succeed(result: ())
                    } else {
                        // Only partly written, so update the readerIndex.
                        p.buffer.skipBytes(num: w)
                        return false
                    }
                }
                
                if (isEmpty || allFlushed) {
                    // return nil to signal to the caller that there are no more buffers to consume
                    return nil
                }
                
                // check if we were able to write everything or not
                assert(expected == written)
                return true
            }
            // could not write the complete buffer
            return false
        }
        
        // empty or flushed everything that is marked to be flushable
        return nil
    }
    
    func failAll(error: Error) {
        while let pending = head {
            outstanding -= UInt64(pending.buffer.readableBytes)
            updateNodes(pending: pending)
            pending.promise.fail(error: error)
        }
        assert(flushCheckpoint  == nil)
        assert(head == nil)
        assert(tail == nil)
        assert(outstanding == 0)
    }

    private class PendingWrite {
        var next: PendingWrite?
        var buffer: ByteBuffer
        let promise: Promise<Void>
        
        init(buffer: ByteBuffer, promise: Promise<Void>) {
            self.buffer = buffer
            self.promise = promise
        }
    }
}

/*
 All operations on SocketChannel are thread-safe
 */
public class SocketChannel : Channel {
    
    public init(eventLoop: EventLoop) throws {
        let socket = try Socket()
        do {
            try socket.setNonBlocking()
        } catch let err {
            let _ = try? socket.close()
            throw err
        }
        
        super.init(socket: socket, eventLoop: eventLoop)
    }
    
    fileprivate init(socket: Socket, eventLoop: EventLoop) throws {
        try socket.setNonBlocking()
        super.init(socket: socket, eventLoop: eventLoop)
    }
    
    override fileprivate func readFromSocket() throws -> Any? {
        var buffer = try recvAllocator.buffer(allocator: allocator)
        if let bytesRead = try buffer.withMutableWritePointer { try (self.socket as! Socket).read(pointer: $0, size: $1) } {
            if bytesRead > 0 {
                return buffer
            } else {
                // end-of-file
                throw ChannelError.eof
            }
        }
        return nil
    }
    
    override fileprivate func writeToSocket(pendingWrites: PendingWrites) throws -> Bool? {
        return try pendingWrites.consume(oneBody: {
            guard $1 > 0 else {
                // No need to call write if the buffer is empty.
                return 0
            }
            // normal write
            return try (self.socket as! Socket).write(pointer: $0, size: $1)
        }, multipleBody: {
            guard $0.count > 0 else {
                // No need to call writev if there is nothing to write.
                return 0
            }
            // gathering write
            return try (self.socket as! Socket).writev(pointers: $0)
        })
    }
    
    override fileprivate func connectSocket(remote: SocketAddress) throws -> Bool {
        return try (self.socket as! Socket).connect(remote: remote)
    }
    
    override fileprivate func finishConnectSocket() throws {
        try (self.socket as! Socket).finishConnect()
    }
}

/*
 All operations on ServerSocketChannel are thread-safe
 */
public class ServerSocketChannel : Channel {
    
    private var backlog: Int32 = 128
    private let group: EventLoopGroup
    
    public init(eventLoop: EventLoop, group: EventLoopGroup) throws {
        let serverSocket = try ServerSocket()
        do {
            try serverSocket.setNonBlocking()
        } catch let err {
            let _ = try? serverSocket.close()
            throw err
        }
        self.group = group
        super.init(socket: serverSocket, eventLoop: eventLoop)
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

    override func bind0(local: SocketAddress, promise: Promise<Void>) {
        assert(eventLoop.inEventLoop)
        do {
            try socket.bind(local: local)
            try (self.socket as! ServerSocket).listen(backlog: backlog)
            promise.succeed(result: ())
            pipeline.fireChannelActive0()
        } catch let err {
            promise.fail(error: err)
        }
    }
    
    override fileprivate func connectSocket(remote: SocketAddress) throws -> Bool {
        throw ChannelError.operationUnsupported
    }
    
    override fileprivate func finishConnectSocket() throws {
        throw ChannelError.operationUnsupported
    }
    
    override fileprivate func readFromSocket() throws -> Any? {
        if let accepted =  try (self.socket as! ServerSocket).accept() {
            do {
                return try SocketChannel(socket: accepted, eventLoop: group.next())
            } catch let err {
                let _ = try? accepted.close()
                throw err
            }
        }
        return nil
    }
    
    override fileprivate func writeToSocket(pendingWrites: PendingWrites) throws -> Bool? {
        pendingWrites.failAll(error: ChannelError.operationUnsupported)
        return true
    }
    
    override func channelRead(data: Any) {
        assert(eventLoop.inEventLoop)

        if let ch = data as? Channel {
            let f = ch.register()
            f.whenFailure(callback: { err in
                _ = ch.close()
            })
            f.whenSuccess { () -> Void in
                ch.pipeline.fireChannelActive0()
            }
        }
    }
}

/*
 All operations on Channel are thread-safe
*/
public class Channel : ChannelOutboundInvoker {

    public let eventLoop: EventLoop

    // Visible to access from EventLoop directly
    let socket: BaseSocket
    var interestedEvent: InterestedEvent = .none
    var closed = false

    private let pendingWrites: PendingWrites = PendingWrites()
    private var readPending = false
    private var neverRegistered = true
    private var pendingConnect: Promise<Void>?
    private let closePromise: Promise<Void>
    
    public var closeFuture: Future<Void> {
        return closePromise.futureResult
    }
    
    public var open: Bool {
        return !closeFuture.fulfilled
    }
    
    public var allocator: ByteBufferAllocator {
        if eventLoop.inEventLoop {
            return bufferAllocator
        } else {
            return try! eventLoop.submit{ self.bufferAllocator }.wait()
        }
    }

    private var bufferAllocator: ByteBufferAllocator = ByteBufferAllocator()
    fileprivate var recvAllocator: RecvByteBufferAllocator = FixedSizeRecvByteBufferAllocator(capacity: 8192)
    fileprivate var autoRead: Bool = true
    fileprivate var maxMessagesPerRead: UInt = 1

    public lazy var pipeline: ChannelPipeline = ChannelPipeline(channel: self)

    public func setOption<T: ChannelOption>(option: T, value: T.OptionType) throws {
        if eventLoop.inEventLoop {
            try setOption0(option: option, value: value)
        } else {
            let _ = try eventLoop.submit{
                try self.setOption0(option: option, value: value)
            }.wait()
        }
    }
    
    fileprivate func setOption0<T: ChannelOption>(option: T, value: T.OptionType) throws {
        assert(eventLoop.inEventLoop)

        if option is SocketOption {
            let (level, name) = option.value as! (Int, Int32)
            try socket.setOption(level: Int32(level), name: name, value: value)
        } else if option is AllocatorOption {
            bufferAllocator = value as! ByteBufferAllocator
        } else if option is RecvAllocatorOption {
            recvAllocator = value as! RecvByteBufferAllocator
        } else if option is AutoReadOption {
            let auto = value as! Bool
            autoRead = auto
            if auto {
                startReading0()
            } else {
                stopReading0()
            }
        } else if option is MaxMessagesPerReadOption {
            maxMessagesPerRead = value as! UInt
        } else {
            fatalError("option \(option) not supported")
        }
    }

    public func getOption<T: ChannelOption>(option: T) throws -> T.OptionType {
        if eventLoop.inEventLoop {
            return try getOption0(option: option)
        } else {
            return try eventLoop.submit{ try self.getOption0(option: option) }.wait()
        }
    }
    
    fileprivate func getOption0<T: ChannelOption>(option: T) throws -> T.OptionType {
        assert(eventLoop.inEventLoop)
        
        if option is SocketOption {
            let (level, name) = option.value as! (Int32, Int32)
            return try socket.getOption(level: level, name: name)
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
        fatalError("option \(option) not supported")
    }
    
    public var localAddress: SocketAddress? {
        get {
            return socket.localAddress
        }
    }

    public var remoteAddress: SocketAddress? {
        get {
            return socket.remoteAddress
        }
    }

    func readIfNeeded() {
        if autoRead {
            pipeline.read0()
        }
    }

    @discardableResult public func bind(local: SocketAddress, promise: Promise<Void>) -> Future<Void> {
        return pipeline.bind(local: local, promise: promise)
    }
    
    @discardableResult public func connect(remote: SocketAddress, promise: Promise<Void>) -> Future<Void> {
        return pipeline.connect(remote: remote, promise: promise)
    }
    
    @discardableResult public func write(data: Any, promise: Promise<Void>) -> Future<Void> {
        return pipeline.write(data: data, promise: promise)
    }
    
    public func flush() {
        pipeline.flush()
    }
    
    public func read() {
        pipeline.read()
    }
    
    @discardableResult public func writeAndFlush(data: Any, promise: Promise<Void>) -> Future<Void> {
        return pipeline.writeAndFlush(data: data, promise: promise)
    }
    
    @discardableResult public func close(promise: Promise<Void>) -> Future<Void> {
        return pipeline.close(promise: promise)
    }
    
    // Methods invoked from the HeadHandler of the ChannelPipeline
    func bind0(local: SocketAddress, promise: Promise<Void> ) {
        assert(eventLoop.inEventLoop)

        do {
            try socket.bind(local: local)
            promise.succeed(result: ())
        } catch let err {
            promise.fail(error: err)
        }
    }

    func write0(data: Any, promise: Promise<Void>) {
        assert(eventLoop.inEventLoop)

        guard !closed else {
            // Channel was already closed, fail the promise and not even queue it.
            promise.fail(error: ChannelError.closed)
            return
        }
        if let buffer = data as? ByteBuffer {
            pendingWrites.add(buffer: buffer, promise: promise)
        } else {
            // Only support ByteBuffer for now. 
            promise.fail(error: ChannelError.messageUnsupported)
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

    func flush0() {
        assert(eventLoop.inEventLoop)

        guard !isWritePending() else {
            return
        }
        
        // This flush is triggered by the user and so we should mark all pending messages as flushed
        if !flushNow(markFlushCheckpoint: true) {
            guard !closed else {
                return
            }

            registerForWritable()
            pipeline.fireChannelWritabilityChanged0(writable: false)
        }
    }
    
    func startReading0() {
        assert(eventLoop.inEventLoop)

        guard !closed else {
            return
        }
        readPending = true
        
        registerForReadable()
    }

    func stopReading0() {
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
    
    func close0(promise: Promise<Void> = Promise<Void>(), error: Error = ChannelError.closed) {
        assert(eventLoop.inEventLoop)

        guard !closed else {
            // Already closed
            promise.succeed(result: ())
            return
        }
        closed = true
        
        safeDeregister()

        do {
            try socket.close()
            promise.succeed(result: ())
        } catch let err {
            promise.fail(error: err)
        }
        if !neverRegistered {
            pipeline.fireChannelUnregistered0()
        }
        pipeline.fireChannelInactive0()
        
        
        // Fail all pending writes and so ensure all pending promises are notified
        pendingWrites.failAll(error: error)
        
        if let connectPromise = pendingConnect {
            pendingConnect = nil
            connectPromise.fail(error: error)
        }
        closePromise.succeed(result: ())
    }
    

    func register0(promise: Promise<Void>) {
        assert(eventLoop.inEventLoop)

        // Was not registered yet so do it now.
        if safeRegister(interested: .read) {
            neverRegistered = false
            promise.succeed(result: ())
            pipeline.fireChannelRegistered0()
        } else {
            promise.succeed(result: ())
        }
    }
    
    public func register(promise: Promise<Void>) -> Future<Void> {
        return pipeline.register(promise: promise)
    }
    

    // Methods invoked from the EventLoop itself
    func writable() {
        assert(eventLoop.inEventLoop)
        assert(!closed)

        if finishConnect() {
            finishWritable()
            return
        }
        
        // This flush is triggered by the EventLoop which means it should only try to write the messages that were marked as flushed before
        if flushNow(markFlushCheckpoint: false) {
            // Everything was written, reregister again with InterestedEvent.Read so we are notified once there is more data on the socketto read.
            pipeline.fireChannelWritabilityChanged0(writable: true)
            
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
            // No read pending so just deregister from the EventLoop for now.
            safeDeregister()
        }
    }
    
    func readable() {
        assert(eventLoop.inEventLoop)
        assert(!closed)
        
        readPending = false
        defer {
            if !closed, !readPending {
                unregisterForReadable()
            }
        }
        
        for _ in 1...maxMessagesPerRead {
            do {
                if let read = try readFromSocket() {
                    pipeline.fireChannelRead0(data: read)
                } else {
                    break
                }
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
                    
                close0(error: err)
                    
                return
                
            }
        }
        pipeline.fireChannelReadComplete0()
    }
    
    fileprivate func connectSocket(remote: SocketAddress) throws -> Bool {
        fatalError("this must be overridden by sub class")
    }
    
    fileprivate func finishConnectSocket() throws {
        fatalError("this must be overridden by sub class")
    }
    
    func connect0(remote: SocketAddress, promise: Promise<Void>) {
        assert(eventLoop.inEventLoop)

        guard pendingConnect == nil else {
            promise.fail(error: ChannelError.connectPending)
            return
        }
        do {
            if try !connectSocket(remote: remote) {
                registerForWritable()
            }
        } catch let error {
            promise.fail(error: error)
        }
    }
    
    fileprivate func readFromSocket() throws -> Any? {
        fatalError("this must be overridden by sub class")
    }

    
    fileprivate func writeToSocket(pendingWrites: PendingWrites) throws -> Bool? {
        fatalError("this must be overridden by sub class")
    }
    
    func channelRead(data: Any) {
        // Do nothing by default
    }

    private func isWritePending() -> Bool {
        return interestedEvent == .write || interestedEvent == .all
    }
    
    // Methods only used from within this class
    private func safeDeregister() {
        interestedEvent = .none
        do {
            try eventLoop.deregister(channel: self)
        } catch let err {
            pipeline.fireErrorCaught0(error: err)
            close0(error: err)
        }
    }
    
    private func safeReregister(interested: InterestedEvent) {
        guard !closed else {
            interestedEvent = .none
            return
        }
        interestedEvent = interested
        do {
            try eventLoop.reregister(channel: self)
        } catch let err {
            pipeline.fireErrorCaught0(error: err)
            close0(error: err)
        }

    }
    
    private func safeRegister(interested: InterestedEvent) -> Bool {
        guard !closed else {
            interestedEvent = .none
            return false
        }
        interestedEvent = interested
        do {
            try eventLoop.register(channel: self)
            return true
        } catch let err {
            pipeline.fireErrorCaught0(error: err)
            close0(error: err)
            return false
        }
    }

    private func flushNow(markFlushCheckpoint: Bool) -> Bool {
        if markFlushCheckpoint {
            pendingWrites.markFlushCheckpoint()
        }
        while !closed {
            do {
                if let written = try writeToSocket(pendingWrites: pendingWrites) {
                    if !written {
                        // Could not write the next buffer(s) completely
                        return false
                    }
                    // Consume the next buffer(s).
                } else {
                    
                    // we handled all pending writes
                    return true
                }
                
            } catch let err {
                close0(error: err)
                
                // we handled all writes
                return true
            }
        }
        return true
    }
    
    fileprivate init(socket: BaseSocket, eventLoop: EventLoop) {
        self.socket = socket
        self.eventLoop = eventLoop
        self.closePromise = eventLoop.newPromise(type: Void.self)
    }
    
    deinit {
        // We should never have any pending writes left as otherwise we may leak callbacks
        assert(pendingWrites.isEmpty)
    }
}

public protocol RecvByteBufferAllocator {
    func buffer(allocator: ByteBufferAllocator) throws -> ByteBuffer
}

public class FixedSizeRecvByteBufferAllocator : RecvByteBufferAllocator {
    let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public func buffer(allocator: ByteBufferAllocator) throws -> ByteBuffer {
        return try allocator.buffer(capacity: capacity)
    }
}

public enum ChannelError: Error {
    case connectPending
    case messageUnsupported
    case operationUnsupported
    case closed
    case eof
}
