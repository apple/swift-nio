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

import NIO
import XCTest


final class PromiseOnReadHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let promise: EventLoopPromise<InboundIn>

    init(promise: EventLoopPromise<InboundIn>) {
        self.promise = promise
    }

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        self.promise.succeed(result: self.unwrapInboundIn(data))
        _ = ctx.pipeline.remove(ctx: ctx)
    }
}


final class MulticastTest: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        try? self.group.syncShutdownGracefully()
    }

    struct NoSuchInterfaceError: Error { }

    struct MulticastInterfaceMismatchError: Error { }

    struct ReceivedDatagramError: Error { }

    private var supportsIPv6: Bool {
        do {
            let ipv6Loopback = try SocketAddress(ipAddress: "::1", port: 0)
            return try System.enumerateInterfaces().filter { $0.address == ipv6Loopback }.first != nil
        } catch {
            return false
        }
    }

    private func interfaceForAddress(address: String) throws -> NIONetworkInterface {
        let targetAddress = try SocketAddress(ipAddress: address, port: 0)
        guard let interface = try System.enumerateInterfaces().lazy.filter({ $0.address == targetAddress }).first else {
            throw NoSuchInterfaceError()
        }
        return interface
    }

    private func bindMulticastChannel(host: String, port: Int, multicastAddress: String, interface: NIONetworkInterface) -> EventLoopFuture<MulticastChannel> {
        return DatagramBootstrap(group: self.group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: host, port: port)
            .then { channel in
                let channel = channel as! MulticastChannel

                do {
                    let multicastAddress = try SocketAddress(ipAddress: multicastAddress, port: channel.localAddress!.port!)
                    return channel.joinGroup(multicastAddress, interface: interface).map { channel }
                } catch {
                    return channel.eventLoop.newFailedFuture(error: error)
                }
            }.then { (channel: MulticastChannel) -> EventLoopFuture<MulticastChannel> in
                let provider = channel as! SocketOptionProvider

                switch channel.localAddress! {
                case .v4:
                    return provider.setIPMulticastLoop(1).map { channel }
                case .v6:
                    return provider.setIPv6MulticastLoop(1).map { channel }
                case .unixDomainSocket:
                    preconditionFailure("Multicast is meaningless on unix domain sockets")
                }
            }
    }

    private func configureSenderMulticastIf(sender: Channel, multicastInterface: NIONetworkInterface) -> EventLoopFuture<Void> {
        let provider = sender as! SocketOptionProvider

        switch (sender.localAddress!, multicastInterface.address) {
        case (.v4, .v4(let addr)):
            return provider.setIPMulticastIF(addr.address.sin_addr)
        case (.v6, .v6):
            return provider.setIPv6MulticastIF(CUnsignedInt(multicastInterface.interfaceIndex))
        default:
            XCTFail("Cannot join channel bound to \(sender.localAddress!) to interface at \(multicastInterface.address)")
            return sender.eventLoop.newFailedFuture(error: MulticastInterfaceMismatchError())
        }
    }

    private func leaveMulticastGroup(channel: Channel, multicastAddress: String, interface: NIONetworkInterface) -> EventLoopFuture<Void> {
        let channel = channel as! MulticastChannel

        do {
            let multicastAddress = try SocketAddress(ipAddress: multicastAddress, port: channel.localAddress!.port!)
            return channel.leaveGroup(multicastAddress, interface: interface)
        } catch {
            return channel.eventLoop.newFailedFuture(error: error)
        }
    }

    private func assertDatagramReaches(multicastChannel: Channel, sender: Channel, multicastAddress: SocketAddress, file: StaticString = #file, line: UInt = #line) throws {
        let receivedMulticastDatagram = multicastChannel.eventLoop.newPromise(of: AddressedEnvelope<ByteBuffer>.self)
        XCTAssertNoThrow(try multicastChannel.pipeline.add(handler: PromiseOnReadHandler(promise: receivedMulticastDatagram)).wait())

        var messageBuffer = sender.allocator.buffer(capacity: 24)
        messageBuffer.write(staticString: "hello, world!")

        XCTAssertNoThrow(
            try sender.writeAndFlush(AddressedEnvelope(remoteAddress: multicastAddress, data: messageBuffer)).wait(),
            file: file,
            line: line
        )

        let receivedDatagram = try assertNoThrowWithValue(receivedMulticastDatagram.futureResult.wait(), file: file, line: line)
        XCTAssertEqual(receivedDatagram.remoteAddress, sender.localAddress!)
        XCTAssertEqual(receivedDatagram.data, messageBuffer)
    }

    private func assertDatagramDoesNotReach(multicastChannel: Channel,
                                            after timeout: TimeAmount,
                                            sender: Channel,
                                            multicastAddress: SocketAddress,
                                            file: StaticString = #file, line: UInt = #line) throws {
        let timeoutPromise = multicastChannel.eventLoop.newPromise(of: Void.self)
        let receivedMulticastDatagram = multicastChannel.eventLoop.newPromise(of: AddressedEnvelope<ByteBuffer>.self)
        XCTAssertNoThrow(try multicastChannel.pipeline.add(handler: PromiseOnReadHandler(promise: receivedMulticastDatagram)).wait())

        // If we receive a datagram, or the reader promise fails, we must fail the timeoutPromise.
        receivedMulticastDatagram.futureResult.map { (_: AddressedEnvelope<ByteBuffer>) in
            timeoutPromise.fail(error: ReceivedDatagramError())
        }.cascadeFailure(promise: timeoutPromise)

        var messageBuffer = sender.allocator.buffer(capacity: 24)
        messageBuffer.write(staticString: "hello, world!")

        XCTAssertNoThrow(
            try sender.writeAndFlush(AddressedEnvelope(remoteAddress: multicastAddress, data: messageBuffer)).wait(),
            file: file,
            line: line
        )

        _ = multicastChannel.eventLoop.scheduleTask(in: timeout) { timeoutPromise.succeed(result: ()) }
        XCTAssertNoThrow(try timeoutPromise.futureResult.wait(), file: file, line: line)
    }

    func testCanJoinBasicMulticastGroupIPv4() throws {
        let multicastInterface = try assertNoThrowWithValue(self.interfaceForAddress(address: "127.0.0.1"))

        // We avoid the risk of interference due to our all-addresses bind by only joining this multicast
        // group on the loopback.
        let listenerChannel = try assertNoThrowWithValue(self.bindMulticastChannel(host: "0.0.0.0",
                                                                                   port: 0,
                                                                                   multicastAddress: "224.0.2.66",
                                                                                   interface: multicastInterface).wait())
        
        defer {
            XCTAssertNoThrow(try listenerChannel.close().wait())
        }

        let multicastAddress = try assertNoThrowWithValue(try SocketAddress(ipAddress: "224.0.2.66", port: listenerChannel.localAddress!.port!))

        // Now that we've joined the group, let's send to it.
        let sender = try assertNoThrowWithValue(DatagramBootstrap(group: self.group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        )
        defer {
            XCTAssertNoThrow(try sender.close().wait())
        }

        XCTAssertNoThrow(try configureSenderMulticastIf(sender: sender, multicastInterface: multicastInterface).wait())
        try self.assertDatagramReaches(multicastChannel: listenerChannel, sender: sender, multicastAddress: multicastAddress)
    }

    func testCanJoinBasicMulticastGroupIPv6() throws {
        guard self.supportsIPv6 else {
            // Skip on non-IPv6 systems
            return
        }

        let multicastInterface = try assertNoThrowWithValue(self.interfaceForAddress(address: "::1"))

        // We avoid the risk of interference due to our all-addresses bind by only joining this multicast
        // group on the loopback.
        let listenerChannel = try assertNoThrowWithValue(self.bindMulticastChannel(host: "::1",
                                                                                   port: 0,
                                                                                   multicastAddress: "ff12::beeb",
                                                                                   interface: multicastInterface).wait())
        defer {
            XCTAssertNoThrow(try listenerChannel.close().wait())
        }

        let multicastAddress = try assertNoThrowWithValue(try SocketAddress(ipAddress: "ff12::beeb", port: listenerChannel.localAddress!.port!))

        // Now that we've joined the group, let's send to it.
        let sender = try assertNoThrowWithValue(DatagramBootstrap(group: self.group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "::1", port: 0)
            .wait()
        )
        defer {
            XCTAssertNoThrow(try sender.close().wait())
        }

        XCTAssertNoThrow(try configureSenderMulticastIf(sender: sender, multicastInterface: multicastInterface).wait())
        try self.assertDatagramReaches(multicastChannel: listenerChannel, sender: sender, multicastAddress: multicastAddress)
    }

    func testCanLeaveAnIPv4MulticastGroup() throws {
        let multicastInterface = try assertNoThrowWithValue(self.interfaceForAddress(address: "127.0.0.1"))

        // We avoid the risk of interference due to our all-addresses bind by only joining this multicast
        // group on the loopback.
        let listenerChannel = try assertNoThrowWithValue(self.bindMulticastChannel(host: "0.0.0.0",
                                                                                   port: 0,
                                                                                   multicastAddress: "224.0.2.66",
                                                                                   interface: multicastInterface).wait())

        defer {
            XCTAssertNoThrow(try listenerChannel.close().wait())
        }

        let multicastAddress = try assertNoThrowWithValue(try SocketAddress(ipAddress: "224.0.2.66", port: listenerChannel.localAddress!.port!))

        // Now that we've joined the group, let's send to it.
        let sender = try assertNoThrowWithValue(DatagramBootstrap(group: self.group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        )
        defer {
            XCTAssertNoThrow(try sender.close().wait())
        }

        XCTAssertNoThrow(try configureSenderMulticastIf(sender: sender, multicastInterface: multicastInterface).wait())
        try self.assertDatagramReaches(multicastChannel: listenerChannel, sender: sender, multicastAddress: multicastAddress)

        // Now we should *leave* the group.
        XCTAssertNoThrow(try leaveMulticastGroup(channel: listenerChannel, multicastAddress: "224.0.2.66", interface: multicastInterface).wait())
        try self.assertDatagramDoesNotReach(multicastChannel: listenerChannel, after: .milliseconds(500), sender: sender, multicastAddress: multicastAddress)
    }

    func testCanLeaveAnIPv6MulticastGroup() throws {
        guard self.supportsIPv6 else {
            // Skip on non-IPv6 systems
            return
        }

        let multicastInterface = try assertNoThrowWithValue(self.interfaceForAddress(address: "::1"))

        // We avoid the risk of interference due to our all-addresses bind by only joining this multicast
        // group on the loopback.
        let listenerChannel = try assertNoThrowWithValue(self.bindMulticastChannel(host: "::1",
                                                                                   port: 0,
                                                                                   multicastAddress: "ff12::beeb",
                                                                                   interface: multicastInterface).wait())
        defer {
            XCTAssertNoThrow(try listenerChannel.close().wait())
        }

        let multicastAddress = try assertNoThrowWithValue(try SocketAddress(ipAddress: "ff12::beeb", port: listenerChannel.localAddress!.port!))

        // Now that we've joined the group, let's send to it.
        let sender = try assertNoThrowWithValue(DatagramBootstrap(group: self.group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "::1", port: 0)
            .wait()
        )
        defer {
            XCTAssertNoThrow(try sender.close().wait())
        }

        XCTAssertNoThrow(try configureSenderMulticastIf(sender: sender, multicastInterface: multicastInterface).wait())
        try self.assertDatagramReaches(multicastChannel: listenerChannel, sender: sender, multicastAddress: multicastAddress)

        // Now we should *leave* the group.
        XCTAssertNoThrow(try leaveMulticastGroup(channel: listenerChannel, multicastAddress: "ff12::beeb", interface: multicastInterface).wait())
        try self.assertDatagramDoesNotReach(multicastChannel: listenerChannel, after: .milliseconds(500), sender: sender, multicastAddress: multicastAddress)
    }
}
