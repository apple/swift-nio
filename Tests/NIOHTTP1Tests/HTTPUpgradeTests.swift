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
import Dispatch
@testable import NIO
@testable import NIOHTTP1

extension ChannelPipeline {
    func assertDoesNotContainUpgrader() throws {
        try self.assertDoesNotContain(handlerType: HTTPServerUpgradeHandler.self)
    }

    func assertDoesNotContain<T>(handlerType: T.Type) throws {
        do {
            _ = try self.context(handlerType: handlerType).wait()
            XCTFail("Found handler")
        } catch ChannelPipelineError.notFound {
            // Nothing to see here
        }
    }

    func assertContainsUpgrader() throws {
        try self.assertContains(handlerType: HTTPServerUpgradeHandler.self)
    }

    func assertContains<T>(handlerType: T.Type) throws {
        do {
            _ = try self.context(handlerType: handlerType).wait()
        } catch ChannelPipelineError.notFound {
            XCTFail("Did not find handler")
        }
    }

    // Waits up to 1 second for the upgrader to be removed by polling the pipeline
    // every 50ms checking for the handler.
    func waitForUpgraderToBeRemoved() throws {
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
    func readAllOutboundBuffers() -> ByteBuffer {
        var buffer = self.allocator.buffer(capacity: 100)
        while case .some(.byteBuffer(var writtenData)) = self.readOutbound() {
            buffer.write(buffer: &writtenData)
        }

        return buffer
    }
}

private func serverHTTPChannelWithAutoremoval(group: EventLoopGroup,
                                              pipelining: Bool,
                                              upgraders: [HTTPProtocolUpgrader],
                                              extraHandlers: [ChannelHandler],
                                              _ upgradeCompletionHandler: @escaping (ChannelHandlerContext) -> Void) throws -> (Channel, EventLoopFuture<Channel>) {
    let p: EventLoopPromise<Channel> = group.next().newPromise()
    let c = try ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        .childChannelInitializer { channel in
            p.succeed(result: channel)
            let upgradeConfig = (upgraders: upgraders, completionHandler: upgradeCompletionHandler)
            return channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: pipelining, withServerUpgrade: upgradeConfig).then {
                let futureResults = extraHandlers.map { channel.pipeline.add(handler: $0) }
                return EventLoopFuture<Void>.andAll(futureResults, eventLoop: channel.eventLoop)
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

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        self.receiveds.append(buffer)
        if let finalBytes = buffer.getBytes(at: buffer.writerIndex - 4, length: 4), finalBytes == [0x0D, 0x0A, 0x0D, 0x0A] {
            self.allDoneBlock(self.receiveds)
        }
    }
}

private class ExplodingHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        XCTFail("Received unexpected read")
    }
}

private func connectedClientChannel(group: EventLoopGroup, serverAddress: SocketAddress) throws -> Channel {
    return try ClientBootstrap(group: group)
        .connect(to: serverAddress)
        .wait()
}

private func setUpTestWithAutoremoval(pipelining: Bool = false,
                                      upgraders: [HTTPProtocolUpgrader],
                                      extraHandlers: [ChannelHandler],
                                      _ upgradeCompletionHandler: @escaping (ChannelHandlerContext) -> Void) throws -> (EventLoopGroup, Channel, Channel, Channel) {
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
        guard let index = lines.index(of: expectedHeader) else {
            XCTFail("Could not find header \"\(expectedHeader)\"")
            return
        }
        lines.remove(at: index)
    }

    // That should be all the headers.
    XCTAssertEqual(lines.count, 0)
}

private class ExplodingUpgrader: HTTPProtocolUpgrader {
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String]

    private enum Explosion: Error {
        case KABOOM
    }

    public init(forProtocol `protocol`: String, requiringHeaders: [String] = []) {
        self.supportedProtocol = `protocol`
        self.requiredUpgradeHeaders = requiringHeaders
    }

    public func buildUpgradeResponse(upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders) throws -> HTTPHeaders {
        XCTFail("buildUpgradeResponse called")
        throw Explosion.KABOOM
    }

    public func upgrade(ctx: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        XCTFail("upgrade called")
        return ctx.eventLoop.newSucceededFuture(result: ())
    }
}

private class UpgraderSaysNo: HTTPProtocolUpgrader {
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String] = []

    public enum No: Error {
        case no
    }

    public init(forProtocol `protocol`: String) {
        self.supportedProtocol = `protocol`
    }

    public func buildUpgradeResponse(upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders) throws -> HTTPHeaders {
        throw No.no
    }

    public func upgrade(ctx: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        XCTFail("upgrade called")
        return ctx.eventLoop.newSucceededFuture(result: ())
    }
}

private class SuccessfulUpgrader: HTTPProtocolUpgrader {
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String]
    private let onUpgradeComplete: (HTTPRequestHead) -> ()

    public init(forProtocol `protocol`: String, requiringHeaders headers: [String], onUpgradeComplete: @escaping (HTTPRequestHead) -> ()) {
        self.supportedProtocol = `protocol`
        self.requiredUpgradeHeaders = headers
        self.onUpgradeComplete = onUpgradeComplete
    }

    public func buildUpgradeResponse(upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders) throws -> HTTPHeaders {
        var headers = initialResponseHeaders
        headers.add(name: "X-Upgrade-Complete", value: "true")
        return headers
    }

    public func upgrade(ctx: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        self.onUpgradeComplete(upgradeRequest)
        return ctx.eventLoop.newSucceededFuture(result: ())
    }
}

private class UpgradeDelayer: HTTPProtocolUpgrader {
    let supportedProtocol: String
    let requiredUpgradeHeaders: [String] = []

    private var upgradePromise: EventLoopPromise<Void>?
    private var ctx: ChannelHandlerContext?

    public init(forProtocol `protocol`: String) {
        self.supportedProtocol = `protocol`
    }

    public func buildUpgradeResponse(upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders) throws -> HTTPHeaders {
        var headers = initialResponseHeaders
        headers.add(name: "X-Upgrade-Complete", value: "true")
        return headers
    }

    public func upgrade(ctx: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<Void> {
        self.upgradePromise = ctx.eventLoop.newPromise()
        self.ctx = ctx
        return self.upgradePromise!.futureResult
    }

    public func unblockUpgrade() {
        self.upgradePromise!.succeed(result: ())
    }
}

private class UserEventSaver<EventType>: ChannelInboundHandler {
    public typealias InboundIn = Any
    public var events: [EventType] = []

    public func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        events.append(event as! EventType)
        ctx.fireUserInboundEventTriggered(event)
    }
}

private class ErrorSaver: ChannelInboundHandler {
    public typealias InboundIn = Any
    public typealias InboundOut = Any
    public var errors: [Error] = []

    public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        errors.append(error)
        ctx.fireErrorCaught(error)
    }
}

private class DataRecorder<T>: ChannelInboundHandler {
    public typealias InboundIn = T
    private var data: [T] = []

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let datum = self.unwrapInboundIn(data)
        self.data.append(datum)
    }

    // Must be called from inside the event loop on pain of death!
    public func receivedData() ->[T] {
        return self.data
    }
}

private extension ByteBuffer {
    static func forString(_ string: String) -> ByteBuffer {
        var buf = ByteBufferAllocator().buffer(capacity: string.utf8.count)
        buf.write(string: string)
        return buf
    }
}

class HTTPUpgradeTestCase: XCTestCase {
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
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString(request))).wait())

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
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString(request))).wait())

        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testUpgradeHandlerBarfsOnUnexpectedOrdering() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertEqual(.some(false), try? channel.finish())
        }

        let handler = HTTPServerUpgradeHandler(upgraders: [ExplodingUpgrader(forProtocol: "myproto")],
                                               httpEncoder: HTTPResponseEncoder(),
                                               extraHTTPHandlers: []) { (_: ChannelHandlerContext) in
            XCTFail("upgrade completed")
        }
        let data = HTTPServerRequestPart.body(ByteBuffer.forString("hello"))

        XCTAssertNoThrow(try channel.pipeline.add(handler: handler).wait())

        do {
            try channel.writeInbound(data)
            XCTFail("Writing of bad data did not error")
        } catch HTTPUpgradeErrors.invalidHTTPOrdering {
            // Nothing to see here.
        }

        // The handler removed itself from the pipeline and passed the unexpected
        // data on.
        try channel.pipeline.assertDoesNotContainUpgrader()
        let receivedData: HTTPServerRequestPart = channel.readInbound()!
        XCTAssertEqual(data, receivedData)
    }

    func testSimpleUpgradeSucceeds() throws {
        var upgradeRequest: HTTPRequestHead? = nil
        var upgradeHandlerCbFired = false
        var upgraderCbFired = false

        let upgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"]) { req in
            upgradeRequest = req
            XCTAssert(upgradeHandlerCbFired)
            upgraderCbFired = true
        }

        let (group, server, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [upgrader],
                                                                                    extraHandlers: []) { (ctx) in
            // This is called before the upgrader gets called.
            XCTAssertNil(upgradeRequest)
            upgradeHandlerCbFired = true

            // We're closing the connection now.
            ctx.close(promise: nil)
        }
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completePromise: EventLoopPromise<Void> = group.next().newPromise()
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])
            completePromise.succeed(result: ())
        }
        XCTAssertNoThrow(try client.pipeline.add(handler: clientHandler).wait())

        // This request is safe to upgrade.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString(request))).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try completePromise.futureResult.wait())

        // At this time we want to assert that everything got called. Their own callbacks assert
        // that the ordering was correct.
        XCTAssert(upgradeHandlerCbFired)
        XCTAssert(upgraderCbFired)

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
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString(request))).wait())

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

        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nConnection: upgrade\r\nUpgrade: myproto\r\nKafkaesque: true\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString(request))).wait())

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
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString(request))).wait())

        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testUpgradeRespectsClientPreference() throws {
        var upgradeRequest: HTTPRequestHead? = nil
        var upgradeHandlerCbFired = false
        var upgraderCbFired = false

        let explodingUpgrader = ExplodingUpgrader(forProtocol: "exploder")
        let successfulUpgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"]) { req in
            upgradeRequest = req
            XCTAssert(upgradeHandlerCbFired)
            upgraderCbFired = true
        }

        let (group, server, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [explodingUpgrader, successfulUpgrader],
                                                                                    extraHandlers: []) { ctx in
            // This is called before the upgrader gets called.
            XCTAssertNil(upgradeRequest)
            upgradeHandlerCbFired = true

            // We're closing the connection now.
            ctx.close(promise: nil)
        }
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completePromise: EventLoopPromise<Void> = group.next().newPromise()
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])
            completePromise.succeed(result: ())
        }
        XCTAssertNoThrow(try client.pipeline.add(handler: clientHandler).wait())

        // This request is safe to upgrade.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto, exploder\r\nKafkaesque: yup\r\nConnection: upgrade, kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString(request))).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try completePromise.futureResult.wait())

        // At this time we want to assert that everything got called. Their own callbacks assert
        // that the ordering was correct.
        XCTAssert(upgradeHandlerCbFired)
        XCTAssert(upgraderCbFired)

        // We also want to confirm that the upgrade handler is no longer in the pipeline.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testUpgradeFiresUserEvent() throws {
        // The user event is fired last, so we don't see it until both other callbacks
        // have fired.
        let eventSaver = UserEventSaver<HTTPUpgradeEvents>()

        let upgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: []) { req in
            XCTAssertEqual(eventSaver.events.count, 0)
        }

        let (group, server, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [upgrader],
                                                                                    extraHandlers: [eventSaver]) { ctx in
            XCTAssertEqual(eventSaver.events.count, 0)
            ctx.close(promise: nil)
        }
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completePromise: EventLoopPromise<Void> = group.next().newPromise()
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])
            completePromise.succeed(result: ())
        }
        XCTAssertNoThrow(try client.pipeline.add(handler: clientHandler).wait())

        // This request is safe to upgrade.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade,kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString(request))).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try completePromise.futureResult.wait())

        // At this time we should have received one user event. We schedule this onto the
        // event loop to guarantee thread safety.
        XCTAssertNoThrow(try connectedServer.eventLoop.scheduleTask(in: .nanoseconds(0)) {
            XCTAssertEqual(eventSaver.events.count, 1)
            if case .upgradeComplete(let proto, let req) = eventSaver.events[0] {
                XCTAssertEqual(proto, "myproto")
                XCTAssertEqual(req.method, .OPTIONS)
                XCTAssertEqual(req.uri, "*")
                XCTAssertEqual(req.version, HTTPVersion(major: 1, minor: 1))
            } else {
                XCTFail("Unexpected event: \(eventSaver.events[0])")
            }
        }.futureResult.wait())

        // We also want to confirm that the upgrade handler is no longer in the pipeline.
        try connectedServer.pipeline.waitForUpgraderToBeRemoved()
    }

    func testUpgraderCanRejectUpgradeForPersonalReasons() throws {
        var upgradeRequest: HTTPRequestHead? = nil
        var upgradeHandlerCbFired = false
        var upgraderCbFired = false

        let explodingUpgrader = UpgraderSaysNo(forProtocol: "noproto")
        let successfulUpgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"]) { req in
            upgradeRequest = req
            XCTAssert(upgradeHandlerCbFired)
            upgraderCbFired = true
        }
        let errorCatcher = ErrorSaver()

        let (group, server, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [explodingUpgrader, successfulUpgrader],
                                                                                    extraHandlers: [errorCatcher]) { ctx in
            // This is called before the upgrader gets called.
            XCTAssertNil(upgradeRequest)
            upgradeHandlerCbFired = true

            // We're closing the connection now.
            ctx.close(promise: nil)
        }
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completePromise: EventLoopPromise<Void> = group.next().newPromise()
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])
            completePromise.succeed(result: ())
        }
        XCTAssertNoThrow(try client.pipeline.add(handler: clientHandler).wait())

        // This request is safe to upgrade.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: noproto,myproto\r\nKafkaesque: yup\r\nConnection: upgrade, kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString(request))).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try completePromise.futureResult.wait())

        // At this time we want to assert that everything got called. Their own callbacks assert
        // that the ordering was correct.
        XCTAssert(upgradeHandlerCbFired)
        XCTAssert(upgraderCbFired)

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
        let (group, server, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [upgrader],
                                                                                    extraHandlers: []) { ctx in
            ctx.close(promise: nil)
        }
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completePromise: EventLoopPromise<Void> = group.next().newPromise()
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])
            completePromise.succeed(result: ())
        }
        XCTAssertNoThrow(try client.pipeline.add(handler: clientHandler).wait())

        // This request is safe to upgrade.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nWeirdcase: yup\r\nConnection: upgrade,weirdcase\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(ByteBuffer.forString(request)).wait())

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
                                                                                    extraHandlers: []) { ctx in
            g.leave()
        }
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completePromise: EventLoopPromise<Void> = group.next().newPromise()
        let clientHandler = SingleHTTPResponseAccumulator { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])
            completePromise.succeed(result: ())
        }
        XCTAssertNoThrow(try client.pipeline.add(handler: clientHandler).wait())

        // This request is safe to upgrade.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nConnection: upgrade\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString(request))).wait())

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

        let (group, server, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [upgrader], extraHandlers: [dataRecorder]) { ctx in
            g.leave()
        }
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completePromise: EventLoopPromise<Void> = group.next().newPromise()
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])
            completePromise.succeed(result: ())
        }
        XCTAssertNoThrow(try client.pipeline.add(handler: clientHandler).wait())

        // This request is safe to upgrade, but is immediately followed by non-HTTP data that will probably
        // blow up the HTTP parser.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nConnection: upgrade\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString(request))).wait())

        // Wait for the upgrade machinery to run.
        g.wait()

        // Ok, send the application data in.
        let appData = "supersecretawesome data definitely not http\r\nawesome\r\ndata\ryeah"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString(appData))).wait())

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

    func testRemovesAllHTTPRelatedHandlersAfterUpgrade() throws {
        let upgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: []) { req in }
        let (group, server, client, connectedServer) = try setUpTestWithAutoremoval(pipelining: true,
                                                                                    upgraders: [upgrader],
                                                                                    extraHandlers: []) { ctx in }
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        // First, validate the pipeline is right.
        XCTAssertNoThrow(try connectedServer.pipeline.assertContains(handlerType: HTTPRequestDecoder.self))
        XCTAssertNoThrow(try connectedServer.pipeline.assertContains(handlerType: HTTPResponseEncoder.self))
        XCTAssertNoThrow(try connectedServer.pipeline.assertContains(handlerType: HTTPServerPipelineHandler.self))

        // This request is safe to upgrade.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString(request))).wait())

        // Let the machinery do its thing.
        XCTAssertNoThrow(try connectedServer.pipeline.waitForUpgraderToBeRemoved())

        // At this time we should validate that none of the HTTP handlers in the pipeline exist.
        XCTAssertNoThrow(try connectedServer.pipeline.assertDoesNotContain(handlerType: HTTPRequestDecoder.self))
        XCTAssertNoThrow(try connectedServer.pipeline.assertDoesNotContain(handlerType: HTTPResponseEncoder.self))
        XCTAssertNoThrow(try connectedServer.pipeline.assertDoesNotContain(handlerType: HTTPServerPipelineHandler.self))
    }

    @available(*, deprecated, message: "Tests deprecated function addHTTPServerHandlers")
    func testBasicUpgradePipelineMutation() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertFalse(try channel.finish())
        }
        let upgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: []) { req in }
        XCTAssertNoThrow(try channel.pipeline.addHTTPServerHandlersWithUpgrader(upgraders: [upgrader]) { ctx in }.wait())
        try channel.pipeline.assertContainsUpgrader()
        try channel.pipeline.assertContains(handlerType: HTTPRequestDecoder.self)
        try channel.pipeline.assertContains(handlerType: HTTPResponseEncoder.self)

        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nConnection: upgrade\r\n\r\n"
        XCTAssertNoThrow(try channel.writeInbound(ByteBuffer.forString(request)))

        var buffer = channel.readAllOutboundBuffers()
        XCTAssertEqual(buffer.readString(length: 34), "HTTP/1.1 101 Switching Protocols\r\n")
        try channel.pipeline.assertDoesNotContainUpgrader()
        try channel.pipeline.assertDoesNotContain(handlerType: HTTPRequestDecoder.self)
        try channel.pipeline.assertDoesNotContain(handlerType: HTTPResponseEncoder.self)
    }
    
    func testUpgradeWithUpgradePayloadInlineWithRequestWorks() throws {
        enum ReceivedTheWrongThingError: Error { case error }
        var upgradeRequest: HTTPRequestHead? = nil
        var upgradeHandlerCbFired = false
        var upgraderCbFired = false
        
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
            
            func handlerAdded(ctx: ChannelHandlerContext) {
                XCTAssertEqual(.fresh, self.state)
                self.state = .added
            }
            
            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                let buf = self.unwrapInboundIn(data)
                XCTAssertEqual(1, buf.readableBytes)
                let stringRead = buf.getString(at: 0, length: buf.readableBytes)
                switch self.state {
                case .added:
                    XCTAssertEqual("A", stringRead)
                    self.state = .inlineDataRead
                    if stringRead == .some("A") {
                        self.firstByteDonePromise.succeed(result: ())
                    } else {
                        self.firstByteDonePromise.fail(error: ReceivedTheWrongThingError.error)
                    }
                case .inlineDataRead:
                    XCTAssertEqual("B", stringRead)
                    self.state = .extraDataRead
                    ctx.channel.close(promise: nil)
                    if stringRead == .some("B") {
                        self.secondByteDonePromise.succeed(result: ())
                    } else {
                        self.secondByteDonePromise.fail(error: ReceivedTheWrongThingError.error)
                    }
                default:
                    XCTFail("channel read in wrong state \(self.state)")
                }
            }
            
            func close(ctx: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
                XCTAssertEqual(.extraDataRead, self.state)
                self.state = .closed
                ctx.close(mode: mode, promise: promise)
                
                self.allDonePromise.succeed(result: ())
            }
        }
        
        let upgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"]) { req in
            upgradeRequest = req
            XCTAssert(upgradeHandlerCbFired)
            upgraderCbFired = true
        }
        
        let promiseGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try promiseGroup.syncShutdownGracefully())
        }
        let firstByteDonePromise: EventLoopPromise<Void> = promiseGroup.next().newPromise()
        let secondByteDonePromise: EventLoopPromise<Void> = promiseGroup.next().newPromise()
        let allDonePromise: EventLoopPromise<Void> = promiseGroup.next().newPromise()
        let (group, server, client, connectedServer) = try setUpTestWithAutoremoval(upgraders: [upgrader],
                                                                                    extraHandlers: []) { (ctx) in
                                                                                        // This is called before the upgrader gets called.
                                                                                        XCTAssertNil(upgradeRequest)
                                                                                        upgradeHandlerCbFired = true
                                                                                        
                                                                                        _ = ctx.channel.pipeline.add(handler: CheckWeReadInlineAndExtraData(firstByteDonePromise: firstByteDonePromise,
                                                                                                                                                            secondByteDonePromise: secondByteDonePromise,
                                                                                                                                                            allDonePromise: allDonePromise))
        }
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        
        let completePromise: EventLoopPromise<Void> = group.next().newPromise()
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["X-Upgrade-Complete: true", "upgrade: myproto", "connection: upgrade"])
            completePromise.succeed(result: ())
        }
        XCTAssertNoThrow(try client.pipeline.add(handler: clientHandler).wait())
        
        // This request is safe to upgrade.
        var request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nKafkaesque: yup\r\nConnection: upgrade\r\nConnection: kafkaesque\r\n\r\n"
        request += "A"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString(request))).wait())

        XCTAssertNoThrow(try firstByteDonePromise.futureResult.wait() as Void)

        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString("B"))).wait())
        
        XCTAssertNoThrow(try secondByteDonePromise.futureResult.wait() as Void)

        XCTAssertNoThrow(try allDonePromise.futureResult.wait() as Void)

        // Let the machinery do its thing.
        XCTAssertNoThrow(try completePromise.futureResult.wait())
        
        // At this time we want to assert that everything got called. Their own callbacks assert
        // that the ordering was correct.
        XCTAssert(upgradeHandlerCbFired)
        XCTAssert(upgraderCbFired)
        
        // We also want to confirm that the upgrade handler is no longer in the pipeline.
        try connectedServer.pipeline.assertDoesNotContainUpgrader()
        
        XCTAssertNoThrow(try allDonePromise.futureResult.wait())
    }
}
