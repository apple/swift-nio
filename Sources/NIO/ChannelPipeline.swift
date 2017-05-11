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

// TODO: Add teardown which also removes the handlers.
public class ChannelPipeline : ChannelInboundInvoker, ChannelOutboundInvoker {
    
    private var head: ChannelHandlerContext?
    private var tail: ChannelHandlerContext?
    private var idx: Int = 0
    
    public var channel: Channel {
        get {
            // Kind of hacky but should be ok for now.
            return (head!.handler as! HeadChannelHandler).channel
        }
    }
    
    public var eventLoop: EventLoop {
        get {
            return channel.eventLoop
        }
    }
    
    private func nextName() -> String {
        let name = "handler\(idx)"
        idx += 1
        return name
    }
    
    public func add(name: String? = nil, handler: ChannelHandler, first: Bool = false) throws {
        let ctx = ChannelHandlerContext(name: name ?? nextName(), handler: handler, pipeline: self)
        if first {
            let next = head!.next
            
            ctx.prev = head
            ctx.next = next
            
            next!.prev = ctx
         
        } else {
            let prev = tail!.prev
            ctx.prev = tail!.prev
            ctx.next = tail
            
            prev!.next = ctx
            tail!.prev = ctx
        }
        
        
        do {
            try ctx.invokeHandlerAdded()
        } catch let err {
            ctx.prev!.next = ctx.next
            ctx.next!.prev = ctx.prev
            
            throw err
        }
    }

    public func remove(handler: ChannelHandler) -> Bool {
        guard let ctx = getCtx(equalsFunc: { ctx in
            return ctx.handler === handler
        }) else {
            return false
        }
        ctx.prev!.next = ctx.next
        ctx.next?.prev = ctx.prev
        return true
    }
    
    public func remove(name: String) -> Bool {
        guard let ctx = getCtx(equalsFunc: { ctx in
            return ctx.name == name
        }) else {
            return false
        }
        ctx.prev!.next = ctx.next
        ctx.next?.prev = ctx.prev
        return true
    }
    
    public func contains(handler: ChannelHandler) -> Bool {
        if getCtx(equalsFunc: { ctx in
            return ctx.handler === handler
        }) == nil {
            return false
        }
        
        return true

    }
    
    public func contains(name: String) -> Bool {
        if getCtx(equalsFunc: { ctx in
            return ctx.name == name
        }) == nil {
            return false
        }
        
        return true
    }
    
    // Just traverse the pipeline from the start
    private func getCtx(equalsFunc: (ChannelHandlerContext) -> Bool) -> ChannelHandlerContext? {
        var ctx = head?.next
        while let c = ctx {
            if c === tail {
                break
            }
            if equalsFunc(c) {
                return c
            }
            ctx = c.next
        }
        return nil
    }

    // Just delegate to the head and tail context

    public func fireChannelRegistered() {
        head!.invokeChannelRegistered()
    }
    
    public func fireChannelUnregistered() {
        head!.invokeChannelUnregistered()
    }
    
    public func fireChannelInactive() {
        head!.invokeChannelInactive()
    }
    
    public func fireChannelActive() {
        head!.invokeChannelActive()
    }
    
    public func fireChannelRead(data: AnyObject) {
        head!.invokeChannelRead(data: data)
    }
    
    public func fireChannelReadComplete() {
        head!.invokeChannelReadComplete()
    }
    
    public func fireChannelWritabilityChanged(writable: Bool) {
        head!.invokeChannelWritabilityChanged(writable: writable)
    }
    
    public func fireUserEventTriggered(event: AnyObject) {
        head!.invokeUserEventTriggered(event: event)
    }
    
    public func fireErrorCaught(error: Error) {
        head!.invokeErrorCaught(error: error)
    }

    public func close(promise: Promise<Void>) -> Future<Void> {
        tail!.invokeClose(promise: promise)
        return promise.futureResult
    }
    
    public func flush() {
        tail!.invokeFlush()
    }
    
    public func read() {
        tail!.invokeRead()
    }

    public func write(data: AnyObject, promise: Promise<Void>) -> Future<Void> {
        tail!.invokeWrite(data: data, promise: promise)
        return promise.futureResult
    }
    
    public func writeAndFlush(data: AnyObject, promise: Promise<Void>) -> Future<Void> {
        tail!.invokeWriteAndFlush(data: data, promise: promise)
        return promise.futureResult
    }
    
    // Only executed from Channel
    init (channel: Channel) {
        head = ChannelHandlerContext(name: "head", handler: HeadChannelHandler(channel: channel), pipeline: self)
        tail = ChannelHandlerContext(name: "tail", handler: TailChannelHandler(), pipeline: self)
        head!.next = tail
        tail!.prev = head
    }
}

class HeadChannelHandler : ChannelHandler {
    
    // Access from the ChannelPipeline itself
    let channel: Channel
    
    init(channel: Channel) {
        self.channel = channel
    }
    
    func write(ctx: ChannelHandlerContext, data: AnyObject, promise: Promise<Void>) {
        channel.write0(data: data, promise: promise)
    }
    
    func flush(ctx: ChannelHandlerContext) {
        channel.flush0()
    }
    
    func close(ctx: ChannelHandlerContext, promise: Promise<Void>) {
        channel.close0(promise: promise)
    }
    
    func read(ctx: ChannelHandlerContext) {
        channel.startReading0()
    }
    
    func channelActive(ctx: ChannelHandlerContext) {
        ctx.fireChannelActive()
        
        readIfNeeded()
    }
    
    func channelReadComplete(ctx: ChannelHandlerContext) {
        ctx.fireChannelReadComplete()
        
        readIfNeeded()
    }
    
    private func readIfNeeded() {
        if channel.config.autoRead {
            channel.read()
        }
    }
}

class TailChannelHandler : ChannelHandler {
    
    func channelRegistered(ctx: ChannelHandlerContext) {
        // Discard
    }
    
    func channelUnregistered(ctx: ChannelHandlerContext) throws {
        // Discard
    }
    
    func channelActive(ctx: ChannelHandlerContext) {
        // Discard
    }
    
    func channelInactive(ctx: ChannelHandlerContext) {
        // Discard
    }
    
    func channelReadComplete(ctx: ChannelHandlerContext) {
        // Discard
    }
    
    func channelWritabilityChanged(ctx: ChannelHandlerContext, writable: Bool) {
        // Discard
    }
    
    func userEventTriggered(ctx: ChannelHandlerContext, event: AnyObject) {
        // Discard
    }
    
    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        // TODO: Log this and tell the user that its most likely a fault not handling it.
    }
    
    func channelRead(ctx: ChannelHandlerContext, data: AnyObject) {
        // TODO: Log this and tell the user that its most likely a fault not handling it.
    }
}
