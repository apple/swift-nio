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

import NIOConcurrencyHelpers

/// The core `Channel` methods for NIO-internal use only.
///
/// - note: All methods must be called from the `EventLoop` thread.
public protocol ChannelCore : class {
    /// Returns the local bound `SocketAddress`.
    func localAddress0() throws -> SocketAddress

    /// Return the connected `SocketAddress`.
    func remoteAddress0() throws -> SocketAddress
    
    /// Register with the `EventLoop` to receive I/O notifications.
    ///
    /// - parameters:
    ///     - promise: The `EventLoopPromise` which should be notified once the operation completes, or nil if no notification should take place.
    func register0(promise: EventLoopPromise<Void>?)

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
public protocol Channel : class, ChannelOutboundInvoker {
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
    func setOption<T: ChannelOption>(option: T, value: T.OptionType) -> EventLoopFuture<Void>
    
    /// Get the value of `option` for this `Channel`.
    func getOption<T: ChannelOption>(option: T) -> EventLoopFuture<T.OptionType>

    /// Returns if this `Channel` is currently writable.
    var isWritable: Bool { get }
    
    /// Returns if this `Channel` is currently active. Active is defined as the period of time after the
    /// `channelActive` and before `channelInactive` has fired. The main use for this is to know if `channelActive`
    /// or `channelInactive` can be expected next when `handlerAdded` was received.
    var isActive: Bool { get }

    /// Reach out to the `ChannelCore`.
    ///
    /// - warning: Unsafe, this is for use in NIO's core only.
    var _unsafe: ChannelCore { get }
}

/// A `SelectableChannel` is a `Channel` that can be used with a `Selector` which notifies a user when certain events
/// before possible. On UNIX a `Selector` is usually an abstraction of `select`, `poll`, `epoll` or `kqueue`.
///
/// - warning: `SelectableChannel` methods and properties are _not_ thread-safe (unless they also belong to `Channel`).
internal protocol SelectableChannel : Channel {
    /// The type of the `Selectable`. A `Selectable` is usually wrapping a file descriptor that can be registered in a
    /// `Selector`.
    associatedtype SelectableType: Selectable

    /// Returns the `Selectable` which usually contains the file descriptor for the socket.
    var selectable: SelectableType { get }
    
    /// The event(s) of interest.
    var interestedEvent: IOEvent { get }

    /// Called when the `SelectableChannel` is ready to be written.
    func writable()
    
    /// Called when the `SelectableChannel` is ready to be read.
    func readable()

    /// Creates a registration for the `interested` `IOEvent` suitable for this `Channel`.
    ///
    /// - parameters:
    ///     - interested: The event(s) of interest.
    /// - returns: A suitable registration for the `IOEvent` of interest.
    func registrationFor(interested: IOEvent) -> NIORegistration
}

extension Channel {
    public var open: Bool {
        return !closeFuture.fulfilled
    }

    public func bind(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        pipeline.bind(to: address, promise: promise)
    }

    // Methods invoked from the HeadHandler of the ChannelPipeline
    // By default, just pass through to pipeline

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
    
    public func triggerUserOutboundEvent(_ event: Any, promise: EventLoopPromise<Void>?) {
        pipeline.triggerUserOutboundEvent(event, promise: promise)
    }
}


/// Provides special extension to make writing data to the `Channel` easier by removing the need to wrap data in `NIOAny` manually.
public extension Channel {
    
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

/// An error that can occur on `Channel` operations.
public enum ChannelError: Error {
    /// Tried to connect on a `Channel` that is already connecting.
    case connectPending

    /// Connect operation timed out
    case connectTimeout(TimeAmount)

    /// Connect operation failed
    case connectFailed(NIOConnectionError)

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

    /// A `Channel` `write` was made with a data type not supported by the channel type: e.g. an `AddressedEnvelope`
    /// for a stream channel.
    case writeDataUnsupported

    /// A `DatagramChannel` `write` was made with a buffer that is larger than the MTU for the connection, and so the
    /// datagram was not written. Either shorten the datagram or manually fragment, and then try again.
    case writeMessageTooLarge

    /// A `DatagramChannel` `write` was made with an address that was not reachable and so could not be delivered.
    case writeHostUnreachable
}

extension ChannelError: Equatable {
    public static func ==(lhs: ChannelError, rhs: ChannelError) -> Bool {
        switch (lhs, rhs) {
        case (.connectPending, .connectPending):
            return true
        case (.connectTimeout(_), .connectTimeout(_)):
            return true
        case (.operationUnsupported, .operationUnsupported):
            return true
        case (.ioOnClosedChannel, .ioOnClosedChannel):
            return true
        case (.alreadyClosed, .alreadyClosed):
            return true
        case (.outputClosed, .outputClosed):
            return true
        case (.inputClosed, .inputClosed):
            return true
        case (.eof, .eof):
            return true
        case (.writeDataUnsupported, .writeDataUnsupported):
            return true
        case (.writeMessageTooLarge, .writeMessageTooLarge):
            return true
        case (.writeHostUnreachable, .writeHostUnreachable):
            return true
        default:
            return false
        }
    }
}

/// An `Channel` related event that is passed through the `ChannelPipeline` to notify the user.
public enum ChannelEvent: Equatable {
    /// `ChannelOptions.allowRemoteHalfClosure` is `true` and input portion of the `Channel` was closed.
    case inputClosed
    /// Output portion of the `Channel` was closed.
    case outputClosed
}
