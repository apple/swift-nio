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
import CNIOLinux
import NIOCore
import NIOPosix
import XCTest

final class PromiseOnReadHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let promise: EventLoopPromise<InboundIn>

    init(promise: EventLoopPromise<InboundIn>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.promise.succeed(Self.unwrapInboundIn(data))
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
    }
}

final class MulticastTest: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.group.syncShutdownGracefully())
    }

    struct NoSuchInterfaceError: Error {}

    struct MulticastInterfaceMismatchError: Error {}

    struct ReceivedDatagramError: Error {}

    @available(*, deprecated)
    private func interfaceForAddress(address: String) throws -> NIONetworkInterface {
        let targetAddress = try SocketAddress(ipAddress: address, port: 0)
        guard let interface = try System.enumerateInterfaces().lazy.filter({ $0.address == targetAddress }).first else {
            throw NoSuchInterfaceError()
        }
        return interface
    }

    private func deviceForAddress(address: String) throws -> NIONetworkDevice {
        let targetAddress = try SocketAddress(ipAddress: address, port: 0)
        guard let device = try System.enumerateDevices().lazy.filter({ $0.address == targetAddress }).first else {
            throw NoSuchInterfaceError()
        }
        return device
    }

    @available(*, deprecated)
    private func bindMulticastChannel(
        host: String,
        port: Int,
        multicastAddress: String,
        interface: NIONetworkInterface
    ) -> EventLoopFuture<MulticastChannel> {
        DatagramBootstrap(group: self.group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port)
            .flatMap { channel in
                let channel = channel as! MulticastChannel

                do {
                    let multicastAddress = try SocketAddress(
                        ipAddress: multicastAddress,
                        port: channel.localAddress!.port!
                    )
                    return channel.joinGroup(multicastAddress, interface: interface).map { channel }
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }.flatMap { (channel: MulticastChannel) -> EventLoopFuture<MulticastChannel> in
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

    private func bindMulticastChannel(
        host: String,
        port: Int,
        multicastAddress: String,
        device: NIONetworkDevice
    ) -> EventLoopFuture<MulticastChannel> {
        DatagramBootstrap(group: self.group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: host, port: port)
            .flatMap { channel in
                let channel = channel as! MulticastChannel

                do {
                    let multicastAddress = try SocketAddress(
                        ipAddress: multicastAddress,
                        port: channel.localAddress!.port!
                    )
                    return channel.joinGroup(multicastAddress, device: device).map { channel }
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }.flatMap { (channel: MulticastChannel) -> EventLoopFuture<MulticastChannel> in
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

    @available(*, deprecated)
    private func configureSenderMulticastIf(
        sender: Channel,
        multicastInterface: NIONetworkInterface
    ) -> EventLoopFuture<Void> {
        let provider = sender as! SocketOptionProvider

        switch (sender.localAddress!, multicastInterface.address) {
        case (.v4, .v4(let addr)):
            return provider.setIPMulticastIF(addr.address.sin_addr)
        case (.v6, .v6):
            return provider.setIPv6MulticastIF(CUnsignedInt(multicastInterface.interfaceIndex))
        default:
            XCTFail(
                "Cannot join channel bound to \(sender.localAddress!) to interface at \(multicastInterface.address)"
            )
            return sender.eventLoop.makeFailedFuture(MulticastInterfaceMismatchError())
        }
    }

    private func configureSenderMulticastIf(sender: Channel, multicastDevice: NIONetworkDevice) -> EventLoopFuture<Void>
    {
        let provider = sender as! SocketOptionProvider

        switch (sender.localAddress!, multicastDevice.address) {
        case (.v4, .some(.v4(let addr))):
            return provider.setIPMulticastIF(addr.address.sin_addr)
        case (.v6, .some(.v6)):
            return provider.setIPv6MulticastIF(CUnsignedInt(multicastDevice.interfaceIndex))
        default:
            XCTFail(
                "Cannot join channel bound to \(sender.localAddress!) to interface at \(String(describing: multicastDevice.address))"
            )
            return sender.eventLoop.makeFailedFuture(MulticastInterfaceMismatchError())
        }
    }

    @available(*, deprecated)
    private func leaveMulticastGroup(
        channel: Channel,
        multicastAddress: String,
        interface: NIONetworkInterface
    ) -> EventLoopFuture<Void> {
        let channel = channel as! MulticastChannel

        do {
            let multicastAddress = try SocketAddress(ipAddress: multicastAddress, port: channel.localAddress!.port!)
            return channel.leaveGroup(multicastAddress, interface: interface)
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }

    private func leaveMulticastGroup(
        channel: Channel,
        multicastAddress: String,
        device: NIONetworkDevice
    ) -> EventLoopFuture<Void> {
        let channel = channel as! MulticastChannel

        do {
            let multicastAddress = try SocketAddress(ipAddress: multicastAddress, port: channel.localAddress!.port!)
            return channel.leaveGroup(multicastAddress, device: device)
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }

    private func assertDatagramReaches(
        multicastChannel: Channel,
        sender: Channel,
        multicastAddress: SocketAddress,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let receivedMulticastDatagram = multicastChannel.eventLoop.makePromise(of: AddressedEnvelope<ByteBuffer>.self)
        XCTAssertNoThrow(
            try multicastChannel.pipeline.addHandler(PromiseOnReadHandler(promise: receivedMulticastDatagram)).wait()
        )

        var messageBuffer = sender.allocator.buffer(capacity: 24)
        messageBuffer.writeStaticString("hello, world!")

        XCTAssertNoThrow(
            try sender.writeAndFlush(AddressedEnvelope(remoteAddress: multicastAddress, data: messageBuffer)).wait(),
            file: (file),
            line: line
        )

        let receivedDatagram = try assertNoThrowWithValue(
            receivedMulticastDatagram.futureResult.wait(),
            file: (file),
            line: line
        )
        XCTAssertEqual(receivedDatagram.remoteAddress, sender.localAddress!)
        XCTAssertEqual(receivedDatagram.data, messageBuffer)
    }

    private func assertDatagramDoesNotReach(
        multicastChannel: Channel,
        after timeout: TimeAmount,
        sender: Channel,
        multicastAddress: SocketAddress,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let timeoutPromise = multicastChannel.eventLoop.makePromise(of: Void.self)
        let receivedMulticastDatagram = multicastChannel.eventLoop.makePromise(of: AddressedEnvelope<ByteBuffer>.self)
        XCTAssertNoThrow(
            try multicastChannel.pipeline.addHandler(PromiseOnReadHandler(promise: receivedMulticastDatagram)).wait()
        )

        // If we receive a datagram, or the reader promise fails, we must fail the timeoutPromise.
        receivedMulticastDatagram.futureResult.map { (_: AddressedEnvelope<ByteBuffer>) in
            timeoutPromise.fail(ReceivedDatagramError())
        }.cascadeFailure(to: timeoutPromise)

        var messageBuffer = sender.allocator.buffer(capacity: 24)
        messageBuffer.writeStaticString("hello, world!")

        XCTAssertNoThrow(
            try sender.writeAndFlush(AddressedEnvelope(remoteAddress: multicastAddress, data: messageBuffer)).wait(),
            file: (file),
            line: line
        )

        _ = multicastChannel.eventLoop.scheduleTask(in: timeout) { timeoutPromise.succeed(()) }
        XCTAssertNoThrow(try timeoutPromise.futureResult.wait(), file: (file), line: line)
    }

    @available(*, deprecated)
    func testCanJoinBasicMulticastGroupIPv4() throws {
        let multicastInterface = try assertNoThrowWithValue(self.interfaceForAddress(address: "127.0.0.1"))
        guard multicastInterface.multicastSupported else {
            // alas, we don't support multicast, let's skip but test the right error is thrown

            XCTAssertThrowsError(
                try self.bindMulticastChannel(
                    host: "0.0.0.0",
                    port: 0,
                    multicastAddress: "224.0.2.66",
                    interface: multicastInterface
                ).wait()
            ) { error in
                if let error = error as? NIOMulticastNotSupportedError {
                    XCTAssertEqual(NIONetworkDevice(multicastInterface), error.device)
                } else {
                    XCTFail("unexpected error: \(error)")
                }
            }
            return
        }

        // We avoid the risk of interference due to our all-addresses bind by only joining this multicast
        // group on the loopback.
        let listenerChannel: Channel
        do {
            listenerChannel = try assertNoThrowWithValue(
                self.bindMulticastChannel(
                    host: "0.0.0.0",
                    port: 0,
                    multicastAddress: "224.0.2.66",
                    interface: multicastInterface
                ).wait()
            )
            // no error, that's great
        } catch {
            if error is NIOMulticastNotSupportedError {
                XCTFail("network interface (\(multicastInterface))) claims we support multicast but: \(error)")
            } else {
                XCTFail("unexpected error: \(error)")
            }
            return
        }

        defer {
            XCTAssertNoThrow(try listenerChannel.close().wait())
        }

        let multicastAddress = try assertNoThrowWithValue(
            try SocketAddress(ipAddress: "224.0.2.66", port: listenerChannel.localAddress!.port!)
        )

        // Now that we've joined the group, let's send to it.
        let sender = try assertNoThrowWithValue(
            DatagramBootstrap(group: self.group)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try sender.close().wait())
        }

        XCTAssertNoThrow(try configureSenderMulticastIf(sender: sender, multicastInterface: multicastInterface).wait())
        try self.assertDatagramReaches(
            multicastChannel: listenerChannel,
            sender: sender,
            multicastAddress: multicastAddress
        )
    }

    @available(*, deprecated)
    func testCanJoinBasicMulticastGroupIPv6() throws {
        guard System.supportsIPv6 else {
            // Skip on non-IPv6 systems
            return
        }

        let multicastInterface = try assertNoThrowWithValue(self.interfaceForAddress(address: "::1"))
        guard multicastInterface.multicastSupported else {
            // alas, we don't support multicast, let's skip but test the right error is thrown

            XCTAssertThrowsError(
                try self.bindMulticastChannel(
                    host: "::1",
                    port: 0,
                    multicastAddress: "ff12::beeb",
                    interface: multicastInterface
                ).wait()
            ) { error in
                if let error = error as? NIOMulticastNotSupportedError {
                    XCTAssertEqual(NIONetworkDevice(multicastInterface), error.device)
                } else {
                    XCTFail("unexpected error: \(error)")
                }
            }
            return
        }

        let listenerChannel: Channel
        do {
            // We avoid the risk of interference due to our all-addresses bind by only joining this multicast
            // group on the loopback.
            listenerChannel = try assertNoThrowWithValue(
                self.bindMulticastChannel(
                    host: "::1",
                    port: 0,
                    multicastAddress: "ff12::beeb",
                    interface: multicastInterface
                ).wait()
            )
        } catch {
            if error is NIOMulticastNotSupportedError {
                XCTFail("network interface (\(multicastInterface))) claims we support multicast but: \(error)")
            } else {
                XCTFail("unexpected error: \(error)")
            }
            return
        }
        defer {
            XCTAssertNoThrow(try listenerChannel.close().wait())
        }

        let multicastAddress = try assertNoThrowWithValue(
            try SocketAddress(ipAddress: "ff12::beeb", port: listenerChannel.localAddress!.port!)
        )

        // Now that we've joined the group, let's send to it.
        let sender = try assertNoThrowWithValue(
            DatagramBootstrap(group: self.group)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "::1", port: 0)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try sender.close().wait())
        }

        XCTAssertNoThrow(try configureSenderMulticastIf(sender: sender, multicastInterface: multicastInterface).wait())
        try self.assertDatagramReaches(
            multicastChannel: listenerChannel,
            sender: sender,
            multicastAddress: multicastAddress
        )
    }

    @available(*, deprecated)
    func testCanLeaveAnIPv4MulticastGroup() throws {
        let multicastInterface = try assertNoThrowWithValue(self.interfaceForAddress(address: "127.0.0.1"))
        guard multicastInterface.multicastSupported else {
            // alas, we don't support multicast, let's skip
            return
        }

        // We avoid the risk of interference due to our all-addresses bind by only joining this multicast
        // group on the loopback.
        let listenerChannel = try assertNoThrowWithValue(
            self.bindMulticastChannel(
                host: "0.0.0.0",
                port: 0,
                multicastAddress: "224.0.2.66",
                interface: multicastInterface
            ).wait()
        )

        defer {
            XCTAssertNoThrow(try listenerChannel.close().wait())
        }

        let multicastAddress = try assertNoThrowWithValue(
            try SocketAddress(ipAddress: "224.0.2.66", port: listenerChannel.localAddress!.port!)
        )

        // Now that we've joined the group, let's send to it.
        let sender = try assertNoThrowWithValue(
            DatagramBootstrap(group: self.group)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try sender.close().wait())
        }

        XCTAssertNoThrow(try configureSenderMulticastIf(sender: sender, multicastInterface: multicastInterface).wait())
        try self.assertDatagramReaches(
            multicastChannel: listenerChannel,
            sender: sender,
            multicastAddress: multicastAddress
        )

        // Now we should *leave* the group.
        XCTAssertNoThrow(
            try leaveMulticastGroup(
                channel: listenerChannel,
                multicastAddress: "224.0.2.66",
                interface: multicastInterface
            ).wait()
        )
        try self.assertDatagramDoesNotReach(
            multicastChannel: listenerChannel,
            after: .milliseconds(500),
            sender: sender,
            multicastAddress: multicastAddress
        )
    }

    @available(*, deprecated)
    func testCanLeaveAnIPv6MulticastGroup() throws {
        guard System.supportsIPv6 else {
            // Skip on non-IPv6 systems
            return
        }

        let multicastInterface = try assertNoThrowWithValue(self.interfaceForAddress(address: "::1"))
        guard multicastInterface.multicastSupported else {
            // alas, we don't support multicast, let's skip
            return
        }

        // We avoid the risk of interference due to our all-addresses bind by only joining this multicast
        // group on the loopback.
        let listenerChannel = try assertNoThrowWithValue(
            self.bindMulticastChannel(
                host: "::1",
                port: 0,
                multicastAddress: "ff12::beeb",
                interface: multicastInterface
            ).wait()
        )
        defer {
            XCTAssertNoThrow(try listenerChannel.close().wait())
        }

        let multicastAddress = try assertNoThrowWithValue(
            try SocketAddress(ipAddress: "ff12::beeb", port: listenerChannel.localAddress!.port!)
        )

        // Now that we've joined the group, let's send to it.
        let sender = try assertNoThrowWithValue(
            DatagramBootstrap(group: self.group)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "::1", port: 0)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try sender.close().wait())
        }

        XCTAssertNoThrow(try configureSenderMulticastIf(sender: sender, multicastInterface: multicastInterface).wait())
        try self.assertDatagramReaches(
            multicastChannel: listenerChannel,
            sender: sender,
            multicastAddress: multicastAddress
        )

        // Now we should *leave* the group.
        XCTAssertNoThrow(
            try leaveMulticastGroup(
                channel: listenerChannel,
                multicastAddress: "ff12::beeb",
                interface: multicastInterface
            ).wait()
        )
        try self.assertDatagramDoesNotReach(
            multicastChannel: listenerChannel,
            after: .milliseconds(500),
            sender: sender,
            multicastAddress: multicastAddress
        )
    }

    func testCanJoinBasicMulticastGroupIPv4WithDevice() throws {
        let multicastDevice = try assertNoThrowWithValue(self.deviceForAddress(address: "127.0.0.1"))
        guard multicastDevice.multicastSupported else {
            // alas, we don't support multicast, let's skip but test the right error is thrown

            XCTAssertThrowsError(
                try self.bindMulticastChannel(
                    host: "0.0.0.0",
                    port: 0,
                    multicastAddress: "224.0.2.66",
                    device: multicastDevice
                ).wait()
            ) { error in
                if let error = error as? NIOMulticastNotSupportedError {
                    XCTAssertEqual(multicastDevice, error.device)
                } else {
                    XCTFail("unexpected error: \(error)")
                }
            }
            return
        }

        // We avoid the risk of interference due to our all-addresses bind by only joining this multicast
        // group on the loopback.
        let listenerChannel: Channel
        do {
            listenerChannel = try assertNoThrowWithValue(
                self.bindMulticastChannel(
                    host: "0.0.0.0",
                    port: 0,
                    multicastAddress: "224.0.2.66",
                    device: multicastDevice
                ).wait()
            )
            // no error, that's great
        } catch {
            if error is NIOMulticastNotSupportedError {
                XCTFail("network interface (\(multicastDevice)) claims we support multicast but: \(error)")
            } else {
                XCTFail("unexpected error: \(error)")
            }
            return
        }

        defer {
            XCTAssertNoThrow(try listenerChannel.close().wait())
        }

        let multicastAddress = try assertNoThrowWithValue(
            try SocketAddress(ipAddress: "224.0.2.66", port: listenerChannel.localAddress!.port!)
        )

        // Now that we've joined the group, let's send to it.
        let sender = try assertNoThrowWithValue(
            DatagramBootstrap(group: self.group)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try sender.close().wait())
        }

        XCTAssertNoThrow(try configureSenderMulticastIf(sender: sender, multicastDevice: multicastDevice).wait())
        try self.assertDatagramReaches(
            multicastChannel: listenerChannel,
            sender: sender,
            multicastAddress: multicastAddress
        )
    }

    func testCanJoinBasicMulticastGroupIPv6WithDevice() throws {
        guard System.supportsIPv6 else {
            // Skip on non-IPv6 systems
            return
        }

        let multicastDevice = try assertNoThrowWithValue(self.deviceForAddress(address: "::1"))
        guard multicastDevice.multicastSupported else {
            // alas, we don't support multicast, let's skip but test the right error is thrown

            XCTAssertThrowsError(
                try self.bindMulticastChannel(
                    host: "::1",
                    port: 0,
                    multicastAddress: "ff12::beeb",
                    device: multicastDevice
                ).wait()
            ) { error in
                if let error = error as? NIOMulticastNotSupportedError {
                    XCTAssertEqual(multicastDevice, error.device)
                } else {
                    XCTFail("unexpected error: \(error)")
                }
            }
            return
        }

        let listenerChannel: Channel
        do {
            // We avoid the risk of interference due to our all-addresses bind by only joining this multicast
            // group on the loopback.
            listenerChannel = try assertNoThrowWithValue(
                self.bindMulticastChannel(
                    host: "::1",
                    port: 0,
                    multicastAddress: "ff12::beeb",
                    device: multicastDevice
                ).wait()
            )
        } catch {
            if error is NIOMulticastNotSupportedError {
                XCTFail("network interface (\(multicastDevice)) claims we support multicast but: \(error)")
            } else {
                XCTFail("unexpected error: \(error)")
            }
            return
        }
        defer {
            XCTAssertNoThrow(try listenerChannel.close().wait())
        }

        let multicastAddress = try assertNoThrowWithValue(
            try SocketAddress(ipAddress: "ff12::beeb", port: listenerChannel.localAddress!.port!)
        )

        // Now that we've joined the group, let's send to it.
        let sender = try assertNoThrowWithValue(
            DatagramBootstrap(group: self.group)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "::1", port: 0)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try sender.close().wait())
        }

        XCTAssertNoThrow(try configureSenderMulticastIf(sender: sender, multicastDevice: multicastDevice).wait())
        try self.assertDatagramReaches(
            multicastChannel: listenerChannel,
            sender: sender,
            multicastAddress: multicastAddress
        )
    }

    func testCanLeaveAnIPv4MulticastGroupWithDevice() throws {
        let multicastDevice = try assertNoThrowWithValue(self.deviceForAddress(address: "127.0.0.1"))
        guard multicastDevice.multicastSupported else {
            // alas, we don't support multicast, let's skip
            return
        }

        // We avoid the risk of interference due to our all-addresses bind by only joining this multicast
        // group on the loopback.
        let listenerChannel = try assertNoThrowWithValue(
            self.bindMulticastChannel(
                host: "0.0.0.0",
                port: 0,
                multicastAddress: "224.0.2.66",
                device: multicastDevice
            ).wait()
        )

        defer {
            XCTAssertNoThrow(try listenerChannel.close().wait())
        }

        let multicastAddress = try assertNoThrowWithValue(
            try SocketAddress(ipAddress: "224.0.2.66", port: listenerChannel.localAddress!.port!)
        )

        // Now that we've joined the group, let's send to it.
        let sender = try assertNoThrowWithValue(
            DatagramBootstrap(group: self.group)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try sender.close().wait())
        }

        XCTAssertNoThrow(try configureSenderMulticastIf(sender: sender, multicastDevice: multicastDevice).wait())
        try self.assertDatagramReaches(
            multicastChannel: listenerChannel,
            sender: sender,
            multicastAddress: multicastAddress
        )

        // Now we should *leave* the group.
        XCTAssertNoThrow(
            try leaveMulticastGroup(channel: listenerChannel, multicastAddress: "224.0.2.66", device: multicastDevice)
                .wait()
        )
        try self.assertDatagramDoesNotReach(
            multicastChannel: listenerChannel,
            after: .milliseconds(500),
            sender: sender,
            multicastAddress: multicastAddress
        )
    }

    func testCanLeaveAnIPv6MulticastGroupWithDevice() throws {
        guard System.supportsIPv6 else {
            // Skip on non-IPv6 systems
            return
        }

        let multicastDevice = try assertNoThrowWithValue(self.deviceForAddress(address: "::1"))
        guard multicastDevice.multicastSupported else {
            // alas, we don't support multicast, let's skip
            return
        }

        // We avoid the risk of interference due to our all-addresses bind by only joining this multicast
        // group on the loopback.
        let listenerChannel = try assertNoThrowWithValue(
            self.bindMulticastChannel(
                host: "::1",
                port: 0,
                multicastAddress: "ff12::beeb",
                device: multicastDevice
            ).wait()
        )
        defer {
            XCTAssertNoThrow(try listenerChannel.close().wait())
        }

        let multicastAddress = try assertNoThrowWithValue(
            try SocketAddress(ipAddress: "ff12::beeb", port: listenerChannel.localAddress!.port!)
        )

        // Now that we've joined the group, let's send to it.
        let sender = try assertNoThrowWithValue(
            DatagramBootstrap(group: self.group)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "::1", port: 0)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try sender.close().wait())
        }

        XCTAssertNoThrow(try configureSenderMulticastIf(sender: sender, multicastDevice: multicastDevice).wait())
        try self.assertDatagramReaches(
            multicastChannel: listenerChannel,
            sender: sender,
            multicastAddress: multicastAddress
        )

        // Now we should *leave* the group.
        XCTAssertNoThrow(
            try leaveMulticastGroup(channel: listenerChannel, multicastAddress: "ff12::beeb", device: multicastDevice)
                .wait()
        )
        try self.assertDatagramDoesNotReach(
            multicastChannel: listenerChannel,
            after: .milliseconds(500),
            sender: sender,
            multicastAddress: multicastAddress
        )
    }
}
