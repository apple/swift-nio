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
    func bind(local: SocketAddress) -> Future<Void>
    func bind(local: SocketAddress, promise: Promise<Void>?)
    
    func connect(remote: SocketAddress) -> Future<Void>
    func connect(remote: SocketAddress, promise: Promise<Void>?)
    
    func write(data: IOData) -> Future<Void>
    func write(data: IOData, promise: Promise<Void>?)
    
    func flush()
    func read()
    
    func writeAndFlush(data: IOData) -> Future<Void>
    func writeAndFlush(data: IOData, promise: Promise<Void>?)
    
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
    
    public func bind(local: SocketAddress) -> Future<Void> {
        let promise = newPromise()
        bind(local: local, promise: promise)
        return promise.futureResult
    }
    
    public func connect(remote: SocketAddress) -> Future<Void> {
        let promise = newPromise()
        connect(remote: remote, promise: promise)
        return promise.futureResult
    }
    
    public func write(data: IOData) -> Future<Void> {
        let promise = newPromise()
        write(data: data, promise: promise)
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
