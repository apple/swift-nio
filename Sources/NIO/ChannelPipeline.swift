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

    public func add(name: String? = nil, handler: ChannelHandler, first: Bool = false) -> EventLoopFuture<Void> {
        let promise: EventLoopPromise<Void> = eventLoop.newPromise()
        if eventLoop.inEventLoop {
            add0(name: name, handler: handler, first: first, promise: promise)
        } else {
            eventLoop.execute {
                self.add0(name: name, handler: handler, first: first, promise: promise)
            }
        }
        return promise.futureResult
    }

    public func add0(name: String?, handler: ChannelHandler, first: Bool, promise: EventLoopPromise<Void>) {
        assert(eventLoop.inEventLoop)

        if destroyed {
            promise.fail(error: ChannelPipelineError.alreadyClosed)
            return
        }
        
        let ctx = ChannelHandlerContext(name: name ?? nextName(), handler: handler, pipeline: self)
        if first {
            ctx.inboundNext = inboundChain
            if handler is _ChannelInboundHandler {
                inboundChain = ctx
            }

            if handler is _ChannelOutboundHandler {
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
            if handler is _ChannelInboundHandler {
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
            if handler is _ChannelOutboundHandler {
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
    
    public func remove(handler: ChannelHandler) -> EventLoopFuture<Bool> {
        return remove0({ $0.handler === handler })
    }
    
    public func remove(name: String) -> EventLoopFuture<Bool> {
        return remove0({ $0.name == name })
    }
    
    public func remove(ctx: ChannelHandlerContext) -> EventLoopFuture<Bool> {
        return remove0({ $0 === ctx })
    }
    
    public func context(handler: ChannelHandler) -> EventLoopFuture<ChannelHandlerContext> {
        return context0({ $0.handler === handler })
    }
    
    public func context(name: String) -> EventLoopFuture<ChannelHandlerContext> {
        return context0({ $0.name == name })
    }
    
    public func context(ctx: ChannelHandlerContext) -> EventLoopFuture<ChannelHandlerContext> {
        return context0({ $0 === ctx })
    }
    
    private func context0(_ fn: @escaping ((ChannelHandlerContext) -> Bool)) -> EventLoopFuture<ChannelHandlerContext> {
        let promise: EventLoopPromise<ChannelHandlerContext> = eventLoop.newPromise()
        
        func _context0() {
            guard let ctx = contexts.first(where: fn) else {
                promise.fail(error: ChannelPipelineError.notFound)
                return
            }
            promise.succeed(result: ctx)
        }
        if eventLoop.inEventLoop {
            _context0()
        } else {
            eventLoop.execute {
                _context0()
            }
        }
        return promise.futureResult
    }
    
    private func remove0(_ fn: @escaping ((ChannelHandlerContext) -> Bool)) -> EventLoopFuture<Bool> {
        let promise: EventLoopPromise<Bool> = eventLoop.newPromise()
        if eventLoop.inEventLoop {
            remove0(ctx: contexts.first(where: fn), promise: promise)
        } else {
            eventLoop.execute {
                self.remove0(ctx: self.contexts.first(where: fn), promise: promise)
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
    
    private func remove0(ctx: ChannelHandlerContext?, promise: EventLoopPromise<Bool>) {
        assert(eventLoop.inEventLoop)
        
        guard let context = ctx else {
            promise.succeed(result: false)
            return
        }
        defer {
            removeFromStorage(context: context)
        }
        do {
            try context.invokeHandlerRemoved()
            promise.succeed(result: true)
        } catch let err {
            promise.fail(error: err)
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
            remove0(ctx: ctx, promise:  eventLoop.newPromise())
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
    
    public func fireChannelRead(data: NIOAny) {
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
    
    public func fireUserInboundEventTriggered(event: Any) {
        if eventLoop.inEventLoop {
            fireUserInboundEventTriggered0(event: event)
        } else {
            eventLoop.execute {
                self.fireUserInboundEventTriggered0(event: event)
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

    public func close(promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            close0(promise: promise)
        } else {
            eventLoop.execute {
                self.close0(promise: promise)
            }
        }
    }

    public func flush(promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            flush0(promise: promise)
        } else {
            eventLoop.execute {
                self.flush0(promise: promise)
            }
        }
    }
    
    public func read(promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            read0(promise: promise)
        } else {
            eventLoop.execute {
                self.read0(promise: promise)
            }
        }
    }

    public func write(data: NIOAny, promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            write0(data: data, promise: promise)
        } else {
            eventLoop.execute {
                self.write0(data: data, promise: promise)
            }
        }
    }

    public func writeAndFlush(data: NIOAny, promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            writeAndFlush0(data: data, promise: promise)
        } else {
            eventLoop.execute {
                self.writeAndFlush0(data: data, promise: promise)
            }
        }
    }
    
    public func bind(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            bind0(to: address, promise: promise)
        } else {
            eventLoop.execute {
                self.bind0(to: address, promise: promise)
            }
        }
    }
    
    public func connect(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            connect0(to: address, promise: promise)
        } else {
            eventLoop.execute {
                self.connect0(to: address, promise: promise)
            }
        }
    }
    
    public func register(promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            register0(promise: promise)
        } else {
            eventLoop.execute {
                self.register0(promise: promise)
            }
        }
    }
    
    public func triggerUserOutboundEvent(event: Any, promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            triggerUserOutboundEvent0(event: event, promise: promise)
        } else {
            eventLoop.execute {
                self.triggerUserOutboundEvent0(event: event, promise: promise)
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
    
    func close0(promise: EventLoopPromise<Void>?) {
        firstOutboundCtx.invokeClose(promise: promise)
    }
    
    func flush0(promise: EventLoopPromise<Void>?) {
        firstOutboundCtx.invokeFlush(promise: promise)
    }
    
    func read0(promise: EventLoopPromise<Void>?) {
        firstOutboundCtx.invokeRead(promise: promise)
    }
    
    func write0(data: NIOAny, promise: EventLoopPromise<Void>?) {
        firstOutboundCtx.invokeWrite(data: data, promise: promise)
    }
    
    func writeAndFlush0(data: NIOAny, promise: EventLoopPromise<Void>?) {
        firstOutboundCtx.invokeWriteAndFlush(data: data, promise: promise)
    }
    
    func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        firstOutboundCtx.invokeBind(to: address, promise: promise)
    }
    
    func connect0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        firstOutboundCtx.invokeConnect(to: address, promise: promise)
    }
    
    func register0(promise: EventLoopPromise<Void>?) {
        firstOutboundCtx.invokeRegister(promise: promise)
    }
    
    func triggerUserOutboundEvent0(event: Any, promise: EventLoopPromise<Void>?) {
        firstOutboundCtx.invokeTriggerUserOutboundEvent(event: event, promise: promise)
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
    
    func fireChannelRead0(data: NIOAny) {
        firstInboundCtx.invokeChannelRead(data: data)
    }
    
    func fireChannelReadComplete0() {
        firstInboundCtx.invokeChannelReadComplete()
    }
    
    func fireChannelWritabilityChanged0() {
        firstInboundCtx.invokeChannelWritabilityChanged()
    }
    
    func fireUserInboundEventTriggered0(event: Any) {
        firstInboundCtx.invokeUserInboundEventTriggered(event: event)
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

private final class HeadChannelHandler : _ChannelOutboundHandler {

    static let sharedInstance = HeadChannelHandler()

    private init() { }

    func register(ctx: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        if let channel = ctx.channel {
            channel._unsafe.register0(promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func bind(ctx: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        if let channel = ctx.channel {
            channel._unsafe.bind0(to: address, promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func connect(ctx: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        if let channel = ctx.channel {
            channel._unsafe.connect0(to: address, promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if let channel = ctx.channel {
            channel._unsafe.write0(data: data.forceAsIOData(), promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func flush(ctx: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        if let channel = ctx.channel {
            channel._unsafe.flush0(promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func close(ctx: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        if let channel = ctx.channel {
            channel._unsafe.close0(error: ChannelError.alreadyClosed, promise: promise)
        } else {
            promise?.fail(error: ChannelError.alreadyClosed)
        }
    }
    
    func read(ctx: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        if let channel = ctx.channel {
            channel._unsafe.read0(promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
    
    func triggerUserOutboundEvent(ctx: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        if let channel = ctx.channel {
            channel._unsafe.triggerUserOutboundEvent0(event: event, promise: promise)
        } else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
        }
    }
}

private final class TailChannelHandler : _ChannelInboundHandler {
    
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
    
    func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        // Discard
    }
    
    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        ctx.channel!._unsafe.errorCaught0(error: error)
    }
    
    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        ctx.channel!._unsafe.channelRead0(data: data)
    }
}

public enum ChannelPipelineError : Error {
    case alreadyRemoved
    case alreadyClosed
    case notFound
}

public final class ChannelHandlerContext : ChannelInvoker {
    
    // visible for ChannelPipeline to modify
    fileprivate var outboundNext: ChannelHandlerContext?
    
    fileprivate var inboundNext: ChannelHandlerContext?
    
    public fileprivate(set) var pipeline: ChannelPipeline?
    
    public var channel: Channel? {
        return pipeline?.channel
    }
    
    public let handler: ChannelHandler
    
    public let name: String
    public let eventLoop: EventLoop
    private let inboundHandler: _ChannelInboundHandler!
    private let outboundHandler: _ChannelOutboundHandler!
    
    // Only created from within ChannelPipeline
    fileprivate init(name: String, handler: ChannelHandler, pipeline: ChannelPipeline) {
        self.name = name
        self.handler = handler
        self.pipeline = pipeline
        self.eventLoop = pipeline.eventLoop
        if let handler = handler as? _ChannelInboundHandler {
            self.inboundHandler = handler
        } else {
            self.inboundHandler = nil
        }
        if let handler = handler as? _ChannelOutboundHandler {
            self.outboundHandler = handler
        } else {
            self.outboundHandler = nil
        }
    }
    
    public func fireChannelRegistered() {
        if let inboundNext = inboundNext {
            inboundNext.invokeChannelRegistered()
        }
    }
    
    public func fireChannelUnregistered() {
        if let inboundNext = inboundNext {
            inboundNext.invokeChannelUnregistered()
        }
    }
    
    public func fireChannelActive() {
        if let inboundNext = inboundNext {
            inboundNext.invokeChannelActive()
        }
    }
    
    public func fireChannelInactive() {
        if let inboundNext = inboundNext {
            inboundNext.invokeChannelInactive()
        }
    }
    
    public func fireChannelRead(data: NIOAny) {
        if let inboundNext = inboundNext {
            inboundNext.invokeChannelRead(data: data)
        }
    }
    
    public func fireChannelReadComplete() {
        if let inboundNext = inboundNext {
            inboundNext.invokeChannelReadComplete()
        }
    }
    
    public func fireChannelWritabilityChanged() {
        if let inboundNext = inboundNext {
            inboundNext.invokeChannelWritabilityChanged()
        }
    }
    
    public func fireErrorCaught(error: Error) {
        if let inboundNext = inboundNext {
            inboundNext.invokeErrorCaught(error: error)
        }
    }
    
    public func fireUserInboundEventTriggered(event: Any) {
        if let inboundNext = inboundNext {
            inboundNext.invokeUserInboundEventTriggered(event: event)
        }
    }
    
    public func register(promise: EventLoopPromise<Void>?) {
        if let outboundNext = outboundNext {
            outboundNext.invokeRegister(promise: promise)
        } else {
            promise?.fail(error: ChannelError.alreadyClosed)
        }
    }
    
    public func bind(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        if let outboundNext = outboundNext {
            outboundNext.invokeBind(to: address, promise: promise)
        } else {
            promise?.fail(error: ChannelError.alreadyClosed)
        }
    }
    
    public func connect(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        if let outboundNext = outboundNext {
            outboundNext.invokeConnect(to: address, promise: promise)
        } else {
            promise?.fail(error: ChannelError.alreadyClosed)
        }
    }

    public func write(data: NIOAny, promise: EventLoopPromise<Void>?) {
        if let outboundNext = outboundNext {
            outboundNext.invokeWrite(data: data, promise: promise)
        } else {
            promise?.fail(error: ChannelError.alreadyClosed)
        }
    }

    public func flush(promise: EventLoopPromise<Void>?) {
        if let outboundNext = outboundNext {
            outboundNext.invokeFlush(promise: promise)
        } else {
            promise?.fail(error: ChannelError.alreadyClosed)
        }
    }
    
    public func writeAndFlush(data: NIOAny, promise: EventLoopPromise<Void>?) {
        if let outboundNext = outboundNext {
            outboundNext.invokeWriteAndFlush(data: data, promise: promise)
        } else {
            promise?.fail(error: ChannelError.alreadyClosed)
        }
    }
    
    public func read(promise: EventLoopPromise<Void>?) {
        if let outboundNext = outboundNext {
            outboundNext.invokeRead(promise: promise)
        } else {
            promise?.fail(error: ChannelError.alreadyClosed)
        }
    }
    
    public func close(promise: EventLoopPromise<Void>?) {
        if let outboundNext = outboundNext {
            outboundNext.invokeClose(promise: promise)
        } else {
            promise?.fail(error: ChannelError.alreadyClosed)
        }
    }
    
    public func triggerUserOutboundEvent(event: Any, promise: EventLoopPromise<Void>?) {
        if let outboundNext = outboundNext {
            outboundNext.invokeTriggerUserOutboundEvent(event: event, promise: promise)
        } else {
            promise?.fail(error: ChannelError.alreadyClosed)
        }
    }
    
    fileprivate func invokeChannelRegistered() {
        assert(inEventLoop)
        
        do {
            try self.inboundHandler.channelRegistered(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    fileprivate func invokeChannelUnregistered() {
        assert(inEventLoop)
        
        do {
            try self.inboundHandler.channelUnregistered(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    fileprivate func invokeChannelActive() {
        assert(inEventLoop)
        
        do {
            try self.inboundHandler.channelActive(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    fileprivate func invokeChannelInactive() {
        assert(inEventLoop)
        
        do {
            try self.inboundHandler.channelInactive(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    fileprivate func invokeChannelRead(data: NIOAny) {
        assert(inEventLoop)
        
        do {
            try self.inboundHandler.channelRead(ctx: self, data: data)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    fileprivate func invokeChannelReadComplete() {
        assert(inEventLoop)
        
        do {
            try self.inboundHandler.channelReadComplete(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    fileprivate func invokeChannelWritabilityChanged() {
        assert(inEventLoop)
        
        do {
            try self.inboundHandler.channelWritabilityChanged(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    fileprivate func invokeErrorCaught(error: Error) {
        assert(inEventLoop)
        
        do {
            try self.inboundHandler.errorCaught(ctx: self, error: error)
        } catch let err {
            // Forward the error thrown by errorCaught through the pipeline
            fireErrorCaught(error: err)
        }
    }
    
    fileprivate func invokeUserInboundEventTriggered(event: Any) {
        assert(inEventLoop)
        
        do {
            try self.inboundHandler.userInboundEventTriggered(ctx: self, event: event)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    fileprivate func invokeRegister(promise: EventLoopPromise<Void>?) {
        assert(inEventLoop)
        assert(promise.map { !$0.futureResult.fulfilled } ?? true, "Promise \(promise!) already fulfilled")
        
        self.outboundHandler.register(ctx: self, promise: promise)
    }
    
   fileprivate func invokeBind(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        assert(inEventLoop)
        assert(promise.map { !$0.futureResult.fulfilled } ?? true, "Promise \(promise!) already fulfilled")

        self.outboundHandler.bind(ctx: self, to: address, promise: promise)
    }
    
    fileprivate func invokeConnect(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        assert(inEventLoop)
        assert(promise.map { !$0.futureResult.fulfilled } ?? true, "Promise \(promise!) already fulfilled")

        self.outboundHandler.connect(ctx: self, to: address, promise: promise)
    }

    fileprivate func invokeWrite(data: NIOAny, promise: EventLoopPromise<Void>?) {
        assert(inEventLoop)
        assert(promise.map { !$0.futureResult.fulfilled } ?? true, "Promise \(promise!) already fulfilled")

        self.outboundHandler.write(ctx: self, data: data, promise: promise)
    }

    fileprivate func invokeFlush(promise: EventLoopPromise<Void>?) {
        assert(inEventLoop)
        
        self.outboundHandler.flush(ctx: self, promise: promise)
    }
    
    fileprivate func invokeWriteAndFlush(data: NIOAny, promise: EventLoopPromise<Void>?) {
        assert(inEventLoop)
        assert(promise.map { !$0.futureResult.fulfilled } ?? true, "Promise \(promise!) already fulfilled")
        
        if let promise = promise {
            var counter = 2
            let callback: (EventLoopFutureValue<Void>) -> Void = { v in
                switch v {
                case .failure(let err):
                    promise.fail(error: err)
                case .success(_):
                    counter -= 1
                    if counter == 0 {
                        promise.succeed(result: ())
                    }
                    assert(counter >= 0)
                }
            }
            
            let writePromise: EventLoopPromise<Void> = eventLoop.newPromise()
            let flushPromise: EventLoopPromise<Void> = eventLoop.newPromise()
            
            self.outboundHandler.write(ctx: self, data: data, promise: writePromise)
            self.outboundHandler.flush(ctx: self, promise: flushPromise)
            
            writePromise.futureResult.whenComplete(callback: callback)
            flushPromise.futureResult.whenComplete(callback: callback)
        } else {
            self.outboundHandler.write(ctx: self, data: data, promise: nil)
            self.outboundHandler.flush(ctx: self, promise: nil)
        }
    }
    
    fileprivate func invokeRead(promise: EventLoopPromise<Void>?) {
        assert(inEventLoop)
        
        self.outboundHandler.read(ctx: self, promise: promise)
    }
    
    fileprivate func invokeClose(promise: EventLoopPromise<Void>?) {
        assert(inEventLoop)
        assert(promise.map { !$0.futureResult.fulfilled } ?? true, "Promise \(promise!) already fulfilled")

        self.outboundHandler.close(ctx: self, promise: promise)
    }
    
    fileprivate func invokeTriggerUserOutboundEvent(event: Any, promise: EventLoopPromise<Void>?) {
        assert(inEventLoop)
        assert(promise.map { !$0.futureResult.fulfilled } ?? true, "Promise \(promise!) already fulfilled")
        
        self.outboundHandler.triggerUserOutboundEvent(ctx: self, event: event, promise: promise)
    }
    
    fileprivate func invokeHandlerAdded() throws {
        assert(inEventLoop)
        
        try handler.handlerAdded(ctx: self)
    }
    
    fileprivate func invokeHandlerRemoved() throws {
        assert(inEventLoop)
        try handler.handlerRemoved(ctx: self)
    }
    
    private var inEventLoop : Bool {
        return eventLoop.inEventLoop
    }
}

