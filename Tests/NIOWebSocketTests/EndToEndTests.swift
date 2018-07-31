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

import XCTest
import NIO
import NIOHTTP1
@testable import NIOWebSocket

extension EmbeddedChannel {
    func readAllInboundBuffers() -> ByteBuffer {
        var buffer = self.allocator.buffer(capacity: 100)
        while var writtenData: ByteBuffer = self.readInbound() {
            buffer.write(buffer: &writtenData)
        }

        return buffer
    }

    func finishAcceptingAlreadyClosed() throws {
        do {
            try self.finish()
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
        var buffer = self.allocator.buffer(capacity: string.utf8.count)
        buffer.write(string: string)
        return self.writeAndFlush(buffer)
    }
}

private func interactInMemory(_ first: EmbeddedChannel, _ second: EmbeddedChannel) throws {
    var operated: Bool

    repeat {
        operated = false

        if case .some(.byteBuffer(let data)) = first.readOutbound() {
            operated = true
            try second.writeInbound(data)
        }
        if case .some(.byteBuffer(let data)) = second.readOutbound() {
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
        guard let index = lines.index(of: expectedHeader) else {
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

    public var frames: [WebSocketFrame] = []
    public var errors: [Error] = []

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        self.frames.append(frame)
    }

    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        self.errors.append(error)
        ctx.fireErrorCaught(error)
    }
}

class EndToEndTests: XCTestCase {
    func createTestFixtures(upgraders: [WebSocketUpgrader]) -> (loop: EmbeddedEventLoop, serverChannel: EmbeddedChannel, clientChannel: EmbeddedChannel) {
        let loop = EmbeddedEventLoop()
        let serverChannel = EmbeddedChannel(loop: loop)
        let upgradeConfig = (upgraders: upgraders as [HTTPProtocolUpgrader], completionHandler: { (ctx: ChannelHandlerContext) in } )
        XCTAssertNoThrow(try serverChannel.pipeline.configureHTTPServerPipeline(withServerUpgrade: upgradeConfig).wait())
        let clientChannel = EmbeddedChannel(loop: loop)
        return (loop: loop, serverChannel: serverChannel, clientChannel: clientChannel)
    }

    func upgradeRequest(path: String = "/", extraHeaders: [String: String], protocolName: String = "websocket") -> String {
        let extraHeaderString = extraHeaders.map { hdr in "\(hdr.key): \(hdr.value)" }.joined(separator: "\r\n")
        return "GET \(path) HTTP/1.1\r\nHost: example.com\r\nConnection: upgrade\r\nUpgrade: \(protocolName)\r\n" + extraHeaderString + "\r\n\r\n"
    }

    func testBasicUpgradeDance() throws {
        let basicUpgrader = WebSocketUpgrader(shouldUpgrade: { head in HTTPHeaders() },
                                              upgradePipelineHandler: { (channel, req) in channel.eventLoop.newSucceededFuture(result: ()) })
        let (loop, server, client) = createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server))

        let receivedResponse = client.readAllInboundBuffers().allAsString()
        assertResponseIs(response: receivedResponse,
                         expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                         expectedResponseHeaders: ["Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade"])
    }

    func testUpgradeWithProtocolName() throws {
        let basicUpgrader = WebSocketUpgrader(shouldUpgrade: { head in HTTPHeaders() },
                                              upgradePipelineHandler: { (channel, req) in channel.eventLoop.newSucceededFuture(result: ()) })
        let (loop, server, client) = createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="], protocolName: "WebSocket")
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server))

        let receivedResponse = client.readAllInboundBuffers().allAsString()
        assertResponseIs(response: receivedResponse,
                         expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                         expectedResponseHeaders: ["Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade"])
    }

    func testCanRejectUpgrade() throws {
        let basicUpgrader = WebSocketUpgrader(shouldUpgrade: { head in nil },
                                              upgradePipelineHandler: { (channel, req) in
                                                  XCTFail("Should not have called")
                                                  return channel.eventLoop.newSucceededFuture(result: ())
                                              }
        )
        let (loop, server, client) = createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        var buffer = server.allocator.buffer(capacity: upgradeRequest.utf8.count)
        buffer.write(string: upgradeRequest)

        // Write this directly to the server.
        do {
            try server.writeInbound(buffer)
            XCTFail("Did not throw")
        } catch NIOWebSocketUpgradeError.unsupportedWebSocketTarget {
            // ok
        } catch {
            XCTFail("Unexpected error hit: \(error)")
        }

        // Nothing gets written.
        XCTAssertEqual(server.readAllOutboundBuffers().allAsString(), "")
    }

    func testRequiresVersion13() throws {
        let basicUpgrader = WebSocketUpgrader(shouldUpgrade: { head in HTTPHeaders() },
                                              upgradePipelineHandler: { (channel, req) in channel.eventLoop.newSucceededFuture(result: ()) })
        let (loop, server, client) = createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "12", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        var buffer = server.allocator.buffer(capacity: upgradeRequest.utf8.count)
        buffer.write(string: upgradeRequest)

        // Write this directly to the server.
        do {
            try server.writeInbound(buffer)
            XCTFail("Did not throw")
        } catch NIOWebSocketUpgradeError.invalidUpgradeHeader {
            // ok
        } catch {
            XCTFail("Unexpected error hit: \(error)")
        }

        // Nothing gets written.
        XCTAssertEqual(server.readAllOutboundBuffers().allAsString(), "")
    }

    func testRequiresVersionHeader() throws {
        let basicUpgrader = WebSocketUpgrader(shouldUpgrade: { head in HTTPHeaders() },
                                              upgradePipelineHandler: { (channel, req) in channel.eventLoop.newSucceededFuture(result: ()) })
        let (loop, server, client) = createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        var buffer = server.allocator.buffer(capacity: upgradeRequest.utf8.count)
        buffer.write(string: upgradeRequest)

        // Write this directly to the server.
        do {
            try server.writeInbound(buffer)
            XCTFail("Did not throw")
        } catch NIOWebSocketUpgradeError.invalidUpgradeHeader {
            // ok
        } catch {
            XCTFail("Unexpected error hit: \(error)")
        }

        // Nothing gets written.
        XCTAssertEqual(server.readAllOutboundBuffers().allAsString(), "")
    }

    func testRequiresKeyHeader() throws {
        let basicUpgrader = WebSocketUpgrader(shouldUpgrade: { head in HTTPHeaders() },
                                              upgradePipelineHandler: { (channel, req) in channel.eventLoop.newSucceededFuture(result: ()) })
        let (loop, server, client) = createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "13"])
        var buffer = server.allocator.buffer(capacity: upgradeRequest.utf8.count)
        buffer.write(string: upgradeRequest)

        // Write this directly to the server.
        do {
            try server.writeInbound(buffer)
            XCTFail("Did not throw")
        } catch NIOWebSocketUpgradeError.invalidUpgradeHeader {
            // ok
        } catch {
            XCTFail("Unexpected error hit: \(error)")
        }

        // Nothing gets written.
        XCTAssertEqual(server.readAllOutboundBuffers().allAsString(), "")
    }

    func testUpgradeMayAddCustomHeaders() throws {
        let upgrader = WebSocketUpgrader(shouldUpgrade: { head in
                                            var hdrs = HTTPHeaders()
                                            hdrs.add(name: "TestHeader", value: "TestValue")
                                            return hdrs
                                         },
                                         upgradePipelineHandler: { (channel, req) in channel.eventLoop.newSucceededFuture(result: ()) })
        let (loop, server, client) = createTestFixtures(upgraders: [upgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server))

        let receivedResponse = client.readAllInboundBuffers().allAsString()
        assertResponseIs(response: receivedResponse,
                         expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                         expectedResponseHeaders: ["Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade", "TestHeader: TestValue"])
    }

    func testMayRegisterMultipleWebSocketEndpoints() throws {
        func buildHandler(path: String) -> WebSocketUpgrader {
            return WebSocketUpgrader(shouldUpgrade: { head in
                                         guard head.uri == "/\(path)" else { return nil }
                                         var hdrs = HTTPHeaders()
                                         hdrs.add(name: "Target", value: path)
                                         return hdrs
                                     },
                                     upgradePipelineHandler: { (channel, req) in channel.eventLoop.newSucceededFuture(result: ()) })
        }
        let first = buildHandler(path: "first")
        let second = buildHandler(path: "second")
        let third = buildHandler(path: "third")

        let (loop, server, client) = createTestFixtures(upgraders: [first, second, third])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(path: "/third", extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server))

        let receivedResponse = client.readAllInboundBuffers().allAsString()
        assertResponseIs(response: receivedResponse,
                         expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                         expectedResponseHeaders: ["Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade", "Target: third"])
    }

    func testSendAFewFrames() throws {
        let recorder = WebSocketRecorderHandler()
        let basicUpgrader = WebSocketUpgrader(shouldUpgrade: { head in HTTPHeaders() },
                                              upgradePipelineHandler: { (channel, req) in
                                                channel.pipeline.add(handler: recorder)

        })
        let (loop, server, client) = createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server))

        let receivedResponse = client.readAllInboundBuffers().allAsString()
        assertResponseIs(response: receivedResponse,
                         expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                         expectedResponseHeaders: ["Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade"])

        // Put a frame encoder in the client pipeline.
        XCTAssertNoThrow(try client.pipeline.add(handler: WebSocketFrameEncoder()).wait())

        var data = client.allocator.buffer(capacity: 12)
        data.write(string: "hello, world")

        // Let's send a frame or two, to confirm that this works.
        let dataFrame = WebSocketFrame(fin: true, opcode: .binary, data: data)
        XCTAssertNoThrow(try client.writeAndFlush(dataFrame).wait())

        let pingFrame = WebSocketFrame(fin: true, opcode: .ping, data: client.allocator.buffer(capacity: 0))
        XCTAssertNoThrow(try client.writeAndFlush(pingFrame).wait())
        XCTAssertNoThrow(try interactInMemory(client, server))

        XCTAssertEqual(recorder.frames, [dataFrame, pingFrame])
    }

    func testMaxFrameSize() throws {
        let basicUpgrader = WebSocketUpgrader(maxFrameSize: 16, shouldUpgrade: { head in HTTPHeaders() },
                                              upgradePipelineHandler: { (channel, req) in
            return channel.eventLoop.newSucceededFuture(result: ())
        })
        let (loop, server, client) = createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finish())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server))

        let receivedResponse = client.readAllInboundBuffers().allAsString()
        assertResponseIs(response: receivedResponse,
                         expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                         expectedResponseHeaders: ["Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade"])

        let decoder = (try server.pipeline.context(handlerType: WebSocketFrameDecoder.self).wait()).handler as! WebSocketFrameDecoder
        XCTAssertEqual(16, decoder.maxFrameSize)
    }

    func testAutomaticErrorHandling() throws {
        let recorder = WebSocketRecorderHandler()
        let basicUpgrader = WebSocketUpgrader(shouldUpgrade: { head in HTTPHeaders() },
                                              upgradePipelineHandler: { (channel, req) in
                                                channel.pipeline.add(handler: recorder)

        })
        let (loop, server, client) = createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finishAcceptingAlreadyClosed())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server))

        let receivedResponse = client.readAllInboundBuffers().allAsString()
        assertResponseIs(response: receivedResponse,
                         expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                         expectedResponseHeaders: ["Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade"])

        // Send a fake frame header that claims this is a ping frame with 126 bytes of data.
        var data = client.allocator.buffer(capacity: 12)
        data.write(bytes: [0x89, 0x7E, 0x00, 0x7E])
        XCTAssertNoThrow(try client.writeAndFlush(data).wait())

        do {
            try interactInMemory(client, server)
            XCTFail("Did not throw")
        } catch NIOWebSocketError.multiByteControlFrameLength {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(recorder.errors.count, 1)
        XCTAssertEqual(recorder.errors.first as? NIOWebSocketError, .some(.multiByteControlFrameLength))

        // The client should have received a close frame, if we'd continued interacting.
        let errorFrame = server.readAllOutboundBytes()
        XCTAssertEqual(errorFrame, [0x88, 0x02, 0x03, 0xEA])
    }

    func testNoAutomaticErrorHandling() throws {
        let recorder = WebSocketRecorderHandler()
        let basicUpgrader = WebSocketUpgrader(automaticErrorHandling: false,
                                              shouldUpgrade: { head in HTTPHeaders() },
                                              upgradePipelineHandler: { (channel, req) in
                                                channel.pipeline.add(handler: recorder)

        })
        let (loop, server, client) = createTestFixtures(upgraders: [basicUpgrader])
        defer {
            XCTAssertNoThrow(try client.finish())
            XCTAssertNoThrow(try server.finishAcceptingAlreadyClosed())
            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }

        let upgradeRequest = self.upgradeRequest(extraHeaders: ["Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "AQIDBAUGBwgJCgsMDQ4PEC=="])
        XCTAssertNoThrow(try client.writeString(upgradeRequest).wait())
        XCTAssertNoThrow(try interactInMemory(client, server))

        let receivedResponse = client.readAllInboundBuffers().allAsString()
        assertResponseIs(response: receivedResponse,
                         expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                         expectedResponseHeaders: ["Upgrade: websocket", "Sec-WebSocket-Accept: OfS0wDaT5NoxF2gqm7Zj2YtetzM=", "Connection: upgrade"])

        // Send a fake frame header that claims this is a ping frame with 126 bytes of data.
        var data = client.allocator.buffer(capacity: 12)
        data.write(bytes: [0x89, 0x7E, 0x00, 0x7E])
        XCTAssertNoThrow(try client.writeAndFlush(data).wait())

        do {
            try interactInMemory(client, server)
            XCTFail("Did not throw")
        } catch NIOWebSocketError.multiByteControlFrameLength {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(recorder.errors.count, 1)
        XCTAssertEqual(recorder.errors.first as? NIOWebSocketError, .some(.multiByteControlFrameLength))

        // The client should not have received a close frame, if we'd continued interacting.
        let errorFrame = server.readAllOutboundBytes()
        XCTAssertEqual(errorFrame, [])
    }
}
