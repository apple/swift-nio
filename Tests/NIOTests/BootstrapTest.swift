//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import NIO
import NIOConcurrencyHelpers
import XCTest

class BootstrapTest: XCTestCase {
    var group: MultiThreadedEventLoopGroup!
    var groupBag: [MultiThreadedEventLoopGroup]? = nil // protected by `self.lock`
    let lock = Lock()

    override func setUp() {
        XCTAssertNil(self.group)
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.lock.withLock {
            XCTAssertNil(self.groupBag)
            self.groupBag = []
        }
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.lock.withLock {
            guard let groupBag = self.groupBag else {
                XCTFail()
                return
            }
            XCTAssertNoThrow(try groupBag.forEach {
                XCTAssertNoThrow(try $0.syncShutdownGracefully())
            })
            self.groupBag = nil
            XCTAssertNotNil(self.group)
        })
        XCTAssertNoThrow(try self.group?.syncShutdownGracefully())
        self.group = nil
    }

    func freshEventLoop() -> EventLoop {
        let group: MultiThreadedEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.lock.withLock {
            self.groupBag!.append(group)
        }
        return group.next()
    }

    func testBootstrapsCallInitializersOnCorrectEventLoop() throws {
        for numThreads in [1 /* everything on one event loop */,
                           2 /* some stuff has shared event loops */,
                           5 /* everything on a different event loop */] {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: numThreads)
            defer {
                XCTAssertNoThrow(try group.syncShutdownGracefully())
            }

            let childChannelDone = group.next().makePromise(of: Void.self)
            let serverChannelDone = group.next().makePromise(of: Void.self)
            let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    XCTAssert(channel.eventLoop.inEventLoop)
                    childChannelDone.succeed(())
                    return channel.eventLoop.makeSucceededFuture(())
                }
                .serverChannelInitializer { channel in
                    XCTAssert(channel.eventLoop.inEventLoop)
                    serverChannelDone.succeed(())
                    return channel.eventLoop.makeSucceededFuture(())
                }
                .bind(host: "localhost", port: 0)
                .wait())
            defer {
                XCTAssertNoThrow(try serverChannel.close().wait())
            }

            let client = try assertNoThrowWithValue(ClientBootstrap(group: group)
                .channelInitializer { channel in
                    XCTAssert(channel.eventLoop.inEventLoop)
                    return channel.eventLoop.makeSucceededFuture(())
                }
                .connect(to: serverChannel.localAddress!)
                .wait(), message: "resolver debug info: \(try! resolverDebugInformation(eventLoop: group.next(),host: "localhost", previouslyReceivedResult: serverChannel.localAddress!))")
            defer {
                XCTAssertNoThrow(try client.syncCloseAcceptingAlreadyClosed())
            }
            XCTAssertNoThrow(try childChannelDone.futureResult.wait())
            XCTAssertNoThrow(try serverChannelDone.futureResult.wait())
        }
    }

    func testTCPBootstrapsTolerateFuturesFromDifferentEventLoopsReturnedInInitializers() throws {
        let childChannelDone = self.freshEventLoop().makePromise(of: Void.self)
        let serverChannelDone = self.freshEventLoop().makePromise(of: Void.self)
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: self.freshEventLoop())
            .childChannelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                defer {
                    childChannelDone.succeed(())
                }
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .serverChannelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                defer {
                    serverChannelDone.succeed(())
                }
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait())
        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let client = try assertNoThrowWithValue(ClientBootstrap(group: self.freshEventLoop())
            .channelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .connect(to: serverChannel.localAddress!)
            .wait())
        defer {
            XCTAssertNoThrow(try client.syncCloseAcceptingAlreadyClosed())
        }
        XCTAssertNoThrow(try childChannelDone.futureResult.wait())
        XCTAssertNoThrow(try serverChannelDone.futureResult.wait())
    }

    func testUDPBootstrapToleratesFuturesFromDifferentEventLoopsReturnedInInitializers() throws {
        XCTAssertNoThrow(try DatagramBootstrap(group: self.freshEventLoop())
            .channelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
            .close()
            .wait())
    }

    func testPreConnectedClientSocketToleratesFuturesFromDifferentEventLoopsReturnedInInitializers() throws {
        var socketFDs: [CInt] = [-1, -1]
        XCTAssertNoThrow(try Posix.socketpair(domain: .local,
                                              type: .stream,
                                              protocol: 0,
                                              socketVector: &socketFDs))
        defer {
            // 0 is closed together with the Channel below.
            XCTAssertNoThrow(try Posix.close(descriptor: socketFDs[1]))
        }

        XCTAssertNoThrow(try ClientBootstrap(group: self.freshEventLoop())
            .channelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .withConnectedSocket(descriptor: socketFDs[0])
            .wait()
            .close()
            .wait())
    }

    func testPreConnectedServerSocketToleratesFuturesFromDifferentEventLoopsReturnedInInitializers() throws {
        let socket = try Posix.socket(domain: .inet, type: .stream, protocol: 0)

        let serverAddress = try assertNoThrowWithValue(SocketAddress.makeAddressResolvingHost("127.0.0.1", port: 0))
        try serverAddress.withSockAddr { serverAddressPtr, size in
            try Posix.bind(descriptor: socket, ptr: serverAddressPtr,
                           bytes: size)
        }

        let childChannelDone = self.freshEventLoop().next().makePromise(of: Void.self)
        let serverChannelDone = self.freshEventLoop().next().makePromise(of: Void.self)

        let serverChannel = try assertNoThrowWithValue(try ServerBootstrap(group: self.freshEventLoop())
            .childChannelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                defer {
                    childChannelDone.succeed(())
                }
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .serverChannelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                defer {
                    serverChannelDone.succeed(())
                }
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .withBoundSocket(descriptor: socket)
            .wait())
        let client = try assertNoThrowWithValue(ClientBootstrap(group: self.freshEventLoop())
            .channelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .connect(to: serverChannel.localAddress!)
            .wait())
        defer {
            XCTAssertNoThrow(try client.syncCloseAcceptingAlreadyClosed())
        }
        XCTAssertNoThrow(try childChannelDone.futureResult.wait())
        XCTAssertNoThrow(try serverChannelDone.futureResult.wait())
    }

    func testTCPClientBootstrapAllowsConformanceCorrectly() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        func restrictBootstrapType(clientBootstrap: NIOClientTCPBootstrap) throws {
            let serverAcceptedChannelPromise = group.next().makePromise(of: Channel.self)
            let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
                .serverOptions([.allowImmediateLocalEndpointAddressReuse])
                .childChannelInitializer { channel in
                    serverAcceptedChannelPromise.succeed(channel)
                    return channel.eventLoop.makeSucceededFuture(())
            }.bind(host: "127.0.0.1", port: 0).wait())

            let clientChannel = try assertNoThrowWithValue(clientBootstrap
                .channelInitializer({ (channel: Channel) in channel.eventLoop.makeSucceededFuture(()) })
                .connect(host: "127.0.0.1", port: serverChannel.localAddress!.port!).wait())

            var buffer = clientChannel.allocator.buffer(capacity: 1)
            buffer.writeString("a")
            try clientChannel.writeAndFlush(NIOAny(buffer)).wait()

            let serverAcceptedChannel = try serverAcceptedChannelPromise.futureResult.wait()

            // Start shutting stuff down.
            XCTAssertNoThrow(try clientChannel.close().wait())

            // Wait for the close promises. These fire last.
            XCTAssertNoThrow(try EventLoopFuture.andAllSucceed([clientChannel.closeFuture,
                                                                serverAcceptedChannel.closeFuture],
                                                                on: group.next()).wait())
        }

        let bootstrap = NIOClientTCPBootstrap(ClientBootstrap(group: group), tls: NIOInsecureNoTLS())
        try restrictBootstrapType(clientBootstrap: bootstrap)
    }
    
    func testServerBootstrapBindTimeout() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        // Set a bindTimeout and call bind. Setting a bind timeout is currently unsupported
        // by ServerBootstrap. We therefore expect the bind timeout to be ignored and bind to
        // succeed, even with a minimal bind timeout.
        let bootstrap = ServerBootstrap(group: group)
            .bindTimeout(.nanoseconds(0))

        let channel = try assertNoThrowWithValue(bootstrap.bind(host: "127.0.0.1", port: 0).wait())
        XCTAssertNoThrow(try channel.close().wait())
    }

    func testServerBootstrapSetsChannelOptionsBeforeChannelInitializer() {
        var channel: Channel? = nil
        XCTAssertNoThrow(channel = try ServerBootstrap(group: self.group)
            .serverOptions([.disableAutoRead])
            .serverChannelInitializer { channel in
                channel.getOption(ChannelOptions.autoRead).whenComplete { result in
                    func workaround() {
                        XCTAssertNoThrow(XCTAssertFalse(try result.get()))
                    }
                    workaround()
                }
                return channel.pipeline.addHandler(MakeSureAutoReadIsOffInChannelInitializer())
        }
        .bind(to: .init(ipAddress: "127.0.0.1", port: 0))
        .wait())
        XCTAssertNotNil(channel)
        XCTAssertNoThrow(try channel?.close().wait())
    }

    func testClientBootstrapSetsChannelOptionsBeforeChannelInitializer() {
        XCTAssertNoThrow(try withTCPServerChannel(group: self.group) { server in
            var channel: Channel? = nil
            XCTAssertNoThrow(channel = try ClientBootstrap(group: self.group)
                .channelOption(ChannelOptions.autoRead, value: false)
                .channelInitializer { channel in
                    channel.getOption(ChannelOptions.autoRead).whenComplete { result in
                        func workaround() {
                            XCTAssertNoThrow(XCTAssertFalse(try result.get()))
                        }
                        workaround()
                    }
                    return channel.pipeline.addHandler(MakeSureAutoReadIsOffInChannelInitializer())
            }
            .connect(to: server.localAddress!)
            .wait())
            XCTAssertNotNil(channel)
            XCTAssertNoThrow(try channel?.close().wait())
        })
    }

    func testPreConnectedSocketSetsChannelOptionsBeforeChannelInitializer() {
        XCTAssertNoThrow(try withTCPServerChannel(group: self.group) { server in
            var maybeSocket: Socket? = nil
            XCTAssertNoThrow(maybeSocket = try Socket(protocolFamily: .inet, type: .stream))
            XCTAssertNoThrow(XCTAssertEqual(true, try maybeSocket?.connect(to: server.localAddress!)))
            var maybeFD: CInt? = nil
            XCTAssertNoThrow(maybeFD = try maybeSocket?.takeDescriptorOwnership())
            guard let fd = maybeFD else {
                XCTFail("could not get a socket fd")
                return
            }

            var channel: Channel? = nil
            XCTAssertNoThrow(channel = try ClientBootstrap(group: self.group)
                .channelOption(ChannelOptions.autoRead, value: false)
                .channelInitializer { channel in
                    channel.getOption(ChannelOptions.autoRead).whenComplete { result in
                        func workaround() {
                            XCTAssertNoThrow(XCTAssertFalse(try result.get()))
                        }
                        workaround()
                    }
                    return channel.pipeline.addHandler(MakeSureAutoReadIsOffInChannelInitializer())
            }
            .withConnectedSocket(descriptor: fd)
            .wait())
            XCTAssertNotNil(channel)
            XCTAssertNoThrow(try channel?.close().wait())
        })
    }

    func testDatagramBootstrapSetsChannelOptionsBeforeChannelInitializer() {
        var channel: Channel? = nil
        XCTAssertNoThrow(channel = try DatagramBootstrap(group: self.group)
            .channelOptions([.disableAutoRead])
            .channelInitializer { channel in
                channel.getOption(ChannelOptions.autoRead).whenComplete { result in
                    func workaround() {
                        XCTAssertNoThrow(XCTAssertFalse(try result.get()))
                    }
                    workaround()
                }
                return channel.pipeline.addHandler(MakeSureAutoReadIsOffInChannelInitializer())
        }
        .bind(to: .init(ipAddress: "127.0.0.1", port: 0))
        .wait())
        XCTAssertNotNil(channel)
        XCTAssertNoThrow(try channel?.close().wait())
    }

    func testPipeBootstrapSetsChannelOptionsBeforeChannelInitializer() {
        XCTAssertNoThrow(try withPipe { inPipe, outPipe in
            var maybeInFD: CInt? = nil
            var maybeOutFD: CInt? = nil
            XCTAssertNoThrow(maybeInFD = try inPipe.takeDescriptorOwnership())
            XCTAssertNoThrow(maybeOutFD = try outPipe.takeDescriptorOwnership())
            guard let inFD = maybeInFD, let outFD = maybeOutFD else {
                XCTFail("couldn't get pipe fds")
                return [inPipe, outPipe]
            }
            var channel: Channel? = nil
            XCTAssertNoThrow(channel = try NIOPipeBootstrap(group: self.group)
                .channelOptions([.disableAutoRead])
                .channelInitializer { channel in
                    channel.getOption(ChannelOptions.autoRead).whenComplete { result in
                        func workaround() {
                            XCTAssertNoThrow(XCTAssertFalse(try result.get()))
                        }
                        workaround()
                    }
                    return channel.pipeline.addHandler(MakeSureAutoReadIsOffInChannelInitializer())
            }
            .withPipes(inputDescriptor: inFD, outputDescriptor: outFD)
            .wait())
            XCTAssertNotNil(channel)
            XCTAssertNoThrow(try channel?.close().wait())
            return []
        })
    }

    func testServerBootstrapAddsAcceptHandlerAfterServerChannelInitialiser() {
        // It's unclear if this is the right solution, see https://github.com/apple/swift-nio/issues/1392
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        struct FoundHandlerThatWasNotSupposedToBeThereError: Error {}

        var maybeServer: Channel? = nil
        XCTAssertNoThrow(maybeServer = try ServerBootstrap(group: group)
            .serverChannelInitializer { channel in
                // Here, we test that we can't find the AcceptHandler
                return channel.pipeline.context(name: "AcceptHandler").flatMap { context -> EventLoopFuture<Void> in
                    XCTFail("unexpectedly found \(context)")
                    return channel.eventLoop.makeFailedFuture(FoundHandlerThatWasNotSupposedToBeThereError())
                }.flatMapError { error -> EventLoopFuture<Void> in
                    XCTAssertEqual(.notFound, error as? ChannelPipelineError)
                    if case .some(.notFound) = error as? ChannelPipelineError {
                        return channel.eventLoop.makeSucceededFuture(())
                    }
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait())

        guard let server = maybeServer else {
            XCTFail("couldn't bootstrap server")
            return
        }

        // But now, it should be there.
        XCTAssertNoThrow(_ = try server.pipeline.context(name: "AcceptHandler").wait())
        XCTAssertNoThrow(try server.close().wait())
    }

    func testClientBootstrapValidatesWorkingELGsCorrectly() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }
        let el = elg.next()

        XCTAssertNotNil(ClientBootstrap(validatingGroup: elg))
        XCTAssertNotNil(ClientBootstrap(validatingGroup: el))
    }

    func testClientBootstrapRejectsNotWorkingELGsCorrectly() {
        let elg = EmbeddedEventLoop()
        defer {
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }
        let el = elg.next()

        XCTAssertNil(ClientBootstrap(validatingGroup: elg))
        XCTAssertNil(ClientBootstrap(validatingGroup: el))
    }

    func testServerBootstrapValidatesWorkingELGsCorrectly() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }
        let el = elg.next()

        XCTAssertNotNil(ServerBootstrap(validatingGroup: elg))
        XCTAssertNotNil(ServerBootstrap(validatingGroup: el))
        XCTAssertNotNil(ServerBootstrap(validatingGroup: elg, childGroup: elg))
        XCTAssertNotNil(ServerBootstrap(validatingGroup: el, childGroup: el))
    }

    func testServerBootstrapRejectsNotWorkingELGsCorrectly() {
        let correctELG = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try correctELG.syncShutdownGracefully())
        }

        let wrongELG = EmbeddedEventLoop()
        defer {
            XCTAssertNoThrow(try wrongELG.syncShutdownGracefully())
        }
        let wrongEL = wrongELG.next()
        let correctEL = correctELG.next()

        // both wrong
        XCTAssertNil(ServerBootstrap(validatingGroup: wrongELG))
        XCTAssertNil(ServerBootstrap(validatingGroup: wrongEL))
        XCTAssertNil(ServerBootstrap(validatingGroup: wrongELG, childGroup: wrongELG))
        XCTAssertNil(ServerBootstrap(validatingGroup: wrongEL, childGroup: wrongEL))

        // group correct, child group wrong
        XCTAssertNil(ServerBootstrap(validatingGroup: correctELG, childGroup: wrongELG))
        XCTAssertNil(ServerBootstrap(validatingGroup: correctEL, childGroup: wrongEL))

        // group wrong, child group correct
        XCTAssertNil(ServerBootstrap(validatingGroup: wrongELG, childGroup: correctELG))
        XCTAssertNil(ServerBootstrap(validatingGroup: wrongEL, childGroup: correctEL))
    }

    func testDatagramBootstrapValidatesWorkingELGsCorrectly() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }
        let el = elg.next()

        XCTAssertNotNil(DatagramBootstrap(validatingGroup: elg))
        XCTAssertNotNil(DatagramBootstrap(validatingGroup: el))
    }

    func testDatagramBootstrapRejectsNotWorkingELGsCorrectly() {
        let elg = EmbeddedEventLoop()
        defer {
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }
        let el = elg.next()

        XCTAssertNil(DatagramBootstrap(validatingGroup: elg))
        XCTAssertNil(DatagramBootstrap(validatingGroup: el))
    }

    func testNIOPipeBootstrapValidatesWorkingELGsCorrectly() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }
        let el = elg.next()

        XCTAssertNotNil(NIOPipeBootstrap(validatingGroup: elg))
        XCTAssertNotNil(NIOPipeBootstrap(validatingGroup: el))
    }

    func testNIOPipeBootstrapRejectsNotWorkingELGsCorrectly() {
        let elg = EmbeddedEventLoop()
        defer {
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }
        let el = elg.next()

        XCTAssertNil(NIOPipeBootstrap(validatingGroup: elg))
        XCTAssertNil(NIOPipeBootstrap(validatingGroup: el))
    }
    
    func testShorthandServerOptionsAreEquivalent() throws {
        func bindAndGetOption<Option>(option: Option, _ applyBootstrapOptions: (ServerBootstrap) -> ServerBootstrap) throws ->
                Option.Value
                where Option : ChannelOption {
            let bootstrap = applyBootstrapOptions(ServerBootstrap(group: group))
            let serverChannel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
            let optionValue = try serverChannel.getOption(option).wait()
            try serverChannel.close().wait()
            return optionValue
        }
        
        func checkOptionEquivalence<Option>(longOption: Option, setValue: Option.Value,
                                            shortOption: NIOTCPServerShorthandOption) throws
            where Option : ChannelOption, Option.Value : Equatable {
            let longSetValue = try bindAndGetOption(option: longOption) { bs in
                bs.serverChannelOption(longOption, value: setValue)
            }
            let shortSetValue = try bindAndGetOption(option: longOption) { bs in
                bs.serverOptions([shortOption])
            }
            let unsetValue = try bindAndGetOption(option: longOption) { $0 }
            
            XCTAssertEqual(longSetValue, shortSetValue)
            XCTAssertNotEqual(longSetValue, unsetValue)
        }
        
        try checkOptionEquivalence(longOption: ChannelOptions.socketOption(.reuseaddr),
                                   setValue: 1,
                                   shortOption: .allowImmediateLocalEndpointAddressReuse)
        #if !os(Windows)
            // Check the oldest way of all.
            // .socket(.init(SOL_SOCKET), .init(SO_REUSEADDR), value: 1)
            try checkOptionEquivalence(longOption: ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)),
                                       setValue: 1,
                                       shortOption: .allowImmediateLocalEndpointAddressReuse)
        #endif
        try checkOptionEquivalence(longOption: ChannelOptions.autoRead,
                                   setValue: false,
                                   shortOption: .disableAutoRead)
        try checkOptionEquivalence(longOption: ChannelOptions.backlog,
                                   setValue: 4,
                                   shortOption: .maximumUnacceptedConnectionBacklog(4))
    }
    
    private final class CloseHandler: ChannelInboundHandler {
        typealias InboundIn = NIOAny

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            // Shutdown a half closed channel.
            if let channelEvent = event as? ChannelEvent {
                if channelEvent == .inputClosed {
                    _ = context.channel.close()
                }
            }
        }
    }
    
    func testShorthandOptionsAreEquivalentServerChild() throws {
        func setAndGetOption<Option>(option: Option, _ applyOptions : (ServerBootstrap) -> ServerBootstrap) throws -> Option.Value where Option : ChannelOption {
                var optionRead : EventLoopFuture<Option.Value>?
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                defer {
                    XCTAssertNoThrow(try group.syncShutdownGracefully())
                }

                let clientBootstrap = ClientBootstrap(group: group)
                let serverAcceptedChannelPromise = group.next().makePromise(of: Channel.self)
                let serverChannel = try assertNoThrowWithValue(applyOptions(ServerBootstrap(group: group))
                    .serverOptions([.allowImmediateLocalEndpointAddressReuse])
                    .childChannelInitializer { channel in
                        optionRead = channel.getOption(option)
                        serverAcceptedChannelPromise.succeed(channel)
                        return channel.pipeline.addHandler(CloseHandler())
                    }.bind(host: "127.0.0.1", port: 0).wait())

                let clientChannel = try assertNoThrowWithValue(clientBootstrap
                    .channelInitializer({ (channel: Channel) in channel.eventLoop.makeSucceededFuture(()) })
                    .connect(host: "127.0.0.1", port: serverChannel.localAddress!.port!).wait())

                let serverAcceptedChannel = try serverAcceptedChannelPromise.futureResult.wait()

                // Start shutting stuff down.
                XCTAssertNoThrow(try serverAcceptedChannel.close().wait())

                // Wait for the close promises. These fire last.
                XCTAssertNoThrow(try EventLoopFuture.andAllSucceed([clientChannel.closeFuture,
                                                                    serverAcceptedChannel.closeFuture],
                                                                    on: group.next()).wait())
            XCTAssertNotNil(optionRead)
            return try optionRead!.wait()

        }
        
        func checkOptionEquivalence<Option>(longOption: Option, setValue: Option.Value,
                                            shortOption: NIOTCPShorthandOption) throws
            where Option : ChannelOption, Option.Value : Equatable {
            
            let longSetValue = try setAndGetOption(option: longOption) { bs in
                bs.childChannelOption(longOption, value: setValue)
            }
            let shortSetValue = try setAndGetOption(option: longOption) { bs in
                bs.childChannelOptions([shortOption])
            }
            let unsetValue = try setAndGetOption(option: longOption) { $0 }
            
            XCTAssertEqual(longSetValue, shortSetValue)
            XCTAssertNotEqual(longSetValue, unsetValue)
        }
        
        // allowImmediateLocalEndpointAddressReuse not checked as problematic to test -
        // At least on Darwin the default for child is to have allow reuse set - probably inherited from listen
        try checkOptionEquivalence(longOption: ChannelOptions.allowRemoteHalfClosure,
                                   setValue: true,
                                   shortOption: .allowRemoteHalfClosure)
        try checkOptionEquivalence(longOption: ChannelOptions.autoRead,
                                   setValue: false,
                                   shortOption: .disableAutoRead)
    }
    
    func testShorthandOptionsAreEquivalentClient() throws {
        func setAndGetOption<Option>(option: Option, _ applyOptions : (ClientBootstrap) -> ClientBootstrap) throws
            -> Option.Value where Option : ChannelOption {
            var optionRead : EventLoopFuture<Option.Value>?
            XCTAssertNoThrow(try withTCPServerChannel(group: self.group) { server in
                var channel: Channel? = nil
                XCTAssertNoThrow(channel = try applyOptions(ClientBootstrap(group: self.group))
                    .channelInitializer { channel in optionRead = channel.getOption(option)
                        return channel.eventLoop.makeSucceededFuture(())
                    }
                .connect(to: server.localAddress!)
                .wait())
                XCTAssertNotNil(optionRead)
                XCTAssertNotNil(channel)
                XCTAssertNoThrow(try channel?.close().wait())
            })
            return try optionRead!.wait()
        }
        
        func checkOptionEquivalence<Option>(longOption: Option, setValue: Option.Value,
                                            shortOption: NIOTCPShorthandOption) throws
            where Option : ChannelOption, Option.Value : Equatable {
            let longSetValue = try setAndGetOption(option: longOption) { bs in
                bs.channelOption(longOption, value: setValue)
            }
            let shortSetValue = try setAndGetOption(option: longOption) { bs in
                bs.channelOptions([shortOption])
            }
            let unsetValue = try setAndGetOption(option: longOption) { $0 }
            
            XCTAssertEqual(longSetValue, shortSetValue)
            XCTAssertNotEqual(longSetValue, unsetValue)
        }
        
        try checkOptionEquivalence(longOption: ChannelOptions.socketOption(.reuseaddr),
                                   setValue: 1,
                                   shortOption: .allowImmediateLocalEndpointAddressReuse)
        try checkOptionEquivalence(longOption: ChannelOptions.allowRemoteHalfClosure,
                                   setValue: true,
                                   shortOption: .allowRemoteHalfClosure)
        try checkOptionEquivalence(longOption: ChannelOptions.autoRead,
                                   setValue: false,
                                   shortOption: .disableAutoRead)
    }
    
    func testShorthandOptionsAreEquivalentUniversalClient() throws {
        func setAndGetOption<Option>(option: Option, _ applyOptions : (NIOClientTCPBootstrap) -> NIOClientTCPBootstrap) throws
            -> Option.Value where Option : ChannelOption {
            var optionRead : EventLoopFuture<Option.Value>?
            XCTAssertNoThrow(try withTCPServerChannel(group: self.group) { server in
                var channel: Channel? = nil
                XCTAssertNoThrow(channel = try applyOptions(NIOClientTCPBootstrap(
                    ClientBootstrap(group: self.group), tls: NIOInsecureNoTLS()))
                    .channelInitializer { channel in optionRead = channel.getOption(option)
                        return channel.eventLoop.makeSucceededFuture(())
                    }
                .connect(to: server.localAddress!)
                .wait())
                XCTAssertNotNil(optionRead)
                XCTAssertNotNil(channel)
                XCTAssertNoThrow(try channel?.close().wait())
            })
            return try optionRead!.wait()
        }
        
        func checkOptionEquivalence<Option>(longOption: Option, setValue: Option.Value,
                                            shortOption: NIOTCPShorthandOption) throws
            where Option : ChannelOption, Option.Value : Equatable {
            let longSetValue = try setAndGetOption(option: longOption) { bs in
                bs.channelOption(longOption, value: setValue)
            }
            let shortSetValue = try setAndGetOption(option: longOption) { bs in
                bs.channelOptions([shortOption])
            }
            let unsetValue = try setAndGetOption(option: longOption) { $0 }
            
            XCTAssertEqual(longSetValue, shortSetValue)
            XCTAssertNotEqual(longSetValue, unsetValue)
        }
        
        try checkOptionEquivalence(longOption: ChannelOptions.socketOption(.reuseaddr),
                                   setValue: 1,
                                   shortOption: .allowImmediateLocalEndpointAddressReuse)
        try checkOptionEquivalence(longOption: ChannelOptions.allowRemoteHalfClosure,
                                   setValue: true,
                                   shortOption: .allowRemoteHalfClosure)
        try checkOptionEquivalence(longOption: ChannelOptions.autoRead,
                                   setValue: false,
                                   shortOption: .disableAutoRead)
    }

    func testShorthandOptionsAreEquivalentDatagram() throws {
        func setAndGetOption<Option>(option: Option, _ applyOptions : (DatagramBootstrap) -> DatagramBootstrap) throws
            -> Option.Value where Option : ChannelOption {
            var optionRead : EventLoopFuture<Option.Value>?
            var channel: Channel? = nil
            XCTAssertNoThrow(channel = try applyOptions(DatagramBootstrap(group: self.group))
                .channelInitializer { channel in optionRead = channel.getOption(option)
                    return channel.eventLoop.makeSucceededFuture(())
                }
                .bind(to: .init(ipAddress: "127.0.0.1", port: 0))
                .wait())
            XCTAssertNotNil(optionRead)
            XCTAssertNotNil(channel)
            XCTAssertNoThrow(try channel?.close().wait())
            return try optionRead!.wait()
        }
        
        func checkOptionEquivalence<Option>(longOption: Option, setValue: Option.Value,
                                            shortOption: NIOUDPShorthandOption) throws
            where Option : ChannelOption, Option.Value : Equatable {
            let longSetValue = try setAndGetOption(option: longOption) { bs in
                bs.channelOption(longOption, value: setValue)
            }
            let shortSetValue = try setAndGetOption(option: longOption) { bs in
                bs.channelOptions([shortOption])
            }
            let unsetValue = try setAndGetOption(option: longOption) { $0 }
            
            XCTAssertEqual(longSetValue, shortSetValue)
            XCTAssertNotEqual(longSetValue, unsetValue)
        }
        
        try checkOptionEquivalence(longOption: ChannelOptions.socketOption(.reuseaddr),
                                   setValue: 1,
                                   shortOption: .allowImmediateLocalEndpointAddressReuse)
        try checkOptionEquivalence(longOption: ChannelOptions.autoRead,
                                   setValue: false,
                                   shortOption: .disableAutoRead)
    }
    
    func testShorthandOptionsAreEquivalentPipe() throws {
        func setAndGetOption<Option>(option: Option, _ applyOptions : (NIOPipeBootstrap) -> NIOPipeBootstrap) throws -> Option.Value
            where Option : ChannelOption {
                var optionRead : EventLoopFuture<Option.Value>?
                XCTAssertNoThrow(try withPipe { inPipe, outPipe in
                   var maybeInFD: CInt? = nil
                   var maybeOutFD: CInt? = nil
                   XCTAssertNoThrow(maybeInFD = try inPipe.takeDescriptorOwnership())
                   XCTAssertNoThrow(maybeOutFD = try outPipe.takeDescriptorOwnership())
                   guard let inFD = maybeInFD, let outFD = maybeOutFD else {
                       XCTFail("couldn't get pipe fds")
                       return [inPipe, outPipe]
                   }
                   var channel: Channel? = nil
                   XCTAssertNoThrow(channel = try applyOptions(NIOPipeBootstrap(group: self.group))
                       .channelInitializer { channel in optionRead = channel.getOption(option)
                        return channel.eventLoop.makeSucceededFuture(())
                   }
                   .withPipes(inputDescriptor: inFD, outputDescriptor: outFD)
                   .wait())
                    XCTAssertNotNil(optionRead)
                    XCTAssertNotNil(channel)
                    XCTAssertNoThrow(try channel?.close().wait())
                    return []
                })
                return try optionRead!.wait()
        }
        
        func checkOptionEquivalence<Option>(longOption: Option, setValue: Option.Value,
                                            shortOption: NIOPipeShorthandOption) throws
            where Option : ChannelOption, Option.Value : Equatable {
            let longSetValue = try setAndGetOption(option: longOption) { bs in
                bs.channelOption(longOption, value: setValue)
            }
            let shortSetValue = try setAndGetOption(option: longOption) { bs in
                bs.channelOptions([shortOption])
            }
            let unsetValue = try setAndGetOption(option: longOption) { $0 }
            
            XCTAssertEqual(longSetValue, shortSetValue)
            XCTAssertNotEqual(longSetValue, unsetValue)
        }
        
        try checkOptionEquivalence(longOption: ChannelOptions.allowRemoteHalfClosure,
                                   setValue: true,
                                   shortOption: .allowRemoteHalfClosure)
        try checkOptionEquivalence(longOption: ChannelOptions.autoRead,
                                   setValue: false,
                                   shortOption: .disableAutoRead)
    }
}

private final class MakeSureAutoReadIsOffInChannelInitializer:  ChannelInboundHandler {
    typealias InboundIn = Channel

    func channelActive(context: ChannelHandlerContext) {
        context.channel.getOption(ChannelOptions.autoRead).whenComplete { result in
            func workaround() {
                XCTAssertNoThrow(XCTAssertFalse(try result.get()))
            }
            workaround()
        }
    }
}
