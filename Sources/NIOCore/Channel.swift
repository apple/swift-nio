//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers

/// The core `Channel` methods that are for internal use of the `Channel` implementation only.
///
/// - warning: If you are not implementing a custom `Channel` type, you should never call any of these.
///
/// - note: All methods must be called from the `EventLoop` thread.
public protocol ChannelCore: AnyObject {
    /// Returns the local bound `SocketAddress`.
    func localAddress0() throws -> SocketAddress

    /// Return the connected `SocketAddress`.
    func remoteAddress0() throws -> SocketAddress

    /// Register with the `EventLoop` to receive I/O notifications.
    ///
    /// - parameters:
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func register0(promise: EventLoopPromise<Void>?)

    /// Register channel as already connected or bound socket.
    /// - parameters:
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func registerAlreadyConfigured0(promise: EventLoopPromise<Void>?)

    /// Bind to a `SocketAddress`.
    ///
    /// - parameters:
    ///     - to: The `SocketAddress` to which we should bind the `Channel`.
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func bind0(to: SocketAddress, promise: EventLoopPromise<Void>?)

    /// Connect to a `SocketAddress`.
    ///
    /// - parameters:
    ///     - to: The `SocketAddress` to which we should connect the `Channel`.
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func connect0(to: SocketAddress, promise: EventLoopPromise<Void>?)

    /// Write the given data to the outbound buffer.
    ///
    /// - parameters:
    ///     - data: The data to write, wrapped in a `NIOAny`.
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?)

    /// Try to flush out all previous written messages that are pending.
    func flush0()

    /// Request that the `Channel` perform a read when data is ready.
    func read0()

    /// Close the `Channel`.
    ///
    /// - parameters:
    ///     - error: The `Error` which will be used to fail any pending writes.
    ///     - mode: The `CloseMode` to apply.
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?)

    /// Trigger an outbound event.
    ///
    /// - parameters:
    ///     - event: The triggered event.
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?)

    /// Called when data was read from the `Channel` but it was not consumed by any `ChannelInboundHandler` in the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - data: The data that was read, wrapped in a `NIOAny`.
    func channelRead0(_ data: NIOAny)

    /// Called when an inbound error was encountered but was not consumed by any `ChannelInboundHandler` in the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - error: The `Error` that was encountered.
    func errorCaught0(error: Error)
}

/// A `Channel` is easiest thought of as a network socket. But it can be anything that is capable of I/O operations such
/// as read, write, connect, and bind.
///
/// - note: All operations on `Channel` are thread-safe.
///
/// In SwiftNIO, all I/O operations are asynchronous and hence all operations on `Channel` are asynchronous too. This means
/// that all I/O operations will return immediately, usually before the work has been completed. The `EventLoopPromise`s
/// passed to or returned by the operations are used to retrieve the result of an operation after it has completed.
///
/// A `Channel` owns its `ChannelPipeline` which handles all I/O events and requests associated with the `Channel`.
public protocol Channel: AnyObject, ChannelOutboundInvoker {
    /// The `Channel`'s `ByteBuffer` allocator. This is _the only_ supported way of allocating `ByteBuffer`s to be used with this `Channel`.
    var allocator: ByteBufferAllocator { get }

    /// The `closeFuture` will fire when the `Channel` has been closed.
    var closeFuture: EventLoopFuture<Void> { get }

    /// The `ChannelPipeline` which handles all I/O events and requests associated with this `Channel`.
    var pipeline: ChannelPipeline { get }

    /// The local `SocketAddress`.
    var localAddress: SocketAddress? { get }

    /// The remote peer's `SocketAddress`.
    var remoteAddress: SocketAddress? { get }

    /// `Channel`s are hierarchical and might have a parent `Channel`. `Channel` hierarchies are in use for certain
    /// protocols such as HTTP/2.
    var parent: Channel? { get }

    /// Set `option` to `value` on this `Channel`.
    func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> EventLoopFuture<Void>

    /// Get the value of `option` for this `Channel`.
    func getOption<Option: ChannelOption>(_ option: Option) -> EventLoopFuture<Option.Value>

    /// Returns if this `Channel` is currently writable.
    var isWritable: Bool { get }

    /// Returns if this `Channel` is currently active. Active is defined as the period of time after the
    /// `channelActive` and before `channelInactive` has fired. The main use for this is to know if `channelActive`
    /// or `channelInactive` can be expected next when `handlerAdded` was received.
    var isActive: Bool { get }

    /// Reach out to the `_ChannelCore`.
    ///
    /// - warning: Unsafe, this is for use in NIO's core only.
    var _channelCore: ChannelCore { get }

    /// Returns a view of the `Channel` exposing synchronous versions of `setOption` and `getOption`.
    /// The default implementation returns `nil`, and `Channel` implementations must opt in to
    /// support this behavior.
    var syncOptions: NIOSynchronousChannelOptions? { get }
}

extension Channel {
    /// Default implementation: `NIOSynchronousChannelOptions` are not supported.
    public var syncOptions: NIOSynchronousChannelOptions? {
        return nil
    }
}

public protocol NIOSynchronousChannelOptions {
    /// Set `option` to `value` on this `Channel`.
    ///
    /// - Important: Must be called on the `EventLoop` the `Channel` is running on.
    func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) throws

    /// Get the value of `option` for this `Channel`.
    ///
    /// - Important: Must be called on the `EventLoop` the `Channel` is running on.
    func getOption<Option: ChannelOption>(_ option: Option) throws -> Option.Value
}

/// Default implementations which will start on the head of the `ChannelPipeline`.
extension Channel {

    public func bind(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        pipeline.bind(to: address, promise: promise)
    }

    public func connect(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        pipeline.connect(to: address, promise: promise)
    }

    public func write(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        pipeline.write(data, promise: promise)
    }

    public func flush() {
        pipeline.flush()
    }

    public func writeAndFlush(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        pipeline.writeAndFlush(data, promise: promise)
    }

    public func read() {
        pipeline.read()
    }

    public func close(mode: CloseMode = .all, promise: EventLoopPromise<Void>?) {
        pipeline.close(mode: mode, promise: promise)
    }

    public func register(promise: EventLoopPromise<Void>?) {
        pipeline.register(promise: promise)
    }

    public func registerAlreadyConfigured0(promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.operationUnsupported)
    }

    public func triggerUserOutboundEvent(_ event: Any, promise: EventLoopPromise<Void>?) {
        pipeline.triggerUserOutboundEvent(event, promise: promise)
    }
}


/// Provides special extension to make writing data to the `Channel` easier by removing the need to wrap data in `NIOAny` manually.
extension Channel {

    /// Write data into the `Channel`, automatically wrapping with `NIOAny`.
    ///
    /// - seealso: `ChannelOutboundInvoker.write`.
    public func write<T>(_ any: T) -> EventLoopFuture<Void> {
        return self.write(NIOAny(any))
    }

    /// Write data into the `Channel`, automatically wrapping with `NIOAny`.
    ///
    /// - seealso: `ChannelOutboundInvoker.write`.
    public func write<T>(_ any: T, promise: EventLoopPromise<Void>?) {
        self.write(NIOAny(any), promise: promise)
    }

    /// Write and flush data into the `Channel`, automatically wrapping with `NIOAny`.
    ///
    /// - seealso: `ChannelOutboundInvoker.writeAndFlush`.
    public func writeAndFlush<T>(_ any: T) -> EventLoopFuture<Void> {
        return self.writeAndFlush(NIOAny(any))
    }


    /// Write and flush data into the `Channel`, automatically wrapping with `NIOAny`.
    ///
    /// - seealso: `ChannelOutboundInvoker.writeAndFlush`.
    public func writeAndFlush<T>(_ any: T, promise: EventLoopPromise<Void>?) {
        self.writeAndFlush(NIOAny(any), promise: promise)
    }
}

extension ChannelCore {
    /// Unwraps the given `NIOAny` as a specific concrete type.
    ///
    /// This method is intended for use when writing custom `ChannelCore` implementations.
    /// This can safely be called in methods like `write0` to extract data from the `NIOAny`
    /// provided in those cases.
    ///
    /// Note that if the unwrap fails, this will cause a runtime trap. `ChannelCore`
    /// implementations should be concrete about what types they support writing. If multiple
    /// types are supported, consider using a tagged union to store the type information like
    /// NIO's own `IOData`, which will minimise the amount of runtime type checking.
    ///
    /// - parameters:
    ///     - data: The `NIOAny` to unwrap.
    ///     - as: The type to extract from the `NIOAny`.
    /// - returns: The content of the `NIOAny`.
    @inlinable
    public func unwrapData<T>(_ data: NIOAny, as: T.Type = T.self) -> T {
        return data.forceAs()
    }

    /// Attempts to unwrap the given `NIOAny` as a specific concrete type.
    ///
    /// This method is intended for use when writing custom `ChannelCore` implementations.
    /// This can safely be called in methods like `write0` to extract data from the `NIOAny`
    /// provided in those cases.
    ///
    /// If the unwrap fails, this will return `nil`. `ChannelCore` implementations should almost
    /// always support only one runtime type, so in general they should avoid using this and prefer
    /// using `unwrapData` instead. This method exists for rare use-cases where tolerating type
    /// mismatches is acceptable.
    ///
    /// - parameters:
    ///     - data: The `NIOAny` to unwrap.
    ///     - as: The type to extract from the `NIOAny`.
    /// - returns: The content of the `NIOAny`, or `nil` if the type is incorrect.
    /// - warning: If you are implementing a `ChannelCore`, you should use `unwrapData` unless you
    ///     are doing something _extremely_ unusual.
    @inlinable
    public func tryUnwrapData<T>(_ data: NIOAny, as: T.Type = T.self) -> T? {
        return data.tryAs()
    }

    /// Removes the `ChannelHandler`s from the `ChannelPipeline` belonging to `channel`, and
    /// closes that `ChannelPipeline`.
    ///
    /// This method is intended for use when writing custom `ChannelCore` implementations.
    /// This can be called from `close0` to tear down the `ChannelPipeline` when closure is
    /// complete.
    ///
    /// - parameters:
    ///     - channel: The `Channel` whose `ChannelPipeline` will be closed.
    @available(*, deprecated, renamed: "removeHandlers(pipeline:)")
    public func removeHandlers(channel: Channel) {
        self.removeHandlers(pipeline: channel.pipeline)
    }

    /// Removes the `ChannelHandler`s from the `ChannelPipeline` `pipeline`, and
    /// closes that `ChannelPipeline`.
    ///
    /// This method is intended for use when writing custom `ChannelCore` implementations.
    /// This can be called from `close0` to tear down the `ChannelPipeline` when closure is
    /// complete.
    ///
    /// - parameters:
    ///     - pipeline: The `ChannelPipline` to be closed.
    public func removeHandlers(pipeline: ChannelPipeline) {
        pipeline.removeHandlers()
    }
}

/// An error that can occur on `Channel` operations.
public enum ChannelError: Error {
    /// Tried to connect on a `Channel` that is already connecting.
    case connectPending

    /// Connect operation timed out
    case connectTimeout(TimeAmount)

    /// Unsupported operation triggered on a `Channel`. For example `connect` on a `ServerSocketChannel`.
    case operationUnsupported

    /// An I/O operation (e.g. read/write/flush) called on a channel that is already closed.
    case ioOnClosedChannel

    /// Close was called on a channel that is already closed.
    case alreadyClosed

    /// Output-side of the channel is closed.
    case outputClosed

    /// Input-side of the channel is closed.
    case inputClosed

    /// A read operation reached end-of-file. This usually means the remote peer closed the socket but it's still
    /// open locally.
    case eof

    /// A `DatagramChannel` `write` was made with a buffer that is larger than the MTU for the connection, and so the
    /// datagram was not written. Either shorten the datagram or manually fragment, and then try again.
    case writeMessageTooLarge

    /// A `DatagramChannel` `write` was made with an address that was not reachable and so could not be delivered.
    case writeHostUnreachable

    /// The local address of the `Channel` could not be determined.
    case unknownLocalAddress

    /// The address family of the multicast group was not valid for this `Channel`.
    case badMulticastGroupAddressFamily

    /// The address family of the provided multicast group join is not valid for this `Channel`.
    case badInterfaceAddressFamily

    /// An attempt was made to join a multicast group that does not correspond to a multicast
    /// address.
    case illegalMulticastAddress(SocketAddress)

    /// Multicast is not supported on Interface
    @available(*, deprecated, renamed: "NIOMulticastNotSupportedError")
    case multicastNotSupported(NIONetworkInterface)

    /// An operation that was inappropriate given the current `Channel` state was attempted.
    case inappropriateOperationForState

    /// An attempt was made to remove a ChannelHandler that is not removable.
    case unremovableHandler
}

extension ChannelError: Equatable { }

/// The removal of a `ChannelHandler` using `ChannelPipeline.removeHandler` has been attempted more than once.
public struct NIOAttemptedToRemoveHandlerMultipleTimesError: Error {}

/// An `Channel` related event that is passed through the `ChannelPipeline` to notify the user.
public enum ChannelEvent: Equatable {
    /// `ChannelOptions.allowRemoteHalfClosure` is `true` and input portion of the `Channel` was closed.
    case inputClosed
    /// Output portion of the `Channel` was closed.
    case outputClosed
}

/// A `Channel` user event that is sent when the `Channel` has been asked to quiesce.
///
/// The action(s) that should be taken after receiving this event are both application and protocol dependent. If the
/// protocol supports a notion of requests and responses, it might make sense to stop accepting new requests but finish
/// processing the request currently in flight.
public struct ChannelShouldQuiesceEvent {
    public init() {
    }
}
