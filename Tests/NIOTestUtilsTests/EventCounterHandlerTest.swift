//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOTestUtils
import XCTest

class EventCounterHandlerTest: XCTestCase {
    private var channel: EmbeddedChannel!
    private var handler: EventCounterHandler!

    override func setUp() {
        handler = EventCounterHandler()
        channel = EmbeddedChannel(handler: handler)
    }

    override func tearDown() {
        handler = nil
        XCTAssertNoThrow(try channel?.finish())
        channel = nil
    }

    func testNothingButEmbeddedChannelInit() {
        // EmbeddedChannel calls register
        XCTAssertEqual(["channelRegistered", "register"], handler.allTriggeredEvents())
        XCTAssertNoThrow(try handler.checkValidity())
        XCTAssertEqual(1, handler.channelRegisteredCalls)
        XCTAssertEqual(1, handler.registerCalls)
    }

    func testNothing() {
        let handler = EventCounterHandler()
        XCTAssertNoThrow(try channel.pipeline.addHandler(handler).wait())
        XCTAssertEqual([], handler.allTriggeredEvents())
        XCTAssertNoThrow(try handler.checkValidity())
    }

    func testInboundWrite() {
        XCTAssertNoThrow(try channel.writeInbound(()))
        XCTAssertEqual(["channelRegistered", "register", "channelRead", "channelReadComplete"],
                       handler.allTriggeredEvents())
        XCTAssertNoThrow(try handler.checkValidity())
        XCTAssertEqual(1, handler.channelRegisteredCalls)
        XCTAssertEqual(1, handler.registerCalls)
        XCTAssertEqual(1, handler.channelReadCalls)
        XCTAssertEqual(1, handler.channelReadCompleteCalls)
    }

    func testOutboundWrite() {
        XCTAssertNoThrow(try channel.writeOutbound(()))
        XCTAssertEqual(["channelRegistered", "register", "write", "flush"],
                       handler.allTriggeredEvents())
        XCTAssertNoThrow(try handler.checkValidity())
        XCTAssertEqual(1, handler.channelRegisteredCalls)
        XCTAssertEqual(1, handler.registerCalls)
        XCTAssertEqual(1, handler.writeCalls)
        XCTAssertEqual(1, handler.flushCalls)
    }

    func testConnectChannel() {
        XCTAssertNoThrow(try channel.connect(to: .init(ipAddress: "1.2.3.4", port: 5678)).wait())
        XCTAssertEqual(["channelRegistered", "register", "connect", "channelActive"],
                       handler.allTriggeredEvents())
        XCTAssertNoThrow(try handler.checkValidity())
        XCTAssertEqual(1, handler.channelRegisteredCalls)
        XCTAssertEqual(1, handler.registerCalls)
        XCTAssertEqual(1, handler.connectCalls)
        XCTAssertEqual(1, handler.channelActiveCalls)
    }

    func testBindChannel() {
        XCTAssertNoThrow(try channel.bind(to: .init(ipAddress: "1.2.3.4", port: 5678)).wait())
        XCTAssertEqual(["channelRegistered", "register", "bind"],
                       handler.allTriggeredEvents())
        XCTAssertNoThrow(try handler.checkValidity())
        XCTAssertEqual(1, handler.channelRegisteredCalls)
        XCTAssertEqual(1, handler.registerCalls)
        XCTAssertEqual(1, handler.bindCalls)
    }

    func testConnectAndCloseChannel() {
        XCTAssertNoThrow(try channel.connect(to: .init(ipAddress: "1.2.3.4", port: 5678)).wait())
        XCTAssertNoThrow(try channel.close().wait())
        XCTAssertEqual(["channelRegistered", "register", "connect", "channelActive", "close", "channelInactive",
                        "channelUnregistered"],
                       handler.allTriggeredEvents())
        XCTAssertNoThrow(try handler.checkValidity())
        XCTAssertEqual(1, handler.channelRegisteredCalls)
        XCTAssertEqual(1, handler.registerCalls)
        XCTAssertEqual(1, handler.connectCalls)
        XCTAssertEqual(1, handler.channelActiveCalls)
        XCTAssertEqual(1, handler.channelInactiveCalls)
        XCTAssertEqual(1, handler.closeCalls)
        XCTAssertEqual(1, handler.channelUnregisteredCalls)

        channel = nil // don't let tearDown close it
    }

    func testError() {
        struct Dummy: Error {}
        channel.pipeline.fireErrorCaught(Dummy())

        XCTAssertEqual(["channelRegistered", "register", "errorCaught"],
                       handler.allTriggeredEvents())
        XCTAssertNoThrow(try handler.checkValidity())
        XCTAssertEqual(1, handler.errorCaughtCalls)

        XCTAssertThrowsError(try channel.throwIfErrorCaught())
    }

    func testEventsWithoutArguments() {
        let noArgEvents: [((ChannelPipeline) -> () -> Void, String)] = [
            (ChannelPipeline.fireChannelRegistered, "channelRegistered"),
            (ChannelPipeline.fireChannelUnregistered, "channelUnregistered"),
            (ChannelPipeline.fireChannelActive, "channelActive"),
            (ChannelPipeline.fireChannelInactive, "channelInactive"),
            (ChannelPipeline.fireChannelReadComplete, "channelReadComplete"),
            (ChannelPipeline.fireChannelWritabilityChanged, "channelWritabilityChanged"),
            (ChannelPipeline.flush, "flush"),
            (ChannelPipeline.read, "read"),
        ]

        for (fire, name) in noArgEvents {
            let channel = EmbeddedChannel()
            defer {
                XCTAssertNoThrow(try channel.finish())
            }
            let handler = EventCounterHandler()

            XCTAssertNoThrow(try channel.pipeline.addHandler(handler).wait())
            XCTAssertEqual([], handler.allTriggeredEvents())
            fire(channel.pipeline)()
            XCTAssertEqual([name], handler.allTriggeredEvents())
        }
    }

    func testInboundUserEvent() {
        channel.pipeline.fireUserInboundEventTriggered(())

        XCTAssertEqual(["channelRegistered", "register", "userInboundEventTriggered"],
                       handler.allTriggeredEvents())
        XCTAssertNoThrow(try handler.checkValidity())
        XCTAssertEqual(1, handler.userInboundEventTriggeredCalls)
    }

    func testOutboundUserEvent() {
        channel.pipeline.triggerUserOutboundEvent((), promise: nil)

        XCTAssertEqual(["channelRegistered", "register", "triggerUserOutboundEvent"],
                       handler.allTriggeredEvents())
        XCTAssertNoThrow(try handler.checkValidity())
        XCTAssertEqual(1, handler.triggerUserOutboundEventCalls)
    }
}
