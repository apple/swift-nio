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
import Sockets


/*
 All operations on ChannelPipeline are thread-safe
 */
public final class ChannelPipeline : ChannelInvoker {
    
    private var outboundChain: ChannelHandlerContext?
    private var inboundChain: ChannelHandlerContext?
    private var contexts: [ChannelHandlerContext] = []
    
    private var idx: Int = 0
    private var destroyed: Bool = false
    
    public var eventLoop: EventLoop {
        return channel.eventLoop
    }

    public unowned let channel: Channel

    public func add(name: String? = nil, handler: ChannelHandler, first: Bool = false) -> Future<Void> {
        let promise: Promise<Void> = eventLoop.newPromise()
        if eventLoop.inEventLoop {
            add0(name: name, handler: handler, first: first, promise: promise)
        } else {
            eventLoop.execute {
                self.add0(name: name, handler: handler, first: first, promise: promise)
            }
        }
        return promise.futureResult
    }

    public func add0(name: String?, handler: ChannelHandler, first: Bool, promise: Promise<Void>) {
        assert(eventLoop.inEventLoop)

        guard !destroyed else {
            promise.fail(error: ChannelPipelineError.alreadyClosed)
            return
        }
        
        let ctx = ChannelHandlerContext(name: name ?? nextName(), handler: handler, pipeline: self)
        if first {
            ctx.inboundNext = inboundChain
            if handler is ChannelInboundHandler {
                inboundChain = ctx
            }

            if handler is ChannelOutboundHandler {
                var c = outboundChain

                if c!.handler === HeadChannelHandler.sharedInstance {
                    ctx.outboundNext = outboundChain
                    outboundChain = ctx
                } else {
                    repeat {
                        let c2 = c!.outboundNext
                        if c2!.handler === HeadChannelHandler.sharedInstance {
                            ctx.outboundNext = c2
                            c!.outboundNext = ctx
                            break
                        }
                        c = c2
                    } while true
                }
            } else {
                ctx.outboundNext = outboundChain
            }

            contexts.insert(ctx, at: 0)
        } else {
            if handler is ChannelInboundHandler {
                var c = inboundChain
                
                if c!.handler === TailChannelHandler.sharedInstance {
                    ctx.inboundNext = inboundChain
                    inboundChain = ctx
                } else {
                    repeat {
                        let c2 = c!.inboundNext
                        if c2!.handler === TailChannelHandler.sharedInstance {
                            ctx.inboundNext = c2
                            c!.inboundNext = ctx
                            break
                        }
                        c = c2
                    } while true
                }
            } else {
                ctx.inboundNext = inboundChain
            }
            
            ctx.outboundNext = outboundChain
            if handler is ChannelOutboundHandler {
                outboundChain = ctx
            }

            contexts.append(ctx)
        }
        
        do {
            try ctx.invokeHandlerAdded()
            promise.succeed(result: ())
        } catch let err {
            removeFromStorage(context: ctx)

            promise.fail(error: err)
        }
    }
    
    public func remove(handler: ChannelHandler) -> Future<Bool> {
        let promise: Promise<Bool> = eventLoop.newPromise()
        if eventLoop.inEventLoop {
            remove0(handler: handler, promise: promise)
        } else {
            eventLoop.execute {
                self.remove0(handler: handler, promise: promise)
            }
        }
        return promise.futureResult
    }
    
    private func removeFromStorage(context: ChannelHandlerContext) {
        // Update the linked-list structure after removal
        if inboundChain === context {
            inboundChain = context.inboundNext
        } else {
            var ic = inboundChain
            while let i = ic {
                if i.inboundNext === context {
                    i.inboundNext = context.inboundNext
                    break
                }
                ic = i.inboundNext
            }
        }
        
        if outboundChain === context {
            outboundChain = context.outboundNext
        } else {
            var oc = outboundChain
            while let o = oc {
                if o.outboundNext === context {
                    o.outboundNext = context.outboundNext
                    break
                }
                oc = o.outboundNext
            }
        }
        
        let index = contexts.index(where: { $0 === context})!
        contexts.remove(at: index)
        
        // Was removed so destroy references
        destroyReferences(context)
  
        assert(inboundChain != nil)
        assert(outboundChain != nil)
    }
    
    private func remove0(handler: ChannelHandler, promise: Promise<Bool>) {
        assert(eventLoop.inEventLoop)

        // find the context in the pipeline
        if let context = contexts.first(where: { $0.handler === handler }) {
            defer {
                removeFromStorage(context: context)
            }
            do {
                try context.invokeHandlerRemoved()
                promise.succeed(result: true)
            } catch let err {
                promise.fail(error: err)
            }
        } else {
            promise.succeed(result: false)
        }
    }
  
    private func nextName() -> String {
        assert(eventLoop.inEventLoop)

        let name = "handler\(idx)"
        idx += 1
        return name
    }

    func removeHandlers() {
        assert(eventLoop.inEventLoop)
        
        while let ctx = contexts.first {
            remove0(handler: ctx.handler, promise:  eventLoop.newPromise())
        }
        
        // We need to set the next reference to nil to ensure we not leak memory due a cycle-reference.
        destroyReferences(inboundChain!)
        destroyReferences(outboundChain!)
        
        destroyed = true
    }
    
    private func destroyReferences(_ ctx: ChannelHandlerContext) {
        // We need to set the next reference to nil to ensure we not leak memory due a cycle-reference.
        ctx.inboundNext = nil
        ctx.outboundNext = nil
        ctx.pipeline = nil
    }
    
    // Just delegate to the head and tail context
    public func fireChannelRegistered() {
        if eventLoop.inEventLoop {
            fireChannelRegistered0()
        } else {
            eventLoop.execute {
                self.fireChannelRegistered0()
            }
        }
    }
   
    public func fireChannelUnregistered() {
        if eventLoop.inEventLoop {
            fireChannelUnregistered0()
        } else {
            eventLoop.execute {
                self.fireChannelUnregistered0()
            }
        }
    }
    
    public func fireChannelInactive() {
        if eventLoop.inEventLoop {
            fireChannelInactive0()
        } else {
            eventLoop.execute {
                self.fireChannelInactive0()
            }
        }
    }
    
    public func fireChannelActive() {
        if eventLoop.inEventLoop {
            fireChannelActive0()
        } else {
            eventLoop.execute {
                self.fireChannelActive0()
            }
        }
    }
    
    public func fireChannelRead(data: IOData) {
        if eventLoop.inEventLoop {
            fireChannelRead0(data: data)
        } else {
            eventLoop.execute {
                self.fireChannelRead0(data: data)
            }
        }
    }
    
    public func fireChannelReadComplete() {
        if eventLoop.inEventLoop {
            fireChannelReadComplete0()
        } else {
            eventLoop.execute {
                self.fireChannelReadComplete0()
            }
        }
    }

    public func fireChannelWritabilityChanged() {
        if eventLoop.inEventLoop {
            fireChannelWritabilityChanged0()
        } else {
            eventLoop.execute {
                self.fireChannelWritabilityChanged0()
            }
        }
    }
    
    public func fireUserEventTriggered(event: Any) {
        if eventLoop.inEventLoop {
            fireUserEventTriggered0(event: event)
        } else {
            eventLoop.execute {
                self.fireUserEventTriggered0(event: event)
            }
        }
    }
    
    public func fireErrorCaught(error: Error) {
        if eventLoop.inEventLoop {
            fireErrorCaught0(error: error)
        } else {
            eventLoop.execute {
                self.fireErrorCaught0(error: error)
            }
        }
    }

    public func close(promise: Promise<Void>?) {
        if eventLoop.inEventLoop {
            close0(promise: promise)
        } else {
            eventLoop.execute {
                self.close0(promise: promise)
            }
        }
    }

    public func flush(promise: Promise<Void>?) {
        if eventLoop.inEventLoop {
            flush0(promise: promise)
        } else {
            eventLoop.execute {
                self.flush0(promise: promise)
            }
        }
    }
    
    public func read(promise: Promise<Void>?) {
        if eventLoop.inEventLoop {
            read0(promise: promise)
        } else {
            eventLoop.execute {
                self.read0(promise: promise)
            }
        }
    }

    public func write(data: IOData, promise: Promise<Void>?) {
        if eventLoop.inEventLoop {
            write0(data: data, promise: promise)
        } else {
            eventLoop.execute {
                self.write0(data: data, promise: promise)
            }
        }
    }

    public func bind(to address: SocketAddress, promise: Promise<Void>?) {
        if eventLoop.inEventLoop {
            bind0(to: address, promise: promise)
        } else {
            eventLoop.execute {
                self.bind0(to: address, promise: promise)
            }
        }
    }
    
    public func connect(to address: SocketAddress, promise: Promise<Void>?) {
        if eventLoop.inEventLoop {
            connect0(to: address, promise: promise)
        } else {
            eventLoop.execute {
                self.connect0(to: address, promise: promise)
            }
        }
    }
    
    public func register(promise: Promise<Void>?) {
        if eventLoop.inEventLoop {
            register0(promise: promise)
        } else {
            eventLoop.execute {
                self.register0(promise: promise)
            }
        }
    }
    
    // These methods are expected to only be called from within the EventLoop
    
    private var firstOutboundCtx: ChannelHandlerContext {
        return outboundChain!
    }
    
    private var firstInboundCtx: ChannelHandlerContext {
        return inboundChain!
    }
    
    func close0(promise: Promise<Void>?) {
        firstOutboundCtx.invokeClose(promise: promise)
    }
    
    func flush0(promise: Promise<Void>?) {
        firstOutboundCtx.invokeFlush(promise: promise)
    }
    
    func read0(promise: Promise<Void>?) {
        firstOutboundCtx.invokeRead(promise: promise)
    }
    
    func write0(data: IOData, promise: Promise<Void>?) {
        firstOutboundCtx.invokeWrite(data: data, promise: promise)
    }
    
    func bind0(to address: SocketAddress, promise: Promise<Void>?) {
        firstOutboundCtx.invokeBind(to: address, promise: promise)
    }
    
    func connect0(to address: SocketAddress, promise: Promise<Void>?) {
        firstOutboundCtx.invokeConnect(to: address, promise: promise)
    }
    
    func register0(promise: Promise<Void>?) {
        firstOutboundCtx.invokeRegister(promise: promise)
    }
    
    func fireChannelRegistered0() {
        firstInboundCtx.invokeChannelRegistered()
    }
    
    func fireChannelUnregistered0() {
        firstInboundCtx.invokeChannelUnregistered()
    }
    
    func fireChannelInactive0() {
        firstInboundCtx.invokeChannelInactive()
    }
    
    func fireChannelActive0() {
        firstInboundCtx.invokeChannelActive()
    }
    
    func fireChannelRead0(data: IOData) {
        firstInboundCtx.invokeChannelRead(data: data)
    }
    
    func fireChannelReadComplete0() {
        firstInboundCtx.invokeChannelReadComplete()
    }
    
    func fireChannelWritabilityChanged0() {
        firstInboundCtx.invokeChannelWritabilityChanged()
    }
    
    func fireUserEventTriggered0(event: Any) {
        firstInboundCtx.invokeUserEventTriggered(event: event)
    }
    
    func fireErrorCaught0(error: Error) {
        firstInboundCtx.invokeErrorCaught(error: error)
    }
    
    private var inEventLoop : Bool {
        return eventLoop.inEventLoop
    }

    // Only executed from Channel
    init (channel: Channel) {
        self.channel = channel
        
        outboundChain = ChannelHandlerContext(name: "head", handler: HeadChannelHandler.sharedInstance, pipeline: self)
        inboundChain = ChannelHandlerContext(name: "tail", handler: TailChannelHandler.sharedInstance, pipeline: self)
        outboundChain!.inboundNext = inboundChain
        inboundChain!.outboundNext = outboundChain
    }
}

private final class HeadChannelHandler : ChannelOutboundHandler {

    static let sharedInstance = HeadChannelHandler()

    private init() { }

    func register(ctx: ChannelHandlerContext, promise: Promise<Void>?) {
        ctx.channel!._unsafe.register0(promise: promise)
    }
    
    func bind(ctx: ChannelHandlerContext, to address: SocketAddress, promise: Promise<Void>?) {
        ctx.channel!._unsafe.bind0(to: address, promise: promise)
    }
    
    func connect(ctx: ChannelHandlerContext, to address: SocketAddress, promise: Promise<Void>?) {
        ctx.channel!._unsafe.connect0(to: address, promise: promise)
    }
    
    func write(ctx: ChannelHandlerContext, data: IOData, promise: Promise<Void>?) {
        ctx.channel!._unsafe.write0(data: data, promise: promise)
    }
    
    func flush(ctx: ChannelHandlerContext, promise: Promise<Void>?) {
        ctx.channel!._unsafe.flush0(promise: promise)
    }
    
    func close(ctx: ChannelHandlerContext, promise: Promise<Void>?) {
        ctx.channel!._unsafe.close0(error: ChannelError.closed, promise: promise)
    }
    
    func read(ctx: ChannelHandlerContext, promise: Promise<Void>?) {
        ctx.channel!._unsafe.read0(promise: promise)
    }
}

private final class TailChannelHandler : ChannelInboundHandler {
    
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
    
    func channelWritabilityChanged(ctx: ChannelHandlerContext) {
        // Discard
    }
    
    func userEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        // Discard
    }
    
    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        // TODO: Log this and tell the user that its most likely a fault not handling it.
    }
    
    func channelRead(ctx: ChannelHandlerContext, data: IOData) {
        ctx.channel!._unsafe.channelRead0(data: data)
    }
}

public enum ChannelPipelineError : Error {
    case alreadyRemoved
    case alreadyClosed
}


public final class ChannelHandlerContext : ChannelInvoker {
    
    // visible for ChannelPipeline to modify and also marked as weak to ensure we not create a
    // reference-cycle for the doubly-linked-list
    fileprivate var outboundNext: ChannelHandlerContext?
    
    fileprivate var inboundNext: ChannelHandlerContext?
    
    // marked as weak to not create a reference cycle between this instance and the pipeline
    public fileprivate(set) weak var pipeline: ChannelPipeline?
    
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
        inboundNext!.invokeChannelRegistered()
    }
    
    public func fireChannelUnregistered() {
        inboundNext!.invokeChannelUnregistered()
    }
    
    public func fireChannelActive() {
        inboundNext!.invokeChannelActive()
    }
    
    public func fireChannelInactive() {
        inboundNext!.invokeChannelInactive()
    }
    
    public func fireChannelRead(data: IOData) {
        inboundNext!.invokeChannelRead(data: data)
    }
    
    public func fireChannelReadComplete() {
        inboundNext!.invokeChannelReadComplete()
    }
    
    public func fireChannelWritabilityChanged() {
        inboundNext!.invokeChannelWritabilityChanged()
    }
    
    public func fireErrorCaught(error: Error) {
        inboundNext!.invokeErrorCaught(error: error)
    }
    
    public func fireUserEventTriggered(event: Any) {
        inboundNext!.invokeUserEventTriggered(event: event)
    }
    
    public func register(promise: Promise<Void>?){
        outboundNext!.invokeRegister(promise: promise)
    }
    
    public func bind(to address: SocketAddress, promise: Promise<Void>?) {
        outboundNext!.invokeBind(to: address, promise: promise)
    }
    
    public func connect(to address: SocketAddress, promise: Promise<Void>?) {
        outboundNext!.invokeBind(to: address, promise: promise)
    }

    public func write(data: IOData, promise: Promise<Void>?) {
        outboundNext!.invokeWrite(data: data, promise: promise)
    }

    public func flush(promise: Promise<Void>?) {
        outboundNext!.invokeFlush(promise: promise)
    }
    
    public func read(promise: Promise<Void>?) {
        outboundNext!.invokeRead(promise: promise)
    }
    
    public func close(promise: Promise<Void>?) {
        outboundNext!.invokeClose(promise: promise)
    }
    
    func invokeChannelRegistered() {
        assert(inEventLoop)
        
        do {
            try (handler as! ChannelInboundHandler).channelRegistered(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    func invokeChannelUnregistered() {
        assert(inEventLoop)
        
        do {
            try (handler as! ChannelInboundHandler).channelUnregistered(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    func invokeChannelActive() {
        assert(inEventLoop)
        
        do {
            try (handler as! ChannelInboundHandler).channelActive(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    func invokeChannelInactive() {
        assert(inEventLoop)
        
        do {
            try (handler as! ChannelInboundHandler).channelInactive(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    func invokeChannelRead(data: IOData) {
        assert(inEventLoop)
        
        do {
            try (handler as! ChannelInboundHandler).channelRead(ctx: self, data: data)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    func invokeChannelReadComplete() {
        assert(inEventLoop)
        
        do {
            try (handler as! ChannelInboundHandler).channelReadComplete(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    func invokeChannelWritabilityChanged() {
        assert(inEventLoop)
        
        do {
            try (handler as! ChannelInboundHandler).channelWritabilityChanged(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    func invokeErrorCaught(error: Error) {
        assert(inEventLoop)
        
        do {
            try (handler as! ChannelInboundHandler).errorCaught(ctx: self, error: error)
        } catch let err {
            // Forward the error thrown by errorCaught through the pipeline
            fireErrorCaught(error: err)
        }
    }
    
    func invokeUserEventTriggered(event: Any) {
        assert(inEventLoop)
        
        do {
            try (handler as! ChannelInboundHandler).userEventTriggered(ctx: self, event: event)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    func invokeRegister(promise: Promise<Void>?) {
        assert(inEventLoop)
        assert(promise.map { !$0.futureResult.fulfilled } ?? true, "Promise \(promise!) already fulfilled")
        
        (handler as! ChannelOutboundHandler).register(ctx: self, promise: promise)
    }
    
    func invokeBind(to address: SocketAddress, promise: Promise<Void>?) {
        assert(inEventLoop)
        assert(promise.map { !$0.futureResult.fulfilled } ?? true, "Promise \(promise!) already fulfilled")

        (handler as! ChannelOutboundHandler).bind(ctx: self, to: address, promise: promise)
    }
    
    func invokeConnect(to address: SocketAddress, promise: Promise<Void>?) {
        assert(inEventLoop)
        assert(promise.map { !$0.futureResult.fulfilled } ?? true, "Promise \(promise!) already fulfilled")

        (handler as! ChannelOutboundHandler).connect(ctx: self, to: address, promise: promise)
    }

    func invokeWrite(data: IOData, promise: Promise<Void>?) {
        assert(inEventLoop)
        assert(promise.map { !$0.futureResult.fulfilled } ?? true, "Promise \(promise!) already fulfilled")

        (handler as! ChannelOutboundHandler).write(ctx: self, data: data, promise: promise)
    }
    
    func invokeFlush(promise: Promise<Void>?) {
        assert(inEventLoop)
        
        (handler as! ChannelOutboundHandler).flush(ctx: self, promise: promise)
    }
    
    func invokeRead(promise: Promise<Void>?) {
        assert(inEventLoop)
        
        (handler as! ChannelOutboundHandler).read(ctx: self, promise: promise)
    }
    
    func invokeClose(promise: Promise<Void>?) {
        assert(inEventLoop)
        assert(promise.map { !$0.futureResult.fulfilled } ?? true, "Promise \(promise!) already fulfilled")

        (handler as! ChannelOutboundHandler).close(ctx: self, promise: promise)
    }
    
    func invokeHandlerAdded() throws {
        assert(inEventLoop)
        
        try handler.handlerAdded(ctx: self)
    }
    
    func invokeHandlerRemoved() throws {
        assert(inEventLoop)
        try handler.handlerRemoved(ctx: self)
    }
    
    private var inEventLoop : Bool {
        return eventLoop.inEventLoop
    }
}

