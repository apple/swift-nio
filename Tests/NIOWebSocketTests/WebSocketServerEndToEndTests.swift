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

import NIOConcurrencyHelpers
import NIOEmbedded
import NIOHTTP1
import XCTest

@testable import NIOCore
@testable import NIOWebSocket

extension EmbeddedChannel {
    func readAllInboundBuffers() throws -> ByteBuffer {
        var buffer = self.allocator.buffer(capacity: 100)
        while var writtenData: ByteBuffer = try self.readInbound() {
            buffer.writeBuffer(&writtenData)
        }

        return buffer
    }

    func finishAcceptingAlreadyClosed() throws {
        do {
            let result = try self.finish().isClean
            XCTAssertTrue(result)
        } catch ChannelError.alreadyClosed {
            // ok
        }
    }
}

extension ByteBuffer {
    func allAsString() -> String {
        self.getString(at: self.readerIndex, length: self.readableBytes)!
    }
}

extension EmbeddedChannel {
    func writeString(_ string: String) -> EventLoopFuture<Void> {
        self.writeAndFlush(self.allocator.buffer(string: string))
    }
}

private func interactInMemory(
    _ first: EmbeddedChannel,
    _ second: EmbeddedChannel,
    eventLoop: EmbeddedEventLoop
) throws {
    var operated: Bool

    repeat {
        eventLoop.run()
        operated = false

        if let data = try first.readOutbound(as: ByteBuffer.self) {
            operated = true
            try second.writeInbound(data)
        }
        if let data = try second.readOutbound(as: ByteBuffer.self) {
            operated = true
            try first.writeInbound(data)
        }
    } while operated
}

private func assertResponseIs(response: String, expectedResponseLine: String, expectedResponseHeaders: [String]) {
    var lines = response.split(separator: "\r\n", omittingEmptySubsequences: false).map { String($0) }

    // We never expect a response body here. This means we need the last two entries to be empty strings.
    XCTAssertEqual("", lines.removeLast())
    XCTAssertEqual("", lines.removeLast())

    // Check the response line is correct.
    let actualResponseLine = lines.removeFirst()
    XCTAssertEqual(expectedResponseLine, actualResponseLine)

    // For each header, find it in the actual response headers and remove it.
    for expectedHeader in expectedResponseHeaders {
        guard let index = lines.firstIndex(of: expectedHeader) else {
            XCTFail("Could not find header \"\(expectedHeader)\"")
            return
        }
        lines.remove(at: index)
    }

    // That should be all the headers.
    XCTAssertEqual(lines.count, 0)
}

private class WebSocketRecorderHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    fileprivate var frames: [WebSocketFrame] = []
    fileprivate var errors: [Error] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = Self.unwrapInboundIn(data)
        self.frames.append(frame)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.errors.append(error)
        context.fireErrorCaught(error)
    }
}

struct WebSocketServerUpgraderConfiguration {
    let maxFrameSize: Int
    let automaticErrorHandling: Bool
    let shouldUpgrade: @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?>
    let upgradePipelineHandler: @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<Void>

    @preconcurrency
    init(
        maxFrameSize: Int = 1 << 14,
        automaticErrorHandling: Bool = true,
        shouldUpgrade: @escaping @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?>,
        upgradePipelineHandler: @escaping @Sendable (Channel, HTTPRequestHead) -> EventLoopFuture<Void>
    ) {
        self.maxFrameSize = maxFrameSize
        self.automaticErrorHandling = automaticErrorHandling
        self.shouldUpgrade = shouldUpgrade
        self.upgradePipelineHandler = upgradePipelineHandler
    }
}

class WebSocketServerEndToEndTests: XCTestCase {
    func createTestFixtures(
        upgraders: [WebSocketServerUpgraderConfiguration],
        loop: EmbeddedEventLoop? = nil
    ) -> (loop: EmbeddedEventLoop, serverChannel: EmbeddedChannel, clientChannel: EmbeddedChannel) {
        let loop = loop ?? EmbeddedEventLoop()
        let serverChannel = EmbeddedChannel(loop: loop)
        let upgraders: [HTTPServerProtocolUpgrader & Sendable] = upgraders.map {
            NIOWebSocketServerUpgrader(
                maxFrameSize: $0.maxFrameSize,
                automaticErrorHandling: $0.automaticErrorHandling,
                shouldUpgrade: $0.shouldUpgrade,
                upgradePipelineHandler: $0.upgradePipelineHandler
            )
        }
        XCTAssertNoThrow(
            try serverChannel.pipeline.configureHTTPServerPipeline(
                withServerUpgrade: (
                    upgraders: upgraders,
                    completionHandler: { (context: ChannelHandlerContext) in }
                )
            ).wait()
        )
        let clientChannel = EmbeddedChannel(loop: loop)
        return (loop: loop, serverChannel: serverChannel, clientChannel: clientChannel)
    }

    private func upgradeRequest(
        path: String = "/",
        extraHeaders: [String: String],
        protocolName: String = "websocket"
    ) -> String {
        let extraHeaderString = extraHeaders.map { hdr in "\(hdr.key): \(hdr.value)" }.joined(separator: "\r\n")
        return "GET \(path) HTTP/1.1\r\nHost: example.com\r\nConnection: upgrade\r\nUpgrade: \(protocolName)\r\n"
            + extraHeaderString + "\r\n\r\n"
    }

    func testBasicUpgradeDance() throws {
        let basicUpgrader = WebSocketServerUpgraderConfiguration(
            shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
            upgradePipelineHandler: { (channel, req) in channel.eventLoop.makeSucceededFuture(()) }
        )
        let (loop, server, client) = self.createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: [
            "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC==",
        ])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())

        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        loop.run()

        XCTAssertNoThrow(
            assertResponseIs(
                response: try client.readAllInboundBuffers().allAsString(),
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: [
                    "Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade",
                ]
            )
        )
    }

    func testUpgradeWithProtocolName() throws {
        let basicUpgrader = WebSocketServerUpgraderConfiguration(
            shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
            upgradePipelineHandler: { (channel, req) in channel.eventLoop.makeSucceededFuture(()) }
        )
        let (loop, server, client) = self.createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(
            extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="],
            protocolName: "WebSocket"
        )
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertNoThrow(
            assertResponseIs(
                response: try client.readAllInboundBuffers().allAsString(),
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: [
                    "Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade",
                ]
            )
        )
    }

    func testCanRejectUpgrade() throws {
        let basicUpgrader = WebSocketServerUpgraderConfiguration(
            shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(nil) },
            upgradePipelineHandler: { (channel, req) in
                XCTFail("Should not have called")
                return channel.eventLoop.makeSucceededFuture(())
            }
        )
        let (loop, server, client) = self.createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: [
            "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC==",
        ])
        let buffer = server.allocator.buffer(string: upgradeRequest)

        // Write this directly to the server.
        XCTAssertThrowsError(try server.writeInbound(buffer)) { error in
            XCTAssertEqual(.unsupportedWebSocketTarget, error as? NIOWebSocketUpgradeError)
        }

        // Nothing gets written.
        XCTAssertNoThrow(XCTAssertEqual(try server.readAllOutboundBuffers().allAsString(), ""))
    }

    func testCanDelayAcceptingUpgrade() throws {
        // This accept promise is going to be written to from a callback. This is only safe because we use
        // embedded channels.
        let acceptPromise = NIOLockedValueBox<EventLoopPromise<HTTPHeaders?>?>(nil)
        let upgradeComplete = NIOLockedValueBox(false)

        let basicUpgrader = WebSocketServerUpgraderConfiguration(
            shouldUpgrade: { (channel, head) in
                let promise = channel.eventLoop.makePromise(of: Optional<HTTPHeaders>.self)
                acceptPromise.withLockedValue { $0 = promise }
                return promise.futureResult
            },
            upgradePipelineHandler: { (channel, req) in
                upgradeComplete.withLockedValue { $0 = true }
                return channel.eventLoop.makeSucceededFuture(())
            }
        )
        let (loop, server, client) = self.createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        XCTAssertNil(acceptPromise.withLockedValue { $0 })

        let upgradeRequest = self.upgradeRequest(extraHeaders: [
            "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC==",
        ])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertNotNil(acceptPromise)

        // No upgrade should have occurred yet.
        XCTAssertNoThrow(XCTAssertNil(try client.readInbound(as: ByteBuffer.self)))
        XCTAssertFalse(upgradeComplete.withLockedValue { $0 })

        // Satisfy the promise. This will cause the upgrade to complete.
        acceptPromise.withLockedValue { $0?.succeed(HTTPHeaders()) }
        loop.run()
        XCTAssertTrue(upgradeComplete.withLockedValue { $0 })
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertNoThrow(
            assertResponseIs(
                response: try client.readAllInboundBuffers().allAsString(),
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: [
                    "Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade",
                ]
            )
        )
    }

    func testRequiresVersion13() throws {
        let basicUpgrader = WebSocketServerUpgraderConfiguration(
            shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
            upgradePipelineHandler: { (channel, req) in channel.eventLoop.makeSucceededFuture(()) }
        )
        let (loop, server, client) = self.createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: [
            "Sec-WebSocket-Version": "12", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC==",
        ])
        let buffer = server.allocator.buffer(string: upgradeRequest)

        // Write this directly to the server.
        XCTAssertThrowsError(try server.writeInbound(buffer)) { error in
            XCTAssertEqual(.invalidUpgradeHeader, error as? NIOWebSocketUpgradeError)
        }

        // Nothing gets written.
        XCTAssertNoThrow(XCTAssertEqual(try server.readAllOutboundBuffers().allAsString(), ""))
    }

    func testRequiresVersionHeader() throws {
        let basicUpgrader = WebSocketServerUpgraderConfiguration(
            shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
            upgradePipelineHandler: { (channel, req) in channel.eventLoop.makeSucceededFuture(()) }
        )
        let (loop, server, client) = self.createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        let buffer = server.allocator.buffer(string: upgradeRequest)

        // Write this directly to the server.
        XCTAssertThrowsError(try server.writeInbound(buffer)) { error in
            XCTAssertEqual(.invalidUpgradeHeader, error as? NIOWebSocketUpgradeError)
        }

        // Nothing gets written.
        XCTAssertNoThrow(XCTAssertEqual(try server.readAllOutboundBuffers().allAsString(), ""))
    }

    func testRequiresKeyHeader() throws {
        let basicUpgrader = WebSocketServerUpgraderConfiguration(
            shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
            upgradePipelineHandler: { (channel, req) in channel.eventLoop.makeSucceededFuture(()) }
        )
        let (loop, server, client) = self.createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "13"])
        let buffer = server.allocator.buffer(string: upgradeRequest)

        // Write this directly to the server.
        XCTAssertThrowsError(try server.writeInbound(buffer)) { error in
            XCTAssertEqual(.invalidUpgradeHeader, error as? NIOWebSocketUpgradeError)
        }

        // Nothing gets written.
        XCTAssertNoThrow(XCTAssertEqual(try server.readAllOutboundBuffers().allAsString(), ""))
    }

    func testUpgradeMayAddCustomHeaders() throws {
        let upgrader = WebSocketServerUpgraderConfiguration(
            shouldUpgrade: { (channel, head) in
                var hdrs = HTTPHeaders()
                hdrs.add(name: "TestHeader", value: "TestValue")
                return channel.eventLoop.makeSucceededFuture(hdrs)
            },
            upgradePipelineHandler: { (channel, req) in channel.eventLoop.makeSucceededFuture(()) }
        )
        let (loop, server, client) = self.createTestFixtures(upgraders: [upgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: [
            "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC==",
        ])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertNoThrow(
            assertResponseIs(
                response: try client.readAllInboundBuffers().allAsString(),
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: [
                    "Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade",
                    "TestHeader: TestValue",
                ]
            )
        )
    }

    func testMayRegisterMultipleWebSocketEndpoints() throws {
        func buildHandler(path: String) -> WebSocketServerUpgraderConfiguration {
            WebSocketServerUpgraderConfiguration(
                shouldUpgrade: { (channel, head) in
                    guard head.uri == "/\(path)" else { return channel.eventLoop.makeSucceededFuture(nil) }
                    var hdrs = HTTPHeaders()
                    hdrs.add(name: "Target", value: path)
                    return channel.eventLoop.makeSucceededFuture(hdrs)
                },
                upgradePipelineHandler: { (channel, req) in channel.eventLoop.makeSucceededFuture(()) }
            )
        }
        let first = buildHandler(path: "first")
        let second = buildHandler(path: "second")
        let third = buildHandler(path: "third")

        let (loop, server, client) = self.createTestFixtures(upgraders: [first, second, third])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(
            path: "/third",
            extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="]
        )
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertNoThrow(
            assertResponseIs(
                response: try client.readAllInboundBuffers().allAsString(),
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: [
                    "Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade",
                    "Target: third",
                ]
            )
        )
    }

    func testSendAFewFrames() throws {
        let embeddedEventLoop = EmbeddedEventLoop()
        let recorder = NIOLoopBound(WebSocketRecorderHandler(), eventLoop: embeddedEventLoop)

        let basicUpgrader = WebSocketServerUpgraderConfiguration(
            shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
            upgradePipelineHandler: { (channel, req) in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(recorder.value)
                }
            }
        )

        let (loop, server, client) = self.createTestFixtures(upgraders: [basicUpgrader], loop: embeddedEventLoop)
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: [
            "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC==",
        ])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertNoThrow(
            assertResponseIs(
                response: try client.readAllInboundBuffers().allAsString(),
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: [
                    "Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade",
                ]
            )
        )

        // Put a frame encoder in the client pipeline.
        XCTAssertNoThrow(try client.pipeline.syncOperations.addHandler(WebSocketFrameEncoder()))

        var data = client.allocator.buffer(capacity: 12)
        data.writeString("hello, world")

        // Let's send a frame or two, to confirm that this works.
        let dataFrame = WebSocketFrame(fin: true, opcode: .binary, data: data)
        XCTAssertNoThrow(try client.writeAndFlush(dataFrame).wait())

        let pingFrame = WebSocketFrame(fin: true, opcode: .ping, data: client.allocator.buffer(capacity: 0))
        XCTAssertNoThrow(try client.writeAndFlush(pingFrame).wait())
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertEqual(recorder.value.frames, [dataFrame, pingFrame])
    }

    func testMaxFrameSize() throws {
        let basicUpgrader = WebSocketServerUpgraderConfiguration(
            maxFrameSize: 16,
            shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
            upgradePipelineHandler: { (channel, req) in
                channel.eventLoop.makeSucceededFuture(())
            }
        )
        let (loop, server, client) = self.createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: [
            "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC==",
        ])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertNoThrow(
            assertResponseIs(
                response: try client.readAllInboundBuffers().allAsString(),
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: [
                    "Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade",
                ]
            )
        )

        let decoder =
            ((try server.pipeline.syncOperations.context(handlerType: ByteToMessageHandler<WebSocketFrameDecoder>.self))
            .handler as! ByteToMessageHandler<WebSocketFrameDecoder>).decoder
        XCTAssertEqual(16, decoder?.maxFrameSize)
    }

    func testAutomaticErrorHandling() throws {
        let embeddedEventLoop = EmbeddedEventLoop()
        let recorder = NIOLoopBound(WebSocketRecorderHandler(), eventLoop: embeddedEventLoop)

        let basicUpgrader = WebSocketServerUpgraderConfiguration(
            shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
            upgradePipelineHandler: { (channel, req) in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(recorder.value)
                }
            }
        )
        let (loop, server, client) = self.createTestFixtures(upgraders: [basicUpgrader], loop: embeddedEventLoop)
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finishAcceptingAlreadyClosed())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: [
            "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC==",
        ])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertNoThrow(
            assertResponseIs(
                response: try client.readAllInboundBuffers().allAsString(),
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: [
                    "Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade",
                ]
            )
        )

        // Send a fake frame header that claims this is a ping frame with 126 bytes of data.
        var data = client.allocator.buffer(capacity: 12)
        data.writeBytes([0x89, 0x7E, 0x00, 0x7E])
        XCTAssertNoThrow(try client.writeAndFlush(data).wait())

        XCTAssertThrowsError(try interactInMemory(client, server, eventLoop: loop)) { error in
            XCTAssertEqual(NIOWebSocketError.multiByteControlFrameLength, error as? NIOWebSocketError)
        }

        XCTAssertEqual(recorder.value.errors.count, 1)
        XCTAssertEqual(recorder.value.errors.first as? NIOWebSocketError, .some(.multiByteControlFrameLength))

        // The client should have received a close frame, if we'd continued interacting.
        XCTAssertNoThrow(XCTAssertEqual(try server.readAllOutboundBytes(), [0x88, 0x02, 0x03, 0xEA]))
    }

    func testNoAutomaticErrorHandling() throws {
        let embeddedEventLoop = EmbeddedEventLoop()
        let recorder = NIOLoopBound(WebSocketRecorderHandler(), eventLoop: embeddedEventLoop)

        let basicUpgrader = WebSocketServerUpgraderConfiguration(
            automaticErrorHandling: false,
            shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
            upgradePipelineHandler: { (channel, req) in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(recorder.value)
                }
            }
        )
        let (loop, server, client) = self.createTestFixtures(upgraders: [basicUpgrader], loop: embeddedEventLoop)
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finishAcceptingAlreadyClosed())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: [
            "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC==",
        ])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertNoThrow(
            assertResponseIs(
                response: try client.readAllInboundBuffers().allAsString(),
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: [
                    "Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade",
                ]
            )
        )

        // Send a fake frame header that claims this is a ping frame with 126 bytes of data.
        var data = client.allocator.buffer(capacity: 12)
        data.writeBytes([0x89, 0x7E, 0x00, 0x7E])
        XCTAssertNoThrow(try client.writeAndFlush(data).wait())

        XCTAssertThrowsError(try interactInMemory(client, server, eventLoop: loop)) { error in
            XCTAssertEqual(NIOWebSocketError.multiByteControlFrameLength, error as? NIOWebSocketError)
        }

        XCTAssertEqual(recorder.value.errors.count, 1)
        XCTAssertEqual(recorder.value.errors.first as? NIOWebSocketError, .some(.multiByteControlFrameLength))

        // The client should not have received a close frame, if we'd continued interacting.
        XCTAssertNoThrow(XCTAssertEqual([], try server.readAllOutboundBytes()))
    }
}

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
final class TypedWebSocketServerEndToEndTests: WebSocketServerEndToEndTests {
    override func createTestFixtures(
        upgraders: [WebSocketServerUpgraderConfiguration],
        loop: EmbeddedEventLoop? = nil
    ) -> (loop: EmbeddedEventLoop, serverChannel: EmbeddedChannel, clientChannel: EmbeddedChannel) {
        let loop = loop ?? EmbeddedEventLoop()
        let serverChannel = EmbeddedChannel(loop: loop)
        let upgraders = upgraders.map {
            NIOTypedWebSocketServerUpgrader(
                maxFrameSize: $0.maxFrameSize,
                enableAutomaticErrorHandling: $0.automaticErrorHandling,
                shouldUpgrade: $0.shouldUpgrade,
                upgradePipelineHandler: $0.upgradePipelineHandler
            )
        }

        XCTAssertNoThrow(
            try serverChannel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                configuration: .init(
                    upgradeConfiguration: NIOTypedHTTPServerUpgradeConfiguration<Void>(
                        upgraders: upgraders,
                        notUpgradingCompletionHandler: { $0.eventLoop.makeSucceededVoidFuture() }
                    )
                )
            )
        )
        let clientChannel = EmbeddedChannel(loop: loop)
        return (loop: loop, serverChannel: serverChannel, clientChannel: clientChannel)
    }
}
