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
import NIOTLS

private class ReadCompletedHandler: ChannelInboundHandler {
    public typealias InboundIn = Any
    public var readCompleteCount: Int

    init() {
        readCompleteCount = 0
    }

    public func channelReadComplete(ctx: ChannelHandlerContext) {
        readCompleteCount += 1
    }
}

class ApplicationProtocolNegotiationHandlerTests: XCTestCase {
    private enum EventType {
        case basic
    }

    func testIgnoresUnknownUserEvents() throws {
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop

        let handler = ApplicationProtocolNegotiationHandler { result in
            XCTFail("Negotiation fired")
            return loop.newSucceededFuture(result: ())
        }

        try channel.pipeline.add(handler: handler).wait()

        // Fire a pair of events that should be ignored.
        channel.pipeline.fireUserInboundEventTriggered(EventType.basic)
        channel.pipeline.fireUserInboundEventTriggered(TLSUserEvent.shutdownCompleted)

        // The channel handler should still be in the pipeline.
        try channel.pipeline.assertContains(handler: handler)

        XCTAssertFalse(try channel.finish())
    }

    private func negotiateTest(event: TLSUserEvent, expectedResult: ALPNResult) throws {
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop
        let continuePromise: EventLoopPromise<Void> = loop.newPromise()

        let expectedResult: ALPNResult = .negotiated("h2")
        var called = false

        let handler = ApplicationProtocolNegotiationHandler { result in
            XCTAssertEqual(expectedResult, result)
            called = true
            return continuePromise.futureResult
        }

        try channel.pipeline.add(handler: handler).wait()

        // Fire the handshake complete event.
        channel.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: "h2"))

        // At this time the callback should have fired, but the handler should still be in
        // the pipeline.
        XCTAssertTrue(called)
        try channel.pipeline.assertContains(handler: handler)

        // Now we fire the future.
        continuePromise.succeed(result: ())

        // Now the handler should have removed itself from the pipeline.
        try channel.pipeline.assertDoesNotContain(handler: handler)

        XCTAssertFalse(try channel.finish())
    }

    func testCallbackReflectsNotificationResult() throws {
        try negotiateTest(event: .handshakeCompleted(negotiatedProtocol: "h2"), expectedResult: .negotiated("h2"))
    }

    func testCallbackNotesFallbackForNoNegotiation() throws {
        try negotiateTest(event: .handshakeCompleted(negotiatedProtocol: ""), expectedResult: .fallback)
    }

    func testNoBufferingBeforeEventFires() throws {
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop

        let handler = ApplicationProtocolNegotiationHandler { result in
            XCTFail("Should not be called")
            return loop.newSucceededFuture(result: ())
        }

        try channel.pipeline.add(handler: handler).wait()

        // The data we write should not be buffered.
        try channel.writeInbound("hello")
        XCTAssertEqual(channel.readInbound()!, "hello")

        XCTAssertFalse(try channel.finish())
    }

    func testBufferingWhileWaitingForFuture() throws {
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop
        let continuePromise: EventLoopPromise<Void> = loop.newPromise()

        let handler = ApplicationProtocolNegotiationHandler { result in
            continuePromise.futureResult
        }

        try channel.pipeline.add(handler: handler).wait()

        // Fire in the event.
        channel.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: "h2"))

        // At this point all writes should be buffered.
        try channel.writeInbound("writes")
        try channel.writeInbound("are")
        try channel.writeInbound("buffered")
        XCTAssertNil(channel.readInbound())

        // Complete the pipeline swap.
        continuePromise.succeed(result: ())

        // Now everything should have been unbuffered.
        XCTAssertEqual(channel.readInbound()!, "writes")
        XCTAssertEqual(channel.readInbound()!, "are")
        XCTAssertEqual(channel.readInbound()!, "buffered")

        XCTAssertFalse(try channel.finish())
    }

    func testNothingBufferedDoesNotFireReadCompleted() throws {
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop
        let continuePromise: EventLoopPromise<Void> = loop.newPromise()

        let handler = ApplicationProtocolNegotiationHandler { result in
            continuePromise.futureResult
        }
        let readCompleteHandler = ReadCompletedHandler()

        try channel.pipeline.add(handler: handler).wait()
        try channel.pipeline.add(handler: readCompleteHandler).wait()

        // Fire in the event.
        channel.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: "h2"))

        // At this time, readComplete hasn't fired.
        XCTAssertEqual(readCompleteHandler.readCompleteCount, 0)

        // Now satisfy the future, which forces data unbuffering. As we haven't buffered any data,
        // readComplete should not be fired.
        continuePromise.succeed(result: ())
        XCTAssertEqual(readCompleteHandler.readCompleteCount, 0)

        XCTAssertFalse(try channel.finish())
    }

    func testUnbufferingFiresReadCompleted() throws {
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop
        let continuePromise: EventLoopPromise<Void> = loop.newPromise()

        let handler = ApplicationProtocolNegotiationHandler { result in
            continuePromise.futureResult
        }
        let readCompleteHandler = ReadCompletedHandler()

        try channel.pipeline.add(handler: handler).wait()
        try channel.pipeline.add(handler: readCompleteHandler).wait()

        // Fire in the event.
        channel.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: "h2"))

        // Send a write, which is buffered.
        try channel.writeInbound("a write")

        // At this time, readComplete hasn't fired.
        XCTAssertEqual(readCompleteHandler.readCompleteCount, 1)

        // Now satisfy the future, which forces data unbuffering. This should fire readComplete.
        continuePromise.succeed(result: ())
        XCTAssertEqual(channel.readInbound()!, "a write")

        XCTAssertEqual(readCompleteHandler.readCompleteCount, 2)

        XCTAssertFalse(try channel.finish())
    }
}
