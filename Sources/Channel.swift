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

#if os(Linux)
import Glibc
#else
import Darwin
#endif

public class Channel : ChannelOutboundInvoker {
    public let pipeline: ChannelPipeline = ChannelPipeline()
    
    // TODO: Make configurable
    public let allocator: BufferAllocator = DefaultBufferAllocator()
    private let recvAllocator: RecvBufferAllocator = FixedSizeBufferAllocator(capacity: 8192)
    
    private let selector: Selector
    private let socket: Socket
    // TODO: This is most likely not the best datastructure for us. Linked-List would be better.
    private var pendingWrites: [(Buffer, Promise<Void>)] = Array()
    private var outstanding: UInt64 = 0
    private var closed: Bool = false
    private var readPending: Bool = false;
    private var interestedEvent: InterestedEvent? = InterestedEvent.Read
    
    init(socket: Socket, selector: Selector) {
        self.socket = socket
        self.selector = selector
    }    

    public func write(data: Buffer, promise: Promise<Void>) -> Future<Void> {
        return pipeline.write(data: data, promise: promise)
    }
    
    public func flush() {
        pipeline.flush()
    }
    
    public func read() {
        pipeline.read()
    }
    
    public func writeAndFlush(data: Buffer, promise: Promise<Void>) -> Future<Void> {
        return pipeline.writeAndFlush(data: data, promise: promise)
    }
    
    public func close(promise: Promise<Void>) -> Future<Void> {
        return pipeline.close(promise: promise)
    }
    
    func attach(initPipeline: (ChannelPipeline) ->()) throws {
        // Attach Channel to previous created pipeline and init it.
        pipeline.attach(channel: self)
        initPipeline(pipeline)
        
        // Start to read data
        try selector.register(selectable: socket, interested: interestedEvent!, attachment: self)

        pipeline.fireChannelActive()
    }
    
    func write0(data: Buffer, promise: Promise<Void>) {
        if closed {
            // Channel was already closed to fail the promise and not even queue it.
            promise.fail(error: IOError(errno: EBADF, reason: "Channel closed"))
            return
        }
        pendingWrites.append((data, promise))
        outstanding += UInt64((data.limit - data.offset))
        
        // TODO: Configurable or remove completely ?
        if outstanding >= 64 * 1024 {
            // Too many outstanding bytes, try flush these now.
            flush0()
        }
    }
    
    func flush0() {
        if interestedEvent != InterestedEvent.Write && interestedEvent != InterestedEvent.All && !flushNow() {
            // Could not flush all of the queued bytes, stop reading until we were able to do so
            if interestedEvent == InterestedEvent.Read {
                safeReregister(interested: InterestedEvent.Write)
            } else {
                safeReregister(interested: InterestedEvent.All)
            }
            pipeline.fireChannelWritabilityChanged(writable: false)
        }
    }
    
    func read0() {
        readPending = true
        if interestedEvent == nil {
            interestedEvent = InterestedEvent.Read
            
            do {
                try selector.register(selectable: socket, interested: interestedEvent!)
            } catch {
                // TODO: Log ?
                close0()
            }
        } else if interestedEvent != InterestedEvent.Read {
            if interestedEvent == InterestedEvent.Write {
                safeReregister(interested: InterestedEvent.All)
            } else {
                safeReregister(interested: InterestedEvent.Read)
            }
        }
    }

    func invokeFlush() {
        if flushNow() {
            // Everything was written, reregister again with InterestedEvent.Read so we are notified once there is more data on the socketto read.
            pipeline.fireChannelWritabilityChanged(writable: true)
            
            if readPending {
                // Start reading again
                safeReregister(interested: InterestedEvent.Read)
            } else {
                safeDeregister()
            }
        }
    }
    
    private func flushNow() -> Bool {
        do {
            while !closed, let pending = pendingWrites.first {
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
        return true
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
    
    func invokeRead() {
        readPending = false

        let buffer = recvAllocator.buffer(allocator: allocator)
        
        defer {
            // Always call the method as last
            pipeline.fireChannelReadComplete()
            
            if !readPending {
                if interestedEvent == InterestedEvent.Read {
                    safeDeregister()
                }
            }
        }
        
        do {
            // TODO: Read spin ?
            if let read = try socket.read(data: &buffer.data) {
                buffer.limit = Int(read)
                pipeline.fireChannelRead(data: buffer)
            }
        } catch let err {
            pipeline.fireErrorCaught(error: err)
            
            failPendingWritesAndClose(err: err)
        }
    }
    
    func close0(promise: Promise<Void> = Promise<Void>()) {
        defer {
            // Ensure this is always called
            pipeline.fireChannelInactive()
            
            // Fail all pending writes and so ensure all pending promises are notified
            failPendingWrites(err: IOError(errno: EBADF, reason: "Channel closed"))
        }
        do {
            closed = true
            try socket.close()
            promise.succeed(result: ())
        } catch let err {
            promise.fail(error: err)
        }
    }
    
    func deregister0() throws {
        interestedEvent = nil
        try selector.deregister(selectable: socket)
    }
    
    func safeDeregister() {
        do {
            try deregister0()
        } catch {
            // TODO: Log ?
            close0()
        }
    }
    
    func safeReregister(interested: InterestedEvent) {
        interestedEvent = interested
        do {
            try selector.reregister(selectable: socket, interested: interested)
        } catch {
            // TODO: Log ?
            close0()
        }
    }
}

protocol RecvBufferAllocator {
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
