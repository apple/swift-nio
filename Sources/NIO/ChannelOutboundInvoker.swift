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

public protocol OutboundData { }

public protocol ChannelOutboundInvoker {
    func register() -> Future<Void>
    @discardableResult func register(promise: Promise<Void>) -> Future<Void>
    func bind(local: SocketAddress) -> Future<Void>
    @discardableResult func bind(local: SocketAddress, promise: Promise<Void>) -> Future<Void>

    func connect(remote: SocketAddress) -> Future<Void>
    @discardableResult func connect(remote: SocketAddress, promise: Promise<Void>) -> Future<Void>
    
    @discardableResult func write<T: OutboundData>(data: T) -> Future<Void>
    @discardableResult func write<T: OutboundData>(data: T, promise: Promise<Void>) -> Future<Void>

    func flush()
    func read()
    
    func writeAndFlush<T: OutboundData>(data: T) -> Future<Void>
    @discardableResult func writeAndFlush<T: OutboundData>(data: T, promise: Promise<Void>) -> Future<Void>

    func close() -> Future<Void>
    @discardableResult func close(promise: Promise<Void>) -> Future<Void>
    
    var eventLoop: EventLoop { get }
}

public extension ChannelOutboundInvoker {
    public func register() -> Future<Void> {
        return register(promise: newVoidPromise())
    }
    
    public func bind(local: SocketAddress) -> Future<Void> {
        return bind(local: local, promise: newVoidPromise())
    }
    
    public func connect(remote: SocketAddress) -> Future<Void> {
        return connect(remote: remote, promise: newVoidPromise())
    }
    
    @discardableResult
    public func write<T: OutboundData>(data: T) -> Future<Void> {
        return write(data: data, promise: newVoidPromise())
    }
    
    @discardableResult
    public func writeAndFlush<T: OutboundData>(data: T) -> Future<Void> {
        return writeAndFlush(data: data, promise: newVoidPromise())
    }
    
    public func close() -> Future<Void> {
        return close(promise: newVoidPromise())
    }
    
    private func newVoidPromise() -> Promise<Void> {
        return eventLoop.newPromise(type: Void.self)
    }
}
