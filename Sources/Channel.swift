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


public class Channel {
    let pipeline: ChannelPipeline
    let selector: Selector
    let socket: Socket
    var buffers: [Buffer]
    var outstanding: UInt64
    
    init(socket: Socket, selector: Selector) {
        self.socket = socket
        self.selector = selector
        pipeline = ChannelPipeline()
        buffers = Array()
        outstanding = 0
    }
    
    func attach(initPipeline: (ChannelPipeline) ->()) throws {
        // Attach Channel to previous created pipeline and init it.
        pipeline.attach(channel: self)
        initPipeline(pipeline)
        
        // Start to read data
        try selector.register(selectable: socket, attachment: self)

        pipeline.fireChannelActive()
    }
    
    func write0(data: Buffer) throws {
        buffers.append(data)
        outstanding += UInt64((data.limit - data.offset))
        
        if outstanding >= 64 * 1024 {
            // Too many outstanding bytes, try flush these now.
            try flush0()
        }
    }
    
    func flush0() throws {
        if try !flushNow() {
            // Could not flush all of the queued bytes, stop reading until we were able to do so
            try selector.reregister(selectable: socket, interested: InterestedEvent.Write)
            pipeline.fireChannelWritabilityChanged(writable: false)
        }
    }
    
    func flushNowAndReadAgain() throws {
        if try flushNow() {
            // Everything was written, reregister again with InterestedEvent.Read so we are notified once there is more data on the socketto read.
            pipeline.fireChannelWritabilityChanged(writable: true)
            try selector.reregister(selectable: socket, interested: InterestedEvent.Read)
        }
    }
    
    func flushNow() throws -> Bool {
        while let buffer = buffers.first {
            if let written = try socket.write(data: buffer.data, offset: buffer.offset, len: buffer.limit - buffer.offset) {
                buffer.offset += Int(written)
                
                outstanding -= UInt64(written)
                if buffer.offset == buffer.limit {
                    buffers.removeFirst()
                }
            } else {
                return false
            }
        }
        return true
    }
    
    func read0() throws {
        // TODO: Make this smarter
        let buffer = Buffer(capacity: 8 * 1024)
        
        // TODO: Read spin
        if let read = try socket.read(data: &buffer.data) {
            buffer.limit = Int(read)
            pipeline.fireChannelRead(data: buffer)
            pipeline.fireChannelReadComplete()
        }
    }
    
    func close0() throws {
        defer {
            // Ensure this is always called
            pipeline.fireChannelInactive()
        }
        try socket.close()
    }
    
    func deregister0() throws {
        try selector.deregister(selectable: socket)
    }
}
