//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOTestUtils

class UniversalBootstrapSupportTest: XCTestCase {

    func testBootstrappingWorks() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        final class DropChannelReadsHandler: ChannelInboundHandler {
            typealias InboundIn = Any

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                // drop
            }
        }

        final class DummyTLSProvider: NIOClientTLSProvider {
            typealias Bootstrap = ClientBootstrap

            final class DropInboundEventsHandler: ChannelInboundHandler {
                typealias InboundIn = Any

                func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
                    // drop
                }
            }

            func enableTLS(_ bootstrap: ClientBootstrap) -> ClientBootstrap {
                return bootstrap.protocolHandlers {
                    [DropInboundEventsHandler()]
                }
            }
        }

        final class FishOutChannelHandler: ChannelInboundHandler {
            typealias InboundIn = Channel

            var acceptedChannels: [Channel] = []

            let firstArrived: EventLoopPromise<Void>

            init(firstArrived: EventLoopPromise<Void>) {
                self.firstArrived = firstArrived
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let channel = self.unwrapInboundIn(data)
                self.acceptedChannels.append(channel)
                if self.acceptedChannels.count == 1 {
                    self.firstArrived.succeed(())
                }
                context.fireChannelRead(data)
            }
        }

        XCTAssertNoThrow(try withTCPServerChannel(group: group) { server in
            let firstArrived = group.next().makePromise(of: Void.self)
            let counter1 = EventCounterHandler()
            let counter2 = EventCounterHandler()
            let channelFisher = FishOutChannelHandler(firstArrived: firstArrived)
            XCTAssertNoThrow(try server.pipeline.addHandler(channelFisher).wait())

            let client = try NIOClientTCPBootstrap(ClientBootstrap(group: group), tls: DummyTLSProvider())
                .channelInitializer { channel in
                    channel.pipeline.addHandlers(counter1, DropChannelReadsHandler(), counter2)
                }
                .channelOption(ChannelOptions.autoRead, value: false)
                .connectTimeout(.hours(1))
                .enableTLS()
                .connect(to: server.localAddress!)
                .wait()
            defer {
                XCTAssertNoThrow(try client.close().wait())
            }

            var buffer = client.allocator.buffer(capacity: 16)
            buffer.writeString("hello")
            var maybeAcceptedChannel: Channel? = nil
            XCTAssertNoThrow(try firstArrived.futureResult.wait())
            XCTAssertNoThrow(maybeAcceptedChannel = try server.eventLoop.submit {
                XCTAssertEqual(1, channelFisher.acceptedChannels.count)
                return channelFisher.acceptedChannels.first
            }.wait())
            guard let acceptedChannel = maybeAcceptedChannel else {
                XCTFail("couldn't fish out the accepted channel")
                return
            }
            XCTAssertNoThrow(try acceptedChannel.writeAndFlush(buffer).wait())

            // auto-read is off, so we shouldn't see any reads/channelReads
            XCTAssertEqual(0, counter1.readCalls)
            XCTAssertEqual(0, counter2.readCalls)
            XCTAssertEqual(0, counter1.channelReadCalls)
            XCTAssertEqual(0, counter2.channelReadCalls)

            // let's do a read
            XCTAssertNoThrow(try client.eventLoop.submit {
                client.read()
            }.wait())
            XCTAssertEqual(1, counter1.readCalls)
            XCTAssertEqual(1, counter2.readCalls)

            // let's check that the order is right
            XCTAssertNoThrow(try client.eventLoop.submit {
                client.pipeline.fireChannelRead(NIOAny(buffer))
                client.pipeline.fireUserInboundEventTriggered(buffer)
            }.wait())

            // the protocol handler which was added by the "TLS" implementation should be first, it however drops
            // inbound events so we shouldn't see them
            XCTAssertEqual(0, counter1.userInboundEventTriggeredCalls)
            XCTAssertEqual(0, counter2.userInboundEventTriggeredCalls)

            // the channelReads so have gone through but only to counter1
            XCTAssertGreaterThanOrEqual(counter1.channelReadCalls, 1)
            XCTAssertEqual(0, counter2.channelReadCalls)
        })
    }
    
    func testBootstrapOverrideOfShortcutOptions() {
        final class FakeBootstrap : NIOClientTCPBootstrapProtocol {
            func channelInitializer(_ handler: @escaping (Channel) -> EventLoopFuture<Void>) -> Self {
                fatalError("Not implemented")
            }
            
            func protocolHandlers(_ handlers: @escaping () -> [ChannelHandler]) -> Self {
                fatalError("Not implemented")
            }
            
            var regularOptionsSeen = false
            func channelOption<Option>(_ option: Option, value: Option.Value) -> Self where Option : ChannelOption {
                regularOptionsSeen = true
                return self
            }
            
            var convenienceOptionConsumed = false
            func _applyChannelConvenienceOptions(_ options: inout ChannelOptions.TCPConvenienceOptions) -> FakeBootstrap {
                if options.consumeAllowLocalEndpointReuse().isSet {
                    convenienceOptionConsumed = true
                }
                return self
            }
            
            func connectTimeout(_ timeout: TimeAmount) -> Self {
                fatalError("Not implemented")
            }
            
            func connect(host: String, port: Int) -> EventLoopFuture<Channel> {
                fatalError("Not implemented")
            }
            
            func connect(to address: SocketAddress) -> EventLoopFuture<Channel> {
                fatalError("Not implemented")
            }
            
            func connect(unixDomainSocketPath: String) -> EventLoopFuture<Channel> {
                fatalError("Not implemented")
            }
        }
        
        // Check consumption works.
        let consumingFake = FakeBootstrap()
        _ = NIOClientTCPBootstrap(consumingFake, tls: NIOInsecureNoTLS())
            .channelConvenienceOptions([.allowLocalEndpointReuse])
        XCTAssertTrue(consumingFake.convenienceOptionConsumed)
        XCTAssertFalse(consumingFake.regularOptionsSeen)
        
        // Check default behaviour works.
        let nonConsumingFake = FakeBootstrap()
        _ = NIOClientTCPBootstrap(nonConsumingFake, tls: NIOInsecureNoTLS())
            .channelConvenienceOptions([.allowRemoteHalfClosure])
        XCTAssertFalse(nonConsumingFake.convenienceOptionConsumed)
        XCTAssertTrue(nonConsumingFake.regularOptionsSeen)
        
        // Both at once.
        let bothFake = FakeBootstrap()
        _ = NIOClientTCPBootstrap(bothFake, tls: NIOInsecureNoTLS())
            .channelConvenienceOptions([.allowRemoteHalfClosure, .allowLocalEndpointReuse])
        XCTAssertTrue(bothFake.convenienceOptionConsumed)
        XCTAssertTrue(bothFake.regularOptionsSeen)
    }
}

// Prove we've not broken implementors of NIOClientTCPBootstrapProtocol by adding a new method.
private class UniversalWithoutNewMethods : NIOClientTCPBootstrapProtocol {
    func channelInitializer(_ handler: @escaping (Channel) -> EventLoopFuture<Void>) -> Self {
        return self
    }
    
    func protocolHandlers(_ handlers: @escaping () -> [ChannelHandler]) -> Self {
        return self
    }
    
    func channelOption<Option>(_ option: Option, value: Option.Value) -> Self where Option : ChannelOption {
        return self
    }
    
    func connectTimeout(_ timeout: TimeAmount) -> Self {
        return self
    }
    
    func connect(host: String, port: Int) -> EventLoopFuture<Channel> {
        return EmbeddedEventLoop().makePromise(of: Channel.self).futureResult
    }
    
    func connect(to address: SocketAddress) -> EventLoopFuture<Channel> {
        return EmbeddedEventLoop().makePromise(of: Channel.self).futureResult
    }
    
    func connect(unixDomainSocketPath: String) -> EventLoopFuture<Channel> {
        return EmbeddedEventLoop().makePromise(of: Channel.self).futureResult
    }
}
