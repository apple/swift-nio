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

import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import XCTest

@testable import NIOHTTP1
@testable import NIOPosix

extension ChannelPipeline {
    fileprivate func assertDoesNotContainUpgrader() throws {
        try self.assertDoesNotContain(handlerType: HTTPServerUpgradeHandler.self)
    }

    func assertDoesNotContain<Handler: ChannelHandler & _NIOCoreSendableMetatype>(
        handlerType: Handler.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        do {
            try self.context(handlerType: handlerType)
                .map { context in
                    XCTFail("Found handler: \(context.handler)", file: (file), line: line)
                }.wait()
        } catch ChannelPipelineError.notFound {
            // Nothing to see here
        }
    }

    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    fileprivate func assertContainsUpgrader() {
        do {
            _ = try self.containsHandler(type: NIOTypedHTTPServerUpgradeHandler<Bool>.self).wait()
        } catch {
            self.assertContains(handlerType: HTTPServerUpgradeHandler.self)
        }
    }

    func assertContains<Handler: ChannelHandler & _NIOCoreSendableMetatype>(handlerType: Handler.Type) {
        XCTAssertNoThrow(try self.containsHandler(type: handlerType).wait(), "did not find handler")
    }

    fileprivate func removeUpgrader() throws {
        try self.context(handlerType: HTTPServerUpgradeHandler.self).flatMap {
            self.syncOperations.removeHandler(context: $0)
        }.wait()
    }

    // Waits up to 1 second for the upgrader to be removed by polling the pipeline
    // every 50ms checking for the handler.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    fileprivate func waitForUpgraderToBeRemoved() throws {
        for _ in 0..<20 {
            do {
                _ = try self.containsHandler(type: HTTPServerUpgradeHandler.self).wait()
                // handler present, keep waiting
                usleep(50)
            } catch ChannelPipelineError.notFound {
                // Checking if the typed variant is present
                do {
                    _ = try self.containsHandler(type: NIOTypedHTTPServerUpgradeHandler<Bool>.self).wait()
                    // handler present, keep waiting
                    usleep(50)
                } catch ChannelPipelineError.notFound {
                    // No upgrader, we're good.
                    return
                }
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

private typealias UpgradeCompletionHandler = @Sendable (ChannelHandlerContext) -> Void

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
private func serverHTTPChannelWithAutoremoval(
    group: EventLoopGroup,
    pipelining: Bool,
    upgraders: [any TypedAndUntypedHTTPServerProtocolUpgrader],
    extraHandlers: [ChannelHandler & Sendable],
    _ upgradeCompletionHandler: @escaping UpgradeCompletionHandler
) throws -> (Channel, EventLoopFuture<Channel>) {
    let p = group.next().makePromise(of: Channel.self)
    let c = try ServerBootstrap(group: group)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            p.succeed(channel)
            let upgradeConfig = (upgraders: upgraders, completionHandler: upgradeCompletionHandler)
            return channel.pipeline.configureHTTPServerPipeline(
                withPipeliningAssistance: pipelining,
                withServerUpgrade: upgradeConfig
            ).flatMap {
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

    init(completion: @escaping ([InboundIn]) -> Void) {
        self.allDoneBlock = completion
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = Self.unwrapInboundIn(data)
        self.receiveds.append(buffer)
        if let finalBytes = buffer.getBytes(at: buffer.writerIndex - 4, length: 4),
            finalBytes == [0x0D, 0x0A, 0x0D, 0x0A]
        {
            self.allDoneBlock(self.receiveds)
        }
    }
}

private class ExplodingHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        XCTFail("Received unexpected read")
    }
}

private func connectedClientChannel(group: EventLoopGroup, serverAddress: SocketAddress) throws -> Channel {
    try ClientBootstrap(group: group)
        .connect(to: serverAddress)
        .wait()
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

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
protocol TypedAndUntypedHTTPServerProtocolUpgrader: HTTPServerProtocolUpgrader, NIOTypedHTTPServerProtocolUpgrader
where UpgradeResult == Bool {}

private final class ExplodingUpgrader: TypedAndUntypedHTTPServerProtocolUpgrader, Sendable {
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String]

    private enum Explosion: Error {
        case KABOOM
    }

    init(forProtocol `protocol`: String, requiringHeaders: [String] = []) {
        self.supportedProtocol = `protocol`
        self.requiredUpgradeHeaders = requiringHeaders
    }

    func buildUpgradeResponse(
        channel: Channel,
        upgradeRequest: HTTPRequestHead,
        initialResponseHeaders: HTTPHeaders
    ) -> EventLoopFuture<HTTPHeaders> {
        XCTFail("buildUpgradeResponse called")
        return channel.eventLoop.makeFailedFuture(Explosion.KABOOM)
    }

    func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        XCTFail("upgrade called")
        return context.eventLoop.makeSucceededFuture(())
    }

    func upgrade(channel: Channel, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Bool> {
        XCTFail("upgrade called")
        return channel.eventLoop.makeSucceededFuture(true)
    }
}

private final class UpgraderSaysNo: TypedAndUntypedHTTPServerProtocolUpgrader, Sendable {
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String] = []

    enum No: Error {
        case no
    }

    init(forProtocol `protocol`: String) {
        self.supportedProtocol = `protocol`
    }

    func buildUpgradeResponse(
        channel: Channel,
        upgradeRequest: HTTPRequestHead,
        initialResponseHeaders: HTTPHeaders
    ) -> EventLoopFuture<HTTPHeaders> {
        channel.eventLoop.makeFailedFuture(No.no)
    }

    func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        XCTFail("upgrade called")
        return context.eventLoop.makeSucceededFuture(())
    }

    func upgrade(channel: Channel, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Bool> {
        XCTFail("upgrade called")
        return channel.eventLoop.makeSucceededFuture(true)
    }
}

private final class SuccessfulUpgrader: TypedAndUntypedHTTPServerProtocolUpgrader, Sendable {
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String]
    private let onUpgradeComplete: @Sendable (HTTPRequestHead) -> Void
    private let buildUpgradeResponseFuture: @Sendable (Channel, HTTPHeaders) -> EventLoopFuture<HTTPHeaders>

    init(
        forProtocol `protocol`: String,
        requiringHeaders headers: [String],
        buildUpgradeResponseFuture: @escaping @Sendable (Channel, HTTPHeaders) -> EventLoopFuture<HTTPHeaders>,
        onUpgradeComplete: @escaping @Sendable (HTTPRequestHead) -> Void
    ) {
        self.supportedProtocol = `protocol`
        self.requiredUpgradeHeaders = headers
        self.onUpgradeComplete = onUpgradeComplete
        self.buildUpgradeResponseFuture = buildUpgradeResponseFuture
    }

    convenience init(
        forProtocol `protocol`: String,
        requiringHeaders headers: [String],
        onUpgradeComplete: @escaping @Sendable (HTTPRequestHead) -> Void
    ) {
        self.init(
            forProtocol: `protocol`,
            requiringHeaders: headers,
            buildUpgradeResponseFuture: { $0.eventLoop.makeSucceededFuture($1) },
            onUpgradeComplete: onUpgradeComplete
        )
    }

    func buildUpgradeResponse(
        channel: Channel,
        upgradeRequest: HTTPRequestHead,
        initialResponseHeaders: HTTPHeaders
    ) -> EventLoopFuture<HTTPHeaders> {
        var headers = initialResponseHeaders
        headers.add(name: "X-Upgrade-Complete", value: "true")
        return self.buildUpgradeResponseFuture(channel, headers)
    }

    func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        self.onUpgradeComplete(upgradeRequest)
        return context.eventLoop.makeSucceededFuture(())
    }

    func upgrade(channel: Channel, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Bool> {
        self.onUpgradeComplete(upgradeRequest)
        return channel.eventLoop.makeSucceededFuture(true)
    }
}

private final class DelayedUnsuccessfulUpgrader: TypedAndUntypedHTTPServerProtocolUpgrader, Sendable {
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String]

    private let upgradePromise: EventLoopPromise<Bool>

    init(forProtocol `protocol`: String, eventLoop: EventLoop) {
        self.supportedProtocol = `protocol`
        self.upgradePromise = eventLoop.makePromise()
        self.requiredUpgradeHeaders = []
    }

    func buildUpgradeResponse(
        channel: Channel,
        upgradeRequest: HTTPRequestHead,
        initialResponseHeaders: HTTPHeaders
    ) -> EventLoopFuture<HTTPHeaders> {
        channel.eventLoop.makeSucceededFuture([:])
    }

    func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        self.upgradePromise.futureResult.map { _ in }
    }

    func unblockUpgrade(withError error: Error) {
        self.upgradePromise.fail(error)
    }

    func upgrade(channel: Channel, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Bool> {
        self.upgradePromise.futureResult
    }
}

private final class UpgradeDelayer: TypedAndUntypedHTTPServerProtocolUpgrader, Sendable {
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String] = []

    private let upgradePromise: EventLoopPromise<Bool>
    private let upgradeRequestedPromise: EventLoopPromise<Void>

    /// - Parameters:
    ///   - protocol: The protocol this upgrader knows how to support.
    ///   - upgradeRequestedPromise: Will be fulfilled when upgrade() is called
    init(forProtocol `protocol`: String, upgradeRequestedPromise: EventLoopPromise<Void>, eventLoop: any EventLoop) {
        self.supportedProtocol = `protocol`
        self.upgradePromise = eventLoop.makePromise()
        self.upgradeRequestedPromise = upgradeRequestedPromise
    }

    func buildUpgradeResponse(
        channel: Channel,
        upgradeRequest: HTTPRequestHead,
        initialResponseHeaders: HTTPHeaders
    ) -> EventLoopFuture<HTTPHeaders> {
        var headers = initialResponseHeaders
        headers.add(name: "X-Upgrade-Complete", value: "true")
        return channel.eventLoop.makeSucceededFuture(headers)
    }

    func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        upgradeRequestedPromise.succeed()
        return self.upgradePromise.futureResult.map { _ in }
    }

    func unblockUpgrade() {
        self.upgradePromise.succeed(true)
    }

    func upgrade(channel: Channel, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Bool> {
        self.upgradeRequestedPromise.succeed()
        return self.upgradePromise.futureResult
    }
}

private final class UpgradeResponseDelayer: HTTPServerProtocolUpgrader, Sendable {
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String] = []

    private let buildUpgradeResponseHandler: @Sendable () -> EventLoopFuture<Void>

    init(
        forProtocol `protocol`: String,
        buildUpgradeResponseHandler: @escaping @Sendable () -> EventLoopFuture<Void>
    ) {
        self.supportedProtocol = `protocol`
        self.buildUpgradeResponseHandler = buildUpgradeResponseHandler
    }

    func buildUpgradeResponse(
        channel: Channel,
        upgradeRequest: HTTPRequestHead,
        initialResponseHeaders: HTTPHeaders
    ) -> EventLoopFuture<HTTPHeaders> {
        self.buildUpgradeResponseHandler().map {
            var headers = initialResponseHeaders
            headers.add(name: "X-Upgrade-Complete", value: "true")
            return headers
        }
    }

    func upgrade(context: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        context.eventLoop.makeSucceededFuture(())
    }
}

private final class UserEventSaver<EventType: Sendable>: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any

    private let _events = NIOLockedValueBox<[EventType]>([])

    var events: [EventType] {
        self._events.withLockedValue { $0 }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        self._events.withLockedValue { $0.append(event as! EventType) }
        context.fireUserInboundEventTriggered(event)
    }
}

private final class ErrorSaver: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any
    typealias InboundOut = Any

    private let _errors = NIOLockedValueBox<[any Error]>([])

    var errors: [Error] {
        self._errors.withLockedValue { $0 }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self._errors.withLockedValue { $0.append(error) }
        context.fireErrorCaught(error)
    }
}

private final class DataRecorder<T: Sendable>: ChannelInboundHandler, Sendable {
    typealias InboundIn = T

    private let data = NIOLockedValueBox<[T]>([])

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let datum = Self.unwrapInboundIn(data)
        self.data.withLockedValue { $0.append(datum) }
    }

    // Must be called from inside the event loop on pain of death!
    func receivedData() -> [T] {
        self.data.withLockedValue { $0 }
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
            context.channel.pipeline.fireChannelRead(data)
        }
        context.fireChannelReadComplete()
    }
}

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
class HTTPServerUpgradeTestCase: XCTestCase {

    static let eventLoop = MultiThreadedEventLoopGroup.singleton.next()

    fileprivate func setUpTestWithAutoremoval(
        pipelining: Bool = false,
        upgraders: [any TypedAndUntypedHTTPServerProtocolUpgrader],
        extraHandlers: [ChannelHandler & Sendable],
        notUpgradingHandler: (@Sendable (Channel) -> EventLoopFuture<Bool>)? = nil,
        upgradeErrorHandler: (@Sendable (Error) -> Void)? = nil,
        _ upgradeCompletionHandler: @escaping UpgradeCompletionHandler
    ) throws -> (Channel, Channel, Channel) {
        let (serverChannel, connectedServerChannelFuture) = try serverHTTPChannelWithAutoremoval(
            group: Self.eventLoop,
            pipelining: pipelining,
            upgraders: upgraders,
            extraHandlers: extraHandlers,
            upgradeCompletionHandler
        )
        let clientChannel = try connectedClientChannel(
            group: Self.eventLoop,
            serverAddress: serverChannel.localAddress!
        )
        return (serverChannel, clientChannel, try connectedServerChannelFuture.wait())
    }

    func testUpgradeWithoutUpgrade() throws {
        let (server, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [ExplodingUpgrader(forProtocol: "myproto")],
            extraHandlers: []
        ) { (_: ChannelHandlerContext) in
            XCTFail("upgrade completed")
        }
        defer {
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
        }

        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testUpgradeAfterInitialRequest() throws {
        let (server, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [ExplodingUpgrader(forProtocol: "myproto")],
            extraHandlers: []
        ) { (_: ChannelHandlerContext) in
            XCTFail("upgrade completed")
        }
        defer {
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
        }

        // This request fires a subsequent upgrade in immediately. It should also be ignored.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\n\r\nOPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nConnection: upgrade\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testUpgradeHandlerBarfsOnUnexpectedOrdering() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertEqual(true, try? channel.finish().isClean)
        }

        let handler = HTTPServerUpgradeHandler(
            upgraders: [ExplodingUpgrader(forProtocol: "myproto")],
            httpEncoder: HTTPResponseEncoder(),
            extraHTTPHandlers: []
        ) { (_: ChannelHandlerContext) in
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

        let (_, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [upgrader],
            extraHandlers: []
        ) { (context) in
            // This is called before the upgrader gets called.
            XCTAssertNil(upgradeRequest.wrappedValue)
            upgradeHandlerCbFired.wrappedValue = true

            // We're closing the connection now.
            context.close(promise: nil)
        }

        let completePromise = Self.eventLoop.makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(
                separator: ""
            )
            assertResponseIs(
                response: resultString,
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"]
            )
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

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
        let (server, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [ExplodingUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"])],
            extraHandlers: []
        ) { (_: ChannelHandlerContext) in
            XCTFail("upgrade completed")
        }
        defer {
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
        }

        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nConnection: upgrade\r\nUpgrade: myproto\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testUpgradeRequiresHeadersInConnection() throws {
        let (server, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [ExplodingUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"])],
            extraHandlers: []
        ) { (_: ChannelHandlerContext) in
            XCTFail("upgrade completed")
        }
        defer {
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
        }

        // This request is missing a 'Kafkaesque' connection header.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nConnection: upgrade\r\nUpgrade: myproto\r\nKafkaesque: true\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testUpgradeOnlyHandlesKnownProtocols() throws {
        let (server, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [ExplodingUpgrader(forProtocol: "myproto")],
            extraHandlers: []
        ) { (_: ChannelHandlerContext) in
            XCTFail("upgrade completed")
        }
        defer {
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
        }

        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nConnection: upgrade\r\nUpgrade: something-else\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

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

        let (_, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [explodingUpgrader, successfulUpgrader],
            extraHandlers: []
        ) { context in
            // This is called before the upgrader gets called.
            XCTAssertNil(upgradeRequest.wrappedValue)
            upgradeHandlerCbFired.wrappedValue = true

            // We're closing the connection now.
            context.close(promise: nil)
        }

        let completePromise = Self.eventLoop.makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(
                separator: ""
            )
            assertResponseIs(
                response: resultString,
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"]
            )
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto, exploder\r\nKafkaesque: yup\r\nConnection: upgrade, kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

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

        let (_, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [upgrader],
            extraHandlers: [eventSaver.wrappedValue]
        ) { context in
            XCTAssertEqual(eventSaver.wrappedValue.events.count, 0)
            context.close(promise: nil)
        }

        let completePromise = Self.eventLoop.makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(
                separator: ""
            )
            assertResponseIs(
                response: resultString,
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"]
            )
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade,kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try completePromise.futureResult.wait())

        // At this time we should have received one user event. We schedule this onto the
        // event loop to guarantee thread safety.
        XCTAssertNoThrow(
            try connectedServer.eventLoop.scheduleTask(deadline: .now()) {
                XCTAssertEqual(eventSaver.wrappedValue.events.count, 1)
                if case .upgradeComplete(let proto, let req) = eventSaver.wrappedValue.events[0] {
                    XCTAssertEqual(proto, "myproto")
                    XCTAssertEqual(req.method, .OPTIONS)
                    XCTAssertEqual(req.uri, "*")
                    XCTAssertEqual(req.version, .http1_1)
                } else {
                    XCTFail("Unexpected event: \(eventSaver.wrappedValue.events[0])")
                }
            }.futureResult.wait()
        )

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

        let (_, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [explodingUpgrader, successfulUpgrader],
            extraHandlers: [errorCatcher]
        ) { context in
            // This is called before the upgrader gets called.
            XCTAssertNil(upgradeRequest.wrappedValue)
            upgradeHandlerCbFired.wrappedValue = true

            // We're closing the connection now.
            context.close(promise: nil)
        }

        let completePromise = Self.eventLoop.makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(
                separator: ""
            )
            assertResponseIs(
                response: resultString,
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"]
            )
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: noproto,myproto\r\nKafkaesque: yup\r\nConnection: upgrade, kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

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

        switch errorCatcher.errors[0] {
        case UpgraderSaysNo.No.no:
            break
        default:
            XCTFail("Unexpected error: \(errorCatcher.errors[0])")
        }
    }

    func testUpgradeIsCaseInsensitive() throws {
        let upgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: ["WeIrDcAsE"]) { req in }
        let (_, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [upgrader],
            extraHandlers: []
        ) { context in
            context.close(promise: nil)
        }

        let completePromise = Self.eventLoop.makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(
                separator: ""
            )
            assertResponseIs(
                response: resultString,
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"]
            )
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nWeirdcase: yup\r\nConnection: upgrade,weirdcase\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try completePromise.futureResult.wait())

        // We also want to confirm that the upgrade handler is no longer in the pipeline.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testDelayedUpgradeBehaviour() throws {
        let upgradeRequestPromise = Self.eventLoop.makePromise(of: Void.self)
        let upgrader = UpgradeDelayer(
            forProtocol: "myproto",
            upgradeRequestedPromise: upgradeRequestPromise,
            eventLoop: Self.eventLoop
        )
        let (server, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [upgrader],
            extraHandlers: []
        ) { context in }

        let completePromise = Self.eventLoop.makePromise(of: Void.self)

        let clientHandlerAdded = client.pipeline.eventLoop.submit {
            let clientHandler = SingleHTTPResponseAccumulator { buffers in
                let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(
                    separator: ""
                )
                assertResponseIs(
                    response: resultString,
                    expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                    expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"]
                )
                completePromise.succeed(())
            }

            return try client.pipeline.syncOperations.addHandler(clientHandler)
        }
        XCTAssertNoThrow(try clientHandlerAdded.wait())

        // This request is safe to upgrade.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nConnection: upgrade\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

        // Ok, we don't think this upgrade should have succeeded yet, but neither should it have failed. We want to
        // dispatch onto the server event loop and check that the channel still contains the upgrade handler.
        connectedServer.pipeline.assertContainsUpgrader()

        // Wait for the upgrade function to be called
        try upgradeRequestPromise.futureResult.wait()
        // Ok, let's unblock the upgrade now. The machinery should do its thing.
        try server.eventLoop.submit {
            upgrader.unblockUpgrade()
        }.wait()
        XCTAssertNoThrow(try completePromise.futureResult.wait())
        client.close(promise: nil)
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testBuffersInboundDataDuringDelayedUpgrade() throws {
        let upgradeRequestPromise = Self.eventLoop.makePromise(of: Void.self)
        let upgrader = UpgradeDelayer(
            forProtocol: "myproto",
            upgradeRequestedPromise: upgradeRequestPromise,
            eventLoop: Self.eventLoop
        )
        let dataRecorder = DataRecorder<ByteBuffer>()

        let (server, client, _) = try setUpTestWithAutoremoval(
            upgraders: [upgrader],
            extraHandlers: [dataRecorder]
        ) { context in }

        let completePromise = Self.eventLoop.makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(
                separator: ""
            )
            assertResponseIs(
                response: resultString,
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"]
            )
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade, but is immediately followed by non-HTTP data.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nConnection: upgrade\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

        // Ok, send the application data in.
        let appData = "supersecretawesome data definitely not http\r\nawesome\r\ndata\ryeah"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: appData)).wait())

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
        let resultString = data.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(
            separator: ""
        )
        XCTAssertEqual(resultString, appData)
    }

    func testDelayedUpgradeResponse() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let upgradeRequested = NIOLockedValueBox(false)

        let delayedPromise = channel.eventLoop.makePromise(of: Void.self)
        let delayedUpgrader = UpgradeResponseDelayer(forProtocol: "myproto") {
            XCTAssertFalse(upgradeRequested.withLockedValue { $0 })
            upgradeRequested.withLockedValue { $0 = true }
            return delayedPromise.futureResult
        }

        XCTAssertNoThrow(
            try channel.pipeline.configureHTTPServerPipeline(
                withServerUpgrade: (upgraders: [delayedUpgrader], completionHandler: { context in })
            ).wait()
        )

        // Let's send in an upgrade request.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try channel.writeInbound(channel.allocator.buffer(string: request)))

        // Upgrade has been requested but not proceeded.
        XCTAssertTrue(upgradeRequested.withLockedValue { $0 })
        channel.pipeline.assertContainsUpgrader()
        XCTAssertNoThrow(try XCTAssertNil(channel.readOutbound(as: ByteBuffer.self)))

        // Ok, now we can upgrade. Upgrader should be out of the pipeline, and we should have seen the 101 response.
        delayedPromise.succeed(())
        channel.embeddedEventLoop.run()
        XCTAssertNoThrow(try channel.pipeline.assertDoesNotContainUpgrader())
        XCTAssertNoThrow(
            assertResponseIs(
                response: try channel.readAllOutboundString(),
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: [
                    "X-Upgrade-Complete: true",
                    "upgrade: myproto",
                    "connection: upgrade",
                ]
            )
        )
    }

    func testChainsDelayedUpgradesAppropriately() throws {
        enum No: Error {
            case no
        }

        let channel = EmbeddedChannel()
        defer {
            XCTAssertTrue(try channel.finish().isClean)
        }

        let upgradingProtocol = NIOLockedValueBox("")

        let failingProtocolPromise = channel.eventLoop.makePromise(of: Void.self)
        let failingProtocolUpgrader = UpgradeResponseDelayer(forProtocol: "failingProtocol") {
            XCTAssertEqual(upgradingProtocol.withLockedValue { $0 }, "")
            upgradingProtocol.withLockedValue { $0 = "failingProtocol" }
            return failingProtocolPromise.futureResult
        }

        let myprotoPromise = channel.eventLoop.makePromise(of: Void.self)
        let myprotoUpgrader = UpgradeResponseDelayer(forProtocol: "myproto") {
            XCTAssertEqual(upgradingProtocol.withLockedValue { $0 }, "failingProtocol")
            upgradingProtocol.withLockedValue { $0 = "myproto" }
            return myprotoPromise.futureResult
        }

        XCTAssertNoThrow(
            try channel.pipeline.configureHTTPServerPipeline(
                withServerUpgrade: (
                    upgraders: [myprotoUpgrader, failingProtocolUpgrader], completionHandler: { context in }
                )
            ).wait()
        )

        // Let's send in an upgrade request.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: failingProtocol, myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try channel.writeInbound(channel.allocator.buffer(string: request)))

        // Upgrade has been requested but not proceeded for the failing protocol.
        XCTAssertEqual(upgradingProtocol.withLockedValue { $0 }, "failingProtocol")
        channel.pipeline.assertContainsUpgrader()
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self)))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())

        // Ok, now we'll fail the promise. This will catch an error, but the upgrade won't happen: instead, the second handler will be fired.
        failingProtocolPromise.fail(No.no)
        XCTAssertEqual(upgradingProtocol.withLockedValue { $0 }, "myproto")
        channel.pipeline.assertContainsUpgrader()
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self)))

        XCTAssertThrowsError(try channel.throwIfErrorCaught()) { error in
            XCTAssertEqual(.no, error as? No)
        }

        // Ok, now we can upgrade. Upgrader should be out of the pipeline, and we should have seen the 101 response.
        myprotoPromise.succeed(())
        channel.embeddedEventLoop.run()
        XCTAssertNoThrow(try channel.pipeline.assertDoesNotContainUpgrader())
        assertResponseIs(
            response: try channel.readAllOutboundString(),
            expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
            expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"]
        )
    }

    func testDelayedUpgradeResponseDeliversFullRequest() throws {
        enum No: Error {
            case no
        }

        let channel = EmbeddedChannel()
        defer {
            XCTAssertTrue(try channel.finish().isClean)
        }

        let upgradeRequested = NIOLockedValueBox(false)

        let delayedPromise = channel.eventLoop.makePromise(of: Void.self)
        let delayedUpgrader = UpgradeResponseDelayer(forProtocol: "myproto") {
            XCTAssertFalse(upgradeRequested.withLockedValue { $0 })
            upgradeRequested.withLockedValue { $0 = true }
            return delayedPromise.futureResult
        }

        XCTAssertNoThrow(
            try channel.pipeline.configureHTTPServerPipeline(
                withServerUpgrade: (upgraders: [delayedUpgrader], completionHandler: { context in })
            ).wait()
        )

        // Let's send in an upgrade request.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try channel.writeInbound(channel.allocator.buffer(string: request)))

        // Upgrade has been requested but not proceeded.
        XCTAssertTrue(upgradeRequested.withLockedValue { $0 })
        channel.pipeline.assertContainsUpgrader()
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

        let upgradeRequested = NIOLockedValueBox(false)

        let delayedPromise = channel.eventLoop.makePromise(of: Void.self)
        let delayedUpgrader = UpgradeResponseDelayer(forProtocol: "myproto") {
            XCTAssertFalse(upgradeRequested.withLockedValue { $0 })
            upgradeRequested.withLockedValue { $0 = true }
            return delayedPromise.futureResult
        }

        // Here we're disabling the pipeline handler, because otherwise it makes this test case impossible to reach.
        XCTAssertNoThrow(
            try channel.pipeline.configureHTTPServerPipeline(
                withPipeliningAssistance: false,
                withServerUpgrade: (upgraders: [delayedUpgrader], completionHandler: { context in })
            ).wait()
        )

        // Let's send in an upgrade request.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try channel.writeInbound(channel.allocator.buffer(string: request)))

        // Upgrade has been requested but not proceeded.
        XCTAssertTrue(upgradeRequested.withLockedValue { $0 })
        channel.pipeline.assertContainsUpgrader()
        XCTAssertNoThrow(XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self)))
        XCTAssertNoThrow(try channel.throwIfErrorCaught())

        // We now need to inject an extra buffered request. To do this we grab the context for the HTTPRequestDecoder and inject some reads.
        XCTAssertNoThrow(
            try channel.pipeline.context(handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self).map { context in
                let requestHead = HTTPServerRequestPart.head(.init(version: .http1_1, method: .GET, uri: "/test"))
                context.fireChannelRead(NIOAny(requestHead))
                context.fireChannelRead(NIOAny(HTTPServerRequestPart.end(nil)))
            }.wait()
        )

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
        let (_, client, connectedServer) = try setUpTestWithAutoremoval(
            pipelining: true,
            upgraders: [upgrader],
            extraHandlers: []
        ) { context in }

        // First, validate the pipeline is right.
        connectedServer.pipeline.assertContains(handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self)
        connectedServer.pipeline.assertContains(handlerType: HTTPResponseEncoder.self)
        connectedServer.pipeline.assertContains(handlerType: HTTPServerPipelineHandler.self)

        // This request is safe to upgrade.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try connectedServer.pipeline.waitForUpgraderToBeRemoved())

        // At this time we should validate that none of the HTTP handlers in the pipeline exist.
        XCTAssertNoThrow(
            try connectedServer.pipeline.assertDoesNotContain(
                handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self
            )
        )
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

            init(
                firstByteDonePromise: EventLoopPromise<Void>,
                secondByteDonePromise: EventLoopPromise<Void>,
                allDonePromise: EventLoopPromise<Void>
            ) {
                self.firstByteDonePromise = firstByteDonePromise
                self.secondByteDonePromise = secondByteDonePromise
                self.allDonePromise = allDonePromise
            }

            func handlerAdded(context: ChannelHandlerContext) {
                XCTAssertEqual(.fresh, self.state)
                self.state = .added
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buf = Self.unwrapInboundIn(data)
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
        let (_, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [upgrader],
            extraHandlers: []
        ) { (context) in
            // This is called before the upgrader gets called.
            XCTAssertNil(upgradeRequest.wrappedValue)
            upgradeHandlerCbFired.wrappedValue = true

            try! context.channel.pipeline.syncOperations.addHandler(
                CheckWeReadInlineAndExtraData(
                    firstByteDonePromise: firstByteDonePromise,
                    secondByteDonePromise: secondByteDonePromise,
                    allDonePromise: allDonePromise
                )
            )
        }

        let completePromise = Self.eventLoop.makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(
                separator: ""
            )
            assertResponseIs(
                response: resultString,
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"]
            )
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        var request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        request += "A"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

        XCTAssertNoThrow(try firstByteDonePromise.futureResult.wait() as Void)

        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: "B")).wait())

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

        let upgradeRequestPromise = Self.eventLoop.makePromise(of: Void.self)
        let delayer = UpgradeDelayer(
            forProtocol: "myproto",
            upgradeRequestedPromise: upgradeRequestPromise,
            eventLoop: Self.eventLoop
        )
        defer {
            delayer.unblockUpgrade()
        }
        XCTAssertNoThrow(
            try channel.pipeline.configureHTTPServerPipeline(
                withServerUpgrade: (upgraders: [delayer], completionHandler: { context in })
            ).wait()
        )

        // Let's send in an upgrade request.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try channel.writeInbound(channel.allocator.buffer(string: request)))
        channel.embeddedEventLoop.run()

        // Upgrade has been requested but not proceeded.
        channel.pipeline.assertContainsUpgrader()
        XCTAssertNoThrow(try XCTAssertNil(channel.readInbound(as: ByteBuffer.self)))

        // The 101 has been sent.
        guard var responseBuffer = try assertNoThrowWithValue(channel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("did not send response")
            return
        }
        XCTAssertNoThrow(try XCTAssertNil(channel.readOutbound(as: ByteBuffer.self)))
        assertResponseIs(
            response: responseBuffer.readString(length: responseBuffer.readableBytes)!,
            expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
            expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"]
        )

        // Now send in some more bytes.
        XCTAssertNoThrow(try channel.writeInbound(channel.allocator.buffer(string: "B")))
        XCTAssertNoThrow(try XCTAssertNil(channel.readInbound(as: ByteBuffer.self)))

        // Now we're going to remove the handler.
        XCTAssertNoThrow(try channel.pipeline.removeUpgrader())

        // This should have delivered the pending bytes and the buffered request, and in all ways have behaved
        // as though upgrade simply failed.
        XCTAssertEqual(
            try assertNoThrowWithValue(channel.readInbound(as: ByteBuffer.self)),
            channel.allocator.buffer(string: "B")
        )
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

        let upgradeRequestPromise = Self.eventLoop.makePromise(of: Void.self)
        let delayer = UpgradeDelayer(
            forProtocol: "myproto",
            upgradeRequestedPromise: upgradeRequestPromise,
            eventLoop: Self.eventLoop
        )
        defer {
            delayer.unblockUpgrade()
        }

        XCTAssertNoThrow(
            try channel.pipeline.configureHTTPServerPipeline(
                withServerUpgrade: (upgraders: [delayer], completionHandler: { context in })
            ).wait()
        )

        // Let's send in an upgrade request.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try channel.writeInbound(channel.allocator.buffer(string: request)))
        channel.embeddedEventLoop.run()

        // Upgrade has been requested but not proceeded.
        channel.pipeline.assertContainsUpgrader()
        XCTAssertNoThrow(try XCTAssertNil(channel.readInbound(as: ByteBuffer.self)))

        // The 101 has been sent.
        guard var responseBuffer = try assertNoThrowWithValue(channel.readOutbound(as: ByteBuffer.self)) else {
            XCTFail("did not send response")
            return
        }
        XCTAssertNoThrow(try XCTAssertNil(channel.readOutbound(as: ByteBuffer.self)))
        assertResponseIs(
            response: responseBuffer.readString(length: responseBuffer.readableBytes)!,
            expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
            expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"]
        )

        // Now send in some more bytes.
        XCTAssertNoThrow(try channel.writeInbound(channel.allocator.buffer(string: "B")))
        XCTAssertNoThrow(try XCTAssertNil(channel.readInbound(as: ByteBuffer.self)))

        // Ok, now we put in a special handler that does a weird readComplete hook thing.
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(ReentrantReadOnChannelReadCompleteHandler()))

        // Now we're going to remove the upgrade handler.
        XCTAssertNoThrow(try channel.pipeline.removeUpgrader())

        // We should have received B and then the re-entrant read in that order.
        XCTAssertEqual(
            try assertNoThrowWithValue(channel.readInbound(as: ByteBuffer.self)),
            channel.allocator.buffer(string: "B")
        )
        XCTAssertEqual(
            try assertNoThrowWithValue(channel.readInbound(as: ByteBuffer.self)),
            channel.allocator.buffer(string: "re-entrant read from channelReadComplete!")
        )
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
        let upgrader = SuccessfulUpgrader(
            forProtocol: "myproto",
            requiringHeaders: ["kafkaesque"]
        ) {
            // this is the wrong EL
            otherELG.next().makeSucceededFuture($1)
        } onUpgradeComplete: { req in
            upgradeRequest.wrappedValue = req
            XCTAssert(upgradeHandlerCbFired.wrappedValue)
            upgraderCbFired.wrappedValue = true
        }

        let (_, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [upgrader],
            extraHandlers: []
        ) { (context) in
            // This is called before the upgrader gets called.
            XCTAssertNil(upgradeRequest.wrappedValue)
            upgradeHandlerCbFired.wrappedValue = true

            // We're closing the connection now.
            context.close(promise: nil)
        }

        let completePromise = Self.eventLoop.makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(
                separator: ""
            )
            assertResponseIs(
                response: resultString,
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"]
            )
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

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
        let upgradeHandler = HTTPServerUpgradeHandler(
            upgraders: [SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: [], onUpgradeComplete: { _ in })],
            httpEncoder: encoder,
            extraHTTPHandlers: handlers,
            upgradeCompletionHandler: { _ in }
        )

        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(encoder))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandlers(handlers))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(upgradeHandler))

        let userEventSaver = UserEventSaver<HTTPServerUpgradeEvents>()
        let dataRecorder = DataRecorder<HTTPServerRequestPart>()
        XCTAssertNoThrow(try channel.pipeline.addHandler(userEventSaver).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(dataRecorder).wait())

        // Remove one of the extra handlers.
        XCTAssertNoThrow(try channel.pipeline.syncOperations.removeHandler(handlers.last!).wait())

        let head = HTTPServerRequestPart.head(
            .init(version: .http1_1, method: .GET, uri: "/foo", headers: ["upgrade": "myproto"])
        )
        XCTAssertNoThrow(try channel.writeInbound(head))
        XCTAssertThrowsError(try channel.writeInbound(HTTPServerRequestPart.end(nil))) { error in
            XCTAssertEqual(error as? ChannelPipelineError, .notFound)
        }

        // Upgrade didn't complete, so no user event.
        XCTAssertTrue(userEventSaver.events.isEmpty)
        // Nothing should have been forwarded.
        XCTAssertTrue(dataRecorder.receivedData().isEmpty)
        // The upgrade handler should still be in the pipeline.
        channel.pipeline.assertContainsUpgrader()
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
        let handler = HTTPServerUpgradeHandler(
            upgraders: [SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: []) { _ in }],
            httpEncoder: encoder,
            extraHTTPHandlers: []
        ) { (_: ChannelHandlerContext) in
            ()
        }

        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(FailAllWritesHandler()))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(encoder))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(handler))

        let userEventSaver = UserEventSaver<HTTPServerUpgradeEvents>()
        let dataRecorder = DataRecorder<HTTPServerRequestPart>()
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(userEventSaver))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(dataRecorder))

        let head = HTTPServerRequestPart.head(
            .init(version: .http1_1, method: .GET, uri: "/foo", headers: ["upgrade": "myproto"])
        )
        XCTAssertNoThrow(try channel.writeInbound(head))
        XCTAssertThrowsError(try channel.writeInbound(HTTPServerRequestPart.end(nil))) { error in
            XCTAssert(error is FailAllWritesHandler.FailAllWritesError)
        }

        // Upgrade didn't complete, so no user event.
        XCTAssertTrue(userEventSaver.events.isEmpty)
        // Nothing should have been forwarded.
        XCTAssertTrue(dataRecorder.receivedData().isEmpty)
        // The upgrade handler should still be in the pipeline.
        channel.pipeline.assertContainsUpgrader()
    }

    func testFailedUpgraderThrowsError() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try? channel.finish())
        }

        struct ImAfraidICantDoThatDave: Error {}

        let upgrader = DelayedUnsuccessfulUpgrader(forProtocol: "myproto", eventLoop: channel.eventLoop)
        let encoder = HTTPResponseEncoder()
        let handler = HTTPServerUpgradeHandler(
            upgraders: [upgrader],
            httpEncoder: encoder,
            extraHTTPHandlers: []
        ) { (_: ChannelHandlerContext) in
            // no-op.
            ()
        }

        let userEventSaver = UserEventSaver<HTTPServerUpgradeEvents>()
        let dataRecorder = DataRecorder<HTTPServerRequestPart>()

        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(encoder))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(handler))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(userEventSaver))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(dataRecorder))

        let head = HTTPServerRequestPart.head(
            .init(version: .http1_1, method: .GET, uri: "/foo", headers: ["upgrade": "myproto"])
        )
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
        channel.pipeline.assertContainsUpgrader()
    }
}

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
final class TypedHTTPServerUpgradeTestCase: HTTPServerUpgradeTestCase {
    fileprivate override func setUpTestWithAutoremoval(
        pipelining: Bool = false,
        upgraders: [any TypedAndUntypedHTTPServerProtocolUpgrader],
        extraHandlers: [ChannelHandler & Sendable],
        notUpgradingHandler: (@Sendable (Channel) -> EventLoopFuture<Bool>)? = nil,
        upgradeErrorHandler: (@Sendable (Error) -> Void)? = nil,
        _ upgradeCompletionHandler: @escaping UpgradeCompletionHandler
    ) throws -> (Channel, Channel, Channel) {
        let connectionChannelPromise = Self.eventLoop.makePromise(of: Channel.self)
        let serverChannelFuture = ServerBootstrap(group: Self.eventLoop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    connectionChannelPromise.succeed(channel)
                    var configuration = NIOUpgradableHTTPServerPipelineConfiguration(
                        upgradeConfiguration: .init(
                            upgraders: upgraders.map { $0 as! any NIOTypedHTTPServerProtocolUpgrader<Bool> },
                            notUpgradingCompletionHandler: {
                                notUpgradingHandler?($0) ?? $0.eventLoop.makeSucceededFuture(false)
                            }
                        )
                    )
                    configuration.enablePipelining = pipelining
                    return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                        configuration: configuration
                    )
                    .flatMap { result in
                        if result {
                            return channel.pipeline.context(handlerType: NIOTypedHTTPServerUpgradeHandler<Bool>.self)
                                .map {
                                    upgradeCompletionHandler($0)
                                }
                        } else {
                            return channel.eventLoop.makeSucceededVoidFuture()
                        }
                    }
                    .flatMapErrorThrowing { error in
                        upgradeErrorHandler?(error)
                        throw error
                    }
                }
                .flatMap { _ in
                    let futureResults = extraHandlers.map { channel.pipeline.addHandler($0) }
                    return EventLoopFuture.andAllSucceed(futureResults, on: channel.eventLoop)
                }
            }.bind(host: "127.0.0.1", port: 0)
        let clientChannel = try connectedClientChannel(
            group: Self.eventLoop,
            serverAddress: serverChannelFuture.wait().localAddress!
        )
        return (try serverChannelFuture.wait(), clientChannel, try connectionChannelPromise.futureResult.wait())
    }

    func testNotUpgrading() throws {
        let notUpgraderCbFired = UnsafeMutableTransferBox(false)

        let upgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"]) { _ in }

        let (_, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [upgrader],
            extraHandlers: []
        ) { channel in
            notUpgraderCbFired.wrappedValue = true
            // We're closing the connection now.
            channel.close(promise: nil)
            return channel.eventLoop.makeSucceededFuture(true)
        } _: { _ in
        }

        let completePromise = Self.eventLoop.makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(
                separator: ""
            )
            XCTAssertEqual(resultString, "")
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: notmyproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try completePromise.futureResult.wait())

        // At this time we want to assert that the not upgrader got called.
        XCTAssert(notUpgraderCbFired.wrappedValue)

        // We also want to confirm that the upgrade handler is no longer in the pipeline.
        try connectedServer.pipeline.assertDoesNotContainUpgrader()
    }

    // - MARK: The following tests are all overridden from the base class since they slightly differ in behaviour

    override func testSimpleUpgradeSucceeds() throws {
        // This test is different since we call the completionHandler after the upgrader
        // modified the pipeline in the typed version.
        let upgradeRequest = UnsafeMutableTransferBox<HTTPRequestHead?>(nil)
        let upgradeHandlerCbFired = UnsafeMutableTransferBox(false)
        let upgraderCbFired = UnsafeMutableTransferBox(false)

        let upgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"]) { req in
            // This is called before completion block.
            upgradeRequest.wrappedValue = req
            upgradeHandlerCbFired.wrappedValue = true

            XCTAssert(upgradeHandlerCbFired.wrappedValue)
            upgraderCbFired.wrappedValue = true
        }

        let (_, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [upgrader],
            extraHandlers: []
        ) { (context) in
            // This is called before the upgrader gets called.
            XCTAssertNotNil(upgradeRequest.wrappedValue)
            upgradeHandlerCbFired.wrappedValue = true

            // We're closing the connection now.
            context.close(promise: nil)
        }

        let completePromise = Self.eventLoop.makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(
                separator: ""
            )
            assertResponseIs(
                response: resultString,
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"]
            )
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try completePromise.futureResult.wait())

        // At this time we want to assert that everything got called. Their own callbacks assert
        // that the ordering was correct.
        XCTAssert(upgradeHandlerCbFired.wrappedValue)
        XCTAssert(upgraderCbFired.wrappedValue)

        // We also want to confirm that the upgrade handler is no longer in the pipeline.
        try connectedServer.pipeline.assertDoesNotContainUpgrader()
    }

    override func testUpgradeRespectsClientPreference() throws {
        // This test is different since we call the completionHandler after the upgrader
        // modified the pipeline in the typed version.
        let upgradeRequest = UnsafeMutableTransferBox<HTTPRequestHead?>(nil)
        let upgradeHandlerCbFired = UnsafeMutableTransferBox(false)
        let upgraderCbFired = UnsafeMutableTransferBox(false)

        let explodingUpgrader = ExplodingUpgrader(forProtocol: "exploder")
        let successfulUpgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"]) { req in
            upgradeRequest.wrappedValue = req
            XCTAssertFalse(upgradeHandlerCbFired.wrappedValue)
            upgraderCbFired.wrappedValue = true
        }

        let (_, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [explodingUpgrader, successfulUpgrader],
            extraHandlers: []
        ) { context in
            // This is called before the upgrader gets called.
            XCTAssertNotNil(upgradeRequest.wrappedValue)
            upgradeHandlerCbFired.wrappedValue = true

            // We're closing the connection now.
            context.close(promise: nil)
        }

        let completePromise = Self.eventLoop.makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(
                separator: ""
            )
            assertResponseIs(
                response: resultString,
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"]
            )
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto, exploder\r\nKafkaesque: yup\r\nConnection: upgrade, kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try completePromise.futureResult.wait())

        // At this time we want to assert that everything got called. Their own callbacks assert
        // that the ordering was correct.
        XCTAssert(upgradeHandlerCbFired.wrappedValue)
        XCTAssert(upgraderCbFired.wrappedValue)

        // We also want to confirm that the upgrade handler is no longer in the pipeline.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    override func testUpgraderCanRejectUpgradeForPersonalReasons() throws {
        // This test is different since we call the completionHandler after the upgrader
        // modified the pipeline in the typed version.
        let upgradeRequest = UnsafeMutableTransferBox<HTTPRequestHead?>(nil)
        let upgradeHandlerCbFired = UnsafeMutableTransferBox(false)
        let upgraderCbFired = UnsafeMutableTransferBox(false)

        let explodingUpgrader = UpgraderSaysNo(forProtocol: "noproto")
        let successfulUpgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"]) { req in
            upgradeRequest.wrappedValue = req
            XCTAssertFalse(upgradeHandlerCbFired.wrappedValue)
            upgraderCbFired.wrappedValue = true
        }
        let errorCatcher = ErrorSaver()

        let (_, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [explodingUpgrader, successfulUpgrader],
            extraHandlers: [errorCatcher]
        ) { context in
            // This is called before the upgrader gets called.
            XCTAssertNotNil(upgradeRequest.wrappedValue)
            upgradeHandlerCbFired.wrappedValue = true

            // We're closing the connection now.
            context.close(promise: nil)
        }

        let completePromise = Self.eventLoop.makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(
                separator: ""
            )
            assertResponseIs(
                response: resultString,
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"]
            )
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: noproto,myproto\r\nKafkaesque: yup\r\nConnection: upgrade, kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

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

        switch errorCatcher.errors[0] {
        case UpgraderSaysNo.No.no:
            break
        default:
            XCTFail("Unexpected error: \(errorCatcher.errors[0])")
        }
    }

    override func testUpgradeWithUpgradePayloadInlineWithRequestWorks() throws {
        // This test is different since we call the completionHandler after the upgrader
        // modified the pipeline in the typed version.
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

            init(
                firstByteDonePromise: EventLoopPromise<Void>,
                secondByteDonePromise: EventLoopPromise<Void>,
                allDonePromise: EventLoopPromise<Void>
            ) {
                self.firstByteDonePromise = firstByteDonePromise
                self.secondByteDonePromise = secondByteDonePromise
                self.allDonePromise = allDonePromise
            }

            func handlerAdded(context: ChannelHandlerContext) {
                XCTAssertEqual(.fresh, self.state)
                self.state = .added
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buf = Self.unwrapInboundIn(data)
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
            XCTAssertFalse(upgradeHandlerCbFired.wrappedValue)
            upgraderCbFired.wrappedValue = true
        }

        let promiseGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try promiseGroup.syncShutdownGracefully())
        }
        let firstByteDonePromise = promiseGroup.next().makePromise(of: Void.self)
        let secondByteDonePromise = promiseGroup.next().makePromise(of: Void.self)
        let allDonePromise = promiseGroup.next().makePromise(of: Void.self)
        let (_, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [upgrader],
            extraHandlers: []
        ) { (context) in
            // This is called before the upgrader gets called.
            XCTAssertNotNil(upgradeRequest.wrappedValue)
            upgradeHandlerCbFired.wrappedValue = true

            try! context.channel.pipeline.syncOperations.addHandler(
                CheckWeReadInlineAndExtraData(
                    firstByteDonePromise: firstByteDonePromise,
                    secondByteDonePromise: secondByteDonePromise,
                    allDonePromise: allDonePromise
                )
            )
        }

        let completePromise = Self.eventLoop.makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(
                separator: ""
            )
            assertResponseIs(
                response: resultString,
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"]
            )
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        var request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        request += "A"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

        XCTAssertNoThrow(try firstByteDonePromise.futureResult.wait() as Void)

        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: "B")).wait())

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

    override func testWeTolerateUpgradeFuturesFromWrongEventLoops() throws {
        // This test is different since we call the completionHandler after the upgrader
        // modified the pipeline in the typed version.
        let upgradeRequest = UnsafeMutableTransferBox<HTTPRequestHead?>(nil)
        let upgradeHandlerCbFired = UnsafeMutableTransferBox(false)
        let upgraderCbFired = UnsafeMutableTransferBox(false)
        let otherELG = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try otherELG.syncShutdownGracefully())
        }

        let upgrader = SuccessfulUpgrader(
            forProtocol: "myproto",
            requiringHeaders: ["kafkaesque"]
        ) {
            // this is the wrong EL
            otherELG.next().makeSucceededFuture($1)
        } onUpgradeComplete: { req in
            upgradeRequest.wrappedValue = req
            XCTAssertFalse(upgradeHandlerCbFired.wrappedValue)
            upgraderCbFired.wrappedValue = true
        }

        let (_, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [upgrader],
            extraHandlers: []
        ) { (context) in
            // This is called before the upgrader gets called.
            XCTAssertNotNil(upgradeRequest.wrappedValue)
            upgradeHandlerCbFired.wrappedValue = true

            // We're closing the connection now.
            context.close(promise: nil)
        }

        let completePromise = Self.eventLoop.makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(
                separator: ""
            )
            assertResponseIs(
                response: resultString,
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"]
            )
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try completePromise.futureResult.wait())

        // At this time we want to assert that everything got called. Their own callbacks assert
        // that the ordering was correct.
        XCTAssert(upgradeHandlerCbFired.wrappedValue)
        XCTAssert(upgraderCbFired.wrappedValue)

        // We also want to confirm that the upgrade handler is no longer in the pipeline.
        try connectedServer.pipeline.assertDoesNotContainUpgrader()
    }

    override func testUpgradeFiresUserEvent() throws {
        // This test is different since we call the completionHandler after the upgrader
        // modified the pipeline in the typed version.
        let eventSaver = UnsafeTransfer(UserEventSaver<HTTPServerUpgradeEvents>())

        let upgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: []) { req in
            XCTAssertEqual(eventSaver.wrappedValue.events.count, 0)
        }

        let (_, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [upgrader],
            extraHandlers: [eventSaver.wrappedValue]
        ) { context in
            XCTAssertEqual(eventSaver.wrappedValue.events.count, 1)
            context.close(promise: nil)
        }

        let completePromise = Self.eventLoop.makePromise(of: Void.self)
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(
                separator: ""
            )
            assertResponseIs(
                response: resultString,
                expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"]
            )
            completePromise.succeed(())
        }
        XCTAssertNoThrow(try client.pipeline.addHandler(clientHandler).wait())

        // This request is safe to upgrade.
        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade,kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try completePromise.futureResult.wait())

        // At this time we should have received one user event. We schedule this onto the
        // event loop to guarantee thread safety.
        XCTAssertNoThrow(
            try connectedServer.eventLoop.scheduleTask(deadline: .now()) {
                XCTAssertEqual(eventSaver.wrappedValue.events.count, 1)
                if case .upgradeComplete(let proto, let req) = eventSaver.wrappedValue.events[0] {
                    XCTAssertEqual(proto, "myproto")
                    XCTAssertEqual(req.method, .OPTIONS)
                    XCTAssertEqual(req.uri, "*")
                    XCTAssertEqual(req.version, .http1_1)
                } else {
                    XCTFail("Unexpected event: \(eventSaver.wrappedValue.events[0])")
                }
            }.futureResult.wait()
        )

        // We also want to confirm that the upgrade handler is no longer in the pipeline.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testHalfClosure() throws {
        let errorCaught = UnsafeMutableTransferBox<Bool>(false)

        let upgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"]) { req in
            XCTFail("Upgrade cannot be successful if we don't send any data to server")
        }
        let (_, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [upgrader],
            extraHandlers: [],
            upgradeErrorHandler: { error in
                switch error {
                case ChannelError.inputClosed:
                    errorCaught.wrappedValue = true
                default:
                    break
                }
            },
            { _ in }
        )

        try client.close(mode: .output).wait()
        try connectedServer.closeFuture.wait()
        XCTAssertEqual(errorCaught.wrappedValue, true)
    }

    /// Test that send a request and closing immediately performs a successful upgrade
    func testSendRequestCloseImmediately() throws {
        let upgradePerformed = UnsafeMutableTransferBox<Bool>(false)

        let upgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"]) { _ in
            upgradePerformed.wrappedValue = true
        }
        let (_, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [upgrader],
            extraHandlers: [],
            upgradeErrorHandler: { error in
                XCTFail("Error: \(error)")
            },
            { _ in }
        )

        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())
        try client.close(mode: .output).wait()
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
        XCTAssertEqual(upgradePerformed.wrappedValue, true)
    }

    /// Test that sending an unfinished upgrade request and closing immediately throws
    /// an input closed error
    func testSendUnfinishedRequestCloseImmediately() throws {
        let errorCaught = UnsafeMutableTransferBox<Bool>(false)

        let upgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"]) { _ in
        }
        let (_, client, connectedServer) = try setUpTestWithAutoremoval(
            upgraders: [upgrader],
            extraHandlers: [],
            upgradeErrorHandler: { error in
                switch error {
                case ChannelError.inputClosed:
                    errorCaught.wrappedValue = true
                default:
                    XCTFail("Error: \(error)")
                }
            },
            { _ in }
        )

        let request =
            "OPTIONS * HTTP/1.1\r\nHost: localhost\r\ncontent-length: 10\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(client.allocator.buffer(string: request)).wait())
        try client.close(mode: .output).wait()
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
        XCTAssertEqual(errorCaught.wrappedValue, true)
    }
}
