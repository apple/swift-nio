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

// TODO: Add teardown which also removes the handlers.
public class ChannelPipeline : ChannelInboundInvoker, ChannelOutboundInvoker {
    
    var head: ChannelHandlerContext?
    var tail: ChannelHandlerContext?
    
    func attach(channel: Channel) {
        head = ChannelHandlerContext(handler: HeadChannelHandler(channel: channel), pipeline: self)
        tail = ChannelHandlerContext(handler: TailChannelHandler(), pipeline: self)
        head!.next = tail
        tail!.prev = head
    }
    
    public func addLast(handler: ChannelHandler) {
        let ctx = ChannelHandlerContext(handler: handler, pipeline: self)
        let prev = tail!.prev
        ctx.prev = tail!.prev
        ctx.next = tail
        
        prev?.next = ctx
        tail?.prev = ctx
        
        ctx.invokeHandlerAdded()
    }

    public func fireChannelInactive() {
        head!.fireChannelInactive()
    }
    
    public func fireChannelActive() {
        head!.fireChannelActive()
    }
    
    public func fireChannelRead(data: Buffer) {
        head!.fireChannelRead(data: data)
    }
    
    public func fireChannelReadComplete() {
        head!.fireChannelReadComplete()
    }
    
    public func fireChannelWritabilityChanged(writable: Bool) {
        head!.fireChannelWritabilityChanged(writable: writable)
    }
    
    public func close() {
        tail!.close()
    }
    
    public func flush() {
        tail!.flush()
    }
    
    public func write(data: Buffer) {
        tail!.write(data: data)
    }
    
    public func writeAndFlush(data: Buffer) {
        tail!.writeAndFlush(data: data)
    }
}

class HeadChannelHandler : ChannelHandler {
    
    let channel: Channel
    
    init(channel: Channel) {
        self.channel = channel
    }
    
    func write(ctx: ChannelHandlerContext, data: Buffer) {
        do {
            try channel.write0(data: data)
        } catch {
            do {
                try channel.close0()
            } catch {
                // TODO: Fix me
            }
        }
    }
    
    func flush(ctx: ChannelHandlerContext) {
        do {
            try channel.flush0()
        } catch {
            do {
                try channel.close0()
            } catch {
                // TODO: Fix me
            }
        }
    }
}

class TailChannelHandler : ChannelHandler { }
