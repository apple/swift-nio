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
//
//  HTTPServerPipelineHandlerTest.swift
//  NIOHTTP1Tests
//
//  Created by Cory Benfield on 02/03/2018.
//

import NIO
@testable import NIOHTTP1
import XCTest

private final class ReadRecorder: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart

    enum Event: Equatable {
        case channelRead(InboundIn)
        case halfClose

        static func == (lhs: Event, rhs: Event) -> Bool {
            switch (lhs, rhs) {
            case let (.channelRead(b1), .channelRead(b2)):
                return b1 == b2
            case (.halfClose, .halfClose):
                return true
            default:
                return false
            }
        }
    }

    public var reads: [Event] = []

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        reads.append(.channelRead(unwrapInboundIn(data)))
        context.fireChannelRead(data)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let evt as ChannelEvent where evt == ChannelEvent.inputClosed:
            reads.append(.halfClose)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
}

private final class WriteRecorder: ChannelOutboundHandler {
    typealias OutboundIn = HTTPServerResponsePart

    public var writes: [HTTPServerResponsePart] = []

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        writes.append(unwrapOutboundIn(data))

        context.write(data, promise: promise)
    }
}

private final class ReadCountingHandler: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    public var readCount = 0

    func read(context: ChannelHandlerContext) {
        readCount += 1
        context.read()
    }
}

private final class QuiesceEventRecorder: ChannelInboundHandler {
    typealias InboundIn = Any
    typealias InboundOut = Any

    public var quiesceCount = 0

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelShouldQuiesceEvent {
            quiesceCount += 1
        }
        context.fireUserInboundEventTriggered(event)
    }
}

class HTTPServerPipelineHandlerTest: XCTestCase {
    var channel: EmbeddedChannel!
    var requestHead: HTTPRequestHead!
    var responseHead: HTTPResponseHead!
    fileprivate var readRecorder: ReadRecorder!
    fileprivate var readCounter: ReadCountingHandler!
    fileprivate var writeRecorder: WriteRecorder!
    fileprivate var pipelineHandler: HTTPServerPipelineHandler!
    fileprivate var quiesceEventRecorder: QuiesceEventRecorder!

    override func setUp() {
        channel = EmbeddedChannel()
        readRecorder = ReadRecorder()
        readCounter = ReadCountingHandler()
        writeRecorder = WriteRecorder()
        pipelineHandler = HTTPServerPipelineHandler()
        quiesceEventRecorder = QuiesceEventRecorder()
        XCTAssertNoThrow(try channel.pipeline.addHandler(readCounter).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(HTTPResponseEncoder()).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(writeRecorder).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(pipelineHandler).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(readRecorder).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(quiesceEventRecorder).wait())

        requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/path")
        requestHead.headers.add(name: "Host", value: "example.com")

        responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        responseHead.headers.add(name: "Server", value: "SwiftNIO")

        // this activates the channel
        XCTAssertNoThrow(try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait())
    }

    override func tearDown() {
        if let channel = self.channel {
            XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true))
            self.channel = nil
        }
        requestHead = nil
        responseHead = nil
        readRecorder = nil
        readCounter = nil
        writeRecorder = nil
        pipelineHandler = nil
        quiesceEventRecorder = nil
    }

    func testBasicBufferingBehaviour() throws {
        // Send in 3 requests at once.
        for _ in 0 ..< 3 {
            XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
            XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }

        // Only one request should have made it through.
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        // Unblock by sending a response.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())

        // Two requests should have made it through now.
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        // Now send the last response.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())

        // Now all three.
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])
    }

    func testReadCallsAreSuppressedWhenPipelining() throws {
        // First, call read() and check it makes it through.
        XCTAssertEqual(readCounter.readCount, 0)
        channel.read()
        XCTAssertEqual(readCounter.readCount, 1)

        // Send in a request.
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Call read again, twice. This should not change the number.
        channel.read()
        channel.read()
        XCTAssertEqual(readCounter.readCount, 1)

        // Send a response.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())

        // This should have automatically triggered a call to read(), but only one.
        XCTAssertEqual(readCounter.readCount, 2)
    }

    func testReadCallsAreSuppressedWhenUnbufferingIfThereIsStillBufferedData() throws {
        // First, call read() and check it makes it through.
        XCTAssertEqual(readCounter.readCount, 0)
        channel.read()
        XCTAssertEqual(readCounter.readCount, 1)

        // Send in two requests.
        for _ in 0 ..< 2 {
            XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
            XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }

        // Call read again, twice. This should not change the number.
        channel.read()
        channel.read()
        XCTAssertEqual(readCounter.readCount, 1)

        // Send a response.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())

        // This should have not triggered a call to read.
        XCTAssertEqual(readCounter.readCount, 1)

        // Try calling read some more.
        channel.read()
        channel.read()
        XCTAssertEqual(readCounter.readCount, 1)

        // Now send in the last response, and see the read go through.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())
        XCTAssertEqual(readCounter.readCount, 2)
    }

    func testServerCanRespondEarly() throws {
        // Send in the first part of a request.
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))

        // This is still moving forward: we can read.
        XCTAssertEqual(readCounter.readCount, 0)
        channel.read()
        XCTAssertEqual(readCounter.readCount, 1)

        // Now the server sends a response immediately.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())

        // We're still moving forward and can read.
        XCTAssertEqual(readCounter.readCount, 1)
        channel.read()
        XCTAssertEqual(readCounter.readCount, 2)

        // The client response completes.
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // We can still read.
        XCTAssertEqual(readCounter.readCount, 2)
        channel.read()
        XCTAssertEqual(readCounter.readCount, 3)
    }

    func testPipelineHandlerWillBufferHalfClose() throws {
        // Send in 2 requests at once.
        for _ in 0 ..< 3 {
            XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
            XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }

        // Now half-close the connection.
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        // Only one request should have made it through, no half-closure yet.
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        // Unblock by sending a response.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())

        // Two requests should have made it through now.
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        // Now send the last response.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())

        // Now the half-closure should be delivered.
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .halfClose])
    }

    func testPipelineHandlerWillDeliverHalfCloseEarly() throws {
        // Send in a request.
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Now send a new request but half-close the connection before we get .end.
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        // Only one request should have made it through, no half-closure yet.
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        // Unblock by sending a response.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())

        // The second request head, followed by the half-close, should have made it through.
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .channelRead(HTTPServerRequestPart.head(requestHead)),
                        .halfClose])
    }

    func testAReadIsNotIssuedWhenUnbufferingAHalfCloseAfterRequestComplete() throws {
        // First, call read() and check it makes it through.
        XCTAssertEqual(readCounter.readCount, 0)
        channel.read()
        XCTAssertEqual(readCounter.readCount, 1)

        // Send in two requests and then half-close.
        for _ in 0 ..< 2 {
            XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
            XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        // Call read again, twice. This should not change the number.
        channel.read()
        channel.read()
        XCTAssertEqual(readCounter.readCount, 1)

        // Send a response.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())

        // This should have not triggered a call to read.
        XCTAssertEqual(readCounter.readCount, 1)

        // Now send in the last response. This should also not issue a read.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())
        XCTAssertEqual(readCounter.readCount, 1)
    }

    func testHalfCloseWhileWaitingForResponseIsPassedAlongIfNothingElseBuffered() throws {
        // Send in 2 requests at once.
        for _ in 0 ..< 2 {
            XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
            XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }

        // Only one request should have made it through, no half-closure yet.
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        // Unblock by sending a response.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())

        // Two requests should have made it through now. Still no half-closure.
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        // Now send the half-closure.
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        // The half-closure should be delivered immediately.
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .halfClose])
    }

    func testRecursiveChannelReadInvocationsDoNotCauseIssues() throws {
        func makeRequestHead(uri: String) -> HTTPRequestHead {
            var requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: uri)
            requestHead.headers.add(name: "Host", value: "example.com")
            return requestHead
        }

        class VerifyOrderHandler: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart
            typealias OutboundOut = HTTPServerResponsePart

            enum NextExpectedMessageType {
                case head
                case end
            }

            enum State {
                case req1HeadExpected
                case req1EndExpected
                case req2HeadExpected
                case req2EndExpected
                case req3HeadExpected
                case req3EndExpected
                case reqBoomHeadExpected
                case reqBoomEndExpected

                case done
            }

            var state: State = .req1HeadExpected

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let req = unwrapInboundIn(data)
                switch req {
                case let .head(head):
                    // except for "req_1", we always send the .end straight away
                    var sendEnd = true
                    switch head.uri {
                    case "/req_1":
                        XCTAssertEqual(.req1HeadExpected, state)
                        state = .req1EndExpected
                        // for req_1, we don't send the end straight away to force the others to be buffered
                        sendEnd = false
                    case "/req_2":
                        XCTAssertEqual(.req2HeadExpected, state)
                        state = .req2EndExpected
                    case "/req_3":
                        XCTAssertEqual(.req3HeadExpected, state)
                        state = .req3EndExpected
                    case "/req_boom":
                        XCTAssertEqual(.reqBoomHeadExpected, state)
                        state = .reqBoomEndExpected
                    default:
                        XCTFail("didn't expect \(head)")
                    }
                    context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok))), promise: nil)
                    if sendEnd {
                        context.write(wrapOutboundOut(.end(nil)), promise: nil)
                    }
                    context.flush()
                case .end:
                    switch state {
                    case .req1EndExpected:
                        state = .req2HeadExpected
                    case .req2EndExpected:
                        state = .req3HeadExpected

                        // this will cause `channelRead` to be recursively called and we need to make sure everything then still works
                        try! (context.channel as! EmbeddedChannel).writeInbound(HTTPServerRequestPart.head(HTTPRequestHead(version: .http1_1, method: .GET, uri: "/req_boom")))
                        try! (context.channel as! EmbeddedChannel).writeInbound(HTTPServerRequestPart.end(nil))
                    case .req3EndExpected:
                        state = .reqBoomHeadExpected
                    case .reqBoomEndExpected:
                        state = .done
                    default:
                        XCTFail("illegal state for end: \(state)")
                    }
                case .body:
                    XCTFail("we don't send any bodies")
                }
            }
        }

        let handler = VerifyOrderHandler()
        XCTAssertNoThrow(try channel.pipeline.addHandler(handler).wait())

        for f in 1 ... 3 {
            XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(makeRequestHead(uri: "/req_\(f)"))))
            XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }

        // now we should have delivered the first request, with the second and third buffered because req_1's .end
        // doesn't get sent by the handler (instead we'll do that below)
        XCTAssertEqual(.req2HeadExpected, handler.state)

        // finish 1st request, that will send through the 2nd one which will then write the 'req_boom' request
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())

        XCTAssertEqual(.done, handler.state)
    }

    func testQuiescingEventWhenInitiallyIdle() throws {
        XCTAssertTrue(channel.isActive)
        channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertFalse(channel.isActive)
        XCTAssertEqual(quiesceEventRecorder.quiesceCount, 0)
    }

    func testQuiescingEventWhenIdleAfterARequest() throws {
        // Send through one request.
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // The request should have made it through.
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        // Now send a response.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())

        // No further events should have happened.
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        XCTAssertTrue(channel.isActive)
        channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertFalse(channel.isActive)
        XCTAssertEqual(quiesceEventRecorder.quiesceCount, 0)
    }

    func testQuiescingInTheMiddleOfARequestNoResponseBitsYet() throws {
        // Send through only the head.
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead))])

        XCTAssertTrue(channel.isActive)
        channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertTrue(channel.isActive)

        // Now send a response.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())

        // still missing the request .end
        XCTAssertTrue(channel.isActive)

        var reqWithConnectionClose: HTTPResponseHead = responseHead
        reqWithConnectionClose.headers.add(name: "connection", value: "close")
        XCTAssertEqual([HTTPServerResponsePart.head(reqWithConnectionClose),
                        HTTPServerResponsePart.end(nil)],
                       writeRecorder.writes)

        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))

        XCTAssertFalse(channel.isActive)
        XCTAssertEqual(quiesceEventRecorder.quiesceCount, 0)
    }

    func testQuiescingAfterHavingReceivedRequestButBeforeResponseWasSent() throws {
        // Send through a full request.
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))

        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        XCTAssertTrue(channel.isActive)
        channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertTrue(channel.isActive)

        // Now send a response.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())

        XCTAssertFalse(channel.isActive)

        var reqWithConnectionClose: HTTPResponseHead = responseHead
        reqWithConnectionClose.headers.add(name: "connection", value: "close")
        XCTAssertEqual([HTTPServerResponsePart.head(reqWithConnectionClose),
                        HTTPServerResponsePart.end(nil)],
                       writeRecorder.writes)

        XCTAssertFalse(channel.isActive)
        XCTAssertEqual(quiesceEventRecorder.quiesceCount, 0)
    }

    func testQuiescingAfterHavingReceivedRequestAndResponseHeadButNoResponseEndYet() throws {
        // Send through a full request.
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))

        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        // Now send the response .head.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())

        XCTAssertTrue(channel.isActive)
        channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertTrue(channel.isActive)

        // Now send the response .end.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())
        XCTAssertFalse(channel.isActive)

        XCTAssertEqual([HTTPServerResponsePart.head(responseHead),
                        HTTPServerResponsePart.end(nil)],
                       writeRecorder.writes)

        XCTAssertFalse(channel.isActive)
        XCTAssertEqual(quiesceEventRecorder.quiesceCount, 0)
    }

    func testQuiescingAfterRequestAndResponseHeadsButBeforeAnyEndsThenRequestEndBeforeResponseEnd() throws {
        // Send through a request .head.
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))

        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead))])

        // Now send the response .head.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())

        XCTAssertTrue(channel.isActive)
        channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertTrue(channel.isActive)

        // Request .end.
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))

        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])
        XCTAssertTrue(channel.isActive)

        // Response .end.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())
        XCTAssertFalse(channel.isActive)

        XCTAssertEqual([HTTPServerResponsePart.head(responseHead),
                        HTTPServerResponsePart.end(nil)],
                       writeRecorder.writes)

        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))

        XCTAssertFalse(channel.isActive)
        XCTAssertEqual(quiesceEventRecorder.quiesceCount, 0)
    }

    func testQuiescingAfterRequestAndResponseHeadsButBeforeAnyEndsThenRequestEndAfterResponseEnd() throws {
        // Send through a request .head.
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))

        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead))])

        // Now send the response .head.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())

        XCTAssertTrue(channel.isActive)
        channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertTrue(channel.isActive)

        // Response .end.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())
        XCTAssertTrue(channel.isActive)

        // Request .end.
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))

        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        XCTAssertFalse(channel.isActive)

        XCTAssertEqual([HTTPServerResponsePart.head(responseHead),
                        HTTPServerResponsePart.end(nil)],
                       writeRecorder.writes)

        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))

        XCTAssertFalse(channel.isActive)
        XCTAssertEqual(quiesceEventRecorder.quiesceCount, 0)
    }

    func testQuiescingAfterHavingReceivedOneRequestButBeforeResponseWasSentWithMoreRequestsInTheBuffer() throws {
        // Send through a full request and buffer a few more
        for _ in 0 ..< 3 {
            XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
            XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }

        // Check that only one request came through
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        XCTAssertTrue(channel.isActive)
        channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertTrue(channel.isActive)

        // Now send a response.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait())

        XCTAssertFalse(channel.isActive)

        var reqWithConnectionClose: HTTPResponseHead = responseHead
        reqWithConnectionClose.headers.add(name: "connection", value: "close")

        // check that only one response (with connection: close) came through
        XCTAssertEqual([HTTPServerResponsePart.head(reqWithConnectionClose),
                        HTTPServerResponsePart.end(nil)],
                       writeRecorder.writes)

        // Check that only one request came through
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        XCTAssertFalse(channel.isActive)
        XCTAssertEqual(quiesceEventRecorder.quiesceCount, 0)
    }

    func testParserErrorOnly() throws {
        class VerifyOrderHandler: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart
            typealias OutboundOut = HTTPServerResponsePart

            enum State {
                case errorExpected
                case done
            }

            var state: State = .errorExpected

            func errorCaught(context _: ChannelHandlerContext, error: Error) {
                XCTAssertEqual(HTTPParserError.headerOverflow, error as? HTTPParserError)
                XCTAssertEqual(.errorExpected, state)
                state = .done
            }

            func channelRead(context _: ChannelHandlerContext, data _: NIOAny) {
                XCTFail("no requests expected")
            }
        }

        let handler = VerifyOrderHandler()
        XCTAssertNoThrow(try channel.pipeline.addHandler(HTTPServerProtocolErrorHandler()).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(handler).wait())

        channel.pipeline.fireErrorCaught(HTTPParserError.headerOverflow)

        XCTAssertEqual(.done, handler.state)
    }

    func testLegitRequestFollowedByParserErrorArrivingWhilstResponseOutstanding() throws {
        func makeRequestHead(uri: String) -> HTTPRequestHead {
            var requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: uri)
            requestHead.headers.add(name: "Host", value: "example.com")
            return requestHead
        }

        class VerifyOrderHandler: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart
            typealias OutboundOut = HTTPServerResponsePart

            enum State {
                case reqHeadExpected
                case reqEndExpected
                case errorExpected
                case done
            }

            var state: State = .reqHeadExpected

            func errorCaught(context _: ChannelHandlerContext, error: Error) {
                XCTAssertEqual(HTTPParserError.closedConnection, error as? HTTPParserError)
                XCTAssertEqual(.errorExpected, state)
                state = .done
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                switch unwrapInboundIn(data) {
                case .head:
                    // We dispatch this to the event loop so that it doesn't happen immediately but rather can be
                    // run from the driving test code whenever it wants by running the EmbeddedEventLoop.
                    context.eventLoop.execute {
                        context.writeAndFlush(self.wrapOutboundOut(.head(.init(version: .http1_1,
                                                                               status: .ok))),
                        promise: nil)
                    }
                    XCTAssertEqual(.reqHeadExpected, state)
                    state = .reqEndExpected
                case .body:
                    XCTFail("no body expected")
                case .end:
                    // We dispatch this to the event loop so that it doesn't happen immediately but rather can be
                    // run from the driving test code whenever it wants by running the EmbeddedEventLoop.
                    context.eventLoop.execute {
                        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                    }
                    XCTAssertEqual(.reqEndExpected, state)
                    state = .errorExpected
                }
            }
        }

        let handler = VerifyOrderHandler()
        XCTAssertNoThrow(try channel.pipeline.addHandler(HTTPServerProtocolErrorHandler()).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(handler).wait())

        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(makeRequestHead(uri: "/one"))))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))
        channel.pipeline.fireErrorCaught(HTTPParserError.closedConnection)

        // let's now run the HTTP responses that we enqueued earlier on.
        (channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertEqual(.done, handler.state)
    }

    func testRemovingWithResponseOutstandingTriggersRead() throws {
        // First, call read() and check it makes it through.
        XCTAssertEqual(readCounter.readCount, 0)
        channel.read()
        XCTAssertEqual(readCounter.readCount, 1)

        // Send in a request.
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Call read again, twice. This should not change the number.
        channel.read()
        channel.read()
        XCTAssertEqual(readCounter.readCount, 1)

        // Remove the handler.
        XCTAssertNoThrow(try channel.pipeline.removeHandler(pipelineHandler).wait())

        // This should have automatically triggered a call to read(), but only one.
        XCTAssertEqual(readCounter.readCount, 2)

        // Incidentally we shouldn't have fired a quiesce event.
        XCTAssertEqual(quiesceEventRecorder.quiesceCount, 0)
    }

    func testRemovingWithPartialResponseOutstandingTriggersRead() throws {
        // First, call read() and check it makes it through.
        XCTAssertEqual(readCounter.readCount, 0)
        channel.read()
        XCTAssertEqual(readCounter.readCount, 1)

        // Send in a request.
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Call read again, twice. This should not change the number.
        channel.read()
        channel.read()
        XCTAssertEqual(readCounter.readCount, 1)

        // Send a partial response, which should not trigger a read.
        XCTAssertNoThrow(try channel.writeAndFlush(HTTPServerResponsePart.head(responseHead)).wait())
        XCTAssertEqual(readCounter.readCount, 1)

        // Remove the handler.
        XCTAssertNoThrow(try channel.pipeline.removeHandler(pipelineHandler).wait())

        // This should have automatically triggered a call to read(), but only one.
        XCTAssertEqual(readCounter.readCount, 2)

        // Incidentally we shouldn't have fired a quiesce event.
        XCTAssertEqual(quiesceEventRecorder.quiesceCount, 0)
    }

    func testRemovingWithBufferedRequestForwards() throws {
        // Send in a request, and part of another.
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))

        // Only one request should have made it through.
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        // Remove the handler.
        XCTAssertNoThrow(try channel.pipeline.removeHandler(pipelineHandler).wait())

        // The extra data should have been forwarded.
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil)),
                        .channelRead(HTTPServerRequestPart.head(requestHead))])
    }

    func testQuiescingInAResponseThenRemovedFiresEventAndReads() throws {
        // First, call read() and check it makes it through.
        XCTAssertEqual(readCounter.readCount, 0)
        channel.read()
        XCTAssertEqual(readCounter.readCount, 1)

        // Send through a request and part of another.
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.end(nil)))
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))

        // Only one request should have made it through.
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead)),
                        .channelRead(HTTPServerRequestPart.end(nil))])

        XCTAssertTrue(channel.isActive)
        XCTAssertEqual(quiesceEventRecorder.quiesceCount, 0)
        XCTAssertEqual(readCounter.readCount, 1)

        // Now quiesce the channel.
        channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertTrue(channel.isActive)
        XCTAssertEqual(quiesceEventRecorder.quiesceCount, 0)
        XCTAssertEqual(readCounter.readCount, 1)

        // Call read again, twice. This should not lead to reads, as we're waiting for the end.
        channel.read()
        channel.read()
        XCTAssertTrue(channel.isActive)
        XCTAssertEqual(quiesceEventRecorder.quiesceCount, 0)
        XCTAssertEqual(readCounter.readCount, 1)

        // Now remove the handler.
        XCTAssertNoThrow(try channel.pipeline.removeHandler(pipelineHandler).wait())

        // Channel should be open, but the quiesce event should have fired, and read
        // shouldn't have been called as we aren't expecting more data.
        XCTAssertTrue(channel.isActive)
        XCTAssertEqual(quiesceEventRecorder.quiesceCount, 1)
        XCTAssertEqual(readCounter.readCount, 1)
    }

    func testQuiescingInAResponseThenRemovedFiresEventAndDoesntRead() throws {
        // First, call read() and check it makes it through.
        XCTAssertEqual(readCounter.readCount, 0)
        channel.read()
        XCTAssertEqual(readCounter.readCount, 1)

        // Send through just the head.
        XCTAssertNoThrow(try channel.writeInbound(HTTPServerRequestPart.head(requestHead)))
        XCTAssertEqual(readRecorder.reads,
                       [.channelRead(HTTPServerRequestPart.head(requestHead))])

        XCTAssertTrue(channel.isActive)
        XCTAssertEqual(quiesceEventRecorder.quiesceCount, 0)
        XCTAssertEqual(readCounter.readCount, 1)
        channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertTrue(channel.isActive)
        XCTAssertEqual(quiesceEventRecorder.quiesceCount, 0)
        XCTAssertEqual(readCounter.readCount, 1)

        // Call read again, twice. This should pass through.
        channel.read()
        channel.read()
        XCTAssertTrue(channel.isActive)
        XCTAssertEqual(quiesceEventRecorder.quiesceCount, 0)
        XCTAssertEqual(readCounter.readCount, 3)

        // Now remove the handler.
        XCTAssertNoThrow(try channel.pipeline.removeHandler(pipelineHandler).wait())

        // Channel should be open, but the quiesce event should have fired, and read
        // shouldn't be (as it passed through.
        XCTAssertTrue(channel.isActive)
        XCTAssertEqual(quiesceEventRecorder.quiesceCount, 1)
        XCTAssertEqual(readCounter.readCount, 3)
    }
}
