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
    public var pipeline: ChannelPipeline {
        return _pipeline
    }
    public var config: ChannelConfig {
        return _config
    }
    public var allocator: ByteBufferAllocator {
        return config.allocator
    }
    public private(set) var open: Bool = true

    public let eventLoop: EventLoop

    // Visible to access from EventLoop directly
    internal let socket: Socket
    internal var interestedEvent: InterestedEvent = .None

    // TODO: This is most likely not the best datastructure for us. Linked-List would be better.
    private var pendingWrites: [(ByteBuffer, Promise<Void>)] = Array()
    private var outstanding: UInt64 = 0
    private var readPending: Bool = false;
    // Needed to be able to use ChannelPipeline(self...)
    private var _pipeline: ChannelPipeline!
    private var _config: ChannelConfig!
    
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
        if interestedEvent != .Write && interestedEvent != .All && !flushNow() {
            guard open else {
                return
            }
            // Could not flush all of the queued bytes, stop reading until we were able to do so
            if interestedEvent == .Read {
                safeReregister(interested: .Write)
            } else {
                safeReregister(interested: .All)
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
            // writes are pending
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
        
        do {

            var buffer = try config.recvAllocator.buffer(allocator: allocator)

            let bytesRead = try buffer.withMutableWritePointer { try self.socket.read(pointer: $0, size: $1) ?? 0 }

            if bytesRead > 0 {
                pipeline.fireChannelRead(data: buffer)
            } else {
                // end-of-file
                close0()
                return
            }
        } catch let err {
            pipeline.fireErrorCaught(error: err)
            
            failPendingWritesAndClose(err: err)
        }
    }
    
    // Methods only used from within this class
    private func safeDeregister() {
        interestedEvent = .None
        do {
            try eventLoop.deregister(channel: self)
        } catch {
            // TODO: Log ?
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
        } catch {
            // TODO: Log ?
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
        } catch {
            // TODO: Log ?
            close0()
        }
    }

    private func flushNow() -> Bool {
        do {
            while open, let _ = pendingWrites.first {
                // We do this because the buffer is a value type and can't be modified in place.
                // If the buffer is still applicable we'll need to add it back into the queue.
                var (buffer, promise) = pendingWrites.removeFirst()

                let written = try buffer.withMutableReadPointer { try self.socket.write(pointer: $0, size: $1) ?? 0 }

                if written > 0 {
                    outstanding -= UInt64(written)
                    if buffer.readerIndex == buffer.writerIndex {
                        promise.succeed(result: ())
                    } else {
                        pendingWrites.insert((buffer, promise), at: 0)
                    }
                } else {
                    return false
                }
            }
        } catch let err {
            // Fail all pending writes so all promises are notified.
            failPendingWritesAndClose(err: err)
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
        self._config = ChannelConfig(channel: self)
        self._pipeline = ChannelPipeline(channel: self)
    }
}

public protocol RecvBufferAllocator {
    func buffer(allocator: ByteBufferAllocator) throws -> ByteBuffer
}

public class FixedSizeByteBufferAllocator : RecvBufferAllocator {
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    public func buffer(allocator: ByteBufferAllocator) throws -> ByteBuffer {
        return try allocator.buffer(capacity: capacity)
    }
}

enum MessageError: Error {
    case unsupported
}

public class ChannelConfig {
    // Declare as weak to remove reference-cycle.
    private weak var channel: Channel?
    private var _autoRead: Bool = true
    public var allocator: ByteBufferAllocator = ByteBufferAllocator()
    public var recvAllocator: RecvBufferAllocator = FixedSizeByteBufferAllocator(capacity: 8192)

    public var autoRead: Bool {
        get {
            return _autoRead
        }
        set (value) {
            _autoRead = value
            if value {
                channel?.startReading0()
            } else {
                channel?.stopReading0()
            }
        }
    }

    init(channel: Channel) {
        self.channel = channel
    }
}
