//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers
@_spi(AsyncChannel) import NIOCore
@_spi(AsyncChannel) @testable import NIOPosix
import XCTest
@_spi(AsyncChannel) import NIOTLS

private final class LineDelimiterDecoder: ByteToMessageDecoder {
    private let newLine = "\n".utf8.first!

    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let readable = buffer.withUnsafeReadableBytes { $0.firstIndex(of: self.newLine) }
        if let readable = readable {
            context.fireChannelRead(self.wrapInboundOut(buffer.readSlice(length: readable)!))
            buffer.moveReaderIndex(forwardBy: 1)
            return .continue
        }
        return .needMoreData
    }
}

private final class TLSUserEventHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        let alpn = String(buffer: buffer)

        if alpn.hasPrefix("alpn:") {
            context.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: String(alpn.dropFirst(5))))
        } else {
            context.fireChannelRead(data)
        }
    }
}

private final class ByteBufferToStringHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = String

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        context.fireChannelRead(self.wrapInboundOut(String(buffer: buffer)))
    }
}

private final class ByteBufferToByteHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = UInt8

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = self.unwrapInboundIn(data)
        let byte = buffer.readInteger(as: UInt8.self)!
        context.fireChannelRead(self.wrapInboundOut(byte))
    }
}

final class AsyncChannelBootstrapTests: XCTestCase {
    enum NegotiationResult {
        case string(NIOAsyncChannel<String, String>)
        case byte(NIOAsyncChannel<UInt8, UInt8>)
    }

    struct ProtocolNegotiationError: Error {}

    enum StringOrByte: Hashable {
        case string(String)
        case byte(UInt8)
    }

    func testAsyncChannel() throws {
        XCTAsyncTest {
            let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 3)

            let channel = try await ServerBootstrap(group: eventLoopGroup)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.autoRead, value: true)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDelimiterDecoder()))
                        try channel.pipeline.syncOperations.addHandler(ByteBufferToStringHandler())
                    }
                }
                .bind(
                    host: "127.0.0.1",
                    port: 0,
                    childChannelInboundType: String.self,
                    childChannelOutboundType: String.self
                )

            try await withThrowingTaskGroup(of: Void.self) { group in
                let (stream, continuation) = AsyncStream<StringOrByte>.makeStream()
                var iterator = stream.makeAsyncIterator()

                group.addTask {
                    try await withThrowingTaskGroup(of: Void.self) { _ in
                        for try await childChannel in channel.inboundStream {
                            for try await value in childChannel.inboundStream {
                                continuation.yield(.string(value))
                            }
                        }
                    }
                }

                let stringChannel = try await self.makeClientChannel(eventLoopGroup: eventLoopGroup, port: channel.channel.localAddress!.port!)
                stringChannel.writeAndFlush(.init(ByteBuffer(string: "hello\n")), promise: nil)

                await XCTAsyncAssertEqual(await iterator.next(), .string("hello"))

                group.cancelAll()
            }
        }
    }

    func testAsyncChannelProtocolNegotiation() throws {
        XCTAsyncTest {
            let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 3)

            let channel: NIOAsyncChannel<NegotiationResult, Never> = try await ServerBootstrap(group: eventLoopGroup)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.autoRead, value: true)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try self.makeProtocolNegotiationChildChannel(channel: channel)
                    }
                }
                .bind(
                    host: "127.0.0.1",
                    port: 0,
                    protocolNegotiationHandlerType: NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult>.self
                )

            try await withThrowingTaskGroup(of: Void.self) { group in
                let (stream, continuation) = AsyncStream<StringOrByte>.makeStream()
                var iterator = stream.makeAsyncIterator()

                group.addTask {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for try await childChannel in channel.inboundStream {
                            group.addTask {
                                switch childChannel {
                                case .string(let channel):
                                    for try await value in channel.inboundStream {
                                        continuation.yield(.string(value))
                                    }
                                case .byte(let channel):
                                    for try await value in channel.inboundStream {
                                        continuation.yield(.byte(value))
                                    }
                                }
                            }
                        }
                    }
                }

                let stringChannel = try await self.makeClientChannel(eventLoopGroup: eventLoopGroup, port: channel.channel.localAddress!.port!)

                // This is for negotiating the protocol
                stringChannel.writeAndFlush(.init(ByteBuffer(string: "alpn:string\n")), promise: nil)

                // This is the actual content
                stringChannel.writeAndFlush(.init(ByteBuffer(string: "hello\n")), promise: nil)

                await XCTAsyncAssertEqual(await iterator.next(), .string("hello"))

                let byteChannel = try await self.makeClientChannel(eventLoopGroup: eventLoopGroup, port: channel.channel.localAddress!.port!)

                // This is for negotiating the protocol
                byteChannel.writeAndFlush(.init(ByteBuffer(string: "alpn:byte\n")), promise: nil)

                // This is the actual content
                byteChannel.write(.init(ByteBuffer(integer: UInt8(8))), promise: nil)
                byteChannel.writeAndFlush(.init(ByteBuffer(string: "\n")), promise: nil)

                await XCTAsyncAssertEqual(await iterator.next(), .byte(8))

                group.cancelAll()
            }
        }
    }

    func testAsyncChannelNestedProtocolNegotiation() throws {
        XCTAsyncTest {
            let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 3)

            let channel: NIOAsyncChannel<NegotiationResult, Never> = try await ServerBootstrap(group: eventLoopGroup)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.autoRead, value: true)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try self.makeNestedProtocolNegotiationChildChannel(channel: channel)
                    }
                }
                .bind(
                    host: "127.0.0.1",
                    port: 0,
                    protocolNegotiationHandlerType: NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult>.self
                )

            try await withThrowingTaskGroup(of: Void.self) { group in
                let (stream, continuation) = AsyncStream<StringOrByte>.makeStream()
                var iterator = stream.makeAsyncIterator()

                group.addTask {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for try await childChannel in channel.inboundStream {
                            group.addTask {
                                switch childChannel {
                                case .string(let channel):
                                    for try await value in channel.inboundStream {
                                        continuation.yield(.string(value))
                                    }
                                case .byte(let channel):
                                    for try await value in channel.inboundStream {
                                        continuation.yield(.byte(value))
                                    }
                                }
                            }
                        }
                    }
                }

                let stringStringChannel = try await self.makeClientChannel(eventLoopGroup: eventLoopGroup, port: channel.channel.localAddress!.port!)

                // This is for negotiating the protocol
                stringStringChannel.writeAndFlush(.init(ByteBuffer(string: "alpn:string\n")), promise: nil)

                // This is for negotiating the nested protocol
                stringStringChannel.writeAndFlush(.init(ByteBuffer(string: "alpn:string\n")), promise: nil)

                // This is the actual content
                stringStringChannel.writeAndFlush(.init(ByteBuffer(string: "hello\n")), promise: nil)

                await XCTAsyncAssertEqual(await iterator.next(), .string("hello"))

                let byteByteChannel = try await self.makeClientChannel(eventLoopGroup: eventLoopGroup, port: channel.channel.localAddress!.port!)

                // This is for negotiating the protocol
                byteByteChannel.writeAndFlush(.init(ByteBuffer(string: "alpn:byte\n")), promise: nil)

                // This is for negotiating the nested protocol
                byteByteChannel.writeAndFlush(.init(ByteBuffer(string: "alpn:byte\n")), promise: nil)

                // This is the actual content
                byteByteChannel.write(.init(ByteBuffer(integer: UInt8(8))), promise: nil)
                byteByteChannel.writeAndFlush(.init(ByteBuffer(string: "\n")), promise: nil)

                await XCTAsyncAssertEqual(await iterator.next(), .byte(8))

                let stringByteChannel = try await self.makeClientChannel(eventLoopGroup: eventLoopGroup, port: channel.channel.localAddress!.port!)

                // This is for negotiating the protocol
                stringByteChannel.writeAndFlush(.init(ByteBuffer(string: "alpn:string\n")), promise: nil)

                // This is for negotiating the nested protocol
                stringByteChannel.writeAndFlush(.init(ByteBuffer(string: "alpn:byte\n")), promise: nil)

                // This is the actual content
                stringByteChannel.write(.init(ByteBuffer(integer: UInt8(8))), promise: nil)
                stringByteChannel.writeAndFlush(.init(ByteBuffer(string: "\n")), promise: nil)

                await XCTAsyncAssertEqual(await iterator.next(), .byte(8))

                let byteStringChannel = try await self.makeClientChannel(eventLoopGroup: eventLoopGroup, port: channel.channel.localAddress!.port!)

                // This is for negotiating the protocol
                byteStringChannel.writeAndFlush(.init(ByteBuffer(string: "alpn:byte\n")), promise: nil)

                // This is for negotiating the nested protocol
                byteStringChannel.writeAndFlush(.init(ByteBuffer(string: "alpn:string\n")), promise: nil)

                // This is the actual content
                byteStringChannel.writeAndFlush(.init(ByteBuffer(string: "hello\n")), promise: nil)

                await XCTAsyncAssertEqual(await iterator.next(), .string("hello"))

                group.cancelAll()
            }
        }
    }

    func testAsyncChannelProtocolNegotiation_whenFails() throws {
        final class CollectingHandler: ChannelInboundHandler {
            typealias InboundIn = Channel

            private let channels: NIOLockedValueBox<[Channel]>

            init(channels: NIOLockedValueBox<[Channel]>) {
                self.channels = channels
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let channel = self.unwrapInboundIn(data)

                self.channels.withLockedValue { $0.append(channel) }

                context.fireChannelRead(data)
            }
        }
        XCTAsyncTest {
            let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 3)
            let channels = NIOLockedValueBox<[Channel]>([Channel]())

            let channel: NIOAsyncChannel<NegotiationResult, Never> = try await ServerBootstrap(group: eventLoopGroup)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .serverChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(CollectingHandler(channels: channels))
                    }
                }
                .childChannelOption(ChannelOptions.autoRead, value: true)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try self.makeProtocolNegotiationChildChannel(channel: channel)
                    }
                }
                .bind(
                    host: "127.0.0.1",
                    port: 0,
                    protocolNegotiationHandlerType: NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult>.self
                )

            try await withThrowingTaskGroup(of: Void.self) { group in
                let (stream, continuation) = AsyncStream<StringOrByte>.makeStream()
                var iterator = stream.makeAsyncIterator()

                group.addTask {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for try await childChannel in channel.inboundStream {
                            group.addTask {
                                switch childChannel {
                                case .string(let channel):
                                    for try await value in channel.inboundStream {
                                        continuation.yield(.string(value))
                                    }
                                case .byte(let channel):
                                    for try await value in channel.inboundStream {
                                        continuation.yield(.byte(value))
                                    }
                                }
                            }
                        }
                    }
                }

                let unknownChannel = try await self.makeClientChannel(eventLoopGroup: eventLoopGroup, port: channel.channel.localAddress!.port!)

                // This is for negotiating the protocol
                unknownChannel.writeAndFlush(.init(ByteBuffer(string: "alpn:unknown\n")), promise: nil)

                // Checking that we can still create new connections afterwards
                let stringChannel = try await self.makeClientChannel(eventLoopGroup: eventLoopGroup, port: channel.channel.localAddress!.port!)

                // This is for negotiating the protocol
                stringChannel.writeAndFlush(.init(ByteBuffer(string: "alpn:string\n")), promise: nil)

                // This is the actual content
                stringChannel.writeAndFlush(.init(ByteBuffer(string: "hello\n")), promise: nil)

                await XCTAsyncAssertEqual(await iterator.next(), .string("hello"))

                let failedInboundChannel = channels.withLockedValue { channels -> Channel in
                    XCTAssertEqual(channels.count, 2)
                    return channels[0]
                }

                // We are waiting here to make sure the channel got closed
                try await failedInboundChannel.closeFuture.get()

                group.cancelAll()
            }
        }
    }

    // MARK: - Test Helpers

    private func makeClientChannel(eventLoopGroup: EventLoopGroup, port: Int) async throws -> Channel {
        return try await ClientBootstrap(group: eventLoopGroup)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDelimiterDecoder()))
                }
            }
            .connect(to: .init(ipAddress: "127.0.0.1", port: port))
            .get()
    }

    private func makeProtocolNegotiationChildChannel(channel: Channel) throws {
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDelimiterDecoder()))
        try channel.pipeline.syncOperations.addHandler(TLSUserEventHandler())
        try self.addTypedApplicationProtocolNegotiationHandler(to: channel)
    }

    private func makeNestedProtocolNegotiationChildChannel(channel: Channel) throws {
        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(LineDelimiterDecoder()))
        try channel.pipeline.syncOperations.addHandler(TLSUserEventHandler())
        try channel.pipeline.syncOperations.addHandler(
            NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult>(eventLoop: channel.eventLoop) { alpnResult, channel in
                switch alpnResult {
                case .negotiated(let alpn):
                    switch alpn {
                    case "string":
                        return channel.eventLoop.makeCompletedFuture {
                            let negotiationFuture = try self.addTypedApplicationProtocolNegotiationHandler(to: channel)

                            return NIOProtocolNegotiationResult.deferredResult(negotiationFuture)
                        }
                    case "byte":
                        return channel.eventLoop.makeCompletedFuture {
                            let negotiationFuture = try self.addTypedApplicationProtocolNegotiationHandler(to: channel)

                            return NIOProtocolNegotiationResult.deferredResult(negotiationFuture)
                        }
                    default:
                        return channel.eventLoop.makeFailedFuture(ProtocolNegotiationError())
                    }
                case .fallback:
                    return channel.eventLoop.makeFailedFuture(ProtocolNegotiationError())
                }
            }
        )
    }

    @discardableResult
    private func addTypedApplicationProtocolNegotiationHandler(to channel: Channel) throws -> EventLoopFuture<NIOProtocolNegotiationResult<NegotiationResult>> {
        let negotiationHandler = NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult>(eventLoop: channel.eventLoop) { alpnResult, channel in
            switch alpnResult {
            case .negotiated(let alpn):
                switch alpn {
                case "string":
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(ByteBufferToStringHandler())
                        let asyncChannel = try NIOAsyncChannel(
                            synchronouslyWrapping: channel,
                            isOutboundHalfClosureEnabled: true,
                            inboundType: String.self,
                            outboundType: String.self
                        )

                        return NIOProtocolNegotiationResult.finished(NegotiationResult.string(asyncChannel))
                    }
                case "byte":
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(ByteBufferToByteHandler())

                        let asyncChannel = try NIOAsyncChannel(
                            synchronouslyWrapping: channel,
                            isOutboundHalfClosureEnabled: true,
                            inboundType: UInt8.self,
                            outboundType: UInt8.self
                        )

                        return NIOProtocolNegotiationResult.finished(NegotiationResult.byte(asyncChannel))
                    }
                default:
                    return channel.eventLoop.makeFailedFuture(ProtocolNegotiationError())
                }
            case .fallback:
                return channel.eventLoop.makeFailedFuture(ProtocolNegotiationError())
            }
        }

        try channel.pipeline.syncOperations.addHandler(negotiationHandler)
        return negotiationHandler.protocolNegotiationResult
    }
}

extension AsyncStream {
    fileprivate static func makeStream(
        of elementType: Element.Type = Element.self,
        bufferingPolicy limit: Continuation.BufferingPolicy = .unbounded
    ) -> (stream: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation) {
        var continuation: AsyncStream<Element>.Continuation!
        let stream = AsyncStream<Element>(bufferingPolicy: limit) { continuation = $0 }
        return (stream: stream, continuation: continuation!)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private func XCTAsyncAssertEqual<Element: Equatable>(_ lhs: @autoclosure () async throws -> Element, _ rhs: @autoclosure () async throws -> Element, file: StaticString = #filePath, line: UInt = #line) async rethrows {
    let lhsResult = try await lhs()
    let rhsResult = try await rhs()
    XCTAssertEqual(lhsResult, rhsResult, file: file, line: line)
}
