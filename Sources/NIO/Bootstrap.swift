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

/// A `ServerBootstrap` is an easy way to bootstrap a `ServerSocketChannel` when creating network servers.
///
/// Example:
///
/// ```swift
///     let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
///     let bootstrap = ServerBootstrap(group: group)
///         // Specify backlog and enable SO_REUSEADDR for the server itself
///         .serverChannelOption(ChannelOptions.backlog, value: 256)
///         .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
///
///         // Set the handlers that are applied to the accepted child `Channel`s.
///         .childChannelInitializer { channel in
///             // Ensure we don't read faster then we can write by adding the BackPressureHandler into the pipeline.
///             channel.pipeline.add(handler: BackPressureHandler()).then { () in
///                 channel.pipeline.add(handler: MyChannelHandler())
///             }
///         }
///
///         // Enable TCP_NODELAY and SO_REUSEADDR for the accepted Channels
///         .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
///         .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
///         .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
///         .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
///     defer {
///         try! group.syncShutdownGracefully()
///     }
///     try! bootstrap.bind(host: host, port: port).wait()
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
    private var serverChannelInit: ((Channel) -> EventLoopFuture<Void>)?
    private var childChannelInit: ((Channel) -> EventLoopFuture<Void>)?
    private var serverChannelOptions = ChannelOptionStorage()
    private var childChannelOptions = ChannelOptionStorage()

    /// Create a `ServerBootstrap` for the `EventLoopGroup` `group`.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use for the `ServerSocketChannel`.
    public convenience init(group: EventLoopGroup) {
        self.init(group: group, childGroup: group)
    }

    /// Create a `ServerBootstrap`.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use for the `bind` of the `ServerSocketChannel` and to accept new `SocketChannel`s with.
    ///     - childGroup: The `EventLoopGroup` to run the accepted `SocketChannel`s on.
    public init(group: EventLoopGroup, childGroup: EventLoopGroup) {
        self.group = group
        self.childGroup = childGroup
    }

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

    /// Initialize the accepted `SocketChannel`s with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// The accepted `Channel` will operate on `ByteBuffer` as inbound and `IOData` as outbound messages.
    ///
    /// - parameters:
    ///     - initializer: A closure that initializes the provided `Channel`.
    public func childChannelInitializer(_ initializer: @escaping (Channel) -> EventLoopFuture<Void>) -> Self {
        self.childChannelInit = initializer
        return self
    }

    /// Specifies a `ChannelOption` to be applied to the `ServerSocketChannel`.
    ///
    /// - note: To specify options for the accepted `SocketChannel`s, look at `ServerBootstrap.childChannelOption`.
    ///
    /// - parameters:
    ///     - option: The option to be applied.
    ///     - value: The value for the option.
    public func serverChannelOption<T: ChannelOption>(_ option: T, value: T.OptionType) -> Self {
        serverChannelOptions.put(key: option, value: value)
        return self
    }

    /// Specifies a `ChannelOption` to be applied to the accepted `SocketChannel`s.
    ///
    /// - parameters:
    ///     - option: The option to be applied.
    ///     - value: The value for the option.
    public func childChannelOption<T: ChannelOption>(_ option: T, value: T.OptionType) -> Self {
        childChannelOptions.put(key: option, value: value)
        return self
    }

    /// Bind the `ServerSocketChannel` to `host` and `port`.
    ///
    /// - parameters:
    ///     - host: The host to bind on.
    ///     - port: The port to bind on.
    public func bind(host: String, port: Int) -> EventLoopFuture<Channel> {
        return bind0 {
            return try SocketAddress.newAddressResolving(host: host, port: port)
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

    /// Use the existing bound socket file descriptor.
    ///
    /// - parameters:
    ///     - descriptor: The _Unix file descriptor_ representing the bound stream socket.
    public func withBoundSocket(descriptor: CInt) -> EventLoopFuture<Channel> {
        func makeChannel(_ eventLoop: SelectableEventLoop, _ childEventLoopGroup: EventLoopGroup) throws -> ServerSocketChannel {
            return try ServerSocketChannel(descriptor: descriptor, eventLoop: eventLoop, group: childEventLoopGroup)
        }
        return bind0(makeServerChannel: makeChannel) { (eventLoop, serverChannel) in
            let promise: EventLoopPromise<Void> = eventLoop.newPromise()
            serverChannel.registerAlreadyConfigured0(promise: promise)
            return promise.futureResult
        }
    }

    private func bind0(_ makeSocketAddress: () throws -> SocketAddress) -> EventLoopFuture<Channel> {
        let address: SocketAddress
        do {
            address = try makeSocketAddress()
        } catch {
            return group.next().newFailedFuture(error: error)
        }
        func makeChannel(_ eventLoop: SelectableEventLoop, _ childEventLoopGroup: EventLoopGroup) throws -> ServerSocketChannel {
            return try ServerSocketChannel(eventLoop: eventLoop,
                                           group: childEventLoopGroup,
                                           protocolFamily: address.protocolFamily)
        }

        return bind0(makeServerChannel: makeChannel) { (eventGroup, serverChannel) in
            serverChannel.registerAndDoSynchronously { serverChannel in
                serverChannel.bind(to: address)
            }
        }
    }

    private func bind0(makeServerChannel: (_ eventLoop: SelectableEventLoop, _ childGroup: EventLoopGroup) throws -> ServerSocketChannel, _ register: @escaping (EventLoop, ServerSocketChannel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel> {
        let eventLoop = self.group.next()
        let childEventLoopGroup = self.childGroup
        let serverChannelOptions = self.serverChannelOptions
        let serverChannelInit = self.serverChannelInit ?? { _ in eventLoop.newSucceededFuture(result: ()) }
        let childChannelInit = self.childChannelInit
        let childChannelOptions = self.childChannelOptions

        let serverChannel: ServerSocketChannel
        do {
            serverChannel = try makeServerChannel(eventLoop as! SelectableEventLoop, childEventLoopGroup)
        } catch {
            return eventLoop.newFailedFuture(error: error)
        }

        return eventLoop.submit {
            return serverChannelInit(serverChannel).then {
                serverChannel.pipeline.add(handler: AcceptHandler(childChannelInitializer: childChannelInit,
                                                                  childChannelOptions: childChannelOptions))
            }.then {
                serverChannelOptions.applyAll(channel: serverChannel)
            }.then {
                register(eventLoop, serverChannel)
            }.map {
                serverChannel as Channel
            }.thenIfError { error in
                serverChannel.close0(error: error, mode: .all, promise: nil)
                return eventLoop.newFailedFuture(error: error)
            }
        }.then {
            $0
        }
    }

    private class AcceptHandler: ChannelInboundHandler {
        public typealias InboundIn = SocketChannel

        private let childChannelInit: ((Channel) -> EventLoopFuture<Void>)?
        private let childChannelOptions: ChannelOptionStorage

        init(childChannelInitializer: ((Channel) -> EventLoopFuture<Void>)?, childChannelOptions: ChannelOptionStorage) {
            self.childChannelInit = childChannelInitializer
            self.childChannelOptions = childChannelOptions
        }

        func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
            if event is ChannelShouldQuiesceEvent {
                ctx.channel.close(promise: nil)
            }
            ctx.fireUserInboundEventTriggered(event)
        }

        func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
            let accepted = self.unwrapInboundIn(data)
            let ctxEventLoop = ctx.eventLoop
            let childEventLoop = accepted.eventLoop
            let childChannelInit = self.childChannelInit ?? { (_: Channel) in childEventLoop.newSucceededFuture(result: ()) }

            @inline(__always)
            func setupChildChannel() -> EventLoopFuture<Void> {
                return self.childChannelOptions.applyAll(channel: accepted).then { () -> EventLoopFuture<Void> in
                    assert(childEventLoop.inEventLoop)
                    return childChannelInit(accepted)
                }
            }

            @inline(__always)
            func fireThroughPipeline(_ future: EventLoopFuture<Void>) {
                assert(ctxEventLoop.inEventLoop)
                future.then { (_) -> EventLoopFuture<Void> in
                    assert(ctxEventLoop.inEventLoop)
                    guard !ctx.pipeline.destroyed else {
                        return ctx.eventLoop.newFailedFuture(error: ChannelError.ioOnClosedChannel)
                    }
                    ctx.fireChannelRead(data)
                    return ctx.eventLoop.newSucceededFuture(result: ())
                }.whenFailure { error in
                    assert(ctx.eventLoop.inEventLoop)
                    self.closeAndFire(ctx: ctx, accepted: accepted, err: error)
                }
            }

            if childEventLoop === ctxEventLoop {
                fireThroughPipeline(setupChildChannel())
            } else {
                fireThroughPipeline(childEventLoop.submit {
                    return setupChildChannel()
                }.then { $0 }.hopTo(eventLoop: ctxEventLoop))
            }
        }

        private func closeAndFire(ctx: ChannelHandlerContext, accepted: SocketChannel, err: Error) {
            accepted.close(promise: nil)
            if ctx.eventLoop.inEventLoop {
                ctx.fireErrorCaught(err)
            } else {
                ctx.eventLoop.execute {
                    ctx.fireErrorCaught(err)
                }
            }
        }
    }
}

private extension Channel {
    func registerAndDoSynchronously(_ body: @escaping (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Void> {
        // this is pretty delicate at the moment:
        // In many cases `body` must be _synchronously_ follow `register`, otherwise in our current
        // implementation, `epoll` will send us `EPOLLHUP`. To have it run synchronously, we need to invoke the
        // `then` on the eventloop that the `register` will succeed on.
        assert(self.eventLoop.inEventLoop)
        return self.register().then {
            assert(self.eventLoop.inEventLoop)
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
///     let bootstrap = ClientBootstrap(group: group)
///         // Enable SO_REUSEADDR.
///         .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
///         .channelInitializer { channel in
///             channel.pipeline.add(handler: MyChannelHandler())
///         }
///     defer {
///         try! group.syncShutdownGracefully()
///     }
///     try! bootstrap.connect(host: "example.org", port: 12345).wait()
///     /* the Channel is now connected */
/// ```
///
/// The connected `SocketChannel` will operate on `ByteBuffer` as inbound and on `IOData` as outbound messages.
public final class ClientBootstrap {

    private let group: EventLoopGroup
    private var channelInitializer: ((Channel) -> EventLoopFuture<Void>)?
    private var channelOptions = ChannelOptionStorage()
    private var connectTimeout: TimeAmount = TimeAmount.seconds(10)
    private var resolver: Resolver?

    /// Create a `ClientBootstrap` on the `EventLoopGroup` `group`.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use.
    public init(group: EventLoopGroup) {
        self.group = group
    }

    /// Initialize the connected `SocketChannel` with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// The connected `Channel` will operate on `ByteBuffer` as inbound and `IOData` as outbound messages.
    ///
    /// - parameters:
    ///     - handler: A closure that initializes the provided `Channel`.
    public func channelInitializer(_ handler: @escaping (Channel) -> EventLoopFuture<Void>) -> Self {
        self.channelInitializer = handler
        return self
    }

    /// Specifies a `ChannelOption` to be applied to the `SocketChannel`.
    ///
    /// - parameters:
    ///     - option: The option to be applied.
    ///     - value: The value for the option.
    public func channelOption<T: ChannelOption>(_ option: T, value: T.OptionType) -> Self {
        channelOptions.put(key: option, value: value)
        return self
    }

    /// Specifies a timeout to apply to a connection attempt.
    //
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

    /// Specify the `host` and `port` to connect to for the TCP `Channel` that will be established.
    ///
    /// - parameters:
    ///     - host: The host to connect to.
    ///     - port: The port to connect to.
    /// - returns: An `EventLoopFuture<Channel>` to deliver the `Channel` when connected.
    public func connect(host: String, port: Int) -> EventLoopFuture<Channel> {
        let loop = self.group.next()
        let connector = HappyEyeballsConnector(resolver: resolver ?? GetaddrinfoResolver(loop: loop, aiSocktype: Posix.SOCK_STREAM, aiProtocol: Posix.IPPROTO_TCP),
                                               loop: loop,
                                               host: host,
                                               port: port,
                                               connectTimeout: self.connectTimeout) { eventLoop, protocolFamily in
            return self.execute(eventLoop: eventLoop, protocolFamily: protocolFamily) { $0.eventLoop.newSucceededFuture(result: ()) }
        }
        return connector.resolveAndConnect()
    }

    /// Specify the `address` to connect to for the TCP `Channel` that will be established.
    ///
    /// - parameters:
    ///     - address: The address to connect to.
    /// - returns: An `EventLoopFuture<Channel>` to deliver the `Channel` when connected.
    public func connect(to address: SocketAddress) -> EventLoopFuture<Channel> {
        return execute(eventLoop: group.next(), protocolFamily: address.protocolFamily) { channel in
            let connectPromise: EventLoopPromise<Void> = channel.eventLoop.newPromise()
            channel.connect(to: address, promise: connectPromise)
            let cancelTask = channel.eventLoop.scheduleTask(in: self.connectTimeout) {
                connectPromise.fail(error: ChannelError.connectTimeout(self.connectTimeout))
                channel.close(promise: nil)
            }

            connectPromise.futureResult.whenComplete {
                cancelTask.cancel()
            }
            return connectPromise.futureResult
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
            return connect(to: address)
        } catch {
            return group.next().newFailedFuture(error: error)
        }
    }

    /// Use the existing connected socket file descriptor.
    ///
    /// - parameters:
    ///     - descriptor: The _Unix file descriptor_ representing the connected stream socket.
    /// - returns: an `EventLoopFuture<Channel>` to deliver the `Channel` immediately.
    public func withConnectedSocket(descriptor: CInt) -> EventLoopFuture<Channel> {
        let eventLoop = group.next()
        let channelInitializer = self.channelInitializer ?? { _ in eventLoop.newSucceededFuture(result: ()) }
        let channel: SocketChannel
        do {
            channel = try SocketChannel(eventLoop: eventLoop as! SelectableEventLoop, descriptor: descriptor)
        } catch {
            return eventLoop.newFailedFuture(error: error)
        }

        return channelInitializer(channel).then {
            self.channelOptions.applyAll(channel: channel)
        }.then {
            let promise: EventLoopPromise<Void> = eventLoop.newPromise()
            channel.registerAlreadyConfigured0(promise: promise)
            return promise.futureResult
        }.map {
            channel
        }.thenIfError { error in
            channel.close0(error: error, mode: .all, promise: nil)
            return channel.eventLoop.newFailedFuture(error: error)
        }
    }

    private func execute(eventLoop: EventLoop,
                         protocolFamily: Int32,
                         _ body: @escaping (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel> {
        let channelInitializer = self.channelInitializer ?? { _ in eventLoop.newSucceededFuture(result: ()) }
        let channelOptions = self.channelOptions

        let promise: EventLoopPromise<Channel> = eventLoop.newPromise()
        let channel: SocketChannel
        do {
            channel = try SocketChannel(eventLoop: eventLoop as! SelectableEventLoop, protocolFamily: protocolFamily)
        } catch let err {
            promise.fail(error: err)
            return promise.futureResult
        }

        @inline(__always)
        func setupChannel() -> EventLoopFuture<Channel> {
            assert(eventLoop.inEventLoop)
            channelInitializer(channel).then {
                channelOptions.applyAll(channel: channel)
            }.then {
                channel.registerAndDoSynchronously(body)
            }.map {
                channel
            }.thenIfError { error in
                channel.close0(error: error, mode: .all, promise: nil)
                return channel.eventLoop.newFailedFuture(error: error)
            }.cascade(promise: promise)
            return promise.futureResult
        }

        if eventLoop.inEventLoop {
            return setupChannel()
        } else {
            return eventLoop.submit(setupChannel).then { $0 }
        }
    }
}

/// A `DatagramBootstrap` is an easy way to bootstrap a `DatagramChannel` when creating datagram clients
/// and servers.
///
/// Example:
///
/// ```swift
///     let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
///     let bootstrap = DatagramBootstrap(group: group)
///         // Enable SO_REUSEADDR.
///         .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
///         .channelInitializer { channel in
///             channel.pipeline.add(handler: MyChannelHandler())
///         }
///     defer {
///         try! group.syncShutdownGracefully()
///     }
///     let channel = try! bootstrap.bind(host: "127.0.0.1", port: 53).wait()
///     /* the Channel is now ready to send/receive datagrams */
///
///     try channel.closeFuture.wait()  // Wait until the channel un-binds.
/// ```
///
/// The `DatagramChannel` will operate on `AddressedEnvelope<ByteBuffer>` as inbound and outbound messages.
public final class DatagramBootstrap {

    private let group: EventLoopGroup
    private var channelInitializer: ((Channel) -> EventLoopFuture<Void>)?
    private var channelOptions = ChannelOptionStorage()

    /// Create a `DatagramBootstrap` on the `EventLoopGroup` `group`.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use.
    public init(group: EventLoopGroup) {
        self.group = group
    }

    /// Initialize the bound `DatagramChannel` with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - handler: A closure that initializes the provided `Channel`.
    public func channelInitializer(_ handler: @escaping (Channel) -> EventLoopFuture<Void>) -> Self {
        self.channelInitializer = handler
        return self
    }

    /// Specifies a `ChannelOption` to be applied to the `DatagramChannel`.
    ///
    /// - parameters:
    ///     - option: The option to be applied.
    ///     - value: The value for the option.
    public func channelOption<T: ChannelOption>(_ option: T, value: T.OptionType) -> Self {
        channelOptions.put(key: option, value: value)
        return self
    }

    /// Use the existing bound socket file descriptor.
    ///
    /// - parameters:
    ///     - descriptor: The _Unix file descriptor_ representing the bound datagram socket.
    public func withBoundSocket(descriptor: CInt) -> EventLoopFuture<Channel> {
        func makeChannel(_ eventLoop: SelectableEventLoop) throws -> DatagramChannel {
            return try DatagramChannel(eventLoop: eventLoop, descriptor: descriptor)
        }
        return bind0(makeChannel: makeChannel) { (eventLoop, channel) in
            let promise: EventLoopPromise<Void> = eventLoop.newPromise()
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
            return try SocketAddress.newAddressResolving(host: host, port: port)
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

    private func bind0(_ makeSocketAddress: () throws -> SocketAddress) -> EventLoopFuture<Channel> {
        let address: SocketAddress
        do {
            address = try makeSocketAddress()
        } catch {
            return group.next().newFailedFuture(error: error)
        }
        func makeChannel(_ eventLoop: SelectableEventLoop) throws -> DatagramChannel {
            return try DatagramChannel(eventLoop: eventLoop,
                                       protocolFamily: address.protocolFamily)
        }
        return bind0(makeChannel: makeChannel) { (eventLoop, channel) in
            channel.register().then {
                channel.bind(to: address)
            }
        }
    }

    private func bind0(makeChannel: (_ eventLoop: SelectableEventLoop) throws -> DatagramChannel, _ registerAndBind: @escaping (EventLoop, DatagramChannel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel> {
        let eventLoop = self.group.next()
        let channelInitializer = self.channelInitializer ?? { _ in eventLoop.newSucceededFuture(result: ()) }
        let channelOptions = self.channelOptions

        let channel: DatagramChannel
        do {
            channel = try makeChannel(eventLoop as! SelectableEventLoop)
        } catch {
            return eventLoop.newFailedFuture(error: error)
        }

        return channelInitializer(channel).then {
            channelOptions.applyAll(channel: channel)
        }.then {
            registerAndBind(eventLoop, channel)
        }.map {
            channel
        }.thenIfError { error in
            eventLoop.newFailedFuture(error: error)
        }
    }
}

fileprivate struct ChannelOptionStorage {
    private var storage: [(Any, (Any, (Channel) -> (Any, Any) -> EventLoopFuture<Void>))] = []

    mutating func put<K: ChannelOption>(key: K,
                             value newValue: K.OptionType) {
        func applier(_ t: Channel) -> (Any, Any) -> EventLoopFuture<Void> {
            return { (x, y) in
                return t.setOption(option: x as! K, value: y as! K.OptionType)
            }
        }
        var hasSet = false
        self.storage = self.storage.map { typeAndValue in
            let (type, value) = typeAndValue
            if type is K {
                hasSet = true
                return (key, (newValue, applier))
            } else {
                return (type, value)
            }
        }
        if !hasSet {
            self.storage.append((key, (newValue, applier)))
        }
    }

    func applyAll(channel: Channel) -> EventLoopFuture<Void> {
        let applyPromise: EventLoopPromise<Void> = channel.eventLoop.newPromise()
        var it = self.storage.makeIterator()

        func applyNext() {
            guard let (key, (value, applier)) = it.next() else {
                // If we reached the end, everything is applied.
                applyPromise.succeed(result: ())
                return
            }

            applier(channel)(key, value).map {
                applyNext()
            }.cascadeFailure(promise: applyPromise)
        }
        applyNext()

        return applyPromise.futureResult
    }
}
