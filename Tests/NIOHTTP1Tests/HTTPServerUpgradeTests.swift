//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2022 Apple Inc. and the SwiftNIO project authors
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
import NIOCore
import NIOEmbedded
@testable import NIOPosix
@testable import NIOHTTP1

extension ChannelPipeline {
    fileprivate func assertDoesNotContainUpgrader() throws {
        try self.assertDoesNotContain(handlerType: HTTPServerUpgradeHandler.self)
    }

    func assertDoesNotContain<Handler: ChannelHandler>(handlerType: Handler.Type,
                                                       file: StaticString = #filePath,
                                                       line: UInt = #line) throws {
        do {
            let context = try self.context(handlerType: handlerType).wait()
            XCTFail("Found handler: \(context.handler)", file: (file), line: line)
        } catch ChannelPipelineError.notFound {
            // Nothing to see here
        }
    }

    fileprivate func assertContainsUpgrader() throws {
        try self.assertContains(handlerType: HTTPServerUpgradeHandler.self)
    }

    func assertContains<Handler: ChannelHandler>(handlerType: Handler.Type) throws {
        XCTAssertNoThrow(try self.context(handlerType: handlerType).wait(), "did not find handler")
    }

    fileprivate func removeUpgrader() throws {
        try self.context(handlerType: HTTPServerUpgradeHandler.self).flatMap {
            self.removeHandler(context: $0)
        }.wait()
    }

    // Waits up to 1 second for the upgrader to be removed by polling the pipeline
    // every 50ms checking for the handler.
    fileprivate func waitForUpgraderToBeRemoved() throws {
        for _ in 0..<20 {
            do {
                _ = try self.context(handlerType: HTTPServerUpgradeHandler.self).wait()
                // handler present, keep waiting
                usleep(50)
            } catch ChannelPipelineError.notFound {
                // No upgrader, we're good.
                return
            }
        }

        XCTFail("Upgrader never removed")
    }
}

extension EmbeddedChannel {
    func readAllOutboundBuffers() throws -> ByteBuffer {
        var buffer = self.allocator.buffer(capacity: 100)
        while var writtenData = try self.readOutbound(as: ByteBuffer.self) {
            buffer.writeBuffer(&writtenData)
        }

        return buffer
    }

    func readAllOutboundString() throws -> String {
        var buffer = try self.readAllOutboundBuffers()
        return buffer.readString(length: buffer.readableBytes)!
    }
}

#if swift(>=5.7)
private typealias UpgradeCompletionHandler = @Sendable (ChannelHandlerContext) -> Void
#else
private typealias UpgradeCompletionHandler = (ChannelHandlerContext) -> Void
#endif

private func serverHTTPChannelWithAutoremoval(group: EventLoopGroup,
                                              pipelining: Bool,
                                              upgraders: [HTTPServerProtocolUpgrader],
                                              extraHandlers: [ChannelHandler],
                                              _ upgradeCompletionHandler: @escaping UpgradeCompletionHandler) throws -> (Channel, EventLoopFuture<Channel>) {
    let p = group.next().makePromise(of: Channel.self)
    let c = try ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            p.succeed(channel)
            let upgradeConfig = (upgraders: upgraders, completionHandler: upgradeCompletionHandler)
            return channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: pipelining, withServerUpgrade: upgradeConfig).flatMap {
                let futureResults = extraHandlers.map { channel.pipeline.addHandler($0) }
                return EventLoopFuture.andAllSucceed(futureResults, on: channel.eventLoop)
            }
        }.bind(host: "127.0.0.1", port: 0).wait()
    return (c, p.futureResult)
}

private class SingleHTTPResponseAccumulator: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private var receiveds: [InboundIn] = []
    private let allDoneBlock: ([InboundIn]) -> Void

    public init(completion: @escaping ([InboundIn]) -> Void) {
        self.allDoneBlock = completion
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        self.receiveds.append(buffer)
        if let finalBytes = buffer.getBytes(at: buffer.writerIndex - 4, length: 4), finalBytes == [0x0D, 0x0A, 0x0D, 0x0A] {
            self.allDoneBlock(self.receiveds)
        }
    }
}

private class ExplodingHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        XCTFail("Received unexpected read")
    }
}

private func connectedClientChannel(group: EventLoopGroup, serverAddress: SocketAddress) throws -> Channel {
    return try ClientBootstrap(group: group)
        .connect(to: serverAddress)
        .wait()
}

private func setUpTestWithAutoremoval(pipelining: Bool = false,
                                      upgraders: [HTTPServerProtocolUpgrader],
                                      extraHandlers: [ChannelHandler],
                                      _ upgradeCompletionHandler: @escaping UpgradeCompletionHandler) throws -> (EventLoopGroup, Channel, Channel, Channel) {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let (serverChannel, connectedServerChannelFuture) = try serverHTTPChannelWithAutoremoval(group: group,
                                                                                             pipelining: pipelining,
                                                                                             upgraders: upgraders,
                                                                                             extraHandlers: extraHandlers,
                                                                                             upgradeCompletionHandler)
    let clientChannel = try connectedClientChannel(group: group, serverAddress: serverChannel.localAddress!)
    return (group, serverChannel, clientChannel, try connectedServerChannelFuture.wait())
}

internal func assertResponseIs(response: String, expectedResponseLine: String, expectedResponseHeaders: [String]) {
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

private class ExplodingUpgrader: HTTPServerProtocolUpgrader {
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String]

    private enum Explosion: Error {
        case KABOOM
    }

    public init(forProtocol `protocol`: String, requiringHeaders: [String] = []) {
        self.supportedProtocol = `protocol`
        self.requiredUpgradeHeaders = requiringHeaders
    }

    public func buildUpgradeResponse(channel: Channel, upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders) -> EventLoopFuture<HTTPHeaders> {
        XCTFail("buildUpgradeResponse called")
        return channel.eventLoop.makeFailedFuture(Explosion.KABOOM)
    }

    public func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        XCTFail("upgrade called")
        return context.eventLoop.makeSucceededFuture(())
    }
}

private class UpgraderSaysNo: HTTPServerProtocolUpgrader {
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String] = []

    public enum No: Error {
        case no
    }

    public init(forProtocol `protocol`: String) {
        self.supportedProtocol = `protocol`
    }

    public func buildUpgradeResponse(channel: Channel, upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders) -> EventLoopFuture<HTTPHeaders> {
        return channel.eventLoop.makeFailedFuture(No.no)
    }

    public func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        XCTFail("upgrade called")
        return context.eventLoop.makeSucceededFuture(())
    }
}

private class SuccessfulUpgrader: HTTPServerProtocolUpgrader {
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String]
    private let onUpgradeComplete: (HTTPRequestHead) -> ()
    private let buildUpgradeResponseFuture: (Channel, HTTPHeaders) -> EventLoopFuture<HTTPHeaders>

    public init(forProtocol `protocol`: String,
                requiringHeaders headers: [String],
                buildUpgradeResponseFuture: @escaping (Channel, HTTPHeaders) -> EventLoopFuture<HTTPHeaders>,
                onUpgradeComplete: @escaping (HTTPRequestHead) -> ()) {
        self.supportedProtocol = `protocol`
        self.requiredUpgradeHeaders = headers
        self.onUpgradeComplete = onUpgradeComplete
        self.buildUpgradeResponseFuture = buildUpgradeResponseFuture
    }

    public convenience init(forProtocol `protocol`: String,
                            requiringHeaders headers: [String],
                            onUpgradeComplete: @escaping (HTTPRequestHead) -> ()) {
        self.init(forProtocol: `protocol`,
                  requiringHeaders: headers,
                  buildUpgradeResponseFuture: { $0.eventLoop.makeSucceededFuture($1) },
                  onUpgradeComplete: onUpgradeComplete)
    }

    public func buildUpgradeResponse(channel: Channel, upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders) -> EventLoopFuture<HTTPHeaders> {
        var headers = initialResponseHeaders
        headers.add(name: "X-Upgrade-Complete", value: "true")
        return self.buildUpgradeResponseFuture(channel, headers)
    }

    public func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        self.onUpgradeComplete(upgradeRequest)
        return context.eventLoop.makeSucceededFuture(())
    }
}

private class DelayedUnsuccessfulUpgrader: HTTPServerProtocolUpgrader {
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String]

    private var upgradePromise: EventLoopPromise<Void>?

    init(forProtocol `protocol`: String) {
        self.supportedProtocol = `protocol`
        self.requiredUpgradeHeaders = []
    }

    func buildUpgradeResponse(channel: Channel,
                              upgradeRequest: HTTPRequestHead,
                              initialResponseHeaders: HTTPHeaders) -> EventLoopFuture<HTTPHeaders> {
        return channel.eventLoop.makeSucceededFuture([:])
    }

    func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        self.upgradePromise = context.eventLoop.makePromise()
        return self.upgradePromise!.futureResult
    }

    func unblockUpgrade(withError error: Error) {
        self.upgradePromise!.fail(error)
    }
}

private class UpgradeDelayer: HTTPServerProtocolUpgrader {
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String] = []

    private var upgradePromise: EventLoopPromise<Void>?

    public init(forProtocol `protocol`: String) {
        self.supportedProtocol = `protocol`
    }

    public func buildUpgradeResponse(channel: Channel, upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders) -> EventLoopFuture<HTTPHeaders> {
        var headers = initialResponseHeaders
        headers.add(name: "X-Upgrade-Complete", value: "true")
        return channel.eventLoop.makeSucceededFuture(headers)
    }

    public func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        self.upgradePromise = context.eventLoop.makePromise()
        return self.upgradePromise!.futureResult
    }

    public func unblockUpgrade() {
        self.upgradePromise!.succeed(())
    }
}

private class UpgradeResponseDelayer: HTTPServerProtocolUpgrader {
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String] = []

    private var context: ChannelHandlerContext?
    private let buildUpgradeResponseHandler: () -> EventLoopFuture<Void>

    public init(forProtocol `protocol`: String, buildUpgradeResponseHandler: @escaping () -> EventLoopFuture<Void>) {
        self.supportedProtocol = `protocol`
        self.buildUpgradeResponseHandler = buildUpgradeResponseHandler
    }

    public func buildUpgradeResponse(channel: Channel, upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders) -> EventLoopFuture<HTTPHeaders> {
        return self.buildUpgradeResponseHandler().map {
            var headers = initialResponseHeaders
            headers.add(name: "X-Upgrade-Complete", value: "true")
            return headers
        }
    }

    public func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        return context.eventLoop.makeSucceededFuture(())
    }
}

private class UserEventSaver<EventType>: ChannelInboundHandler {
    public typealias InboundIn = Any
    public var events: [EventType] = []

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        events.append(event as! EventType)
        context.fireUserInboundEventTriggered(event)
    }
}

private class ErrorSaver: ChannelInboundHandler {
    public typealias InboundIn = Any
    public typealias InboundOut = Any
    public var errors: [Error] = []

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        errors.append(error)
        context.fireErrorCaught(error)
    }
}

private class DataRecorder<T>: ChannelInboundHandler {
    public typealias InboundIn = T
    private var data: [T] = []

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let datum = self.unwrapInboundIn(data)
        self.data.append(datum)
    }

    // Must be called from inside the event loop on pain of death!
    public func receivedData() ->[T] {
        return self.data
    }
}

private class ReentrantReadOnChannelReadCompleteHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    typealias InboundOut = Any

    private var didRead = false

    func channelReadComplete(context: ChannelHandlerContext) {
        // Make sure we only do this once.
        if !self.didRead {
            self.didRead = true
            let data = context.channel.allocator.buffer(string: "re-entrant read from channelReadComplete!")

            // Please never do this.
            context.channel.pipeline.fireChannelRead(NIOAny(data))
        }
        context.fireChannelReadComplete()
    }
}

class HTTPServerUpgradeTestCase: XCTestCase {
    func testUpgradeWithoutUpgrade() throws {
        let (group, server, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [ExplodingUpgrader(forProtocol: "myproto")],
                                                                                    extraHandlers: []) { (_: ChannelHandlerContext) in
            XCTFail("upgrade completed")
        }
        defer {
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(client.allocator.buffer(string: request))).wait())

        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testUpgradeAfterInitialRequest() throws {
        let (group, server, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [ExplodingUpgrader(forProtocol: "myproto")],
                                                                                    extraHandlers: []) { (_: ChannelHandlerContext) in
            XCTFail("upgrade completed")
        }
        defer {
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        // This request fires a subsequent upgrade in immediately. It should also be ignored.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\n\r\nOPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nConnection: upgrade\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(client.allocator.buffer(string: request))).wait())

        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testUpgradeHandlerBarfsOnUnexpectedOrdering() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertEqual(true, try? channel.finish().isClean)
        }

        let handler = HTTPServerUpgradeHandler(upgraders: [ExplodingUpgrader(forProtocol: "myproto")],
                                               httpEncoder: HTTPResponseEncoder(),
                                               extraHTTPHandlers: []) { (_: ChannelHandlerContext) in
            XCTFail("upgrade completed")
        }
        let data = HTTPServerRequestPart.body(channel.allocator.buffer(string: "hello"))

        XCTAssertNoThrow(try channel.pipeline.addHandler(handler).wait())

        XCTAssertThrowsError(try channel.writeInbound(data)) { error in
            XCTAssertEqual(.invalidHTTPOrdering, error as? HTTPServerUpgradeErrors)
        }

        // The handler removed itself from the pipeline and passed the unexpected
        // data on.
        try channel.pipeline.assertDoesNotContainUpgrader()
        let receivedData: HTTPServerRequestPart = try channel.readInbound()!
        XCTAssertEqual(data, receivedData)
    }

    func testSimpleUpgradeSucceeds() throws {
        let upgradeRequest = UnsafeMutableTransferBox<HTTPRequestHead?>(nil)
        let upgradeHandlerCbFired = UnsafeMutableTransferBox(false)
        let upgraderCbFired = UnsafeMutableTransferBox(false)

        let upgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"]) { req in
            upgradeRequest.wrappedValue = req
            XCTAssert(upgradeHandlerCbFired.wrappedValue)
            upgraderCbFired.wrappedValue = true
        }

        let (group, _, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [upgrader],
                                                                               extraHandlers: []) { (context) in
            // This is called before the upgrader gets called.
            XCTAssertNil(upgradeRequest.wrappedValue)
            upgradeHandlerCbFired.wrappedValue = true

            // We're closing the connection now.
            context.close(promise: nil)
        }
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completePromise = group.next().makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(client.allocator.buffer(string: request))).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try completePromise.futureResult.wait())

        // At this time we want to assert that everything got called. Their own callbacks assert
        // that the ordering was correct.
        XCTAssert(upgradeHandlerCbFired.wrappedValue)
        XCTAssert(upgraderCbFired.wrappedValue)

        // We also want to confirm that the upgrade handler is no longer in the pipeline.
        try connectedServer.pipeline.assertDoesNotContainUpgrader()
    }

    func testUpgradeRequiresCorrectHeaders() throws {
        let (group, server, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [ExplodingUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"])],
                                                                                    extraHandlers: []) { (_: ChannelHandlerContext) in
            XCTFail("upgrade completed")
        }
        defer {
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nConnection: upgrade\r\nUpgrade: myproto\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(client.allocator.buffer(string: request))).wait())

        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testUpgradeRequiresHeadersInConnection() throws {
        let (group, server, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [ExplodingUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"])],
                                                                                    extraHandlers: []) { (_: ChannelHandlerContext) in
            XCTFail("upgrade completed")
        }
        defer {
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        // This request is missing a 'Kafkaesque' connection header.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nConnection: upgrade\r\nUpgrade: myproto\r\nKafkaesque: true\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(client.allocator.buffer(string: request))).wait())

        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testUpgradeOnlyHandlesKnownProtocols() throws {
        let (group, server, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [ExplodingUpgrader(forProtocol: "myproto")],
                                                                                    extraHandlers: []) { (_: ChannelHandlerContext) in
            XCTFail("upgrade completed")
        }
        defer {
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nConnection: upgrade\r\nUpgrade: something-else\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(client.allocator.buffer(string: request))).wait())

        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testUpgradeRespectsClientPreference() throws {
        let upgradeRequest = UnsafeMutableTransferBox<HTTPRequestHead?>(nil)
        let upgradeHandlerCbFired = UnsafeMutableTransferBox(false)
        let upgraderCbFired = UnsafeMutableTransferBox(false)

        let explodingUpgrader = ExplodingUpgrader(forProtocol: "exploder")
        let successfulUpgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"]) { req in
            upgradeRequest.wrappedValue = req
            XCTAssert(upgradeHandlerCbFired.wrappedValue)
            upgraderCbFired.wrappedValue = true
        }

        let (group, _, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [explodingUpgrader, successfulUpgrader],
                                                                               extraHandlers: []) { context in
            // This is called before the upgrader gets called.
            XCTAssertNil(upgradeRequest.wrappedValue)
            upgradeHandlerCbFired.wrappedValue = true

            // We're closing the connection now.
            context.close(promise: nil)
        }
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completePromise = group.next().makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto, exploder\r\nKafkaesque: yup\r\nConnection: upgrade, kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(client.allocator.buffer(string: request))).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try completePromise.futureResult.wait())

        // At this time we want to assert that everything got called. Their own callbacks assert
        // that the ordering was correct.
        XCTAssert(upgradeHandlerCbFired.wrappedValue)
        XCTAssert(upgraderCbFired.wrappedValue)

        // We also want to confirm that the upgrade handler is no longer in the pipeline.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testUpgradeFiresUserEvent() throws {
        // The user event is fired last, so we don't see it until both other callbacks
        // have fired.
        let eventSaver = UnsafeTransfer(UserEventSaver<HTTPServerUpgradeEvents>())

        let upgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: []) { req in
            XCTAssertEqual(eventSaver.wrappedValue.events.count, 0)
        }

        let (group, _, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [upgrader],
                                                                               extraHandlers: [eventSaver.wrappedValue]) { context in
            XCTAssertEqual(eventSaver.wrappedValue.events.count, 0)
            context.close(promise: nil)
        }
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completePromise = group.next().makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade,kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(client.allocator.buffer(string: request))).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try completePromise.futureResult.wait())

        // At this time we should have received one user event. We schedule this onto the
        // event loop to guarantee thread safety.
        XCTAssertNoThrow(try connectedServer.eventLoop.scheduleTask(deadline: .now()) {
            XCTAssertEqual(eventSaver.wrappedValue.events.count, 1)
            if case .upgradeComplete(let proto, let req) = eventSaver.wrappedValue.events[0] {
                XCTAssertEqual(proto, "myproto")
                XCTAssertEqual(req.method, .OPTIONS)
                XCTAssertEqual(req.uri, "*")
                XCTAssertEqual(req.version, .http1_1)
            } else {
                XCTFail("Unexpected event: \(eventSaver.wrappedValue.events[0])")
            }
        }.futureResult.wait())

        // We also want to confirm that the upgrade handler is no longer in the pipeline.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testUpgraderCanRejectUpgradeForPersonalReasons() throws {
        let upgradeRequest = UnsafeMutableTransferBox<HTTPRequestHead?>(nil)
        let upgradeHandlerCbFired = UnsafeMutableTransferBox(false)
        let upgraderCbFired = UnsafeMutableTransferBox(false)

        let explodingUpgrader = UpgraderSaysNo(forProtocol: "noproto")
        let successfulUpgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"]) { req in
            upgradeRequest.wrappedValue = req
            XCTAssert(upgradeHandlerCbFired.wrappedValue)
            upgraderCbFired.wrappedValue = true
        }
        let errorCatcher = ErrorSaver()

        let (group, _, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [explodingUpgrader, successfulUpgrader],
                                                                               extraHandlers: [errorCatcher]) { context in
            // This is called before the upgrader gets called.
            XCTAssertNil(upgradeRequest.wrappedValue)
            upgradeHandlerCbFired.wrappedValue = true

            // We're closing the connection now.
            context.close(promise: nil)
        }
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completePromise = group.next().makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: noproto,myproto\r\nKafkaesque: yup\r\nConnection: upgrade, kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(client.allocator.buffer(string: request))).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try completePromise.futureResult.wait())

        // At this time we want to assert that everything got called. Their own callbacks assert
        // that the ordering was correct.
        XCTAssert(upgradeHandlerCbFired.wrappedValue)
        XCTAssert(upgraderCbFired.wrappedValue)

        // We also want to confirm that the upgrade handler is no longer in the pipeline.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()

        // And we want to confirm we saved the error.
        XCTAssertEqual(errorCatcher.errors.count, 1)

        switch(errorCatcher.errors[0]) {
        case UpgraderSaysNo.No.no:
            break
        default:
            XCTFail("Unexpected error: \(errorCatcher.errors[0])")
        }
    }

    func testUpgradeIsCaseInsensitive() throws {
        let upgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: ["WeIrDcAsE"]) { req in }
        let (group, _, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [upgrader],
                                                                               extraHandlers: []) { context in
            context.close(promise: nil)
        }
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completePromise = group.next().makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nWeirdcase: yup\r\nConnection: upgrade,weirdcase\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try completePromise.futureResult.wait())

        // We also want to confirm that the upgrade handler is no longer in the pipeline.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testDelayedUpgradeBehaviour() throws {
        let g = DispatchGroup()
        g.enter()

        let upgrader = UpgradeDelayer(forProtocol: "myproto")
        let (group, server, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [upgrader],
                                                                                    extraHandlers: []) { context in
            g.leave()
        }
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completePromise = group.next().makePromise(of: Void.self)
        let clientHandler = SingleHTTPResponseAccumulator { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nConnection: upgrade\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(client.allocator.buffer(string: request))).wait())

        g.wait()

        // Ok, we don't think this upgrade should have succeeded yet, but neither should it have failed. We want to
        // dispatch onto the server event loop and check that the channel still contains the upgrade handler.
        try connectedServer.pipeline.assertContainsUpgrader()

        // Ok, let's unblock the upgrade now. The machinery should do its thing.
        try server.eventLoop.submit {
            upgrader.unblockUpgrade()
        }.wait()
        XCTAssertNoThrow(try completePromise.futureResult.wait())
        client.close(promise: nil)
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testBuffersInboundDataDuringDelayedUpgrade() throws {
        let g = DispatchGroup()
        g.enter()

        let upgrader = UpgradeDelayer(forProtocol: "myproto")
        let dataRecorder = DataRecorder<ByteBuffer>()

        let (group, server, client, _) = try setUpTestWithAutoremoval(upgraders: [upgrader],
                                                                      extraHandlers: [dataRecorder]) { context in
            g.leave()
        }
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completePromise = group.next().makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade, but is immediately followed by non-HTTP data that will probably
        // blow up the HTTP parser.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nConnection: upgrade\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(client.allocator.buffer(string: request))).wait())

        // Wait for the upgrade machinery to run.
        g.wait()

        // Ok, send the application data in.
        let appData = "supersecretawesome data definitely not http\r\nawesome\r\ndata\ryeah"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(client.allocator.buffer(string: appData))).wait())

        // Now we need to wait a little bit before we move forward. This needs to give time for the
        // I/O to settle. 100ms should be plenty to handle that I/O.
        try server.eventLoop.scheduleTask(in: .milliseconds(100)) {
            upgrader.unblockUpgrade()
        }.futureResult.wait()

        client.close(promise: nil)
        XCTAssertNoThrow(try completePromise.futureResult.wait())

        // Let's check that the data recorder saw everything.
        let data = try server.eventLoop.submit {
            dataRecorder.receivedData()
        }.wait()
        let resultString = data.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
        XCTAssertEqual(resultString, appData)
    }

    func testDelayedUpgradeResponse() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        var upgradeRequested = false

        let delayedPromise = channel.eventLoop.makePromise(of: Void.self)
        let delayedUpgrader = UpgradeResponseDelayer(forProtocol: "myproto") {
            XCTAssertFalse(upgradeRequested)
            upgradeRequested = true
            return delayedPromise.futureResult
        }

        XCTAssertNoThrow(try channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [delayedUpgrader], completionHandler: { context in })).wait())

        // Let's send in an upgrade request.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try channel.writeInbound(channel.allocator.buffer(string: request)))

        // Upgrade has been requested but not proceeded.
        XCTAssertTrue(upgradeRequested)
        XCTAssertNoThrow(try channel.pipeline.assertContainsUpgrader())
        XCTAssertNoThrow(try XCTAssertNil(channel.readOutbound(as: ByteBuffer.self)))

        // Ok, now we can upgrade. Upgrader should be out of the pipeline, and we should have seen the 101 response.
        delayedPromise.succeed(())
        channel.embeddedEventLoop.run()
        XCTAssertNoThrow(try channel.pipeline.assertDoesNotContainUpgrader())
        XCTAssertNoThrow(assertResponseIs(response: try channel.readAllOutboundString(),
                                          expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                                          expectedResponseHeaders: ["X-Upgrade-Complete: true",
                                                                    "upgrade: myproto",
                                                                    "connection: upgrade"]))
    }

    func testChainsDelayedUpgradesAppropriately() throws {
        enum No: Error {
            case no
        }

        let channel = EmbeddedChannel()
        defer {
            XCTAssertTrue(try channel.finish().isClean)
        }

        var upgradingProtocol = ""

        let failingProtocolPromise = channel.eventLoop.makePromise(of: Void.self)
        let failingProtocolUpgrader = UpgradeResponseDelayer(forProtocol: "failingProtocol") {
            XCTAssertEqual(upgradingProtocol, "")
            upgradingProtocol = "failingProtocol"
            return failingProtocolPromise.futureResult
        }

        let myprotoPromise = channel.eventLoop.makePromise(of: Void.self)
        let myprotoUpgrader = UpgradeResponseDelayer(forProtocol: "myproto") {
            XCTAssertEqual(upgradingProtocol, "failingProtocol")
            upgradingProtocol = "myproto"
            return myprotoPromise.futureResult
        }

        XCTAssertNoThrow(try channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [myprotoUpgrader, failingProtocolUpgrader], completionHandler: { context in })).wait())

        // Let's send in an upgrade request.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: failingProtocol, myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try channel.writeInbound(channel.allocator.buffer(string: request)))

        // Upgrade has been requested but not proceeded for the failing protocol.
        XCTAssertEqual(upgradingProtocol, "failingProtocol")
        XCTAssertNoThrow(try channel.pipeline.assertContainsUpgrader())
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self)))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())

        // Ok, now we'll fail the promise. This will catch an error, but the upgrade won't happen: instead, the second handler will be fired.
        failingProtocolPromise.fail(No.no)
        XCTAssertEqual(upgradingProtocol, "myproto")
        XCTAssertNoThrow(try channel.pipeline.assertContainsUpgrader())
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self)))
        
        XCTAssertThrowsError(try channel.throwIfErrorCaught()) { error in
            XCTAssertEqual(.no, error as? No)
        }

        // Ok, now we can upgrade. Upgrader should be out of the pipeline, and we should have seen the 101 response.
        myprotoPromise.succeed(())
        channel.embeddedEventLoop.run()
        XCTAssertNoThrow(try channel.pipeline.assertDoesNotContainUpgrader())
        assertResponseIs(response: try channel.readAllOutboundString(),
                         expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                         expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])
    }

    func testDelayedUpgradeResponseDeliversFullRequest() throws {
        enum No: Error {
            case no
        }

        let channel = EmbeddedChannel()
        defer {
            XCTAssertTrue(try channel.finish().isClean)
        }

        var upgradeRequested = false

        let delayedPromise = channel.eventLoop.makePromise(of: Void.self)
        let delayedUpgrader = UpgradeResponseDelayer(forProtocol: "myproto") {
            XCTAssertFalse(upgradeRequested)
            upgradeRequested = true
            return delayedPromise.futureResult
        }

        XCTAssertNoThrow(try channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [delayedUpgrader], completionHandler: { context in })).wait())

        // Let's send in an upgrade request.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try channel.writeInbound(channel.allocator.buffer(string: request)))

        // Upgrade has been requested but not proceeded.
        XCTAssertTrue(upgradeRequested)
        XCTAssertNoThrow(try channel.pipeline.assertContainsUpgrader())
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self)))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())

        // Ok, now we fail the upgrade. This fires an error, and then delivers the original request.
        delayedPromise.fail(No.no)
        XCTAssertNoThrow(try channel.pipeline.assertDoesNotContainUpgrader())
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self)))

        XCTAssertThrowsError(try channel.throwIfErrorCaught()) { error in
            XCTAssertEqual(.no, error as? No)
        }

        switch try channel.readInbound(as: HTTPServerRequestPart.self) {
        case .some(.head):
            // ok
            break
        case let t:
            XCTFail("Expected .head, got \(String(describing: t))")
        }

        switch try channel.readInbound(as: HTTPServerRequestPart.self) {
        case .some(.end):
            // ok
            break
        case let t:
            XCTFail("Expected .head, got \(String(describing: t))")
        }

        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound(as: HTTPServerRequestPart.self)))
    }

    func testDelayedUpgradeResponseDeliversFullRequestAndPendingBits() throws {
        enum No: Error {
            case no
        }

        let channel = EmbeddedChannel()
        defer {
            XCTAssertTrue(try channel.finish().isClean)
        }

        var upgradeRequested = false

        let delayedPromise = channel.eventLoop.makePromise(of: Void.self)
        let delayedUpgrader = UpgradeResponseDelayer(forProtocol: "myproto") {
            XCTAssertFalse(upgradeRequested)
            upgradeRequested = true
            return delayedPromise.futureResult
        }

        // Here we're disabling the pipeline handler, because otherwise it makes this test case impossible to reach.
        XCTAssertNoThrow(try channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false,
                                                                          withServerUpgrade: (upgraders: [delayedUpgrader], completionHandler: { context in })).wait())

        // Let's send in an upgrade request.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try channel.writeInbound(channel.allocator.buffer(string: request)))

        // Upgrade has been requested but not proceeded.
        XCTAssertTrue(upgradeRequested)
        XCTAssertNoThrow(try channel.pipeline.assertContainsUpgrader())
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self)))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())

        // We now need to inject an extra buffered request. To do this we grab the context for the HTTPRequestDecoder and inject some reads.
        XCTAssertNoThrow(try channel.pipeline.context(handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self).map { context in
            let requestHead = HTTPServerRequestPart.head(.init(version: .http1_1, method: .GET, uri: "/test"))
            context.fireChannelRead(NIOAny(requestHead))
            context.fireChannelRead(NIOAny(HTTPServerRequestPart.end(nil)))
        }.wait())

        // Ok, now we fail the upgrade. This fires an error, and then delivers the original request and the buffered one.
        delayedPromise.fail(No.no)
        XCTAssertNoThrow(try channel.pipeline.assertDoesNotContainUpgrader())
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self)))

        XCTAssertThrowsError(try channel.throwIfErrorCaught()) { error in
            XCTAssertEqual(.no, error as? No)
        }

        switch try channel.readInbound(as: HTTPServerRequestPart.self) {
        case .some(.head(let h)):
            XCTAssertEqual(h.method, .OPTIONS)
        case let t:
            XCTFail("Expected .head, got \(String(describing: t))")
        }

        switch try channel.readInbound(as: HTTPServerRequestPart.self) {
        case .some(.end):
            // ok
            break
        case let t:
            XCTFail("Expected .head, got \(String(describing: t))")
        }


        switch try channel.readInbound(as: HTTPServerRequestPart.self) {
        case .some(.head(let h)):
            XCTAssertEqual(h.method, .GET)
        case let t:
            XCTFail("Expected .head, got \(String(describing: t))")
        }

        switch try channel.readInbound(as: HTTPServerRequestPart.self) {
        case .some(.end):
            // ok
            break
        case let t:
            XCTFail("Expected .head, got \(String(describing: t))")
        }

        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound(as: HTTPServerRequestPart.self)))
    }

    func testRemovesAllHTTPRelatedHandlersAfterUpgrade() throws {
        let upgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: []) { req in }
        let (group, _, client, connectedServer) = try setUpTestWithAutoremoval(pipelining: true,
                                                                               upgraders: [upgrader],
                                                                               extraHandlers: []) { context in }
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        // First, validate the pipeline is right.
        XCTAssertNoThrow(try connectedServer.pipeline.assertContains(handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self))
        XCTAssertNoThrow(try connectedServer.pipeline.assertContains(handlerType: HTTPResponseEncoder.self))
        XCTAssertNoThrow(try connectedServer.pipeline.assertContains(handlerType: HTTPServerPipelineHandler.self))

        // This request is safe to upgrade.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(client.allocator.buffer(string: request))).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try connectedServer.pipeline.waitForUpgraderToBeRemoved())

        // At this time we should validate that none of the HTTP handlers in the pipeline exist.
        XCTAssertNoThrow(try connectedServer.pipeline.assertDoesNotContain(handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self))
        XCTAssertNoThrow(try connectedServer.pipeline.assertDoesNotContain(handlerType: HTTPResponseEncoder.self))
        XCTAssertNoThrow(try connectedServer.pipeline.assertDoesNotContain(handlerType: HTTPServerPipelineHandler.self))
    }

    func testUpgradeWithUpgradePayloadInlineWithRequestWorks() throws {
        enum ReceivedTheWrongThingError: Error { case error }
        let upgradeRequest = UnsafeMutableTransferBox<HTTPRequestHead?>(nil)
        let upgradeHandlerCbFired = UnsafeMutableTransferBox(false)
        let upgraderCbFired = UnsafeMutableTransferBox(false)
        
        class CheckWeReadInlineAndExtraData: ChannelDuplexHandler {
            typealias InboundIn = ByteBuffer
            typealias OutboundIn = Never
            typealias OutboundOut = Never
            
            enum State {
                case fresh
                case added
                case inlineDataRead
                case extraDataRead
                case closed
            }
            
            private let firstByteDonePromise: EventLoopPromise<Void>
            private let secondByteDonePromise: EventLoopPromise<Void>
            private let allDonePromise: EventLoopPromise<Void>
            private var state = State.fresh
            
            init(firstByteDonePromise: EventLoopPromise<Void>,
                 secondByteDonePromise: EventLoopPromise<Void>,
                 allDonePromise: EventLoopPromise<Void>) {
                self.firstByteDonePromise = firstByteDonePromise
                self.secondByteDonePromise = secondByteDonePromise
                self.allDonePromise = allDonePromise
            }
            
            func handlerAdded(context: ChannelHandlerContext) {
                XCTAssertEqual(.fresh, self.state)
                self.state = .added
            }
            
            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buf = self.unwrapInboundIn(data)
                XCTAssertEqual(1, buf.readableBytes)
                let stringRead = buf.readString(length: buf.readableBytes)
                switch self.state {
                case .added:
                    XCTAssertEqual("A", stringRead)
                    self.state = .inlineDataRead
                    if stringRead == .some("A") {
                        self.firstByteDonePromise.succeed(())
                    } else {
                        self.firstByteDonePromise.fail(ReceivedTheWrongThingError.error)
                    }
                case .inlineDataRead:
                    XCTAssertEqual("B", stringRead)
                    self.state = .extraDataRead
                    context.channel.close(promise: nil)
                    if stringRead == .some("B") {
                        self.secondByteDonePromise.succeed(())
                    } else {
                        self.secondByteDonePromise.fail(ReceivedTheWrongThingError.error)
                    }
                default:
                    XCTFail("channel read in wrong state \(self.state)")
                }
            }
            
            func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
                XCTAssertEqual(.extraDataRead, self.state)
                self.state = .closed
                context.close(mode: mode, promise: promise)
                
                self.allDonePromise.succeed(())
            }
        }
        
        let upgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"]) { req in
            upgradeRequest.wrappedValue = req
            XCTAssert(upgradeHandlerCbFired.wrappedValue)
            upgraderCbFired.wrappedValue = true
        }
        
        let promiseGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try promiseGroup.syncShutdownGracefully())
        }
        let firstByteDonePromise = promiseGroup.next().makePromise(of: Void.self)
        let secondByteDonePromise = promiseGroup.next().makePromise(of: Void.self)
        let allDonePromise = promiseGroup.next().makePromise(of: Void.self)
        let (group, _, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [upgrader],
                                                                               extraHandlers: []) { (context) in
            // This is called before the upgrader gets called.
            XCTAssertNil(upgradeRequest.wrappedValue)
            upgradeHandlerCbFired.wrappedValue = true

            _ = context.channel.pipeline.addHandler(CheckWeReadInlineAndExtraData(firstByteDonePromise: firstByteDonePromise,
                                                                                  secondByteDonePromise: secondByteDonePromise,
                                                                                  allDonePromise: allDonePromise))
        }
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        
        let completePromise = group.next().makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())
        
        // This request is safe to upgrade.
        var request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        request += "A"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(client.allocator.buffer(string: request))).wait())

        XCTAssertNoThrow(try firstByteDonePromise.futureResult.wait() as Void)

        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(client.allocator.buffer(string: "B"))).wait())
        
        XCTAssertNoThrow(try secondByteDonePromise.futureResult.wait() as Void)

        XCTAssertNoThrow(try allDonePromise.futureResult.wait() as Void)

        // Let the machinery do its thing.
        XCTAssertNoThrow(try completePromise.futureResult.wait())
        
        // At this time we want to assert that everything got called. Their own callbacks assert
        // that the ordering was correct.
        XCTAssert(upgradeHandlerCbFired.wrappedValue)
        XCTAssert(upgraderCbFired.wrappedValue)
        
        // We also want to confirm that the upgrade handler is no longer in the pipeline.
        try connectedServer.pipeline.assertDoesNotContainUpgrader()
        
        XCTAssertNoThrow(try allDonePromise.futureResult.wait())
    }

    func testDeliversBytesWhenRemovedDuringPartialUpgrade() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let delayer = UpgradeDelayer(forProtocol: "myproto")
        defer {
            delayer.unblockUpgrade()
        }
        XCTAssertNoThrow(try channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [delayer], completionHandler: { context in })).wait())

        // Let's send in an upgrade request.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try channel.writeInbound(channel.allocator.buffer(string: request)))
        channel.embeddedEventLoop.run()

        // Upgrade has been requested but not proceeded.
        XCTAssertNoThrow(try channel.pipeline.assertContainsUpgrader())
        XCTAssertNoThrow(try XCTAssertNil(channel.readInbound(as: ByteBuffer.self)))

        // The 101 has been sent.
        guard var responseBuffer = try assertNoThrowWithValue(channel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("did not send response")
            return
        }
        XCTAssertNoThrow(try XCTAssertNil(channel.readOutbound(as: ByteBuffer.self)))
        assertResponseIs(response: responseBuffer.readString(length: responseBuffer.readableBytes)!,
                         expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                         expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])

        // Now send in some more bytes.
        XCTAssertNoThrow(try channel.writeInbound(channel.allocator.buffer(string: "B")))
        XCTAssertNoThrow(try XCTAssertNil(channel.readInbound(as: ByteBuffer.self)))

        // Now we're going to remove the handler.
        XCTAssertNoThrow(try channel.pipeline.removeUpgrader())

        // This should have delivered the pending bytes and the buffered request, and in all ways have behaved
        // as though upgrade simply failed.
        XCTAssertEqual(try assertNoThrowWithValue(channel.readInbound(as: ByteBuffer.self)),
                       channel.allocator.buffer(string: "B"))
        XCTAssertNoThrow(try channel.pipeline.assertDoesNotContainUpgrader())
        XCTAssertNoThrow(try XCTAssertNil(channel.readOutbound(as: ByteBuffer.self)))
    }

    func testDeliversBytesWhenReentrantlyCalledInChannelReadCompleteOnRemoval() throws {
        // This is a very specific test: we want to make sure that even the very last gasp of the HTTPServerUpgradeHandler
        // can still deliver bytes if it gets them.
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let delayer = UpgradeDelayer(forProtocol: "myproto")
        defer {
            delayer.unblockUpgrade()
        }

        XCTAssertNoThrow(try channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [delayer], completionHandler: { context in })).wait())

        // Let's send in an upgrade request.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try channel.writeInbound(channel.allocator.buffer(string: request)))
        channel.embeddedEventLoop.run()

        // Upgrade has been requested but not proceeded.
        XCTAssertNoThrow(try channel.pipeline.assertContainsUpgrader())
        XCTAssertNoThrow(try XCTAssertNil(channel.readInbound(as: ByteBuffer.self)))

        // The 101 has been sent.
        guard var responseBuffer = try assertNoThrowWithValue(channel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("did not send response")
            return
        }
        XCTAssertNoThrow(try XCTAssertNil(channel.readOutbound(as: ByteBuffer.self)))
        assertResponseIs(response: responseBuffer.readString(length: responseBuffer.readableBytes)!,
                         expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                         expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])

        // Now send in some more bytes.
        XCTAssertNoThrow(try channel.writeInbound(channel.allocator.buffer(string: "B")))
        XCTAssertNoThrow(try XCTAssertNil(channel.readInbound(as: ByteBuffer.self)))

        // Ok, now we put in a special handler that does a weird readComplete hook thing.
        XCTAssertNoThrow(try channel.pipeline.addHandler(ReentrantReadOnChannelReadCompleteHandler()).wait())

        // Now we're going to remove the upgrade handler.
        XCTAssertNoThrow(try channel.pipeline.removeUpgrader())

        // We should have received B and then the re-entrant read in that order.
        XCTAssertEqual(try assertNoThrowWithValue(channel.readInbound(as: ByteBuffer.self)),
                       channel.allocator.buffer(string: "B"))
        XCTAssertEqual(try assertNoThrowWithValue(channel.readInbound(as: ByteBuffer.self)),
                       channel.allocator.buffer(string: "re-entrant read from channelReadComplete!"))
        XCTAssertNoThrow(try channel.pipeline.assertDoesNotContainUpgrader())
        XCTAssertNoThrow(try XCTAssertNil(channel.readOutbound(as: ByteBuffer.self)))
    }

    func testWeTolerateUpgradeFuturesFromWrongEventLoops() throws {
        let upgradeRequest = UnsafeMutableTransferBox<HTTPRequestHead?>(nil)
        let upgradeHandlerCbFired = UnsafeMutableTransferBox(false)
        let upgraderCbFired = UnsafeMutableTransferBox(false)
        let otherELG = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try otherELG.syncShutdownGracefully())
        }

        let upgrader = SuccessfulUpgrader(forProtocol: "myproto",
                                          requiringHeaders: ["kafkaesque"],
                                          buildUpgradeResponseFuture: {
                                            // this is the wrong EL
                                            otherELG.next().makeSucceededFuture($1)
        }) { req in
            upgradeRequest.wrappedValue = req
            XCTAssert(upgradeHandlerCbFired.wrappedValue)
            upgraderCbFired.wrappedValue = true
        }

        let (group, _, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [upgrader],
                                                                               extraHandlers: []) { (context) in
                                                                                // This is called before the upgrader gets called.
            XCTAssertNil(upgradeRequest.wrappedValue)
            upgradeHandlerCbFired.wrappedValue = true

            // We're closing the connection now.
            context.close(promise: nil)
        }
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completePromise = group.next().makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(client.allocator.buffer(string: request))).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try completePromise.futureResult.wait())

        // At this time we want to assert that everything got called. Their own callbacks assert
        // that the ordering was correct.
        XCTAssert(upgradeHandlerCbFired.wrappedValue)
        XCTAssert(upgraderCbFired.wrappedValue)

        // We also want to confirm that the upgrade handler is no longer in the pipeline.
        try connectedServer.pipeline.assertDoesNotContainUpgrader()
    }

    func testFailingToRemoveExtraHandlersThrowsError() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try? channel.finish())
        }

        let encoder = HTTPResponseEncoder()
        let handlers: [RemovableChannelHandler] = [HTTPServerPipelineHandler(), HTTPServerProtocolErrorHandler()]
        let upgradeHandler = HTTPServerUpgradeHandler(upgraders: [SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: [], onUpgradeComplete: { _ in })],
                                                      httpEncoder: encoder,
                                                      extraHTTPHandlers: handlers,
                                                      upgradeCompletionHandler: { _ in })

        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(encoder))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandlers(handlers))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(upgradeHandler))

        let userEventSaver = UserEventSaver<HTTPServerUpgradeEvents>()
        let dataRecorder = DataRecorder<HTTPServerRequestPart>()
        XCTAssertNoThrow(try channel.pipeline.addHandler(userEventSaver).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(dataRecorder).wait())

        // Remove one of the extra handlers.
        XCTAssertNoThrow(try channel.pipeline.removeHandler(handlers.last!).wait())

        let head = HTTPServerRequestPart.head(.init(version: .http1_1, method: .GET, uri: "/foo", headers: ["upgrade": "myproto"]))
        XCTAssertNoThrow(try channel.writeInbound(head))
        XCTAssertThrowsError(try channel.writeInbound(HTTPServerRequestPart.end(nil))) { error in
            XCTAssertEqual(error as? ChannelPipelineError, .notFound)
        }

        // Upgrade didn't complete, so no user event.
        XCTAssertTrue(userEventSaver.events.isEmpty)
        // Nothing should have been forwarded.
        XCTAssertTrue(dataRecorder.receivedData().isEmpty)
        // The upgrade handler should still be in the pipeline.
        try channel.pipeline.assertContainsUpgrader()
    }

    func testFailedUpgradeResponseWriteThrowsError() throws {
        final class FailAllWritesHandler: ChannelOutboundHandler {
            typealias OutboundIn = NIOAny
            struct FailAllWritesError: Error {}

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                promise?.fail(FailAllWritesError())
            }
        }

        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try? channel.finish())
        }

        let encoder = HTTPResponseEncoder()
        let handler = HTTPServerUpgradeHandler(upgraders: [SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: []) { _ in }],
                                               httpEncoder: encoder,
                                               extraHTTPHandlers: []) { (_: ChannelHandlerContext) in
            ()
        }

        XCTAssertNoThrow(try channel.pipeline.addHandler(FailAllWritesHandler()).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(encoder).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(handler).wait())

        let userEventSaver = UserEventSaver<HTTPServerUpgradeEvents>()
        let dataRecorder = DataRecorder<HTTPServerRequestPart>()
        XCTAssertNoThrow(try channel.pipeline.addHandler(userEventSaver).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(dataRecorder).wait())

        let head = HTTPServerRequestPart.head(.init(version: .http1_1, method: .GET, uri: "/foo", headers: ["upgrade": "myproto"]))
        XCTAssertNoThrow(try channel.writeInbound(head))
        XCTAssertThrowsError(try channel.writeInbound(HTTPServerRequestPart.end(nil))) { error in
            XCTAssert(error is FailAllWritesHandler.FailAllWritesError)
        }

        // Upgrade didn't complete, so no user event.
        XCTAssertTrue(userEventSaver.events.isEmpty)
        // Nothing should have been forwarded.
        XCTAssertTrue(dataRecorder.receivedData().isEmpty)
        // The upgrade handler should still be in the pipeline.
        try channel.pipeline.assertContainsUpgrader()
    }

    func testFailedUpgraderThrowsError() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try? channel.finish())
        }

        struct ImAfraidICantDoThatDave: Error {}

        let upgrader = DelayedUnsuccessfulUpgrader(forProtocol: "myproto")
        let encoder = HTTPResponseEncoder()
        let handler = HTTPServerUpgradeHandler(upgraders: [upgrader],
                                               httpEncoder: encoder,
                                               extraHTTPHandlers: []) { (_: ChannelHandlerContext) in
            // no-op.
            ()
        }

        let userEventSaver = UserEventSaver<HTTPServerUpgradeEvents>()
        let dataRecorder = DataRecorder<HTTPServerRequestPart>()

        XCTAssertNoThrow(try channel.pipeline.addHandler(encoder).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(handler).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(userEventSaver).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(dataRecorder).wait())

        let head = HTTPServerRequestPart.head(.init(version: .http1_1, method: .GET, uri: "/foo", headers: ["upgrade": "myproto"]))
        XCTAssertNoThrow(try channel.writeInbound(head))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Write another head, on a successful upgrade it will be unbuffered.
        XCTAssertNoThrow(try channel.writeInbound(head))

        // Unblock the upgrade.
        upgrader.unblockUpgrade(withError: ImAfraidICantDoThatDave())

        // Upgrade didn't complete, so no user event.
        XCTAssertTrue(userEventSaver.events.isEmpty)
        // Nothing should have been forwarded.
        XCTAssertTrue(dataRecorder.receivedData().isEmpty)
        // The upgrade handler should still be in the pipeline.
        try channel.pipeline.assertContainsUpgrader()
    }
}
