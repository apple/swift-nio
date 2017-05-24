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

public protocol ChannelOutboundInvoker {
    func register() -> Future<Void>
    @discardableResult func register(promise: Promise<Void>) -> Future<Void>
    func bind(address: SocketAddress) -> Future<Void>
    @discardableResult func bind(address: SocketAddress, promise: Promise<Void>) -> Future<Void>

    func write(data: Any) -> Future<Void>
    @discardableResult func write(data: Any, promise: Promise<Void>) -> Future<Void>

    func flush()
    func read()
    
    func writeAndFlush(data: Any) -> Future<Void>
    @discardableResult func writeAndFlush(data: Any, promise: Promise<Void>) -> Future<Void>

    func close() -> Future<Void>
    @discardableResult func close(promise: Promise<Void>) -> Future<Void>
    
    var eventLoop: EventLoop { get }
}

public extension ChannelOutboundInvoker {
    public func register() -> Future<Void> {
        return register(promise: eventLoop.newPromise(type: Void.self))
    }
    
    public func bind(address: SocketAddress) -> Future<Void> {
        return bind(address: address, promise: eventLoop.newPromise(type: Void.self))
    }
    
    public func write(data: Any) -> Future<Void> {
        return write(data: data, promise: eventLoop.newPromise(type: Void.self))
    }
    
    public func writeAndFlush(data: Any) -> Future<Void> {
        return writeAndFlush(data: data, promise: eventLoop.newPromise(type: Void.self))
    }
    
    public func close() -> Future<Void> {
        return close(promise: eventLoop.newPromise(type: Void.self))
    }
}
