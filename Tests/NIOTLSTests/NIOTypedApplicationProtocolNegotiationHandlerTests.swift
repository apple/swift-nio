//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@_spi(AsyncChannel) import NIOTLS
@_spi(AsyncChannel) import NIOCore
import NIOEmbedded
import XCTest
import NIOTestUtils

final class NIOTypedApplicationProtocolNegotiationHandlerTests: XCTestCase {
    enum NegotiationResult: Equatable {
        case negotiated(ALPNResult)
        case failed
    }

    private let negotiatedEvent: TLSUserEvent = .handshakeCompleted(negotiatedProtocol: "h2")
    private let negotiatedResult: ALPNResult = .negotiated("h2")

    func testChannelProvidedToCallback() throws {
        let emChannel = EmbeddedChannel()
        let loop = emChannel.eventLoop as! EmbeddedEventLoop
        var called = false

        let handler = NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult>(eventLoop: loop) { result, channel in
            called = true
            XCTAssertEqual(result, self.negotiatedResult)
            XCTAssertTrue(emChannel === channel)
            return loop.makeSucceededFuture(.finished(.negotiated(result)))
        }

        try emChannel.pipeline.addHandler(handler).wait()
        emChannel.pipeline.fireUserInboundEventTriggered(negotiatedEvent)
        XCTAssertTrue(called)

        XCTAssertEqual(try handler.protocolNegotiationResult.wait(), .finished(.negotiated(negotiatedResult)))
    }

    func testIgnoresUnknownUserEvents() throws {
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop

        let handler = NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult>(eventLoop: loop) { result in
            XCTFail("Negotiation fired")
            return loop.makeSucceededFuture(.finished(.failed))
        }

        try channel.pipeline.addHandler(handler).wait()

        // Fire a pair of events that should be ignored.
        channel.pipeline.fireUserInboundEventTriggered("FakeEvent")
        channel.pipeline.fireUserInboundEventTriggered(TLSUserEvent.shutdownCompleted)

        // The channel handler should still be in the pipeline.
        try channel.pipeline.assertContains(handler: handler)

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testNoBufferingBeforeEventFires() throws {
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop

        let handler = NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult>(eventLoop: loop) { result in
            XCTFail("Should not be called")
            return loop.makeSucceededFuture(.finished(.failed))
        }

        try channel.pipeline.addHandler(handler).wait()

        // The data we write should not be buffered.
        try channel.writeInbound("hello")
        XCTAssertNoThrow(XCTAssertEqual(try channel.readInbound()!, "hello"))

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testBufferingWhileWaitingForFuture() throws {
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop
        let continuePromise = loop.makePromise(of: NIOProtocolNegotiationResult<NegotiationResult>.self)

        let handler = NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult>(eventLoop: loop) { result in
            return continuePromise.futureResult
        }

        try channel.pipeline.addHandler(handler).wait()

        // Fire in the event.
        channel.pipeline.fireUserInboundEventTriggered(negotiatedEvent)

        // At this point all writes should be buffered.
        try channel.writeInbound("writes")
        try channel.writeInbound("are")
        try channel.writeInbound("buffered")
        XCTAssertNoThrow(XCTAssertNil(try channel.readInbound()))

        // Complete the pipeline swap.
        continuePromise.succeed(.finished(.failed))

        // Now everything should have been unbuffered.
        XCTAssertNoThrow(XCTAssertEqual(try channel.readInbound()!, "writes"))
        XCTAssertNoThrow(XCTAssertEqual(try channel.readInbound()!, "are"))
        XCTAssertNoThrow(XCTAssertEqual(try channel.readInbound()!, "buffered"))

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testNothingBufferedDoesNotFireReadCompleted() throws {
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop
        let continuePromise = loop.makePromise(of: NIOProtocolNegotiationResult<NegotiationResult>.self)

        let handler = NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult>(eventLoop: loop) { result in
            continuePromise.futureResult
        }
        let eventCounterHandler = EventCounterHandler()

        try channel.pipeline.addHandler(handler).wait()
        try channel.pipeline.addHandler(eventCounterHandler).wait()

        // Fire in the event.
        channel.pipeline.fireUserInboundEventTriggered(negotiatedEvent)

        // At this time, readComplete hasn't fired.
        XCTAssertEqual(eventCounterHandler.channelReadCompleteCalls, 0)

        // Now satisfy the future, which forces data unbuffering. As we haven't buffered any data,
        // readComplete should not be fired.
        continuePromise.succeed(.finished(.failed))
        XCTAssertEqual(eventCounterHandler.channelReadCompleteCalls, 0)

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testUnbufferingFiresReadCompleted() throws {
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop
        let continuePromise = loop.makePromise(of: NIOProtocolNegotiationResult<NegotiationResult>.self)

        let handler = NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult>(eventLoop: loop) { result in
            continuePromise.futureResult
        }
        let eventCounterHandler = EventCounterHandler()

        try channel.pipeline.addHandler(handler).wait()
        try channel.pipeline.addHandler(eventCounterHandler).wait()

        // Fire in the event.
        channel.pipeline.fireUserInboundEventTriggered(negotiatedEvent)

        // Send a write, which is buffered.
        try channel.writeInbound("a write")

        // At this time, readComplete hasn't fired.
        XCTAssertEqual(eventCounterHandler.channelReadCompleteCalls, 1)

        // Now satisfy the future, which forces data unbuffering. This should fire readComplete.
        continuePromise.succeed(.finished(.failed))
        XCTAssertNoThrow(XCTAssertEqual(try channel.readInbound()!, "a write"))

        XCTAssertEqual(eventCounterHandler.channelReadCompleteCalls, 2)

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testUnbufferingHandlesReentrantReads() throws {
        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop
        let continuePromise = loop.makePromise(of: NIOProtocolNegotiationResult<NegotiationResult>.self)

        let handler = NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult>(eventLoop: loop) { result in
            continuePromise.futureResult
        }
        let eventCounterHandler = EventCounterHandler()

        try channel.pipeline.addHandler(handler).wait()
        try channel.pipeline.addHandler(DuplicatingReadHandler(embeddedChannel: channel)).wait()
        try channel.pipeline.addHandler(eventCounterHandler).wait()

        // Fire in the event.
        channel.pipeline.fireUserInboundEventTriggered(negotiatedEvent)

        // Send a write, which is buffered.
        try channel.writeInbound("a write")

        // At this time, readComplete hasn't fired.
        XCTAssertEqual(eventCounterHandler.channelReadCompleteCalls, 1)

        // Now satisfy the future, which forces data unbuffering. This should fire readComplete.
        continuePromise.succeed(.finished(.failed))
        XCTAssertNoThrow(XCTAssertEqual(try channel.readInbound()!, "a write"))
        XCTAssertNoThrow(XCTAssertEqual(try channel.readInbound()!, "a write"))
        
        XCTAssertEqual(eventCounterHandler.channelReadCompleteCalls, 3)

        XCTAssertTrue(try channel.finish().isClean)
    }
}
