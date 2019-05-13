//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2019 Apple Inc. and the SwiftNIO project authors
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
@testable import NIO
@testable import NIOHTTP1

extension ChannelPipeline {
    
    // Waits up to 1 second for the upgrader to be removed by polling the pipeline
    // every 50ms checking for the handler.
    fileprivate func waitForClientUpgraderToBeRemoved() throws {
        for _ in 0..<20 {
            do {
                _ = try self.context(handlerType: NIOHTTPClientUpgradeHandler.self).wait()
                // handler present, keep waiting
                usleep(50)
            } catch ChannelPipelineError.notFound {
                return // No upgrader, carry on.
            }
        }

        XCTFail("Upgrader never removed")
    }
}

private func serverHTTPChannel(group: EventLoopGroup,
                               upgraders: [HTTPServerProtocolUpgrader]? = nil,
                               httpHandlers: [ChannelHandler] = []) throws -> (Channel, EventLoopFuture<Channel>) {
    
    let p = group.next().makePromise(of: Channel.self)
    let c = try ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        .childChannelInitializer { channel in
            p.succeed(channel)
            
            let upgradeConfig: HTTPUpgradeConfiguration? = upgraders.map {
                let fakeCompletion: (ChannelHandlerContext) -> Void = {_ in }
                return (upgraders: $0, completionHandler: fakeCompletion)
            }
            return channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false,
                                                                withServerUpgrade: upgradeConfig).flatMap {
                let futureResults = httpHandlers.map { channel.pipeline.addHandler($0) }
                return EventLoopFuture.andAllSucceed(futureResults, on: channel.eventLoop)
            }
        }.bind(host: "127.0.0.1", port: 0).wait()
    return (c, p.futureResult)
}
    
private func connectedClientChannel(group: EventLoopGroup,
                                    serverAddress: SocketAddress,
                                    httpHandler: RemovableChannelHandler,
                                    upgraders: [NIOHTTPClientProtocolUpgrader] = [],
                                    _ upgradeCompletionHandler: @escaping (ChannelHandlerContext) -> Void) throws -> Channel {

    return try ClientBootstrap(group: group)
        .channelInitializer { channel in
            
            let config: NIOHTTPClientUpgradeConfiguration = (
                upgraders: upgraders,
                completionHandler: { context in
                    channel.pipeline.removeHandler(httpHandler, promise: nil)
                    upgradeCompletionHandler(context)
            })
            
            return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config).flatMap {
                channel.pipeline.addHandler(httpHandler)
            }
        }
        .connect(to: serverAddress) // Now add the upgraders.
        .wait()
}

private final class SuccessfulServerUpgrader: HTTPServerProtocolUpgrader {
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String]
    private let onUpgradeComplete: (HTTPRequestHead) -> ()
    
    fileprivate init(forProtocol `protocol`: String, requiringHeaders headers: [String] = [], onUpgradeComplete: @escaping (HTTPRequestHead) -> () = { _ in }) {
        self.supportedProtocol = `protocol`
        self.requiredUpgradeHeaders = headers
        self.onUpgradeComplete = onUpgradeComplete
    }
    
    fileprivate func buildUpgradeResponse(channel: Channel, upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders) -> EventLoopFuture<HTTPHeaders> {
        var headers = initialResponseHeaders
        headers.add(name: "X-Upgrade-Complete", value: "true")
        return channel.eventLoop.makeSucceededFuture(headers)
    }
    
    fileprivate func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        self.onUpgradeComplete(upgradeRequest)
        return context.eventLoop.makeSucceededFuture(())
    }
}

private func setUpTestWithUpgradingServer(clientHTTPHandler: RemovableChannelHandler,
                                          clientUpgraders: [NIOHTTPClientProtocolUpgrader],
                                          serverUpgraders: [HTTPServerProtocolUpgrader],
                                          _ upgradeCompletionHandler: @escaping (ChannelHandlerContext) -> Void) throws -> (EventLoopGroup, Channel, Channel, Channel) {
    
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let (serverChannel, connectedServerChannelFuture) = try serverHTTPChannel(group: group,
                                                                              upgraders: serverUpgraders)
    
    let clientChannel = try connectedClientChannel(group: group,
                                                   serverAddress: serverChannel.localAddress!,
                                                   httpHandler: clientHTTPHandler,
                                                   upgraders: clientUpgraders,
                                                   upgradeCompletionHandler)
    
    return (group, serverChannel, clientChannel, try connectedServerChannelFuture.wait())
}

private func setUpTestWithFixedServer(clientHTTPHandler: RemovableChannelHandler,
                                      clientUpgraders: [NIOHTTPClientProtocolUpgrader],
                                      serverHTTPHandler: ChannelHandler,
                                      _ upgradeCompletionHandler: @escaping (ChannelHandlerContext) -> Void) throws -> (EventLoopGroup, Channel, Channel, Channel) {
    
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    
    let (serverChannel, connectedServerChannelFuture) = try serverHTTPChannel(group: group,
                                                                              httpHandlers: [serverHTTPHandler])
    
    let clientChannel = try connectedClientChannel(group: group,
                                                   serverAddress: serverChannel.localAddress!,
                                                   httpHandler: clientHTTPHandler,
                                                   upgraders: clientUpgraders,
                                                   upgradeCompletionHandler)
    
    return (group, serverChannel, clientChannel, try connectedServerChannelFuture.wait())
}

private final class SuccessfulClientUpgrader: NIOHTTPClientProtocolUpgrader {
    
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String]
    let upgradeHeaders: [(String,String)]
    
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
    
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String]
    let upgradeHeaders: [(String,String)]
    
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
    
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String]
    let upgradeHeaders: [(String,String)]

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

private class UpgradeDelayClientUpgrader: NIOHTTPClientProtocolUpgrader {

    let supportedProtocol: String
    let requiredUpgradeHeaders: [String]
    let upgradeHeaders: [(String,String)]
    
    let upgradedHandler: SimpleUpgradedHandler = SimpleUpgradedHandler()
    
    private var upgradePromise: EventLoopPromise<Void>?
    private var context: ChannelHandlerContext?
    
    fileprivate init(forProtocol `protocol`: String,
                     requiredUpgradeHeaders: [String] = [],
                     upgradeHeaders: [(String,String)] = []) {
        self.supportedProtocol = `protocol`
        self.requiredUpgradeHeaders = requiredUpgradeHeaders
        self.upgradeHeaders = upgradeHeaders
    }
    
    func addCustom(upgradeRequestHeaders: inout HTTPHeaders) {
        for (name, value) in self.upgradeHeaders {
            upgradeRequestHeaders.replaceOrAdd(name: name, value: value)
        }
    }
    
    func shouldAllowUpgrade(upgradeResponse: HTTPResponseHead) -> Bool {
        return true
    }

    func upgrade(context: ChannelHandlerContext, upgradeResponse: HTTPResponseHead) -> EventLoopFuture<Void> {
        self.upgradePromise = context.eventLoop.makePromise()
        self.context = context
        return self.upgradePromise!.futureResult.flatMap {
            context.pipeline.addHandler(self.upgradedHandler)
        }
    }
    
    func unblockUpgrade() {
        self.upgradePromise!.succeed(())
    }
}

private final class FixedResponseServerHTTPHandler: ChannelInboundHandler {
    fileprivate typealias InboundIn = HTTPServerRequestPart
    fileprivate typealias OutboundOut = HTTPServerResponsePart
    
    private var clientRequestReceived: (HTTPRequestHead) -> Void
    private var serverResponse: () -> HTTPResponseHead
    
    fileprivate var errorTriggerred: ((Error) -> Void)?

    fileprivate init(clientRequestReceived: @escaping (HTTPRequestHead) -> Void = { _ in },
         serverResponse: @escaping () -> HTTPResponseHead) {

        self.clientRequestReceived = clientRequestReceived
        self.serverResponse = serverResponse
    }
    
    fileprivate func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        
        let clientResponse = self.unwrapInboundIn(data)
        
        switch clientResponse {
        case .head(let responseHead):
            self.clientRequestReceived(responseHead)
        case .body:
            break
        case .end:

            let requestHead = self.serverResponse()
            
            context.write(self.wrapOutboundOut(.head(requestHead)), promise: nil)

            let buffer = context.channel.allocator.buffer(capacity: 0)
            let response = HTTPServerResponsePart.body(.byteBuffer(buffer.slice()))
            context.write(self.wrapOutboundOut(response), promise: nil)

            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
    
    fileprivate func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.errorTriggerred?(error)
    }
}

private final class SimpleUpgradedHandler: ChannelInboundHandler {
    fileprivate typealias InboundIn = ByteBuffer
    fileprivate typealias OutboundOut = ByteBuffer
    
    fileprivate var handlerAddedContextCallCount = 0
    fileprivate var channelReadContextDataCallCount = 0
    
    func handlerAdded(context: ChannelHandlerContext) {
        self.handlerAddedContextCallCount += 1
    }
    
    fileprivate func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.channelReadContextDataCallCount += 1
    }
}

// A HTTP handler that will send a request and then fail if it receives a response or an error.
// It can be used when there is a successful upgrade as the handler should be removed by the upgrader.
private final class ExplodingHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPClientResponsePart
    public typealias OutboundOut = HTTPClientRequestPart
    
    public func channelActive(context: ChannelHandlerContext) {

        // We are connected. It's time to send the message to the server to initialise the upgrade dance.
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(0)")
        
        let requestHead = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1),
                                          method: .GET,
                                          uri: "/",
                                          headers: headers)
        
        context.write(self.wrapOutboundOut(.head(requestHead)), promise: nil)
        
        let emptyBuffer = context.channel.allocator.buffer(capacity: 0)
        let body = HTTPClientRequestPart.body(.byteBuffer(emptyBuffer))
        context.write(self.wrapOutboundOut(body), promise: nil)
        
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        XCTFail("Received unexpected read")
    }
    
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        XCTFail("Received unexpected erro")
    }
}

// A HTTP handler that will send an initial request which can be augmented by the upgrade handler.
// It will record which error or response calls it receives so that they can be measured at a later time.
private final class RecordingHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPClientResponsePart
    public typealias OutboundOut = HTTPClientRequestPart
    
    var channelReadChannelHandlerContextDataCallCount = 0
    var errorCaughtChannelHandlerContextCallCount = 0
    var errorCaughtChannelHandlerLatestError: Error?
    
    public func channelActive(context: ChannelHandlerContext) {
        
        // We are connected. It's time to send the message to the server to initialise the upgrade dance.
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(0)")
        
        let requestHead = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1),
                                          method: .GET,
                                          uri: "/",
                                          headers: headers)
        
        context.write(self.wrapOutboundOut(.head(requestHead)), promise: nil)
        
        let emptyBuffer = context.channel.allocator.buffer(capacity: 0)
        let body = HTTPClientRequestPart.body(.byteBuffer(emptyBuffer))
        context.write(self.wrapOutboundOut(body), promise: nil)
        
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.channelReadChannelHandlerContextDataCallCount += 1
    }
    
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.errorCaughtChannelHandlerContextCallCount += 1
        self.errorCaughtChannelHandlerLatestError = error
    }
}

class HTTPClientUpgradeTestCase: XCTestCase {
    
    // MARK: Test basic happy path requests and responses against an operational upgrade server.
    
    func testSimpleUpgradeSucceeds() throws {
        
        let upgradeProtocol = "myProto"
        let addedUpgradeHeader = "myUpgradeHeader"
        let addedUpgradeHeaderValue = "upgradeHeaderValue"

        var upgradeHandlerCallbackFired = false

        // This header is not required by the server but we will validate its receipt.
        let clientHeaders = [(addedUpgradeHeader, addedUpgradeHeaderValue)]

        let clientUpgrader = SuccessfulClientUpgrader(forProtocol: upgradeProtocol,
                                                      upgradeHeaders: clientHeaders)
        
        let serverUpgrader = SuccessfulServerUpgrader(forProtocol: upgradeProtocol) { upgradeRequestAtServer in
            
            // Check the fidelity of the request send to the server.
            XCTAssertEqual("/", upgradeRequestAtServer.uri)
            XCTAssertEqual(.GET, upgradeRequestAtServer.method)
            XCTAssertEqual(["upgrade"], upgradeRequestAtServer.headers["Connection"])
            XCTAssertEqual([addedUpgradeHeaderValue], upgradeRequestAtServer.headers[addedUpgradeHeader])
        }

        // The process should kick-off independently by sending the upgrade request to the server.
        let (group, server, client, connectedServer) =
            try setUpTestWithUpgradingServer(clientHTTPHandler: ExplodingHTTPHandler(),
                                             clientUpgraders: [clientUpgrader],
                                             serverUpgraders: [serverUpgrader]) { (context) in

                                            // This is called before the upgrader gets called.
                                            upgradeHandlerCallbackFired = true
        }
        
        // First, validate the pipeline has http handlers.
        XCTAssertNoThrow(try client.pipeline.assertContains(handlerType: HTTPRequestEncoder.self))
        XCTAssertNoThrow(try client.pipeline.assertContains(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))
        XCTAssertNoThrow(try client.pipeline.assertContains(handlerType: NIOHTTPClientUpgradeHandler.self))

        defer {
            
            // Once upgraded, validate the pipeline has been removed.
            XCTAssertNoThrow(try client.pipeline.assertDoesNotContain(handlerType: HTTPRequestEncoder.self))
            XCTAssertNoThrow(try client.pipeline.assertDoesNotContain(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))
            XCTAssertNoThrow(try client.pipeline.assertDoesNotContain(handlerType: NIOHTTPClientUpgradeHandler.self))
            
            // Check the client upgrader was used correctly.
            XCTAssertEqual(1, clientUpgrader.addCustomUpgradeRequestHeadersCallCount)
            XCTAssertEqual(1, clientUpgrader.shouldAllowUpgradeCallCount)
            XCTAssertEqual(1, clientUpgrader.upgradeContextResponseCallCount)
            
            XCTAssert(upgradeHandlerCallbackFired)
            
            // Close the pipeline.
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try client.pipeline.waitForClientUpgraderToBeRemoved()
    }
    
    func testUpgradeWithRequiredHeadersSucceeds() throws {

        let upgradeProtocol = "myProto"
        let addedUpgradeHeader = "myUpgradeHeader"
        let addedUpgradeHeaderValue = "upgradeHeaderValue"
        
        var upgradeHandlerCallbackFired = false
        
        let clientHeaders = [(addedUpgradeHeader, addedUpgradeHeaderValue)]
        
        let clientUpgrader = SuccessfulClientUpgrader(forProtocol: upgradeProtocol,
                                                      requiredUpgradeHeaders: [addedUpgradeHeader],
                                                      upgradeHeaders: clientHeaders)
        
        let serverUpgrader = SuccessfulServerUpgrader(forProtocol: upgradeProtocol) { upgradeRequestAtServer in
            
            // Check the fidelity of the request send to the server.
            XCTAssertEqual("/", upgradeRequestAtServer.uri)
            XCTAssertEqual(.GET, upgradeRequestAtServer.method)
            
            // Required headers also need to be in the connection header on sent request.
            XCTAssert(upgradeRequestAtServer.headers["Connection"].contains("upgrade"))
            XCTAssert(upgradeRequestAtServer.headers["Connection"].contains(addedUpgradeHeader))
            
            XCTAssertEqual([addedUpgradeHeaderValue], upgradeRequestAtServer.headers[addedUpgradeHeader])
        }
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let (group, server, client, connectedServer) =
            try setUpTestWithUpgradingServer(clientHTTPHandler: ExplodingHTTPHandler(),
                                             clientUpgraders: [clientUpgrader],
                                             serverUpgraders: [serverUpgrader]) { (context) in
                                                
                                                // This is called before the upgrader gets called.
                                                upgradeHandlerCallbackFired = true
        }
        
        defer {
            
            // Once upgraded, validate the pipeline has been removed.
            XCTAssertNoThrow(try client.pipeline.assertDoesNotContain(handlerType: HTTPRequestEncoder.self))
            XCTAssertNoThrow(try client.pipeline.assertDoesNotContain(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))
            XCTAssertNoThrow(try client.pipeline.assertDoesNotContain(handlerType: NIOHTTPClientUpgradeHandler.self))
            
            // Check the client upgrader was used correctly.
            XCTAssertEqual(1, clientUpgrader.addCustomUpgradeRequestHeadersCallCount)
            XCTAssertEqual(1, clientUpgrader.shouldAllowUpgradeCallCount)
            XCTAssertEqual(1, clientUpgrader.upgradeContextResponseCallCount)
            
            XCTAssert(upgradeHandlerCallbackFired)
            
            // Close the pipeline.
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        
        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try client.pipeline.waitForClientUpgraderToBeRemoved()
    }
    
    func testSimpleUpgradeSucceedsWhenMultipleAvailableProtocols() throws {
        
        let unusedUpgradeProtocol = "unusedMyProto"
        let unusedUpgradeHeader = "unusedMyUpgradeHeader"
        let unusedUpgradeHeaderValue = "unusedUpgradeHeaderValue"
        
        let upgradeProtocol = "myProto"
        let addedUpgradeHeader = "myUpgradeHeader"
        let addedUpgradeHeaderValue = "upgradeHeaderValue"
        
        var upgradeHandlerCallbackFired = false
        
        // These headers are not required by the server but we will validate their receipt.
        let unusedClientHeaders = [(unusedUpgradeHeader, unusedUpgradeHeaderValue)]
        let clientHeaders = [(addedUpgradeHeader, addedUpgradeHeaderValue)]
        
        let unusedClientUpgrader = ExplodingClientUpgrader(forProtocol: unusedUpgradeProtocol,
                                                           upgradeHeaders: unusedClientHeaders)
        
        let clientUpgrader = SuccessfulClientUpgrader(forProtocol: upgradeProtocol,
                                                      upgradeHeaders: clientHeaders)
        
        let serverUpgrader = SuccessfulServerUpgrader(forProtocol: upgradeProtocol) { upgradeRequestAtServer in
            
            // Check that the details for both protocols are sent to the server.
            let expectedUpgrade = "\(unusedUpgradeProtocol),\(upgradeProtocol)" // Should preserve order.
            let actualUpgrade = upgradeRequestAtServer.headers["upgrade"].first ?? ""
            XCTAssertEqual(expectedUpgrade.lowercased(), actualUpgrade.lowercased())
            
            XCTAssertEqual([unusedUpgradeHeaderValue], upgradeRequestAtServer.headers[unusedUpgradeHeader])
            XCTAssertEqual([addedUpgradeHeaderValue], upgradeRequestAtServer.headers[addedUpgradeHeader])
        }
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let (group, server, client, connectedServer) =
            try setUpTestWithUpgradingServer(clientHTTPHandler: ExplodingHTTPHandler(),
                                             clientUpgraders: [unusedClientUpgrader, clientUpgrader],
                                             serverUpgraders: [serverUpgrader]) { (context) in
                                            
                                            // This is called before the upgrader gets called.
                                            upgradeHandlerCallbackFired = true
        }
        
        defer {
            // Should just upgrade to the accepted protocol.
            XCTAssertEqual(1, clientUpgrader.addCustomUpgradeRequestHeadersCallCount)
            XCTAssertEqual(1, clientUpgrader.shouldAllowUpgradeCallCount)
            XCTAssertEqual(1, clientUpgrader.upgradeContextResponseCallCount)
            
            XCTAssert(upgradeHandlerCallbackFired)
            
            // Close the pipeline.
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        
        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try client.pipeline.waitForClientUpgraderToBeRemoved()
    }
    
    // MARK: Test specific requests and responses with simple server using a fixed response.
    
    func testNoUpgradeAsNoServerUpgrade() throws {
        
        var upgradeHandlerCallbackFired = false

        let clientUpgrader = ExplodingClientUpgrader(forProtocol: "myProto")
        
        let fixedResponse = FixedResponseServerHTTPHandler(serverResponse: {

            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            headers.add(name: "Content-Length", value: "\(0)")
            
            let responseHead = HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1),
                                                status: .ok,
                                                headers: headers)
            return responseHead
        })
        
        let clientHandler = RecordingHTTPHandler()
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let (group, server, client, _) =
            try setUpTestWithFixedServer(clientHTTPHandler: clientHandler,
                                         clientUpgraders: [clientUpgrader],
                                         serverHTTPHandler: fixedResponse) { (context) in
                                            
                                                upgradeHandlerCallbackFired = true
        }
        
        defer {
            // Check that the http elements are not removed from the pipeline.
            XCTAssertNoThrow(try client.pipeline.assertContains(handlerType: HTTPRequestEncoder.self))
            XCTAssertNoThrow(try client.pipeline.assertContains(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))

            // Check that the HTTP handler received its response.
            XCTAssertLessThan(0, clientHandler.channelReadChannelHandlerContextDataCallCount)
            // Is not an error, just silently remove as there is no upgrade.
            XCTAssertEqual(0, clientHandler.errorCaughtChannelHandlerContextCallCount)

            XCTAssertFalse(upgradeHandlerCallbackFired)
            
            // Close the pipeline.
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        
        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try client.pipeline.waitForClientUpgraderToBeRemoved()
    }
    
    func testFirstResponseReturnsServerError() throws {
        
        var upgradeHandlerCallbackFired = false
        
        let clientUpgrader = ExplodingClientUpgrader(forProtocol: "myProto")
        
        let fixedResponse = FixedResponseServerHTTPHandler(serverResponse: {
            // Responds with error code.
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            headers.add(name: "Content-Length", value: "\(0)")
            
            let responseHead = HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1),
                                                status: .notFound,
                                                headers: headers)
            return responseHead
        })
        
        let clientHandler = RecordingHTTPHandler()
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let (group, server, client, _) =
            try setUpTestWithFixedServer(clientHTTPHandler: clientHandler,
                                         clientUpgraders: [clientUpgrader],
                                         serverHTTPHandler: fixedResponse) { (context) in
                                            
                                            upgradeHandlerCallbackFired = true
        }
        
        // Should fail with error (response is malformed) and remove upgrader from pipeline.
        defer {
            // Check that the http elements are not removed from the pipeline.
            XCTAssertNoThrow(try client.pipeline.assertContains(handlerType: HTTPRequestEncoder.self))
            XCTAssertNoThrow(try client.pipeline.assertContains(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))
            
            // Check that the HTTP handler received its response.
            XCTAssertLessThan(0, clientHandler.channelReadChannelHandlerContextDataCallCount)

            // Check a separate error is not reported, the error response will be forwarded on.
            XCTAssertEqual(0, clientHandler.errorCaughtChannelHandlerContextCallCount)
            
            XCTAssertFalse(upgradeHandlerCallbackFired)
            
            // Close the pipeline.
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        
        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try client.pipeline.waitForClientUpgraderToBeRemoved()
    }
    
    func testUpgradeResponseMissingAllProtocols() throws {
        
        var upgradeHandlerCallbackFired = false
        
        let clientUpgrader = ExplodingClientUpgrader(forProtocol: "myProto")
        
        let fixedResponse = FixedResponseServerHTTPHandler(serverResponse: {
            // Responds with switching protocols, but upgrade header is missing
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            headers.add(name: "Content-Length", value: "\(0)")
            headers.add(name: "Connection", value: "upgrade")
            
            let responseHead = HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1),
                                                status: .switchingProtocols,
                                                headers: headers)
            return responseHead
        })
        
        let clientHandler = RecordingHTTPHandler()
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let (group, server, client, _) =
            try setUpTestWithFixedServer(clientHTTPHandler: clientHandler,
                                         clientUpgraders: [clientUpgrader],
                                         serverHTTPHandler: fixedResponse) { (context) in
                                            
                                            upgradeHandlerCallbackFired = true
        }
        
        // Should fail with error (response is malformed) and remove upgrader from pipeline.
        defer {
            // Check that the http elements are not removed from the pipeline.
            XCTAssertNoThrow(try client.pipeline.assertContains(handlerType: HTTPRequestEncoder.self))
            XCTAssertNoThrow(try client.pipeline.assertContains(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))
            
            // Check that the HTTP handler received its response.
            XCTAssertLessThan(0, clientHandler.channelReadChannelHandlerContextDataCallCount)
            // Check an error is reported
            XCTAssertEqual(1, clientHandler.errorCaughtChannelHandlerContextCallCount)
            
            let reportedError = clientHandler.errorCaughtChannelHandlerLatestError! as! NIOHTTPClientUpgradeError
            XCTAssertEqual(NIOHTTPClientUpgradeError.responseProtocolNotFound, reportedError)
            
            XCTAssertFalse(upgradeHandlerCallbackFired)
            
            // Close the pipeline.
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        
        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try client.pipeline.waitForClientUpgraderToBeRemoved()
    }
    
    func testUpgradeOnlyHandlesKnownProtocols() throws {

        var upgradeHandlerCallbackFired = false
        
        let clientUpgrader = ExplodingClientUpgrader(forProtocol: "myProto")
        
        let fixedResponse = FixedResponseServerHTTPHandler(serverResponse: {
            // Responds with switching protocols, but upgrade header is missing
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            headers.add(name: "Content-Length", value: "\(0)")
            headers.add(name: "Connection", value: "upgrade")
            headers.add(name: "Upgrade", value: "unsupportedProtocol")
            
            let responseHead = HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1),
                                                status: .switchingProtocols,
                                                headers: headers)
            return responseHead
        })
        
        let clientHandler = RecordingHTTPHandler()
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let (group, server, client, _) =
            try setUpTestWithFixedServer(clientHTTPHandler: clientHandler,
                                         clientUpgraders: [clientUpgrader],
                                         serverHTTPHandler: fixedResponse) { (context) in
                                            
                                            upgradeHandlerCallbackFired = true
        }
        
        // Should fail with error (response is unsupported) and remove upgrader from pipeline.
        defer {
            // Check that the http elements are not removed from the pipeline.
            XCTAssertNoThrow(try client.pipeline.assertContains(handlerType: HTTPRequestEncoder.self))
            XCTAssertNoThrow(try client.pipeline.assertContains(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))
            
            // Check that the HTTP handler received its response.
            XCTAssertLessThan(0, clientHandler.channelReadChannelHandlerContextDataCallCount)
            // Check an error is reported
            XCTAssertEqual(1, clientHandler.errorCaughtChannelHandlerContextCallCount)
            
            let reportedError = clientHandler.errorCaughtChannelHandlerLatestError! as! NIOHTTPClientUpgradeError
            XCTAssertEqual(NIOHTTPClientUpgradeError.responseProtocolNotFound, reportedError)
            
            XCTAssertFalse(upgradeHandlerCallbackFired)
            
            // Close the pipeline.
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        
        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try client.pipeline.waitForClientUpgraderToBeRemoved()
    }
    
    func testUpgradeResponseCanBeRejectedByClientUpgrader() throws {
        
        var upgradeHandlerCallbackFired = false
        
        let clientUpgrader = DenyingClientUpgrader(forProtocol: "myProto")
        
        let fixedResponse = FixedResponseServerHTTPHandler(serverResponse: {
            // Responds with switching protocols accepted and valid response.
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            headers.add(name: "Content-Length", value: "\(0)")
            headers.add(name: "Connection", value: "upgrade")
            headers.add(name: "Upgrade", value: "myProto")
            
            let responseHead = HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1),
                                                status: .switchingProtocols,
                                                headers: headers)
            return responseHead
        })
        
        let clientHandler = RecordingHTTPHandler()
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let (group, server, client, _) =
            try setUpTestWithFixedServer(clientHTTPHandler: clientHandler,
                                         clientUpgraders: [clientUpgrader],
                                         serverHTTPHandler: fixedResponse) { (context) in
                                            
                                            upgradeHandlerCallbackFired = true
        }
        
        // Should fail with error (response is denied) and remove upgrader from pipeline.
        defer {
            // Check that the http elements are not removed from the pipeline.
            XCTAssertNoThrow(try client.pipeline.assertContains(handlerType: HTTPRequestEncoder.self))
            XCTAssertNoThrow(try client.pipeline.assertContains(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))

            XCTAssertEqual(1, clientUpgrader.addCustomUpgradeRequestHeadersCallCount)
            
            // Check that the HTTP handler received its response.
            XCTAssertLessThan(0, clientHandler.channelReadChannelHandlerContextDataCallCount)
            
            // Check an error is reported
            XCTAssertEqual(1, clientHandler.errorCaughtChannelHandlerContextCallCount)
            
            let reportedError = clientHandler.errorCaughtChannelHandlerLatestError! as! NIOHTTPClientUpgradeError
            XCTAssertEqual(NIOHTTPClientUpgradeError.upgraderDeniedUpgrade, reportedError)
            
            XCTAssertFalse(upgradeHandlerCallbackFired)
            
            // Close the pipeline.
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        
        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try client.pipeline.waitForClientUpgraderToBeRemoved()
    }
    
    func testUpgradeIsCaseInsensitive() throws {
        
        let upgradeProtocol = "mYPrOtO123"
        var upgradeHandlerCallbackFired = false
        
        let clientUpgrader = SuccessfulClientUpgrader(forProtocol: upgradeProtocol)
        
        let fixedResponse = FixedResponseServerHTTPHandler(serverResponse: {
            
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            headers.add(name: "Content-Length", value: "\(0)")
            
            // Upgrade headers
            headers.add(name: "CoNnEcTiOn", value: "uPGrAdE")
            headers.add(name: "uPgRaDe", value: upgradeProtocol)
            
            let responseHead = HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1),
                                                status: .switchingProtocols,
                headers: headers)
            return responseHead
        })
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let (group, server, client, connectedServer) =
            try setUpTestWithFixedServer(clientHTTPHandler: ExplodingHTTPHandler(),
                                         clientUpgraders: [clientUpgrader],
                                         serverHTTPHandler: fixedResponse) { (context) in
                                            
                                            upgradeHandlerCallbackFired = true
        }
        
        defer {
            // Check that the http elements are removed from the pipeline.
            XCTAssertNoThrow(try client.pipeline.assertDoesNotContain(handlerType: HTTPRequestEncoder.self))
            XCTAssertNoThrow(try client.pipeline.assertDoesNotContain(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))
            
            // Check the client upgrader was used.
            XCTAssertEqual(1, clientUpgrader.addCustomUpgradeRequestHeadersCallCount)
            XCTAssertEqual(1, clientUpgrader.shouldAllowUpgradeCallCount)
            XCTAssertEqual(1, clientUpgrader.upgradeContextResponseCallCount)
            
            XCTAssert(upgradeHandlerCallbackFired)
            
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        
        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try client.pipeline.waitForClientUpgraderToBeRemoved()
    }

    // MARK: Test when client pipeline experiences delay.

    func testBuffersInboundDataDuringAddingHandlers() throws {
        
        let g = DispatchGroup()
        g.enter()
        
        let upgradeProtocol = "myProto"
        var upgradeHandlerCallbackFired = false
        
        let clientUpgrader = UpgradeDelayClientUpgrader(forProtocol: upgradeProtocol)
        
        let fixedResponse = FixedResponseServerHTTPHandler(serverResponse: {
            
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            headers.add(name: "Content-Length", value: "\(0)")
            
            // Upgrade headers
            headers.add(name: "Connection", value: "upgrade")
            headers.add(name: "upgrade", value: upgradeProtocol)
            
            let responseHead = HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1),
                                                status: .switchingProtocols,
                headers: headers)
            return responseHead
        })
        
        // The process should kick-off independently by sending the upgrade request to the server.
        let (group, server, client, connectedServer) =
            // The exploding handler ensures that the http handler does not get passed to the handler
            try setUpTestWithFixedServer(clientHTTPHandler: ExplodingHTTPHandler(),
                                         clientUpgraders: [clientUpgrader],
                                         serverHTTPHandler: fixedResponse) { (context) in
                                            
                                            g.leave()

                                            upgradeHandlerCallbackFired = true
        }
        
        // Wait for the upgrade machinery to run.
        g.wait()
        
        let appData = "supersecretawesome data definitely not http\r\nawesome\r\ndata\ryeah"
        let buffer = NIOAny(ByteBuffer.forString(appData))
        client.pipeline.fireChannelRead(buffer)
        client.pipeline.fireChannelReadComplete()
        
        // Now we need to wait a little bit before we move forward. This needs to give time for the
        // I/O to settle. 100ms should be plenty to handle that I/O.
        try client.eventLoop.scheduleTask(in: .milliseconds(100)) {
            
            // Sanity check that the upgrade was delayed.
            XCTAssertEqual(0, clientUpgrader.upgradedHandler.handlerAddedContextCallCount)
            
            // Upgrade now.
            clientUpgrader.unblockUpgrade()
        }.futureResult.wait()
        
        defer {
            // Check that the http elements are removed from the pipeline.
            XCTAssertNoThrow(try client.pipeline.assertDoesNotContain(handlerType: HTTPRequestEncoder.self))
            XCTAssertNoThrow(try client.pipeline.assertDoesNotContain(handlerType: ByteToMessageHandler<HTTPResponseDecoder>.self))
            
            XCTAssert(upgradeHandlerCallbackFired)

            // Check that the data gets fired to the new handler once it is added.
            XCTAssertEqual(1, clientUpgrader.upgradedHandler.handlerAddedContextCallCount)
            XCTAssertEqual(1, clientUpgrader.upgradedHandler.channelReadContextDataCallCount)
            
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        
        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try client.pipeline.waitForClientUpgraderToBeRemoved()
    }
}
