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
import Dispatch
@testable import NIOCore
import NIOEmbedded
@testable import NIOHTTP1

extension EmbeddedChannel {
    
    fileprivate func readByteBufferOutputAsString() throws -> String? {
        
        if let requestData: IOData = try self.readOutbound(),
            case .byteBuffer(var requestBuffer) = requestData {
            
            return requestBuffer.readString(length: requestBuffer.readableBytes)
        }
        
        return nil
    }
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

    try channel.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes, withClientUpgrade: config).flatMap({
        channel.pipeline.addHandler(clientHTTPHandler)
    }).wait()
    
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0))
        .wait()
    
    return channel
}

private final class SuccessfulClientUpgrader: NIOHTTPClientProtocolUpgrader {
    
    fileprivate let supportedProtocol: String
    fileprivate let requiredUpgradeHeaders: [String]
    fileprivate let upgradeHeaders: [(String,String)]
    
    private(set) var addCustomUpgradeRequestHeadersCallCount = 0
    private(set) var shouldAllowUpgradeCallCount = 0
    private(set) var upgradeContextResponseCallCount = 0
    
    fileprivate init(forProtocol `protocol`: String, requiredUpgradeHeaders: [String] = [], upgradeHeaders: [(String,String)] = []) {
        self.supportedProtocol = `protocol`
        self.requiredUpgradeHeaders = requiredUpgradeHeaders
        self.upgradeHeaders = upgradeHeaders
    }
    
    fileprivate func addCustom(upgradeRequestHeaders: inout HTTPHeaders) {
        self.addCustomUpgradeRequestHeadersCallCount += 1
        for (name, value) in self.upgradeHeaders {
            upgradeRequestHeaders.replaceOrAdd(name: name, value: value)
        }
    }
    
    fileprivate func shouldAllowUpgrade(upgradeResponse: HTTPResponseHead) -> Bool {
        self.shouldAllowUpgradeCallCount += 1
        return true
    }
    
    fileprivate func upgrade(context: ChannelHandlerContext, upgradeResponse: HTTPResponseHead) -> EventLoopFuture<Void> {
        self.upgradeContextResponseCallCount += 1
        return context.channel.eventLoop.makeSucceededFuture(())
    }
}

private final class ExplodingClientUpgrader: NIOHTTPClientProtocolUpgrader {
    
    fileprivate let supportedProtocol: String
    fileprivate let requiredUpgradeHeaders: [String]
    fileprivate let upgradeHeaders: [(String,String)]
    
    fileprivate init(forProtocol `protocol`: String,
                     requiredUpgradeHeaders: [String] = [],
                     upgradeHeaders: [(String,String)] = []) {
        self.supportedProtocol = `protocol`
        self.requiredUpgradeHeaders = requiredUpgradeHeaders
        self.upgradeHeaders = upgradeHeaders
    }
    
    fileprivate func addCustom(upgradeRequestHeaders: inout HTTPHeaders) {
        for (name, value) in self.upgradeHeaders {
            upgradeRequestHeaders.replaceOrAdd(name: name, value: value)
        }
    }
    
    fileprivate func shouldAllowUpgrade(upgradeResponse: HTTPResponseHead) -> Bool {
        XCTFail("This method should not be called.")
        return false
    }
    
    fileprivate func upgrade(context: ChannelHandlerContext, upgradeResponse: HTTPResponseHead) -> EventLoopFuture<Void> {
        XCTFail("Upgrade should not be called.")
        return context.channel.eventLoop.makeSucceededFuture(())
    }
}

private final class DenyingClientUpgrader: NIOHTTPClientProtocolUpgrader {
    
    fileprivate let supportedProtocol: String
    fileprivate let requiredUpgradeHeaders: [String]
    fileprivate let upgradeHeaders: [(String,String)]

    private(set) var addCustomUpgradeRequestHeadersCallCount = 0
    
    fileprivate init(forProtocol `protocol`: String,
                     requiredUpgradeHeaders: [String] = [],
                    upgradeHeaders: [(String,String)] = []) {
        
        self.supportedProtocol = `protocol`
        self.requiredUpgradeHeaders = requiredUpgradeHeaders
        self.upgradeHeaders = upgradeHeaders
    }
    
    fileprivate func addCustom(upgradeRequestHeaders: inout HTTPHeaders) {
        self.addCustomUpgradeRequestHeadersCallCount += 1
        for (name, value) in self.upgradeHeaders {
            upgradeRequestHeaders.replaceOrAdd(name: name, value: value)
        }
    }
    
    fileprivate func shouldAllowUpgrade(upgradeResponse: HTTPResponseHead) -> Bool {
        return false
    }
    
    fileprivate func upgrade(context: ChannelHandlerContext, upgradeResponse: HTTPResponseHead) -> EventLoopFuture<Void> {
        XCTFail("Upgrade should not be called.")
        return context.channel.eventLoop.makeSucceededFuture(())
    }
}

private final class UpgradeDelayClientUpgrader: NIOHTTPClientProtocolUpgrader {

    fileprivate let supportedProtocol: String
    fileprivate let requiredUpgradeHeaders: [String]
    fileprivate let upgradeHeaders: [(String,String)]
    
    fileprivate let upgradedHandler = SimpleUpgradedHandler()
    
    private var upgradePromise: EventLoopPromise<Void>?

    fileprivate init(forProtocol `protocol`: String,
                     requiredUpgradeHeaders: [String] = [],
                     upgradeHeaders: [(String,String)] = []) {
        self.supportedProtocol = `protocol`
        self.requiredUpgradeHeaders = requiredUpgradeHeaders
        self.upgradeHeaders = upgradeHeaders
    }
    
    fileprivate func addCustom(upgradeRequestHeaders: inout HTTPHeaders) {
        for (name, value) in self.upgradeHeaders {
            upgradeRequestHeaders.replaceOrAdd(name: name, value: value)
        }
    }
    
    fileprivate func shouldAllowUpgrade(upgradeResponse: HTTPResponseHead) -> Bool {
        return true
    }

    fileprivate func upgrade(context: ChannelHandlerContext, upgradeResponse: HTTPResponseHead) -> EventLoopFuture<Void> {
        self.upgradePromise = context.eventLoop.makePromise()
        return self.upgradePromise!.futureResult.flatMap {
            context.pipeline.addHandler(self.upgradedHandler)
        }
    }
    
    fileprivate func unblockUpgrade() {
        self.upgradePromise!.succeed(())
    }
}

private final class SimpleUpgradedHandler: ChannelInboundHandler {
    fileprivate typealias InboundIn = ByteBuffer
    fileprivate typealias OutboundOut = ByteBuffer
    
    fileprivate var handlerAddedContextCallCount = 0
    fileprivate var channelReadContextDataCallCount = 0
    
    fileprivate func handlerAdded(context: ChannelHandlerContext) {
        self.handlerAddedContextCallCount += 1
    }
    
    fileprivate func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.channelReadContextDataCallCount += 1
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
        XCTFail("Received unexpected erro")
    }
}

// A HTTP handler that will send an initial request which can be augmented by the upgrade handler.
// It will record which error or response calls it receives so that they can be measured at a later time.
private final class RecordingHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    fileprivate typealias InboundIn = HTTPClientResponsePart
    fileprivate typealias OutboundOut = HTTPClientRequestPart
    
    fileprivate var channelReadChannelHandlerContextDataCallCount = 0
    fileprivate var errorCaughtChannelHandlerContextCallCount = 0
    fileprivate var errorCaughtChannelHandlerLatestError: Error?
    
    fileprivate func channelActive(context: ChannelHandlerContext) {
        // We are connected. It's time to send the message to the server to initialise the upgrade dance.
        self.fireSendRequest(context: context)
    }
    
    fileprivate func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.channelReadChannelHandlerContextDataCallCount += 1
    }
    
    fileprivate func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.errorCaughtChannelHandlerContextCallCount += 1
        self.errorCaughtChannelHandlerLatestError = error
    }
}

class HTTPClientUpgradeTestCase: XCTestCase {
    
    // MARK: Test basic happy path requests and responses.
    
    func testSimpleUpgradeSucceeds() throws {
        
        let upgradeProtocol = "myProto"
        let addedUpgradeHeader = "myUpgradeHeader"
        let addedUpgradeValue = "upgradeHeader"

        var upgradeHandlerCallbackFired = false

        // This header is not required by the server but we will validate its receipt.
        let clientHeaders = [(addedUpgradeHeader, addedUpgradeValue)]

        let clientUpgrader = SuccessfulClientUpgrader(forProtocol: upgradeProtocol,
                                                      upgradeHeaders: clientHeaders)
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let clientChannel = try setUpClientChannel(clientHTTPHandler: ExplodingHTTPHandler(),
                                                   clientUpgraders: [clientUpgrader]) { _ in
                                                    
                                                    // This is called before the upgrader gets called.
                                                    upgradeHandlerCallbackFired = true
        }
        defer {
            XCTAssertNoThrow(try clientChannel.finish())
        }
        
        // Read the server request.
        if let requestString = try clientChannel.readByteBufferOutputAsString() {
            XCTAssertEqual(requestString, "GET / HTTP/1.1\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 0\r\nConnection: upgrade\r\nUpgrade: \(upgradeProtocol.lowercased())\r\n\(addedUpgradeHeader): \(addedUpgradeValue)\r\n\r\n")
        } else {
            XCTFail()
        }
        
        // Validate the pipeline still has http handlers.
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertContains(handlerType: HTTPRequestEncoder.self))
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertContains(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertContains(handlerType: NIOHTTPClientUpgradeHandler.self))
        
        // Push the successful server response.
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: \(upgradeProtocol)\r\n\r\n"

        XCTAssertNoThrow(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response)))
        
        clientChannel.embeddedEventLoop.run()

        // Once upgraded, validate the pipeline has been removed.
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: HTTPRequestEncoder.self))
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: NIOHTTPClientUpgradeHandler.self))
        
        // Check the client upgrader was used correctly.
        XCTAssertEqual(1, clientUpgrader.addCustomUpgradeRequestHeadersCallCount)
        XCTAssertEqual(1, clientUpgrader.shouldAllowUpgradeCallCount)
        XCTAssertEqual(1, clientUpgrader.upgradeContextResponseCallCount)
        
        XCTAssert(upgradeHandlerCallbackFired)
    }
    
    func testUpgradeWithRequiredHeadersShowsInRequest() throws {
        
        let upgradeProtocol = "myProto"
        let addedUpgradeHeader = "myUpgradeHeader"
        let addedUpgradeValue = "upgradeValue"
        
        let clientHeaders = [(addedUpgradeHeader, addedUpgradeValue)]
        
        let clientUpgrader = SuccessfulClientUpgrader(forProtocol: upgradeProtocol,
                                                      requiredUpgradeHeaders: [addedUpgradeHeader],
                                                      upgradeHeaders: clientHeaders)
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let clientChannel = try setUpClientChannel(clientHTTPHandler: ExplodingHTTPHandler(),
                                                   clientUpgraders: [clientUpgrader]) { _ in
        }
        defer {
            XCTAssertNoThrow(try clientChannel.finish())
        }

        // Read the server request and check that it has the required header also added to the connection header.
        if let requestString = try clientChannel.readByteBufferOutputAsString() {
            XCTAssertEqual(requestString, "GET / HTTP/1.1\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 0\r\nConnection: upgrade,\(addedUpgradeHeader)\r\nUpgrade: \(upgradeProtocol.lowercased())\r\n\(addedUpgradeHeader): \(addedUpgradeValue)\r\n\r\n")
        } else {
            XCTFail()
        }
        
        // Check the client upgrader was used correctly, no response received.
        XCTAssertEqual(1, clientUpgrader.addCustomUpgradeRequestHeadersCallCount)
        XCTAssertEqual(0, clientUpgrader.shouldAllowUpgradeCallCount)
        XCTAssertEqual(0, clientUpgrader.upgradeContextResponseCallCount)
    }
    
    func testSimpleUpgradeSucceedsWhenMultipleAvailableProtocols() throws {
        
        let unusedUpgradeProtocol = "unusedMyProto"
        let unusedUpgradeHeader = "unusedMyUpgradeHeader"
        let unusedUpgradeValue = "unusedUpgradeHeaderValue"
        
        let upgradeProtocol = "myProto"
        let addedUpgradeHeader = "myUpgradeHeader"
        let addedUpgradeValue = "upgradeHeaderValue"
        
        var upgradeHandlerCallbackFired = false
        
        // These headers are not required by the server but we will validate their receipt.
        let unusedClientHeaders = [(unusedUpgradeHeader, unusedUpgradeValue)]
        let clientHeaders = [(addedUpgradeHeader, addedUpgradeValue)]
        
        let unusedClientUpgrader = ExplodingClientUpgrader(forProtocol: unusedUpgradeProtocol,
                                                           upgradeHeaders: unusedClientHeaders)
        
        let clientUpgrader = SuccessfulClientUpgrader(forProtocol: upgradeProtocol,
                                                      upgradeHeaders: clientHeaders)

        let clientUpgraders: [NIOHTTPClientProtocolUpgrader] = [unusedClientUpgrader, clientUpgrader]
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let clientChannel = try setUpClientChannel(clientHTTPHandler: ExplodingHTTPHandler(),
                                                   clientUpgraders: clientUpgraders) { (context) in
                                                    
                                                    // This is called before the upgrader gets called.
                                                    upgradeHandlerCallbackFired = true
        }
        defer {
            XCTAssertNoThrow(try clientChannel.finish())
        }
        
        // Read the server request.
        if let requestString = try clientChannel.readByteBufferOutputAsString() {
            
            // Check that the details for both protocols are sent to the server, in preference order.
            let expectedUpgrade = "\(unusedUpgradeProtocol),\(upgradeProtocol)".lowercased()
            
            XCTAssertEqual(requestString, "GET / HTTP/1.1\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 0\r\nConnection: upgrade\r\nUpgrade: \(expectedUpgrade)\r\n\(unusedUpgradeHeader): \(unusedUpgradeValue)\r\n\(addedUpgradeHeader): \(addedUpgradeValue)\r\n\r\n")
        } else {
            XCTFail()
        }
        
        // Push the successful server response.
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: \(upgradeProtocol)\r\n\r\n"
        
        XCTAssertNoThrow(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response)))
        
        clientChannel.embeddedEventLoop.run()
        
        // Should just upgrade to the accepted protocol, the other protocol uses an exploding upgrader.
        XCTAssertEqual(1, clientUpgrader.addCustomUpgradeRequestHeadersCallCount)
        XCTAssertEqual(1, clientUpgrader.shouldAllowUpgradeCallCount)
        XCTAssertEqual(1, clientUpgrader.upgradeContextResponseCallCount)
        
        XCTAssert(upgradeHandlerCallbackFired)
        
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: NIOHTTPClientUpgradeHandler.self))
    }
    
    func testUpgradeCompleteFlush() throws {
        final class ChannelReadWriteHandler: ChannelDuplexHandler {
            typealias OutboundIn = Any
            typealias InboundIn = Any
            typealias OutboundOut = Any
            
            var messagesReceived = 0
            
            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                self.messagesReceived += 1
                context.writeAndFlush(data, promise: nil)
            }
        }

        final class AddHandlerClientUpgrader<T: ChannelInboundHandler>: NIOHTTPClientProtocolUpgrader {
            fileprivate let requiredUpgradeHeaders: [String] = []
            fileprivate let supportedProtocol: String
            fileprivate let handler: T

            fileprivate init(forProtocol `protocol`: String, addingHandler handler: T) {
                self.supportedProtocol = `protocol`
                self.handler = handler
            }
            
            func addCustom(upgradeRequestHeaders: inout HTTPHeaders) { }
            
            func shouldAllowUpgrade(upgradeResponse: HTTPResponseHead) -> Bool {
                return true
            }
            
            func upgrade(context: ChannelHandlerContext, upgradeResponse: HTTPResponseHead) -> EventLoopFuture<Void> {
                return context.pipeline.addHandler(handler)
            }
        }
        
        var upgradeHandlerCallbackFired = false
        let handler = ChannelReadWriteHandler()
        let upgrader = AddHandlerClientUpgrader(forProtocol: "myproto", addingHandler: handler)
        let clientChannel = try setUpClientChannel(clientHTTPHandler: ExplodingHTTPHandler(),
                                                   clientUpgraders: [upgrader]) { (context) in
                                                    
                                                    upgradeHandlerCallbackFired = true
        }
        defer {
            XCTAssertNoThrow(try clientChannel.finish())
        }
        
        // Read the server request.
        if let requestString = try clientChannel.readByteBufferOutputAsString() {
            XCTAssertEqual(requestString, "GET / HTTP/1.1\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 0\r\nConnection: upgrade\r\nUpgrade: myproto\r\n\r\n")
            XCTAssertNoThrow(XCTAssertEqual(try clientChannel.readByteBufferOutputAsString(), ""))  // Empty body
            XCTAssertNoThrow(XCTAssertNil(try clientChannel.readByteBufferOutputAsString()))
        } else {
            XCTFail()
        }
        
        // Push the successful server response.
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: myproto\r\n\r\nTest"
                
        XCTAssertNoThrow(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response)))
        
        clientChannel.embeddedEventLoop.run()
                
        XCTAssert(upgradeHandlerCallbackFired)
        
        XCTAssertEqual(handler.messagesReceived, 1)
        
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: NIOHTTPClientUpgradeHandler.self))
        XCTAssertNoThrow(XCTAssertEqual(try clientChannel.readByteBufferOutputAsString(), "Test"))
    }
    
    // MARK: Test requests and responses with other specific actions.
    
    func testNoUpgradeAsNoServerUpgrade() throws {
        
        var upgradeHandlerCallbackFired = false

        let clientUpgrader = ExplodingClientUpgrader(forProtocol: "myProto")
        let clientHandler = RecordingHTTPHandler()
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let clientChannel = try setUpClientChannel(clientHTTPHandler: clientHandler,
                                                   clientUpgraders: [clientUpgrader]) { _ in
                                                    
                                                    // This is called before the upgrader gets called.
                                                    upgradeHandlerCallbackFired = true
        }
        defer {
            XCTAssertNoThrow(try clientChannel.finish())
        }
        
        let response = "HTTP/1.1 200 OK\r\n\r\n"
        XCTAssertNoThrow(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response)))
        
        clientChannel.embeddedEventLoop.run()
        
        // Check that the http elements are not removed from the pipeline.
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertContains(handlerType: HTTPRequestEncoder.self))
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertContains(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))

        // Check that the HTTP handler received its response.
        XCTAssertEqual(1, clientHandler.channelReadChannelHandlerContextDataCallCount)
        // Is not an error, just silently remove as there is no upgrade.
        XCTAssertEqual(0, clientHandler.errorCaughtChannelHandlerContextCallCount)

        XCTAssertFalse(upgradeHandlerCallbackFired)
        
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: NIOHTTPClientUpgradeHandler.self))
    }
    
    func testFirstResponseReturnsServerError() throws {
        
        var upgradeHandlerCallbackFired = false
        
        let clientUpgrader = ExplodingClientUpgrader(forProtocol: "myProto")
        let clientHandler = RecordingHTTPHandler()
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let clientChannel = try setUpClientChannel(clientHTTPHandler: clientHandler,
                                                   clientUpgraders: [clientUpgrader]) { _ in
                                                    
                                                    // This is called before the upgrader gets called.
                                                    upgradeHandlerCallbackFired = true
        }
        defer {
            XCTAssertNoThrow(try clientChannel.finish())
        }
        
        let response = "HTTP/1.1 404 Not Found\r\n\r\n"
        XCTAssertNoThrow(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response)))
        
        clientChannel.embeddedEventLoop.run()
        
        // Should fail with error (response is malformed) and remove upgrader from pipeline.
        
        // Check that the http elements are not removed from the pipeline.
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertContains(handlerType: HTTPRequestEncoder.self))
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertContains(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))
        
        // Check that the HTTP handler received its response.
        XCTAssertEqual(1, clientHandler.channelReadChannelHandlerContextDataCallCount)

        // Check a separate error is not reported, the error response will be forwarded on.
        XCTAssertEqual(0, clientHandler.errorCaughtChannelHandlerContextCallCount)
        
        XCTAssertFalse(upgradeHandlerCallbackFired)
        
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: NIOHTTPClientUpgradeHandler.self))
    }

    func testUpgradeResponseMissingAllProtocols() throws {
        
        var upgradeHandlerCallbackFired = false
        
        let clientUpgrader = ExplodingClientUpgrader(forProtocol: "myProto")
        let clientHandler = RecordingHTTPHandler()
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let clientChannel = try setUpClientChannel(clientHTTPHandler: clientHandler,
                                                   clientUpgraders: [clientUpgrader]) { _ in
                                                    
                                                    // This is called before the upgrader gets called.
                                                    upgradeHandlerCallbackFired = true
        }
        defer {
            XCTAssertNoThrow(try clientChannel.finish())
        }
        
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\n\r\n"
        XCTAssertNoThrow(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response)))
        
        clientChannel.embeddedEventLoop.run()
        
        // Should fail with error (response is malformed) and remove upgrader from pipeline.
        
        // Check that the http elements are not removed from the pipeline.
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertContains(handlerType: HTTPRequestEncoder.self))
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertContains(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))
            
        // Check that the HTTP handler received its response.
        XCTAssertLessThanOrEqual(1, clientHandler.channelReadChannelHandlerContextDataCallCount)
        // Check an error is reported
        XCTAssertEqual(1, clientHandler.errorCaughtChannelHandlerContextCallCount)
            
        let reportedError = clientHandler.errorCaughtChannelHandlerLatestError! as! NIOHTTPClientUpgradeError
        XCTAssertEqual(NIOHTTPClientUpgradeError.responseProtocolNotFound, reportedError)
            
        XCTAssertFalse(upgradeHandlerCallbackFired)
        
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: NIOHTTPClientUpgradeHandler.self))
    }
    
    func testUpgradeOnlyHandlesKnownProtocols() throws {

        var upgradeHandlerCallbackFired = false
        
        let clientUpgrader = ExplodingClientUpgrader(forProtocol: "myProto")
        let clientHandler = RecordingHTTPHandler()
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let clientChannel = try setUpClientChannel(clientHTTPHandler: clientHandler,
                                                   clientUpgraders: [clientUpgrader]) { _ in
                                                    
                                                    // This is called before the upgrader gets called.
                                                    upgradeHandlerCallbackFired = true
        }
        defer {
            XCTAssertNoThrow(try clientChannel.finish())
        }
        
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: unknownProtocol\r\n\r\n"
        XCTAssertNoThrow(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response)))
        
        clientChannel.embeddedEventLoop.run()
        
        // Should fail with error (response is malformed) and remove upgrader from pipeline.
        
        // Check that the http elements are not removed from the pipeline.
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertContains(handlerType: HTTPRequestEncoder.self))
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertContains(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))
            
        // Check that the HTTP handler received its response.
        XCTAssertLessThanOrEqual(1, clientHandler.channelReadChannelHandlerContextDataCallCount)
        // Check an error is reported
        XCTAssertEqual(1, clientHandler.errorCaughtChannelHandlerContextCallCount)
            
        let reportedError = clientHandler.errorCaughtChannelHandlerLatestError! as! NIOHTTPClientUpgradeError
        XCTAssertEqual(NIOHTTPClientUpgradeError.responseProtocolNotFound, reportedError)
            
        XCTAssertFalse(upgradeHandlerCallbackFired)
        
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: NIOHTTPClientUpgradeHandler.self))
    }
    
    func testUpgradeResponseCanBeRejectedByClientUpgrader() throws {
        
        let upgradeProtocol = "myProto"
        
        var upgradeHandlerCallbackFired = false
        
        let clientUpgrader = DenyingClientUpgrader(forProtocol: upgradeProtocol)
        let clientHandler = RecordingHTTPHandler()
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let clientChannel = try setUpClientChannel(clientHTTPHandler: clientHandler,
                                                   clientUpgraders: [clientUpgrader]) { _ in
                                                    
                                                    // This is called before the upgrader gets called.
                                                    upgradeHandlerCallbackFired = true
        }
        defer {
            XCTAssertNoThrow(try clientChannel.finish())
        }
        
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: \(upgradeProtocol)\r\n\r\n"
        XCTAssertNoThrow(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response)))

        clientChannel.embeddedEventLoop.run()
        
        // Should fail with error (response is denied) and remove upgrader from pipeline.
        
        // Check that the http elements are not removed from the pipeline.
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertContains(handlerType: HTTPRequestEncoder.self))
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertContains(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))

        XCTAssertEqual(1, clientUpgrader.addCustomUpgradeRequestHeadersCallCount)
            
        // Check that the HTTP handler received its response.
        XCTAssertLessThanOrEqual(1, clientHandler.channelReadChannelHandlerContextDataCallCount)
            
        // Check an error is reported
        XCTAssertEqual(1, clientHandler.errorCaughtChannelHandlerContextCallCount)
            
        let reportedError = clientHandler.errorCaughtChannelHandlerLatestError! as! NIOHTTPClientUpgradeError
        XCTAssertEqual(NIOHTTPClientUpgradeError.upgraderDeniedUpgrade, reportedError)
        XCTAssertFalse(upgradeHandlerCallbackFired)
        
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: NIOHTTPClientUpgradeHandler.self))
    }
    
    func testUpgradeIsCaseInsensitive() throws {
        
        let upgradeProtocol = "mYPrOtO123"
        var upgradeHandlerCallbackFired = false
        
        let clientUpgrader = SuccessfulClientUpgrader(forProtocol: upgradeProtocol)

        // The process should kick-off independently by sending the upgrade request to the server.
        let clientChannel = try setUpClientChannel(clientHTTPHandler: ExplodingHTTPHandler(),
                                                   clientUpgraders: [clientUpgrader]) { _ in
                                                    
                                                    // This is called before the upgrader gets called.
                                                    upgradeHandlerCallbackFired = true
        }
        defer {
            XCTAssertNoThrow(try clientChannel.finish())
        }
        
        let response = "HTTP/1.1 101 Switching Protocols\r\nCoNnEcTiOn: uPgRaDe\r\nuPgRaDe: \(upgradeProtocol)\r\n\r\n"
        XCTAssertNoThrow(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response)))
        
        clientChannel.embeddedEventLoop.run()
        
        // Should fail with error (response is denied) and remove upgrader from pipeline.
        
        // Check that the http elements are removed from the pipeline.
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: HTTPRequestEncoder.self))
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))
            
        // Check the client upgrader was used.
        XCTAssertEqual(1, clientUpgrader.addCustomUpgradeRequestHeadersCallCount)
        XCTAssertEqual(1, clientUpgrader.shouldAllowUpgradeCallCount)
        XCTAssertEqual(1, clientUpgrader.upgradeContextResponseCallCount)
            
        XCTAssert(upgradeHandlerCallbackFired)
        
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: NIOHTTPClientUpgradeHandler.self))
    }

    // MARK: Test when client pipeline experiences delay.

    func testBuffersInboundDataDuringAddingHandlers() throws {
        
        let upgradeProtocol = "myProto"
        var upgradeHandlerCallbackFired = false
        
        let clientUpgrader = UpgradeDelayClientUpgrader(forProtocol: upgradeProtocol)

        let clientChannel = try setUpClientChannel(clientHTTPHandler: ExplodingHTTPHandler(),
                                                   clientUpgraders: [clientUpgrader]) { (context) in
                                                    
                                                    // This is called before the upgrader gets called.
                                                    upgradeHandlerCallbackFired = true
        }
        defer {
            XCTAssertNoThrow(try clientChannel.finish())
        }

        
        // Push the successful server response.
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: \(upgradeProtocol)\r\n\r\n"
        XCTAssertNoThrow(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response)))
        
        // Run the processing of the response, but with the upgrade delayed by the client upgrader.
        clientChannel.embeddedEventLoop.run()
        
        // Soundness check that the upgrade was delayed.
        XCTAssertEqual(0, clientUpgrader.upgradedHandler.handlerAddedContextCallCount)
        
        // Add some non-http data.
        let appData = "supersecretawesome data definitely not http\r\nawesome\r\ndata\ryeah"
        XCTAssertNoThrow(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: appData)))
        
        // Upgrade now.
        clientUpgrader.unblockUpgrade()
        clientChannel.embeddedEventLoop.run()
        
        // Check that the http elements are removed from the pipeline.
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: HTTPRequestEncoder.self))
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))
        
        XCTAssert(upgradeHandlerCallbackFired)

        // Check that the data gets fired to the new handler once it is added.
        XCTAssertEqual(1, clientUpgrader.upgradedHandler.handlerAddedContextCallCount)
        XCTAssertEqual(1, clientUpgrader.upgradedHandler.channelReadContextDataCallCount)
        
        XCTAssertNoThrow(try clientChannel.pipeline
            .assertDoesNotContain(handlerType: NIOHTTPClientUpgradeHandler.self))
    }
    
    func testFiresOutboundErrorDuringAddingHandlers() throws {
        
        let upgradeProtocol = "myProto"
        var errorOnAdditionalChannelWrite: Error?
        var upgradeHandlerCallbackFired = false
        
        let clientUpgrader = UpgradeDelayClientUpgrader(forProtocol: upgradeProtocol)
        let clientHandler = RecordingHTTPHandler()
        
        let clientChannel = try setUpClientChannel(clientHTTPHandler: clientHandler,
                                                   clientUpgraders: [clientUpgrader]) { (context) in
                                                    
                                                    // This is called before the upgrader gets called.
                                                    upgradeHandlerCallbackFired = true
        }
        defer {
            XCTAssertNoThrow(try clientChannel.finish())
        }
        
        // Push the successful server response.
        let response = "HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: \(upgradeProtocol)\r\n\r\n"
        XCTAssertNoThrow(try clientChannel.writeInbound(clientChannel.allocator.buffer(string: response)))
        
        let promise = clientChannel.eventLoop.makePromise(of: Void.self)
        
        promise.futureResult.whenFailure() { error in
            errorOnAdditionalChannelWrite = error
        }

        // Send another outbound request during the upgrade.
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let secondRequest: HTTPClientRequestPart = .head(requestHead)
        clientChannel.writeAndFlush(secondRequest, promise: promise)
        
        clientChannel.embeddedEventLoop.run()

        let reportedError = clientHandler.errorCaughtChannelHandlerLatestError! as! NIOHTTPClientUpgradeError
        XCTAssertEqual(NIOHTTPClientUpgradeError.writingToHandlerDuringUpgrade, reportedError)

        let promiseError = errorOnAdditionalChannelWrite as! NIOHTTPClientUpgradeError
        XCTAssertEqual(NIOHTTPClientUpgradeError.writingToHandlerDuringUpgrade, promiseError)
        
        // Soundness check that the upgrade was delayed.
        XCTAssertEqual(0, clientUpgrader.upgradedHandler.handlerAddedContextCallCount)
        
        // Upgrade now.
        clientUpgrader.unblockUpgrade()
        clientChannel.embeddedEventLoop.run()

        // Check that the upgrade was still successful, despite the interruption.
        XCTAssert(upgradeHandlerCallbackFired)
        XCTAssertEqual(1, clientUpgrader.upgradedHandler.handlerAddedContextCallCount)
    }
    
    func testFiresInboundErrorBeforeSendsRequestUpgrade() throws {
        
        let upgradeProtocol = "myProto"
        
        let clientUpgrader = SuccessfulClientUpgrader(forProtocol: upgradeProtocol)
        let clientHandler = RecordingHTTPHandler()
        
        let clientChannel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try clientChannel.finish())
        }
        
        let upgrader = NIOHTTPClientUpgradeHandler(upgraders: [clientUpgrader],
                                                   httpHandlers: [clientHandler],
                                                   upgradeCompletionHandler: { context in
        })
        
        try clientChannel.pipeline.addHandler(upgrader).wait()
        
        try clientChannel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
        
        let headers = HTTPHeaders([("Connection", "upgrade"),
                                   ("Upgrade", "\(upgradeProtocol)")])
        let head = HTTPResponseHead(version: .http1_1,
                                    status: .switchingProtocols,
                                    headers: headers)
        let response = HTTPClientResponsePart.head(head)
        
        XCTAssertThrowsError(try clientChannel.writeInbound(response)) { error in
            let reportedError = error as! NIOHTTPClientUpgradeError
            XCTAssertEqual(NIOHTTPClientUpgradeError.receivedResponseBeforeRequestSent, reportedError)
        }
    }
}
