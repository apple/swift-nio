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


/*
 All operations on ChannelPipeline are thread-safe
 */
public class ChannelPipeline : ChannelInboundInvoker {
    
    private var head: ChannelHandlerContext?
    private var tail: ChannelHandlerContext?
    private var idx: Int = 0
    fileprivate let eventLoop: EventLoop

    public unowned let channel: Channel

    public func add(name: String? = nil, handler: ChannelHandler, first: Bool = false) -> Future<Void> {
        let promise = eventLoop.newPromise(type: Void.self)
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
            promise.succeed(result: ())
        } catch let err {
            ctx.prev!.next = ctx.next
            ctx.next!.prev = ctx.prev

            promise.fail(error: err)
        }
    }
    
    public func remove(handler: ChannelHandler) -> Future<Bool> {
        let promise = Promise<Bool>()
        if eventLoop.inEventLoop {
            remove0(handler: handler, promise: promise)
        } else {
            eventLoop.execute {
                self.remove0(handler: handler, promise: promise)
            }
        }
        return promise.futureResult
    }
    
    private func remove0(handler: ChannelHandler, promise: Promise<Bool>) {
        assert(eventLoop.inEventLoop)

        guard let ctx = getCtx(equalsFunc: { ctx in
            return ctx.handler === handler
        }) else {
            promise.succeed(result: false)
            return
        }
        
        defer {
            ctx.prev!.next = ctx.next
            ctx.next?.prev = ctx.prev
            
            // Was removed so set pipeline and prev / next to nil
            ctx.pipeline = nil
            ctx.prev = nil
            ctx.next = nil
        }
        do {
            try ctx.invokeHandlerRemoved()
            promise.succeed(result: true)
        } catch let err {
            promise.fail(error: err)
        }
    }
    
    public func remove(name: String) -> Future<Bool> {
        let promise = Promise<Bool>()
        if eventLoop.inEventLoop {
            remove0(name: name, promise: promise)
        } else {
            eventLoop.execute {
                self.remove0(name: name, promise: promise)
            }
        }
        return promise.futureResult
    }
    
    private func remove0(name: String, promise: Promise<Bool>) {
        assert(eventLoop.inEventLoop)

        guard let ctx = getCtx(equalsFunc: { ctx in
            return ctx.name == name
        }) else {
            promise.succeed(result: false)
            return
        }
        defer {
            ctx.prev!.next = ctx.next
            ctx.next?.prev = ctx.prev
        }

        do {
            try ctx.invokeHandlerRemoved()
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

    // Just traverse the pipeline from the start
    private func getCtx(equalsFunc: (ChannelHandlerContext) -> Bool) -> ChannelHandlerContext? {
        assert(eventLoop.inEventLoop)

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
        assert(eventLoop.inEventLoop)
        
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
    
    public func fireChannelRead(data: Any) {
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

    public func fireChannelWritabilityChanged(writable: Bool) {
        if eventLoop.inEventLoop {
            fireChannelWritabilityChanged0(writable: writable)
        } else {
            eventLoop.execute {
                self.fireChannelWritabilityChanged0(writable: writable)
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

    func close(promise: Promise<Void>) -> Future<Void> {
        if eventLoop.inEventLoop {
            tail!.invokeClose(promise: promise)
        } else {
            eventLoop.execute {
                self.tail!.invokeClose(promise: promise)
            }
        }
        return promise.futureResult
    }
    
    func flush() {
        if eventLoop.inEventLoop {
            tail!.invokeFlush()
        } else {
            eventLoop.execute {
                self.tail!.invokeFlush()
            }
        }
    }
    
    func read() {
        if eventLoop.inEventLoop {
            read0()
        } else {
            eventLoop.execute {
                self.read0()
            }
        }
    }

    @discardableResult
    func write(data: Any, promise: Promise<Void>) -> Future<Void> {
        if eventLoop.inEventLoop {
            tail!.invokeWrite(data: data, promise: promise)
        } else {
            eventLoop.execute {
                self.tail!.invokeWrite(data: data, promise: promise)
            }
        }
        return promise.futureResult
    }
    
    @discardableResult
    func writeAndFlush(data: Any, promise: Promise<Void>) -> Future<Void> {
        if eventLoop.inEventLoop {
            tail!.invokeWriteAndFlush(data: data, promise: promise)
        } else {
            eventLoop.execute {
                self.tail!.invokeWriteAndFlush(data: data, promise: promise)
            }
        }
        return promise.futureResult
    }
    
    func bind(local: SocketAddress, promise: Promise<Void>) -> Future<Void> {
        if eventLoop.inEventLoop {
            tail!.invokeBind(local: local, promise: promise)
        } else {
            eventLoop.execute {
                self.tail!.invokeBind(local: local, promise: promise)
            }
        }
        return promise.futureResult
    }
    
    func connect(remote: SocketAddress, promise: Promise<Void>) -> Future<Void> {
        if eventLoop.inEventLoop {
            tail!.invokeConnect(remote: remote, promise: promise)
        } else {
            eventLoop.execute {
                self.tail!.invokeConnect(remote: remote, promise: promise)
            }
        }
        return promise.futureResult
    }
    
    func register(promise: Promise<Void>) -> Future<Void> {
        if eventLoop.inEventLoop {
            tail!.invokeRegister(promise: promise)
        } else {
            eventLoop.execute {
                self.tail!.invokeRegister(promise: promise)
            }
        }
        return promise.futureResult
    }
    
    // These methods are expected to only be called from withint the EventLoop
    func read0() {
        tail!.invokeRead()
    }
    
    func fireChannelRegistered0() {
        head!.invokeChannelRegistered()
    }
    
    func fireChannelUnregistered0() {
        head!.invokeChannelUnregistered()
    }
    
    func fireChannelInactive0() {
        head!.invokeChannelInactive()
    }
    
    func fireChannelActive0() {
        head!.invokeChannelActive()
    }
    
    func fireChannelRead0(data: Any) {
        head!.invokeChannelRead(data: data)
    }
    
    func fireChannelReadComplete0() {
        head!.invokeChannelReadComplete()
    }
    
    func fireChannelWritabilityChanged0(writable: Bool) {
        head!.invokeChannelWritabilityChanged(writable: writable)
    }
    
    func fireUserEventTriggered0(event: Any) {
        head!.invokeUserEventTriggered(event: event)
    }
    
    func fireErrorCaught0(error: Error) {
        head!.invokeErrorCaught(error: error)
    }
    
    private var inEventLoop : Bool {
        return eventLoop.inEventLoop
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

    func register(ctx: ChannelHandlerContext, promise: Promise<Void>) {
        ctx.channel!._unsafe.register0(promise: promise)
    }
    
    func bind(ctx: ChannelHandlerContext, local: SocketAddress, promise: Promise<Void>) {
        ctx.channel!._unsafe.bind0(local: local, promise: promise)
    }
    
    func connect(ctx: ChannelHandlerContext, remote: SocketAddress, promise: Promise<Void>) {
        ctx.channel!._unsafe.connect0(remote: remote, promise: promise)
    }
    
    func write(ctx: ChannelHandlerContext, data: Any, promise: Promise<Void>) {
        ctx.channel!._unsafe.write0(data: data, promise: promise)
    }
    
    func flush(ctx: ChannelHandlerContext) {
        ctx.channel!._unsafe.flush0()
    }
    
    func close(ctx: ChannelHandlerContext, promise: Promise<Void>) {
        ctx.channel!._unsafe.close0(promise: promise)
    }
    
    func read(ctx: ChannelHandlerContext) {
        ctx.channel!._unsafe.startReading0()
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
        ctx.channel!._unsafe.readIfNeeded0()
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
        ctx.channel!._unsafe.channelRead0(data: data)
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
        next!.invokeChannelRegistered()
    }
    
    public func fireChannelUnregistered() {
        next!.invokeChannelUnregistered()
    }
    
    public func fireChannelActive() {
        next!.invokeChannelActive()
    }
    
    public func fireChannelInactive() {
        next!.invokeChannelInactive()
    }
    
    public func fireChannelRead(data: Any) {
        next!.invokeChannelRead(data: data)
    }
    
    public func fireChannelReadComplete() {
        next!.invokeChannelReadComplete()
    }
    
    public func fireChannelWritabilityChanged(writable: Bool) {
        next!.invokeChannelWritabilityChanged(writable: writable)
    }
    
    public func fireErrorCaught(error: Error) {
        next!.invokeErrorCaught(error: error)
    }
    
    public func fireUserEventTriggered(event: Any) {
        next!.invokeUserEventTriggered(event: event)
    }
    
    @discardableResult public func register(promise: Promise<Void>) -> Future<Void> {
        prev!.invokeRegister(promise: promise)
        return promise.futureResult
    }
    
    @discardableResult public func bind(local: SocketAddress, promise: Promise<Void>) -> Future<Void> {
        prev!.invokeBind(local: local, promise: promise)
        return promise.futureResult
    }
    
    @discardableResult public func connect(remote: SocketAddress, promise: Promise<Void>) -> Future<Void> {
        prev!.invokeBind(local: remote, promise: promise)
        return promise.futureResult
    }

    @discardableResult public func write(data: Any, promise: Promise<Void>) -> Future<Void> {
        prev!.invokeWrite(data: data, promise: promise)
        return promise.futureResult
    }
    
    @discardableResult public func writeAndFlush(data: Any, promise: Promise<Void>) -> Future<Void> {
        prev!.invokeWriteAndFlush(data: data, promise: promise)
        return promise.futureResult
    }
    
    public func flush() {
        prev!.invokeFlush()
    }
    
    public func read() {
        prev!.invokeRead()
    }
    
    @discardableResult public func close(promise: Promise<Void>) -> Future<Void> {
        prev!.invokeClose(promise: promise)
        return promise.futureResult
    }
    
    func invokeChannelRegistered() {
        assert(inEventLoop)
        
        do {
            try handler.channelRegistered(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    func invokeChannelUnregistered() {
        assert(inEventLoop)
        
        do {
            try handler.channelUnregistered(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    func invokeChannelActive() {
        assert(inEventLoop)
        
        do {
            try handler.channelActive(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    func invokeChannelInactive() {
        assert(inEventLoop)
        
        do {
            try handler.channelInactive(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    func invokeChannelRead(data: Any) {
        assert(inEventLoop)
        
        do {
            try handler.channelRead(ctx: self, data: data)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    func invokeChannelReadComplete() {
        assert(inEventLoop)
        
        do {
            try handler.channelReadComplete(ctx: self)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    func invokeChannelWritabilityChanged(writable: Bool) {
        assert(inEventLoop)
        
        do {
            try handler.channelWritabilityChanged(ctx: self, writable: writable)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    func invokeErrorCaught(error: Error) {
        assert(inEventLoop)
        
        do {
            try handler.errorCaught(ctx: self, error: error)
        } catch let err {
            // Forward the error thrown by errorCaught through the pipeline
            fireErrorCaught(error: err)
        }
    }
    
    func invokeUserEventTriggered(event: Any) {
        assert(inEventLoop)
        
        do {
            try handler.userEventTriggered(ctx: self, event: event)
        } catch let err {
            invokeErrorCaught(error: err)
        }
    }
    
    func invokeRegister(promise: Promise<Void>) {
        assert(inEventLoop)
        
        handler.register(ctx: self, promise: promise)
    }
    
    func invokeBind(local: SocketAddress, promise: Promise<Void>) {
        assert(inEventLoop)
        
        handler.bind(ctx: self, local: local, promise: promise)
    }
    
    func invokeConnect(remote: SocketAddress, promise: Promise<Void>) {
        assert(inEventLoop)
        
        handler.connect(ctx: self, remote: remote, promise: promise)
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
        try handler.handlerRemoved(ctx: self)
    }
    
    private var inEventLoop : Bool {
        return eventLoop.inEventLoop
    }
}

