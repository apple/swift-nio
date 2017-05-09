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
    
    func attach(channel: Channel) {
        // Chain up the double-linked-list
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
        
        prev!.next = ctx
        tail!.prev = ctx
        do {
            try ctx.invokeHandlerAdded()
        } catch {
            ctx.prev!.next = ctx.next
            ctx.next!.prev = ctx.prev
            
            // TODO: Log ?
        }
    }
    
    public func addFirst(handler: ChannelHandler) {
        let ctx = ChannelHandlerContext(handler: handler, pipeline: self)
        let next = head!.next
        
        ctx.prev = head
        ctx.next = next
        
        next!.prev = ctx
        
        do {
            try ctx.invokeHandlerAdded()
        } catch {
            ctx.prev!.next = ctx.next
            ctx.next!.prev = ctx.prev
            
            // TODO: Log ?
        }
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
    
    public func fireChannelRead(data: Buffer) {
        head!.invokeChannelRead(data: data)
    }
    
    public func fireChannelReadComplete() {
        head!.invokeChannelReadComplete()
    }
    
    public func fireChannelWritabilityChanged(writable: Bool) {
        head!.invokeChannelWritabilityChanged(writable: writable)
    }
    
    public func fireUserEventTriggered(event: AnyClass) {
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

    public func write(data: Buffer, promise: Promise<Void>) -> Future<Void> {
        tail!.invokeWrite(data: data, promise: promise)
        return promise.futureResult
    }
    
    public func writeAndFlush(data: Buffer, promise: Promise<Void>) -> Future<Void> {
        tail!.invokeWriteAndFlush(data: data, promise: promise)
        return promise.futureResult
    }
    
    
    public func write(data: Buffer) -> Future<Void> {
        return write(data: data, promise: eventLoop.newPromise(type: Void.self))
    }
    
    public func writeAndFlush(data: Buffer) -> Future<Void> {
        return writeAndFlush(data: data, promise: eventLoop.newPromise(type: Void.self))
    }
    
    public func close() -> Future<Void> {
        return close(promise: eventLoop.newPromise(type: Void.self))
    }
}

class HeadChannelHandler : ChannelHandler {
    
    let channel: Channel
    
    init(channel: Channel) {
        self.channel = channel
    }
    
    func write(ctx: ChannelHandlerContext, data: Buffer, promise: Promise<Void>) {
        channel.write0(data: data, promise: promise)
    }
    
    func flush(ctx: ChannelHandlerContext) {
        channel.flush0()
    }
    
    func close(ctx: ChannelHandlerContext, promise: Promise<Void>) {
        channel.close0(promise: promise)
    }
    
    func read(ctx: ChannelHandlerContext) {
        channel.read0()
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
        // TODO: Introduce auto-read and non-autoread mode and call channel.read() based on it.
        channel.read()
    }
}

class TailChannelHandler : ChannelHandler {
    
    public func channelRegistered(ctx: ChannelHandlerContext) {
        // Discard
    }
    
    public func channelUnregistered(ctx: ChannelHandlerContext) throws {
        // Discard
    }
    
    public func channelActive(ctx: ChannelHandlerContext) {
        // Discard
    }
    
    public func channelInactive(ctx: ChannelHandlerContext) {
        // Discard
    }
    
    public func channelReadComplete(ctx: ChannelHandlerContext) {
        // Discard
    }
    
    public func channelWritabilityChanged(ctx: ChannelHandlerContext, writable: Bool) {
        // Discard
    }
    
    public func userEventTriggered(ctx: ChannelHandlerContext, event: AnyClass) {
        // Discard
    }
    
    public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        // TODO: Log this and tell the user that its most likely a fault not handling it.
    }
    
    public func channelRead(ctx: ChannelHandlerContext, data: Buffer) {
        // TODO: Log this and tell the user that its most likely a fault not handling it.
    }
}
