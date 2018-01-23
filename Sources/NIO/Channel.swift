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
/// - note: All methods must be called from the EventLoop thread
public protocol ChannelCore : class {
    func register0(promise: EventLoopPromise<Void>?)
    func bind0(to: SocketAddress, promise: EventLoopPromise<Void>?)
    func connect0(to: SocketAddress, promise: EventLoopPromise<Void>?)
    func write0(data: IOData, promise: EventLoopPromise<Void>?)
    func flush0(promise: EventLoopPromise<Void>?)
    func read0(promise: EventLoopPromise<Void>?)
    func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?)
    func triggerUserOutboundEvent0(event: Any, promise: EventLoopPromise<Void>?)
    func channelRead0(data: NIOAny)
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
    func setOption<T: ChannelOption>(option: T, value: T.OptionType) throws
    
    /// Get the value of `option` for this `Channel`.
    func getOption<T: ChannelOption>(option: T) throws -> T.OptionType

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
protocol SelectableChannel : Channel {
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

    public func write(data: NIOAny, promise: EventLoopPromise<Void>?) {
        pipeline.write(data: data, promise: promise)
    }

    public func flush(promise: EventLoopPromise<Void>?) {
        pipeline.flush(promise: promise)
    }
    
    public func writeAndFlush(data: NIOAny, promise: EventLoopPromise<Void>?) {
        pipeline.writeAndFlush(data: data, promise: promise)
    }

    public func read(promise: EventLoopPromise<Void>?) {
        pipeline.read(promise: promise)
    }

    public func close(mode: CloseMode = .all, promise: EventLoopPromise<Void>?) {
        pipeline.close(mode: mode, promise: promise)
    }

    public func register(promise: EventLoopPromise<Void>?) {
        pipeline.register(promise: promise)
    }
    
    public func triggerUserOutboundEvent(event: Any, promise: EventLoopPromise<Void>?) {
        pipeline.triggerUserOutboundEvent(event: event, promise: promise)
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

