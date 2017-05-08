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

public class Channel : ChannelOutboundInvoker {
    public let pipeline: ChannelPipeline
    public let allocator: BufferAllocator
    private let recvAllocator: RecvBufferAllocator;
    
    private let selector: Selector
    private let socket: Socket
    private var pendingWrites: [(Buffer, Promise<Void>)]
    private var outstanding: UInt64
    private var flushPending: Bool
    
    init(socket: Socket, selector: Selector) {
        self.socket = socket
        self.selector = selector
        pipeline = ChannelPipeline()
        // TODO: This is most likely not the best datastructure for us. Doubly-Linked-List would be better.
        pendingWrites = Array()
        outstanding = 0
        flushPending = false
        allocator = DefaultBufferAllocator()
        
        // TODO: Make configurable
        recvAllocator = FixedSizeBufferAllocator(capacity: 8192)
    }
    

    public func write(data: Buffer, promise: Promise<Void>) -> Future<Void> {
        return pipeline.write(data: data, promise: promise)
    }
    
    public func flush() {
        pipeline.flush()
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
        try selector.register(selectable: socket, attachment: self)

        pipeline.fireChannelActive()
    }
    
    func write0(data: Buffer, promise: Promise<Void>) {
        pendingWrites.append((data, promise))
        outstanding += UInt64((data.limit - data.offset))
        
        // TODO: Configurable or remove completely ?
        if outstanding >= 64 * 1024 {
            // Too many outstanding bytes, try flush these now.
            flush0()
        }
    }
    
    func flush0() {
        if !flushPending && !flushNow() {
            // Could not flush all of the queued bytes, stop reading until we were able to do so
            do {
                try selector.reregister(selectable: socket, interested: InterestedEvent.Write)
            
                flushPending = true
                pipeline.fireChannelWritabilityChanged(writable: false)
            } catch {
                // TODO: Log ?
                close0()
            }
        }
    }
    
    func flushNowAndReadAgain() {
        if flushNow() {
            // Everything was written, reregister again with InterestedEvent.Read so we are notified once there is more data on the socketto read.
            pipeline.fireChannelWritabilityChanged(writable: true)
            flushPending = false

            do {
                try selector.reregister(selectable: socket, interested: InterestedEvent.Read)
            } catch {
                // TODO: Log ?
                close0()
            }
        }
    }
    
    private func flushNow() -> Bool {
        do {
            while let pending = pendingWrites.first {
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
            while let pending = pendingWrites.first {
                pending.1.fail(error: err)
                pendingWrites.removeFirst()
            }
            
            if err is IOError {
                close0()
            }
        }
        return true
    }
    
    func read0() {
        let buffer = recvAllocator.buffer(allocator: allocator)
        
        defer {
            // Always call the method as last
            pipeline.fireChannelReadComplete()
        }
        
        do {
            // TODO: Read spin ?
            if let read = try socket.read(data: &buffer.data) {
                buffer.limit = Int(read)
                pipeline.fireChannelRead(data: buffer)
            }
        } catch let err {
            pipeline.fireErrorCaught(error: err)
            if err is IOError {
                close0()
            }
        }
    }
    
    func close0(promise: Promise<Void> = Promise<Void>()) {
        defer {
            // Ensure this is always called
            pipeline.fireChannelInactive()
        }
        do {
            try socket.close()
            promise.succeed(result: ())
        } catch let err {
            promise.fail(error: err)
        }
    }
    
    func deregister0() throws {
        try selector.deregister(selectable: socket)
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
