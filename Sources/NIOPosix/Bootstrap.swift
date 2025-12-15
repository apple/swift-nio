//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import CNIOLinux
import CNIOOpenBSD
import NIOCore

#if os(Windows)
import ucrt

import func WinSDK.GetFileType

import let WinSDK.FILE_TYPE_PIPE
import let WinSDK.INVALID_HANDLE_VALUE

import struct WinSDK.DWORD
import struct WinSDK.HANDLE
#endif

/// The type of all `channelInitializer` callbacks.
internal typealias ChannelInitializerCallback = @Sendable (Channel) -> EventLoopFuture<Void>

/// Common functionality for all NIO on sockets bootstraps.
internal enum NIOOnSocketsBootstraps {
    internal static func isCompatible(group: EventLoopGroup) -> Bool {
        group is SelectableEventLoop || group is MultiThreadedEventLoopGroup
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
///         .serverChannelOption(.backlog, value: 256)
///         .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
///
///         // Set the handlers that are applied to the accepted child `Channel`s.
///         .childChannelInitializer { channel in
///            channel.eventLoop.makeCompletedFuture {
///                // Ensure we don't read faster than we can write by adding the BackPressureHandler into the pipeline.
///                try channel.pipeline.syncOperations.addHandler(BackPressureHandler())
///                try channel.pipeline.syncOperations.addHandler(MyChannelHandler())
///            }
///         }
///
///         // Enable SO_REUSEADDR for the accepted Channels
///         .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
///         .childChannelOption(.maxMessagesPerRead, value: 16)
///         .childChannelOption(.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
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
    /// - Parameters:
    ///   - group: The `EventLoopGroup` to use for the `bind` of the `ServerSocketChannel` and to accept new `SocketChannel`s with.
    public convenience init(group: EventLoopGroup) {
        guard NIOOnSocketsBootstraps.isCompatible(group: group) else {
            preconditionFailure(
                "ServerBootstrap is only compatible with MultiThreadedEventLoopGroup and "
                    + "SelectableEventLoop. You tried constructing one with \(group) which is incompatible."
            )
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
    /// - Parameters:
    ///   - group: The `EventLoopGroup` to use for the `bind` of the `ServerSocketChannel` and to accept new `SocketChannel`s with.
    ///   - childGroup: The `EventLoopGroup` to run the accepted `SocketChannel`s on.
    public convenience init(group: EventLoopGroup, childGroup: EventLoopGroup) {
        guard
            NIOOnSocketsBootstraps.isCompatible(group: group) && NIOOnSocketsBootstraps.isCompatible(group: childGroup)
        else {
            preconditionFailure(
                "ServerBootstrap is only compatible with MultiThreadedEventLoopGroup and "
                    + "SelectableEventLoop. You tried constructing one with group: \(group) and "
                    + "childGroup: \(childGroup) at least one of which is incompatible."
            )
        }
        self.init(validatingGroup: group, childGroup: childGroup)!

    }

    /// Create a `ServerBootstrap` on the `EventLoopGroup` `group` which accepts `Channel`s on `childGroup`, validating
    /// that the `EventLoopGroup`s are compatible with `ServerBootstrap`.
    ///
    /// - Parameters:
    ///   - group: The `EventLoopGroup` to use for the `bind` of the `ServerSocketChannel` and to accept new `SocketChannel`s with.
    ///   - childGroup: The `EventLoopGroup` to run the accepted `SocketChannel`s on. If `nil`, `group` is used.
    public init?(validatingGroup group: EventLoopGroup, childGroup: EventLoopGroup? = nil) {
        let childGroup = childGroup ?? group
        guard
            NIOOnSocketsBootstraps.isCompatible(group: group) && NIOOnSocketsBootstraps.isCompatible(group: childGroup)
        else {
            return nil
        }

        self.group = group
        self.childGroup = childGroup
        self._serverChannelOptions = ChannelOptions.Storage()
        self._childChannelOptions = ChannelOptions.Storage()
        self.serverChannelInit = nil
        self.childChannelInit = nil
        self._serverChannelOptions.append(key: .tcpOption(.tcp_nodelay), value: 1)
        self.enableMPTCP = false
    }

    /// Initialize the `ServerSocketChannel` with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// The `ServerSocketChannel` uses the accepted `Channel`s as inbound messages.
    ///
    /// - Note: To set the initializer for the accepted `SocketChannel`s, look at `ServerBootstrap.childChannelInitializer`.
    ///
    /// - Parameters:
    ///   - initializer: A closure that initializes the provided `Channel`.
    @preconcurrency
    public func serverChannelInitializer(_ initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> Self
    {
        self.serverChannelInit = initializer
        return self
    }

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
    /// - Parameters:
    ///   - initializer: A closure that initializes the provided `Channel`.
    @preconcurrency
    public func childChannelInitializer(_ initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> Self {
        self.childChannelInit = initializer
        return self
    }

    /// Specifies a `ChannelOption` to be applied to the `ServerSocketChannel`.
    ///
    /// - Note: To specify options for the accepted `SocketChannel`s, look at `ServerBootstrap.childChannelOption`.
    ///
    /// - Parameters:
    ///   - option: The option to be applied.
    ///   - value: The value for the option.
    @inlinable
    public func serverChannelOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
        self._serverChannelOptions.append(key: option, value: value)
        return self
    }

    /// Specifies a `ChannelOption` to be applied to the accepted `SocketChannel`s.
    ///
    /// - Parameters:
    ///   - option: The option to be applied.
    ///   - value: The value for the option.
    @inlinable
    public func childChannelOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
        self._childChannelOptions.append(key: option, value: value)
        return self
    }

    /// Specifies a timeout to apply to a bind attempt. Currently unsupported.
    ///
    /// - Parameters:
    ///   - timeout: The timeout that will apply to the bind attempt.
    public func bindTimeout(_ timeout: TimeAmount) -> Self {
        self
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
    /// - Parameters:
    ///   - value: Whether to enable MPTCP or not.
    public func enableMPTCP(_ value: Bool) -> Self {
        self.enableMPTCP = value

        // This is a temporary workaround until we get some stable Linux kernel
        // versions that support TCP_NODELAY and MPTCP.
        if value {
            self._serverChannelOptions.remove(key: .tcpOption(.tcp_nodelay))
        }

        return self
    }

    /// Bind the `ServerSocketChannel` to `host` and `port`.
    ///
    /// - Parameters:
    ///   - host: The host to bind on.
    ///   - port: The port to bind on.
    public func bind(host: String, port: Int) -> EventLoopFuture<Channel> {
        bind0 {
            try SocketAddress.makeAddressResolvingHost(host, port: port)
        }
    }

    /// Bind the `ServerSocketChannel` to `address`.
    ///
    /// - Parameters:
    ///   - address: The `SocketAddress` to bind on.
    public func bind(to address: SocketAddress) -> EventLoopFuture<Channel> {
        bind0 { address }
    }

    /// Bind the `ServerSocketChannel` to a UNIX Domain Socket.
    ///
    /// - Parameters:
    ///   - unixDomainSocketPath: The _Unix domain socket_ path to bind to. `unixDomainSocketPath` must not exist, it will be created by the system.
    public func bind(unixDomainSocketPath: String) -> EventLoopFuture<Channel> {
        bind0 {
            try SocketAddress(unixDomainSocketPath: unixDomainSocketPath)
        }
    }

    /// Bind the `ServerSocketChannel` to a UNIX Domain Socket.
    ///
    /// - Parameters:
    ///   - unixDomainSocketPath: The path of the UNIX Domain Socket to bind on. The`unixDomainSocketPath` must not exist,
    ///     unless `cleanupExistingSocketFile`is set to `true`.
    ///   - cleanupExistingSocketFile: Whether to cleanup an existing socket file at `unixDomainSocketPath`.
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

    /// Bind the `ServerSocketChannel` to a VSOCK socket.
    ///
    /// - Parameters:
    ///   - vsockAddress: The VSOCK socket address to bind on.
    public func bind(to vsockAddress: VsockAddress) -> EventLoopFuture<Channel> {
        func makeChannel(
            _ eventLoop: SelectableEventLoop,
            _ childEventLoopGroup: EventLoopGroup,
            _ enableMPTCP: Bool
        ) throws -> ServerSocketChannel {
            try ServerSocketChannel(
                eventLoop: eventLoop,
                group: childEventLoopGroup,
                protocolFamily: .vsock,
                enableMPTCP: enableMPTCP
            )
        }
        return bind0(makeServerChannel: makeChannel) { (eventLoop, serverChannel) in
            serverChannel.register().flatMap {
                let promise = eventLoop.makePromise(of: Void.self)
                serverChannel.triggerUserOutboundEvent0(
                    VsockChannelEvents.BindToAddress(vsockAddress),
                    promise: promise
                )
                return promise.futureResult
            }
        }
    }

    #if !os(Windows)
    /// Use the existing bound socket file descriptor.
    ///
    /// - Parameters:
    ///   - descriptor: The _Unix file descriptor_ representing the bound stream socket.
    @available(*, deprecated, renamed: "withBoundSocket(_:)")
    public func withBoundSocket(descriptor: CInt) -> EventLoopFuture<Channel> {
        withBoundSocket(descriptor)
    }
    #endif

    /// Use the existing bound socket file descriptor.
    ///
    /// - Parameters:
    ///   - socket: The _Unix file descriptor_ representing the bound stream socket.
    public func withBoundSocket(_ socket: NIOBSDSocket.Handle) -> EventLoopFuture<Channel> {
        func makeChannel(
            _ eventLoop: SelectableEventLoop,
            _ childEventLoopGroup: EventLoopGroup,
            _ enableMPTCP: Bool
        ) throws -> ServerSocketChannel {
            if enableMPTCP {
                throw ChannelError._operationUnsupported
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
        func makeChannel(
            _ eventLoop: SelectableEventLoop,
            _ childEventLoopGroup: EventLoopGroup,
            _ enableMPTCP: Bool
        ) throws -> ServerSocketChannel {
            try ServerSocketChannel(
                eventLoop: eventLoop,
                group: childEventLoopGroup,
                protocolFamily: address.protocol,
                enableMPTCP: enableMPTCP
            )
        }

        return bind0(makeServerChannel: makeChannel) { (eventLoop, serverChannel) in
            serverChannel.registerAndDoSynchronously { serverChannel in
                serverChannel.bind(to: address)
            }
        }
    }

    private func bind0(
        makeServerChannel: (_ eventLoop: SelectableEventLoop, _ childGroup: EventLoopGroup, _ enableMPTCP: Bool) throws
            -> ServerSocketChannel,
        _ register: @escaping @Sendable (EventLoop, ServerSocketChannel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        let eventLoop = self.group.next()
        let childEventLoopGroup = self.childGroup
        let serverChannelOptions = self._serverChannelOptions
        let serverChannelInit = self.serverChannelInit ?? { _ in eventLoop.makeSucceededFuture(()) }
        let childChannelInit = self.childChannelInit
        let childChannelOptions = self._childChannelOptions

        let serverChannel: ServerSocketChannel
        do {
            serverChannel = try makeServerChannel(
                eventLoop as! SelectableEventLoop,
                childEventLoopGroup,
                self.enableMPTCP
            )
        } catch {
            return eventLoop.makeFailedFuture(error)
        }

        return eventLoop.submit {
            serverChannelOptions.applyAllChannelOptions(to: serverChannel).flatMap {
                serverChannelInit(serverChannel)
            }.flatMap {
                do {
                    try serverChannel.pipeline.syncOperations.addHandler(
                        AcceptHandler(
                            childChannelInitializer: childChannelInit,
                            childChannelOptions: childChannelOptions
                        ),
                        name: "AcceptHandler"
                    )
                    return register(eventLoop, serverChannel)
                } catch {
                    return eventLoop.makeFailedFuture(error)
                }
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

    final class AcceptHandler: ChannelInboundHandler {
        public typealias InboundIn = SocketChannel
        public typealias InboundOut = SocketChannel

        private let childChannelInit: (@Sendable (Channel) -> EventLoopFuture<Void>)?
        private let childChannelOptions: ChannelOptions.Storage

        init(
            childChannelInitializer: (@Sendable (Channel) -> EventLoopFuture<Void>)?,
            childChannelOptions: ChannelOptions.Storage
        ) {
            self.childChannelInit = childChannelInitializer
            self.childChannelOptions = childChannelOptions
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if event is ChannelShouldQuiesceEvent {
                let loopBoundContext = context.loopBound
                context.channel.close().whenFailure { error in
                    let context = loopBoundContext.value
                    context.fireErrorCaught(error)
                }
            }
            context.fireUserInboundEventTriggered(event)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let accepted = AcceptHandler.unwrapInboundIn(data)
            let ctxEventLoop = context.eventLoop
            let childEventLoop = accepted.eventLoop
            let childChannelInit = self.childChannelInit ?? { (_: Channel) in childEventLoop.makeSucceededFuture(()) }
            let childChannelOptions = self.childChannelOptions

            @inline(__always)
            @Sendable
            func setupChildChannel() -> EventLoopFuture<Void> {
                childChannelOptions.applyAllChannelOptions(to: accepted).flatMap { () -> EventLoopFuture<Void> in
                    childEventLoop.assertInEventLoop()
                    return childChannelInit(accepted)
                }
            }

            @inline(__always)
            func fireThroughPipeline(_ future: EventLoopFuture<Void>, context: ChannelHandlerContext) {
                // Strictly these asserts are redundant with future.assumeIsolated(), but as this code
                // has guarantees that can be quite hard to follow we keep them here.
                ctxEventLoop.assertInEventLoop()
                assert(ctxEventLoop === context.eventLoop)
                future.assumeIsolated().flatMap { (_) -> EventLoopFuture<Void> in
                    guard context.channel.isActive else {
                        return ctxEventLoop.makeFailedFuture(ChannelError._ioOnClosedChannel)
                    }
                    context.fireChannelRead(AcceptHandler.wrapInboundOut(accepted))
                    return context.eventLoop.makeSucceededFuture(())
                }.whenFailure { error in
                    self.closeAndFire(context: context, accepted: accepted, err: error)
                }
            }

            if childEventLoop === ctxEventLoop {
                fireThroughPipeline(setupChildChannel(), context: context)
            } else {
                fireThroughPipeline(
                    childEventLoop.flatSubmit {
                        setupChildChannel()
                    }.hop(to: ctxEventLoop),
                    context: context
                )
            }
        }

        private func closeAndFire(context: ChannelHandlerContext, accepted: SocketChannel, err: Error) {
            accepted.close(promise: nil)
            if context.eventLoop.inEventLoop {
                context.fireErrorCaught(err)
            } else {
                let loopBoundContext = context.loopBound
                context.eventLoop.execute {
                    let context = loopBoundContext.value
                    context.fireErrorCaught(err)
                }
            }
        }
    }
}

// MARK: Async bind methods

extension ServerBootstrap {
    /// Bind the `ServerSocketChannel` to the `host` and `port` parameters.
    ///
    /// - Parameters:
    ///   - host: The host to bind on.
    ///   - port: The port to bind on.
    ///   - serverBackPressureStrategy: The back pressure strategy used by the server socket channel.
    ///   - childChannelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind<Output: Sendable>(
        host: String,
        port: Int,
        serverBackPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        childChannelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> NIOAsyncChannel<Output, Never> {
        let address = try SocketAddress.makeAddressResolvingHost(host, port: port)

        return try await bind(
            to: address,
            serverBackPressureStrategy: serverBackPressureStrategy,
            childChannelInitializer: childChannelInitializer
        )
    }

    /// Bind the `ServerSocketChannel` to the `address` parameter.
    ///
    /// - Parameters:
    ///   - address: The `SocketAddress` to bind on.
    ///   - serverBackPressureStrategy: The back pressure strategy used by the server socket channel.
    ///   - childChannelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind<Output: Sendable>(
        to address: SocketAddress,
        serverBackPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        childChannelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> NIOAsyncChannel<Output, Never> {
        try await bind0(
            makeServerChannel: { eventLoop, childEventLoopGroup, enableMPTCP in
                try ServerSocketChannel(
                    eventLoop: eventLoop,
                    group: childEventLoopGroup,
                    protocolFamily: address.protocol,
                    enableMPTCP: enableMPTCP
                )
            },
            serverBackPressureStrategy: serverBackPressureStrategy,
            childChannelInitializer: childChannelInitializer,
            registration: { serverChannel in
                serverChannel.registerAndDoSynchronously { serverChannel in
                    serverChannel.bind(to: address)
                }
            }
        ).get()
    }

    /// Bind the `ServerSocketChannel` to a UNIX Domain Socket.
    ///
    /// - Parameters:
    ///   - unixDomainSocketPath: The path of the UNIX Domain Socket to bind on. The`unixDomainSocketPath` must not exist,
    ///     unless `cleanupExistingSocketFile`is set to `true`.
    ///   - cleanupExistingSocketFile: Whether to cleanup an existing socket file at `unixDomainSocketPath`.
    ///   - serverBackPressureStrategy: The back pressure strategy used by the server socket channel.
    ///   - childChannelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind<Output: Sendable>(
        unixDomainSocketPath: String,
        cleanupExistingSocketFile: Bool = false,
        serverBackPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        childChannelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> NIOAsyncChannel<Output, Never> {
        if cleanupExistingSocketFile {
            try BaseSocket.cleanupSocket(unixDomainSocketPath: unixDomainSocketPath)
        }

        let address = try SocketAddress(unixDomainSocketPath: unixDomainSocketPath)

        return try await self.bind(
            to: address,
            serverBackPressureStrategy: serverBackPressureStrategy,
            childChannelInitializer: childChannelInitializer
        )
    }

    /// Bind the `ServerSocketChannel` to a VSOCK socket.
    ///
    /// - Parameters:
    ///   - vsockAddress: The VSOCK socket address to bind on.
    ///   - serverBackPressureStrategy: The back pressure strategy used by the server socket channel.
    ///   - childChannelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind<Output: Sendable>(
        to vsockAddress: VsockAddress,
        serverBackPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        childChannelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> NIOAsyncChannel<Output, Never> {
        func makeChannel(
            _ eventLoop: SelectableEventLoop,
            _ childEventLoopGroup: EventLoopGroup,
            _ enableMPTCP: Bool
        ) throws -> ServerSocketChannel {
            try ServerSocketChannel(
                eventLoop: eventLoop,
                group: childEventLoopGroup,
                protocolFamily: .vsock,
                enableMPTCP: enableMPTCP
            )
        }

        return try await self.bind0(
            makeServerChannel: makeChannel,
            serverBackPressureStrategy: serverBackPressureStrategy,
            childChannelInitializer: childChannelInitializer
        ) { channel in
            channel.register().flatMap {
                let promise = channel.eventLoop.makePromise(of: Void.self)
                channel.triggerUserOutboundEvent0(
                    VsockChannelEvents.BindToAddress(vsockAddress),
                    promise: promise
                )
                return promise.futureResult
            }
        }.get()
    }

    /// Use the existing bound socket file descriptor.
    ///
    /// - Parameters:
    ///   - socket: The _Unix file descriptor_ representing the bound stream socket.
    ///   - cleanupExistingSocketFile: Unused.
    ///   - serverBackPressureStrategy: The back pressure strategy used by the server socket channel.
    ///   - childChannelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind<Output: Sendable>(
        _ socket: NIOBSDSocket.Handle,
        cleanupExistingSocketFile: Bool = false,
        serverBackPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        childChannelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> NIOAsyncChannel<Output, Never> {
        try await bind0(
            makeServerChannel: { eventLoop, childEventLoopGroup, enableMPTCP in
                if enableMPTCP {
                    throw ChannelError._operationUnsupported
                }
                return try ServerSocketChannel(
                    socket: socket,
                    eventLoop: eventLoop,
                    group: childEventLoopGroup
                )
            },
            serverBackPressureStrategy: serverBackPressureStrategy,
            childChannelInitializer: childChannelInitializer,
            registration: { serverChannel in
                let promise = serverChannel.eventLoop.makePromise(of: Void.self)
                serverChannel.registerAlreadyConfigured0(promise: promise)
                return promise.futureResult
            }
        ).get()
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    private func bind0<ChannelInitializerResult>(
        makeServerChannel: @escaping (SelectableEventLoop, EventLoopGroup, Bool) throws -> ServerSocketChannel,
        serverBackPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        childChannelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<ChannelInitializerResult>,
        registration: @escaping @Sendable (ServerSocketChannel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<NIOAsyncChannel<ChannelInitializerResult, Never>> {
        let eventLoop = self.group.next()
        let childEventLoopGroup = self.childGroup
        let serverChannelOptions = self._serverChannelOptions
        let serverChannelInit = self.serverChannelInit ?? { _ in eventLoop.makeSucceededFuture(()) }
        let childChannelInit = self.childChannelInit
        let childChannelOptions = self._childChannelOptions

        let serverChannel: ServerSocketChannel
        do {
            serverChannel = try makeServerChannel(
                eventLoop as! SelectableEventLoop,
                childEventLoopGroup,
                self.enableMPTCP
            )
        } catch {
            return eventLoop.makeFailedFuture(error)
        }

        return eventLoop.submit {
            serverChannelOptions.applyAllChannelOptions(to: serverChannel).flatMap {
                serverChannelInit(serverChannel)
            }.flatMap { (_) -> EventLoopFuture<NIOAsyncChannel<ChannelInitializerResult, Never>> in
                do {
                    try serverChannel.pipeline.syncOperations.addHandler(
                        AcceptBackoffHandler(shouldForwardIOErrorCaught: false),
                        name: "AcceptBackOffHandler"
                    )
                    try serverChannel.pipeline.syncOperations.addHandler(
                        AcceptHandler(
                            childChannelInitializer: childChannelInit,
                            childChannelOptions: childChannelOptions
                        ),
                        name: "AcceptHandler"
                    )
                    let asyncChannel = try NIOAsyncChannel<ChannelInitializerResult, Never>
                        ._wrapAsyncChannelWithTransformations(
                            wrappingChannelSynchronously: serverChannel,
                            backPressureStrategy: serverBackPressureStrategy,
                            channelReadTransformation: { channel -> EventLoopFuture<ChannelInitializerResult> in
                                // The channelReadTransformation is run on the EL of the server channel
                                // We have to make sure that we execute child channel initializer on the
                                // EL of the child channel.
                                channel.eventLoop.flatSubmit {
                                    childChannelInitializer(channel)
                                }
                            }
                        )
                    return registration(serverChannel)
                        .map { (_) -> NIOAsyncChannel<ChannelInitializerResult, Never> in asyncChannel
                        }
                } catch {
                    return eventLoop.makeFailedFuture(error)
                }
            }.flatMapError { error -> EventLoopFuture<NIOAsyncChannel<ChannelInitializerResult, Never>> in
                serverChannel.close0(error: error, mode: .all, promise: nil)
                return eventLoop.makeFailedFuture(error)
            }
        }.flatMap {
            $0
        }
    }
}

@available(*, unavailable)
extension ServerBootstrap: Sendable {}

extension Channel {
    fileprivate func registerAndDoSynchronously(
        _ body: @escaping (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        // this is pretty delicate at the moment:
        // In many cases `body` must be _synchronously_ follow `register`, otherwise in our current
        // implementation, `epoll` will send us `EPOLLHUP`. To have it run synchronously, we need to invoke the
        // `flatMap` on the eventloop that the `register` will succeed on.
        self.eventLoop.assertInEventLoop()
        return self.register().assumeIsolated().flatMap {
            body(self)
        }.nonisolated()
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
    private var protocolHandlers: Optional<@Sendable () -> [ChannelHandler]>
    private var _channelInitializer: ChannelInitializerCallback
    private var channelInitializer: ChannelInitializerCallback {
        if let protocolHandlers = self.protocolHandlers {
            let channelInitializer = _channelInitializer
            return { channel in
                channelInitializer(channel).hop(to: channel.eventLoop).flatMapThrowing {
                    try channel.pipeline.syncOperations.addHandlers(protocolHandlers(), position: .first)
                }
            }
        } else {
            return self._channelInitializer
        }
    }
    @usableFromInline
    internal var _channelOptions: ChannelOptions.Storage
    private var connectTimeout: TimeAmount = TimeAmount.seconds(10)
    private var resolver: Optional<Resolver & Sendable>
    private var bindTarget: Optional<SocketAddress>
    private var enableMPTCP: Bool

    /// Create a `ClientBootstrap` on the `EventLoopGroup` `group`.
    ///
    /// The `EventLoopGroup` `group` must be compatible, otherwise the program will crash. `ClientBootstrap` is
    /// compatible only with `MultiThreadedEventLoopGroup` as well as the `EventLoop`s returned by
    /// `MultiThreadedEventLoopGroup.next`. See `init(validatingGroup:)` for a fallible initializer for
    /// situations where it's impossible to tell ahead of time if the `EventLoopGroup` is compatible or not.
    ///
    /// - Parameters:
    ///   - group: The `EventLoopGroup` to use.
    public convenience init(group: EventLoopGroup) {
        guard NIOOnSocketsBootstraps.isCompatible(group: group) else {
            preconditionFailure(
                "ClientBootstrap is only compatible with MultiThreadedEventLoopGroup and "
                    + "SelectableEventLoop. You tried constructing one with \(group) which is incompatible."
            )
        }
        self.init(validatingGroup: group)!
    }

    /// Create a `ClientBootstrap` on the `EventLoopGroup` `group`, validating that `group` is compatible.
    ///
    /// - Parameters:
    ///   - group: The `EventLoopGroup` to use.
    public init?(validatingGroup group: EventLoopGroup) {
        guard NIOOnSocketsBootstraps.isCompatible(group: group) else {
            return nil
        }
        self.group = group
        self._channelOptions = ChannelOptions.Storage()
        self._channelOptions.append(key: .tcpOption(.tcp_nodelay), value: 1)
        self._channelInitializer = { channel in channel.eventLoop.makeSucceededFuture(()) }
        self.protocolHandlers = nil
        self.resolver = nil
        self.bindTarget = nil
        self.enableMPTCP = false
    }

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
    /// - Parameters:
    ///   - handler: A closure that initializes the provided `Channel`.
    @preconcurrency
    public func channelInitializer(_ handler: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> Self {
        self._channelInitializer = handler
        return self
    }

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

    /// Specifies a `ChannelOption` to be applied to the `SocketChannel`.
    ///
    /// - Parameters:
    ///   - option: The option to be applied.
    ///   - value: The value for the option.
    @inlinable
    public func channelOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
        self._channelOptions.append(key: option, value: value)
        return self
    }

    /// Specifies a timeout to apply to a connection attempt.
    ///
    /// - Parameters:
    ///   - timeout: The timeout that will apply to the connection attempt.
    public func connectTimeout(_ timeout: TimeAmount) -> Self {
        self.connectTimeout = timeout
        return self
    }

    /// Specifies the `Resolver` to use or `nil` if the default should be used.
    ///
    /// - Parameters:
    ///   - resolver: The resolver that will be used during the connection attempt.
    @preconcurrency
    public func resolver(_ resolver: (Resolver & Sendable)?) -> Self {
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
    /// - Parameters:
    ///   - value: Whether to enable MPTCP or not.
    public func enableMPTCP(_ value: Bool) -> Self {
        self.enableMPTCP = value

        // This is a temporary workaround until we get some stable Linux kernel
        // versions that support TCP_NODELAY and MPTCP.
        if value {
            self._channelOptions.remove(key: .tcpOption(.tcp_nodelay))
        }

        return self
    }

    /// Bind the `SocketChannel` to `address`.
    ///
    /// Using `bind` is not necessary unless you need the local address to be bound to a specific address.
    ///
    /// - Parameters:
    ///   - address: The `SocketAddress` to bind on.
    public func bind(to address: SocketAddress) -> ClientBootstrap {
        self.bindTarget = address
        return self
    }

    func makeSocketChannel(
        eventLoop: EventLoop,
        protocolFamily: NIOBSDSocket.ProtocolFamily
    ) throws -> SocketChannel {
        try Self.makeSocketChannel(
            eventLoop: eventLoop,
            protocolFamily: protocolFamily,
            enableMPTCP: self.enableMPTCP
        )
    }

    static func makeSocketChannel(
        eventLoop: EventLoop,
        protocolFamily: NIOBSDSocket.ProtocolFamily,
        enableMPTCP: Bool
    ) throws -> SocketChannel {
        try SocketChannel(
            eventLoop: eventLoop as! SelectableEventLoop,
            protocolFamily: protocolFamily,
            enableMPTCP: enableMPTCP
        )
    }

    /// Specify the `host` and `port` to connect to for the TCP `Channel` that will be established.
    ///
    /// - Note: Makes use of Happy Eyeballs.
    ///
    /// - Parameters:
    ///   - host: The host to connect to.
    ///   - port: The port to connect to.
    /// - Returns: An `EventLoopFuture<Channel>` to deliver the `Channel` when connected.
    public func connect(host: String, port: Int) -> EventLoopFuture<Channel> {
        let loop = self.group.next()
        let resolver =
            self.resolver
            ?? GetaddrinfoResolver(
                loop: loop,
                aiSocktype: .stream,
                aiProtocol: .tcp
            )
        let enableMPTCP = self.enableMPTCP
        let channelInitializer = self.channelInitializer
        let channelOptions = self._channelOptions
        let bindTarget = self.bindTarget

        let connector = HappyEyeballsConnector(
            resolver: resolver,
            loop: loop,
            host: host,
            port: port,
            connectTimeout: self.connectTimeout
        ) { eventLoop, protocolFamily in
            Self.initializeAndRegisterNewChannel(
                eventLoop: eventLoop,
                protocolFamily: protocolFamily,
                enableMPTCP: enableMPTCP,
                channelInitializer: channelInitializer,
                channelOptions: channelOptions,
                bindTarget: bindTarget
            ) {
                $0.eventLoop.makeSucceededFuture(())
            }
        }
        return connector.resolveAndConnect()
    }

    private static func connect(
        freshChannel channel: Channel,
        address: SocketAddress,
        connectTimeout: TimeAmount
    ) -> EventLoopFuture<Void> {
        let connectPromise = channel.eventLoop.makePromise(of: Void.self)
        channel.connect(to: address, promise: connectPromise)
        let cancelTask = channel.eventLoop.scheduleTask(in: connectTimeout) {
            connectPromise.fail(ChannelError.connectTimeout(connectTimeout))
            channel.close(promise: nil)
        }

        connectPromise.futureResult.whenComplete { (_: Result<Void, Error>) in
            cancelTask.cancel()
        }
        return connectPromise.futureResult
    }

    internal func testOnly_connect(
        injectedChannel: SocketChannel,
        to address: SocketAddress
    ) -> EventLoopFuture<Channel> {
        let connectTimeout = self.connectTimeout
        return self.initializeAndRegisterChannel(injectedChannel) { channel in
            Self.connect(freshChannel: channel, address: address, connectTimeout: connectTimeout)
        }
    }

    /// Specify the `address` to connect to for the TCP `Channel` that will be established.
    ///
    /// - Parameters:
    ///   - address: The address to connect to.
    /// - Returns: An `EventLoopFuture<Channel>` to deliver the `Channel` when connected.
    public func connect(to address: SocketAddress) -> EventLoopFuture<Channel> {
        let connectTimeout = self.connectTimeout

        return self.initializeAndRegisterNewChannel(
            eventLoop: self.group.next(),
            protocolFamily: address.protocol
        ) { channel in
            Self.connect(freshChannel: channel, address: address, connectTimeout: connectTimeout)
        }
    }

    /// Specify the `unixDomainSocket` path to connect to for the UDS `Channel` that will be established.
    ///
    /// - Parameters:
    ///   - unixDomainSocketPath: The _Unix domain socket_ path to connect to.
    /// - Returns: An `EventLoopFuture<Channel>` to deliver the `Channel` when connected.
    public func connect(unixDomainSocketPath: String) -> EventLoopFuture<Channel> {
        do {
            let address = try SocketAddress(unixDomainSocketPath: unixDomainSocketPath)
            return self.connect(to: address)
        } catch {
            return self.group.next().makeFailedFuture(error)
        }
    }

    /// Specify the VSOCK address to connect to for the `Channel`.
    ///
    /// - Parameters:
    ///   - address: The VSOCK address to connect to.
    /// - Returns: An `EventLoopFuture<Channel>` for when the `Channel` is connected.
    public func connect(to address: VsockAddress) -> EventLoopFuture<Channel> {
        let connectTimeout = self.connectTimeout
        return self.initializeAndRegisterNewChannel(
            eventLoop: self.group.next(),
            protocolFamily: .vsock
        ) { channel in
            let connectPromise = channel.eventLoop.makePromise(of: Void.self)
            channel.triggerUserOutboundEvent(VsockChannelEvents.ConnectToAddress(address), promise: connectPromise)

            let cancelTask = channel.eventLoop.scheduleTask(in: connectTimeout) {
                connectPromise.fail(ChannelError.connectTimeout(connectTimeout))
                channel.close(promise: nil)
            }
            connectPromise.futureResult.whenComplete { (_: Result<Void, Error>) in
                cancelTask.cancel()
            }

            return connectPromise.futureResult
        }
    }

    #if !os(Windows)
    /// Use the existing connected socket file descriptor.
    ///
    /// - Parameters:
    ///   - descriptor: The _Unix file descriptor_ representing the connected stream socket.
    /// - Returns: an `EventLoopFuture<Channel>` to deliver the `Channel`.
    @available(*, deprecated, renamed: "withConnectedSocket(_:)")
    public func withConnectedSocket(descriptor: CInt) -> EventLoopFuture<Channel> {
        self.withConnectedSocket(descriptor)
    }
    #endif

    /// Use the existing connected socket file descriptor.
    ///
    /// - Parameters:
    ///   - socket: The _Unix file descriptor_ representing the connected stream socket.
    /// - Returns: an `EventLoopFuture<Channel>` to deliver the `Channel`.
    public func withConnectedSocket(_ socket: NIOBSDSocket.Handle) -> EventLoopFuture<Channel> {
        let eventLoop = group.next()
        let channelInitializer = self.channelInitializer
        let options = self._channelOptions

        let channel: SocketChannel
        do {
            channel = try SocketChannel(eventLoop: eventLoop as! SelectableEventLoop, socket: socket)
        } catch {
            return eventLoop.makeFailedFuture(error)
        }

        @Sendable
        func setupChannel() -> EventLoopFuture<Channel> {
            eventLoop.assertInEventLoop()
            return options.applyAllChannelOptions(to: channel).flatMap {
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

    private func initializeAndRegisterNewChannel(
        eventLoop: EventLoop,
        protocolFamily: NIOBSDSocket.ProtocolFamily,
        _ body: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        Self.initializeAndRegisterNewChannel(
            eventLoop: eventLoop,
            protocolFamily: protocolFamily,
            enableMPTCP: self.enableMPTCP,
            channelInitializer: self.channelInitializer,
            channelOptions: self._channelOptions,
            bindTarget: self.bindTarget,
            body
        )
    }

    private static func initializeAndRegisterNewChannel(
        eventLoop: EventLoop,
        protocolFamily: NIOBSDSocket.ProtocolFamily,
        enableMPTCP: Bool,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>,
        channelOptions: ChannelOptions.Storage,
        bindTarget: SocketAddress?,
        _ body: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        let channel: SocketChannel
        do {
            channel = try Self.makeSocketChannel(
                eventLoop: eventLoop,
                protocolFamily: protocolFamily,
                enableMPTCP: enableMPTCP
            )
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
        return Self.initializeAndRegisterChannel(
            channel,
            channelInitializer: channelInitializer,
            channelOptions: channelOptions,
            bindTarget: bindTarget,
            body
        )
    }

    private func initializeAndRegisterChannel(
        _ channel: SocketChannel,
        _ body: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        Self.initializeAndRegisterChannel(
            channel,
            channelInitializer: self.channelInitializer,
            channelOptions: self._channelOptions,
            bindTarget: self.bindTarget,
            body
        )
    }

    private static func initializeAndRegisterChannel(
        _ channel: SocketChannel,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>,
        channelOptions: ChannelOptions.Storage,
        bindTarget: SocketAddress?,
        _ body: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        let eventLoop = channel.eventLoop

        @inline(__always)
        @Sendable
        func setupChannel() -> EventLoopFuture<Channel> {
            eventLoop.assertInEventLoop()
            return channelOptions.applyAllChannelOptions(to: channel).flatMap {
                if let bindTarget = bindTarget {
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

// MARK: Async connect methods

extension ClientBootstrap {
    /// Specify the `host` and `port` to connect to for the TCP `Channel` that will be established.
    ///
    /// - Parameters:
    ///   - host: The host to connect to.
    ///   - port: The port to connect to.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect<Output: Sendable>(
        host: String,
        port: Int,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        let eventLoop = self.group.next()
        return try await self.connect(
            host: host,
            port: port,
            eventLoop: eventLoop,
            channelInitializer: channelInitializer,
            postRegisterTransformation: { output, eventLoop in
                eventLoop.makeSucceededFuture(output)
            }
        )
    }

    /// Specify the `address` to connect to for the TCP `Channel` that will be established.
    ///
    /// - Parameters:
    ///   - address: The address to connect to.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect<Output: Sendable>(
        to address: SocketAddress,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        let eventLoop = self.group.next()
        let connectTimeout = self.connectTimeout
        return try await self.initializeAndRegisterNewChannel(
            eventLoop: eventLoop,
            protocolFamily: address.protocol,
            channelInitializer: channelInitializer,
            postRegisterTransformation: { output, eventLoop in
                eventLoop.makeSucceededFuture(output)
            },
            { channel in
                Self.connect(freshChannel: channel, address: address, connectTimeout: connectTimeout)
            }
        ).get().1
    }

    /// Specify the `unixDomainSocket` path to connect to for the UDS `Channel` that will be established.
    ///
    /// - Parameters:
    ///   - unixDomainSocketPath: The _Unix domain socket_ path to connect to.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect<Output: Sendable>(
        unixDomainSocketPath: String,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        let address = try SocketAddress(unixDomainSocketPath: unixDomainSocketPath)
        return try await self.connect(
            to: address,
            channelInitializer: channelInitializer
        )
    }

    /// Specify the VSOCK address to connect to for the `Channel`.
    ///
    /// - Parameters:
    ///   - address: The VSOCK address to connect to.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect<Output: Sendable>(
        to address: VsockAddress,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        let connectTimeout = self.connectTimeout
        return try await self.initializeAndRegisterNewChannel(
            eventLoop: self.group.next(),
            protocolFamily: NIOBSDSocket.ProtocolFamily.vsock,
            channelInitializer: channelInitializer,
            postRegisterTransformation: { result, eventLoop in
                eventLoop.makeSucceededFuture(result)
            }
        ) { channel in
            let connectPromise = channel.eventLoop.makePromise(of: Void.self)
            channel.triggerUserOutboundEvent(VsockChannelEvents.ConnectToAddress(address), promise: connectPromise)

            let cancelTask = channel.eventLoop.scheduleTask(in: connectTimeout) {
                connectPromise.fail(ChannelError.connectTimeout(connectTimeout))
                channel.close(promise: nil)
            }
            connectPromise.futureResult.whenComplete { (_: Result<Void, Error>) in
                cancelTask.cancel()
            }

            return connectPromise.futureResult
        }.get().1
    }

    /// Use the existing connected socket file descriptor.
    ///
    /// - Parameters:
    ///   - socket: The _Unix file descriptor_ representing the connected stream socket.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func withConnectedSocket<Output: Sendable>(
        _ socket: NIOBSDSocket.Handle,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        let eventLoop = group.next()
        return try await self.withConnectedSocket(
            eventLoop: eventLoop,
            socket: socket,
            channelInitializer: channelInitializer,
            postRegisterTransformation: { output, eventLoop in
                eventLoop.makeSucceededFuture(output)
            }
        )
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    func connect<ChannelInitializerResult: Sendable, PostRegistrationTransformationResult: Sendable>(
        host: String,
        port: Int,
        eventLoop: EventLoop,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<ChannelInitializerResult>,
        postRegisterTransformation:
            @escaping @Sendable (ChannelInitializerResult, EventLoop) -> EventLoopFuture<
                PostRegistrationTransformationResult
            >
    ) async throws -> PostRegistrationTransformationResult {
        let resolver =
            self.resolver
            ?? GetaddrinfoResolver(
                loop: eventLoop,
                aiSocktype: .stream,
                aiProtocol: .tcp
            )

        let enableMPTCP = self.enableMPTCP
        let bootstrapChannelInitializer = self.channelInitializer
        let channelOptions = self._channelOptions
        let bindTarget = self.bindTarget

        let connector = HappyEyeballsConnector<PostRegistrationTransformationResult>(
            resolver: resolver,
            loop: eventLoop,
            host: host,
            port: port,
            connectTimeout: self.connectTimeout
        ) { eventLoop, protocolFamily in
            Self.initializeAndRegisterNewChannel(
                eventLoop: eventLoop,
                protocolFamily: protocolFamily,
                enableMPTPCP: enableMPTCP,
                bootstrapChannelInitializer: bootstrapChannelInitializer,
                channelOptions: channelOptions,
                bindTarget: bindTarget,
                channelInitializer: channelInitializer,
                postRegisterTransformation: postRegisterTransformation
            ) {
                $0.eventLoop.makeSucceededFuture(())
            }
        }
        return try await connector.resolveAndConnect().map { $0.1 }.get()
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    private func withConnectedSocket<
        ChannelInitializerResult: Sendable,
        PostRegistrationTransformationResult: Sendable
    >(
        eventLoop: EventLoop,
        socket: NIOBSDSocket.Handle,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<ChannelInitializerResult>,
        postRegisterTransformation:
            @escaping @Sendable (ChannelInitializerResult, EventLoop) -> EventLoopFuture<
                PostRegistrationTransformationResult
            >
    ) async throws -> PostRegistrationTransformationResult {
        let channel = try SocketChannel(eventLoop: eventLoop as! SelectableEventLoop, socket: socket)

        return try await self.initializeAndRegisterChannel(
            channel: channel,
            channelInitializer: channelInitializer,
            registration: { channel in
                let promise = eventLoop.makePromise(of: Void.self)
                channel.registerAlreadyConfigured0(promise: promise)
                return promise.futureResult
            },
            postRegisterTransformation: postRegisterTransformation
        ).get()
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    private func initializeAndRegisterNewChannel<
        ChannelInitializerResult: Sendable,
        PostRegistrationTransformationResult: Sendable
    >(
        eventLoop: EventLoop,
        protocolFamily: NIOBSDSocket.ProtocolFamily,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<ChannelInitializerResult>,
        postRegisterTransformation:
            @escaping @Sendable (ChannelInitializerResult, EventLoop) -> EventLoopFuture<
                PostRegistrationTransformationResult
            >,
        _ body: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<(Channel, PostRegistrationTransformationResult)> {
        let channel: SocketChannel
        do {
            channel = try self.makeSocketChannel(eventLoop: eventLoop, protocolFamily: protocolFamily)
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
        return self.initializeAndRegisterChannel(
            channel: channel,
            channelInitializer: channelInitializer,
            registration: { channel in
                channel.registerAndDoSynchronously(body)
            },
            postRegisterTransformation: postRegisterTransformation
        ).map { (channel, $0) }
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    private static func initializeAndRegisterNewChannel<
        ChannelInitializerResult: Sendable,
        PostRegistrationTransformationResult: Sendable
    >(
        eventLoop: EventLoop,
        protocolFamily: NIOBSDSocket.ProtocolFamily,
        enableMPTPCP: Bool,
        bootstrapChannelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>,
        channelOptions: ChannelOptions.Storage,
        bindTarget: SocketAddress?,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<ChannelInitializerResult>,
        postRegisterTransformation:
            @escaping @Sendable (ChannelInitializerResult, EventLoop) -> EventLoopFuture<
                PostRegistrationTransformationResult
            >,
        _ body: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<(Channel, PostRegistrationTransformationResult)> {
        let channel: SocketChannel
        do {
            channel = try Self.makeSocketChannel(
                eventLoop: eventLoop,
                protocolFamily: protocolFamily,
                enableMPTCP: enableMPTPCP
            )
        } catch {
            return eventLoop.makeFailedFuture(error)
        }
        return Self.initializeAndRegisterChannel(
            channel: channel,
            bootstrapChannelInitializer: bootstrapChannelInitializer,
            channelOptions: channelOptions,
            bindTarget: bindTarget,
            channelInitializer: channelInitializer,
            registration: { channel in
                channel.registerAndDoSynchronously(body)
            },
            postRegisterTransformation: postRegisterTransformation
        ).map { (channel, $0) }
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    private func initializeAndRegisterChannel<
        ChannelInitializerResult: Sendable,
        PostRegistrationTransformationResult: Sendable
    >(
        channel: SocketChannel,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<ChannelInitializerResult>,
        registration: @escaping @Sendable (SocketChannel) -> EventLoopFuture<Void>,
        postRegisterTransformation:
            @escaping @Sendable (ChannelInitializerResult, EventLoop) -> EventLoopFuture<
                PostRegistrationTransformationResult
            >
    ) -> EventLoopFuture<PostRegistrationTransformationResult> {
        Self.initializeAndRegisterChannel(
            channel: channel,
            bootstrapChannelInitializer: self.channelInitializer,
            channelOptions: self._channelOptions,
            bindTarget: self.bindTarget,
            channelInitializer: channelInitializer,
            registration: registration,
            postRegisterTransformation: postRegisterTransformation
        )
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    private static func initializeAndRegisterChannel<
        ChannelInitializerResult: Sendable,
        PostRegistrationTransformationResult: Sendable
    >(
        channel: SocketChannel,
        bootstrapChannelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>,
        channelOptions: ChannelOptions.Storage,
        bindTarget: SocketAddress?,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<ChannelInitializerResult>,
        registration: @escaping @Sendable (SocketChannel) -> EventLoopFuture<Void>,
        postRegisterTransformation:
            @escaping @Sendable (ChannelInitializerResult, EventLoop) -> EventLoopFuture<
                PostRegistrationTransformationResult
            >
    ) -> EventLoopFuture<PostRegistrationTransformationResult> {
        let channelInitializer = { @Sendable channel in
            bootstrapChannelInitializer(channel).hop(to: channel.eventLoop)
                .assumeIsolated()
                .flatMap { channelInitializer(channel) }
                .nonisolated()
        }
        let eventLoop = channel.eventLoop

        @inline(__always)
        @Sendable
        func setupChannel() -> EventLoopFuture<PostRegistrationTransformationResult> {
            eventLoop.assertInEventLoop()
            return
                channelOptions
                .applyAllChannelOptions(to: channel)
                .assumeIsolated()
                .flatMap {
                    if let bindTarget = bindTarget {
                        return
                            channel
                            .bind(to: bindTarget)
                            .flatMap {
                                channelInitializer(channel)
                            }
                    } else {
                        return channelInitializer(channel)
                    }
                }.flatMap { (result: ChannelInitializerResult) in
                    eventLoop.assertInEventLoop()
                    return registration(channel).map {
                        result
                    }
                }.flatMap {
                    (result: ChannelInitializerResult) -> EventLoopFuture<PostRegistrationTransformationResult> in
                    postRegisterTransformation(result, eventLoop)
                }.flatMapError { error in
                    eventLoop.assertInEventLoop()
                    channel.close0(error: error, mode: .all, promise: nil)
                    return channel.eventLoop.makeFailedFuture(error)
                }
                .nonisolated()
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
    private var proto: NIOBSDSocket.ProtocolSubtype = .default

    /// Create a `DatagramBootstrap` on the `EventLoopGroup` `group`.
    ///
    /// The `EventLoopGroup` `group` must be compatible, otherwise the program will crash. `DatagramBootstrap` is
    /// compatible only with `MultiThreadedEventLoopGroup` as well as the `EventLoop`s returned by
    /// `MultiThreadedEventLoopGroup.next`. See `init(validatingGroup:)` for a fallible initializer for
    /// situations where it's impossible to tell ahead of time if the `EventLoopGroup` is compatible or not.
    ///
    /// - Parameters:
    ///   - group: The `EventLoopGroup` to use.
    public convenience init(group: EventLoopGroup) {
        guard NIOOnSocketsBootstraps.isCompatible(group: group) else {
            preconditionFailure(
                "DatagramBootstrap is only compatible with MultiThreadedEventLoopGroup and "
                    + "SelectableEventLoop. You tried constructing one with \(group) which is incompatible."
            )
        }
        self.init(validatingGroup: group)!
    }

    /// Create a `DatagramBootstrap` on the `EventLoopGroup` `group`, validating that `group` is compatible.
    ///
    /// - Parameters:
    ///   - group: The `EventLoopGroup` to use.
    public init?(validatingGroup group: EventLoopGroup) {
        guard NIOOnSocketsBootstraps.isCompatible(group: group) else {
            return nil
        }
        self._channelOptions = ChannelOptions.Storage()
        self.group = group
        self.channelInitializer = nil
    }

    /// Initialize the bound `DatagramChannel` with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// - Parameters:
    ///   - handler: A closure that initializes the provided `Channel`.
    @preconcurrency
    public func channelInitializer(_ handler: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> Self {
        self.channelInitializer = handler
        return self
    }

    /// Specifies a `ChannelOption` to be applied to the `DatagramChannel`.
    ///
    /// - Parameters:
    ///   - option: The option to be applied.
    ///   - value: The value for the option.
    @inlinable
    public func channelOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> Self {
        self._channelOptions.append(key: option, value: value)
        return self
    }

    public func protocolSubtype(_ subtype: NIOBSDSocket.ProtocolSubtype) -> Self {
        self.proto = subtype
        return self
    }

    #if !os(Windows)
    /// Use the existing bound socket file descriptor.
    ///
    /// - Parameters:
    ///   - descriptor: The _Unix file descriptor_ representing the bound datagram socket.
    @available(*, deprecated, renamed: "withBoundSocket(_:)")
    public func withBoundSocket(descriptor: CInt) -> EventLoopFuture<Channel> {
        self.withBoundSocket(descriptor)
    }
    #endif

    /// Use the existing bound socket file descriptor.
    ///
    /// - Parameters:
    ///   - socket: The _Unix file descriptor_ representing the bound datagram socket.
    public func withBoundSocket(_ socket: NIOBSDSocket.Handle) -> EventLoopFuture<Channel> {
        func makeChannel(_ eventLoop: SelectableEventLoop) throws -> DatagramChannel {
            try DatagramChannel(eventLoop: eventLoop, socket: socket)
        }
        return withNewChannel(makeChannel: makeChannel) { eventLoop, channel in
            let promise = eventLoop.makePromise(of: Void.self)
            channel.registerAlreadyConfigured0(promise: promise)
            return promise.futureResult
        }
    }

    /// Bind the `DatagramChannel` to `host` and `port`.
    ///
    /// - Parameters:
    ///   - host: The host to bind on.
    ///   - port: The port to bind on.
    public func bind(host: String, port: Int) -> EventLoopFuture<Channel> {
        bind0 {
            try SocketAddress.makeAddressResolvingHost(host, port: port)
        }
    }

    /// Bind the `DatagramChannel` to `address`.
    ///
    /// - Parameters:
    ///   - address: The `SocketAddress` to bind on.
    public func bind(to address: SocketAddress) -> EventLoopFuture<Channel> {
        bind0 { address }
    }

    /// Bind the `DatagramChannel` to a UNIX Domain Socket.
    ///
    /// - Parameters:
    ///   - unixDomainSocketPath: The path of the UNIX Domain Socket to bind on. `path` must not exist, it will be created by the system.
    public func bind(unixDomainSocketPath: String) -> EventLoopFuture<Channel> {
        bind0 {
            try SocketAddress(unixDomainSocketPath: unixDomainSocketPath)
        }
    }

    /// Bind the `DatagramChannel` to a UNIX Domain Socket.
    ///
    /// - Parameters:
    ///   - unixDomainSocketPath: The path of the UNIX Domain Socket to bind on. The`unixDomainSocketPath` must not exist,
    ///     unless `cleanupExistingSocketFile`is set to `true`.
    ///   - cleanupExistingSocketFile: Whether to cleanup an existing socket file at `unixDomainSocketPath`.
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
        let subtype = self.proto
        let address: SocketAddress
        do {
            address = try makeSocketAddress()
        } catch {
            return group.next().makeFailedFuture(error)
        }
        func makeChannel(_ eventLoop: SelectableEventLoop) throws -> DatagramChannel {
            try DatagramChannel(
                eventLoop: eventLoop,
                protocolFamily: address.protocol,
                protocolSubtype: subtype
            )
        }
        return withNewChannel(makeChannel: makeChannel) { _, channel in
            channel.register().flatMap {
                channel.bind(to: address)
            }
        }
    }

    /// Connect the `DatagramChannel` to `host` and `port`.
    ///
    /// - Parameters:
    ///   - host: The host to connect to.
    ///   - port: The port to connect to.
    public func connect(host: String, port: Int) -> EventLoopFuture<Channel> {
        connect0 {
            try SocketAddress.makeAddressResolvingHost(host, port: port)
        }
    }

    /// Connect the `DatagramChannel` to `address`.
    ///
    /// - Parameters:
    ///   - address: The `SocketAddress` to connect to.
    public func connect(to address: SocketAddress) -> EventLoopFuture<Channel> {
        connect0 { address }
    }

    /// Connect the `DatagramChannel` to a UNIX Domain Socket.
    ///
    /// - Parameters:
    ///   - unixDomainSocketPath: The path of the UNIX Domain Socket to connect to. `path` must not exist, it will be created by the system.
    public func connect(unixDomainSocketPath: String) -> EventLoopFuture<Channel> {
        connect0 {
            try SocketAddress(unixDomainSocketPath: unixDomainSocketPath)
        }
    }

    private func connect0(_ makeSocketAddress: () throws -> SocketAddress) -> EventLoopFuture<Channel> {
        let subtype = self.proto
        let address: SocketAddress
        do {
            address = try makeSocketAddress()
        } catch {
            return group.next().makeFailedFuture(error)
        }
        func makeChannel(_ eventLoop: SelectableEventLoop) throws -> DatagramChannel {
            try DatagramChannel(
                eventLoop: eventLoop,
                protocolFamily: address.protocol,
                protocolSubtype: subtype
            )
        }
        return withNewChannel(makeChannel: makeChannel) { _, channel in
            channel.register().flatMap {
                channel.connect(to: address)
            }
        }
    }

    private func withNewChannel(
        makeChannel: (_ eventLoop: SelectableEventLoop) throws -> DatagramChannel,
        _ bringup: @escaping @Sendable (EventLoop, DatagramChannel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        let eventLoop = self.group.next()
        let channelInitializer = self.channelInitializer ?? { @Sendable _ in eventLoop.makeSucceededFuture(()) }
        let channelOptions = self._channelOptions

        let channel: DatagramChannel
        do {
            channel = try makeChannel(eventLoop as! SelectableEventLoop)
        } catch {
            return eventLoop.makeFailedFuture(error)
        }

        @Sendable
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

// MARK: Async connect/bind methods

extension DatagramBootstrap {
    /// Use the existing bound socket file descriptor.
    ///
    /// - Parameters:
    ///   - socket: The _Unix file descriptor_ representing the bound stream socket.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func withBoundSocket<Output: Sendable>(
        _ socket: NIOBSDSocket.Handle,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        func makeChannel(_ eventLoop: SelectableEventLoop) throws -> DatagramChannel {
            try DatagramChannel(eventLoop: eventLoop, socket: socket)
        }
        return try await self.makeConfiguredChannel(
            makeChannel: makeChannel(_:),
            channelInitializer: channelInitializer,
            registration: { channel in
                let promise = channel.eventLoop.makePromise(of: Void.self)
                channel.registerAlreadyConfigured0(promise: promise)
                return promise.futureResult
            },
            postRegisterTransformation: { output, eventLoop in
                eventLoop.makeSucceededFuture(output)
            }
        ).get()
    }

    /// Bind the `DatagramChannel` to `host` and `port`.
    ///
    /// - Parameters:
    ///   - host: The host to bind on.
    ///   - port: The port to bind on.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind<Output: Sendable>(
        host: String,
        port: Int,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        try await self.bind0(
            makeSocketAddress: {
                try SocketAddress.makeAddressResolvingHost(host, port: port)
            },
            channelInitializer: channelInitializer,
            postRegisterTransformation: { output, eventLoop in
                eventLoop.makeSucceededFuture(output)
            }
        )
    }

    /// Bind the `DatagramChannel` to the `address`.
    ///
    /// - Parameters:
    ///   - address: The `SocketAddress` to bind on.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind<Output: Sendable>(
        to address: SocketAddress,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        try await self.bind0(
            makeSocketAddress: {
                address
            },
            channelInitializer: channelInitializer,
            postRegisterTransformation: { output, eventLoop in
                eventLoop.makeSucceededFuture(output)
            }
        )
    }

    /// Bind the `DatagramChannel` to the `unixDomainSocketPath`.
    ///
    /// - Parameters:
    ///   - unixDomainSocketPath: The path of the UNIX Domain Socket to bind on. The`unixDomainSocketPath` must not exist,
    ///     unless `cleanupExistingSocketFile`is set to `true`.
    ///   - cleanupExistingSocketFile: Whether to cleanup an existing socket file at `unixDomainSocketPath`.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func bind<Output: Sendable>(
        unixDomainSocketPath: String,
        cleanupExistingSocketFile: Bool = false,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        if cleanupExistingSocketFile {
            try BaseSocket.cleanupSocket(unixDomainSocketPath: unixDomainSocketPath)
        }

        return try await self.bind0(
            makeSocketAddress: {
                try SocketAddress(unixDomainSocketPath: unixDomainSocketPath)
            },
            channelInitializer: channelInitializer,
            postRegisterTransformation: { output, eventLoop in
                eventLoop.makeSucceededFuture(output)
            }
        )
    }

    /// Connect the `DatagramChannel` to `host` and `port`.
    ///
    /// - Parameters:
    ///   - host: The host to connect to.
    ///   - port: The port to connect to.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect<Output: Sendable>(
        host: String,
        port: Int,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        try await self.connect0(
            makeSocketAddress: {
                try SocketAddress.makeAddressResolvingHost(host, port: port)
            },
            channelInitializer: channelInitializer,
            postRegisterTransformation: { output, eventLoop in
                eventLoop.makeSucceededFuture(output)
            }
        )
    }

    /// Connect the `DatagramChannel` to the `address`.
    ///
    /// - Parameters:
    ///   - address: The `SocketAddress` to connect to.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect<Output: Sendable>(
        to address: SocketAddress,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        try await self.connect0(
            makeSocketAddress: {
                address
            },
            channelInitializer: channelInitializer,
            postRegisterTransformation: { output, eventLoop in
                eventLoop.makeSucceededFuture(output)
            }
        )
    }

    /// Connect the `DatagramChannel` to the `unixDomainSocketPath`.
    ///
    /// - Parameters:
    ///   - unixDomainSocketPath: The path of the UNIX Domain Socket to connect to. `path` must not exist, it will be created by the system.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func connect<Output: Sendable>(
        unixDomainSocketPath: String,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        try await self.connect0(
            makeSocketAddress: {
                try SocketAddress(unixDomainSocketPath: unixDomainSocketPath)
            },
            channelInitializer: channelInitializer,
            postRegisterTransformation: { output, eventLoop in
                eventLoop.makeSucceededFuture(output)
            }
        )
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    private func connect0<ChannelInitializerResult: Sendable, PostRegistrationTransformationResult: Sendable>(
        makeSocketAddress: () throws -> SocketAddress,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<ChannelInitializerResult>,
        postRegisterTransformation:
            @escaping @Sendable (ChannelInitializerResult, EventLoop) -> EventLoopFuture<
                PostRegistrationTransformationResult
            >
    ) async throws -> PostRegistrationTransformationResult {
        let address = try makeSocketAddress()
        let subtype = self.proto

        func makeChannel(_ eventLoop: SelectableEventLoop) throws -> DatagramChannel {
            try DatagramChannel(
                eventLoop: eventLoop,
                protocolFamily: address.protocol,
                protocolSubtype: subtype
            )
        }

        return try await self.makeConfiguredChannel(
            makeChannel: makeChannel(_:),
            channelInitializer: channelInitializer,
            registration: { channel in
                channel.register().flatMap {
                    channel.connect(to: address)
                }
            },
            postRegisterTransformation: postRegisterTransformation
        ).get()
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    private func bind0<ChannelInitializerResult: Sendable, PostRegistrationTransformationResult: Sendable>(
        makeSocketAddress: () throws -> SocketAddress,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<ChannelInitializerResult>,
        postRegisterTransformation:
            @escaping @Sendable (ChannelInitializerResult, EventLoop) -> EventLoopFuture<
                PostRegistrationTransformationResult
            >
    ) async throws -> PostRegistrationTransformationResult {
        let address = try makeSocketAddress()
        let subtype = self.proto

        func makeChannel(_ eventLoop: SelectableEventLoop) throws -> DatagramChannel {
            try DatagramChannel(
                eventLoop: eventLoop,
                protocolFamily: address.protocol,
                protocolSubtype: subtype
            )
        }

        return try await self.makeConfiguredChannel(
            makeChannel: makeChannel(_:),
            channelInitializer: channelInitializer,
            registration: { channel in
                channel.register().flatMap {
                    channel.bind(to: address)
                }
            },
            postRegisterTransformation: postRegisterTransformation
        ).get()
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    private func makeConfiguredChannel<
        ChannelInitializerResult: Sendable,
        PostRegistrationTransformationResult: Sendable
    >(
        makeChannel: (_ eventLoop: SelectableEventLoop) throws -> DatagramChannel,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<ChannelInitializerResult>,
        registration: @escaping @Sendable (Channel) -> EventLoopFuture<Void>,
        postRegisterTransformation:
            @escaping @Sendable (ChannelInitializerResult, EventLoop) -> EventLoopFuture<
                PostRegistrationTransformationResult
            >
    ) -> EventLoopFuture<PostRegistrationTransformationResult> {
        let eventLoop = self.group.next()
        let bootstrapChannelInitializer =
            self.channelInitializer ?? { @Sendable _ in eventLoop.makeSucceededFuture(()) }
        let channelInitializer = { @Sendable (channel: Channel) -> EventLoopFuture<ChannelInitializerResult> in
            bootstrapChannelInitializer(channel)
                .hop(to: channel.eventLoop)
                .assumeIsolated()
                .flatMap { channelInitializer(channel) }
                .nonisolated()
        }
        let channelOptions = self._channelOptions

        let channel: DatagramChannel
        do {
            channel = try makeChannel(eventLoop as! SelectableEventLoop)
        } catch {
            return eventLoop.makeFailedFuture(error)
        }

        @Sendable
        func setupChannel() -> EventLoopFuture<PostRegistrationTransformationResult> {
            eventLoop.assertInEventLoop()
            return channelOptions.applyAllChannelOptions(to: channel).flatMap {
                channelInitializer(channel)
            }.flatMap { (result: ChannelInitializerResult) in
                eventLoop.assertInEventLoop()
                return registration(channel).map {
                    result
                }
            }.flatMap { (result: ChannelInitializerResult) -> EventLoopFuture<PostRegistrationTransformationResult> in
                postRegisterTransformation(result, eventLoop)
            }.flatMapError { error in
                eventLoop.assertInEventLoop()
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
///                       .takingOwnershipOfDescriptors(input: STDIN_FILENO, output: STDOUT_FILENO)
///
public final class NIOPipeBootstrap {
    private let group: EventLoopGroup
    private var channelInitializer: Optional<ChannelInitializerCallback>
    @usableFromInline
    internal var _channelOptions: ChannelOptions.Storage
    private let hooks: any NIOPipeBootstrapHooks

    /// Create a `NIOPipeBootstrap` on the `EventLoopGroup` `group`.
    ///
    /// The `EventLoopGroup` `group` must be compatible, otherwise the program will crash. `NIOPipeBootstrap` is
    /// compatible only with `MultiThreadedEventLoopGroup` as well as the `EventLoop`s returned by
    /// `MultiThreadedEventLoopGroup.next`. See `init(validatingGroup:)` for a fallible initializer for
    /// situations where it's impossible to tell ahead of time if the `EventLoopGroup`s are compatible or not.
    ///
    /// - Parameters:
    ///   - group: The `EventLoopGroup` to use.
    public convenience init(group: EventLoopGroup) {
        guard NIOOnSocketsBootstraps.isCompatible(group: group) else {
            preconditionFailure(
                "NIOPipeBootstrap is only compatible with MultiThreadedEventLoopGroup and "
                    + "SelectableEventLoop. You tried constructing one with \(group) which is incompatible."
            )
        }
        self.init(validatingGroup: group)!
    }

    /// Create a `NIOPipeBootstrap` on the `EventLoopGroup` `group`, validating that `group` is compatible.
    ///
    /// - Parameters:
    ///   - group: The `EventLoopGroup` to use.
    public init?(validatingGroup group: EventLoopGroup) {
        guard NIOOnSocketsBootstraps.isCompatible(group: group) else {
            return nil
        }

        self._channelOptions = ChannelOptions.Storage()
        self.group = group
        self.channelInitializer = nil
        self.hooks = DefaultNIOPipeBootstrapHooks()
    }

    /// Initialiser for hooked testing
    init?(validatingGroup group: EventLoopGroup, hooks: any NIOPipeBootstrapHooks) {
        guard NIOOnSocketsBootstraps.isCompatible(group: group) else {
            return nil
        }

        self._channelOptions = ChannelOptions.Storage()
        self.group = group
        self.channelInitializer = nil
        self.hooks = hooks
    }

    /// Initialize the connected `PipeChannel` with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// The connected `Channel` will operate on `ByteBuffer` as inbound and outbound messages. Please note that
    /// `IOData.fileRegion` is _not_ supported for `PipeChannel`s because `sendfile` only works on sockets.
    ///
    /// - Parameters:
    ///   - handler: A closure that initializes the provided `Channel`.
    @preconcurrency
    public func channelInitializer(_ handler: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> Self {
        self.channelInitializer = handler
        return self
    }

    /// Specifies a `ChannelOption` to be applied to the `PipeChannel`.
    ///
    /// - Parameters:
    ///   - option: The option to be applied.
    ///   - value: The value for the option.
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
            throw ChannelError._operationUnsupported
        }
        #else
        var s: stat = .init()
        try withUnsafeMutablePointer(to: &s) { ptr in
            try Posix.fstat(descriptor: descriptor, outStat: ptr)
        }
        switch s.st_mode & S_IFMT {
        case S_IFREG, S_IFDIR, S_IFLNK, S_IFBLK:
            throw ChannelError._operationUnsupported
        default:
            ()  // Let's default to ok
        }
        #endif
    }

    /// Create the `PipeChannel` with the provided file descriptor which is used for both input & output.
    ///
    /// This method is useful for specialilsed use-cases where you want to use `NIOPipeBootstrap` for say a serial line.
    ///
    /// - Note: If this method returns a succeeded future, SwiftNIO will close `inputOutput` when the `Channel`
    ///         becomes inactive. You _must not_ do any further operations with `inputOutput`, including `close`.
    ///         If this method returns a failed future, you still own the file descriptor and are responsible for
    ///         closing it.
    ///
    /// - Parameters:
    ///   - inputOutput: The _Unix file descriptor_ for the input & output.
    /// - Returns: an `EventLoopFuture<Channel>` to deliver the `Channel`.
    public func takingOwnershipOfDescriptor(inputOutput: CInt) -> EventLoopFuture<Channel> {
        #if os(Windows)
        fatalError(missingPipeSupportWindows)
        #else
        let inputFD = inputOutput
        let outputFD = try! Posix.dup(descriptor: inputOutput)

        return self.takingOwnershipOfDescriptors(input: inputFD, output: outputFD).flatMapErrorThrowing { error in
            try! Posix.close(descriptor: outputFD)
            throw error
        }
        #endif
    }

    /// Create the `PipeChannel` with the provided input and output file descriptors.
    ///
    /// The input and output file descriptors must be distinct. If you have a single file descriptor, consider using
    /// `ClientBootstrap.withConnectedSocket(descriptor:)` if it's a socket or
    /// `NIOPipeBootstrap.takingOwnershipOfDescriptor` if it is not a socket.
    ///
    /// - Note: If this method returns a succeeded future, SwiftNIO will close `input` and `output`
    ///         when the `Channel` becomes inactive. You _must not_ do any further operations `input` or
    ///         `output`, including `close`.
    ///         If this method returns a failed future, you still own the file descriptors and are responsible for
    ///         closing them.
    ///
    /// - Parameters:
    ///   - input: The _Unix file descriptor_ for the input (ie. the read side).
    ///   - output: The _Unix file descriptor_ for the output (ie. the write side).
    /// - Returns: an `EventLoopFuture<Channel>` to deliver the `Channel`.
    public func takingOwnershipOfDescriptors(input: CInt, output: CInt) -> EventLoopFuture<Channel> {
        self._takingOwnershipOfDescriptors(input: input, output: output)
    }

    /// Create the `PipeChannel` with the provided input file descriptor.
    ///
    /// The input file descriptor must be distinct.
    ///
    /// - Note: If this method returns a succeeded future, SwiftNIO will close `input` when the `Channel`
    ///         becomes inactive. You _must not_ do any further operations to `input`, including `close`.
    ///         If this method returns a failed future, you still own the file descriptor and are responsible for
    ///         closing them.
    ///
    /// - Parameters:
    ///   - input: The _Unix file descriptor_ for the input (ie. the read side).
    /// - Returns: an `EventLoopFuture<Channel>` to deliver the `Channel`.
    public func takingOwnershipOfDescriptor(
        input: CInt
    ) -> EventLoopFuture<Channel> {
        self._takingOwnershipOfDescriptors(input: input, output: nil)
    }

    /// Create the `PipeChannel` with the provided output file descriptor.
    ///
    /// The output file descriptor must be distinct.
    ///
    /// - Note: If this method returns a succeeded future, SwiftNIO will close `output` when the `Channel`
    ///         becomes inactive. You _must not_ do any further operations to `output`, including `close`.
    ///         If this method returns a failed future, you still own the file descriptor and are responsible for
    ///         closing them.
    ///
    /// - Parameters:
    ///   - output: The _Unix file descriptor_ for the output (ie. the write side).
    /// - Returns: an `EventLoopFuture<Channel>` to deliver the `Channel`.
    public func takingOwnershipOfDescriptor(
        output: CInt
    ) -> EventLoopFuture<Channel> {
        self._takingOwnershipOfDescriptors(input: nil, output: output)
    }

    private func _takingOwnershipOfDescriptors(input: CInt?, output: CInt?) -> EventLoopFuture<Channel> {
        self._takingOwnershipOfDescriptors(
            input: input,
            output: output
        ) { channel in
            channel.eventLoop.makeSucceededFuture(channel)
        }
    }

    @available(*, deprecated, renamed: "takingOwnershipOfDescriptor(inputOutput:)")
    public func withInputOutputDescriptor(_ fileDescriptor: CInt) -> EventLoopFuture<Channel> {
        self.takingOwnershipOfDescriptor(inputOutput: fileDescriptor)
    }

    @available(*, deprecated, renamed: "takingOwnershipOfDescriptors(input:output:)")
    public func withPipes(inputDescriptor: CInt, outputDescriptor: CInt) -> EventLoopFuture<Channel> {
        self.takingOwnershipOfDescriptors(input: inputDescriptor, output: outputDescriptor)
    }
}

// MARK: Arbitrary payload

extension NIOPipeBootstrap {
    /// Create the `PipeChannel` with the provided file descriptor which is used for both input & output.
    ///
    /// This method is useful for specialilsed use-cases where you want to use `NIOPipeBootstrap` for say a serial line.
    ///
    /// - Note: If this method returns a succeeded future, SwiftNIO will close `inputOutput` when the `Channel`
    ///         becomes inactive. You _must not_ do any further operations with `inputOutput`, including `close`.
    ///         If this method returns a failed future, you still own the file descriptor and are responsible for
    ///         closing it.
    ///
    /// - Parameters:
    ///   - inputOutput: The _Unix file descriptor_ for the input & output.
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func takingOwnershipOfDescriptor<Output: Sendable>(
        inputOutput: CInt,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        #if os(Windows)
        fatalError(missingPipeSupportWindows)
        #else
        let inputFD = inputOutput
        let outputFD = try! Posix.dup(descriptor: inputOutput)

        do {
            return try await self.takingOwnershipOfDescriptors(
                input: inputFD,
                output: outputFD,
                channelInitializer: channelInitializer
            )
        } catch {
            try! Posix.close(descriptor: outputFD)
            throw error
        }
        #endif
    }

    /// Create the `PipeChannel` with the provided input and output file descriptors.
    ///
    /// The input and output file descriptors must be distinct.
    ///
    /// - Note: If this method returns a succeeded future, SwiftNIO will close `input` and `output`
    ///         when the `Channel` becomes inactive. You _must not_ do any further operations `input` or
    ///         `output`, including `close`.
    ///         If this method returns a failed future, you still own the file descriptors and are responsible for
    ///         closing them.
    ///
    /// - Parameters:
    ///   - input: The _Unix file descriptor_ for the input (ie. the read side).
    ///   - output: The _Unix file descriptor_ for the output (ie. the write side).
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func takingOwnershipOfDescriptors<Output: Sendable>(
        input: CInt,
        output: CInt,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        try await self._takingOwnershipOfDescriptors(
            input: input,
            output: output,
            channelInitializer: channelInitializer
        )
    }

    /// Create the `PipeChannel` with the provided input file descriptor.
    ///
    /// The input file descriptor must be distinct.
    ///
    /// - Note: If this method returns a succeeded future, SwiftNIO will close `input` when the `Channel`
    ///         becomes inactive. You _must not_ do any further operations to `input`, including `close`.
    ///         If this method returns a failed future, you still own the file descriptor and are responsible for
    ///         closing them.
    ///
    /// - Parameters:
    ///   - input: The _Unix file descriptor_ for the input (ie. the read side).
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func takingOwnershipOfDescriptor<Output: Sendable>(
        input: CInt,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        try await self._takingOwnershipOfDescriptors(
            input: input,
            output: nil,
            channelInitializer: channelInitializer
        )
    }

    /// Create the `PipeChannel` with the provided output file descriptor.
    ///
    /// The output file descriptor must be distinct.
    ///
    /// - Note: If this method returns a succeeded future, SwiftNIO will close `output` when the `Channel`
    ///         becomes inactive. You _must not_ do any further operations to `output`, including `close`.
    ///         If this method returns a failed future, you still own the file descriptor and are responsible for
    ///         closing them.
    ///
    /// - Parameters:
    ///   - output: The _Unix file descriptor_ for the output (ie. the write side).
    ///   - channelInitializer: A closure to initialize the channel. The return value of this closure is returned from the `connect`
    ///   method.
    /// - Returns: The result of the channel initializer.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public func takingOwnershipOfDescriptor<Output: Sendable>(
        output: CInt,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Output>
    ) async throws -> Output {
        try await self._takingOwnershipOfDescriptors(
            input: nil,
            output: output,
            channelInitializer: channelInitializer
        )
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    func _takingOwnershipOfDescriptors<ChannelInitializerResult: Sendable>(
        input: CInt?,
        output: CInt?,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<ChannelInitializerResult>
    ) async throws -> ChannelInitializerResult {
        try await self._takingOwnershipOfDescriptors(
            input: input,
            output: output,
            channelInitializer: channelInitializer
        ).get()
    }

    func _takingOwnershipOfDescriptors<ChannelInitializerResult: Sendable>(
        input: CInt?,
        output: CInt?,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<ChannelInitializerResult>
    ) -> EventLoopFuture<ChannelInitializerResult> {
        #if os(Windows)
        fatalError(missingPipeSupportWindows)
        #else
        precondition(
            input ?? 0 >= 0 && output ?? 0 >= 0 && input != output,
            "illegal file descriptor pair. The file descriptors \(String(describing: input)), \(String(describing: output)) "
                + "must be distinct and both positive integers."
        )
        precondition(!(input == nil && output == nil), "Either input or output has to be set")
        let eventLoop = group.next()
        let channelOptions = self._channelOptions

        let channel: PipeChannel
        let pipeChannelInput: SelectablePipeHandle?
        let pipeChannelOutput: SelectablePipeHandle?
        let hasNoInputPipe: Bool
        let hasNoOutputPipe: Bool
        let bootstrapChannelInitializer = self.channelInitializer
        do {
            if let input = input {
                try self.validateFileDescriptorIsNotAFile(input)
            }
            if let output = output {
                try self.validateFileDescriptorIsNotAFile(output)
            }

            pipeChannelInput = input.flatMap { SelectablePipeHandle(takingOwnershipOfDescriptor: $0) }
            pipeChannelOutput = output.flatMap { SelectablePipeHandle(takingOwnershipOfDescriptor: $0) }
            hasNoInputPipe = pipeChannelInput == nil
            hasNoOutputPipe = pipeChannelOutput == nil
            do {
                channel = try self.hooks.makePipeChannel(
                    eventLoop: eventLoop as! SelectableEventLoop,
                    input: pipeChannelInput,
                    output: pipeChannelOutput
                )
            } catch {
                // Release file handles back to the caller in case of failure.
                _ = try? pipeChannelInput?.takeDescriptorOwnership()
                _ = try? pipeChannelOutput?.takeDescriptorOwnership()
                throw error
            }
        } catch {
            return eventLoop.makeFailedFuture(error)
        }

        @Sendable
        func setupChannel() -> EventLoopFuture<ChannelInitializerResult> {
            eventLoop.assertInEventLoop()
            return channelOptions.applyAllChannelOptions(to: channel).flatMap {
                if let bootstrapChannelInitializer {
                    bootstrapChannelInitializer(channel)
                } else {
                    channel.eventLoop.makeSucceededVoidFuture()
                }
            }
            .flatMap {
                _ -> EventLoopFuture<ChannelInitializerResult> in
                channelInitializer(channel)
            }.flatMap { result in
                eventLoop.assertInEventLoop()
                let promise = eventLoop.makePromise(of: Void.self)
                channel.registerAlreadyConfigured0(promise: promise)
                return promise.futureResult.map { result }
            }.flatMap { result -> EventLoopFuture<ChannelInitializerResult> in
                if hasNoInputPipe {
                    return channel.close(mode: .input).map { result }
                }
                if hasNoOutputPipe {
                    return channel.close(mode: .output).map { result }
                }
                return channel.selectableEventLoop.makeSucceededFuture(result)
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
        #endif
    }
}

@available(*, unavailable)
extension NIOPipeBootstrap: Sendable {}

protocol NIOPipeBootstrapHooks {
    func makePipeChannel(
        eventLoop: SelectableEventLoop,
        input: SelectablePipeHandle?,
        output: SelectablePipeHandle?
    ) throws -> PipeChannel
}

private struct DefaultNIOPipeBootstrapHooks: NIOPipeBootstrapHooks {
    func makePipeChannel(
        eventLoop: SelectableEventLoop,
        input: SelectablePipeHandle?,
        output: SelectablePipeHandle?
    ) throws -> PipeChannel {
        try PipeChannel(eventLoop: eventLoop, input: input, output: output)
    }
}
