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

import NIOCore
import NIOEmbedded
import NIOTLS
import NIOTestUtils
import XCTest

private class ReadCompletedHandler: ChannelInboundHandler {
    public typealias InboundIn = Any
    public var readCompleteCount: Int

    init() {
        readCompleteCount = 0
    }

    public func channelReadComplete(context: ChannelHandlerContext) {
        readCompleteCount += 1
    }
}

final class DuplicatingReadHandler: ChannelInboundHandler {
    typealias InboundIn = String

    private let channel: EmbeddedChannel

    private var hasDuplicatedRead = false

    init(embeddedChannel: EmbeddedChannel) {
        self.channel = embeddedChannel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if !self.hasDuplicatedRead {
            self.hasDuplicatedRead = true
            try! self.channel.writeInbound(Self.unwrapInboundIn(data))
        }
        context.fireChannelRead(data)
    }
}

class ApplicationProtocolNegotiationHandlerTests: XCTestCase {
    private enum EventType {
        case basic
    }

    private let negotiatedEvent: TLSUserEvent = .handshakeCompleted(negotiatedProtocol: "h2")
    private let negotiatedResult: ALPNResult = .negotiated("h2")

    func testChannelProvidedToCallback() throws {
        let emChannel = EmbeddedChannel()
        let loop = emChannel.eventLoop as! EmbeddedEventLoop
        var called = false

        let handler = ApplicationProtocolNegotiationHandler { result, channel in
            called = true
            XCTAssertEqual(result, self.negotiatedResult)
            XCTAssertTrue(emChannel === channel)
            return loop.makeSucceededFuture(())
        }

        try emChannel.pipeline.syncOperations.addHandler(handler)
        emChannel.pipeline.fireUserInboundEventTriggered(negotiatedEvent)
        XCTAssertTrue(called)
    }

    func testIgnoresUnknownUserEvents() throws {
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop

        let handler = ApplicationProtocolNegotiationHandler { result in
            XCTFail("Negotiation fired")
            return loop.makeSucceededFuture(())
        }

        try channel.pipeline.syncOperations.addHandler(handler)

        // Fire a pair of events that should be ignored.
        channel.pipeline.fireUserInboundEventTriggered(EventType.basic)
        channel.pipeline.fireUserInboundEventTriggered(TLSUserEvent.shutdownCompleted)

        // The channel handler should still be in the pipeline.
        try channel.pipeline.assertContains(handler: handler)

        XCTAssertTrue(try channel.finish().isClean)
    }

    private func negotiateTest(event: TLSUserEvent, expectedResult: ALPNResult) throws {
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop
        let continuePromise = loop.makePromise(of: Void.self)

        var called = false

        let handler = ApplicationProtocolNegotiationHandler { result in
            XCTAssertEqual(self.negotiatedResult, result)
            called = true
            return continuePromise.futureResult
        }

        try channel.pipeline.syncOperations.addHandler(handler)

        // Fire the handshake complete event.
        channel.pipeline.fireUserInboundEventTriggered(negotiatedEvent)

        // At this time the callback should have fired, but the handler should still be in
        // the pipeline.
        XCTAssertTrue(called)
        try channel.pipeline.assertContains(handler: handler)

        // Now we fire the future.
        continuePromise.succeed(())

        // Now the handler should have removed itself from the pipeline.
        try channel.pipeline.assertDoesNotContain(handler: handler)

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testCallbackReflectsNotificationResult() throws {
        try negotiateTest(event: negotiatedEvent, expectedResult: negotiatedResult)
    }

    func testCallbackNotesFallbackForNoNegotiation() throws {
        try negotiateTest(event: .handshakeCompleted(negotiatedProtocol: ""), expectedResult: .fallback)
    }

    func testNoBufferingBeforeEventFires() throws {
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop

        let handler = ApplicationProtocolNegotiationHandler { result in
            XCTFail("Should not be called")
            return loop.makeSucceededFuture(())
        }

        try channel.pipeline.syncOperations.addHandler(handler)

        // The data we write should not be buffered.
        try channel.writeInbound("hello")
        XCTAssertNoThrow(XCTAssertEqual(try channel.readInbound()!, "hello"))

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testBufferingWhileWaitingForFuture() throws {
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop
        let continuePromise = loop.makePromise(of: Void.self)

        let handler = ApplicationProtocolNegotiationHandler { result in
            continuePromise.futureResult
        }

        try channel.pipeline.syncOperations.addHandler(handler)

        // Fire in the event.
        channel.pipeline.fireUserInboundEventTriggered(negotiatedEvent)

        // At this point all writes should be buffered.
        try channel.writeInbound("writes")
        try channel.writeInbound("are")
        try channel.writeInbound("buffered")
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))

        // Complete the pipeline swap.
        continuePromise.succeed(())

        // Now everything should have been unbuffered.
        XCTAssertNoThrow(XCTAssertEqual(try channel.readInbound()!, "writes"))
        XCTAssertNoThrow(XCTAssertEqual(try channel.readInbound()!, "are"))
        XCTAssertNoThrow(XCTAssertEqual(try channel.readInbound()!, "buffered"))

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testNothingBufferedDoesNotFireReadCompleted() throws {
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop
        let continuePromise = loop.makePromise(of: Void.self)

        let handler = ApplicationProtocolNegotiationHandler { result in
            continuePromise.futureResult
        }
        let readCompleteHandler = ReadCompletedHandler()

        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.pipeline.syncOperations.addHandler(readCompleteHandler)

        // Fire in the event.
        channel.pipeline.fireUserInboundEventTriggered(negotiatedEvent)

        // At this time, readComplete hasn't fired.
        XCTAssertEqual(readCompleteHandler.readCompleteCount, 0)

        // Now satisfy the future, which forces data unbuffering. As we haven't buffered any data,
        // readComplete should not be fired.
        continuePromise.succeed(())
        XCTAssertEqual(readCompleteHandler.readCompleteCount, 0)

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testUnbufferingFiresReadCompleted() throws {
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop
        let continuePromise = loop.makePromise(of: Void.self)

        let handler = ApplicationProtocolNegotiationHandler { result in
            continuePromise.futureResult
        }
        let readCompleteHandler = ReadCompletedHandler()

        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.pipeline.syncOperations.addHandler(readCompleteHandler)

        // Fire in the event.
        channel.pipeline.fireUserInboundEventTriggered(negotiatedEvent)

        // Send a write, which is buffered.
        try channel.writeInbound("a write")

        // At this time, readComplete hasn't fired.
        XCTAssertEqual(readCompleteHandler.readCompleteCount, 1)

        // Now satisfy the future, which forces data unbuffering. This should fire readComplete.
        continuePromise.succeed(())
        XCTAssertNoThrow(XCTAssertEqual(try channel.readInbound()!, "a write"))

        XCTAssertEqual(readCompleteHandler.readCompleteCount, 2)

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testUnbufferingHandlesReentrantReads() throws {
        let channel = EmbeddedChannel()
        let continuePromise = channel.eventLoop.makePromise(of: Void.self)

        let handler = ApplicationProtocolNegotiationHandler { result in
            continuePromise.futureResult
        }
        let readCompleteHandler = ReadCompletedHandler()

        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.pipeline.syncOperations.addHandler(DuplicatingReadHandler(embeddedChannel: channel))
        try channel.pipeline.syncOperations.addHandler(readCompleteHandler)

        // Fire in the event.
        channel.pipeline.fireUserInboundEventTriggered(negotiatedEvent)

        // Send a write, which is buffered.
        try channel.writeInbound("a write")

        // At this time, readComplete hasn't fired.
        XCTAssertEqual(readCompleteHandler.readCompleteCount, 1)

        // Now satisfy the future, which forces data unbuffering. This should fire readComplete.
        continuePromise.succeed(())
        XCTAssertNoThrow(XCTAssertEqual(try channel.readInbound()!, "a write"))
        XCTAssertNoThrow(XCTAssertEqual(try channel.readInbound()!, "a write"))

        XCTAssertEqual(readCompleteHandler.readCompleteCount, 3)

        XCTAssertTrue(try channel.finish().isClean)
    }
}
