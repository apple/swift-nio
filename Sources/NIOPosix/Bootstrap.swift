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
@_spi(AsyncChannel) import NIOCore

#if os(Windows)
import ucrt

import func WinSDK.GetFileType

import let WinSDK.FILE_TYPE_PIPE
import let WinSDK.INVALID_HANDLE_VALUE

import struct WinSDK.DWORD
import struct WinSDK.HANDLE
#endif

#if swift(>=5.7)
/// The type of all `channelInitializer` callbacks.
internal typealias ChannelInitializerCallback = @Sendable (Channel) -> EventLoopFuture<Void>
#else
/// The type of all `channelInitializer` callbacks.
internal typealias ChannelInitializerCallback = (Channel) -> EventLoopFuture<Void>
#endif

/// Common functionality for all NIO on sockets bootstraps.
internal enum NIOOnSocketsBootstraps {
    internal static func isCompatible(group: EventLoopGroup) -> Bool {
        return group is SelectableEventLoop || group is MultiThreadedEventLoopGroup
    }
}

/// A `ServerBootstrap` is an easy way to bootstrap a `ServerSocketChannel` when creating network servers.
///
/// Example:
///
/// ```swift
///     let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
///     defer {
///         try! group.syncShutdownGracefully()
///     }
///     let bootstrap = ServerBootstrap(group: group)
///         // Specify backlog and enable SO_REUSEADDR for the server itself
///         .serverChannelOption(ChannelOptions.backlog, value: 256)
///         .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
///
///         // Set the handlers that are applied to the accepted child `Channel`s.
///         .childChannelInitializer { channel in
///             // Ensure we don't read faster then we can write by adding the BackPressureHandler into the pipeline.
///             channel.pipeline.addHandler(BackPressureHandler()).flatMap { () in
///                 // make sure to instantiate your `ChannelHandlers` inside of
///                 // the closure as it will be invoked once per connection.
///                 channel.pipeline.addHandler(MyChannelHandler())
///             }
///         }
///
///         // Enable SO_REUSEADDR for the accepted Channels
///         .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
///         .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
///         .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
///     let channel = try! bootstrap.bind(host: host, port: port).wait()
///     /* the server will now be accepting connections */
///
///     try! channel.closeFuture.wait() // wait forever as we never close the Channel
/// ```
///
/// The `EventLoopFuture` returned by `bind` will fire with a `ServerSocketChannel`. This is the channel that owns the listening socket.
/// Each time it accepts a new connection it will fire a `SocketChannel` through the `ChannelPipeline` via `fireChannelRead`: as a result,
/// the `ServerSocketChannel` operates on `Channel`s as inbound messages. Outbound messages are not supported on a `ServerSocketChannel`
/// which means that each write attempt will fail.
///
/// Accepted `SocketChannel`s operate on `ByteBuffer` as inbound data, and `IOData` as outbound data.
public final class ServerBootstrap {

    private let group: EventLoopGroup
    private let childGroup: EventLoopGroup
    private var serverChannelInit: Optional<ChannelInitializerCallback>
    private var childChannelInit: Optional<ChannelInitializerCallback>
    @usableFromInline
    internal var _serverChannelOptions: ChannelOptions.Storage
    @usableFromInline
    internal var _childChannelOptions: ChannelOptions.Storage
    private var enableMPTCP: Bool

    /// Create a `ServerBootstrap` on the `EventLoopGroup` `group`.
    ///
    /// The `EventLoopGroup` `group` must be compatible, otherwise the program will crash. `ServerBootstrap` is
    /// compatible only with `MultiThreadedEventLoopGroup` as well as the `EventLoop`s returned by
    /// `MultiThreadedEventLoopGroup.next`. See `init(validatingGroup:childGroup:)` for a fallible initializer for
    /// situations where it's impossible to tell ahead of time if the `EventLoopGroup`s are compatible or not.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use for the `bind` of the `ServerSocketChannel` and to accept new `SocketChannel`s with.
    public convenience init(group: EventLoopGroup) {
        guard NIOOnSocketsBootstraps.isCompatible(group: group) else {
            preconditionFailure("ServerBootstrap is only compatible with MultiThreadedEventLoopGroup and " +
                                "SelectableEventLoop. You tried constructing one with \(group) which is incompatible.")
        }
        self.init(validatingGroup: group, childGroup: group)!
    }

    /// Create a `ServerBootstrap` on the `EventLoopGroup` `group` which accepts `Channel`s on `childGroup`.
    ///
    /// The `EventLoopGroup`s `group` and `childGroup` must be compatible, otherwise the program will crash.
    /// `ServerBootstrap` is compatible only with `MultiThreadedEventLoopGroup` as well as the `EventLoop`s returned by
    /// `MultiThreadedEventLoopGroup.next`. See `init(validatingGroup:childGroup:)` for a fallible initializer for
    /// situations where it's impossible to tell ahead of time if the `EventLoopGroup`s are compatible or not.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use for the `bind` of the `ServerSocketChannel` and to accept new `SocketChannel`s with.
    ///     - childGroup: The `EventLoopGroup` to run the accepted `SocketChannel`s on.
    public convenience init(group: EventLoopGroup, childGroup: EventLoopGroup) {
        guard NIOOnSocketsBootstraps.isCompatible(group: group) && NIOOnSocketsBootstraps.isCompatible(group: childGroup) else {
            preconditionFailure("ServerBootstrap is only compatible with MultiThreadedEventLoopGroup and " +
                                "SelectableEventLoop. You tried constructing one with group: \(group) and " +
                                "childGroup: \(childGroup) at least one of which is incompatible.")
        }
        self.init(validatingGroup: group, childGroup: childGroup)!

    }

    /// Create a `ServerBootstrap` on the `EventLoopGroup` `group` which accepts `Channel`s on `childGroup`, validating
    /// that the `EventLoopGroup`s are compatible with `ServerBootstrap`.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use for the `bind` of the `ServerSocketChannel` and to accept new `SocketChannel`s with.
    ///     - childGroup: The `EventLoopGroup` to run the accepted `SocketChannel`s on. If `nil`, `group` is used.
    public init?(validatingGroup group: EventLoopGroup, childGroup: EventLoopGroup? = nil) {
        let childGroup = childGroup ?? group
        guard NIOOnSocketsBootstraps.isCompatible(group: group) && NIOOnSocketsBootstraps.isCompatible(group: childGroup) else {
            return nil
        }

        self.group = group
        self.childGroup = childGroup
        self._serverChannelOptions = ChannelOptions.Storage()
        self._childChannelOptions = ChannelOptions.Storage()
        self.serverChannelInit = nil
        self.childChannelInit = nil
        self._serverChannelOptions.append(key: ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
        self.enableMPTCP = false
    }

    #if swift(>=5.7)
    /// Initialize the `ServerSocketChannel` with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// The `ServerSocketChannel` uses the accepted `Channel`s as inbound messages.
    ///
    /// - note: To set the initializer for the accepted `SocketChannel`s, look at `ServerBootstrap.childChannelInitializer`.
    ///
    /// - parameters:
    ///     - initializer: A closure that initializes the provided `Channel`.
    @preconcurrency
    public func serverChannelInitializer(_ initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> Self {
        self.serverChannelInit = initializer
        return self
    }
    #else
    /// Initialize the `ServerSocketChannel` with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// The `ServerSocketChannel` uses the accepted `Channel`s as inbound messages.
    ///
    /// - note: To set the initializer for the accepted `SocketChannel`s, look at `ServerBootstrap.childChannelInitializer`.
    ///
    /// - parameters:
    ///     - initializer: A closure that initializes the provided `Channel`.
    public func serverChannelInitializer(_ initializer: @escaping (Channel) -> EventLoopFuture<Void>) -> Self {
        self.serverChannelInit = initializer
        return self
    }
    #endif

    #if swift(>=5.7)
    /// Initialize the accepted `SocketChannel`s with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`. Note that if the `initializer` fails then the error will be
    /// fired in the *parent* channel.
    ///
    /// - warning: The `initializer` will be invoked once for every accepted connection. Therefore it's usually the
    ///            right choice to instantiate stateful `ChannelHandler`s within the closure to make sure they are not
    ///            accidentally shared across `Channel`s. There are expert use-cases where stateful handler need to be
    ///            shared across `Channel`s in which case the user is responsible to synchronise the state access
    ///            appropriately.
    ///
    /// The accepted `Channel` will operate on `ByteBuffer` as inbound and `IOData` as outbound messages.
    ///
    /// - parameters:
    ///     - initializer: A closure that initializes the provided `Channel`.
    @preconcurrency
    public func childChannelInitializer(_ initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> Self {
        self.childChannelInit = initializer
        return self
    }
    #else
    /// Initialize the accepted `SocketChannel`s with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`. Note that if the `initializer` fails then the error will be
    /// fired in the *parent* channel.
    ///
    /// - warning: The `initializer` will be invoked once for every accepted connection. Therefore it's usually the
    ///            right choice to instantiate stateful `ChannelHandler`s within the closure to make sure they are not
    ///            accidentally shared across `Channel`s. There are expert use-cases where stateful handler need to be
    ///            shared across `Channel`s in which case the user is responsible to synchronise the state access
    ///            appropriately.
    ///
    /// The accepted `Channel` will operate on `ByteBuffer` as inbound and `IOData` as outbound messages.
    ///
    /// - parameters:
    ///     - initializer: A closure that initializes the provided `Channel`.
    public func childChannelInitializer(_ initializer: @escaping (Channel) -> EventLoopFuture<Void>) -> Self {
        self.childChannelInit = initializer
        return self
    }
    #endif

    /// Specifies a `ChannelOption` to be applied to the `ServerSocketChannel`.
    ///
    /// - note: To specify options for the accepted `SocketChannel`s, look at `ServerBootstrap.childChannelOption`.
    ///
    /// - parameters:
    ///     - option: The option to be applied.
    ///     - value: The value for the option.
    @inlinable
    public func serverChannelOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
        self._serverChannelOptions.append(key: option, value: value)
        return self
    }

    /// Specifies a `ChannelOption` to be applied to the accepted `SocketChannel`s.
    ///
    /// - parameters:
    ///     - option: The option to be applied.
    ///     - value: The value for the option.
    @inlinable
    public func childChannelOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
        self._childChannelOptions.append(key: option, value: value)
        return self
    }

    /// Specifies a timeout to apply to a bind attempt. Currently unsupported.
    ///
    /// - parameters:
    ///     - timeout: The timeout that will apply to the bind attempt.
    public func bindTimeout(_ timeout: TimeAmount) -> Self {
        return self
    }

    /// Enables multi-path TCP support.
    ///
    /// This option is only supported on some systems, and will lead to bind
    /// failing if the system does not support it. Users are recommended to
    /// only enable this in response to configuration or feature detection.
    ///
    /// > Note: Enabling this setting will re-enable Nagle's algorithm, even if it
    /// > had been disabled. This is a temporary workaround for a Linux kernel
    /// > limitation.
    ///
    /// - parameters:
    ///     - value: Whether to enable MPTCP or not.
    public func enableMPTCP(_ value: Bool) -> Self {
        self.enableMPTCP = value

        // This is a temporary workaround until we get some stable Linux kernel
        // versions that support TCP_NODELAY and MPTCP.
        if value {
            self._serverChannelOptions.remove(key: ChannelOptions.tcpOption(.tcp_nodelay))
        }

        return self
    }

    /// Bind the `ServerSocketChannel` to `host` and `port`.
    ///
    /// - parameters:
    ///     - host: The host to bind on.
    ///     - port: The port to bind on.
    public func bind(host: String, port: Int) -> EventLoopFuture<Channel> {
        return bind0 {
            return try SocketAddress.makeAddressResolvingHost(host, port: port)
        }
    }

    /// Bind the `ServerSocketChannel` to `address`.
    ///
    /// - parameters:
    ///     - address: The `SocketAddress` to bind on.
    public func bind(to address: SocketAddress) -> EventLoopFuture<Channel> {
        return bind0 { address }
    }

    /// Bind the `ServerSocketChannel` to a UNIX Domain Socket.
    ///
    /// - parameters:
    ///     - unixDomainSocketPath: The _Unix domain socket_ path to bind to. `unixDomainSocketPath` must not exist, it will be created by the system.
    public func bind(unixDomainSocketPath: String) -> EventLoopFuture<Channel> {
        return bind0 {
            try SocketAddress(unixDomainSocketPath: unixDomainSocketPath)
        }
    }

    /// Bind the `ServerSocketChannel` to a UNIX Domain Socket.
    ///
    /// - parameters:
    ///     - unixDomainSocketPath: The path of the UNIX Domain Socket to bind on. The`unixDomainSocketPath` must not exist,
    ///     unless `cleanupExistingSocketFile`is set to `true`.
    ///     - cleanupExistingSocketFile: Whether to cleanup an existing socket file at `unixDomainSocketPath`.
    public func bind(unixDomainSocketPath: String, cleanupExistingSocketFile: Bool) -> EventLoopFuture<Channel> {
        if cleanupExistingSocketFile {
            do {
                try BaseSocket.cleanupSocket(unixDomainSocketPath: unixDomainSocketPath)
            } catch {
                return group.next().makeFailedFuture(error)
            }
        }

        return self.bind(unixDomainSocketPath: unixDomainSocketPath)
    }

    #if !os(Windows)
        /// Use the existing bound socket file descriptor.
        ///
        /// - parameters:
        ///     - descriptor: The _Unix file descriptor_ representing the bound stream socket.
        @available(*, deprecated, renamed: "withBoundSocket(_:)")
        public func withBoundSocket(descriptor: CInt) -> EventLoopFuture<Channel> {
            return withBoundSocket(descriptor)
        }
    #endif

    /// Use the existing bound socket file descriptor.
    ///
    /// - parameters:
    ///     - descriptor: The _Unix file descriptor_ representing the bound stream socket.
    public func withBoundSocket(_ socket: NIOBSDSocket.Handle) -> EventLoopFuture<Channel> {
        func makeChannel(_ eventLoop: SelectableEventLoop, _ childEventLoopGroup: EventLoopGroup, _ enableMPTCP: Bool) throws -> ServerSocketChannel {
            if enableMPTCP {
                throw ChannelError.operationUnsupported
            }
            return try ServerSocketChannel(socket: socket, eventLoop: eventLoop, group: childEventLoopGroup)
        }
        return bind0(makeServerChannel: makeChannel) { (eventLoop, serverChannel) in
            let promise = eventLoop.makePromise(of: Void.self)
            serverChannel.registerAlreadyConfigured0(promise: promise)
            return promise.futureResult
        }
    }

    private func bind0(_ makeSocketAddress: () throws -> SocketAddress) -> EventLoopFuture<Channel> {
        let address: SocketAddress
        do {
            address = try makeSocketAddress()
        } catch {
            return group.next().makeFailedFuture(error)
        }
        func makeChannel(_ eventLoop: SelectableEventLoop, _ childEventLoopGroup: EventLoopGroup, _ enableMPTCP: Bool) throws -> ServerSocketChannel {
            return try ServerSocketChannel(eventLoop: eventLoop,
                                           group: childEventLoopGroup,
                                           protocolFamily: address.protocol,
                                           enableMPTCP: enableMPTCP)
        }

        return bind0(makeServerChannel: makeChannel) { (eventLoop, serverChannel) in
            serverChannel.registerAndDoSynchronously { serverChannel in
                serverChannel.bind(to: address)
            }
        }
    }

    private func bind0(makeServerChannel: (_ eventLoop: SelectableEventLoop, _ childGroup: EventLoopGroup, _ enableMPTCP: Bool) throws -> ServerSocketChannel, _ register: @escaping (EventLoop, ServerSocketChannel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel> {
        let eventLoop = self.group.next()
        let childEventLoopGroup = self.childGroup
        let serverChannelOptions = self._serverChannelOptions
        let serverChannelInit = self.serverChannelInit ?? { _ in eventLoop.makeSucceededFuture(()) }
        let childChannelInit = self.childChannelInit
        let childChannelOptions = self._childChannelOptions

        let serverChannel: ServerSocketChannel
        do {
            serverChannel = try makeServerChannel(eventLoop as! SelectableEventLoop, childEventLoopGroup, self.enableMPTCP)
        } catch {
            return eventLoop.makeFailedFuture(error)
        }

        return eventLoop.submit {
            serverChannelOptions.applyAllChannelOptions(to: serverChannel).flatMap {
                serverChannelInit(serverChannel)
            }.flatMap {
                serverChannel.pipeline.addHandler(AcceptHandler(childChannelInitializer: childChannelInit,
                                                                childChannelOptions: childChannelOptions),
                                                  name: "AcceptHandler")
            }.flatMap {
                register(eventLoop, serverChannel)
            }.map {
                serverChannel as Channel
            }.flatMapError { error in
                serverChannel.close0(error: error, mode: .all, promise: nil)
                return eventLoop.makeFailedFuture(error)
            }
        }.flatMap {
            $0
        }
    }

    private class AcceptHandler: ChannelInboundHandler {
        public typealias InboundIn = SocketChannel

        private let childChannelInit: ((Channel) -> EventLoopFuture<Void>)?
        private let childChannelOptions: ChannelOptions.Storage

        init(childChannelInitializer: ((Channel) -> EventLoopFuture<Void>)?, childChannelOptions: ChannelOptions.Storage) {
            self.childChannelInit = childChannelInitializer
            self.childChannelOptions = childChannelOptions
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if event is ChannelShouldQuiesceEvent {
                context.channel.close().whenFailure { error in
                    context.fireErrorCaught(error)
                }
            }
            context.fireUserInboundEventTriggered(event)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let accepted = self.unwrapInboundIn(data)
            let ctxEventLoop = context.eventLoop
            let childEventLoop = accepted.eventLoop
            let childChannelInit = self.childChannelInit ?? { (_: Channel) in childEventLoop.makeSucceededFuture(()) }

            @inline(__always)
            func setupChildChannel() -> EventLoopFuture<Void> {
                return self.childChannelOptions.applyAllChannelOptions(to: accepted).flatMap { () -> EventLoopFuture<Void> in
                    childEventLoop.assertInEventLoop()
                    return childChannelInit(accepted)
                }
            }

            @inline(__always)
            func fireThroughPipeline(_ future: EventLoopFuture<Void>) {
                ctxEventLoop.assertInEventLoop()
                future.flatMap { (_) -> EventLoopFuture<Void> in
                    ctxEventLoop.assertInEventLoop()
                    guard context.channel.isActive else {
                        return context.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
                    }
                    context.fireChannelRead(data)
                    return context.eventLoop.makeSucceededFuture(())
                }.whenFailure { error in
                    ctxEventLoop.assertInEventLoop()
                    self.closeAndFire(context: context, accepted: accepted, err: error)
                }
            }

            if childEventLoop === ctxEventLoop {
                fireThroughPipeline(setupChildChannel())
            } else {
                fireThroughPipeline(childEventLoop.flatSubmit {
                    return setupChildChannel()
                }.hop(to: ctxEventLoop))
            }
        }

        private func closeAndFire(context: ChannelHandlerContext, accepted: SocketChannel, err: Error) {
            accepted.close(promise: nil)
            if context.eventLoop.inEventLoop {
                context.fireErrorCaught(err)
            } else {
                context.eventLoop.execute {
                    context.fireErrorCaught(err)
                }
            }
        }
    }
}

// MARK: AsyncChannel based bind
extension ServerBootstrap {
    /// Bind the `ServerSocketChannel` to the `host` and `port` parameters.
    ///
    /// - Parameters:
    ///   - host: The host to bind on.
    ///   - port: The port to bind on.
    ///   - serverBackpressureStrategy: The back pressure strategy used by the server socket channel.
    ///   - childBackpressureStrategy: The back pressure strategy used by the child channels.
    ///   - childChannelInboundType: The child channel's inbound type.
    ///   - childChannelOutboundType: The child channel's outbound type.
    ///   - isChildChannelOutboundHalfClosureEnabled: Indicates if half closure is enabled on the child channels. If half closure is enabled
    ///   then finishing the ``NIOAsyncChannelWriter`` will lead to half closure.
    /// - Returns: A ``NIOAsyncChannel`` of connection ``NIOAsyncChannel``s.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @_spi(AsyncChannel)
    public func bind<ChildChannelInbound: Sendable, ChildChannelOutbound: Sendable>(
        host: String,
        port: Int,
        serverBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        childChannelInboundType: ChildChannelInbound.Type = ChildChannelInbound.self,
        childChannelOutboundType: ChildChannelOutbound.Type = ChildChannelOutbound.self,
        childBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        isChildChannelOutboundHalfClosureEnabled: Bool = false
    ) async throws -> NIOAsyncChannel<NIOAsyncChannel<ChildChannelInbound, ChildChannelOutbound>, Never> {
        return try await self.bindAsyncChannel0(
            serverBackpressureStrategy: serverBackpressureStrategy,
            childBackpressureStrategy: childBackpressureStrategy,
            isChildChannelOutboundHalfClosureEnabled: isChildChannelOutboundHalfClosureEnabled
        ) {
            return try SocketAddress.makeAddressResolvingHost(host, port: port)
        }
    }

    /// Bind the `ServerSocketChannel` to the `address` parameter.
    ///
    /// - Parameters:
    ///   - address: The `SocketAddress` to bind on.
    ///   - serverBackpressureStrategy: The back pressure strategy used by the server socket channel.
    ///   - childBackpressureStrategy: The back pressure strategy used by the child channels.
    ///   - childChannelInboundType: The child channel's inbound type.
    ///   - childChannelOutboundType: The child channel's outbound type.
    ///   - isChildChannelOutboundHalfClosureEnabled: Indicates if half closure is enabled on the child channels. If half closure is enabled
    ///   then finishing the ``NIOAsyncChannelWriter`` will lead to half closure.
    /// - Returns: A ``NIOAsyncChannel`` of connection ``NIOAsyncChannel``s.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @_spi(AsyncChannel)
    public func bind<ChildChannelInbound: Sendable, ChildChannelOutbound: Sendable>(
        to address: SocketAddress,
        serverBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        childBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        childChannelInboundType: ChildChannelInbound.Type = ChildChannelInbound.self,
        childChannelOutboundType: ChildChannelOutbound.Type = ChildChannelOutbound.self,
        isChildChannelOutboundHalfClosureEnabled: Bool = false
    ) async throws -> NIOAsyncChannel<NIOAsyncChannel<ChildChannelInbound, ChildChannelOutbound>, Never> {
        return try await self.bindAsyncChannel0(
            serverBackpressureStrategy: serverBackpressureStrategy,
            childBackpressureStrategy: childBackpressureStrategy,
            isChildChannelOutboundHalfClosureEnabled: isChildChannelOutboundHalfClosureEnabled
        ) { address }
    }

    /// Bind the `ServerSocketChannel` to the `unixDomainSocketPath` parameter.
    ///
    /// - Parameters:
    ///   - unixDomainSocketPath: The path of the UNIX Domain Socket to bind on. The`unixDomainSocketPath` must not exist,
    ///     unless `cleanupExistingSocketFile`is set to `true`.
    ///   - cleanupExistingSocketFile: Whether to cleanup an existing socket file at `unixDomainSocketPath`.
    ///   - serverBackpressureStrategy: The back pressure strategy used by the server socket channel.
    ///   - childBackpressureStrategy: The back pressure strategy used by the child channels.
    ///   - childChannelInboundType: The child channel's inbound type.
    ///   - childChannelOutboundType: The child channel's outbound type.
    ///   - isChildChannelOutboundHalfClosureEnabled: Indicates if half closure is enabled on the child channels. If half closure is enabled
    ///   then finishing the ``NIOAsyncChannelWriter`` will lead to half closure.
    /// - Returns: A ``NIOAsyncChannel`` of connection ``NIOAsyncChannel``s.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @_spi(AsyncChannel)
    public func bind<ChildChannelInbound: Sendable, ChildChannelOutbound: Sendable>(
        unixDomainSocketPath: String,
        cleanupExistingSocketFile: Bool = false,
        serverBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        childBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        childChannelInboundType: ChildChannelInbound.Type = ChildChannelInbound.self,
        childChannelOutboundType: ChildChannelOutbound.Type = ChildChannelOutbound.self,
        isChildChannelOutboundHalfClosureEnabled: Bool = false
    ) async throws -> NIOAsyncChannel<NIOAsyncChannel<ChildChannelInbound, ChildChannelOutbound>, Never> {
        if cleanupExistingSocketFile {
            try BaseSocket.cleanupSocket(unixDomainSocketPath: unixDomainSocketPath)
        }

        return try await self.bind(
            unixDomainSocketPath: unixDomainSocketPath,
            serverBackpressureStrategy: serverBackpressureStrategy,
            childBackpressureStrategy: childBackpressureStrategy,
            isChildChannelOutboundHalfClosureEnabled: isChildChannelOutboundHalfClosureEnabled
        )
    }

    /// Use the existing bound socket file descriptor.
    ///
    /// - Parameters:
    ///   - socket: The _Unix file descriptor_ representing the bound stream socket.
    ///   - serverBackpressureStrategy: The back pressure strategy used by the server socket channel.
    ///   - childBackpressureStrategy: The back pressure strategy used by the child channels.
    ///   - childChannelInboundType: The child channel's inbound type.
    ///   - childChannelOutboundType: The child channel's outbound type.
    ///   - isChildChannelOutboundHalfClosureEnabled: Indicates if half closure is enabled on the child channels. If half closure is enabled
    ///   then finishing the ``NIOAsyncChannelWriter`` will lead to half closure.
    /// - Returns: A ``NIOAsyncChannel`` of connection ``NIOAsyncChannel``s.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @_spi(AsyncChannel)
    public func withBoundSocket<ChildChannelInbound: Sendable, ChildChannelOutbound: Sendable>(
        _ socket: NIOBSDSocket.Handle,
        serverBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        childBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        childChannelInboundType: ChildChannelInbound.Type = ChildChannelInbound.self,
        childChannelOutboundType: ChildChannelOutbound.Type = ChildChannelOutbound.self,
        isChildChannelOutboundHalfClosureEnabled: Bool = false
    ) async throws -> NIOAsyncChannel<NIOAsyncChannel<ChildChannelInbound, ChildChannelOutbound>, Never> {
        func makeChannel(_ eventLoop: SelectableEventLoop, _ childEventLoopGroup: EventLoopGroup, _ enableMPTCP: Bool) throws -> ServerSocketChannel {
            if enableMPTCP {
                throw ChannelError.operationUnsupported
            }
            return try ServerSocketChannel(socket: socket, eventLoop: eventLoop, group: childEventLoopGroup)
        }
        return try await self.bindAsyncChannel0(
            makeServerChannel: makeChannel,
            serverBackpressureStrategy: serverBackpressureStrategy,
            childBackpressureStrategy: childBackpressureStrategy,
            isChildChannelOutboundHalfClosureEnabled: isChildChannelOutboundHalfClosureEnabled
        ) { (eventLoop, serverChannel) in
            let promise = eventLoop.makePromise(of: Void.self)
            serverChannel.registerAlreadyConfigured0(promise: promise)
            return promise.futureResult
        }
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    private func bindAsyncChannel0<ChildChannelInbound: Sendable, ChildChannelOutbound: Sendable>(
        serverBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        childBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        isChildChannelOutboundHalfClosureEnabled: Bool,
        _ makeSocketAddress: () throws -> SocketAddress
    ) async throws -> NIOAsyncChannel<NIOAsyncChannel<ChildChannelInbound, ChildChannelOutbound>, Never> {
        let address = try makeSocketAddress()

        func makeChannel(_ eventLoop: SelectableEventLoop, _ childEventLoopGroup: EventLoopGroup, _ enableMPTCP: Bool) throws -> ServerSocketChannel {
            return try ServerSocketChannel(eventLoop: eventLoop,
                                           group: childEventLoopGroup,
                                           protocolFamily: address.protocol,
                                           enableMPTCP: enableMPTCP)
        }

        return try await self.bindAsyncChannel0(
            makeServerChannel: makeChannel,
            serverBackpressureStrategy: serverBackpressureStrategy,
            childBackpressureStrategy: childBackpressureStrategy,
            isChildChannelOutboundHalfClosureEnabled: isChildChannelOutboundHalfClosureEnabled
        ) { (eventLoop, serverChannel) in
            serverChannel.registerAndDoSynchronously { serverChannel in
                serverChannel.bind(to: address)
            }
        }
    }

    private typealias MakeServerChannel = (_ eventLoop: SelectableEventLoop, _ childGroup: EventLoopGroup, _ enableMPTCP: Bool) throws -> ServerSocketChannel
    private typealias Register = @Sendable (EventLoop, ServerSocketChannel) -> EventLoopFuture<Void>

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    private func bindAsyncChannel0<ChildChannelInbound: Sendable, ChildChannelOutbound: Sendable>(
        makeServerChannel: MakeServerChannel,
        serverBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        childBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        isChildChannelOutboundHalfClosureEnabled: Bool,
        _ register: @escaping Register
    ) async throws -> NIOAsyncChannel<NIOAsyncChannel<ChildChannelInbound, ChildChannelOutbound>, Never>  {
        let eventLoop = self.group.next()
        let childEventLoopGroup = self.childGroup
        let serverChannelOptions = self._serverChannelOptions
        let serverChannelInit = self.serverChannelInit ?? { _ in eventLoop.makeSucceededFuture(()) }
        let childChannelInit = self.childChannelInit
        let childChannelOptions = self._childChannelOptions

        let serverChannel = try makeServerChannel(eventLoop as! SelectableEventLoop, childEventLoopGroup, self.enableMPTCP)

        return try await eventLoop.submit {
            serverChannelOptions.applyAllChannelOptions(to: serverChannel).flatMap {
                serverChannelInit(serverChannel)
            }.flatMap {
                do {
                    try serverChannel.pipeline.syncOperations.addHandler(
                        AcceptHandler(childChannelInitializer: childChannelInit, childChannelOptions: childChannelOptions),
                        name: "AcceptHandler"
                    )

                    // We are wrapping the inbound channels into `NIOAsyncChannel`s with the transformation
                    // closure of the `NIOAsyncChannel` that allows us to wrap them without adding
                    // wrapping/unwrapping handlers to the pipeline.
                    let asyncChannel = try NIOAsyncChannel<NIOAsyncChannel<ChildChannelInbound, ChildChannelOutbound>, Never>.wrapAsyncChannelForBootstrapBind(
                        synchronouslyWrapping: serverChannel,
                        backpressureStrategy: serverBackpressureStrategy,
                        transformationClosure: { channel in
                            // We must hop to the child channel event loop here to add the async channel handlers
                            channel.eventLoop.submit {
                                try NIOAsyncChannel(
                                    synchronouslyWrapping: channel,
                                    backpressureStrategy: childBackpressureStrategy,
                                    isOutboundHalfClosureEnabled: isChildChannelOutboundHalfClosureEnabled,
                                    inboundType: ChildChannelInbound.self,
                                    outboundType: ChildChannelOutbound.self
                                )
                            }
                        }
                    )
                    return register(eventLoop, serverChannel).map { asyncChannel }
                } catch {
                    return eventLoop.makeFailedFuture(error)
                }
            }.flatMapError { error in
                serverChannel.close0(error: error, mode: .all, promise: nil)
                return eventLoop.makeFailedFuture(error)
            }
        }.flatMap {
            $0
        }.get()
    }
}

// MARK: AsyncChannel based bind with protocol negotiation
extension ServerBootstrap {
    /// Bind the `ServerSocketChannel` to the `host` and `port` parameters.
    /// Waiting for protocol negotiation to finish before yielding the channel to the returned ``NIOAsyncChannel``.
    ///
    /// - Parameters:
    ///   - host: The host to bind on.
    ///   - port: The port to bind on.
    ///   - protocolNegotiationHandlerType: The protocol negotiation handler type that is awaited on. A handler of this type
    ///   must be added to the pipeline in the child channel initializer.
    ///   - serverBackpressureStrategy: The back pressure strategy used by the server socket channel.
    /// - Returns: A ``NIOAsyncChannel`` of  the protocol negotiation results. It is expected that the protocol negotiation handler
    /// is going to wrap the child channels into ``NIOAsyncChannel`` which are returned as part of the negotiation result.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @_spi(AsyncChannel)
    public func bind<Handler: NIOProtocolNegotiationHandler>(
        host: String,
        port: Int,
        protocolNegotiationHandlerType: Handler.Type,
        serverBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil
    ) async throws -> NIOAsyncChannel<Handler.NegotiationResult, Never> {
        return try await self.bindAsyncChannelWithProtocolNegotiation0(
            protocolNegotiationHandlerType: protocolNegotiationHandlerType,
            serverBackpressureStrategy: serverBackpressureStrategy
        ) {
            return try SocketAddress.makeAddressResolvingHost(host, port: port)
        }
    }

    /// Bind the `ServerSocketChannel` to the `address` parameter.
    /// Waiting for protocol negotiation to finish before yielding the channel to the returned ``NIOAsyncChannel``.
    ///
    /// - Parameters:
    ///   - address: The `SocketAddress` to bind on.
    ///   - protocolNegotiationHandlerType: The protocol negotiation handler type that is awaited on. A handler of this type
    ///   must be added to the pipeline in the child channel initializer.
    ///   - serverBackpressureStrategy: The back pressure strategy used by the server socket channel.
    /// - Returns: A ``NIOAsyncChannel`` of  the protocol negotiation results. It is expected that the protocol negotiation handler
    /// is going to wrap the child channels into ``NIOAsyncChannel`` which are returned as part of the negotiation result.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @_spi(AsyncChannel)
    public func bind<Handler: NIOProtocolNegotiationHandler>(
        to address: SocketAddress,
        protocolNegotiationHandlerType: Handler.Type,
        serverBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil
    ) async throws -> NIOAsyncChannel<Handler.NegotiationResult, Never> {
        return try await self.bindAsyncChannelWithProtocolNegotiation0(
            protocolNegotiationHandlerType: protocolNegotiationHandlerType,
            serverBackpressureStrategy: serverBackpressureStrategy
        ) { address }
    }

    /// Bind the `ServerSocketChannel` to a UNIX Domain Socket.
    /// Waiting for protocol negotiation to finish before yielding the channel to the returned ``NIOAsyncChannel``.
    ///
    /// - Parameters:
    ///   - unixDomainSocketPath: The path of the UNIX Domain Socket to bind on. The`unixDomainSocketPath` must not exist,
    ///     unless `cleanupExistingSocketFile`is set to `true`.
    ///   - cleanupExistingSocketFile: Whether to cleanup an existing socket file at `unixDomainSocketPath`.
    ///   - protocolNegotiationHandlerType: The protocol negotiation handler type that is awaited on. A handler of this type
    ///   must be added to the pipeline in the child channel initializer.
    ///   - serverBackpressureStrategy: The back pressure strategy used by the server socket channel.
    /// - Returns: A ``NIOAsyncChannel`` of  the protocol negotiation results. It is expected that the protocol negotiation handler
    /// is going to wrap the child channels into ``NIOAsyncChannel`` which are returned as part of the negotiation result.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @_spi(AsyncChannel)
    public func bind<Handler: NIOProtocolNegotiationHandler>(
        unixDomainSocketPath: String,
        cleanupExistingSocketFile: Bool = false,
        protocolNegotiationHandlerType: Handler.Type,
        serverBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil
    ) async throws -> NIOAsyncChannel<Handler.NegotiationResult, Never> {
        if cleanupExistingSocketFile {
            try BaseSocket.cleanupSocket(unixDomainSocketPath: unixDomainSocketPath)
        }

        return try await self.bind(
            unixDomainSocketPath: unixDomainSocketPath,
            protocolNegotiationHandlerType: protocolNegotiationHandlerType,
            serverBackpressureStrategy: serverBackpressureStrategy
        )
    }

    /// Use the existing bound socket file descriptor.
    /// Waiting for protocol negotiation to finish before yielding the channel to the returned ``NIOAsyncChannel``.
    ///
    /// - Parameters:
    ///   - socket: The _Unix file descriptor_ representing the bound stream socket.
    ///   - protocolNegotiationHandlerType: The protocol negotiation handler type that is awaited on. A handler of this type
    ///   must be added to the pipeline in the child channel initializer.
    ///   - serverBackpressureStrategy: The back pressure strategy used by the server socket channel.
    /// - Returns: A ``NIOAsyncChannel`` of  the protocol negotiation results. It is expected that the protocol negotiation handler
    /// is going to wrap the child channels into ``NIOAsyncChannel`` which are returned as part of the negotiation result.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @_spi(AsyncChannel)
    public func withBoundSocket<Handler: NIOProtocolNegotiationHandler>(
        _ socket: NIOBSDSocket.Handle,
        protocolNegotiationHandlerType: Handler.Type,
        serverBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil
    ) async throws -> NIOAsyncChannel<Handler.NegotiationResult, Never> {
        func makeChannel(_ eventLoop: SelectableEventLoop, _ childEventLoopGroup: EventLoopGroup, _ enableMPTCP: Bool) throws -> ServerSocketChannel {
            if enableMPTCP {
                throw ChannelError.operationUnsupported
            }
            return try ServerSocketChannel(socket: socket, eventLoop: eventLoop, group: childEventLoopGroup)
        }
        return try await self.bindAsyncChannelWithProtocolNegotiation0(
            makeServerChannel: makeChannel,
            protocolNegotiationHandlerType: protocolNegotiationHandlerType,
            serverBackpressureStrategy: serverBackpressureStrategy
        ) { (eventLoop, serverChannel) in
            let promise = eventLoop.makePromise(of: Void.self)
            serverChannel.registerAlreadyConfigured0(promise: promise)
            return promise.futureResult
        }
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    private func bindAsyncChannelWithProtocolNegotiation0<Handler: NIOProtocolNegotiationHandler & ChannelHandler>(
        protocolNegotiationHandlerType: Handler.Type,
        serverBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        _ makeSocketAddress: () throws -> SocketAddress
    ) async throws -> NIOAsyncChannel<Handler.NegotiationResult, Never> {
        let address = try makeSocketAddress()

        func makeChannel(_ eventLoop: SelectableEventLoop, _ childEventLoopGroup: EventLoopGroup, _ enableMPTCP: Bool) throws -> ServerSocketChannel {
            return try ServerSocketChannel(eventLoop: eventLoop,
                                           group: childEventLoopGroup,
                                           protocolFamily: address.protocol,
                                           enableMPTCP: enableMPTCP)
        }

        return try await self.bindAsyncChannelWithProtocolNegotiation0(
            makeServerChannel: makeChannel,
            protocolNegotiationHandlerType: protocolNegotiationHandlerType,
            serverBackpressureStrategy: serverBackpressureStrategy
        ) { (eventLoop, serverChannel) in
            serverChannel.registerAndDoSynchronously { serverChannel in
                serverChannel.bind(to: address)
            }
        }
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    private func bindAsyncChannelWithProtocolNegotiation0<Handler: NIOProtocolNegotiationHandler & ChannelHandler>(
        makeServerChannel: MakeServerChannel,
        protocolNegotiationHandlerType: Handler.Type,
        serverBackpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        _ register: @escaping Register
    ) async throws -> NIOAsyncChannel<Handler.NegotiationResult, Never>  {
        let eventLoop = self.group.next()
        let childEventLoopGroup = self.childGroup
        let serverChannelOptions = self._serverChannelOptions
        let serverChannelInit = self.serverChannelInit ?? { _ in eventLoop.makeSucceededFuture(()) }
        let childChannelInit = self.childChannelInit
        let childChannelOptions = self._childChannelOptions

        let serverChannel = try makeServerChannel(eventLoop as! SelectableEventLoop, childEventLoopGroup, self.enableMPTCP)

        return try await eventLoop.submit {
            serverChannelOptions.applyAllChannelOptions(to: serverChannel).flatMap {
                serverChannelInit(serverChannel)
            }.flatMap {
                do {
                    try serverChannel.pipeline.syncOperations.addHandler(
                        AcceptHandler(childChannelInitializer: childChannelInit, childChannelOptions: childChannelOptions),
                        name: "AcceptHandler"
                    )

                    // In the case of protocol negotiation we cannot wrap the child channels into
                    // `NIOAsyncChannel`s for the user since we don't know the type. We rather expect
                    // the user to wrap the child channels themselves when the negotiation is done
                    // and return the wrapped async channel as part of the negotiation result.
                    let asyncChannel = try NIOAsyncChannel<Handler.NegotiationResult, Never>.wrapAsyncChannelForBootstrapBindWithProtocolNegotiation(
                        synchronouslyWrapping: serverChannel,
                        backpressureStrategy: serverBackpressureStrategy,
                        transformationClosure: { (channel: Channel) in
                            channel.pipeline.handler(type: protocolNegotiationHandlerType)
                                .flatMap { handler -> EventLoopFuture<NIOProtocolNegotiationResult<Handler.NegotiationResult>> in
                                    handler.protocolNegotiationResult
                                }.flatMap { result in
                                    ServerBootstrap.waitForFinalResult(result, eventLoop: eventLoop)
                                }.flatMapErrorThrowing { error in
                                    channel.pipeline.fireErrorCaught(error)
                                    channel.close(promise: nil)
                                    throw error
                                }
                        }

                    )
                    return register(eventLoop, serverChannel).map { asyncChannel }
                } catch {
                    return eventLoop.makeFailedFuture(error)
                }
            }.flatMapError { error in
                serverChannel.close0(error: error, mode: .all, promise: nil)
                return eventLoop.makeFailedFuture(error)
            }
        }.flatMap {
            $0
        }.get()
    }

    /// This method recursively waits for the final result of protocol negotiation
    static func waitForFinalResult<NegotiationResult>(
        _ result: NIOProtocolNegotiationResult<NegotiationResult>,
        eventLoop: EventLoop
    ) -> EventLoopFuture<NegotiationResult> {
        switch result {
        case .finished(let negotiationResult):
            return eventLoop.makeSucceededFuture(negotiationResult)

        case .deferredResult(let future):
            return future.flatMap { result in
                return waitForFinalResult(result, eventLoop: eventLoop)
            }
        }
    }
}

@available(*, unavailable)
extension ServerBootstrap: Sendable {}

private extension Channel {
    func registerAndDoSynchronously(_ body: @escaping (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Void> {
        // this is pretty delicate at the moment:
        // In many cases `body` must be _synchronously_ follow `register`, otherwise in our current
        // implementation, `epoll` will send us `EPOLLHUP`. To have it run synchronously, we need to invoke the
        // `flatMap` on the eventloop that the `register` will succeed on.
        self.eventLoop.assertInEventLoop()
        return self.register().flatMap {
            self.eventLoop.assertInEventLoop()
            return body(self)
        }
    }
}

/// A `ClientBootstrap` is an easy way to bootstrap a `SocketChannel` when creating network clients.
///
/// Usually you re-use a `ClientBootstrap` once you set it up and called `connect` multiple times on it.
/// This way you ensure that the same `EventLoop`s will be shared across all your connections.
///
/// Example:
///
/// ```swift
///     let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
///     defer {
///         try! group.syncShutdownGracefully()
///     }
///     let bootstrap = ClientBootstrap(group: group)
///         // Enable SO_REUSEADDR.
///         .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
///         .channelInitializer { channel in
///             // always instantiate the handler _within_ the closure as
///             // it may be called multiple times (for example if the hostname
///             // resolves to both IPv4 and IPv6 addresses, cf. Happy Eyeballs).
///             channel.pipeline.addHandler(MyChannelHandler())
///         }
///     try! bootstrap.connect(host: "example.org", port: 12345).wait()
///     /* the Channel is now connected */
/// ```
///
/// The connected `SocketChannel` will operate on `ByteBuffer` as inbound and on `IOData` as outbound messages.
public final class ClientBootstrap: NIOClientTCPBootstrapProtocol {
    private let group: EventLoopGroup
    #if swift(>=5.7)
    private var protocolHandlers: Optional<@Sendable () -> [ChannelHandler]>
    #else
    private var protocolHandlers: Optional<() -> [ChannelHandler]>
    #endif
    private var _channelInitializer: ChannelInitializerCallback
    private var channelInitializer: ChannelInitializerCallback {
        if let protocolHandlers = self.protocolHandlers {
            let channelInitializer = _channelInitializer
            return { channel in
                channelInitializer(channel).flatMap {
                    channel.pipeline.addHandlers(protocolHandlers(), position: .first)
                }
            }
        } else {
            return self._channelInitializer
        }
    }
    @usableFromInline
    internal var _channelOptions: ChannelOptions.Storage
    private var connectTimeout: TimeAmount = TimeAmount.seconds(10)
    private var resolver: Optional<Resolver>
    private var bindTarget: Optional<SocketAddress>
    private var enableMPTCP: Bool

    /// Create a `ClientBootstrap` on the `EventLoopGroup` `group`.
    ///
    /// The `EventLoopGroup` `group` must be compatible, otherwise the program will crash. `ClientBootstrap` is
    /// compatible only with `MultiThreadedEventLoopGroup` as well as the `EventLoop`s returned by
    /// `MultiThreadedEventLoopGroup.next`. See `init(validatingGroup:)` for a fallible initializer for
    /// situations where it's impossible to tell ahead of time if the `EventLoopGroup` is compatible or not.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use.
    public convenience init(group: EventLoopGroup) {
        guard NIOOnSocketsBootstraps.isCompatible(group: group) else {
            preconditionFailure("ClientBootstrap is only compatible with MultiThreadedEventLoopGroup and " +
                                "SelectableEventLoop. You tried constructing one with \(group) which is incompatible.")
        }
        self.init(validatingGroup: group)!
    }

    /// Create a `ClientBootstrap` on the `EventLoopGroup` `group`, validating that `group` is compatible.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use.
    public init?(validatingGroup group: EventLoopGroup) {
        guard NIOOnSocketsBootstraps.isCompatible(group: group) else {
            return nil
        }
        self.group = group
        self._channelOptions = ChannelOptions.Storage()
        self._channelOptions.append(key: ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
        self._channelInitializer = { channel in channel.eventLoop.makeSucceededFuture(()) }
        self.protocolHandlers = nil
        self.resolver = nil
        self.bindTarget = nil
        self.enableMPTCP = false
    }

    #if swift(>=5.7)
    /// Initialize the connected `SocketChannel` with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// The connected `Channel` will operate on `ByteBuffer` as inbound and `IOData` as outbound messages.
    ///
    /// - warning: The `handler` closure may be invoked _multiple times_ so it's usually the right choice to instantiate
    ///            `ChannelHandler`s within `handler`. The reason `handler` may be invoked multiple times is that to
    ///            successfully set up a connection multiple connections might be setup in the process. Assuming a
    ///            hostname that resolves to both IPv4 and IPv6 addresses, NIO will follow
    ///            [_Happy Eyeballs_](https://en.wikipedia.org/wiki/Happy_Eyeballs) and race both an IPv4 and an IPv6
    ///            connection. It is possible that both connections get fully established before the IPv4 connection
    ///            will be closed again because the IPv6 connection 'won the race'. Therefore the `channelInitializer`
    ///            might be called multiple times and it's important not to share stateful `ChannelHandler`s in more
    ///            than one `Channel`.
    ///
    /// - parameters:
    ///     - handler: A closure that initializes the provided `Channel`.
    @preconcurrency
    public func channelInitializer(_ handler: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> Self {
        self._channelInitializer = handler
        return self
    }
    #else
    /// Initialize the connected `SocketChannel` with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// The connected `Channel` will operate on `ByteBuffer` as inbound and `IOData` as outbound messages.
    ///
    /// - warning: The `handler` closure may be invoked _multiple times_ so it's usually the right choice to instantiate
    ///            `ChannelHandler`s within `handler`. The reason `handler` may be invoked multiple times is that to
    ///            successfully set up a connection multiple connections might be setup in the process. Assuming a
    ///            hostname that resolves to both IPv4 and IPv6 addresses, NIO will follow
    ///            [_Happy Eyeballs_](https://en.wikipedia.org/wiki/Happy_Eyeballs) and race both an IPv4 and an IPv6
    ///            connection. It is possible that both connections get fully established before the IPv4 connection
    ///            will be closed again because the IPv6 connection 'won the race'. Therefore the `channelInitializer`
    ///            might be called multiple times and it's important not to share stateful `ChannelHandler`s in more
    ///            than one `Channel`.
    ///
    /// - parameters:
    ///     - handler: A closure that initializes the provided `Channel`.
    public func channelInitializer(_ handler: @escaping (Channel) -> EventLoopFuture<Void>) -> Self {
        self._channelInitializer = handler
        return self
    }
    #endif

    #if swift(>=5.7)
    /// Sets the protocol handlers that will be added to the front of the `ChannelPipeline` right after the
    /// `channelInitializer` has been called.
    ///
    /// Per bootstrap, you can only set the `protocolHandlers` once. Typically, `protocolHandlers` are used for the TLS
    /// implementation. Most notably, `NIOClientTCPBootstrap`, NIO's "universal bootstrap" abstraction, uses
    /// `protocolHandlers` to add the required `ChannelHandler`s for many TLS implementations.
    @preconcurrency
    public func protocolHandlers(_ handlers: @escaping @Sendable () -> [ChannelHandler]) -> Self {
        precondition(self.protocolHandlers == nil, "protocol handlers can only be set once")
        self.protocolHandlers = handlers
        return self
    }
    #else
    /// Sets the protocol handlers that will be added to the front of the `ChannelPipeline` right after the
    /// `channelInitializer` has been called.
    ///
    /// Per bootstrap, you can only set the `protocolHandlers` once. Typically, `protocolHandlers` are used for the TLS
    /// implementation. Most notably, `NIOClientTCPBootstrap`, NIO's "universal bootstrap" abstraction, uses
    /// `protocolHandlers` to add the required `ChannelHandler`s for many TLS implementations.
    public func protocolHandlers(_ handlers: @escaping () -> [ChannelHandler]) -> Self {
        precondition(self.protocolHandlers == nil, "protocol handlers can only be set once")
        self.protocolHandlers = handlers
        return self
    }
    #endif

    /// Specifies a `ChannelOption` to be applied to the `SocketChannel`.
    ///
    /// - parameters:
    ///     - option: The option to be applied.
    ///     - value: The value for the option.
    @inlinable
    public func channelOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
        self._channelOptions.append(key: option, value: value)
        return self
    }

    /// Specifies a timeout to apply to a connection attempt.
    ///
    /// - parameters:
    ///     - timeout: The timeout that will apply to the connection attempt.
    public func connectTimeout(_ timeout: TimeAmount) -> Self {
        self.connectTimeout = timeout
        return self
    }

    /// Specifies the `Resolver` to use or `nil` if the default should be used.
    ///
    /// - parameters:
    ///     - resolver: The resolver that will be used during the connection attempt.
    public func resolver(_ resolver: Resolver?) -> Self {
        self.resolver = resolver
        return self
    }

    /// Enables multi-path TCP support.
    ///
    /// This option is only supported on some systems, and will lead to bind
    /// failing if the system does not support it. Users are recommended to
    /// only enable this in response to configuration or feature detection.
    ///
    /// > Note: Enabling this setting will re-enable Nagle's algorithm, even if it
    /// > had been disabled. This is a temporary workaround for a Linux kernel
    /// > limitation.
    ///
    /// - parameters:
    ///     - value: Whether to enable MPTCP or not.
    public func enableMPTCP(_ value: Bool) -> Self {
        self.enableMPTCP = value

        // This is a temporary workaround until we get some stable Linux kernel
        // versions that support TCP_NODELAY and MPTCP.
        if value {
            self._channelOptions.remove(key: ChannelOptions.tcpOption(.tcp_nodelay))
        }

        return self
    }

    /// Bind the `SocketChannel` to `address`.
    ///
    /// Using `bind` is not necessary unless you need the local address to be bound to a specific address.
    ///
    /// - note: Using `bind` will disable Happy Eyeballs on this `Channel`.
    ///
    /// - parameters:
    ///     - address: The `SocketAddress` to bind on.
    public func bind(to address: SocketAddress) -> ClientBootstrap {
        self.bindTarget = address
        return self
    }

    func makeSocketChannel(eventLoop: EventLoop,
                           protocolFamily: NIOBSDSocket.ProtocolFamily) throws -> SocketChannel {
        return try SocketChannel(eventLoop: eventLoop as! SelectableEventLoop, protocolFamily: protocolFamily, enableMPTCP: self.enableMPTCP)
    }

    /// Specify the `host` and `port` to connect to for the TCP `Channel` that will be established.
    ///
    /// - parameters:
    ///     - host: The host to connect to.
    ///     - port: The port to connect to.
    /// - returns: An `EventLoopFuture<Channel>` to deliver the `Channel` when connected.
    public func connect(host: String, port: Int) -> EventLoopFuture<Channel> {
        let loop = self.group.next()
        let resolver = self.resolver ?? GetaddrinfoResolver(loop: loop,
                                                            aiSocktype: .stream,
                                                            aiProtocol: .tcp)
        let connector = HappyEyeballsConnector(resolver: resolver,
                                               loop: loop,
                                               host: host,
                                               port: port,
                                               connectTimeout: self.connectTimeout) { eventLoop, protocolFamily in
            return self.initializeAndRegisterNewChannel(eventLoop: eventLoop, protocolFamily: protocolFamily) {
                $0.eventLoop.makeSucceededFuture(())
            }
        }
        return connector.resolveAndConnect()
    }

    private func connect(freshChannel channel: Channel, address: SocketAddress) -> EventLoopFuture<Void> {
        let connectPromise = channel.eventLoop.makePromise(of: Void.self)
        channel.connect(to: address, promise: connectPromise)
        let cancelTask = channel.eventLoop.scheduleTask(in: self.connectTimeout) {
            connectPromise.fail(ChannelError.connectTimeout(self.connectTimeout))
            channel.close(promise: nil)
        }

        connectPromise.futureResult.whenComplete { (_: Result<Void, Error>) in
            cancelTask.cancel()
        }
        return connectPromise.futureResult
    }

    internal func testOnly_connect(injectedChannel: SocketChannel,
                                   to address: SocketAddress) -> EventLoopFuture<Channel> {
        return self.initializeAndRegisterChannel(injectedChannel) { channel in
            return self.connect(freshChannel: channel, address: address)
        }
    }

    /// Specify the `address` to connect to for the TCP `Channel` that will be established.
    ///
    /// - parameters:
    ///     - address: The address to connect to.
    /// - returns: An `EventLoopFuture<Channel>` to deliver the `Channel` when connected.
    public func connect(to address: SocketAddress) -> EventLoopFuture<Channel> {
        return self.initializeAndRegisterNewChannel(eventLoop: self.group.next(),
                                                    protocolFamily: address.protocol) { channel in
            return self.connect(freshChannel: channel, address: address)
        }
    }

    /// Specify the `unixDomainSocket` path to connect to for the UDS `Channel` that will be established.
    ///
    /// - parameters:
    ///     - unixDomainSocketPath: The _Unix domain socket_ path to connect to.
    /// - returns: An `EventLoopFuture<Channel>` to deliver the `Channel` when connected.
    public func connect(unixDomainSocketPath: String) -> EventLoopFuture<Channel> {
        do {
            let address = try SocketAddress(unixDomainSocketPath: unixDomainSocketPath)
            return self.connect(to: address)
        } catch {
            return self.group.next().makeFailedFuture(error)
        }
    }

    #if !os(Windows)
        /// Use the existing connected socket file descriptor.
        ///
        /// - parameters:
        ///     - descriptor: The _Unix file descriptor_ representing the connected stream socket.
        /// - returns: an `EventLoopFuture<Channel>` to deliver the `Channel`.
        @available(*, deprecated, renamed: "withConnectedSocket(_:)")
        public func withConnectedSocket(descriptor: CInt) -> EventLoopFuture<Channel> {
          return self.withConnectedSocket(descriptor)
        }
    #endif

    /// Use the existing connected socket file descriptor.
    ///
    /// - parameters:
    ///     - descriptor: The _Unix file descriptor_ representing the connected stream socket.
    /// - returns: an `EventLoopFuture<Channel>` to deliver the `Channel`.
    public func withConnectedSocket(_ socket: NIOBSDSocket.Handle) -> EventLoopFuture<Channel> {
        let eventLoop = group.next()
        let channelInitializer = self.channelInitializer
        let channel: SocketChannel
        do {
            channel = try SocketChannel(eventLoop: eventLoop as! SelectableEventLoop, socket: socket)
        } catch {
            return eventLoop.makeFailedFuture(error)
        }

        func setupChannel() -> EventLoopFuture<Channel> {
            eventLoop.assertInEventLoop()
            return self._channelOptions.applyAllChannelOptions(to: channel).flatMap {
                channelInitializer(channel)
            }.flatMap {
                eventLoop.assertInEventLoop()
                let promise = eventLoop.makePromise(of: Void.self)
                channel.registerAlreadyConfigured0(promise: promise)
                return promise.futureResult
            }.map {
                channel
            }.flatMapError { error in
                channel.close0(error: error, mode: .all, promise: nil)
                return channel.eventLoop.makeFailedFuture(error)
            }
        }

        if eventLoop.inEventLoop {
            return setupChannel()
        } else {
            return eventLoop.flatSubmit { setupChannel() }
        }
    }

    private func initializeAndRegisterNewChannel(eventLoop: EventLoop,
                                                 protocolFamily: NIOBSDSocket.ProtocolFamily,
                                                 _ body: @escaping (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel> {
        let channel: SocketChannel
        do {
            channel = try self.makeSocketChannel(eventLoop: eventLoop, protocolFamily: protocolFamily)
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
        return self.initializeAndRegisterChannel(channel, body)
    }

    private func initializeAndRegisterChannel(_ channel: SocketChannel,
                                              _ body: @escaping (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel> {
        let channelInitializer = self.channelInitializer
        let channelOptions = self._channelOptions
        let eventLoop = channel.eventLoop

        @inline(__always)
        func setupChannel() -> EventLoopFuture<Channel> {
            eventLoop.assertInEventLoop()
            return channelOptions.applyAllChannelOptions(to: channel).flatMap {
                if let bindTarget = self.bindTarget {
                    return channel.bind(to: bindTarget).flatMap {
                        channelInitializer(channel)
                    }
                } else {
                    return channelInitializer(channel)
                }
            }.flatMap {
                eventLoop.assertInEventLoop()
                return channel.registerAndDoSynchronously(body)
            }.map {
                channel
            }.flatMapError { error in
                channel.close0(error: error, mode: .all, promise: nil)
                return channel.eventLoop.makeFailedFuture(error)
            }
        }

        if eventLoop.inEventLoop {
            return setupChannel()
        } else {
            return eventLoop.flatSubmit {
                setupChannel()
            }
        }
    }
}

@available(*, unavailable)
extension ClientBootstrap: Sendable {}

/// A `DatagramBootstrap` is an easy way to bootstrap a `DatagramChannel` when creating datagram clients
/// and servers.
///
/// Example:
///
/// ```swift
///     let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
///     defer {
///         try! group.syncShutdownGracefully()
///     }
///     let bootstrap = DatagramBootstrap(group: group)
///         // Enable SO_REUSEADDR.
///         .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
///         .channelInitializer { channel in
///             channel.pipeline.addHandler(MyChannelHandler())
///         }
///     let channel = try! bootstrap.bind(host: "127.0.0.1", port: 53).wait()
///     /* the Channel is now ready to send/receive datagrams */
///
///     try channel.closeFuture.wait()  // Wait until the channel un-binds.
/// ```
///
/// The `DatagramChannel` will operate on `AddressedEnvelope<ByteBuffer>` as inbound and outbound messages.
public final class DatagramBootstrap {

    private let group: EventLoopGroup
    private var channelInitializer: Optional<ChannelInitializerCallback>
    @usableFromInline
    internal var _channelOptions: ChannelOptions.Storage

    /// Create a `DatagramBootstrap` on the `EventLoopGroup` `group`.
    ///
    /// The `EventLoopGroup` `group` must be compatible, otherwise the program will crash. `DatagramBootstrap` is
    /// compatible only with `MultiThreadedEventLoopGroup` as well as the `EventLoop`s returned by
    /// `MultiThreadedEventLoopGroup.next`. See `init(validatingGroup:)` for a fallible initializer for
    /// situations where it's impossible to tell ahead of time if the `EventLoopGroup` is compatible or not.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use.
    public convenience init(group: EventLoopGroup) {
        guard NIOOnSocketsBootstraps.isCompatible(group: group) else {
            preconditionFailure("DatagramBootstrap is only compatible with MultiThreadedEventLoopGroup and " +
                                "SelectableEventLoop. You tried constructing one with \(group) which is incompatible.")
        }
        self.init(validatingGroup: group)!
    }

    /// Create a `DatagramBootstrap` on the `EventLoopGroup` `group`, validating that `group` is compatible.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use.
    public init?(validatingGroup group: EventLoopGroup) {
        guard NIOOnSocketsBootstraps.isCompatible(group: group) else {
            return nil
        }
        self._channelOptions = ChannelOptions.Storage()
        self.group = group
        self.channelInitializer = nil
    }

    #if swift(>=5.7)
    /// Initialize the bound `DatagramChannel` with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - handler: A closure that initializes the provided `Channel`.
    @preconcurrency
    public func channelInitializer(_ handler: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> Self {
        self.channelInitializer = handler
        return self
    }
    #else
    /// Initialize the bound `DatagramChannel` with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - handler: A closure that initializes the provided `Channel`.
    public func channelInitializer(_ handler: @escaping (Channel) -> EventLoopFuture<Void>) -> Self {
        self.channelInitializer = handler
        return self
    }
    #endif

    /// Specifies a `ChannelOption` to be applied to the `DatagramChannel`.
    ///
    /// - parameters:
    ///     - option: The option to be applied.
    ///     - value: The value for the option.
    @inlinable
    public func channelOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
        self._channelOptions.append(key: option, value: value)
        return self
    }

    #if !os(Windows)
        /// Use the existing bound socket file descriptor.
        ///
        /// - parameters:
        ///     - descriptor: The _Unix file descriptor_ representing the bound datagram socket.
        @available(*, deprecated, renamed: "withBoundSocket(_:)")
        public func withBoundSocket(descriptor: CInt) -> EventLoopFuture<Channel> {
            return self.withBoundSocket(descriptor)
        }
    #endif

    /// Use the existing bound socket file descriptor.
    ///
    /// - parameters:
    ///     - descriptor: The _Unix file descriptor_ representing the bound datagram socket.
    public func withBoundSocket(_ socket: NIOBSDSocket.Handle) -> EventLoopFuture<Channel> {
        func makeChannel(_ eventLoop: SelectableEventLoop) throws -> DatagramChannel {
            return try DatagramChannel(eventLoop: eventLoop, socket: socket)
        }
        return withNewChannel(makeChannel: makeChannel) { (eventLoop, channel) in
            let promise = eventLoop.makePromise(of: Void.self)
            channel.registerAlreadyConfigured0(promise: promise)
            return promise.futureResult
        }
    }

    /// Bind the `DatagramChannel` to `host` and `port`.
    ///
    /// - parameters:
    ///     - host: The host to bind on.
    ///     - port: The port to bind on.
    public func bind(host: String, port: Int) -> EventLoopFuture<Channel> {
        return bind0 {
            return try SocketAddress.makeAddressResolvingHost(host, port: port)
        }
    }

    /// Bind the `DatagramChannel` to `address`.
    ///
    /// - parameters:
    ///     - address: The `SocketAddress` to bind on.
    public func bind(to address: SocketAddress) -> EventLoopFuture<Channel> {
        return bind0 { address }
    }

    /// Bind the `DatagramChannel` to a UNIX Domain Socket.
    ///
    /// - parameters:
    ///     - unixDomainSocketPath: The path of the UNIX Domain Socket to bind on. `path` must not exist, it will be created by the system.
    public func bind(unixDomainSocketPath: String) -> EventLoopFuture<Channel> {
        return bind0 {
            return try SocketAddress(unixDomainSocketPath: unixDomainSocketPath)
        }
    }

    /// Bind the `DatagramChannel` to a UNIX Domain Socket.
    ///
    /// - parameters:
    ///     - unixDomainSocketPath: The path of the UNIX Domain Socket to bind on. The`unixDomainSocketPath` must not exist,
    ///     unless `cleanupExistingSocketFile`is set to `true`.
    ///     - cleanupExistingSocketFile: Whether to cleanup an existing socket file at `unixDomainSocketPath`.
    public func bind(unixDomainSocketPath: String, cleanupExistingSocketFile: Bool) -> EventLoopFuture<Channel> {
        if cleanupExistingSocketFile {
            do {
                try BaseSocket.cleanupSocket(unixDomainSocketPath: unixDomainSocketPath)
            } catch {
                return group.next().makeFailedFuture(error)
            }
        }

        return self.bind(unixDomainSocketPath: unixDomainSocketPath)
    }

    private func bind0(_ makeSocketAddress: () throws -> SocketAddress) -> EventLoopFuture<Channel> {
        let address: SocketAddress
        do {
            address = try makeSocketAddress()
        } catch {
            return group.next().makeFailedFuture(error)
        }
        func makeChannel(_ eventLoop: SelectableEventLoop) throws -> DatagramChannel {
            return try DatagramChannel(eventLoop: eventLoop,
                                       protocolFamily: address.protocol,
                                       protocolSubtype: .default)
        }
        return withNewChannel(makeChannel: makeChannel) { (eventLoop, channel) in
            channel.register().flatMap {
                channel.bind(to: address)
            }
        }
    }

    /// Connect the `DatagramChannel` to `host` and `port`.
    ///
    /// - parameters:
    ///     - host: The host to connect to.
    ///     - port: The port to connect to.
    public func connect(host: String, port: Int) -> EventLoopFuture<Channel> {
        return connect0 {
            return try SocketAddress.makeAddressResolvingHost(host, port: port)
        }
    }

    /// Connect the `DatagramChannel` to `address`.
    ///
    /// - parameters:
    ///     - address: The `SocketAddress` to connect to.
    public func connect(to address: SocketAddress) -> EventLoopFuture<Channel> {
        return connect0 { address }
    }

    /// Connect the `DatagramChannel` to a UNIX Domain Socket.
    ///
    /// - parameters:
    ///     - unixDomainSocketPath: The path of the UNIX Domain Socket to connect to. `path` must not exist, it will be created by the system.
    public func connect(unixDomainSocketPath: String) -> EventLoopFuture<Channel> {
        return connect0 {
            return try SocketAddress(unixDomainSocketPath: unixDomainSocketPath)
        }
    }

    private func connect0(_ makeSocketAddress: () throws -> SocketAddress) -> EventLoopFuture<Channel> {
        let address: SocketAddress
        do {
            address = try makeSocketAddress()
        } catch {
            return group.next().makeFailedFuture(error)
        }
        func makeChannel(_ eventLoop: SelectableEventLoop) throws -> DatagramChannel {
            return try DatagramChannel(eventLoop: eventLoop,
                                       protocolFamily: address.protocol,
                                       protocolSubtype: .default)
        }
        return withNewChannel(makeChannel: makeChannel) { (eventLoop, channel) in
            channel.register().flatMap {
                channel.connect(to: address)
            }
        }
    }

    private func withNewChannel(makeChannel: (_ eventLoop: SelectableEventLoop) throws -> DatagramChannel, _ bringup: @escaping (EventLoop, DatagramChannel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel> {
        let eventLoop = self.group.next()
        let channelInitializer = self.channelInitializer ?? { _ in eventLoop.makeSucceededFuture(()) }
        let channelOptions = self._channelOptions

        let channel: DatagramChannel
        do {
            channel = try makeChannel(eventLoop as! SelectableEventLoop)
        } catch {
            return eventLoop.makeFailedFuture(error)
        }

        func setupChannel() -> EventLoopFuture<Channel> {
            eventLoop.assertInEventLoop()
            return channelOptions.applyAllChannelOptions(to: channel).flatMap {
                channelInitializer(channel)
            }.flatMap {
                eventLoop.assertInEventLoop()
                return bringup(eventLoop, channel)
            }.map {
                channel
            }.flatMapError { error in
                eventLoop.makeFailedFuture(error)
            }
        }

        if eventLoop.inEventLoop {
            return setupChannel()
        } else {
            return eventLoop.flatSubmit {
                setupChannel()
            }
        }
    }
}

@available(*, unavailable)
extension DatagramBootstrap: Sendable {}


/// A `NIOPipeBootstrap` is an easy way to bootstrap a `PipeChannel` which uses two (uni-directional) UNIX pipes
/// and makes a `Channel` out of them.
///
/// Example bootstrapping a `Channel` using `stdin` and `stdout`:
///
///     let channel = try NIOPipeBootstrap(group: group)
///                       .channelInitializer { channel in
///                           channel.pipeline.addHandler(MyChannelHandler())
///                       }
///                       .withPipes(inputDescriptor: STDIN_FILENO, outputDescriptor: STDOUT_FILENO)
///
public final class NIOPipeBootstrap {
    private let group: EventLoopGroup
    private var channelInitializer: Optional<ChannelInitializerCallback>
    @usableFromInline
    internal var _channelOptions: ChannelOptions.Storage

    /// Create a `NIOPipeBootstrap` on the `EventLoopGroup` `group`.
    ///
    /// The `EventLoopGroup` `group` must be compatible, otherwise the program will crash. `NIOPipeBootstrap` is
    /// compatible only with `MultiThreadedEventLoopGroup` as well as the `EventLoop`s returned by
    /// `MultiThreadedEventLoopGroup.next`. See `init(validatingGroup:)` for a fallible initializer for
    /// situations where it's impossible to tell ahead of time if the `EventLoopGroup`s are compatible or not.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use.
    public convenience init(group: EventLoopGroup) {
        guard NIOOnSocketsBootstraps.isCompatible(group: group) else {
            preconditionFailure("NIOPipeBootstrap is only compatible with MultiThreadedEventLoopGroup and " +
                                "SelectableEventLoop. You tried constructing one with \(group) which is incompatible.")
        }
        self.init(validatingGroup: group)!
    }

    /// Create a `NIOPipeBootstrap` on the `EventLoopGroup` `group`, validating that `group` is compatible.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use.
    public init?(validatingGroup group: EventLoopGroup) {
        guard NIOOnSocketsBootstraps.isCompatible(group: group) else {
            return nil
        }

        self._channelOptions = ChannelOptions.Storage()
        self.group = group
        self.channelInitializer = nil
    }

    #if swift(>=5.7)
    /// Initialize the connected `PipeChannel` with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// The connected `Channel` will operate on `ByteBuffer` as inbound and outbound messages. Please note that
    /// `IOData.fileRegion` is _not_ supported for `PipeChannel`s because `sendfile` only works on sockets.
    ///
    /// - parameters:
    ///     - handler: A closure that initializes the provided `Channel`.
    @preconcurrency
    public func channelInitializer(_ handler: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> Self {
        self.channelInitializer = handler
        return self
    }
    #else
    /// Initialize the connected `PipeChannel` with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// The connected `Channel` will operate on `ByteBuffer` as inbound and outbound messages. Please note that
    /// `IOData.fileRegion` is _not_ supported for `PipeChannel`s because `sendfile` only works on sockets.
    ///
    /// - parameters:
    ///     - handler: A closure that initializes the provided `Channel`.
    public func channelInitializer(_ handler: @escaping (Channel) -> EventLoopFuture<Void>) -> Self {
        self.channelInitializer = handler
        return self
    }
    #endif

    /// Specifies a `ChannelOption` to be applied to the `PipeChannel`.
    ///
    /// - parameters:
    ///     - option: The option to be applied.
    ///     - value: The value for the option.
    @inlinable
    public func channelOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
        self._channelOptions.append(key: option, value: value)
        return self
    }

    private func validateFileDescriptorIsNotAFile(_ descriptor: CInt) throws {
#if os(Windows)
        // NOTE: this is a *non-owning* handle, do *NOT* call `CloseHandle`
        let hFile: HANDLE = HANDLE(bitPattern: _get_osfhandle(descriptor))!
        if hFile == INVALID_HANDLE_VALUE {
            throw IOError(errnoCode: EBADF, reason: "_get_osfhandle")
        }

        // The check here is different from other platforms as the file types on
        // Windows are different.  SOCKETs and files are different domains, and
        // as a result we know that the descriptor is not a socket.  The only
        // other type of file it could be is either character or disk, neither
        // of which support the operations here.
        switch GetFileType(hFile) {
        case DWORD(FILE_TYPE_PIPE):
            break
        default:
            throw ChannelError.operationUnsupported
        }
#else
        var s: stat = .init()
        try withUnsafeMutablePointer(to: &s) { ptr in
            try Posix.fstat(descriptor: descriptor, outStat: ptr)
        }
        switch s.st_mode & S_IFMT {
        case S_IFREG, S_IFDIR, S_IFLNK, S_IFBLK:
            throw ChannelError.operationUnsupported
        default:
            () // Let's default to ok
        }
#endif
    }

    /// Create the `PipeChannel` with the provided file descriptor which is used for both input & output.
    ///
    /// This method is useful for specialilsed use-cases where you want to use `NIOPipeBootstrap` for say a serial line.
    ///
    /// - note: If this method returns a succeeded future, SwiftNIO will close `fileDescriptor` when the `Channel`
    ///         becomes inactive. You _must not_ do any further operations with `fileDescriptor`, including `close`.
    ///         If this method returns a failed future, you still own the file descriptor and are responsible for
    ///         closing it.
    ///
    /// - parameters:
    ///     - fileDescriptor: The _Unix file descriptor_ for the input & output.
    /// - returns: an `EventLoopFuture<Channel>` to deliver the `Channel`.
    public func withInputOutputDescriptor(_ fileDescriptor: CInt) -> EventLoopFuture<Channel> {
        let inputFD = fileDescriptor
        let outputFD = try! Posix.dup(descriptor: fileDescriptor)

        return self.withPipes(inputDescriptor: inputFD, outputDescriptor: outputFD).flatMapErrorThrowing { error in
            try! Posix.close(descriptor: outputFD)
            throw error
        }
    }

    /// Create the `PipeChannel` with the provided input and output file descriptors.
    ///
    /// The input and output file descriptors must be distinct. If you have a single file descriptor, consider using
    /// `ClientBootstrap.withConnectedSocket(descriptor:)` if it's a socket or
    /// `NIOPipeBootstrap.withInputOutputDescriptor` if it is not a socket.
    ///
    /// - note: If this method returns a succeeded future, SwiftNIO will close `inputDescriptor` and `outputDescriptor`
    ///         when the `Channel` becomes inactive. You _must not_ do any further operations `inputDescriptor` or
    ///         `outputDescriptor`, including `close`.
    ///         If this method returns a failed future, you still own the file descriptors and are responsible for
    ///         closing them.
    ///
    /// - parameters:
    ///     - inputDescriptor: The _Unix file descriptor_ for the input (ie. the read side).
    ///     - outputDescriptor: The _Unix file descriptor_ for the output (ie. the write side).
    /// - returns: an `EventLoopFuture<Channel>` to deliver the `Channel`.
    public func withPipes(inputDescriptor: CInt, outputDescriptor: CInt) -> EventLoopFuture<Channel> {
        precondition(inputDescriptor >= 0 && outputDescriptor >= 0 && inputDescriptor != outputDescriptor,
                     "illegal file descriptor pair. The file descriptors \(inputDescriptor), \(outputDescriptor) " +
                     "must be distinct and both positive integers.")
        let eventLoop = group.next()
        do {
            try self.validateFileDescriptorIsNotAFile(inputDescriptor)
            try self.validateFileDescriptorIsNotAFile(outputDescriptor)
        } catch {
            return eventLoop.makeFailedFuture(error)
        }

        let channelInitializer = self.channelInitializer ?? { _ in eventLoop.makeSucceededFuture(()) }
        let channel: PipeChannel
        do {
            let inputFH = NIOFileHandle(descriptor: inputDescriptor)
            let outputFH = NIOFileHandle(descriptor: outputDescriptor)
            channel = try PipeChannel(eventLoop: eventLoop as! SelectableEventLoop,
                                      inputPipe: inputFH,
                                      outputPipe: outputFH)
        } catch {
            return eventLoop.makeFailedFuture(error)
        }

        func setupChannel() -> EventLoopFuture<Channel> {
            eventLoop.assertInEventLoop()
            return self._channelOptions.applyAllChannelOptions(to: channel).flatMap {
                channelInitializer(channel)
            }.flatMap {
                eventLoop.assertInEventLoop()
                let promise = eventLoop.makePromise(of: Void.self)
                channel.registerAlreadyConfigured0(promise: promise)
                return promise.futureResult
            }.map {
                channel
            }.flatMapError { error in
                channel.close0(error: error, mode: .all, promise: nil)
                return channel.eventLoop.makeFailedFuture(error)
            }
        }

        if eventLoop.inEventLoop {
            return setupChannel()
        } else {
            return eventLoop.flatSubmit {
                setupChannel()
            }
        }
    }
}

@available(*, unavailable)
extension NIOPipeBootstrap: Sendable {}
