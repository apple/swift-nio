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

import XCTest
@testable import NIOCore
import NIOEmbedded
import NIOHTTP1
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
        return self.getString(at: self.readerIndex, length: self.readableBytes)!
    }
}

extension EmbeddedChannel {
    func writeString(_ string: String) -> EventLoopFuture<Void> {
        return self.writeAndFlush(self.allocator.buffer(string: string))
    }
}

private func interactInMemory(_ first: EmbeddedChannel,
                              _ second: EmbeddedChannel,
                              eventLoop: EmbeddedEventLoop) throws {
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
        let frame = self.unwrapInboundIn(data)
        self.frames.append(frame)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.errors.append(error)
        context.fireErrorCaught(error)
    }
}

class WebSocketServerEndToEndTests: XCTestCase {
    private func createTestFixtures(upgraders: [NIOWebSocketServerUpgrader]) -> (loop: EmbeddedEventLoop, serverChannel: EmbeddedChannel, clientChannel: EmbeddedChannel) {
        let loop = EmbeddedEventLoop()
        let serverChannel = EmbeddedChannel(loop: loop)
        XCTAssertNoThrow(try serverChannel.pipeline.configureHTTPServerPipeline(
            withServerUpgrade: (upgraders: upgraders as [HTTPServerProtocolUpgrader], completionHandler: { (context: ChannelHandlerContext) in } )
        ).wait())
        let clientChannel = EmbeddedChannel(loop: loop)
        return (loop: loop, serverChannel: serverChannel, clientChannel: clientChannel)
    }

    private func upgradeRequest(path: String = "/", extraHeaders: [String: String], protocolName: String = "websocket") -> String {
        let extraHeaderString = extraHeaders.map { hdr in "\(hdr.key): \(hdr.value)" }.joined(separator: "\r\n")
        return "GET \(path) HTTP/1.1\r\nHost: example.com\r\nConnection: upgrade\r\nUpgrade: \(protocolName)\r\n" + extraHeaderString + "\r\n\r\n"
    }

    func testBasicUpgradeDance() throws {
        let basicUpgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
                                              upgradePipelineHandler: { (channel, req) in channel.eventLoop.makeSucceededFuture(()) })
        let (loop, server, client) = self.createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())

        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        loop.run()

        XCTAssertNoThrow(assertResponseIs(response: try client.readAllInboundBuffers().allAsString(),
                                          expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                                          expectedResponseHeaders: ["Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade"]))
    }

    func testUpgradeWithProtocolName() throws {
        let basicUpgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
                                              upgradePipelineHandler: { (channel, req) in channel.eventLoop.makeSucceededFuture(()) })
        let (loop, server, client) = self.createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="], protocolName: "WebSocket")
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertNoThrow(assertResponseIs(response: try client.readAllInboundBuffers().allAsString(),
                                          expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                                          expectedResponseHeaders: ["Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade"]))
    }

    func testCanRejectUpgrade() throws {
        let basicUpgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(nil) },
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

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
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
        var acceptPromise: EventLoopPromise<HTTPHeaders?>? = nil
        var upgradeComplete = false

        let basicUpgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { (channel, head) in
                                                  acceptPromise = channel.eventLoop.makePromise()
                                                  return acceptPromise!.futureResult
                                              },
                                              upgradePipelineHandler: { (channel, req) in
                                                  upgradeComplete = true
                                                  return channel.eventLoop.makeSucceededFuture(())
                                              })
        let (loop, server, client) = self.createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        XCTAssertNil(acceptPromise)

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertNotNil(acceptPromise)

        // No upgrade should have occurred yet.
        XCTAssertNoThrow(XCTAssertNil(try client.readInbound(as: ByteBuffer.self)))
        XCTAssertFalse(upgradeComplete)

        // Satisfy the promise. This will cause the upgrade to complete.
        acceptPromise?.succeed(HTTPHeaders())
        loop.run()
        XCTAssertTrue(upgradeComplete)
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertNoThrow(assertResponseIs(response: try client.readAllInboundBuffers().allAsString(),
                                          expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                                          expectedResponseHeaders: ["Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade"]))
    }

    func testRequiresVersion13() throws {
        let basicUpgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
                                              upgradePipelineHandler: { (channel, req) in channel.eventLoop.makeSucceededFuture(()) })
        let (loop, server, client) = self.createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "12", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        let buffer = server.allocator.buffer(string: upgradeRequest)

        // Write this directly to the server.
        XCTAssertThrowsError(try server.writeInbound(buffer)) { error in
            XCTAssertEqual(.invalidUpgradeHeader, error as? NIOWebSocketUpgradeError)
        }

        // Nothing gets written.
        XCTAssertNoThrow(XCTAssertEqual(try server.readAllOutboundBuffers().allAsString(), ""))
    }

    func testRequiresVersionHeader() throws {
        let basicUpgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
                                              upgradePipelineHandler: { (channel, req) in channel.eventLoop.makeSucceededFuture(()) })
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
        let basicUpgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
                                              upgradePipelineHandler: { (channel, req) in channel.eventLoop.makeSucceededFuture(()) })
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
        let upgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { (channel, head) in
                                            var hdrs = HTTPHeaders()
                                            hdrs.add(name: "TestHeader", value: "TestValue")
                                            return channel.eventLoop.makeSucceededFuture(hdrs)
                                         },
                                         upgradePipelineHandler: { (channel, req) in channel.eventLoop.makeSucceededFuture(()) })
        let (loop, server, client) = self.createTestFixtures(upgraders: [upgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertNoThrow(assertResponseIs(response: try client.readAllInboundBuffers().allAsString(),
                                          expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                                          expectedResponseHeaders: ["Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade", "TestHeader: TestValue"]))
    }

    func testMayRegisterMultipleWebSocketEndpoints() throws {
        func buildHandler(path: String) -> NIOWebSocketServerUpgrader {
            return NIOWebSocketServerUpgrader(shouldUpgrade: { (channel, head) in
                                         guard head.uri == "/\(path)" else { return channel.eventLoop.makeSucceededFuture(nil) }
                                         var hdrs = HTTPHeaders()
                                         hdrs.add(name: "Target", value: path)
                                         return channel.eventLoop.makeSucceededFuture(hdrs)
                                     },
                                     upgradePipelineHandler: { (channel, req) in channel.eventLoop.makeSucceededFuture(()) })
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

        let upgradeRequest = self.upgradeRequest(path: "/third", extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertNoThrow(assertResponseIs(response: try client.readAllInboundBuffers().allAsString(),
                                          expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                                          expectedResponseHeaders: ["Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade", "Target: third"]))
    }

    func testSendAFewFrames() throws {
        let recorder = WebSocketRecorderHandler()
        let basicUpgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
                                              upgradePipelineHandler: { (channel, req) in
                                                channel.pipeline.addHandler(recorder)

        })
        let (loop, server, client) = self.createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertNoThrow(assertResponseIs(response: try client.readAllInboundBuffers().allAsString(),
                                          expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                                          expectedResponseHeaders: ["Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade"]))

        // Put a frame encoder in the client pipeline.
        XCTAssertNoThrow(try client.pipeline.addHandler(WebSocketFrameEncoder()).wait())

        var data = client.allocator.buffer(capacity: 12)
        data.writeString("hello, world")

        // Let's send a frame or two, to confirm that this works.
        let dataFrame = WebSocketFrame(fin: true, opcode: .binary, data: data)
        XCTAssertNoThrow(try client.writeAndFlush(dataFrame).wait())

        let pingFrame = WebSocketFrame(fin: true, opcode: .ping, data: client.allocator.buffer(capacity: 0))
        XCTAssertNoThrow(try client.writeAndFlush(pingFrame).wait())
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertEqual(recorder.frames, [dataFrame, pingFrame])
    }

    func testMaxFrameSize() throws {
        let basicUpgrader = NIOWebSocketServerUpgrader(maxFrameSize: 16, shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
                                              upgradePipelineHandler: { (channel, req) in
            return channel.eventLoop.makeSucceededFuture(())
        })
        let (loop, server, client) = self.createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertNoThrow(assertResponseIs(response: try client.readAllInboundBuffers().allAsString(),
                                          expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                                          expectedResponseHeaders: ["Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade"]))

        let decoder = ((try server.pipeline.context(handlerType: ByteToMessageHandler<WebSocketFrameDecoder>.self).wait()).handler as! ByteToMessageHandler<WebSocketFrameDecoder>).decoder
        XCTAssertEqual(16, decoder?.maxFrameSize)
    }

    func testAutomaticErrorHandling() throws {
        let recorder = WebSocketRecorderHandler()
        let basicUpgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
                                              upgradePipelineHandler: { (channel, req) in
                                                channel.pipeline.addHandler(recorder)

        })
        let (loop, server, client) = self.createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finishAcceptingAlreadyClosed())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertNoThrow(assertResponseIs(response: try client.readAllInboundBuffers().allAsString(),
                                          expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                                          expectedResponseHeaders: ["Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade"]))

        // Send a fake frame header that claims this is a ping frame with 126 bytes of data.
        var data = client.allocator.buffer(capacity: 12)
        data.writeBytes([0x89, 0x7E, 0x00, 0x7E])
        XCTAssertNoThrow(try client.writeAndFlush(data).wait())

        XCTAssertThrowsError(try interactInMemory(client, server, eventLoop: loop)) { error in
            XCTAssertEqual(NIOWebSocketError.multiByteControlFrameLength, error as? NIOWebSocketError)
        }

        XCTAssertEqual(recorder.errors.count, 1)
        XCTAssertEqual(recorder.errors.first as? NIOWebSocketError, .some(.multiByteControlFrameLength))

        // The client should have received a close frame, if we'd continued interacting.
        XCTAssertNoThrow(XCTAssertEqual(try server.readAllOutboundBytes(), [0x88, 0x02, 0x03, 0xEA]))
    }

    func testNoAutomaticErrorHandling() throws {
        let recorder = WebSocketRecorderHandler()
        let basicUpgrader = NIOWebSocketServerUpgrader(automaticErrorHandling: false,
                                              shouldUpgrade: { (channel, head) in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
                                              upgradePipelineHandler: { (channel, req) in
                                                channel.pipeline.addHandler(recorder)

        })
        let (loop, server, client) = self.createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finishAcceptingAlreadyClosed())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server, eventLoop: loop))

        XCTAssertNoThrow(assertResponseIs(response: try client.readAllInboundBuffers().allAsString(),
                                          expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                                          expectedResponseHeaders: ["Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade"]))

        // Send a fake frame header that claims this is a ping frame with 126 bytes of data.
        var data = client.allocator.buffer(capacity: 12)
        data.writeBytes([0x89, 0x7E, 0x00, 0x7E])
        XCTAssertNoThrow(try client.writeAndFlush(data).wait())

        XCTAssertThrowsError(try interactInMemory(client, server, eventLoop: loop)) { error in
            XCTAssertEqual(NIOWebSocketError.multiByteControlFrameLength, error as? NIOWebSocketError)
        }

        XCTAssertEqual(recorder.errors.count, 1)
        XCTAssertEqual(recorder.errors.first as? NIOWebSocketError, .some(.multiByteControlFrameLength))

        // The client should not have received a close frame, if we'd continued interacting.
        XCTAssertNoThrow(XCTAssertEqual([], try server.readAllOutboundBytes()))
    }
}
