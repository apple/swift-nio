//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers
import NIOTLS
import XCTest

@testable import NIOCore
@testable import NIOPosix

private final class IPHeaderRemoverHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias InboundOut = AddressedEnvelope<ByteBuffer>

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var data = Self.unwrapInboundIn(data)
        let header = data.data.readIPv4Header()
        assert(header != nil)
        context.fireChannelRead(Self.wrapInboundOut(data))
    }
}

private final class LineDelimiterCoder: ByteToMessageDecoder, MessageToByteEncoder {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let newLine = "\n".utf8.first!
    private let inboundID: UInt8?
    private let outboundID: UInt8?

    init(inboundID: UInt8? = nil, outboundID: UInt8? = nil) {
        self.inboundID = inboundID
        self.outboundID = outboundID
    }

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let readable = buffer.withUnsafeReadableBytes { $0.firstIndex(of: self.newLine) }
        if let readable = readable {
            if let id = self.inboundID {
                let data = buffer.readSlice(length: readable - 1)!
                let inboundID = buffer.readInteger(as: UInt8.self)!
                buffer.moveReaderIndex(forwardBy: 1)

                if id == inboundID {
                    context.fireChannelRead(Self.wrapInboundOut(data))
                }
                return .continue
            } else {
                context.fireChannelRead(Self.wrapInboundOut(buffer.readSlice(length: readable)!))
                buffer.moveReaderIndex(forwardBy: 1)
                return .continue
            }
        }
        return .needMoreData
    }

    func encode(data: ByteBuffer, out: inout ByteBuffer) throws {
        out.writeImmutableBuffer(data)
        if let id = self.outboundID {
            out.writeInteger(id)
        }
        out.writeString("\n")
    }
}

private final class TLSUserEventHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    enum ALPN: String {
        case string
        case byte
        case unknown
    }

    private var proposedALPN: ALPN?

    init(
        proposedALPN: ALPN? = nil
    ) {
        self.proposedALPN = proposedALPN
    }

    func handlerAdded(context: ChannelHandlerContext) {
        guard context.channel.isActive else {
            return
        }

        if let proposedALPN = self.proposedALPN {
            self.proposedALPN = nil
            context.writeAndFlush(.init(ByteBuffer(string: "negotiate-alpn:\(proposedALPN.rawValue)")), promise: nil)
        }
        context.fireChannelActive()
    }

    func channelActive(context: ChannelHandlerContext) {
        if let proposedALPN = self.proposedALPN {
            context.writeAndFlush(.init(ByteBuffer(string: "negotiate-alpn:\(proposedALPN.rawValue)")), promise: nil)
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = Self.unwrapInboundIn(data)
        let string = String(buffer: buffer)

        if string.hasPrefix("negotiate-alpn:") {
            let alpn = String(string.dropFirst(15))
            context.writeAndFlush(.init(ByteBuffer(string: "alpn:\(alpn)")), promise: nil)
            context.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: alpn))
            context.pipeline.syncOperations.removeHandler(self, promise: nil)
        } else if string.hasPrefix("alpn:") {
            context.fireUserInboundEventTriggered(
                TLSUserEvent.handshakeCompleted(negotiatedProtocol: String(string.dropFirst(5)))
            )
            context.pipeline.syncOperations.removeHandler(self, promise: nil)
        } else {
            context.fireChannelRead(data)
        }
    }
}

private final class ByteBufferToStringHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = String
    typealias OutboundIn = String
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = Self.unwrapInboundIn(data)
        context.fireChannelRead(Self.wrapInboundOut(String(buffer: buffer)))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = ByteBuffer(string: Self.unwrapOutboundIn(data))
        context.write(.init(buffer), promise: promise)
    }
}

private final class ByteBufferToByteHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = UInt8
    typealias OutboundIn = UInt8
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = Self.unwrapInboundIn(data)
        let byte = buffer.readInteger(as: UInt8.self)!
        context.fireChannelRead(Self.wrapInboundOut(byte))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = ByteBuffer(integer: Self.unwrapOutboundIn(data))
        context.write(.init(buffer), promise: promise)
    }
}

private final class AddressedEnvelopingHandler: ChannelDuplexHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = Any

    var remoteAddress: SocketAddress?

    init(remoteAddress: SocketAddress? = nil) {
        self.remoteAddress = remoteAddress
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = Self.unwrapInboundIn(data)
        self.remoteAddress = envelope.remoteAddress

        context.fireChannelRead(Self.wrapInboundOut(envelope.data))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = Self.unwrapOutboundIn(data)
        if let remoteAddress = self.remoteAddress {
            context.write(
                Self.wrapOutboundOut(AddressedEnvelope(remoteAddress: remoteAddress, data: buffer)),
                promise: promise
            )
            return
        }

        context.write(Self.wrapOutboundOut(buffer), promise: promise)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class AsyncChannelBootstrapTests: XCTestCase {
    var group: MultiThreadedEventLoopGroup!

    enum NegotiationResult {
        case string(NIOAsyncChannel<String, String>)
        case byte(NIOAsyncChannel<UInt8, UInt8>)
    }

    struct ProtocolNegotiationError: Error {}

    enum StringOrByte: Hashable {
        case string(String)
        case byte(UInt8)
    }

    // MARK: Server/Client Bootstrap

    func testServerClientBootstrap_withAsyncChannel_andHostPort() async throws {
        let eventLoopGroup = self.group!

        let channel = try await ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.autoRead, value: true)
            .bind(
                host: "127.0.0.1",
                port: 0
            ) { channel in
                channel.eventLoop.makeCompletedFuture { () -> NIOAsyncChannel<String, String> in
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(LineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(ByteBufferToStringHandler())
                    return try NIOAsyncChannel(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(
                            inboundType: String.self,
                            outboundType: String.self
                        )
                    )
                }
            }

        try await withThrowingTaskGroup(of: Void.self) { group in
            let (stream, continuation) = AsyncStream<StringOrByte>.makeStream()
            var iterator = stream.makeAsyncIterator()

            group.addTask {
                try await withThrowingTaskGroup(of: Void.self) { _ in
                    try await channel.executeThenClose { inbound in
                        for try await childChannel in inbound {
                            try await childChannel.executeThenClose { childChannelInbound, _ in
                                for try await value in childChannelInbound {
                                    continuation.yield(.string(value))
                                }
                            }
                        }
                    }
                }
            }

            let stringChannel = try await self.makeClientChannel(
                eventLoopGroup: eventLoopGroup,
                port: channel.channel.localAddress!.port!
            )
            try await stringChannel.executeThenClose { _, outbound in
                try await outbound.write("hello")
            }

            await XCTAsyncAssertEqual(await iterator.next(), .string("hello"))

            group.cancelAll()
        }
    }

    func testAsyncChannelProtocolNegotiation() async throws {
        let eventLoopGroup = self.group!

        let channel: NIOAsyncChannel<EventLoopFuture<NegotiationResult>, Never> = try await ServerBootstrap(
            group: eventLoopGroup
        )
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .childChannelOption(.autoRead, value: true)
        .bind(
            host: "127.0.0.1",
            port: 0
        ) { channel in
            channel.eventLoop.makeCompletedFuture {
                try Self.configureProtocolNegotiationHandlers(channel: channel)
            }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            let (stream, continuation) = AsyncStream<StringOrByte>.makeStream()
            var serverIterator = stream.makeAsyncIterator()

            group.addTask {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    try await channel.executeThenClose { inbound in
                        for try await negotiationResult in inbound {
                            group.addTask {
                                switch try await negotiationResult.get() {
                                case .string(let channel):
                                    try await channel.executeThenClose { inbound, _ in
                                        for try await value in inbound {
                                            continuation.yield(.string(value))
                                        }
                                    }
                                case .byte(let channel):
                                    try await channel.executeThenClose { inbound, _ in
                                        for try await value in inbound {
                                            continuation.yield(.byte(value))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            let stringNegotiationResultFuture = try await self.makeClientChannelWithProtocolNegotiation(
                eventLoopGroup: eventLoopGroup,
                port: channel.channel.localAddress!.port!,
                proposedALPN: .string
            )
            let stringNegotiationResult = try await stringNegotiationResultFuture.get()
            switch stringNegotiationResult {
            case .string(let stringChannel):
                try await stringChannel.executeThenClose { _, outbound in
                    // This is the actual content
                    try await outbound.write("hello")
                }
                await XCTAsyncAssertEqual(await serverIterator.next(), .string("hello"))
            case .byte:
                preconditionFailure()
            }

            let byteNegotiationResultFuture = try await self.makeClientChannelWithProtocolNegotiation(
                eventLoopGroup: eventLoopGroup,
                port: channel.channel.localAddress!.port!,
                proposedALPN: .byte
            )
            let byteNegotiationResult = try await byteNegotiationResultFuture.get()
            switch byteNegotiationResult {
            case .string:
                preconditionFailure()
            case .byte(let byteChannel):
                try await byteChannel.executeThenClose { _, outbound in
                    // This is the actual content
                    try await outbound.write(UInt8(8))
                }
                await XCTAsyncAssertEqual(await serverIterator.next(), .byte(8))
            }

            group.cancelAll()
        }
    }

    func testAsyncChannelNestedProtocolNegotiation() async throws {
        let eventLoopGroup = self.group!

        let channel: NIOAsyncChannel<EventLoopFuture<EventLoopFuture<NegotiationResult>>, Never> =
            try await ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(
                host: "127.0.0.1",
                port: 0
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try Self.configureNestedProtocolNegotiationHandlers(channel: channel)
                }
            }

        try await withThrowingTaskGroup(of: Void.self) { group in
            let (stream, continuation) = AsyncStream<StringOrByte>.makeStream()
            var serverIterator = stream.makeAsyncIterator()

            group.addTask {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    try await channel.executeThenClose { inbound in
                        for try await negotiationResult in inbound {
                            group.addTask {
                                switch try await negotiationResult.get().get() {
                                case .string(let channel):
                                    try await channel.executeThenClose { inbound, _ in
                                        for try await value in inbound {
                                            continuation.yield(.string(value))
                                        }
                                    }
                                case .byte(let channel):
                                    try await channel.executeThenClose { inbound, _ in
                                        for try await value in inbound {
                                            continuation.yield(.byte(value))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            let stringStringNegotiationResult = try await self.makeClientChannelWithNestedProtocolNegotiation(
                eventLoopGroup: eventLoopGroup,
                port: channel.channel.localAddress!.port!,
                proposedOuterALPN: .string,
                proposedInnerALPN: .string
            )
            switch try await stringStringNegotiationResult.get().get() {
            case .string(let stringChannel):
                try await stringChannel.executeThenClose { _, outbound in
                    // This is the actual content
                    try await outbound.write("hello")
                }
                await XCTAsyncAssertEqual(await serverIterator.next(), .string("hello"))
            case .byte:
                preconditionFailure()
            }

            let byteStringNegotiationResult = try await self.makeClientChannelWithNestedProtocolNegotiation(
                eventLoopGroup: eventLoopGroup,
                port: channel.channel.localAddress!.port!,
                proposedOuterALPN: .byte,
                proposedInnerALPN: .string
            )
            switch try await byteStringNegotiationResult.get().get() {
            case .string(let stringChannel):
                try await stringChannel.executeThenClose { _, outbound in
                    // This is the actual content
                    try await outbound.write("hello")
                }
                await XCTAsyncAssertEqual(await serverIterator.next(), .string("hello"))
            case .byte:
                preconditionFailure()
            }

            let byteByteNegotiationResult = try await self.makeClientChannelWithNestedProtocolNegotiation(
                eventLoopGroup: eventLoopGroup,
                port: channel.channel.localAddress!.port!,
                proposedOuterALPN: .byte,
                proposedInnerALPN: .byte
            )
            switch try await byteByteNegotiationResult.get().get() {
            case .string:
                preconditionFailure()
            case .byte(let byteChannel):
                try await byteChannel.executeThenClose { _, outbound in
                    // This is the actual content
                    try await outbound.write(UInt8(8))
                }
                await XCTAsyncAssertEqual(await serverIterator.next(), .byte(8))
            }

            let stringByteNegotiationResult = try await self.makeClientChannelWithNestedProtocolNegotiation(
                eventLoopGroup: eventLoopGroup,
                port: channel.channel.localAddress!.port!,
                proposedOuterALPN: .string,
                proposedInnerALPN: .byte
            )
            switch try await stringByteNegotiationResult.get().get() {
            case .string:
                preconditionFailure()
            case .byte(let byteChannel):
                try await byteChannel.executeThenClose { _, outbound in
                    // This is the actual content
                    try await outbound.write(UInt8(8))
                }
                await XCTAsyncAssertEqual(await serverIterator.next(), .byte(8))
            }

            group.cancelAll()
        }
    }

    func testAsyncChannelProtocolNegotiation_whenFails() async throws {
        final class CollectingHandler: ChannelInboundHandler {
            typealias InboundIn = Channel

            private let channels: NIOLockedValueBox<[Channel]>

            init(channels: NIOLockedValueBox<[Channel]>) {
                self.channels = channels
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let channel = Self.unwrapInboundIn(data)

                self.channels.withLockedValue { $0.append(channel) }

                context.fireChannelRead(data)
            }
        }

        let eventLoopGroup = self.group!
        let channels = NIOLockedValueBox<[Channel]>([Channel]())

        let channel: NIOAsyncChannel<EventLoopFuture<NegotiationResult>, Never> = try await ServerBootstrap(
            group: eventLoopGroup
        )
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .serverChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(CollectingHandler(channels: channels))
            }
        }
        .childChannelOption(.autoRead, value: true)
        .bind(
            host: "127.0.0.1",
            port: 0
        ) { channel in
            channel.eventLoop.makeCompletedFuture {
                try Self.configureProtocolNegotiationHandlers(channel: channel)
            }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            let (stream, continuation) = AsyncStream<StringOrByte>.makeStream()
            var serverIterator = stream.makeAsyncIterator()

            group.addTask {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    try await channel.executeThenClose { inbound in
                        for try await negotiationResult in inbound {
                            group.addTask {
                                switch try await negotiationResult.get() {
                                case .string(let channel):
                                    try await channel.executeThenClose { inbound, _ in
                                        for try await value in inbound {
                                            continuation.yield(.string(value))
                                        }
                                    }
                                case .byte(let channel):
                                    try await channel.executeThenClose { inbound, _ in
                                        for try await value in inbound {
                                            continuation.yield(.byte(value))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            let failedProtocolNegotiation = try await self.makeClientChannelWithProtocolNegotiation(
                eventLoopGroup: eventLoopGroup,
                port: channel.channel.localAddress!.port!,
                proposedALPN: .unknown
            )
            await XCTAssertThrowsError {
                try await failedProtocolNegotiation.get()
            }

            // Let's check that we can still open a new connection
            let stringNegotiationResult = try await self.makeClientChannelWithProtocolNegotiation(
                eventLoopGroup: eventLoopGroup,
                port: channel.channel.localAddress!.port!,
                proposedALPN: .string
            )
            switch try await stringNegotiationResult.get() {
            case .string(let stringChannel):
                try await stringChannel.executeThenClose { _, outbound in
                    // This is the actual content
                    try await outbound.write("hello")
                }
                await XCTAsyncAssertEqual(await serverIterator.next(), .string("hello"))
            case .byte:
                preconditionFailure()
            }

            let failedInboundChannel = channels.withLockedValue { channels -> Channel in
                XCTAssertEqual(channels.count, 2)
                return channels[0]
            }

            // We are waiting here to make sure the channel got closed
            try await failedInboundChannel.closeFuture.get()

            group.cancelAll()
        }
    }

    func testClientBootstrap_connectFails() async throws {
        // Beyond verifying the connect throws, this test allows us to check that 'NIOAsyncChannel'
        // doesn't crash on deinit when we never return it to the user.
        await XCTAssertThrowsError {
            try await ClientBootstrap(
                group: .singletonMultiThreadedEventLoopGroup
            ).connect(unixDomainSocketPath: "testClientBootstrapConnectFails") { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(
                            inboundType: ByteBuffer.self,
                            outboundType: ByteBuffer.self
                        )
                    )
                }
            }
        }
    }

    func testServerClientBootstrap_withAsyncChannel_clientConnectedSocket() async throws {
        let eventLoopGroup = self.group!

        let channel = try await ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.autoRead, value: true)
            .bind(
                host: "127.0.0.1",
                port: 0
            ) { channel in
                channel.eventLoop.makeCompletedFuture { () -> NIOAsyncChannel<String, String> in
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(LineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(ByteBufferToStringHandler())
                    return try NIOAsyncChannel(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(
                            inboundType: String.self,
                            outboundType: String.self
                        )
                    )
                }
            }

        try await withThrowingTaskGroup(of: Void.self) { group in
            let (stream, continuation) = AsyncStream<StringOrByte>.makeStream()
            var iterator = stream.makeAsyncIterator()

            group.addTask {
                try await withThrowingTaskGroup(of: Void.self) { _ in
                    try await channel.executeThenClose { inbound in
                        for try await childChannel in inbound {
                            try await childChannel.executeThenClose { childChannelInbound, _ in
                                for try await value in childChannelInbound {
                                    continuation.yield(.string(value))
                                }
                            }
                        }
                    }
                }
            }

            let s = try Socket(protocolFamily: .inet, type: .stream)
            XCTAssert(try s.connect(to: channel.channel.localAddress!))
            let fd = try s.takeDescriptorOwnership()

            let stringChannel = try await self.makeClientChannel(
                eventLoopGroup: eventLoopGroup,
                fileDescriptor: fd
            )
            try await stringChannel.executeThenClose { _, outbound in
                try await outbound.write("hello")
            }

            await XCTAsyncAssertEqual(await iterator.next(), .string("hello"))

            group.cancelAll()
        }
    }

    // MARK: Datagram Bootstrap

    func testDatagramBootstrap_withAsyncChannel_andHostPort() async throws {
        let eventLoopGroup = self.group!

        let serverChannel = try await self.makeUDPServerChannel(eventLoopGroup: eventLoopGroup)
        let clientChannel = try await self.makeUDPClientChannel(
            eventLoopGroup: eventLoopGroup,
            port: serverChannel.channel.localAddress!.port!
        )
        try await serverChannel.executeThenClose { serverChannelInbound, serverChannelOutbound in
            try await clientChannel.executeThenClose { clientChannelInbound, clientChannelOutbound in
                var serverInboundIterator = serverChannelInbound.makeAsyncIterator()
                var clientInboundIterator = clientChannelInbound.makeAsyncIterator()

                try await clientChannelOutbound.write("request")
                try await XCTAsyncAssertEqual(try await serverInboundIterator.next(), "request")

                try await serverChannelOutbound.write("response")
                try await XCTAsyncAssertEqual(try await clientInboundIterator.next(), "response")
            }
        }
    }

    func testDatagramBootstrap_withProtocolNegotiation_andHostPort() async throws {
        let eventLoopGroup = self.group!

        // We are creating a channel here to get a random port from the system
        let channel = try await DatagramBootstrap(group: eventLoopGroup)
            .bind(
                to: .init(ipAddress: "127.0.0.1", port: 0),
                channelInitializer: { channel -> EventLoopFuture<Channel> in
                    channel.eventLoop.makeSucceededFuture(channel)
                }
            )

        let port = channel.localAddress!.port!
        try await channel.close()

        try await withThrowingTaskGroup(of: EventLoopFuture<NegotiationResult>.self) { group in
            group.addTask {
                // We have to use a fixed port here since we only get the channel once protocol negotiation is done
                try await Self.makeUDPServerChannelWithProtocolNegotiation(
                    eventLoopGroup: eventLoopGroup,
                    port: port
                )
            }

            // We need to sleep here since we can only connect the client after the server started.
            try await Task.sleep(nanoseconds: 100_000_000)

            group.addTask {
                // We have to use a fixed port here since we only get the channel once protocol negotiation is done
                try await Self.makeUDPClientChannelWithProtocolNegotiation(
                    eventLoopGroup: eventLoopGroup,
                    port: port,
                    proposedALPN: .string
                )
            }

            let firstNegotiationResult = try await group.next()
            let secondNegotiationResult = try await group.next()

            switch (try await firstNegotiationResult?.get(), try await secondNegotiationResult?.get()) {
            case (.string(let firstChannel), .string(let secondChannel)):
                try await firstChannel.executeThenClose { firstChannelInbound, firstChannelOutbound in
                    try await secondChannel.executeThenClose { secondChannelInbound, secondChannelOutbound in
                        var firstInboundIterator = firstChannelInbound.makeAsyncIterator()
                        var secondInboundIterator = secondChannelInbound.makeAsyncIterator()

                        try await firstChannelOutbound.write("request")
                        try await XCTAsyncAssertEqual(try await secondInboundIterator.next(), "request")

                        try await secondChannelOutbound.write("response")
                        try await XCTAsyncAssertEqual(try await firstInboundIterator.next(), "response")
                    }
                }

            default:
                preconditionFailure()
            }
        }
    }

    func testDatagramBootstrap_connectFails() async throws {
        // Beyond verifying the connect throws, this test allows us to check that 'NIOAsyncChannel'
        // doesn't crash on deinit when we never return it to the user.
        await XCTAssertThrowsError {
            try await DatagramBootstrap(
                group: .singletonMultiThreadedEventLoopGroup
            ).connect(unixDomainSocketPath: "testDatagramBootstrapConnectFails") { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(
                            inboundType: AddressedEnvelope<ByteBuffer>.self,
                            outboundType: AddressedEnvelope<ByteBuffer>.self
                        )
                    )
                }
            }
        }
    }

    // MARK: - Pipe Bootstrap

    func testPipeBootstrap() async throws {
        let eventLoopGroup = self.group!
        let (pipe1ReadFD, pipe1WriteFD, pipe2ReadFD, pipe2WriteFD) = self.makePipeFileDescriptors()
        let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        let toChannel: NIOAsyncChannel<Never, ByteBuffer>
        let fromChannel: NIOAsyncChannel<ByteBuffer, Never>

        do {
            channel = try await NIOPipeBootstrap(group: eventLoopGroup)
                .takingOwnershipOfDescriptors(
                    input: pipe1ReadFD,
                    output: pipe2WriteFD
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            for fileDescriptor in [pipe1ReadFD, pipe1WriteFD, pipe2ReadFD, pipe2WriteFD] {
                try SystemCalls.close(descriptor: fileDescriptor)
            }
            throw error
        }

        do {
            toChannel = try await NIOPipeBootstrap(group: eventLoopGroup)
                .takingOwnershipOfDescriptor(
                    output: pipe1WriteFD
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            for fileDescriptor in [pipe1WriteFD, pipe2ReadFD] {
                try SystemCalls.close(descriptor: fileDescriptor)
            }
            throw error
        }

        do {
            fromChannel = try await NIOPipeBootstrap(group: eventLoopGroup)
                .takingOwnershipOfDescriptor(
                    input: pipe2ReadFD
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            for fileDescriptor in [pipe2ReadFD] {
                try SystemCalls.close(descriptor: fileDescriptor)
            }
            throw error
        }

        try await channel.executeThenClose { channelInbound, channelOutbound in
            try await fromChannel.executeThenClose { fromChannelInbound, _ in
                try await toChannel.executeThenClose { _, toChannelOutbound in
                    var inboundIterator = channelInbound.makeAsyncIterator()
                    var fromChannelInboundIterator = fromChannelInbound.makeAsyncIterator()

                    try await toChannelOutbound.write(.init(string: "Request"))
                    try await XCTAsyncAssertEqual(try await inboundIterator.next(), ByteBuffer(string: "Request"))

                    let response = ByteBuffer(string: "Response")
                    try await channelOutbound.write(response)
                    try await XCTAsyncAssertEqual(try await fromChannelInboundIterator.next(), response)
                }
            }
        }
    }

    func testPipeBootstrap_whenInputNil() async throws {
        let eventLoopGroup = self.group!
        let (pipe1ReadFD, pipe1WriteFD) = self.makePipeFileDescriptors()
        let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        let fromChannel: NIOAsyncChannel<ByteBuffer, Never>

        do {
            channel = try await NIOPipeBootstrap(group: eventLoopGroup)
                .takingOwnershipOfDescriptor(
                    output: pipe1WriteFD
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            for fileDescriptor in [pipe1ReadFD, pipe1WriteFD] {
                try SystemCalls.close(descriptor: fileDescriptor)
            }
            throw error
        }

        do {
            fromChannel = try await NIOPipeBootstrap(group: eventLoopGroup)
                .takingOwnershipOfDescriptor(
                    input: pipe1ReadFD
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            for fileDescriptor in [pipe1WriteFD] {
                try SystemCalls.close(descriptor: fileDescriptor)
            }
            throw error
        }

        try await channel.executeThenClose { channelInbound, channelOutbound in
            try await fromChannel.executeThenClose { fromChannelInbound, _ in
                var inboundIterator = channelInbound.makeAsyncIterator()
                var fromChannelInboundIterator = fromChannelInbound.makeAsyncIterator()

                try await XCTAsyncAssertEqual(try await inboundIterator.next(), nil)

                let response = ByteBuffer(string: "Response")
                try await channelOutbound.write(response)
                try await XCTAsyncAssertEqual(try await fromChannelInboundIterator.next(), response)
            }
        }
    }

    func testPipeBootstrap_whenOutputNil() async throws {
        let eventLoopGroup = self.group!
        let (pipe1ReadFD, pipe1WriteFD) = self.makePipeFileDescriptors()
        let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        let toChannel: NIOAsyncChannel<Never, ByteBuffer>

        do {
            channel = try await NIOPipeBootstrap(group: eventLoopGroup)
                .takingOwnershipOfDescriptor(
                    input: pipe1ReadFD
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            for fileDescriptor in [pipe1ReadFD, pipe1WriteFD] {
                try SystemCalls.close(descriptor: fileDescriptor)
            }

            throw error
        }

        do {
            toChannel = try await NIOPipeBootstrap(group: eventLoopGroup)
                .takingOwnershipOfDescriptor(
                    output: pipe1WriteFD
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            for fileDescriptor in [pipe1WriteFD] {
                try SystemCalls.close(descriptor: fileDescriptor)
            }
            throw error
        }

        try await channel.executeThenClose { channelInbound, channelOutbound in
            try await toChannel.executeThenClose { _, toChannelOutbound in
                var inboundIterator = channelInbound.makeAsyncIterator()

                try await toChannelOutbound.write(.init(string: "Request"))
                try await XCTAsyncAssertEqual(try await inboundIterator.next(), ByteBuffer(string: "Request"))

                let response = ByteBuffer(string: "Response")
                await XCTAsyncAssertThrowsError(try await channelOutbound.write(response)) { error in
                    XCTAssertEqual(error as? NIOAsyncWriterError, .alreadyFinished())
                }
            }
        }
    }

    func testPipeBootstrap_withProtocolNegotiation() async throws {
        let eventLoopGroup = self.group!
        let (pipe1ReadFD, pipe1WriteFD, pipe2ReadFD, pipe2WriteFD) = self.makePipeFileDescriptors()
        let negotiationResult: EventLoopFuture<NegotiationResult>
        let toChannel: NIOAsyncChannel<Never, ByteBuffer>
        let fromChannel: NIOAsyncChannel<ByteBuffer, Never>

        do {
            negotiationResult = try await NIOPipeBootstrap(group: eventLoopGroup)
                .takingOwnershipOfDescriptors(
                    input: pipe1ReadFD,
                    output: pipe2WriteFD
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try Self.configureProtocolNegotiationHandlers(channel: channel)
                    }
                }
        } catch {
            for fileDescriptor in [pipe1ReadFD, pipe1WriteFD, pipe2ReadFD, pipe2WriteFD] {
                try SystemCalls.close(descriptor: fileDescriptor)
            }
            throw error
        }

        do {
            toChannel = try await NIOPipeBootstrap(group: eventLoopGroup)
                .takingOwnershipOfDescriptor(
                    output: pipe1WriteFD
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            for fileDescriptor in [pipe1WriteFD, pipe2ReadFD] {
                try SystemCalls.close(descriptor: fileDescriptor)
            }
            throw error
        }

        do {
            fromChannel = try await NIOPipeBootstrap(group: eventLoopGroup)
                .takingOwnershipOfDescriptor(
                    input: pipe2ReadFD
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            for fileDescriptor in [pipe2ReadFD] {
                try SystemCalls.close(descriptor: fileDescriptor)
            }
            throw error
        }

        try await fromChannel.executeThenClose { fromChannelInbound, _ in
            try await toChannel.executeThenClose { _, toChannelOutbound in
                var fromChannelInboundIterator = fromChannelInbound.makeAsyncIterator()

                try await toChannelOutbound.write(.init(string: "alpn:string\nHello\n"))
                switch try await negotiationResult.get() {
                case .string(let channel):
                    try await channel.executeThenClose { channelInbound, channelOutbound in
                        var inboundIterator = channelInbound.makeAsyncIterator()
                        do {
                            try await XCTAsyncAssertEqual(try await inboundIterator.next(), "Hello")

                            let expectedResponse = ByteBuffer(string: "Response\n")
                            try await channelOutbound.write("Response")
                            let response = try await fromChannelInboundIterator.next()
                            XCTAssertEqual(response, expectedResponse)
                        } catch {
                            // We only got to close the FDs that are not owned by the PipeChannel
                            for fileDescriptor in [pipe1WriteFD, pipe2ReadFD] {
                                try? SystemCalls.close(descriptor: fileDescriptor)
                            }
                            throw error
                        }
                    }

                case .byte:
                    fatalError()
                }
            }
        }
    }

    func testPipeBootstrap_callsChannelInitializer() async throws {
        let eventLoopGroup = self.group!
        let (pipe1ReadFD, pipe1WriteFD, pipe2ReadFD, pipe2WriteFD) = self.makePipeFileDescriptors()
        let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        let toChannel: NIOAsyncChannel<Never, ByteBuffer>
        let fromChannel: NIOAsyncChannel<ByteBuffer, Never>
        let didCallChannelInitializer = NIOLockedValueBox(0)

        do {
            channel = try await NIOPipeBootstrap(group: eventLoopGroup)
                .channelInitializer { channel in
                    didCallChannelInitializer.withLockedValue { $0 += 1 }
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                .takingOwnershipOfDescriptors(
                    input: pipe1ReadFD,
                    output: pipe2WriteFD
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            for fileDescriptor in [pipe1ReadFD, pipe1WriteFD, pipe2ReadFD, pipe2WriteFD] {
                try SystemCalls.close(descriptor: fileDescriptor)
            }
            throw error
        }

        do {
            toChannel = try await NIOPipeBootstrap(group: eventLoopGroup)
                .channelInitializer { channel in
                    didCallChannelInitializer.withLockedValue { $0 += 1 }
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                .takingOwnershipOfDescriptor(
                    output: pipe1WriteFD
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            for fileDescriptor in [pipe1WriteFD, pipe2ReadFD] {
                try SystemCalls.close(descriptor: fileDescriptor)
            }
            throw error
        }

        do {
            fromChannel = try await NIOPipeBootstrap(group: eventLoopGroup)
                .channelInitializer { channel in
                    didCallChannelInitializer.withLockedValue { $0 += 1 }
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                .takingOwnershipOfDescriptor(
                    input: pipe2ReadFD
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            for fileDescriptor in [pipe2ReadFD] {
                try SystemCalls.close(descriptor: fileDescriptor)
            }
            throw error
        }

        try await channel.executeThenClose { channelInbound, channelOutbound in
            try await fromChannel.executeThenClose { fromChannelInbound, _ in
                try await toChannel.executeThenClose { _, toChannelOutbound in
                    var inboundIterator = channelInbound.makeAsyncIterator()
                    var fromChannelInboundIterator = fromChannelInbound.makeAsyncIterator()

                    try await toChannelOutbound.write(.init(string: "Request"))
                    try await XCTAsyncAssertEqual(try await inboundIterator.next(), ByteBuffer(string: "Request"))

                    let response = ByteBuffer(string: "Response")
                    try await channelOutbound.write(response)
                    try await XCTAsyncAssertEqual(try await fromChannelInboundIterator.next(), response)
                }
            }
        }

        XCTAssertEqual(didCallChannelInitializer.withLockedValue { $0 }, 3)
    }

    func testPipeBootstrap_whenInputNil_callsChannelInitializer() async throws {
        let eventLoopGroup = self.group!
        let (pipe1ReadFD, pipe1WriteFD) = self.makePipeFileDescriptors()
        let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        let fromChannel: NIOAsyncChannel<ByteBuffer, Never>
        let didCallChannelInitializer = NIOLockedValueBox(0)

        do {
            channel = try await NIOPipeBootstrap(group: eventLoopGroup)
                .channelInitializer { channel in
                    didCallChannelInitializer.withLockedValue { $0 += 1 }
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                .takingOwnershipOfDescriptor(
                    output: pipe1WriteFD
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            for fileDescriptor in [pipe1ReadFD, pipe1WriteFD] {
                try SystemCalls.close(descriptor: fileDescriptor)
            }
            throw error
        }

        do {
            fromChannel = try await NIOPipeBootstrap(group: eventLoopGroup)
                .channelInitializer { channel in
                    didCallChannelInitializer.withLockedValue { $0 += 1 }
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                .takingOwnershipOfDescriptor(
                    input: pipe1ReadFD
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            for fileDescriptor in [pipe1WriteFD] {
                try SystemCalls.close(descriptor: fileDescriptor)
            }
            throw error
        }

        try await channel.executeThenClose { channelInbound, channelOutbound in
            try await fromChannel.executeThenClose { fromChannelInbound, _ in
                var inboundIterator = channelInbound.makeAsyncIterator()
                var fromChannelInboundIterator = fromChannelInbound.makeAsyncIterator()

                try await XCTAsyncAssertEqual(try await inboundIterator.next(), nil)

                let response = ByteBuffer(string: "Response")
                try await channelOutbound.write(response)
                try await XCTAsyncAssertEqual(try await fromChannelInboundIterator.next(), response)
            }
        }

        XCTAssertEqual(didCallChannelInitializer.withLockedValue { $0 }, 2)
    }

    func testPipeBootstrap_whenOutputNil_callsChannelInitializer() async throws {
        let eventLoopGroup = self.group!
        let (pipe1ReadFD, pipe1WriteFD) = self.makePipeFileDescriptors()
        let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        let toChannel: NIOAsyncChannel<Never, ByteBuffer>
        let didCallChannelInitializer = NIOLockedValueBox(0)

        do {
            channel = try await NIOPipeBootstrap(group: eventLoopGroup)
                .channelInitializer { channel in
                    didCallChannelInitializer.withLockedValue { $0 += 1 }
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                .takingOwnershipOfDescriptor(
                    input: pipe1ReadFD
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            for fileDescriptor in [pipe1ReadFD, pipe1WriteFD] {
                try SystemCalls.close(descriptor: fileDescriptor)
            }

            throw error
        }

        do {
            toChannel = try await NIOPipeBootstrap(group: eventLoopGroup)
                .channelInitializer { channel in
                    didCallChannelInitializer.withLockedValue { $0 += 1 }
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                .takingOwnershipOfDescriptor(
                    output: pipe1WriteFD
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                    }
                }
        } catch {
            for fileDescriptor in [pipe1WriteFD] {
                try SystemCalls.close(descriptor: fileDescriptor)
            }
            throw error
        }

        try await channel.executeThenClose { channelInbound, channelOutbound in
            try await toChannel.executeThenClose { _, toChannelOutbound in
                var inboundIterator = channelInbound.makeAsyncIterator()

                try await toChannelOutbound.write(.init(string: "Request"))
                try await XCTAsyncAssertEqual(try await inboundIterator.next(), ByteBuffer(string: "Request"))

                let response = ByteBuffer(string: "Response")
                await XCTAsyncAssertThrowsError(try await channelOutbound.write(response)) { error in
                    XCTAssertEqual(error as? NIOAsyncWriterError, .alreadyFinished())
                }
            }
        }

        XCTAssertEqual(didCallChannelInitializer.withLockedValue { $0 }, 2)
    }

    // MARK: RawSocket bootstrap

    func testRawSocketBootstrap() async throws {
        try XCTSkipIfUserHasNotEnoughRightsForRawSocketAPI()
        let eventLoopGroup = self.group!

        let serverChannel = try await self.makeRawSocketServerChannel(eventLoopGroup: eventLoopGroup)
        let clientChannel = try await self.makeRawSocketClientChannel(eventLoopGroup: eventLoopGroup)

        try await serverChannel.executeThenClose { serverChannelInbound, serverChannelOutbound in
            try await clientChannel.executeThenClose { clientChannelInbound, clientChannelOutbound in
                var serverInboundIterator = serverChannelInbound.makeAsyncIterator()
                var clientInboundIterator = clientChannelInbound.makeAsyncIterator()

                try await clientChannelOutbound.write("request")
                try await XCTAsyncAssertEqual(try await serverInboundIterator.next(), "request")

                try await serverChannelOutbound.write("response")
                try await XCTAsyncAssertEqual(try await clientInboundIterator.next(), "response")
            }
        }
    }

    func testRawSocketBootstrap_withProtocolNegotiation() async throws {
        try XCTSkipIfUserHasNotEnoughRightsForRawSocketAPI()
        let eventLoopGroup = self.group!

        try await withThrowingTaskGroup(of: EventLoopFuture<NegotiationResult>.self) { group in
            group.addTask {
                // We have to use a fixed port here since we only get the channel once protocol negotiation is done
                try await Self.makeRawSocketServerChannelWithProtocolNegotiation(
                    eventLoopGroup: eventLoopGroup
                )
            }

            // We need to sleep here since we can only connect the client after the server started.
            try await Task.sleep(nanoseconds: 100_000_000)

            group.addTask {
                try await Self.makeRawSocketClientChannelWithProtocolNegotiation(
                    eventLoopGroup: eventLoopGroup,
                    proposedALPN: .string
                )
            }

            let firstNegotiationResult = try await group.next()
            let secondNegotiationResult = try await group.next()

            switch (try await firstNegotiationResult?.get(), try await secondNegotiationResult?.get()) {
            case (.string(let firstChannel), .string(let secondChannel)):
                try await firstChannel.executeThenClose { firstChannelInbound, firstChannelOutbound in
                    try await secondChannel.executeThenClose { secondChannelInbound, secondChannelOutbound in
                        var firstInboundIterator = firstChannelInbound.makeAsyncIterator()
                        var secondInboundIterator = secondChannelInbound.makeAsyncIterator()

                        try await firstChannelOutbound.write("request")
                        try await XCTAsyncAssertEqual(try await secondInboundIterator.next(), "request")

                        try await secondChannelOutbound.write("response")
                        try await XCTAsyncAssertEqual(try await firstInboundIterator.next(), "response")
                    }
                }

            default:
                preconditionFailure()
            }
        }
    }

    // MARK: VSock

    func testVSock() async throws {
        try XCTSkipUnless(System.supportsVsockLoopback, "No vsock loopback transport available")
        let eventLoopGroup = self.group!

        let port = VsockAddress.Port(1234)

        let serverChannel = try await ServerBootstrap(group: eventLoopGroup)
            .bind(
                to: VsockAddress(cid: .any, port: port)
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(LineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(ByteBufferToStringHandler())
                    return try NIOAsyncChannel<String, String>(wrappingChannelSynchronously: channel)
                }
            }

        #if canImport(Darwin)
        let connectAddress = VsockAddress(cid: .any, port: port)
        #elseif os(Linux) || os(Android)
        let connectAddress = VsockAddress(cid: .local, port: port)
        #endif

        try await withThrowingTaskGroup(of: Void.self) { group in
            let (stream, continuation) = AsyncStream<StringOrByte>.makeStream()
            var iterator = stream.makeAsyncIterator()

            group.addTask {
                try await withThrowingTaskGroup(of: Void.self) { _ in
                    try await serverChannel.executeThenClose { inbound in
                        for try await childChannel in inbound {
                            try await childChannel.executeThenClose { childChannelInbound, _ in
                                for try await value in childChannelInbound {
                                    continuation.yield(.string(value))
                                }
                            }
                        }
                    }
                }
            }

            let stringChannel = try await ClientBootstrap(group: eventLoopGroup)
                .connect(to: connectAddress) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDelimiterCoder()))
                        try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(LineDelimiterCoder()))
                        try channel.pipeline.syncOperations.addHandler(ByteBufferToStringHandler())
                        return try NIOAsyncChannel<String, String>(wrappingChannelSynchronously: channel)
                    }
                }
            try await stringChannel.executeThenClose { _, outbound in
                try await outbound.write("hello")
            }

            await XCTAsyncAssertEqual(await iterator.next(), .string("hello"))

            group.cancelAll()
        }
    }

    // MARK: - Test Helpers

    private func makePipeFileDescriptors() -> (
        pipe1ReadFD: CInt, pipe1WriteFD: CInt, pipe2ReadFD: CInt, pipe2WriteFD: CInt
    ) {
        var pipe1FDs: [CInt] = [-1, -1]
        pipe1FDs.withUnsafeMutableBufferPointer { ptr in
            XCTAssertEqual(0, pipe(ptr.baseAddress!))
        }
        var pipe2FDs: [CInt] = [-1, -1]
        pipe2FDs.withUnsafeMutableBufferPointer { ptr in
            XCTAssertEqual(0, pipe(ptr.baseAddress!))
        }
        return (pipe1FDs[0], pipe1FDs[1], pipe2FDs[0], pipe2FDs[1])
    }

    private func makePipeFileDescriptors() -> (pipeReadFD: CInt, pipeWriteFD: CInt) {
        var pipeFDs: [CInt] = [-1, -1]
        pipeFDs.withUnsafeMutableBufferPointer { ptr in
            XCTAssertEqual(0, pipe(ptr.baseAddress!))
        }
        return (pipeFDs[0], pipeFDs[1])
    }

    private func makeRawSocketServerChannel(
        eventLoopGroup: EventLoopGroup
    ) async throws -> NIOAsyncChannel<String, String> {
        try await NIORawSocketBootstrap(group: eventLoopGroup)
            .bind(
                host: "127.0.0.1",
                ipProtocol: .reservedForTesting
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(IPHeaderRemoverHandler())
                    try channel.pipeline.syncOperations.addHandler(
                        AddressedEnvelopingHandler(remoteAddress: SocketAddress(ipAddress: "127.0.0.1", port: 0))
                    )
                    try channel.pipeline.syncOperations.addHandler(
                        ByteToMessageHandler(LineDelimiterCoder(inboundID: 1))
                    )
                    try channel.pipeline.syncOperations.addHandler(
                        MessageToByteHandler(LineDelimiterCoder(outboundID: 2))
                    )
                    try channel.pipeline.syncOperations.addHandler(ByteBufferToStringHandler())
                    return try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                }
            }
    }

    private func makeRawSocketClientChannel(
        eventLoopGroup: EventLoopGroup
    ) async throws -> NIOAsyncChannel<String, String> {
        try await NIORawSocketBootstrap(group: eventLoopGroup)
            .connect(
                host: "127.0.0.1",
                ipProtocol: .reservedForTesting
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(IPHeaderRemoverHandler())
                    try channel.pipeline.syncOperations.addHandler(
                        AddressedEnvelopingHandler(remoteAddress: SocketAddress(ipAddress: "127.0.0.1", port: 0))
                    )
                    try channel.pipeline.syncOperations.addHandler(
                        ByteToMessageHandler(LineDelimiterCoder(inboundID: 2))
                    )
                    try channel.pipeline.syncOperations.addHandler(
                        MessageToByteHandler(LineDelimiterCoder(outboundID: 1))
                    )
                    try channel.pipeline.syncOperations.addHandler(ByteBufferToStringHandler())
                    return try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                }
            }
    }

    private static func makeRawSocketServerChannelWithProtocolNegotiation(
        eventLoopGroup: EventLoopGroup
    ) async throws -> EventLoopFuture<NegotiationResult> {
        try await NIORawSocketBootstrap(group: eventLoopGroup)
            .bind(
                host: "127.0.0.1",
                ipProtocol: .reservedForTesting
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(IPHeaderRemoverHandler())
                    try channel.pipeline.syncOperations.addHandler(
                        AddressedEnvelopingHandler(remoteAddress: SocketAddress(ipAddress: "127.0.0.1", port: 0))
                    )
                    return try Self.configureProtocolNegotiationHandlers(
                        channel: channel,
                        proposedALPN: nil,
                        inboundID: 1,
                        outboundID: 2
                    )
                }
            }
    }

    private static func makeRawSocketClientChannelWithProtocolNegotiation(
        eventLoopGroup: EventLoopGroup,
        proposedALPN: TLSUserEventHandler.ALPN
    ) async throws -> EventLoopFuture<NegotiationResult> {
        try await NIORawSocketBootstrap(group: eventLoopGroup)
            .connect(
                host: "127.0.0.1",
                ipProtocol: .reservedForTesting
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(IPHeaderRemoverHandler())
                    try channel.pipeline.syncOperations.addHandler(
                        AddressedEnvelopingHandler(remoteAddress: SocketAddress(ipAddress: "127.0.0.1", port: 0))
                    )
                    return try Self.configureProtocolNegotiationHandlers(
                        channel: channel,
                        proposedALPN: proposedALPN,
                        inboundID: 2,
                        outboundID: 1
                    )
                }
            }
    }

    private func makeClientChannel(
        eventLoopGroup: EventLoopGroup,
        port: Int
    ) async throws -> NIOAsyncChannel<String, String> {
        try await ClientBootstrap(group: eventLoopGroup)
            .connect(
                to: .init(ipAddress: "127.0.0.1", port: port)
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(AddressedEnvelopingHandler())
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(LineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(ByteBufferToStringHandler())
                    return try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                }
            }
    }

    private func makeClientChannel(
        eventLoopGroup: EventLoopGroup,
        fileDescriptor: CInt
    ) async throws -> NIOAsyncChannel<String, String> {
        try await ClientBootstrap(group: eventLoopGroup)
            .withConnectedSocket(fileDescriptor) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(AddressedEnvelopingHandler())
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(LineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(ByteBufferToStringHandler())
                    return try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                }
            }
    }

    private func makeClientChannelWithProtocolNegotiation(
        eventLoopGroup: EventLoopGroup,
        port: Int,
        proposedALPN: TLSUserEventHandler.ALPN
    ) async throws -> EventLoopFuture<NegotiationResult> {
        try await ClientBootstrap(group: eventLoopGroup)
            .connect(
                to: .init(ipAddress: "127.0.0.1", port: port)
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try Self.configureProtocolNegotiationHandlers(channel: channel, proposedALPN: proposedALPN)
                }
            }
    }

    private func makeClientChannelWithNestedProtocolNegotiation(
        eventLoopGroup: EventLoopGroup,
        port: Int,
        proposedOuterALPN: TLSUserEventHandler.ALPN,
        proposedInnerALPN: TLSUserEventHandler.ALPN
    ) async throws -> EventLoopFuture<EventLoopFuture<NegotiationResult>> {
        try await ClientBootstrap(group: eventLoopGroup)
            .connect(
                to: .init(ipAddress: "127.0.0.1", port: port)
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try Self.configureNestedProtocolNegotiationHandlers(
                        channel: channel,
                        proposedOuterALPN: proposedOuterALPN,
                        proposedInnerALPN: proposedInnerALPN
                    )
                }
            }
    }

    private func makeUDPServerChannel(eventLoopGroup: EventLoopGroup) async throws -> NIOAsyncChannel<String, String> {
        try await DatagramBootstrap(group: eventLoopGroup)
            .bind(
                host: "127.0.0.1",
                port: 0
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(AddressedEnvelopingHandler())
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(LineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(ByteBufferToStringHandler())
                    return try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                }
            }
    }

    private static func makeUDPServerChannelWithProtocolNegotiation(
        eventLoopGroup: EventLoopGroup,
        port: Int,
        proposedALPN: TLSUserEventHandler.ALPN? = nil
    ) async throws -> EventLoopFuture<NegotiationResult> {
        try await DatagramBootstrap(group: eventLoopGroup)
            .bind(
                host: "127.0.0.1",
                port: port
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(AddressedEnvelopingHandler())
                    return try Self.configureProtocolNegotiationHandlers(channel: channel, proposedALPN: proposedALPN)
                }
            }
    }

    private func makeUDPClientChannel(
        eventLoopGroup: EventLoopGroup,
        port: Int
    ) async throws -> NIOAsyncChannel<String, String> {
        try await DatagramBootstrap(group: eventLoopGroup)
            .connect(
                host: "127.0.0.1",
                port: port
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(AddressedEnvelopingHandler())
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(LineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(ByteBufferToStringHandler())
                    return try NIOAsyncChannel(wrappingChannelSynchronously: channel)
                }
            }
    }

    private static func makeUDPClientChannelWithProtocolNegotiation(
        eventLoopGroup: EventLoopGroup,
        port: Int,
        proposedALPN: TLSUserEventHandler.ALPN
    ) async throws -> EventLoopFuture<NegotiationResult> {
        try await DatagramBootstrap(group: eventLoopGroup)
            .connect(
                host: "127.0.0.1",
                port: port
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(AddressedEnvelopingHandler())
                    return try Self.configureProtocolNegotiationHandlers(channel: channel, proposedALPN: proposedALPN)
                }
            }
    }

    @discardableResult
    private static func configureProtocolNegotiationHandlers(
        channel: Channel,
        proposedALPN: TLSUserEventHandler.ALPN? = nil,
        inboundID: UInt8? = nil,
        outboundID: UInt8? = nil
    ) throws -> EventLoopFuture<NegotiationResult> {
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDelimiterCoder(inboundID: inboundID)))
        try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(LineDelimiterCoder(outboundID: outboundID)))
        try channel.pipeline.syncOperations.addHandler(TLSUserEventHandler(proposedALPN: proposedALPN))
        return try self.addTypedApplicationProtocolNegotiationHandler(to: channel)
    }

    @discardableResult
    private static func configureNestedProtocolNegotiationHandlers(
        channel: Channel,
        proposedOuterALPN: TLSUserEventHandler.ALPN? = nil,
        proposedInnerALPN: TLSUserEventHandler.ALPN? = nil
    ) throws -> EventLoopFuture<EventLoopFuture<NegotiationResult>> {
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDelimiterCoder()))
        try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(LineDelimiterCoder()))
        try channel.pipeline.syncOperations.addHandler(TLSUserEventHandler(proposedALPN: proposedOuterALPN))
        let negotiationHandler = NIOTypedApplicationProtocolNegotiationHandler<EventLoopFuture<NegotiationResult>> {
            alpnResult,
            channel in
            switch alpnResult {
            case .negotiated(let alpn):
                switch alpn {
                case "string":
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            TLSUserEventHandler(proposedALPN: proposedInnerALPN)
                        )
                        let negotiationFuture = try Self.addTypedApplicationProtocolNegotiationHandler(to: channel)

                        return negotiationFuture
                    }
                case "byte":
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            TLSUserEventHandler(proposedALPN: proposedInnerALPN)
                        )
                        let negotiationHandler = try Self.addTypedApplicationProtocolNegotiationHandler(to: channel)

                        return negotiationHandler
                    }
                default:
                    return channel.close().flatMapThrowing { throw ProtocolNegotiationError() }
                }
            case .fallback:
                return channel.close().flatMapThrowing { throw ProtocolNegotiationError() }
            }
        }
        try channel.pipeline.syncOperations.addHandler(negotiationHandler)
        return negotiationHandler.protocolNegotiationResult
    }

    @discardableResult
    private static func addTypedApplicationProtocolNegotiationHandler(
        to channel: Channel
    ) throws -> EventLoopFuture<NegotiationResult> {
        let negotiationHandler = NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult> {
            alpnResult,
            channel in
            switch alpnResult {
            case .negotiated(let alpn):
                switch alpn {
                case "string":
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(ByteBufferToStringHandler())
                        let asyncChannel = try NIOAsyncChannel<String, String>(
                            wrappingChannelSynchronously: channel
                        )

                        return .string(asyncChannel)
                    }
                case "byte":
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(ByteBufferToByteHandler())

                        let asyncChannel = try NIOAsyncChannel<UInt8, UInt8>(
                            wrappingChannelSynchronously: channel
                        )

                        return .byte(asyncChannel)
                    }
                default:
                    return channel.close().flatMapThrowing { throw ProtocolNegotiationError() }
                }
            case .fallback:
                return channel.close().flatMapThrowing { throw ProtocolNegotiationError() }
            }
        }

        try channel.pipeline.syncOperations.addHandler(negotiationHandler)
        return negotiationHandler.protocolNegotiationResult
    }

    override func setUp() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 3)
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.group.syncShutdownGracefully())
        self.group = nil
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension AsyncStream {
    static func makeStream(
        of elementType: Element.Type = Element.self,
        bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded
    ) -> (stream: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation) {
        var continuation: AsyncStream<Element>.Continuation!
        let stream = AsyncStream<Element>(bufferingPolicy: limit) { continuation = $0 }
        return (stream: stream, continuation: continuation!)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private func XCTAsyncAssertEqual<Element: Equatable>(
    _ lhs: @autoclosure () async throws -> Element,
    _ rhs: @autoclosure () async throws -> Element,
    file: StaticString = #filePath,
    line: UInt = #line
) async rethrows {
    let lhsResult = try await lhs()
    let rhsResult = try await rhs()
    XCTAssertEqual(lhsResult, rhsResult, file: file, line: line)
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private func XCTAsyncAssertThrowsError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (_ error: Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
