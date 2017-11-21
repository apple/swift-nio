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
public protocol ChannelOutboundInvoker {
    func register() -> EventLoopFuture<Void>
    func register(promise: EventLoopPromise<Void>?)

    func bind(to: SocketAddress) -> EventLoopFuture<Void>
    func bind(to: SocketAddress, promise: EventLoopPromise<Void>?)

    func connect(to: SocketAddress) -> EventLoopFuture<Void>
    func connect(to: SocketAddress, promise: EventLoopPromise<Void>?)
    
    func write(data: NIOAny) -> EventLoopFuture<Void>
    func write(data: NIOAny, promise: EventLoopPromise<Void>?)

    func flush() -> EventLoopFuture<Void>
    func flush(promise: EventLoopPromise<Void>?)

    func writeAndFlush(data: NIOAny) -> EventLoopFuture<Void>
    func writeAndFlush(data: NIOAny, promise: EventLoopPromise<Void>?)
    
    func read() -> EventLoopFuture<Void>
    func read(promise: EventLoopPromise<Void>?)

    func close() -> EventLoopFuture<Void>
    func close(promise: EventLoopPromise<Void>?)
    
    func triggerUserOutboundEvent(event: Any) -> EventLoopFuture<Void>
    func triggerUserOutboundEvent(event: Any, promise: EventLoopPromise<Void>?)
    
    var eventLoop: EventLoop { get }
}

extension ChannelOutboundInvoker {
    public func register() -> EventLoopFuture<Void> {
        let promise = newPromise()
        register(promise: promise)
        return promise.futureResult
    }
    
    public func bind(to address: SocketAddress) -> EventLoopFuture<Void> {
        let promise = newPromise()
        bind(to: address, promise: promise)
        return promise.futureResult
    }
    
    public func connect(to address: SocketAddress) -> EventLoopFuture<Void> {
        let promise = newPromise()
        connect(to: address, promise: promise)
        return promise.futureResult
    }
    
    public func write(data: NIOAny) -> EventLoopFuture<Void> {
        let promise = newPromise()
        write(data: data, promise: promise)
        return promise.futureResult
    }
    
    public func read() -> EventLoopFuture<Void> {
        let promise = newPromise()
        read(promise: promise)
        return promise.futureResult
    }
    
    public func flush() -> EventLoopFuture<Void> {
        let promise = newPromise()
        flush(promise: promise)
        return promise.futureResult
    }
    
    public func writeAndFlush(data: NIOAny) -> EventLoopFuture<Void> {
        let promise = newPromise()
        writeAndFlush(data: data, promise: promise)
        return promise.futureResult
    }
    
    public func close() -> EventLoopFuture<Void> {
        let promise = newPromise()
        close(promise: promise)
        return promise.futureResult
    }
    
    public func triggerUserOutboundEvent(event: Any) -> EventLoopFuture<Void> {
        let promise = newPromise()
        triggerUserOutboundEvent(event: event, promise: promise)
        return promise.futureResult
    }
    
    private func newPromise() -> EventLoopPromise<Void> {
        return eventLoop.newPromise()
    }
}

public protocol ChannelInboundInvoker {
    
    func fireChannelRegistered()
    
    func fireChannelUnregistered()
    
    func fireChannelActive()
    
    func fireChannelInactive()
    
    func fireChannelRead(data: NIOAny)
    
    func fireChannelReadComplete()
    
    func fireChannelWritabilityChanged()
    
    func fireErrorCaught(error: Error)
    
    func fireUserInboundEventTriggered(event: Any)
}

public protocol ChannelInvoker : ChannelOutboundInvoker, ChannelInboundInvoker { }
