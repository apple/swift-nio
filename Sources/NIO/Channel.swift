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
    public var allocator: BufferAllocator {
        return config.allocator
    }
    
    public let eventLoop: EventLoop
    
    // Visible to access from EventLoop directly
    internal let socket: Socket
    internal var interestedEvent: InterestedEvent? = nil

    // TODO: This is most likely not the best datastructure for us. Linked-List would be better.
    private var pendingWrites: [(Buffer, Promise<Void>)] = Array()
    private var outstanding: UInt64 = 0
    public private(set) var open: Bool = true
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
        if let buffer = data as? Buffer {
            pendingWrites.append((buffer, promise))
            outstanding += UInt64((buffer.limit - buffer.offset))
            
        } else {
            // Only support Buffer for now. 
            promise.fail(error: MessageError.unsupported)
        }
    }
    
    func flush0() {
        if interestedEvent != InterestedEvent.Write && interestedEvent != InterestedEvent.All && !flushNow() {
            guard open else {
                return
            }
            // Could not flush all of the queued bytes, stop reading until we were able to do so
            if interestedEvent == InterestedEvent.Read {
                safeReregister(interested: InterestedEvent.Write)
            } else {
                safeReregister(interested: InterestedEvent.All)
            }
            pipeline.fireChannelWritabilityChanged(writable: false)
        }
    }
    
    func startReading0() {
        guard open else {
            return
        }
        readPending = true
        
        if let ev = interestedEvent {
            if ev == InterestedEvent.Write {
                // writes are pending
                safeReregister(interested: InterestedEvent.All)
            }
        } else {
            // Not registered on the EventLoop so do it now.
            safeRegister(interested: InterestedEvent.Read)
        }
    }

    func stopReading0() {
        guard open else {
            return
        }
        if let ev = interestedEvent {
            switch ev {
            case InterestedEvent.Read:
                safeDeregister()
            case InterestedEvent.All:
                safeReregister(interested: InterestedEvent.Write)
            default:
                // Nothing to do
                break
            }
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
        safeRegister(interested: InterestedEvent.Read)
        
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
                safeReregister(interested: InterestedEvent.Read)
            } else {
                // No read pending so just deregister from the EventLoop for now.
                safeDeregister()
            }
        }
    }
    
    func readFromEventLoop() {
        assert(open)
        
        readPending = false
        
        let buffer = config.recvAllocator.buffer(allocator: allocator)
        
        defer {
            // Always call the method as last
            pipeline.fireChannelReadComplete()
            
            if open, !readPending, let ev = interestedEvent {
                switch ev {
                case InterestedEvent.Read:
                    safeDeregister()
                case InterestedEvent.All:
                    safeReregister(interested: InterestedEvent.Write)
                default:
                    break
                }
            }
        }
        
        do {
            // TODO: Read spin ?
            if let read = try socket.read(data: &buffer.data) {
                guard read > 0 else {
                    // end-of-file
                    close0()
                    return
                }
                buffer.limit = Int(read)
                pipeline.fireChannelRead(data: buffer)
            } else {
                print("NOT READABLE");
            }
        } catch let err {
            pipeline.fireErrorCaught(error: err)
            
            failPendingWritesAndClose(err: err)
        }
    }
    
    // Methods only used from within this class
    private func safeDeregister() {
        interestedEvent = nil
        do {
            try eventLoop.deregister(channel: self)
        } catch {
            // TODO: Log ?
            close0()
        }
    }
    
    private func safeReregister(interested: InterestedEvent) {
        guard open else {
            safeDeregister()
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
            safeDeregister()
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
            while open, let pending = pendingWrites.first {
                if let written = try socket.write(data: pending.0.data, offset: pending.0.offset, len: pending.0.limit - pending.0.offset) {
                    pending.0.offset += Int(written)
                    
                    outstanding -= UInt64(written)
                    if pending.0.offset == pending.0.limit {
                        pendingWrites.removeFirst()
                        pending.1.succeed(result: ())
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
    func buffer(allocator: BufferAllocator) -> Buffer
}

public class FixedSizeBufferAllocator : RecvBufferAllocator {
    private let capacity: Int32
    
    init(capacity: Int32) {
        self.capacity = capacity
    }
    
    public func buffer(allocator: BufferAllocator) -> Buffer {
        return allocator.buffer(capacity: capacity)
    }
}

enum MessageError: Error {
    case unsupported
}

public class ChannelConfig {
    // Declare as weak to remove reference-cycle.
    private weak var channel: Channel?
    private var _autoRead: Bool = true
    public var allocator: BufferAllocator = DefaultBufferAllocator()
    public var recvAllocator: RecvBufferAllocator = FixedSizeBufferAllocator(capacity: 8192)

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
