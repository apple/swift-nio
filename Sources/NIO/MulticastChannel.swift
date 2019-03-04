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

/// A `MulticastChannel` is a `Channel` that supports IP multicast operations: that is, a channel that can join multicast
/// groups.
///
/// - note: As with `Channel`, all operations on a `MulticastChannel` are thread-safe.
public protocol MulticastChannel: Channel {
    /// Request that the `MulticastChannel` join the multicast group given by `group`.
    ///
    /// - parameters:
    ///     - group: The IP address corresponding to the relevant multicast group.
    ///     - promise: The `EventLoopPromise` that will be notified once the operation is complete, or
    ///         `nil` if you are not interested in the result of the operation.
    func joinGroup(_ group: SocketAddress, promise: EventLoopPromise<Void>?)

    /// Request that the `MulticastChannel` join the multicast group given by `group` on the interface
    /// given by `interface`.
    ///
    /// - parameters:
    ///     - group: The IP address corresponding to the relevant multicast group.
    ///     - interface: The interface on which to join the given group, or `nil` to allow the kernel to choose.
    ///     - promise: The `EventLoopPromise` that will be notified once the operation is complete, or
    ///         `nil` if you are not interested in the result of the operation.
    func joinGroup(_ group: SocketAddress, interface: NIONetworkInterface?, promise: EventLoopPromise<Void>?)

    /// Request that the `MulticastChannel` leave the multicast group given by `group`.
    ///
    /// - parameters:
    ///     - group: The IP address corresponding to the relevant multicast group.
    ///     - promise: The `EventLoopPromise` that will be notified once the operation is complete, or
    ///         `nil` if you are not interested in the result of the operation.
    func leaveGroup(_ group: SocketAddress, promise: EventLoopPromise<Void>?)

    /// Request that the `MulticastChannel` leave the multicast group given by `group` on the interface
    /// given by `interface`.
    ///
    /// - parameters:
    ///     - group: The IP address corresponding to the relevant multicast group.
    ///     - interface: The interface on which to leave the given group, or `nil` to allow the kernel to choose.
    ///     - promise: The `EventLoopPromise` that will be notified once the operation is complete, or
    ///         `nil` if you are not interested in the result of the operation.
    func leaveGroup(_ group: SocketAddress, interface: NIONetworkInterface?, promise: EventLoopPromise<Void>?)
}


// MARK:- Default implementations for MulticastChannel
extension MulticastChannel {
    public func joinGroup(_ group: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.joinGroup(group, interface: nil, promise: promise)
    }

    public func joinGroup(_ group: SocketAddress) -> EventLoopFuture<Void> {
        let promise = self.eventLoop.makePromise(of: Void.self)
        self.joinGroup(group, promise: promise)
        return promise.futureResult
    }

    public func joinGroup(_ group: SocketAddress, interface: NIONetworkInterface?) -> EventLoopFuture<Void> {
        let promise = self.eventLoop.makePromise(of: Void.self)
        self.joinGroup(group, interface: interface, promise: promise)
        return promise.futureResult
    }

    public func leaveGroup(_ group: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.leaveGroup(group, interface: nil, promise: promise)
    }

    public func leaveGroup(_ group: SocketAddress) -> EventLoopFuture<Void> {
        let promise = self.eventLoop.makePromise(of: Void.self)
        self.leaveGroup(group, promise: promise)
        return promise.futureResult
    }

    public func leaveGroup(_ group: SocketAddress, interface: NIONetworkInterface?) -> EventLoopFuture<Void> {
        let promise = self.eventLoop.makePromise(of: Void.self)
        self.leaveGroup(group, interface: interface, promise: promise)
        return promise.futureResult
    }
}
