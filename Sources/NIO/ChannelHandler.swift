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

/// Base protocol for handlers that handle I/O events or intercept an I/O operation.
///
/// All methods are called from within the `EventLoop` that is assigned to the `Channel` itself.
//
/// You should _never_ implement this protocol directly. Please implement one of its sub-protocols.
public protocol ChannelHandler: class {
    /// Called when this `ChannelHandler` is added to the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func handlerAdded(ctx: ChannelHandlerContext)

    /// Called when this `ChannelHandler` is removed from the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func handlerRemoved(ctx: ChannelHandlerContext)
}

/// Untyped `ChannelHandler` which handles outbound I/O events or intercept an outbound I/O operation.
///
/// Despite the fact that `write` is one of the methods on this `protocol`, you should avoid assuming that "outbound" events are to do with
/// writing to channel sources. Instead, "outbound" events are events that are passed *to* the channel source (e.g. a socket): that is, things you tell
/// the channel source to do. That includes `write` ("write this data to the channel source"), but it also includes `read` ("please begin attempting to read from
/// the channel source") and `bind` ("please bind the following address"), which have nothing to do with sending data.
///
/// We _strongly_ advise against implementing this protocol directly. Please implement `ChannelOutboundHandler`.
public protocol _ChannelOutboundHandler: ChannelHandler {

    /// Called to request that the `Channel` register itself for I/O events with its `EventLoop`.
    /// This should call `ctx.register` to forward the operation to the next `_ChannelOutboundHandler` in the `ChannelPipeline` or
    /// complete the `EventLoopPromise` to let the caller know that the operation completed.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func register(ctx: ChannelHandlerContext, promise: EventLoopPromise<Void>?)

    /// Called to request that the `Channel` bind to a specific `SocketAddress`.
    ///
    /// This should call `ctx.bind` to forward the operation to the next `_ChannelOutboundHandler` in the `ChannelPipeline` or
    /// complete the `EventLoopPromise` to let the caller know that the operation completed.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///     - to: The `SocketAddress` to which this `Channel` should bind.
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func bind(ctx: ChannelHandlerContext, to: SocketAddress, promise: EventLoopPromise<Void>?)

    /// Called to request that the `Channel` connect to a given `SocketAddress`.
    ///
    /// This should call `ctx.connect` to forward the operation to the next `_ChannelOutboundHandler` in the `ChannelPipeline` or
    /// complete the `EventLoopPromise` to let the caller know that the operation completed.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///     - to: The `SocketAddress` to which the the `Channel` should connect.
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func connect(ctx: ChannelHandlerContext, to: SocketAddress, promise: EventLoopPromise<Void>?)

    /// Called to request a write operation. The write operation will write the messages through the
    /// `ChannelPipeline`. Those are then ready to be flushed to the actual `Channel` when
    /// `Channel.flush` or `ChannelHandlerContext.flush` is called.
    ///
    /// This should call `ctx.write` to forward the operation to the next `_ChannelOutboundHandler` in the `ChannelPipeline` or
    /// complete the `EventLoopPromise` to let the caller know that the operation completed.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///     - data: The data to write through the `Channel`, wrapped in a `NIOAny`.
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?)

    /// Called to request that the `Channel` flush all pending writes. The flush operation will try to flush out all previous written messages
    /// that are pending.
    ///
    /// This should call `ctx.flush` to forward the operation to the next `_ChannelOutboundHandler` in the `ChannelPipeline` or just
    /// discard it if the flush should be suppressed.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func flush(ctx: ChannelHandlerContext)

    /// Called to request that the `Channel` perform a read when data is ready. The read operation will signal that we are ready to read more data.
    ///
    /// This should call `ctx.read` to forward the operation to the next `_ChannelOutboundHandler` in the `ChannelPipeline` or just
    /// discard it if the flush should be suppressed.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func read(ctx: ChannelHandlerContext)

    /// Called to request that the `Channel` close itself down`.
    ///
    /// This should call `ctx.close` to forward the operation to the next `_ChannelOutboundHandler` in the `ChannelPipeline` or
    /// complete the `EventLoopPromise` to let the caller know that the operation completed.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///     - mode: The `CloseMode` to apply
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func close(ctx: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?)

    /// Called when an user outbound event is triggered.
    ///
    /// This should call `ctx.triggerUserOutboundEvent` to forward the operation to the next `_ChannelOutboundHandler` in the `ChannelPipeline` or
    /// complete the `EventLoopPromise` to let the caller know that the operation completed.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///     - event: The triggered event.
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func triggerUserOutboundEvent(ctx: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?)
}

/// Untyped `ChannelHandler` which handles inbound I/O events.
///
/// Despite the fact that `channelRead` is one of the methods on this `protocol`, you should avoid assuming that "inbound" events are to do with
/// reading from channel sources. Instead, "inbound" events are events that originate *from* the channel source (e.g. the socket): that is, events that the
/// channel source tells you about. This includes things like `channelRead` ("there is some data to read"), but it also includes things like
/// `channelWritabilityChanged` ("this source is no longer marked writable").
///
/// We _strongly_ advise against implementing this protocol directly. Please implement `ChannelInboundHandler`.
public protocol _ChannelInboundHandler: ChannelHandler {

    /// Called when the `Channel` has successfully registered with its `EventLoop` to handle I/O.
    ///
    /// This should call `ctx.fireChannelRegistered` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func channelRegistered(ctx: ChannelHandlerContext)

    /// Called when the `Channel` has unregistered from its `EventLoop`, and so will no longer be receiving I/O events.
    ///
    /// This should call `ctx.fireChannelUnregistered` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func channelUnregistered(ctx: ChannelHandlerContext)

    /// Called when the `Channel` has become active, and is able to send and receive data.
    ///
    /// This should call `ctx.fireChannelActive` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func channelActive(ctx: ChannelHandlerContext)

    /// Called when the `Channel` has become inactive and is no longer able to send and receive data`.
    ///
    /// This should call `ctx.fireChannelInactive` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func channelInactive(ctx: ChannelHandlerContext)

    /// Called when some data has been read from the remote peer.
    ///
    /// This should call `ctx.fireChannelRead` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///     - data: The data read from the remote peer, wrapped in a `NIOAny`.
    func channelRead(ctx: ChannelHandlerContext, data: NIOAny)

    /// Called when the `Channel` has completed its current read loop, either because no more data is available to read from the transport at this time, or because the `Channel` needs to yield to the event loop to process other I/O events for other `Channel`s.
    /// If `ChannelOptions.autoRead` is `false` no further read attempt will be made until `ChannelHandlerContext.read` or `Channel.read` is explicitly called.
    ///
    /// This should call `ctx.fireChannelReadComplete` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func channelReadComplete(ctx: ChannelHandlerContext)

    /// The writability state of the `Channel` has changed, either because it has buffered more data than the writability high water mark, or because the amount of buffered data has dropped below the writability low water mark.
    /// You can check the state with `Channel.isWritable`.
    ///
    /// This should call `ctx.fireChannelWritabilityChanged` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func channelWritabilityChanged(ctx: ChannelHandlerContext)

    /// Called when a user inbound event has been triggered.
    ///
    /// This should call `ctx.fireUserInboundEventTriggered` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///     - event: The event.
    func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any)

    /// An error was encountered earlier in the inbound `ChannelPipeline`.
    ///
    /// This should call `ctx.fireErrorCaught` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the error.
    ///
    /// - parameters:
    ///     - ctx: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///     - error: The `Error` that was encountered.
    func errorCaught(ctx: ChannelHandlerContext, error: Error)
}

//  Default implementations for the ChannelHandler protocol
extension ChannelHandler {

    /// Do nothing by default.
    public func handlerAdded(ctx: ChannelHandlerContext) {
    }

    /// Do nothing by default.
    public func handlerRemoved(ctx: ChannelHandlerContext) {
    }
}

/// Provides default implementations for all methods defined by `_ChannelOutboundHandler`.
///
/// These default implementations will just call `ctx.methodName` to forward to the next `_ChannelOutboundHandler` in
/// the `ChannelPipeline` until the operation is handled by the `Channel` itself.
extension _ChannelOutboundHandler {

    public func register(ctx: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        ctx.register(promise: promise)
    }

    public func bind(ctx: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        ctx.bind(to: address, promise: promise)
    }

    public func connect(ctx: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        ctx.connect(to: address, promise: promise)
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        ctx.write(data, promise: promise)
    }

    public func flush(ctx: ChannelHandlerContext) {
        ctx.flush()
    }

    public func read(ctx: ChannelHandlerContext) {
        ctx.read()
    }

    public func close(ctx: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        ctx.close(mode: mode, promise: promise)
    }

    public func triggerUserOutboundEvent(ctx: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        ctx.triggerUserOutboundEvent(event, promise: promise)
    }
}

/// Provides default implementations for all methods defined by `_ChannelInboundHandler`.
///
/// These default implementations will just `ctx.fire*` to forward to the next `_ChannelInboundHandler` in
/// the `ChannelPipeline` until the operation is handled by the `Channel` itself.
extension _ChannelInboundHandler {

    public func channelRegistered(ctx: ChannelHandlerContext) {
        ctx.fireChannelRegistered()
    }

    public func channelUnregistered(ctx: ChannelHandlerContext) {
        ctx.fireChannelUnregistered()
    }

    public func channelActive(ctx: ChannelHandlerContext) {
        ctx.fireChannelActive()
    }

    public func channelInactive(ctx: ChannelHandlerContext) {
        ctx.fireChannelInactive()
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        ctx.fireChannelRead(data)
    }

    public func channelReadComplete(ctx: ChannelHandlerContext) {
        ctx.fireChannelReadComplete()
    }

    public func channelWritabilityChanged(ctx: ChannelHandlerContext) {
        ctx.fireChannelWritabilityChanged()
    }

    public func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        ctx.fireUserInboundEventTriggered(event)
    }

    public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        ctx.fireErrorCaught(error)
    }
}

