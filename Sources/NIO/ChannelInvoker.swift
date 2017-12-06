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
/// Allows users to invoke an "outbound" operation related to a `Channel` that will flow through the `ChannelPipeline` until
/// it will finally be executed by the the `Channel.Unsafe` implementation.
public protocol ChannelOutboundInvoker {
    
    /// Register on an `EventLoop` and so have all its IO handled.
    ///
    /// - returns: the future which will be notified once the operation completes.
    func register() -> EventLoopFuture<Void>
    
    /// Register on an `EventLoop` and so have all its IO handled.
    ///
    /// - parameters:
    ///       - promise: the `EventLoopPromise` that will be notified once the operation completes,
    ///                  or `nil` if not interested in the outcome of the operation.
    func register(promise: EventLoopPromise<Void>?)
    
    /// Bind to a `SocketAddress`.
    /// - parameters:
    ///       - to: the `SocketAddress` to which we should bind the `Channel`.
    /// - returns: the future which will be notified once the operation completes.
    func bind(to: SocketAddress) -> EventLoopFuture<Void>
    
    /// Bind to a `SocketAddress`.
    /// - parameters:
    ///       - to: the `SocketAddress` to which we should bind the `Channel`.
    ///       - promise: the `EventLoopPromise` that will be notified once the operation completes,
    ///                  or `nil` if not interested in the outcome of the operation.
    func bind(to: SocketAddress, promise: EventLoopPromise<Void>?)

    /// Connect to a `SocketAddress`.
    /// - parameters:
    ///       - to: the `SocketAddress` to which we should connect the `Channel`.
    /// - returns: the future which will be notified once the operation completes.
    func connect(to: SocketAddress) -> EventLoopFuture<Void>
    
    /// Connect to a `SocketAddress`.
    /// - parameters:
    ///       - to: the `SocketAddress` to which we should connect the `Channel`.
    ///       - promise: the `EventLoopPromise` that will be notified once the operation completes,
    ///                  or `nil` if not interested in the outcome of the operation.
    func connect(to: SocketAddress, promise: EventLoopPromise<Void>?)
    
    /// Write data to the remote peer.
    ///
    /// Be aware that to be sure that data is really written to the remote peer you need to call `flush` or use `writeAndFlush`.
    /// Calling `write` multiple times and then `flush` may allow the `Channel` to `write` multiple data objects to the remote peer with one syscall.
    ///
    /// - parameters:
    ///       - data: the data to write
    /// - returns: the future which will be notified once the operation completes.
    func write(data: NIOAny) -> EventLoopFuture<Void>
   
    /// Write data to the remote peer.
    ///
    /// Be aware that to be sure that data is really written to the remote peer you need to call `flush` or use `writeAndFlush`.
    /// Calling `write` multiple times and then `flush` may allow the `Channel` to `write` multiple data objects to the remote peer with one syscall.
    ///
    /// - parameters:
    ///       - data: the data to write
    ///       - promise: the `EventLoopPromise` that will be notified once the operation completes,
    ///                  or `nil` if not interested in the outcome of the operation.
    func write(data: NIOAny, promise: EventLoopPromise<Void>?)

    /// Flush data that was previously written via `write` to the remote peer.
    ///
    /// - returns: the future which will be notified once the operation completes.
    func flush() -> EventLoopFuture<Void>
    
    /// Flush data that was previously written via `write` to the remote peer.
    ///
    /// - parameters:
    ///       - promise: the `EventLoopPromise` that will be notified once the operation completes,
    ///                  or `nil` if not interested in the outcome of the operation.
    func flush(promise: EventLoopPromise<Void>?)

    /// Shortcut for calling `write` and `flush`.
    ///
    /// - parameters:
    ///       - data: the data to write
    /// - returns: the future which will be notified once the operation completes.
    func writeAndFlush(data: NIOAny) -> EventLoopFuture<Void>
    
    /// Shortcut for calling `write` and `flush`.
    ///
    /// - parameters:
    ///       - data: the data to write
    ///       - promise: the `EventLoopPromise` that will be notified once the operation completes,
    ///                  or `nil` if not interested in the outcome of the operation.
    func writeAndFlush(data: NIOAny, promise: EventLoopPromise<Void>?)
    
    /// Signal that we want to read from the `Channel` once there is data ready.
    ///
    /// If `ChannelOptions.AutoRead` is set for a `Channel` (which is the default) this method is automatically invoked by the transport implementation,
    /// otherwise it's the user's responsibility to call this method manually once new data should be read and processed.
    ///
    /// - returns: the future which will be notified once the operation completes.
    func read() -> EventLoopFuture<Void>
    
    /// Signal that we want to read from the `Channel` once there is data ready.
    ///
    /// If `ChannelOptions.AutoRead` is set for a `Channel` (which is the default) this method is automatically invoked by the transport implementation,
    /// otherwise it's the user's responsibility to call this method manually once new data should be read and processed.
    ///
    /// - parameters:
    ///       - promise: the `EventLoopPromise` that will be notified once the operation completes,
    ///                  or `nil` if not interested in the outcome of the operation.
    func read(promise: EventLoopPromise<Void>?)

    /// Close the `Channel` and so the connection if one exists.
    ///
    /// - returns: the future which will be notified once the operation completes.
    func close() -> EventLoopFuture<Void>
    
    /// Close the `Channel` and so the connection if one exists.
    ///
    /// - parameters:
    ///       - promise: the `EventLoopPromise` that will be notified once the operation completes,
    ///                  or `nil` if not interested in the outcome of the operation.
    func close(promise: EventLoopPromise<Void>?)
    
    /// Trigger a custom user outbound event which will flow through the `ChannelPipeline`.
    ///
    /// - parameters:
    ///       - event: the event itself.
    /// - returns: the future which will be notified once the operation completes.
    func triggerUserOutboundEvent(event: Any) -> EventLoopFuture<Void>
    
    /// Trigger a custom user outbound event which will flow through the `ChannelPipeline`.
    ///
    /// - parameters:
    ///       - promise: the `EventLoopPromise` that will be notified once the operation completes,
    ///                  or `nil` if not interested in the outcome of the operation.
    func triggerUserOutboundEvent(event: Any, promise: EventLoopPromise<Void>?)
    
    /// The `EventLoop` which is used by this `ChannelOutboundInvoker` for execution.
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

/// Fire inbound events related to a `Channel` through the `ChannelPipeline` until its end is reached or it's consumed by a `ChannelHandler`.
public protocol ChannelInboundInvoker {
 
    /// Called once a `Channel` was registered to its `EventLoop` and so IO will be processed.
    func fireChannelRegistered()
    
    /// Called once a `Channel` was unregistered from its `EventLoop` which means no IO will be handled for a `Channel` anymore.
    func fireChannelUnregistered()
    
    /// Called once a `Channel` becomes active.
    ///
    /// What active means depends on the `Channel` implementation and semantics.
    /// For example for TCP it means the `Channel` is connected to the remote peer.
    func fireChannelActive()
    
    /// Called once a `Channel` becomes inactive.
    ///
    /// What inactive means depends on the `Channel` implementation and semantics.
    /// For example for TCP it means the `Channel` was disconnected from the remote peer and closed.
    func fireChannelInactive()
    
    /// Called once there is some data read for a `Channel` that needs processing.
    ///
    /// - parameters:
    ///       - data: the data that was read and is ready to be processed.
    func fireChannelRead(data: NIOAny)
    
    /// Called once there is no more data to read immediately on a `Channel`. Any new data received will be handled later.
    func fireChannelReadComplete()
    
    /// Called when a `Channel`'s writable state changes.
    ///
    /// The writability state of a Channel depends on watermarks that can be set via `Channel.setOption` and how much data
    /// is still waiting to be transferred to the remote peer.
    /// You should take care to enforce some kind of backpressure if the channel becomes unwritable which means `Channel.isWritable`
    /// will return `false` to ensure you do not consume too much memory due to queued writes. What exactly you should do here depends on the
    /// protocol and other semantics. But for example you may want to stop writing to the `Channel` until `Channel.writable` becomes
    /// `true` again or stop reading at all.
    func fireChannelWritabilityChanged()
    
    /// Called when an inbound operation `Error` was caught.
    ///
    /// Be aware that for inbound operations this method is called while for outbound operations defined in `ChannelOutboundInvoker`
    /// the `EventLoopFuture` or `EventLoopPromise` will be notified.
    ///
    /// - parameters:
    ///       - error: the error we encountered.
    func fireErrorCaught(error: Error)
    
    /// Trigger a custom user inbound event which will flow through the `ChannelPipeline`.
    ///
    /// - parameters:
    ///       - event: the event itself.
    func fireUserInboundEventTriggered(event: Any)
}

/// A protocol that signals that outbound and inbound events are triggered by this invoker.
public protocol ChannelInvoker : ChannelOutboundInvoker, ChannelInboundInvoker { }
