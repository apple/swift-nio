//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2024 Apple Inc. and the SwiftNIO project authors
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
import XCTest

@testable import NIOHTTP1

private final class ReadRecorder: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart

    enum Event: Equatable {
        case channelRead(InboundIn)
        case halfClose

        static func == (lhs: Event, rhs: Event) -> Bool {
            switch (lhs, rhs) {
            case (.channelRead(let b1), .channelRead(let b2)):
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
        self.reads.append(.channelRead(Self.unwrapInboundIn(data)))
        context.fireChannelRead(data)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let evt as ChannelEvent where evt == ChannelEvent.inputClosed:
            self.reads.append(.halfClose)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
}

private final class WriteRecorder: ChannelOutboundHandler {
    typealias OutboundIn = HTTPServerResponsePart

    public var writes: [HTTPServerResponsePart] = []

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.writes.append(Self.unwrapOutboundIn(data))

        context.write(data, promise: promise)
    }
}

private final class ReadCountingHandler: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    public var readCount = 0

    func read(context: ChannelHandlerContext) {
        self.readCount += 1
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

// This handler drops close mode output. This is because EmbeddedChannel doesn't support it,
// and tests here don't require that it does anything sensible.
private final class CloseOutputSuppressor: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        if mode == .output {
            promise?.succeed()
        } else {
            context.close(mode: mode, promise: promise)
        }
    }
}

class HTTPServerPipelineHandlerTest: XCTestCase {
    var channel: EmbeddedChannel! = nil
    var requestHead: HTTPRequestHead! = nil
    var responseHead: HTTPResponseHead! = nil
    fileprivate var readRecorder: ReadRecorder! = nil
    fileprivate var readCounter: ReadCountingHandler! = nil
    fileprivate var writeRecorder: WriteRecorder! = nil
    fileprivate var pipelineHandler: HTTPServerPipelineHandler! = nil
    fileprivate var quiesceEventRecorder: QuiesceEventRecorder! = nil

    override func setUp() {
        self.channel = EmbeddedChannel()
        self.readRecorder = ReadRecorder()
        self.readCounter = ReadCountingHandler()
        self.writeRecorder = WriteRecorder()
        self.pipelineHandler = HTTPServerPipelineHandler()
        self.quiesceEventRecorder = QuiesceEventRecorder()
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(CloseOutputSuppressor()))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(self.readCounter))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(HTTPResponseEncoder()))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(self.writeRecorder))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(self.pipelineHandler))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(self.readRecorder))
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(self.quiesceEventRecorder))

        self.requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/path")
        self.requestHead.headers.add(name: "Host", value: "example.com")

        self.responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        self.responseHead.headers.add(name: "Server", value: "SwiftNIO")

        // this activates the channel
        XCTAssertNoThrow(try self.channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait())
    }

    override func tearDown() {
        if let channel = self.channel {
            XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true))
            self.channel = nil
        }
        self.requestHead = nil
        self.responseHead = nil
        self.readRecorder = nil
        self.readCounter = nil
        self.writeRecorder = nil
        self.pipelineHandler = nil
        self.quiesceEventRecorder = nil
    }

    func testBasicBufferingBehaviour() throws {
        // Send in 3 requests at once.
        for _ in 0..<3 {
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }

        // Only one request should have made it through.
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )

        // Unblock by sending a response.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))

        // Two requests should have made it through now.
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )

        // Now send the last response.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))

        // Now all three.
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )
    }

    func testReadCallsAreSuppressedWhenPipelining() throws {
        // First, call read() and check it makes it through.
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Send in a request.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Call read again, twice. This should not change the number.
        self.channel.read()
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Send a response.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))

        // This should have automatically triggered a call to read(), but only one.
        XCTAssertEqual(self.readCounter.readCount, 2)
    }

    func testReadCallsAreSuppressedWhenUnbufferingIfThereIsStillBufferedData() throws {
        // First, call read() and check it makes it through.
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Send in two requests.
        for _ in 0..<2 {
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }

        // Call read again, twice. This should not change the number.
        self.channel.read()
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Send a response.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))

        // This should have not triggered a call to read.
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Try calling read some more.
        self.channel.read()
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Now send in the last response, and see the read go through.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))
        XCTAssertEqual(self.readCounter.readCount, 2)
    }

    func testServerCanRespondEarly() throws {
        // Send in the first part of a request.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))

        // This is still moving forward: we can read.
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Now the server sends a response immediately.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))

        // We're still moving forward and can read.
        XCTAssertEqual(self.readCounter.readCount, 1)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 2)

        // The client response completes.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // We can still read.
        XCTAssertEqual(self.readCounter.readCount, 2)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 3)
    }

    func testPipelineHandlerWillBufferHalfClose() throws {
        // Send in 2 requests at once.
        for _ in 0..<3 {
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }

        // Now half-close the connection.
        self.channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        // Only one request should have made it through, no half-closure yet.
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )

        // Unblock by sending a response.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))

        // Two requests should have made it through now.
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )

        // Now send the last response.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))

        // Now the half-closure should be delivered.
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
                .halfClose,
            ]
        )
    }

    func testPipelineHandlerWillDeliverHalfCloseEarly() throws {
        // Send in a request.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Now send a new request but half-close the connection before we get .end.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        self.channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        // Only one request should have made it through, no half-closure yet.
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )

        // Unblock by sending a response.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))

        // The second request head, followed by the half-close, should have made it through.
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .halfClose,
            ]
        )
    }

    func testAReadIsNotIssuedWhenUnbufferingAHalfCloseAfterRequestComplete() throws {
        // First, call read() and check it makes it through.
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Send in two requests and then half-close.
        for _ in 0..<2 {
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }
        self.channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        // Call read again, twice. This should not change the number.
        self.channel.read()
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Send a response.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))

        // This should have not triggered a call to read.
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Now send in the last response. This should also not issue a read.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))
        XCTAssertEqual(self.readCounter.readCount, 1)
    }

    func testHalfCloseWhileWaitingForResponseIsPassedAlongIfNothingElseBuffered() throws {
        // Send in 2 requests at once.
        for _ in 0..<2 {
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }

        // Only one request should have made it through, no half-closure yet.
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )

        // Unblock by sending a response.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))

        // Two requests should have made it through now. Still no half-closure.
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )

        // Now send the half-closure.
        self.channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)

        // The half-closure should be delivered immediately.
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
                .halfClose,
            ]
        )
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
                let req = Self.unwrapInboundIn(data)
                switch req {
                case .head(let head):
                    // except for "req_1", we always send the .end straight away
                    var sendEnd = true
                    switch head.uri {
                    case "/req_1":
                        XCTAssertEqual(.req1HeadExpected, self.state)
                        self.state = .req1EndExpected
                        // for req_1, we don't send the end straight away to force the others to be buffered
                        sendEnd = false
                    case "/req_2":
                        XCTAssertEqual(.req2HeadExpected, self.state)
                        self.state = .req2EndExpected
                    case "/req_3":
                        XCTAssertEqual(.req3HeadExpected, self.state)
                        self.state = .req3EndExpected
                    case "/req_boom":
                        XCTAssertEqual(.reqBoomHeadExpected, self.state)
                        self.state = .reqBoomEndExpected
                    default:
                        XCTFail("didn't expect \(head)")
                    }
                    context.write(
                        Self.wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok))),
                        promise: nil
                    )
                    if sendEnd {
                        context.write(Self.wrapOutboundOut(.end(nil)), promise: nil)
                    }
                    context.flush()
                case .end:
                    switch self.state {
                    case .req1EndExpected:
                        self.state = .req2HeadExpected
                    case .req2EndExpected:
                        self.state = .req3HeadExpected

                        // this will cause `channelRead` to be recursively called and we need to make sure everything then still works
                        try! (context.channel as! EmbeddedChannel).writeInbound(
                            HTTPServerRequestPart.head(
                                HTTPRequestHead(version: .http1_1, method: .GET, uri: "/req_boom")
                            )
                        )
                        try! (context.channel as! EmbeddedChannel).writeInbound(HTTPServerRequestPart.end(nil))
                    case .req3EndExpected:
                        self.state = .reqBoomHeadExpected
                    case .reqBoomEndExpected:
                        self.state = .done
                    default:
                        XCTFail("illegal state for end: \(self.state)")
                    }
                case .body:
                    XCTFail("we don't send any bodies")
                }
            }
        }

        let handler = VerifyOrderHandler()
        XCTAssertNoThrow(try channel.pipeline.syncOperations.addHandler(handler))

        for f in 1...3 {
            XCTAssertNoThrow(
                try self.channel.writeInbound(HTTPServerRequestPart.head(makeRequestHead(uri: "/req_\(f)")))
            )
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }

        // now we should have delivered the first request, with the second and third buffered because req_1's .end
        // doesn't get sent by the handler (instead we'll do that below)
        XCTAssertEqual(.req2HeadExpected, handler.state)

        // finish 1st request, that will send through the 2nd one which will then write the 'req_boom' request
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))

        XCTAssertEqual(.done, handler.state)
    }

    func testQuiescingEventWhenInitiallyIdle() throws {
        XCTAssertTrue(self.channel.isActive)
        self.channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertFalse(self.channel.isActive)
        XCTAssertEqual(self.quiesceEventRecorder.quiesceCount, 0)
    }

    func testQuiescingEventWhenIdleAfterARequest() throws {
        // Send through one request.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // The request should have made it through.
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )

        // Now send a response.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))

        // No further events should have happened.
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )

        XCTAssertTrue(self.channel.isActive)
        self.channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertFalse(self.channel.isActive)
        XCTAssertEqual(self.quiesceEventRecorder.quiesceCount, 0)
    }

    func testQuiescingInTheMiddleOfARequestNoResponseBitsYet() throws {
        // Send through only the head.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertEqual(
            self.readRecorder.reads,
            [.channelRead(HTTPServerRequestPart.head(self.requestHead))]
        )

        XCTAssertTrue(self.channel.isActive)
        self.channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertTrue(self.channel.isActive)

        // Now send a response.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))

        // still missing the request .end
        XCTAssertTrue(self.channel.isActive)

        var reqWithConnectionClose: HTTPResponseHead = self.responseHead
        reqWithConnectionClose.headers.add(name: "connection", value: "close")
        XCTAssertEqual(
            [
                HTTPServerResponsePart.head(reqWithConnectionClose),
                HTTPServerResponsePart.end(nil),
            ],
            self.writeRecorder.writes
        )

        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        XCTAssertFalse(self.channel.isActive)
        XCTAssertEqual(self.quiesceEventRecorder.quiesceCount, 0)
    }

    func testQuiescingAfterHavingReceivedRequestButBeforeResponseWasSent() throws {
        // Send through a full request.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )

        XCTAssertTrue(self.channel.isActive)
        self.channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertTrue(self.channel.isActive)

        // Now send a response.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))

        XCTAssertFalse(self.channel.isActive)

        var reqWithConnectionClose: HTTPResponseHead = self.responseHead
        reqWithConnectionClose.headers.add(name: "connection", value: "close")
        XCTAssertEqual(
            [
                HTTPServerResponsePart.head(reqWithConnectionClose),
                HTTPServerResponsePart.end(nil),
            ],
            self.writeRecorder.writes
        )

        XCTAssertFalse(self.channel.isActive)
        XCTAssertEqual(self.quiesceEventRecorder.quiesceCount, 0)
    }

    func testQuiescingAfterHavingReceivedRequestAndResponseHeadButNoResponseEndYet() throws {
        // Send through a full request.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )

        // Now send the response .head.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))

        XCTAssertTrue(self.channel.isActive)
        self.channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertTrue(self.channel.isActive)

        // Now send the response .end.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))
        XCTAssertFalse(self.channel.isActive)

        XCTAssertEqual(
            [
                HTTPServerResponsePart.head(self.responseHead),
                HTTPServerResponsePart.end(nil),
            ],
            self.writeRecorder.writes
        )

        XCTAssertFalse(self.channel.isActive)
        XCTAssertEqual(self.quiesceEventRecorder.quiesceCount, 0)
    }

    func testQuiescingAfterRequestAndResponseHeadsButBeforeAnyEndsThenRequestEndBeforeResponseEnd() throws {
        // Send through a request .head.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))

        XCTAssertEqual(
            self.readRecorder.reads,
            [.channelRead(HTTPServerRequestPart.head(self.requestHead))]
        )

        // Now send the response .head.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))

        XCTAssertTrue(self.channel.isActive)
        self.channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertTrue(self.channel.isActive)

        // Request .end.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )
        XCTAssertTrue(self.channel.isActive)

        // Response .end.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))
        XCTAssertFalse(self.channel.isActive)

        XCTAssertEqual(
            [
                HTTPServerResponsePart.head(self.responseHead),
                HTTPServerResponsePart.end(nil),
            ],
            self.writeRecorder.writes
        )

        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        XCTAssertFalse(self.channel.isActive)
        XCTAssertEqual(self.quiesceEventRecorder.quiesceCount, 0)
    }

    func testQuiescingAfterRequestAndResponseHeadsButBeforeAnyEndsThenRequestEndAfterResponseEnd() throws {
        // Send through a request .head.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))

        XCTAssertEqual(
            self.readRecorder.reads,
            [.channelRead(HTTPServerRequestPart.head(self.requestHead))]
        )

        // Now send the response .head.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))

        XCTAssertTrue(self.channel.isActive)
        self.channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertTrue(self.channel.isActive)

        // Response .end.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))
        XCTAssertTrue(self.channel.isActive)

        // Request .end.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )

        XCTAssertFalse(self.channel.isActive)

        XCTAssertEqual(
            [
                HTTPServerResponsePart.head(self.responseHead),
                HTTPServerResponsePart.end(nil),
            ],
            self.writeRecorder.writes
        )

        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        XCTAssertFalse(self.channel.isActive)
        XCTAssertEqual(self.quiesceEventRecorder.quiesceCount, 0)
    }

    func testQuiescingAfterHavingReceivedOneRequestButBeforeResponseWasSentWithMoreRequestsInTheBuffer() throws {
        // Send through a full request and buffer a few more
        for _ in 0..<3 {
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }

        // Check that only one request came through
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )

        XCTAssertTrue(self.channel.isActive)
        self.channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertTrue(self.channel.isActive)

        // Now send a response.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))

        XCTAssertFalse(self.channel.isActive)

        var reqWithConnectionClose: HTTPResponseHead = self.responseHead
        reqWithConnectionClose.headers.add(name: "connection", value: "close")

        // check that only one response (with connection: close) came through
        XCTAssertEqual(
            [
                HTTPServerResponsePart.head(reqWithConnectionClose),
                HTTPServerResponsePart.end(nil),
            ],
            self.writeRecorder.writes
        )

        // Check that only one request came through
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )

        XCTAssertFalse(self.channel.isActive)
        XCTAssertEqual(self.quiesceEventRecorder.quiesceCount, 0)
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

            func errorCaught(context: ChannelHandlerContext, error: Error) {
                XCTAssertEqual(HTTPParserError.unknown, error as? HTTPParserError)
                XCTAssertEqual(.errorExpected, self.state)
                self.state = .done
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                XCTFail("no requests expected")
            }
        }

        let handler = VerifyOrderHandler()
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTPServerProtocolErrorHandler()))
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(handler))

        self.channel.pipeline.fireErrorCaught(HTTPParserError.unknown)

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

            func errorCaught(context: ChannelHandlerContext, error: Error) {
                XCTAssertEqual(HTTPParserError.closedConnection, error as? HTTPParserError)
                XCTAssertEqual(.errorExpected, self.state)
                self.state = .done
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let loopBoundContext = context.loopBound
                switch Self.unwrapInboundIn(data) {
                case .head:
                    // We dispatch this to the event loop so that it doesn't happen immediately but rather can be
                    // run from the driving test code whenever it wants by running the EmbeddedEventLoop.
                    context.eventLoop.execute {
                        let context = loopBoundContext.value
                        context.writeAndFlush(
                            Self.wrapOutboundOut(
                                .head(
                                    .init(
                                        version: .http1_1,
                                        status: .ok
                                    )
                                )
                            ),
                            promise: nil
                        )
                    }
                    XCTAssertEqual(.reqHeadExpected, self.state)
                    self.state = .reqEndExpected
                case .body:
                    XCTFail("no body expected")
                case .end:
                    // We dispatch this to the event loop so that it doesn't happen immediately but rather can be
                    // run from the driving test code whenever it wants by running the EmbeddedEventLoop.
                    context.eventLoop.execute {
                        let context = loopBoundContext.value
                        context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: nil)
                    }
                    XCTAssertEqual(.reqEndExpected, self.state)
                    self.state = .errorExpected
                }
            }
        }

        let handler = VerifyOrderHandler()
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(HTTPServerProtocolErrorHandler()))
        XCTAssertNoThrow(try self.channel.pipeline.syncOperations.addHandler(handler))

        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(makeRequestHead(uri: "/one"))))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))
        self.channel.pipeline.fireErrorCaught(HTTPParserError.closedConnection)

        // let's now run the HTTP responses that we enqueued earlier on.
        (self.channel.eventLoop as! EmbeddedEventLoop).run()
        XCTAssertEqual(.done, handler.state)
    }

    func testRemovingWithResponseOutstandingTriggersRead() throws {
        // First, call read() and check it makes it through.
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Send in a request.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Call read again, twice. This should not change the number.
        self.channel.read()
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Remove the handler.
        XCTAssertNoThrow(try channel.pipeline.syncOperations.removeHandler(self.pipelineHandler).wait())

        // This should have automatically triggered a call to read(), but only one.
        XCTAssertEqual(self.readCounter.readCount, 2)

        // Incidentally we shouldn't have fired a quiesce event.
        XCTAssertEqual(self.quiesceEventRecorder.quiesceCount, 0)
    }

    func testRemovingWithPartialResponseOutstandingTriggersRead() throws {
        // First, call read() and check it makes it through.
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Send in a request.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Call read again, twice. This should not change the number.
        self.channel.read()
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Send a partial response, which should not trigger a read.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Remove the handler.
        XCTAssertNoThrow(try channel.pipeline.syncOperations.removeHandler(self.pipelineHandler).wait())

        // This should have automatically triggered a call to read(), but only one.
        XCTAssertEqual(self.readCounter.readCount, 2)

        // Incidentally we shouldn't have fired a quiesce event.
        XCTAssertEqual(self.quiesceEventRecorder.quiesceCount, 0)
    }

    func testRemovingWithBufferedRequestForwards() throws {
        // Send in a request, and part of another.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))

        // Only one request should have made it through.
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )

        // Remove the handler.
        XCTAssertNoThrow(try channel.pipeline.syncOperations.removeHandler(self.pipelineHandler).wait())

        // The extra data should have been forwarded.
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
            ]
        )
    }

    func testQuiescingInAResponseThenRemovedFiresEventAndReads() throws {
        // First, call read() and check it makes it through.
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Send through a request and part of another.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))

        // Only one request should have made it through.
        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )

        XCTAssertTrue(self.channel.isActive)
        XCTAssertEqual(self.quiesceEventRecorder.quiesceCount, 0)
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Now quiesce the channel.
        self.channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertTrue(self.channel.isActive)
        XCTAssertEqual(self.quiesceEventRecorder.quiesceCount, 0)
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Call read again, twice. This should not lead to reads, as we're waiting for the end.
        self.channel.read()
        self.channel.read()
        XCTAssertTrue(self.channel.isActive)
        XCTAssertEqual(self.quiesceEventRecorder.quiesceCount, 0)
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Now remove the handler.
        XCTAssertNoThrow(try channel.pipeline.syncOperations.removeHandler(self.pipelineHandler).wait())

        // Channel should be open, but the quiesce event should have fired, and read
        // shouldn't have been called as we aren't expecting more data.
        XCTAssertTrue(self.channel.isActive)
        XCTAssertEqual(self.quiesceEventRecorder.quiesceCount, 1)
        XCTAssertEqual(self.readCounter.readCount, 1)
    }

    func testQuiescingInAResponseThenRemovedFiresEventAndDoesntRead() throws {
        // First, call read() and check it makes it through.
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Send through just the head.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertEqual(
            self.readRecorder.reads,
            [.channelRead(HTTPServerRequestPart.head(self.requestHead))]
        )

        XCTAssertTrue(self.channel.isActive)
        XCTAssertEqual(self.quiesceEventRecorder.quiesceCount, 0)
        XCTAssertEqual(self.readCounter.readCount, 1)
        self.channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
        XCTAssertTrue(self.channel.isActive)
        XCTAssertEqual(self.quiesceEventRecorder.quiesceCount, 0)
        XCTAssertEqual(self.readCounter.readCount, 1)

        // Call read again, twice. This should pass through.
        self.channel.read()
        self.channel.read()
        XCTAssertTrue(self.channel.isActive)
        XCTAssertEqual(self.quiesceEventRecorder.quiesceCount, 0)
        XCTAssertEqual(self.readCounter.readCount, 3)

        // Now remove the handler.
        XCTAssertNoThrow(try channel.pipeline.syncOperations.removeHandler(self.pipelineHandler).wait())

        // Channel should be open, but the quiesce event should have fired, and read
        // shouldn't be (as it passed through.
        XCTAssertTrue(self.channel.isActive)
        XCTAssertEqual(self.quiesceEventRecorder.quiesceCount, 1)
        XCTAssertEqual(self.readCounter.readCount, 3)
    }

    func testServerCanRespondContinue() throws {
        // Send in the first part of a request.
        var expect100ContinueHead = self.requestHead!
        expect100ContinueHead.headers.replaceOrAdd(name: "expect", value: "100-continue")
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(expect100ContinueHead)))

        var continueResponse = self.responseHead
        continueResponse!.status = .continue

        // Now the server sends a continue response.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(continueResponse!)))

        // The client response completes.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Now the server sends the final response.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))
    }

    func testServerCanRespondProcessingMultipleTimes() throws {
        // Send in a request.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // We haven't completed our response, so no more reading
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 0)

        var processResponse: HTTPResponseHead = self.responseHead!
        processResponse.status = .processing

        // Now the server sends multiple processing responses.
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(processResponse)))

        // We are processing... Reading not allowed
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 0)

        // Continue processing...
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(processResponse)))

        // We are processing... Reading not allowed
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 0)

        // Continue processing...
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(processResponse)))

        // We are processing... Reading not allowed
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 0)

        // Now send the actual response!
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))
        XCTAssertNoThrow(try channel.writeOutbound(HTTPServerResponsePart.end(nil)))

        // This should have triggered a read
        XCTAssertEqual(self.readCounter.readCount, 1)
    }

    func testServerCloseOutputForcesReadsBackOn() throws {
        // Send in a request
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Reads are blocked.
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 0)

        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )

        // Now the server sends close output
        XCTAssertNoThrow(try channel.close(mode: .output).wait())

        // This unblocked the read and further reads can continue.
        XCTAssertEqual(self.readCounter.readCount, 1)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 2)
    }

    func testCloseOutputAlwaysAllowsReads() throws {
        // Send in a request
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Reads are blocked.
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 0)

        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )

        // Now the server sends close output
        XCTAssertNoThrow(try channel.close(mode: .output).wait())

        // This unblocked the read and further reads can continue.
        XCTAssertEqual(self.readCounter.readCount, 1)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 2)

        // New requests can come in, but are dropped.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Reads keep working.
        XCTAssertEqual(self.readCounter.readCount, 2)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 3)

        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )
    }

    func testCloseOutputFirstIsOkEvenIfItsABitWeird() throws {
        // Server sends close output first
        XCTAssertNoThrow(try channel.close(mode: .output).wait())

        // Send in a request
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Reads are unblocked.
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 1)

        // But the data is dropped.
        XCTAssertEqual(self.readRecorder.reads, [])

        // New requests can come in, and are dropped.
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Reads keep working.
        XCTAssertEqual(self.readCounter.readCount, 1)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 2)

        XCTAssertEqual(self.readRecorder.reads, [])
    }

    func testPipelinedRequestsAreDroppedWhenWeSendCloseOutput() throws {
        // Send in three requests
        for _ in 0..<3 {
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
            XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))
        }

        // Reads are blocked and only one request was read.
        XCTAssertEqual(self.readCounter.readCount, 0)
        self.channel.read()
        XCTAssertEqual(self.readCounter.readCount, 0)

        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )

        // Server sends close mode output. The buffered requests are dropped.
        XCTAssertNoThrow(try channel.close(mode: .output).wait())

        XCTAssertEqual(
            self.readRecorder.reads,
            [
                .channelRead(HTTPServerRequestPart.head(self.requestHead)),
                .channelRead(HTTPServerRequestPart.end(nil)),
            ]
        )
    }

    func testWritesAfterCloseOutputAreDropped() throws {
        // Send in a request
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.end(nil)))

        // Server sends a head.
        XCTAssertNoThrow(try self.channel.writeOutbound(HTTPServerResponsePart.head(self.responseHead)))

        // Now the server sends close output
        XCTAssertNoThrow(try channel.close(mode: .output).wait())

        // Now, in error, the server sends .body and .end. Both pass unannounced.
        XCTAssertNoThrow(try self.channel.writeOutbound(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer()))))
        XCTAssertNoThrow(try self.channel.writeOutbound(HTTPServerResponsePart.end(nil)))
    }

    func testSendingHeadTwiceGivesError() throws {
        self.pipelineHandler.failOnPreconditions = false
        // Sending a head once is normal
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))
        // Sending a head twice is an error
        XCTAssertThrowsError(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead))) { error in
            XCTAssertEqual(
                error as? HTTPServerPipelineHandler.ConnectionStateError,
                .preconditionViolated(message: "received request head in state requestAndResponseEndPending")
            )
        }
    }

    func testServerRespondToNothing() {
        self.pipelineHandler.failOnPreconditions = false

        // Writing an end whilst in state idle is an error
        XCTAssertThrowsError(try self.channel.writeOutbound(HTTPServerResponsePart.end(nil))) { error in
            XCTAssertEqual(
                error as? HTTPServerPipelineHandler.ConnectionStateError,
                .preconditionViolated(message: "Unexpectedly received a response in state idle")
            )
        }

        // Calling finish surfaces the error again
        XCTAssertThrowsError(try self.channel.finish()) { error in
            XCTAssertEqual(
                error as? HTTPServerPipelineHandler.ConnectionStateError,
                .preconditionViolated(message: "Unexpectedly received a response in state idle")
            )
        }
    }

    func testServerRequestEndFirstIsError() {
        self.pipelineHandler.failOnPreconditions = false
        // End sending a request which was never started
        XCTAssertThrowsError(try self.channel.writeInbound(HTTPServerRequestPart.end(nil))) { error in
            XCTAssertEqual(
                error as? HTTPServerPipelineHandler.ConnectionStateError,
                .preconditionViolated(message: "Received second request")
            )
        }
    }

    func testForcefulShutdownWhenViolatedPrecondition() {
        self.pipelineHandler.failOnPreconditions = false

        // End sending a request which was never started
        XCTAssertThrowsError(try self.channel.writeInbound(HTTPServerRequestPart.end(nil))) { error in
            XCTAssertEqual(
                error as? HTTPServerPipelineHandler.ConnectionStateError,
                .preconditionViolated(message: "Received second request")
            )
        }
        // The handler should now refuse further io, and forcefully shutdown
        XCTAssertNoThrow(try self.channel.writeInbound(HTTPServerRequestPart.head(self.requestHead)))

        self.channel.embeddedEventLoop.run()

        // Ensure the channel is closed
        XCTAssertNoThrow(try self.channel.closeFuture.wait())
    }
}
