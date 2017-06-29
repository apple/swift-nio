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
import Sockets

public protocol ChannelOutboundInvoker {
    func register() -> Future<Void>
    func register(promise: Promise<Void>?)

    func bind(to: SocketAddress) -> Future<Void>
    func bind(to: SocketAddress, promise: Promise<Void>?)

    func connect(to: SocketAddress) -> Future<Void>
    func connect(to: SocketAddress, promise: Promise<Void>?)
    
    func write(data: IOData) -> Future<Void>
    func write(data: IOData, promise: Promise<Void>?)

    func flush() -> Future<Void>
    func flush(promise: Promise<Void>?)

    func writeAndFlush(data: IOData) -> Future<Void>
    func writeAndFlush(data: IOData, promise: Promise<Void>?)
    
    func read() -> Future<Void>
    func read(promise: Promise<Void>?)

    func close() -> Future<Void>
    func close(promise: Promise<Void>?)

    var eventLoop: EventLoop { get }
}

public extension ChannelOutboundInvoker {
    public func register() -> Future<Void> {
        let promise = newPromise()
        register(promise: promise)
        return promise.futureResult
    }
    
    public func bind(to address: SocketAddress) -> Future<Void> {
        let promise = newPromise()
        bind(to: address, promise: promise)
        return promise.futureResult
    }
    
    public func connect(to address: SocketAddress) -> Future<Void> {
        let promise = newPromise()
        connect(to: address, promise: promise)
        return promise.futureResult
    }
    
    public func write(data: IOData) -> Future<Void> {
        let promise = newPromise()
        write(data: data, promise: promise)
        return promise.futureResult
    }
    
    public func read() -> Future<Void> {
        let promise = newPromise()
        read(promise: promise)
        return promise.futureResult
    }
    
    public func flush() -> Future<Void> {
        let promise = newPromise()
        flush(promise: promise)
        return promise.futureResult
    }
    
    public func writeAndFlush(data: IOData) -> Future<Void> {
        let promise = newPromise()
        writeAndFlush(data: data, promise: promise)
        return promise.futureResult
    }
    
    public func close() -> Future<Void> {
        let promise = newPromise()
        close(promise: promise)
        return promise.futureResult
    }
    
    private func newPromise() -> Promise<Void> {
        return eventLoop.newPromise()
    }
}

public protocol ChannelInboundInvoker {
    
    func fireChannelRegistered()
    
    func fireChannelUnregistered()
    
    func fireChannelActive()
    
    func fireChannelInactive()
    
    func fireChannelRead(data: IOData)
    
    func fireChannelReadComplete()
    
    func fireChannelWritabilityChanged()
    
    func fireErrorCaught(error: Error)
    
    func fireUserEventTriggered(event: Any)
}

public protocol ChannelInvoker : ChannelOutboundInvoker, ChannelInboundInvoker { }
