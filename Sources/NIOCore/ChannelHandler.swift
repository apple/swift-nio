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
public protocol ChannelHandler: AnyObject {
    /// Called when this `ChannelHandler` is added to the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func handlerAdded(context: ChannelHandlerContext)

    /// Called when this `ChannelHandler` is removed from the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func handlerRemoved(context: ChannelHandlerContext)
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
    /// This should call `context.register` to forward the operation to the next `_ChannelOutboundHandler` in the `ChannelPipeline` or
    /// complete the `EventLoopPromise` to let the caller know that the operation completed.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func register(context: ChannelHandlerContext, promise: EventLoopPromise<Void>?)

    /// Called to request that the `Channel` bind to a specific `SocketAddress`.
    ///
    /// This should call `context.bind` to forward the operation to the next `_ChannelOutboundHandler` in the `ChannelPipeline` or
    /// complete the `EventLoopPromise` to let the caller know that the operation completed.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///     - to: The `SocketAddress` to which this `Channel` should bind.
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func bind(context: ChannelHandlerContext, to: SocketAddress, promise: EventLoopPromise<Void>?)

    /// Called to request that the `Channel` connect to a given `SocketAddress`.
    ///
    /// This should call `context.connect` to forward the operation to the next `_ChannelOutboundHandler` in the `ChannelPipeline` or
    /// complete the `EventLoopPromise` to let the caller know that the operation completed.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///     - to: The `SocketAddress` to which the the `Channel` should connect.
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func connect(context: ChannelHandlerContext, to: SocketAddress, promise: EventLoopPromise<Void>?)

    /// Called to request a write operation. The write operation will write the messages through the
    /// `ChannelPipeline`. Those are then ready to be flushed to the actual `Channel` when
    /// `Channel.flush` or `ChannelHandlerContext.flush` is called.
    ///
    /// This should call `context.write` to forward the operation to the next `_ChannelOutboundHandler` in the `ChannelPipeline` or
    /// complete the `EventLoopPromise` to let the caller know that the operation completed.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///     - data: The data to write through the `Channel`, wrapped in a `NIOAny`.
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?)

    /// Called to request that the `Channel` flush all pending writes. The flush operation will try to flush out all previous written messages
    /// that are pending.
    ///
    /// This should call `context.flush` to forward the operation to the next `_ChannelOutboundHandler` in the `ChannelPipeline` or just
    /// discard it if the flush should be suppressed.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func flush(context: ChannelHandlerContext)

    /// Called to request that the `Channel` perform a read when data is ready. The read operation will signal that we are ready to read more data.
    ///
    /// This should call `context.read` to forward the operation to the next `_ChannelOutboundHandler` in the `ChannelPipeline` or just
    /// discard it if the read should be suppressed.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func read(context: ChannelHandlerContext)

    /// Called to request that the `Channel` close itself down`.
    ///
    /// This should call `context.close` to forward the operation to the next `_ChannelOutboundHandler` in the `ChannelPipeline` or
    /// complete the `EventLoopPromise` to let the caller know that the operation completed.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///     - mode: The `CloseMode` to apply
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?)

    /// Called when an user outbound event is triggered.
    ///
    /// This should call `context.triggerUserOutboundEvent` to forward the operation to the next `_ChannelOutboundHandler` in the `ChannelPipeline` or
    /// complete the `EventLoopPromise` to let the caller know that the operation completed.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///     - event: The triggered event.
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?)
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
    /// This should call `context.fireChannelRegistered` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func channelRegistered(context: ChannelHandlerContext)

    /// Called when the `Channel` has unregistered from its `EventLoop`, and so will no longer be receiving I/O events.
    ///
    /// This should call `context.fireChannelUnregistered` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func channelUnregistered(context: ChannelHandlerContext)

    /// Called when the `Channel` has become active, and is able to send and receive data.
    ///
    /// This should call `context.fireChannelActive` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func channelActive(context: ChannelHandlerContext)

    /// Called when the `Channel` has become inactive and is no longer able to send and receive data`.
    ///
    /// This should call `context.fireChannelInactive` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func channelInactive(context: ChannelHandlerContext)

    /// Called when some data has been read from the remote peer.
    ///
    /// This should call `context.fireChannelRead` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///     - data: The data read from the remote peer, wrapped in a `NIOAny`.
    func channelRead(context: ChannelHandlerContext, data: NIOAny)

    /// Called when the `Channel` has completed its current read loop, either because no more data is available to read from the transport at this time, or because the `Channel` needs to yield to the event loop to process other I/O events for other `Channel`s.
    /// If `ChannelOptions.autoRead` is `false` no further read attempt will be made until `ChannelHandlerContext.read` or `Channel.read` is explicitly called.
    ///
    /// This should call `context.fireChannelReadComplete` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func channelReadComplete(context: ChannelHandlerContext)

    /// The writability state of the `Channel` has changed, either because it has buffered more data than the writability high water mark, or because the amount of buffered data has dropped below the writability low water mark.
    /// You can check the state with `Channel.isWritable`.
    ///
    /// This should call `context.fireChannelWritabilityChanged` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    func channelWritabilityChanged(context: ChannelHandlerContext)

    /// Called when a user inbound event has been triggered.
    ///
    /// This should call `context.fireUserInboundEventTriggered` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the event.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///     - event: The event.
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any)

    /// An error was encountered earlier in the inbound `ChannelPipeline`.
    ///
    /// This should call `context.fireErrorCaught` to forward the operation to the next `_ChannelInboundHandler` in the `ChannelPipeline` if you want to allow the next handler to also handle the error.
    ///
    /// - parameters:
    ///     - context: The `ChannelHandlerContext` which this `ChannelHandler` belongs to.
    ///     - error: The `Error` that was encountered.
    func errorCaught(context: ChannelHandlerContext, error: Error)
}

//  Default implementations for the ChannelHandler protocol
extension ChannelHandler {

    /// Do nothing by default.
    public func handlerAdded(context: ChannelHandlerContext) {
    }

    /// Do nothing by default.
    public func handlerRemoved(context: ChannelHandlerContext) {
    }
}

/// Provides default implementations for all methods defined by `_ChannelOutboundHandler`.
///
/// These default implementations will just call `context.methodName` to forward to the next `_ChannelOutboundHandler` in
/// the `ChannelPipeline` until the operation is handled by the `Channel` itself.
extension _ChannelOutboundHandler {

    public func register(context: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        context.register(promise: promise)
    }

    public func bind(context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        context.bind(to: address, promise: promise)
    }

    public func connect(context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        context.connect(to: address, promise: promise)
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(data, promise: promise)
    }

    public func flush(context: ChannelHandlerContext) {
        context.flush()
    }

    public func read(context: ChannelHandlerContext) {
        context.read()
    }

    public func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        context.close(mode: mode, promise: promise)
    }

    public func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        context.triggerUserOutboundEvent(event, promise: promise)
    }
}

/// Provides default implementations for all methods defined by `_ChannelInboundHandler`.
///
/// These default implementations will just `context.fire*` to forward to the next `_ChannelInboundHandler` in
/// the `ChannelPipeline` until the operation is handled by the `Channel` itself.
extension _ChannelInboundHandler {

    public func channelRegistered(context: ChannelHandlerContext) {
        context.fireChannelRegistered()
    }

    public func channelUnregistered(context: ChannelHandlerContext) {
        context.fireChannelUnregistered()
    }

    public func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        context.fireChannelInactive()
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }

    public func channelReadComplete(context: ChannelHandlerContext) {
        context.fireChannelReadComplete()
    }

    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        context.fireChannelWritabilityChanged()
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        context.fireUserInboundEventTriggered(event)
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.fireErrorCaught(error)
    }
}

/// A `RemovableChannelHandler` is a `ChannelHandler` that can be dynamically removed from a `ChannelPipeline` whilst
/// the `Channel` is operating normally.
/// A `RemovableChannelHandler` is required to remove itself from the `ChannelPipeline` (using
/// `ChannelHandlerContext.removeHandler`) as soon as possible.
///
/// - note: When a `Channel` gets torn down, every `ChannelHandler` in the `Channel`'s `ChannelPipeline` will be
///         removed from the `ChannelPipeline`. Those removals however happen synchronously and are not going through
///         the methods of this protocol.
public protocol RemovableChannelHandler: ChannelHandler {
    /// Ask the receiving `RemovableChannelHandler` to remove itself from the `ChannelPipeline` as soon as possible.
    /// The receiving `RemovableChannelHandler` may elect to remove itself sometime after this method call, rather than
    /// immediately, but if it does so it must take the necessary precautions to handle events arriving between the
    /// invocation of this method and the call to `ChannelHandlerContext.removeHandler` that triggers the actual
    /// removal.
    ///
    /// - note: Like the other `ChannelHandler` methods, this method should not be invoked by the user directly. To
    ///         remove a `RemovableChannelHandler` from the `ChannelPipeline`, use `ChannelPipeline.remove`.
    ///
    /// - parameters:
    ///    - context: The `ChannelHandlerContext` of the `RemovableChannelHandler` to be removed from the `ChannelPipeline`.
    ///    - removalToken: The removal token to hand to `ChannelHandlerContext.removeHandler` to trigger the actual
    ///                    removal from the `ChannelPipeline`.
    func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken)
}

extension RemovableChannelHandler {
    // Implements the default behaviour which is to synchronously remove the handler from the pipeline. Thanks to this,
    // stateless `ChannelHandler`s can just use `RemovableChannelHandler` as a marker-protocol and declare themselves
    // as removable without writing any extra code.
    public func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        precondition(context.handler === self)
        context.leavePipeline(removalToken: removalToken)
    }
}
