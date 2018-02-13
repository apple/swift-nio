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
@testable import NIO
@testable import NIOHTTP1

private extension ChannelPipeline {
    func assertDoesNotContain(handler: ChannelHandler) throws {
        do {
            let _ = try self.context(handler: handler).wait()
            XCTFail("Found handler")
        } catch ChannelPipelineError.notFound {
            // Nothing to see here
        }
    }
}

private func serverHTTPChannel(group: EventLoopGroup, handlers: [ChannelHandler]) throws -> Channel {
    return try ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.addHTTPServerHandlers().then {
                let futureResults = handlers.map { channel.pipeline.add(handler: $0) }
                return EventLoopFuture<Void>.andAll(futureResults, eventLoop: channel.eventLoop)
            }
        }.bind(host: "127.0.0.1", port: 0).wait()
}

private func connectedClientChannel(group: EventLoopGroup, serverAddress: SocketAddress) throws -> Channel {
    return try ClientBootstrap(group: group)
        .connect(to: serverAddress)
        .wait()
}

private func setUpTest(withHandlers handlers: [ChannelHandler]) throws -> (EventLoopGroup, Channel, Channel) {
    let group = MultiThreadedEventLoopGroup(numThreads: 1)
    let serverChannel = try serverHTTPChannel(group: group, handlers: handlers)
    let clientChannel = try connectedClientChannel(group: group, serverAddress: serverChannel.localAddress!)
    return (group, serverChannel, clientChannel)
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

    public func upgrade(ctx: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) {
        XCTFail("upgrade called")
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

    public func upgrade(ctx: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) {
        XCTFail("upgrade called")
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

    public func upgrade(ctx: ChannelHandlerContext, upgradeRequest: HTTPRequestHead) {
        self.onUpgradeComplete(upgradeRequest)
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

private extension ByteBuffer {
    static func forString(_ string: String) -> ByteBuffer {
        var buf = ByteBufferAllocator().buffer(capacity: string.utf8.count)
        buf.write(string: string)
        return buf
    }
}

class HTTPUpgradeTestCase: XCTestCase {
    func testUpgradeWithoutUpgrade() throws {
        let handler = HTTPServerUpgradeHandler(upgraders: [ExplodingUpgrader(forProtocol: "myproto")]) { _ in
            XCTFail("upgrade completed")
        }
        let (group, server, client) = try setUpTest(withHandlers: [handler])
        defer {
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString(request))).wait())

        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try client.pipeline.assertDoesNotContain(handler: handler)
    }

    func testUpgradeAfterInitialRequest() throws {
        let handler = HTTPServerUpgradeHandler(upgraders: [ExplodingUpgrader(forProtocol: "myproto")]) { _ in
            XCTFail("upgrade completed")
        }
        let (group, server, client) = try setUpTest(withHandlers: [handler])
        defer {
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        // This request fires a subsequent upgrade in immediately. It should also be ignored.
        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\n\r\nOPTIONS * HTTP/1.1\r\nHost: localhost\r\nUpgrade: myproto\r\nConnection: upgrade\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString(request))).wait())

        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try client.pipeline.assertDoesNotContain(handler: handler)
    }

    func testUpgradeHandlerBarfsOnUnexpectedOrdering() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertEqual(.some(false), try? channel.finish())
        }

        let handler = HTTPServerUpgradeHandler(upgraders: [ExplodingUpgrader(forProtocol: "myproto")]) { _ in
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
        try channel.pipeline.assertDoesNotContain(handler: handler)
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
        let handler = HTTPServerUpgradeHandler(upgraders: [upgrader]) { ctx in
            // This is called before the upgrader gets called.
            XCTAssertNil(upgradeRequest)
            upgradeHandlerCbFired = true

            // We're closing the connection now.
            ctx.close(promise: nil)
        }

        let (group, server, client) = try setUpTest(withHandlers: [handler])
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completePromise: EventLoopPromise<Void> = group.next().newPromise()
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["x-upgrade-complete: true", "upgrade: myproto", "connection: upgrade"])
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
        try client.pipeline.assertDoesNotContain(handler: handler)
    }

    func testUpgradeRequiresCorrectHeaders() throws {
        let handler = HTTPServerUpgradeHandler(upgraders: [ExplodingUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"])]) { _ in
            XCTFail("upgrade completed")
        }
        let (group, server, client) = try setUpTest(withHandlers: [handler])
        defer {
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nConnection: upgrade\r\nUpgrade: myproto\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString(request))).wait())

        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try client.pipeline.assertDoesNotContain(handler: handler)
    }

    func testUpgradeRequiresHeadersInConnection() throws {
        let handler = HTTPServerUpgradeHandler(upgraders: [ExplodingUpgrader(forProtocol: "myproto", requiringHeaders: ["kafkaesque"])]) { _ in
            XCTFail("upgrade completed")
        }
        let (group, server, client) = try setUpTest(withHandlers: [handler])
        defer {
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nConnection: upgrade\r\nUpgrade: myproto\r\nKafkaesque: true\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString(request))).wait())

        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try client.pipeline.assertDoesNotContain(handler: handler)
    }

    func testUpgradeOnlyHandlesKnownProtocols() throws {
        let handler = HTTPServerUpgradeHandler(upgraders: [ExplodingUpgrader(forProtocol: "myproto")]) { _ in
            XCTFail("upgrade completed")
        }
        let (group, server, client) = try setUpTest(withHandlers: [handler])
        defer {
            XCTAssertNoThrow(try client.close().wait())
            XCTAssertNoThrow(try server.close().wait())
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let request = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nConnection: upgrade\r\nUpgrade: something-else\r\n\r\n"
        XCTAssertNoThrow(try client.writeAndFlush(NIOAny(ByteBuffer.forString(request))).wait())

        // At this time the channel pipeline should not contain our handler: it should have removed itself.
        try client.pipeline.assertDoesNotContain(handler: handler)
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
        let handler = HTTPServerUpgradeHandler(upgraders: [explodingUpgrader, successfulUpgrader]) { ctx in
            // This is called before the upgrader gets called.
            XCTAssertNil(upgradeRequest)
            upgradeHandlerCbFired = true

            // We're closing the connection now.
            ctx.close(promise: nil)
        }

        let (group, server, client) = try setUpTest(withHandlers: [handler])
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completePromise: EventLoopPromise<Void> = group.next().newPromise()
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["x-upgrade-complete: true", "upgrade: myproto", "connection: upgrade"])
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
        try client.pipeline.assertDoesNotContain(handler: handler)
    }

    func testUpgradeFiresUserEvent() throws {
        // The user event is fired last, so we don't see it until both other callbacks
        // have fired.
        let eventSaver = UserEventSaver<HTTPUpgradeEvents>()

        let upgrader = SuccessfulUpgrader(forProtocol: "myproto", requiringHeaders: []) { req in
            XCTAssertEqual(eventSaver.events.count, 0)
        }
        let handler = HTTPServerUpgradeHandler(upgraders: [upgrader]) { ctx in
            XCTAssertEqual(eventSaver.events.count, 0)
            ctx.close(promise: nil)
        }

        let (group, server, client) = try setUpTest(withHandlers: [handler, eventSaver])
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completePromise: EventLoopPromise<Void> = group.next().newPromise()
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["x-upgrade-complete: true", "upgrade: myproto", "connection: upgrade"])
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
        XCTAssertNoThrow(try group.next().scheduleTask(in: .nanoseconds(0)) {
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
        try client.pipeline.assertDoesNotContain(handler: handler)
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
        let handler = HTTPServerUpgradeHandler(upgraders: [explodingUpgrader, successfulUpgrader]) { ctx in
            // This is called before the upgrader gets called.
            XCTAssertNil(upgradeRequest)
            upgradeHandlerCbFired = true

            // We're closing the connection now.
            ctx.close(promise: nil)
        }
        let errorCatcher = ErrorSaver()

        let (group, server, client) = try setUpTest(withHandlers: [handler, errorCatcher])
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let completePromise: EventLoopPromise<Void> = group.next().newPromise()
        let clientHandler = ArrayAccumulationHandler<ByteBuffer> { buffers in
            let resultString = buffers.map { $0.getString(at: $0.readerIndex, length: $0.readableBytes)! }.joined(separator: "")
            assertResponseIs(response: resultString,
                             expectedResponseLine: "HTTP/1.1 101 Switching Protocols",
                             expectedResponseHeaders: ["x-upgrade-complete: true", "upgrade: myproto", "connection: upgrade"])
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
        try client.pipeline.assertDoesNotContain(handler: handler)

        // And we want to confirm we saved the error.
        XCTAssertEqual(errorCatcher.errors.count, 1)

        switch(errorCatcher.errors[0]) {
        case UpgraderSaysNo.No.no:
            break
        default:
            XCTFail("Unexpected error: \(errorCatcher.errors[0])")
        }
    }
}
