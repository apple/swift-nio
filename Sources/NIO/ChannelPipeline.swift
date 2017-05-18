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

public class ChannelPipeline : ChannelInboundInvoker {
    
    private var head: ChannelHandlerContext?
    private var tail: ChannelHandlerContext?
    private var idx: Int = 0
    fileprivate let eventLoop: EventLoop

    public unowned let channel: Channel

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

    private func nextName() -> String {
        let name = "handler\(idx)"
        idx += 1
        return name
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

    func removeHandlers() {
        // The channel was unregistered which means it will not handle any more events.
        // Remove all handlers now.
        var ctx = head?.next
        while let c = ctx {
            if c === tail {
                break
            }
            let next = c.next
            head?.next = next
            next?.prev = head
            
            do {
                try c.invokeHandlerRemoved()
            } catch let err {
                next?.invokeErrorCaught(error: err)
            }
            ctx = c.next
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
    
    public func fireChannelRead(data: Any) {
        head!.invokeChannelRead(data: data)
    }
    
    public func fireChannelReadComplete() {
        head!.invokeChannelReadComplete()
    }
    
    public func fireChannelWritabilityChanged(writable: Bool) {
        head!.invokeChannelWritabilityChanged(writable: writable)
    }
    
    public func fireUserEventTriggered(event: Any) {
        head!.invokeUserEventTriggered(event: event)
    }
    
    public func fireErrorCaught(error: Error) {
        head!.invokeErrorCaught(error: error)
    }
    
    internal func close(promise: Promise<Void>) -> Future<Void> {
        tail!.invokeClose(promise: promise)
        return promise.futureResult
    }
    
    internal func flush() {
        tail!.invokeFlush()
    }
    
    internal func read() {
        tail!.invokeRead()
    }

    internal func write(data: Any, promise: Promise<Void>) -> Future<Void> {
        tail!.invokeWrite(data: data, promise: promise)
        return promise.futureResult
    }
    
    internal func writeAndFlush(data: Any, promise: Promise<Void>) -> Future<Void> {
        tail!.invokeWriteAndFlush(data: data, promise: promise)
        return promise.futureResult
    }
    
    // Only executed from Channel
    init (channel: Channel) {
        self.channel = channel
        self.eventLoop = channel.eventLoop
        
        head = ChannelHandlerContext(name: "head", handler: HeadChannelHandler.sharedInstance, pipeline: self)
        tail = ChannelHandlerContext(name: "tail", handler: TailChannelHandler.sharedInstance, pipeline: self)
        head!.next = tail
        tail!.prev = head
    }
}

private class HeadChannelHandler : ChannelHandler {

    static let sharedInstance = HeadChannelHandler()

    private init() { }

    func write(ctx: ChannelHandlerContext, data: Any, promise: Promise<Void>) {
        ctx.channel!.write0(data: data, promise: promise)
    }
    
    func flush(ctx: ChannelHandlerContext) {
        ctx.channel!.flush0()
    }
    
    func close(ctx: ChannelHandlerContext, promise: Promise<Void>) {
        ctx.channel!.close0(promise: promise)
    }
    
    func read(ctx: ChannelHandlerContext) {
        ctx.channel!.startReading0()
    }
    
    func channelActive(ctx: ChannelHandlerContext) {
        ctx.fireChannelActive()
        
        readIfNeeded(ctx: ctx)
    }
    
    func channelReadComplete(ctx: ChannelHandlerContext) {
        ctx.fireChannelReadComplete()
        
        readIfNeeded(ctx: ctx)
    }
    
    func channelUnregistered(ctx: ChannelHandlerContext) {
        ctx.fireChannelUnregistered()
        
        ctx.pipeline!.removeHandlers()
    }

    private func readIfNeeded(ctx: ChannelHandlerContext) {
        ctx.channel!.readIfNeeded()
    }
}

private class TailChannelHandler : ChannelHandler {
    
    static let sharedInstance = TailChannelHandler()
    
    private init() { }

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
    
    func userEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        // Discard
    }
    
    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        // TODO: Log this and tell the user that its most likely a fault not handling it.
    }
    
    func channelRead(ctx: ChannelHandlerContext, data: Any) {
        // TODO: Log this and tell the user that its most likely a fault not handling it.
    }
}

public enum ChannelPipelineException : Error {
    case alreadyRemoved
}


public class ChannelHandlerContext : ChannelInboundInvoker, ChannelOutboundInvoker {
    
    // visible for ChannelPipeline to modify and also marked as weak to ensure we not create a
    // reference-cycle for the doubly-linked-list
    fileprivate weak var prev: ChannelHandlerContext?
    
    fileprivate var next: ChannelHandlerContext?
    
    // marked as weak to not create a reference cycle between this instance and the pipeline
    public private(set) weak var pipeline: ChannelPipeline?
    
    public var channel: Channel? {
        return pipeline?.channel
    }
    
    public let handler: ChannelHandler
    public let name: String
    public let eventLoop: EventLoop
    
    // Only created from within ChannelPipeline
    init(name: String, handler: ChannelHandler, pipeline: ChannelPipeline) {
        self.name = name
        self.handler = handler
        self.pipeline = pipeline
        self.eventLoop = pipeline.eventLoop
    }
    
    public func fireChannelRegistered() {
        if let ctx = next {
            ctx.invokeChannelRegistered()
        } else {
            safeErrorCaught(ctx: self, error: ChannelPipelineException.alreadyRemoved)
        }
    }
    
    public func fireChannelUnregistered() {
        if let ctx = next {
            ctx.invokeChannelUnregistered()
        } else {
            safeErrorCaught(ctx: self, error: ChannelPipelineException.alreadyRemoved)
        }
    }
    
    public func fireChannelActive() {
        if let ctx = next {
            ctx.invokeChannelActive()
        } else {
            safeErrorCaught(ctx: self, error: ChannelPipelineException.alreadyRemoved)
        }
    }
    
    public func fireChannelInactive() {
        if let ctx = next {
            ctx.invokeChannelInactive()
        } else {
            safeErrorCaught(ctx: self, error: ChannelPipelineException.alreadyRemoved)
        }
    }
    
    public func fireChannelRead(data: Any) {
        if let ctx = next {
            ctx.invokeChannelRead(data: data)
        } else {
            safeErrorCaught(ctx: self, error: ChannelPipelineException.alreadyRemoved)
        }
    }
    
    public func fireChannelReadComplete() {
        if let ctx = next {
            ctx.invokeChannelReadComplete()
        } else {
            safeErrorCaught(ctx: self, error: ChannelPipelineException.alreadyRemoved)
        }
    }
    
    public func fireChannelWritabilityChanged(writable: Bool) {
        if let ctx = next {
            ctx.invokeChannelWritabilityChanged(writable: writable)
        } else {
            safeErrorCaught(ctx: self, error: ChannelPipelineException.alreadyRemoved)
        }
    }
    
    public func fireErrorCaught(error: Error) {
        if let ctx = next {
            ctx.invokeErrorCaught(error: error)
        } else {
            safeErrorCaught(ctx: self, error: ChannelPipelineException.alreadyRemoved)
        }
    }
    
    public func fireUserEventTriggered(event: Any) {
        if let ctx = next {
            ctx.invokeUserEventTriggered(event: event)
        } else {
            safeErrorCaught(ctx: self, error: ChannelPipelineException.alreadyRemoved)
        }
    }
    
    public func write(data: Any, promise: Promise<Void>) -> Future<Void> {
        if let ctx = prev {
            ctx.invokeWrite(data: data, promise: promise)
        } else {
            promise.fail(error: ChannelPipelineException.alreadyRemoved)
        }
        return promise.futureResult
    }
    
    public func writeAndFlush(data: Any, promise: Promise<Void>) -> Future<Void> {
        if let ctx = prev {
            ctx.invokeWriteAndFlush(data: data, promise: promise)
        } else {
            promise.fail(error: ChannelPipelineException.alreadyRemoved)
        }
        return promise.futureResult
    }
    
    public func flush() {
        prev?.invokeFlush()
    }
    
    public func read() {
        prev?.invokeRead()
    }
    
    public func close(promise: Promise<Void>) -> Future<Void> {
        if let ctx = prev {
            ctx.invokeClose(promise: promise)
        } else {
            promise.fail(error: ChannelPipelineException.alreadyRemoved)
        }
        
        return promise.futureResult
    }
    
    func invokeChannelRegistered() {
        assert(inEventLoop)
        
        do {
            try handler.channelRegistered(ctx: self)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeChannelUnregistered() {
        assert(inEventLoop)
        
        do {
            try handler.channelUnregistered(ctx: self)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeChannelActive() {
        assert(inEventLoop)
        
        do {
            try handler.channelActive(ctx: self)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeChannelInactive() {
        assert(inEventLoop)
        
        do {
            try handler.channelInactive(ctx: self)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeChannelRead(data: Any) {
        assert(inEventLoop)
        
        do {
            try handler.channelRead(ctx: self, data: data)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeChannelReadComplete() {
        assert(inEventLoop)
        
        do {
            try handler.channelReadComplete(ctx: self)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeChannelWritabilityChanged(writable: Bool) {
        assert(inEventLoop)
        
        do {
            try handler.channelWritabilityChanged(ctx: self, writable: writable)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeErrorCaught(error: Error) {
        assert(inEventLoop)
        
        do {
            try handler.errorCaught(ctx: self, error: error)
        } catch {
            // TODO: What to do ?
        }
    }
    
    func invokeUserEventTriggered(event: Any) {
        assert(inEventLoop)
        
        do {
            try handler.userEventTriggered(ctx: self, event: event)
        } catch let err {
            safeErrorCaught(ctx: self, error: err)
        }
    }
    
    func invokeWrite(data: Any, promise: Promise<Void>) {
        assert(inEventLoop)
        
        handler.write(ctx: self, data: data, promise: promise)
    }
    
    func invokeFlush() {
        assert(inEventLoop)
        
        handler.flush(ctx: self)
    }
    
    func invokeWriteAndFlush(data: Any, promise: Promise<Void>) {
        assert(inEventLoop)
        
        handler.write(ctx: self, data: data, promise: promise)
        handler.flush(ctx: self)
    }
    
    func invokeRead() {
        assert(inEventLoop)
        
        handler.read(ctx: self)
    }
    
    func invokeClose(promise: Promise<Void>) {
        assert(inEventLoop)
        
        handler.close(ctx: self, promise: promise)
    }
    
    func invokeHandlerAdded() throws {
        assert(inEventLoop)
        
        try handler.handlerAdded(ctx: self)
    }
    
    func invokeHandlerRemoved() throws {
        assert(inEventLoop)
        
        defer {
            pipeline = nil
            prev = nil
            next = nil
        }
        try handler.handlerRemoved(ctx: self)
    }
    
    private var inEventLoop : Bool {
        return eventLoop.inEventLoop
    }
    
    private func safeErrorCaught(ctx: ChannelHandlerContext, error: Error) {
        do {
            try handler.errorCaught(ctx: ctx, error: error)
        } catch {
            // TOOO: What to do here ?
        }
    }
}

