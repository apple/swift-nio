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

/// A `ServerBootstrap` is an easy way to bootstrap a `ServerChannel` when creating network servers.
public final class ServerBootstrap {
    
    private let group: EventLoopGroup
    private let childGroup: EventLoopGroup
    private var serverChannelInit: ((Channel) -> EventLoopFuture<()>)?
    private var childChannelInit: ((Channel) -> EventLoopFuture<()>)?
    private var serverChannelOptions = ChannelOptionStorage()
    private var childChannelOptions = ChannelOptionStorage()

    /// Create a `ServerBootstrap` for the `EventLoopGroup` `group`.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use for the `ServerChannel`.
    public convenience init(group: EventLoopGroup) {
        self.init(group: group, childGroup: group)
    }

    /// Create a `ServerBootstrap`.
    ///
    /// - parameters:
    ///     - group: The `EventLoopGroup` to use for the `bind` of the `ServerSocketChannel`.
    ///     - childGroup: The `EventLoopGroup` to run the accepted `SocketChannel`s on.
    public init(group: EventLoopGroup, childGroup: EventLoopGroup) {
        self.group = group
        self.childGroup = childGroup
    }
    
    /// Initialize the `ServerSocketChannel` with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// - note: To set the initializer for the accepted `SocketChannel`s, look at `ServerBootstrap.childChannelInitializer`.
    ///
    /// - parameters:
    ///     - initializer: A closure that initializes the provided `Channel`.
    public func serverChannelInitializer(_ initializer: @escaping (Channel) -> EventLoopFuture<()>) -> Self {
        self.serverChannelInit = initializer
        return self
    }
    
    /// Initialize the accepted `SocketChannel`s with `initializer`. The most common task in initializer is to add
    /// `ChannelHandler`s to the `ChannelPipeline`.
    ///
    /// - parameters:
    ///     - initializer: A closure that initializes the provided `Channel`.
    public func childChannelInitializer(_ initializer: @escaping (Channel) -> EventLoopFuture<()>) -> Self {
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
    public func bind(to host: String, on port: Int32) -> EventLoopFuture<Channel> {
        let evGroup = group
        do {
            let address = try SocketAddress.newAddressResolving(host: host, port: port)
            return bind0(eventLoopGroup: evGroup, to: address)
        } catch let err {
            return evGroup.next().newFailedFuture(error: err)
        }
    }

    /// Bind the `ServerSocketChannel` to `address`.
    ///
    /// - parameters:
    ///     - address: The `SocketAddress` to bind on.
    public func bind(to address: SocketAddress) -> EventLoopFuture<Channel> {
        return bind0(eventLoopGroup: group, to: address)
    }

    /// Bind the `ServerSocketChannel` to a UNIX Domain Socket.
    ///
    /// - parameters:
    ///     - path: The path of the UNIX Domain Socket to bind on. `path` must not exist, it will be created by the system.
    public func bind(unixDomainSocket path: String) -> EventLoopFuture<Channel> {
        let evGroup = group
        do {
            let address = try SocketAddress.unixDomainSocketAddress(path: path)
            return bind0(eventLoopGroup: evGroup, to: address)
        } catch let err {
            return evGroup.next().newFailedFuture(error: err)
        }
    }

    private func bind0(eventLoopGroup: EventLoopGroup, to address: SocketAddress) -> EventLoopFuture<Channel> {
        let childEventLoopGroup = self.childGroup
        let serverChannelOptions = self.serverChannelOptions
        let eventLoop = eventLoopGroup.next()
        let serverChannelInit = self.serverChannelInit
        let childChannelInit = self.childChannelInit
        let childChannelOptions = self.childChannelOptions
        
        let promise: EventLoopPromise<Channel> = eventLoop.newPromise()
        do {
            let serverChannel = try ServerSocketChannel(eventLoop: eventLoop as! SelectableEventLoop,
                                                        group: childEventLoopGroup,
                                                        protocolFamily: address.protocolFamily)
            
            func finishServerSetup() {
                serverChannelOptions.applyAll(channel: serverChannel).then {
                    serverChannel.register()
                }.then {
                    serverChannel.bind(to: address)
                }.map {
                    serverChannel
                }.cascade(promise: promise)
            }

            func addAcceptHandlerAndFinishServerSetup() {
                let f = serverChannel.pipeline.add(handler: AcceptHandler(childChannelInitializer: childChannelInit,
                                                                          childChannelOptions: childChannelOptions))
                f.whenComplete { v in
                    switch v {
                    case .failure(let err):
                        promise.fail(error: err)
                    case .success(_):
                        finishServerSetup()
                    }
                }
            }

            if let serverChannelInit = serverChannelInit {
                serverChannelInit(serverChannel).whenComplete { v in
                    switch v {
                    case .failure(let err):
                        promise.fail(error: err)
                    case .success(_):
                        addAcceptHandlerAndFinishServerSetup()
                    }
                }
            } else {
                addAcceptHandlerAndFinishServerSetup()
            }
        } catch let err {
            promise.fail(error: err)
        }

        return promise.futureResult
    }
    
    private class AcceptHandler : ChannelInboundHandler {
        public typealias InboundIn = SocketChannel
        
        private let childChannelInit: ((Channel) -> EventLoopFuture<()>)?
        private let childChannelOptions: ChannelOptionStorage
        
        init(childChannelInitializer: ((Channel) -> EventLoopFuture<()>)?, childChannelOptions: ChannelOptionStorage) {
            self.childChannelInit = childChannelInitializer
            self.childChannelOptions = childChannelOptions
        }
        
        func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
            let accepted = self.unwrapInboundIn(data)
            let eventLoop = ctx.channel.eventLoop
            self.childChannelOptions.applyAll(channel: accepted).whenComplete { v in
                // We must return to the server channel.
                eventLoop.execute {
                    switch v {
                    case .failure(let err):
                        self.closeAndFire(ctx: ctx, accepted: accepted, err: err)
    
                    case .success(_):
                        if let childChannelInit = self.childChannelInit {
                            childChannelInit(accepted).whenComplete { v in
                                switch v {
                                case .failure(let err):
                                    self.closeAndFire(ctx: ctx, accepted: accepted, err: err)
                                case .success(_):
                                    if ctx.eventLoop.inEventLoop {
                                        ctx.fireChannelRead(data: data)
                                    } else {
                                        ctx.eventLoop.execute {
                                            ctx.fireChannelRead(data: data)
                                        }
                                    }
                                }
                            }
                        } else {
                            ctx.fireChannelRead(data: data)
                        }
                    }
               }
            }
        }
        
        private func closeAndFire(ctx: ChannelHandlerContext, accepted: SocketChannel, err: Error) {
            _ = accepted.close()
            if ctx.eventLoop.inEventLoop {
                ctx.fireErrorCaught(error: err)
            } else {
                ctx.eventLoop.execute {
                    ctx.fireErrorCaught(error: err)
                }
            }
        }
    }
}

/// A `ClientBootstrap` is an easy way to bootstrap a `SocketChannel` when creating network clients.
public final class ClientBootstrap {
    
    private let group: EventLoopGroup
    private var channelInitializer: ((Channel) -> EventLoopFuture<()>)?
    private var channelOptions = ChannelOptionStorage()
    private var connectTimeout: TimeAmount = TimeAmount.seconds(10)

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
    /// - parameters:
    ///     - handler: A closure that initializes the provided `Channel`.
    public func channelInitializer(_ handler: @escaping (Channel) -> EventLoopFuture<()>) -> Self {
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

    /// Specify the `host` and `port` to connect to for the TCP `Channel` that will be established.
    ///
    /// - parameters:
    ///     - host: The host to connect to.
    ///     - port: The port to connect to.
    /// - returns: An `EventLoopFuture<Channel>` to deliver the `Channel` when connected.
    public func connect(to host: String, on port: Int) -> EventLoopFuture<Channel> {
        let loop = self.group.next()
        let connector = HappyEyeballsConnector(resolver: GetaddrinfoResolver(loop: loop),
                                               loop: self.group.next(),
                                               host: host,
                                               port: port,
                                               connectTimeout: self.connectTimeout) { eventLoop, protocolFamily in
            return self.execute(eventLoop: eventLoop, protocolFamily: protocolFamily) { $0.eventLoop.newSucceedFuture(result: ()) }
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
                _ = channel.close()
            }

            connectPromise.futureResult.whenComplete { _ in cancelTask.cancel() }
            return connectPromise.futureResult
        }
    }

    /// Specify the `unixDomainSocket` path to connect to for the UDS `Channel` that will be established.
    ///
    /// - parameters:
    ///     - address: The address to connect to.
    /// - returns: An `EventLoopFuture<Channel>` to deliver the `Channel` when connected.
    public func connect(to unixDomainSocket: String) -> EventLoopFuture<Channel> {
        do {
            let address = try SocketAddress.unixDomainSocketAddress(path: unixDomainSocket)
            return connect(to: address)
        } catch {
            return group.next().newFailedFuture(error: error)
        }
    }

    private func execute(eventLoop: EventLoop,
                         protocolFamily: Int32,
                         _ body: @escaping (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel> {
        let channelInitializer = self.channelInitializer
        let channelOptions = self.channelOptions

        let promise: EventLoopPromise<Channel> = eventLoop.newPromise()
        do {
            let channel = try SocketChannel(eventLoop: eventLoop as! SelectableEventLoop, protocolFamily: protocolFamily)

            func finishClientSetup() {
                channelOptions.applyAll(channel: channel).then {
                    channel.register()
                }.then {
                    body(channel)
                }.map {
                    channel
                }.cascade(promise: promise)
            }

            if let channelInitializer = channelInitializer {
                channelInitializer(channel).whenComplete { v in
                    switch v {
                    case .failure(let err):
                        promise.fail(error: err)
                    case .success(_):
                        finishClientSetup()
                    }
                }
            } else {
                finishClientSetup()
            }
        } catch let err {
            promise.fail(error: err)
        }

        return promise.futureResult
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

            applier(channel)(key, value).whenComplete { v in
                switch v {
                case .failure(let err):
                    applyPromise.fail(error: err)
                case .success(_):
                    applyNext()
                }
            }
        }
        applyNext()

        return applyPromise.futureResult
    }
}
