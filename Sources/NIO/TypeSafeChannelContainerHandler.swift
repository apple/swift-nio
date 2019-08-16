//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//


public protocol TypeSafeChannelHandler {
    associatedtype InboundIn
    associatedtype InboundOut
    associatedtype OutboundIn
    associatedtype OutboundOut

    typealias Context = TypeSafeChannelContext<InboundIn, InboundOut, OutboundIn, OutboundOut>

    var asTypeUnsafes: [ChannelHandler] { get }

    func handlerAdded(context: Context)

    func handlerRemoved(context: Context)

    func channelRegistered(context: Context)

    func channelUnregistered(context: Context)

    func channelActive(context: Context)

    func channelInactive(context: Context)

    func channelRead(context: Context, data: InboundIn)

    func channelReadComplete(context: Context)

    func channelWritabilityChanged(context: Context)

    func userInboundEventTriggered(context: Context, event: Any)

    func errorCaught(context: Context, error: Error)

    func register(context: Context, promise: EventLoopPromise<Void>?)

    func bind(context: Context, to: SocketAddress, promise: EventLoopPromise<Void>?)

    func connect(context: Context, to: SocketAddress, promise: EventLoopPromise<Void>?)

    func write(context: Context, data: OutboundIn, promise: EventLoopPromise<Void>?)

    func flush(context: Context)

    func read(context: Context)

    func close(context: Context, mode: CloseMode, promise: EventLoopPromise<Void>?)

    func triggerUserOutboundEvent(context: Context, event: Any, promise: EventLoopPromise<Void>?)
}

extension TypeSafeChannelHandler {
    public func handlerAdded(context: Context) {
    }

    public func handlerRemoved(context: Context) {
    }

    public func channelRegistered(context: Context) {
        context.fireChannelRegistered()
    }

    public func channelUnregistered(context: Context) {
        context.fireChannelUnregistered()
    }

    public func channelActive(context: Context) {
        context.fireChannelActive()
    }

    public func channelInactive(context: Context) {
        context.fireChannelInactive()
    }

    public func channelReadComplete(context: Context) {
        context.fireChannelReadComplete()
    }

    public func channelWritabilityChanged(context: Context) {
        context.fireChannelWritabilityChanged()
    }

    public func userInboundEventTriggered(context: Context, event: Any) {
        context.fireUserInboundEventTriggered(event)
    }

    public func errorCaught(context: Context, error: Error) {
        context.fireErrorCaught(error)
    }

    public func register(context: Context, promise: EventLoopPromise<Void>?) {
        context.register(promise: promise)
    }

    public func bind(context: Context, to: SocketAddress, promise: EventLoopPromise<Void>?) {
        context.bind(to: to, promise: promise)
    }

    public func connect(context: Context, to: SocketAddress, promise: EventLoopPromise<Void>?) {
        context.connect(to: to, promise: promise)
    }

    public func flush(context: Context) {
        context.flush()
    }

    public func read(context: Context) {
        context.read()
    }

    public func close(context: Context, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        context.close(mode: mode, promise: promise)
    }

    public func triggerUserOutboundEvent(context: Context, event: Any, promise: EventLoopPromise<Void>?) {
        context.triggerUserOutboundEvent(event, promise: promise)
    }
}

extension TypeSafeChannelHandler where InboundIn == InboundOut {
    public func channelRead(context: Context, data: InboundIn) {
        context.fireChannelRead(data)
    }
}

extension TypeSafeChannelHandler where InboundIn == Never {
    public func channelRead(context: Context, data: InboundIn) {
        // can't precondition here that this doesn't happen because it would warn that it will never be executed.
    }
}

extension TypeSafeChannelHandler where OutboundIn == Never {
    public func write(context: Context, data: OutboundIn, promise: EventLoopPromise<Void>?) {
        // can't precondition here that this doesn't happen because it would warn that it will never be executed.
    }
}

extension TypeSafeChannelHandler where OutboundIn == OutboundOut {
    public func write(context: Context, data: OutboundIn, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
    }
}

public class TypeSafeChannelContainerHandler<Handler: TypeSafeChannelHandler,
    /*                                        */ InboundIn, InboundOut, OutboundIn, OutboundOut>
    /*                                        */ where Handler.InboundIn == InboundIn, Handler.InboundOut == InboundOut,
/*                                            */ Handler.OutboundIn == OutboundIn, Handler.OutboundOut == OutboundOut {
    private let handler: Handler
    private var context: TypeSafeChannelContext<InboundIn, InboundOut, OutboundIn, OutboundOut>!

    public init(_ handler: Handler) {
        self.handler = handler
    }
}

extension TypeSafeChannelContainerHandler: ChannelDuplexHandler {
    public final func handlerAdded(context: ChannelHandlerContext) {
        self.context = TypeSafeChannelContext(eventLoop: context.eventLoop, context: context)
    }

    public final func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    public final func channelRegistered(context: ChannelHandlerContext) {
        self.handler.channelRegistered(context: self.context)
    }

    public final func channelUnregistered(context: ChannelHandlerContext) {
        self.handler.channelUnregistered(context: self.context)
    }

    public final func channelActive(context: ChannelHandlerContext) {
        self.handler.channelActive(context: self.context)
    }

    public final func channelInactive(context: ChannelHandlerContext) {
        self.handler.channelInactive(context: self.context)
    }

    public final func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.handler.channelRead(context: self.context, data: self.unwrapInboundIn(data))
    }

    public final func channelReadComplete(context: ChannelHandlerContext) {
        self.handler.channelReadComplete(context: self.context)
    }

    public final func channelWritabilityChanged(context: ChannelHandlerContext) {
        self.handler.channelWritabilityChanged(context: self.context)
    }

    public final func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        self.handler.userInboundEventTriggered(context: self.context, event: event)
    }

    public final func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.handler.errorCaught(context: self.context, error: error)
    }

    public final func register(context: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        self.handler.register(context: self.context, promise: promise)
    }

    public final func bind(context: ChannelHandlerContext, to: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.handler.bind(context: self.context, to: to, promise: promise)
    }

    public final func connect(context: ChannelHandlerContext, to: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.handler.connect(context: self.context, to: to, promise: promise)
    }

    public final func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.handler.write(context: self.context, data: self.unwrapOutboundIn(data), promise: promise)
    }

    public final func flush(context: ChannelHandlerContext) {
        self.handler.flush(context: self.context)
    }

    public final func read(context: ChannelHandlerContext) {
        self.handler.read(context: self.context)
    }

    public final func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        self.handler.close(context: self.context, mode: mode, promise: promise)
    }

    public final func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        self.handler.triggerUserOutboundEvent(context: self.context, event: event, promise: promise)
    }
}

public class TypeSafeChannelContext<InboundIn, InboundOut, OutboundIn, OutboundOut> {
    public let eventLoop: EventLoop

    @usableFromInline
    internal let context: ChannelHandlerContext

    internal init(eventLoop: EventLoop, context: ChannelHandlerContext) {
        self.eventLoop = eventLoop
        self.context = context
    }

    @inlinable
    public func fireChannelRegistered() {
        self.context.fireChannelRegistered()
    }

    @inlinable
    public func fireChannelUnregistered() {
        self.context.fireChannelUnregistered()
    }

    @inlinable
    public func fireChannelActive() {
        self.context.fireChannelActive()
    }

    @inlinable
    public func fireChannelInactive() {
        self.context.fireChannelInactive()
    }

    @inlinable
    public func fireChannelRead(_ data: InboundOut) {
        self.context.fireChannelRead(NIOAny(data))
    }

    @inlinable
    public func fireChannelReadComplete() {
        self.context.fireChannelReadComplete()
    }

    @inlinable
    public func fireChannelWritabilityChanged() {
        self.context.fireChannelWritabilityChanged()
    }

    @inlinable
    public func fireErrorCaught(_ error: Error) {
        self.context.fireErrorCaught(error)
    }

    @inlinable
    public func fireUserInboundEventTriggered(_ event: Any) {
        self.context.fireUserInboundEventTriggered(event)
    }

    @inlinable
    public func register(promise: EventLoopPromise<Void>?) {
        self.context.register(promise: promise)
    }

    @inlinable
    public func bind(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.context.bind(to: to, promise: promise)
    }

    @inlinable
    public func connect(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.context.connect(to: to, promise: promise)
    }

    @inlinable
    public func write(_ data: OutboundOut, promise: EventLoopPromise<Void>?) {
        self.context.write(NIOAny(data), promise: promise)
    }

    @inlinable
    public func flush() {
        self.context.flush()
    }

    @inlinable
    public func writeAndFlush(_ data: OutboundOut, promise: EventLoopPromise<Void>?) {
        self.context.writeAndFlush(NIOAny(data), promise: promise)
    }

    @inlinable
    public func read() {
        self.context.read()
    }

    @inlinable
    public func close(mode: CloseMode = .all, promise: EventLoopPromise<Void>?) {
        self.context.close(mode: mode, promise: promise)
    }

    @inlinable
    public func triggerUserOutboundEvent(_ event: Any, promise: EventLoopPromise<Void>?) {
        self.context.triggerUserOutboundEvent(event, promise: promise)
    }
}

extension TypeSafeChannelHandler {
    public var asTypeUnsafes: [ChannelHandler] {
        return [TypeSafeChannelContainerHandler(self)]
    }
}

public struct ChannelHandlerPair<L: TypeSafeChannelHandler, R: TypeSafeChannelHandler>: TypeSafeChannelHandler where L.InboundOut == R.InboundIn, R.OutboundOut == L.OutboundIn {
    public typealias InboundIn = L.InboundIn
    public typealias InboundOut = R.InboundOut
    public typealias OutboundIn = R.OutboundIn
    public typealias OutboundOut = L.OutboundOut

    let left: L
    let right: R

    public var asTypeUnsafes: [ChannelHandler] {
        self.left.asTypeUnsafes + self.right.asTypeUnsafes
    }

    public func channelRead(context: TypeSafeChannelContext<L.InboundIn, R.InboundOut, R.OutboundIn, L.OutboundOut>, data: L.InboundIn) {
        preconditionFailure()
    }

    public func write(context: TypeSafeChannelContext<L.InboundIn, R.InboundOut, R.OutboundIn, L.OutboundOut>, data: R.OutboundIn, promise: EventLoopPromise<Void>?) {
        preconditionFailure()
    }
}

infix operator <==>: AdditionPrecedence

class TestHandler<A,B,C,D>: TypeSafeChannelHandler {
    typealias InboundIn = A
    typealias InboundOut = B
    typealias OutboundIn = C
    typealias OutboundOut = D

    func channelRead(context: TypeSafeChannelContext<A, B, C, D>, data: A) {
    }

    func write(context: TypeSafeChannelContext<A, B, C, D>, data: C, promise: EventLoopPromise<Void>?) {
    }
}

public func <==> <L: TypeSafeChannelHandler, R: TypeSafeChannelHandler> (lhs: L, rhs: R) -> ChannelHandlerPair<L, R> {
    return .init(left: lhs, right: rhs)
}

let multiHandler = TestHandler<Int, Int, Int, Int>() <==>
    TestHandler<Int, Int, Int, Int>() <==>
    TestHandler<Int, Int, Int, Int>() <==>
    TestHandler<Int, Float, Float, Int>() <==>
    TestHandler<Float, String, Int, Float>()

extension ChannelPipeline {
    public func addHandler<L, R>(_ handler: ChannelHandlerPair<L, R>,
                                 name: String? = nil,
                                 position: ChannelPipeline.Position = .last) -> EventLoopFuture<Void> {
        self.addHandlers(handler.asTypeUnsafes, position: position)
    }
}
