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

public class Channel : ChannelOutboundInvoker {
    public private(set) var open: Bool = true

    public let eventLoop: EventLoop

    // Visible to access from EventLoop directly
    internal let socket: Socket
    internal var interestedEvent: InterestedEvent = .None

    // TODO: This is most likely not the best datastructure for us. Linked-List would be better.
    private var pendingWrites: [(ByteBuffer, Promise<Void>)] = Array()
    private var outstanding: UInt64 = 0
    private var readPending: Bool = false

    public private(set) var allocator: ByteBufferAllocator = ByteBufferAllocator()
    private var recvAllocator: RecvByteBufferAllocator = FixedSizeRecvByteBufferAllocator(capacity: 8192)
    private var autoRead: Bool = true
    private var maxMessagesPerRead: UInt = 1

    public lazy var pipeline: ChannelPipeline = ChannelPipeline(channel: self)

    public func setOption<T: ChannelOption>(option: T, value: T.OptionType) throws {
        if option is SocketOption {
            let (level, name) = option.value as! (Int32, Int32)
            try socket.setOption(level: level, name: name, value: value)
        } else if option is AllocatorOption {
            allocator = value as! ByteBufferAllocator
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
        if option is SocketOption {
            let (level, name) = option.value as! (Int32, Int32)
            return try socket.getOption(level: level, name: name)
        }
        if option is AllocatorOption {
            return allocator as! T.OptionType
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

    internal func readIfNeeded() {
        if autoRead {
            read()
        }
    }
    
    public func write(data: Any, promise: Promise<Void>) -> Future<Void> {
        return pipeline.write(data: data, promise: promise)
    }
    
    public func flush() {
        pipeline.flush()
    }
    
    public func read() {
        pipeline.read()
    }
    
    public func writeAndFlush(data: Any, promise: Promise<Void>) -> Future<Void> {
        return pipeline.writeAndFlush(data: data, promise: promise)
    }
    
    public func close(promise: Promise<Void>) -> Future<Void> {
        return pipeline.close(promise: promise)
    }
    
    // Methods invoked from the HeadHandler of the ChannelPipeline
    func write0(data: Any, promise: Promise<Void>) {
        guard open else {
            // Channel was already closed to fail the promise and not even queue it.
            promise.fail(error: IOError(errno: EBADF, reason: "Channel closed"))
            return
        }
        if let buffer = data as? ByteBuffer {
            pendingWrites.append((buffer, promise))
            outstanding += UInt64(buffer.readableBytes)
            
        } else {
            // Only support ByteBuffer for now. 
            promise.fail(error: MessageError.unsupported)
        }
    }

    func flush0() {
        guard !isWritePending() else {
            return
        }
        
        if !flushNow() {
            guard open else {
                return
            }

            switch interestedEvent {
            case .Read:
                safeReregister(interested: .All)
            case .None:
                safeReregister(interested: .Write)
            default:
                break
            }
 
            pipeline.fireChannelWritabilityChanged(writable: false)
        }
    }
    
    func startReading0() {
        guard open else {
            return
        }
        readPending = true
        
        switch interestedEvent {
        case .Write:
            safeReregister(interested: .All)
        case .None:
            safeRegister(interested: .Read)
        default:
            break
        }
    }

    func stopReading0() {
        guard open else {
            return
        }
        switch interestedEvent {
        case .Read:
            safeReregister(interested: .None)
        case .All:
            safeReregister(interested: .Write)
        default:
            break
        }
    }
    
    func close0(promise: Promise<Void> = Promise<Void>()) {
        guard open else {
            // Already closed
            promise.succeed(result: ())
            return
        }
        
        do {
            open = false
            try socket.close()
            promise.succeed(result: ())
        } catch let err {
            promise.fail(error: err)
        }
        safeDeregister()
        pipeline.fireChannelUnregistered()
        pipeline.fireChannelInactive()
        
        
        // Fail all pending writes and so ensure all pending promises are notified
        failPendingWrites(err: IOError(errno: EBADF, reason: "Channel closed"))
    }
    
    func registerOnEventLoop(initPipeline: (ChannelPipeline) throws ->()) {
        // Was not registered yet so do it now.
        safeRegister(interested: .Read)
        
        do {
            try initPipeline(pipeline)
        
            pipeline.fireChannelRegistered()
        } catch let err {
            pipeline.fireErrorCaught(error: err)
            close0()
        }
    }

    // Methods invoked from the EventLoop itself
    func flushFromEventLoop() {
        assert(open)

        if flushNow() {
            // Everything was written, reregister again with InterestedEvent.Read so we are notified once there is more data on the socketto read.
            pipeline.fireChannelWritabilityChanged(writable: true)
            
            guard open else {
                return
            }
            if readPending {
                // Start reading again
                safeReregister(interested: .Read)
            } else {
                // No read pending so just deregister from the EventLoop for now.
                safeDeregister()
            }
        }
    }
    
    func readFromEventLoop() {
        assert(open)
        
        readPending = false
        defer {
            // Always call the method as last
            pipeline.fireChannelReadComplete()
            
            if open, !readPending {
                switch interestedEvent {
                case .Read:
                    safeReregister(interested: .None)
                case .All:
                    safeReregister(interested: .Write)
                default:
                    break
                }
            }
        }
        
        for _ in 1...maxMessagesPerRead {
            do {
                var buffer = try recvAllocator.buffer(allocator: allocator)
                
                if let bytesRead = try buffer.withMutableWritePointer { try self.socket.read(pointer: $0, size: $1) } {
                    if bytesRead > 0 {
                        pipeline.fireChannelRead(data: buffer)
                    } else {
                        // end-of-file
                        close0()
                        return
                    }
                }
            } catch let err {
                pipeline.fireErrorCaught(error: err)
            
                failPendingWritesAndClose(err: err)

                break
            }
        }

    }

    private func isWritePending() -> Bool {
        return interestedEvent == .Write || interestedEvent == .All
    }
    
    // Methods only used from within this class
    private func safeDeregister() {
        interestedEvent = .None
        do {
            try eventLoop.deregister(channel: self)
        } catch let err {
            pipeline.fireErrorCaught(error: err)
            close0()
        }
    }
    
    private func safeReregister(interested: InterestedEvent) {
        guard open else {
            interestedEvent = .None
            return
        }
        interestedEvent = interested
        do {
            try eventLoop.reregister(channel: self)
        } catch let err {
            pipeline.fireErrorCaught(error: err)
            close0()
        }

    }
    
    private func safeRegister(interested: InterestedEvent) {
        guard open else {
            interestedEvent = .None
            return
        }
        interestedEvent = interested
        do {
            try eventLoop.register(channel: self)
        } catch let err {
            pipeline.fireErrorCaught(error: err)
            close0()
        }
    }

    private func flushNow() -> Bool {
        while open, !pendingWrites.isEmpty {
            // We do this because the buffer is a value type and can't be modified in place.
            // If the buffer is still applicable we'll need to add it back into the queue.
            var (buffer, promise) = pendingWrites.removeFirst()
            
            do {
                if let written = try buffer.withMutableReadPointer { try self.socket.write(pointer: $0, size: $1) } {
                    outstanding -= UInt64(written)
                    if buffer.readerIndex == buffer.writerIndex {
                        promise.succeed(result: ())
                    } else {
                        pendingWrites.insert((buffer, promise), at: 0)
                    }
                } else {
                    pendingWrites.insert((buffer, promise), at: 0)
                    return false
                }
            } catch let err {
                // fail the promise that we removed first to ensure we not leak the attached callbacks.
                promise.fail(error: err)
                
                // fail all pending writes so all promises are notified.
                failPendingWritesAndClose(err: err)
                
                // we handled all writes
                return true
            }
        }
        return pendingWrites.isEmpty
    }
    
    private func failPendingWritesAndClose(err: Error) {
        // Fail all pending writes so all promises are notified.
        failPendingWrites(err: err)
        close0()
    }
    
    private func failPendingWrites(err: Error) {
        for pending in pendingWrites {
            pending.1.fail(error: err)
        }
        pendingWrites.removeAll()
        outstanding = 0
    }
    
    init(socket: Socket, eventLoop: EventLoop) {
        self.socket = socket
        self.eventLoop = eventLoop
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
        self.capacity = capacity
    }

    public func buffer(allocator: ByteBufferAllocator) throws -> ByteBuffer {
        return try allocator.buffer(capacity: capacity)
    }
}

enum MessageError: Error {
    case unsupported
}
