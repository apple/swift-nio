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

    #if !os(Windows)
        /// Request that the `MulticastChannel` join the multicast group given by `group` on the interface
        /// given by `interface`.
        ///
        /// - parameters:
        ///     - group: The IP address corresponding to the relevant multicast group.
        ///     - interface: The interface on which to join the given group, or `nil` to allow the kernel to choose.
        ///     - promise: The `EventLoopPromise` that will be notified once the operation is complete, or
        ///         `nil` if you are not interested in the result of the operation.
        @available(*, deprecated, renamed: "joinGroup(_:device:promise:)")
        func joinGroup(_ group: SocketAddress, interface: NIONetworkInterface?, promise: EventLoopPromise<Void>?)
    #endif

    /// Request that the `MulticastChannel` join the multicast group given by `group` on the device
    /// given by `device`.
    ///
    /// - parameters:
    ///     - group: The IP address corresponding to the relevant multicast group.
    ///     - device: The device on which to join the given group, or `nil` to allow the kernel to choose.
    ///     - promise: The `EventLoopPromise` that will be notified once the operation is complete, or
    ///         `nil` if you are not interested in the result of the operation.
    func joinGroup(_ group: SocketAddress, device: NIONetworkDevice?, promise: EventLoopPromise<Void>?)

    /// Request that the `MulticastChannel` leave the multicast group given by `group`.
    ///
    /// - parameters:
    ///     - group: The IP address corresponding to the relevant multicast group.
    ///     - promise: The `EventLoopPromise` that will be notified once the operation is complete, or
    ///         `nil` if you are not interested in the result of the operation.
    func leaveGroup(_ group: SocketAddress, promise: EventLoopPromise<Void>?)

    #if !os(Windows)
        /// Request that the `MulticastChannel` leave the multicast group given by `group` on the interface
        /// given by `interface`.
        ///
        /// - parameters:
        ///     - group: The IP address corresponding to the relevant multicast group.
        ///     - interface: The interface on which to leave the given group, or `nil` to allow the kernel to choose.
        ///     - promise: The `EventLoopPromise` that will be notified once the operation is complete, or
        ///         `nil` if you are not interested in the result of the operation.
        @available(*, deprecated, renamed: "leaveGroup(_:device:promise:)")
        func leaveGroup(_ group: SocketAddress, interface: NIONetworkInterface?, promise: EventLoopPromise<Void>?)
    #endif

    /// Request that the `MulticastChannel` leave the multicast group given by `group` on the device
    /// given by `device`.
    ///
    /// - parameters:
    ///     - group: The IP address corresponding to the relevant multicast group.
    ///     - device: The device on which to leave the given group, or `nil` to allow the kernel to choose.
    ///     - promise: The `EventLoopPromise` that will be notified once the operation is complete, or
    ///         `nil` if you are not interested in the result of the operation.
    func leaveGroup(_ group: SocketAddress, device: NIONetworkDevice?, promise: EventLoopPromise<Void>?)
}

// MARK: - Default implementations for MulticastChannel

public extension MulticastChannel {
    func joinGroup(_ group: SocketAddress, promise: EventLoopPromise<Void>?) {
        joinGroup(group, device: nil, promise: promise)
    }

    func joinGroup(_ group: SocketAddress) -> EventLoopFuture<Void> {
        let promise = eventLoop.makePromise(of: Void.self)
        joinGroup(group, promise: promise)
        return promise.futureResult
    }

    #if !os(Windows)
        @available(*, deprecated, renamed: "joinGroup(_:device:)")
        func joinGroup(_ group: SocketAddress, interface: NIONetworkInterface?) -> EventLoopFuture<Void> {
            let promise = eventLoop.makePromise(of: Void.self)
            joinGroup(group, interface: interface, promise: promise)
            return promise.futureResult
        }
    #endif

    func joinGroup(_ group: SocketAddress, device: NIONetworkDevice?) -> EventLoopFuture<Void> {
        let promise = eventLoop.makePromise(of: Void.self)
        joinGroup(group, device: device, promise: promise)
        return promise.futureResult
    }

    func leaveGroup(_ group: SocketAddress, promise: EventLoopPromise<Void>?) {
        leaveGroup(group, device: nil, promise: promise)
    }

    func leaveGroup(_ group: SocketAddress) -> EventLoopFuture<Void> {
        let promise = eventLoop.makePromise(of: Void.self)
        leaveGroup(group, promise: promise)
        return promise.futureResult
    }

    #if !os(Windows)
        @available(*, deprecated, renamed: "leaveGroup(_:device:)")
        func leaveGroup(_ group: SocketAddress, interface: NIONetworkInterface?) -> EventLoopFuture<Void> {
            let promise = eventLoop.makePromise(of: Void.self)
            leaveGroup(group, interface: interface, promise: promise)
            return promise.futureResult
        }
    #endif

    func leaveGroup(_ group: SocketAddress, device: NIONetworkDevice?) -> EventLoopFuture<Void> {
        let promise = eventLoop.makePromise(of: Void.self)
        leaveGroup(group, device: device, promise: promise)
        return promise.futureResult
    }
}

// MARK: - API Compatibility shims for MulticastChannel

public extension MulticastChannel {
    /// Request that the `MulticastChannel` join the multicast group given by `group` on the device
    /// given by `device`.
    ///
    /// - parameters:
    ///     - group: The IP address corresponding to the relevant multicast group.
    ///     - device: The device on which to join the given group, or `nil` to allow the kernel to choose.
    ///     - promise: The `EventLoopPromise` that will be notified once the operation is complete, or
    ///         `nil` if you are not interested in the result of the operation.
    func joinGroup(_: SocketAddress, device _: NIONetworkDevice?, promise: EventLoopPromise<Void>?) {
        // We just fail this in the default implementation. Users should override it.
        promise?.fail(NIOMulticastNotImplementedError())
    }

    /// Request that the `MulticastChannel` leave the multicast group given by `group` on the device
    /// given by `device`.
    ///
    /// - parameters:
    ///     - group: The IP address corresponding to the relevant multicast group.
    ///     - device: The device on which to leave the given group, or `nil` to allow the kernel to choose.
    ///     - promise: The `EventLoopPromise` that will be notified once the operation is complete, or
    ///         `nil` if you are not interested in the result of the operation.
    func leaveGroup(_: SocketAddress, device _: NIONetworkDevice?, promise: EventLoopPromise<Void>?) {
        // We just fail this in the default implementation. Users should override it.
        promise?.fail(NIOMulticastNotImplementedError())
    }
}
