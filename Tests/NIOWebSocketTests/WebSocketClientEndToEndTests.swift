//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the SwiftNIO project authors
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
    
    fileprivate func readByteBufferOutputAsString() throws -> String? {
        
        if let requestBuffer: ByteBuffer = try self.readOutbound() {
            return requestBuffer.getString(at: 0, length: requestBuffer.readableBytes)
        }
        
        return nil
    }
}

extension ChannelPipeline {
    
    fileprivate func assertDoesNotContain<Handler: ChannelHandler>(handlerType: Handler.Type,
                                                                   file: StaticString = #filePath,
                                                                   line: UInt = #line) throws {
        XCTAssertThrowsError(try self.syncOperations.context(handlerType: handlerType), file: (file), line: line) { error in
            XCTAssertEqual(.notFound, error as? ChannelPipelineError)
        }
    }
    
    fileprivate func assertContains<Handler: ChannelHandler>(handlerType: Handler.Type) throws {
        do {
            _ = try self.syncOperations.context(handlerType: handlerType)
        } catch ChannelPipelineError.notFound {
            XCTFail("Did not find handler")
        }
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

private func setUpClientChannel(clientHTTPHandler: RemovableChannelHandler,
                                clientUpgraders: [NIOHTTPClientProtocolUpgrader],
                                _ upgradeCompletionHandler: @escaping (ChannelHandlerContext) -> Void) throws -> EmbeddedChannel {
    
    let channel = EmbeddedChannel()
    
    let config: NIOHTTPClientUpgradeConfiguration = (
        upgraders: clientUpgraders,
        completionHandler: { context in
            channel.pipeline.removeHandler(clientHTTPHandler, promise: nil)
            upgradeCompletionHandler(context)
    })
    
    try channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config).flatMap({
        channel.pipeline.addHandler(clientHTTPHandler)
    }).wait()
    
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0))
        .wait()
    
    return channel
}

// A HTTP handler that will send an initial request which can be augmented by the upgrade handler.
private final class BasicHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    fileprivate typealias InboundIn = HTTPClientResponsePart
    fileprivate typealias OutboundOut = HTTPClientRequestPart
    
    fileprivate func channelActive(context: ChannelHandlerContext) {
        // We are connected. It's time to send the message to the server to initialise the upgrade dance.
        self.fireSendRequest(context: context)
    }
}

// A HTTP handler that will send a request and then fail if it receives a response or an error.
// It can be used when there is a successful upgrade as the handler should be removed by the upgrader.
private final class ExplodingHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    fileprivate typealias InboundIn = HTTPClientResponsePart
    fileprivate typealias OutboundOut = HTTPClientRequestPart
    
    fileprivate func channelActive(context: ChannelHandlerContext) {
        // We are connected. It's time to send the message to the server to initialise the upgrade dance.
        self.fireSendRequest(context: context)
    }
    
    fileprivate func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        XCTFail("Received unexpected read")
    }
    
    fileprivate func errorCaught(context: ChannelHandlerContext, error: Error) {
        XCTFail("Received unexpected error")
    }
}

extension ChannelInboundHandler where OutboundOut == HTTPClientRequestPart {
    
    fileprivate func fireSendRequest(context: ChannelHandlerContext) {
        
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(0)")
        
        let requestHead = HTTPRequestHead(version: .http1_1,
                                          method: .GET,
                                          uri: "/",
                                          headers: headers)
        
        context.write(self.wrapOutboundOut(.head(requestHead)), promise: nil)
        
        let emptyBuffer = context.channel.allocator.buffer(capacity: 0)
        let body = HTTPClientRequestPart.body(.byteBuffer(emptyBuffer))
        context.write(self.wrapOutboundOut(body), promise: nil)
        
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }
}

private class WebSocketRecorderHandler: ChannelInboundHandler, ChannelOutboundHandler {
    typealias OutboundIn = WebSocketFrame
    
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    public var frames: [WebSocketFrame] = []
    public var errors: [Error] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        self.frames.append(frame)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.errors.append(error)
        context.fireErrorCaught(error)
    }
}

private func basicRequest(path: String = "/") -> String {
    return "GET \(path) HTTP/1.1\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 0"
}

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
class WebSocketClientEndToEndTests: XCTestCase {
    func testSimpleUpgradeSucceeds() throws {

        var upgradeHandlerCallbackFired = false
        let requestKey = "OfS0wDaT5NoxF2gqm7Zj2YtetzM="
        let responseKey = "yKEqitDFPE81FyIhKTm+ojBqigk="

        let basicUpgrader = NIOWebSocketClientUpgrader(requestKey: requestKey,
                                                       upgradePipelineHandler: { (channel: Channel, _: HTTPResponseHead) in
                channel.pipeline.addHandler(WebSocketRecorderHandler())
        })

        // The process should kick-off independently by sending the upgrade request to the server.
        let clientChannel = try setUpClientChannel(clientHTTPHandler: ExplodingHTTPHandler(),
                                                   clientUpgraders: [basicUpgrader]) { _ in
                                                    
                                                    // This is called before the upgrader gets called.
                                                    upgradeHandlerCallbackFired = true
        }

        // Read the server request.
        if let requestString = try clientChannel.readByteBufferOutputAsString() {
            XCTAssertEqual(requestString, basicRequest() + "\r\nConnection: upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: \(requestKey)\r\nSec-WebSocket-Version: 13\r\n\r\n")
        } else {
            XCTFail()
        }
        
        // Push the successful server response.
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept:\(responseKey)\r\n\r\n"
        
        XCTAssertNoThrow(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response)))
        
        clientChannel.embeddedEventLoop.run()
        
        // Once upgraded, validate the http pipeline has been removed.
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: HTTPRequestEncoder.self))
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: NIOHTTPClientUpgradeHandler.self))
        
        // Check that the pipeline now has the correct websocket handlers added.
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertContains(handlerType: WebSocketFrameEncoder.self))
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertContains(handlerType: ByteToMessageHandler<WebSocketFrameDecoder>.self))
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertContains(handlerType: WebSocketRecorderHandler.self))
        
        XCTAssert(upgradeHandlerCallbackFired)
        
        // Close the pipeline.
        XCTAssertNoThrow(try clientChannel.close().wait())
    }

    func testRejectUpgradeIfMissingAcceptKey() throws {
        
        let requestKey = "OfS0wDaT5NoxF2gqm7Zj2YtetzM="
        
        let basicUpgrader = NIOWebSocketClientUpgrader(requestKey: requestKey,
                                                       upgradePipelineHandler: { (channel: Channel, _: HTTPResponseHead) in
                                                        channel.pipeline.addHandler(WebSocketRecorderHandler())
        })
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let clientChannel = try setUpClientChannel(clientHTTPHandler: BasicHTTPHandler(),
                                                   clientUpgraders: [basicUpgrader]) { _ in
        }

        // Push the successful server response but with a missing accept key.
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n"
        
        XCTAssertThrowsError(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response))) { error in
            XCTAssertEqual(.upgraderDeniedUpgrade, error as? NIOHTTPClientUpgradeError)
        }

        // Close the pipeline.
        XCTAssertNoThrow(try clientChannel.close().wait())
    }

    func testRejectUpgradeIfIncorrectAcceptKey() throws {
        
        let requestKey = "OfS0wDaT5NoxF2gqm7Zj2YtetzM="
        let responseKey = "notACorrectKeyL1am=F1y=nn="
        
        let basicUpgrader = NIOWebSocketClientUpgrader(requestKey: requestKey,
                                                       upgradePipelineHandler: { (channel: Channel, _: HTTPResponseHead) in
                                                        channel.pipeline.addHandler(WebSocketRecorderHandler())
        })
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let clientChannel = try setUpClientChannel(clientHTTPHandler: BasicHTTPHandler(),
                                                   clientUpgraders: [basicUpgrader]) { _ in
        }

        // Push the successful server response but with an incorrect response key.
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept:\(responseKey)\r\n\r\n"

        XCTAssertThrowsError(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response))) { error in
            XCTAssertEqual(.upgraderDeniedUpgrade, error as? NIOHTTPClientUpgradeError)
        }

        // Close the pipeline.
        XCTAssertNoThrow(try clientChannel.close().wait())
    }

    func testRejectUpgradeIfNotWebsocket() throws {
        
        let requestKey = "OfS0wDaT5NoxF2gqm7Zj2YtetzM="
        let responseKey = "yKEqitDFPE81FyIhKTm+ojBqigk="
        
        let basicUpgrader = NIOWebSocketClientUpgrader(requestKey: requestKey,
                                                       upgradePipelineHandler: { (channel: Channel, _: HTTPResponseHead) in
                                                        channel.pipeline.addHandler(WebSocketRecorderHandler())
        })
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let clientChannel = try setUpClientChannel(clientHTTPHandler: BasicHTTPHandler(),
                                                   clientUpgraders: [basicUpgrader]) { _ in
        }

        // Push the successful server response with an incorrect protocol.
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: myProtocol\r\nSec-WebSocket-Accept:\(responseKey)\r\n\r\n"
        
        XCTAssertThrowsError(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response))) { error in
            XCTAssertEqual(.responseProtocolNotFound, error as? NIOHTTPClientUpgradeError)
        }

        // Close the pipeline.
        XCTAssertNoThrow(try clientChannel.close().wait())
    }
    
    fileprivate func runSuccessfulUpgrade() throws -> (EmbeddedChannel, WebSocketRecorderHandler) {
        
        let handler = WebSocketRecorderHandler()
        
        let basicUpgrader = NIOWebSocketClientUpgrader(requestKey: "OfS0wDaT5NoxF2gqm7Zj2YtetzM=",
                                                       upgradePipelineHandler: { (channel: Channel, _: HTTPResponseHead) in
                                                        channel.pipeline.addHandler(handler)
        })
        
        let clientChannel = try setUpClientChannel(clientHTTPHandler: ExplodingHTTPHandler(),
                                                   clientUpgraders: [basicUpgrader]) { _ in
        }
        
        // Push the successful server response.
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept:yKEqitDFPE81FyIhKTm+ojBqigk=\r\n\r\n"
        
        XCTAssertNoThrow(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response)))
        
        clientChannel.embeddedEventLoop.run()
        
        // We now have a successful upgrade, clear the output channels read to test the frames.
        XCTAssertNoThrow(try clientChannel.readOutbound(as: ByteBuffer.self))
        
        clientChannel.embeddedEventLoop.run()
        
        return (clientChannel, handler)
        
    }
    
    func testSendAFewFrames() throws {
        
        let (clientChannel, _) = try self.runSuccessfulUpgrade()

        // Send a frame or two, to confirm that the Websocket pipeline works.
        let stringSentInFrame = "hello, world"
        
        var data = clientChannel.allocator.buffer(capacity: 12)
        data.writeString(stringSentInFrame)
        
        let dataFrame = WebSocketFrame(fin: true, opcode: .binary, data: data)
        
        XCTAssertNoThrow(try clientChannel.writeOutbound(dataFrame))
        
        clientChannel.embeddedEventLoop.run()
        
        let outboundAsString = try clientChannel.readAllOutboundBuffers().allAsString()
        XCTAssert(outboundAsString.contains(stringSentInFrame))
        
        // Frame number two coming up.
        let stringSentInSecondFrame = "two"
        
        var dataTwo = clientChannel.allocator.buffer(capacity: 3)
        dataTwo.writeString(stringSentInSecondFrame)

        let pingFrame = WebSocketFrame(fin: true, opcode: .text, data: dataTwo)
        XCTAssertNoThrow(try clientChannel.writeAndFlush(pingFrame).wait())
        
        clientChannel.embeddedEventLoop.run()
        
        let pingAsString = try clientChannel.readAllOutboundBuffers().allAsString()
        XCTAssert(pingAsString.contains(stringSentInSecondFrame))
        
        // Close the pipeline.
        XCTAssertNoThrow(try clientChannel.close().wait())
    }

    private func encodeFrame(dataString: String, opcode: WebSocketOpcode) throws -> (WebSocketFrame, [UInt8]) {
        
        let serverChannel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try serverChannel.finish())
        }
        
        var buffer = serverChannel.allocator.buffer(capacity: 11)
        buffer.writeString(dataString)
        
        let dataFrame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
        
        try serverChannel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder())
        serverChannel.writeAndFlush(dataFrame, promise: nil)

        return (dataFrame, try serverChannel.readAllOutboundBytes())
    }
    
    func testReceiveAFewFrames() throws {
        
        let (clientChannel, recorder) = try self.runSuccessfulUpgrade()
        defer {
            XCTAssertNoThrow(try clientChannel.finish(acceptAlreadyClosed: true))
        }
        
        // Listen out for a frame or two, to confirm that the Websocket pipeline works.
        let (binaryFrame, binaryFrameAsBytes) = try self.encodeFrame(dataString: "hello, back", opcode: .binary)
        
        var data = clientChannel.allocator.buffer(capacity: binaryFrameAsBytes.count)
        data.writeBytes(binaryFrameAsBytes)
        
        XCTAssertNoThrow(try clientChannel.writeInbound(data))
        
        clientChannel.embeddedEventLoop.run()
        
        XCTAssertEqual(recorder.frames, [binaryFrame])
        
        // Frame number two coming up.
        let (textFrame, textFrameAsBytes) = try self.encodeFrame(dataString: "two", opcode: .text)

        var dataTwo = clientChannel.allocator.buffer(capacity: textFrameAsBytes.count)
        dataTwo.writeBytes(textFrameAsBytes)
        
        XCTAssertNoThrow(try clientChannel.writeInbound(dataTwo))
        
        clientChannel.embeddedEventLoop.run()
        
        XCTAssertEqual([binaryFrame, textFrame], recorder.frames)
        XCTAssertEqual(0, recorder.errors.count)

        // Close the pipeline.
        XCTAssertNoThrow(try clientChannel.close().wait())
    }
}

#if !canImport(Darwin) || swift(>=5.10)
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
final class TypedWebSocketClientEndToEndTests: WebSocketClientEndToEndTests {
    func setUpClientChannel(
        clientUpgraders: [any NIOTypedHTTPClientProtocolUpgrader<Void>],
        notUpgradingCompletionHandler: @Sendable @escaping (Channel) -> EventLoopFuture<Void>
    ) throws -> (EmbeddedChannel, EventLoopFuture<Void>) {

        let channel = EmbeddedChannel()

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(0)")

        let requestHead = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/",
            headers: headers
        )

        let config = NIOTypedHTTPClientUpgradeConfiguration(
            upgradeRequestHead: requestHead,
            upgraders: clientUpgraders,
            notUpgradingCompletionHandler: notUpgradingCompletionHandler
        )

        let upgradeResult = try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(configuration: .init(upgradeConfiguration: config))

        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0))
            .wait()

        return (channel, upgradeResult)
    }

    override func testSimpleUpgradeSucceeds() throws {
        let requestKey = "OfS0wDaT5NoxF2gqm7Zj2YtetzM="
        let responseKey = "yKEqitDFPE81FyIhKTm+ojBqigk="

        let basicUpgrader = NIOTypedWebSocketClientUpgrader(
            requestKey: requestKey,
            upgradePipelineHandler: { (channel: Channel, _: HTTPResponseHead) in
                channel.pipeline.addHandler(WebSocketRecorderHandler())
        })

        // The process should kick-off independently by sending the upgrade request to the server.
        let (clientChannel, upgradeResult) = try setUpClientChannel(
            clientUpgraders: [basicUpgrader],
            notUpgradingCompletionHandler: { $0.eventLoop.makeSucceededVoidFuture() }
        )

        // Read the server request.
        if let requestString = try clientChannel.readByteBufferOutputAsString() {
            XCTAssertEqual(requestString, basicRequest() + "\r\nConnection: upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: \(requestKey)\r\nSec-WebSocket-Version: 13\r\n\r\n")
        } else {
            XCTFail()
        }

        // Push the successful server response.
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept:\(responseKey)\r\n\r\n"

        XCTAssertNoThrow(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response)))

        clientChannel.embeddedEventLoop.run()

        // Once upgraded, validate the http pipeline has been removed.
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: HTTPRequestEncoder.self))
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: NIOHTTPClientUpgradeHandler.self))

        // Check that the pipeline now has the correct websocket handlers added.
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertContains(handlerType: WebSocketFrameEncoder.self))
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertContains(handlerType: ByteToMessageHandler<WebSocketFrameDecoder>.self))
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertContains(handlerType: WebSocketRecorderHandler.self))

        try upgradeResult.wait()

        // Close the pipeline.
        XCTAssertNoThrow(try clientChannel.close().wait())
    }

    override func testRejectUpgradeIfMissingAcceptKey() throws {
        let requestKey = "OfS0wDaT5NoxF2gqm7Zj2YtetzM="

        let basicUpgrader = NIOTypedWebSocketClientUpgrader(
            requestKey: requestKey,
            upgradePipelineHandler: { (channel: Channel, _: HTTPResponseHead) in
                channel.pipeline.addHandler(WebSocketRecorderHandler())
        })

        // The process should kick-off independently by sending the upgrade request to the server.
        let (clientChannel, upgradeResult) = try setUpClientChannel(
            clientUpgraders: [basicUpgrader],
            notUpgradingCompletionHandler: { $0.eventLoop.makeSucceededVoidFuture() }
        )

        // Push the successful server response but with a missing accept key.
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n"

        XCTAssertThrowsError(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response))) { error in
            XCTAssertEqual(error as? NIOHTTPClientUpgradeError, NIOHTTPClientUpgradeError.upgraderDeniedUpgrade)
        }

        // Close the pipeline.
        XCTAssertNoThrow(try clientChannel.close().wait())

        XCTAssertThrowsError(try upgradeResult.wait()) { error in
            XCTAssertEqual(error as? NIOHTTPClientUpgradeError, NIOHTTPClientUpgradeError.upgraderDeniedUpgrade)
        }
    }

    override func testRejectUpgradeIfIncorrectAcceptKey() throws {
        let requestKey = "OfS0wDaT5NoxF2gqm7Zj2YtetzM="
        let responseKey = "notACorrectKeyL1am=F1y=nn="

        let basicUpgrader = NIOTypedWebSocketClientUpgrader(
            requestKey: requestKey,
            upgradePipelineHandler: { (channel: Channel, _: HTTPResponseHead) in
                channel.pipeline.addHandler(WebSocketRecorderHandler())
        })

        // The process should kick-off independently by sending the upgrade request to the server.
        let (clientChannel, upgradeResult) = try setUpClientChannel(
            clientUpgraders: [basicUpgrader],
            notUpgradingCompletionHandler: { $0.eventLoop.makeSucceededVoidFuture() }
        )

        // Push the successful server response but with an incorrect response key.
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept:\(responseKey)\r\n\r\n"

        XCTAssertThrowsError(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response))) { error in
            XCTAssertEqual(error as? NIOHTTPClientUpgradeError, NIOHTTPClientUpgradeError.upgraderDeniedUpgrade)
        }

        // Close the pipeline.
        XCTAssertNoThrow(try clientChannel.close().wait())

        XCTAssertThrowsError(try upgradeResult.wait()) { error in
            XCTAssertEqual(error as? NIOHTTPClientUpgradeError, NIOHTTPClientUpgradeError.upgraderDeniedUpgrade)
        }
    }

    override func testRejectUpgradeIfNotWebsocket() throws {
        let requestKey = "OfS0wDaT5NoxF2gqm7Zj2YtetzM="
        let responseKey = "yKEqitDFPE81FyIhKTm+ojBqigk="

        let basicUpgrader = NIOTypedWebSocketClientUpgrader(
            requestKey: requestKey,
            upgradePipelineHandler: { (channel: Channel, _: HTTPResponseHead) in
                channel.pipeline.addHandler(WebSocketRecorderHandler())
        })

        // The process should kick-off independently by sending the upgrade request to the server.
        let (clientChannel, upgradeResult) = try setUpClientChannel(
            clientUpgraders: [basicUpgrader],
            notUpgradingCompletionHandler: { $0.eventLoop.makeSucceededVoidFuture() }
        )

        // Push the successful server response with an incorrect protocol.
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: myProtocol\r\nSec-WebSocket-Accept:\(responseKey)\r\n\r\n"

        XCTAssertThrowsError(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response))) { error in
            XCTAssertEqual(error as? NIOHTTPClientUpgradeError, NIOHTTPClientUpgradeError.responseProtocolNotFound)
        }

        // Close the pipeline.
        XCTAssertNoThrow(try clientChannel.close().wait())

        XCTAssertThrowsError(try upgradeResult.wait()) { error in
            XCTAssertEqual(error as? NIOHTTPClientUpgradeError, NIOHTTPClientUpgradeError.responseProtocolNotFound)
        }
    }

    override fileprivate func runSuccessfulUpgrade() throws -> (EmbeddedChannel, WebSocketRecorderHandler) {
        let handler = WebSocketRecorderHandler()

        let basicUpgrader = NIOTypedWebSocketClientUpgrader(
            requestKey: "OfS0wDaT5NoxF2gqm7Zj2YtetzM=",
            upgradePipelineHandler: { (channel: Channel, _: HTTPResponseHead) in
                channel.pipeline.addHandler(handler)
            })

        // The process should kick-off independently by sending the upgrade request to the server.
        let (clientChannel, upgradeResult) = try setUpClientChannel(
            clientUpgraders: [basicUpgrader],
            notUpgradingCompletionHandler: { $0.eventLoop.makeSucceededVoidFuture() }
        )

        // Push the successful server response.
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept:yKEqitDFPE81FyIhKTm+ojBqigk=\r\n\r\n"

        XCTAssertNoThrow(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response)))

        clientChannel.embeddedEventLoop.run()

        // We now have a successful upgrade, clear the output channels read to test the frames.
        XCTAssertNoThrow(try clientChannel.readOutbound(as: ByteBuffer.self))

        clientChannel.embeddedEventLoop.run()

        try upgradeResult.wait()

        return (clientChannel, handler)
    }

    func testSimpleUpgradeRejectedWhenServerSendsUpgradeNil() throws {

        enum TestUpgradeResult: Int {
            case successfulUpgrade
            case notUpgraded
        }

        let serverRecorder = WebSocketRecorderHandler()
        let clientRecorder = WebSocketRecorderHandler()
        let loop = EmbeddedEventLoop()
        let serverChannel = EmbeddedChannel(loop: loop)
        let clientChannel = EmbeddedChannel(loop: loop)

        let serverUpgrader = NIOTypedWebSocketServerUpgrader(
            shouldUpgrade: { (channel, head) in
                channel.eventLoop.makeSucceededFuture(nil)
            },
            upgradePipelineHandler: { (channel, req) in
                channel.pipeline.addHandler(serverRecorder)
            }
        )

        XCTAssertNoThrow(try serverChannel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
            configuration: .init(
                upgradeConfiguration: NIOTypedHTTPServerUpgradeConfiguration<Void>(
                    upgraders: [serverUpgrader],
                    notUpgradingCompletionHandler: { $0.eventLoop.makeSucceededVoidFuture() }
                )
            )
        ))

        let basicClientUpgrader = NIOTypedWebSocketClientUpgrader<TestUpgradeResult>(
            upgradePipelineHandler: { (channel: Channel, _: HTTPResponseHead) in
                channel.eventLoop.makeCompletedFuture {
                    return TestUpgradeResult.successfulUpgrade
                }
            })

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(0)")
        let requestHead = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/",
            headers: headers
        )
        let config = NIOTypedHTTPClientUpgradeConfiguration<TestUpgradeResult>(
            upgradeRequestHead: requestHead,
            upgraders: [basicClientUpgrader],
            notUpgradingCompletionHandler: { channel in
                channel.eventLoop.makeCompletedFuture {
                    return TestUpgradeResult.notUpgraded
                }
            }
        )
        let updgradeResult = try clientChannel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(configuration: .init(upgradeConfiguration: config))

        XCTAssertNoThrow(try interactInMemory(clientChannel, serverChannel, eventLoop: loop))
        XCTAssertNoThrow(try clientChannel.finish())
        updgradeResult.whenComplete { result in
            switch result {
            case .success(let value):
                XCTAssertTrue(value == .notUpgraded)
            case .failure(let error):
                XCTFail("There should be no failure here \(error)")
            }
        }
        XCTAssertNoThrow(try serverChannel.finishAcceptingAlreadyClosed())
        XCTAssertEqual(clientRecorder.errors.count, 0)
        XCTAssertEqual(serverRecorder.errors.count, 0)
        XCTAssertNoThrow(try loop.syncShutdownGracefully())
    }
}
#endif
