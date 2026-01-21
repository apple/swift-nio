//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the SwiftNIO project authors
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
import NIOTestUtils
import XCTest

class EventCounterHandlerTest: XCTestCase {
    private var channel: EmbeddedChannel!
    private var handler: EventCounterHandler!

    override func setUp() {
        self.handler = EventCounterHandler()
        self.channel = EmbeddedChannel(handler: self.handler)
    }

    override func tearDown() {
        self.handler = nil
        XCTAssertNoThrow(try self.channel?.finish())
        self.channel = nil
    }

    func testNothingButEmbeddedChannelInit() {
        // EmbeddedChannel calls register
        XCTAssertEqual(["channelRegistered", "register"], self.handler.allTriggeredEvents())
        XCTAssertNoThrow(try self.handler.checkValidity())
        XCTAssertEqual(1, self.handler.channelRegisteredCalls)
        XCTAssertEqual(1, self.handler.registerCalls)
    }

    func testNothing() {
        let handler = EventCounterHandler()
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(handler).wait())
        XCTAssertEqual([], handler.allTriggeredEvents())
        XCTAssertNoThrow(try handler.checkValidity())
    }

    func testInboundWrite() {
        XCTAssertNoThrow(try self.channel.writeInbound(()))
        XCTAssertEqual(
            ["channelRegistered", "register", "channelRead", "channelReadComplete"],
            self.handler.allTriggeredEvents()
        )
        XCTAssertNoThrow(try self.handler.checkValidity())
        XCTAssertEqual(1, self.handler.channelRegisteredCalls)
        XCTAssertEqual(1, self.handler.registerCalls)
        XCTAssertEqual(1, self.handler.channelReadCalls)
        XCTAssertEqual(1, self.handler.channelReadCompleteCalls)
    }

    func testOutboundWrite() {
        XCTAssertNoThrow(try self.channel.writeOutbound(()))
        XCTAssertEqual(
            ["channelRegistered", "register", "write", "flush"],
            self.handler.allTriggeredEvents()
        )
        XCTAssertNoThrow(try self.handler.checkValidity())
        XCTAssertEqual(1, self.handler.channelRegisteredCalls)
        XCTAssertEqual(1, self.handler.registerCalls)
        XCTAssertEqual(1, self.handler.writeCalls)
        XCTAssertEqual(1, self.handler.flushCalls)
    }

    func testConnectChannel() {
        XCTAssertNoThrow(try self.channel.connect(to: .init(ipAddress: "1.2.3.4", port: 5678)).wait())
        XCTAssertEqual(
            ["channelRegistered", "register", "connect", "channelActive"],
            self.handler.allTriggeredEvents()
        )
        XCTAssertNoThrow(try self.handler.checkValidity())
        XCTAssertEqual(1, self.handler.channelRegisteredCalls)
        XCTAssertEqual(1, self.handler.registerCalls)
        XCTAssertEqual(1, self.handler.connectCalls)
        XCTAssertEqual(1, self.handler.channelActiveCalls)
    }

    func testBindChannel() {
        XCTAssertNoThrow(try self.channel.bind(to: .init(ipAddress: "1.2.3.4", port: 5678)).wait())
        XCTAssertEqual(
            ["channelRegistered", "register", "bind"],
            self.handler.allTriggeredEvents()
        )
        XCTAssertNoThrow(try self.handler.checkValidity())
        XCTAssertEqual(1, self.handler.channelRegisteredCalls)
        XCTAssertEqual(1, self.handler.registerCalls)
        XCTAssertEqual(1, self.handler.bindCalls)
    }

    func testConnectAndCloseChannel() {
        XCTAssertNoThrow(try self.channel.connect(to: .init(ipAddress: "1.2.3.4", port: 5678)).wait())
        XCTAssertNoThrow(try self.channel.close().wait())
        XCTAssertEqual(
            [
                "channelRegistered", "register", "connect", "channelActive", "close", "channelInactive",
                "channelUnregistered",
            ],
            self.handler.allTriggeredEvents()
        )
        XCTAssertNoThrow(try self.handler.checkValidity())
        XCTAssertEqual(1, self.handler.channelRegisteredCalls)
        XCTAssertEqual(1, self.handler.registerCalls)
        XCTAssertEqual(1, self.handler.connectCalls)
        XCTAssertEqual(1, self.handler.channelActiveCalls)
        XCTAssertEqual(1, self.handler.channelInactiveCalls)
        XCTAssertEqual(1, self.handler.closeCalls)
        XCTAssertEqual(1, self.handler.channelUnregisteredCalls)

        self.channel = nil  // don't let tearDown close it
    }

    func testError() {
        struct Dummy: Error {}
        self.channel.pipeline.fireErrorCaught(Dummy())

        XCTAssertEqual(
            ["channelRegistered", "register", "errorCaught"],
            self.handler.allTriggeredEvents()
        )
        XCTAssertNoThrow(try self.handler.checkValidity())
        XCTAssertEqual(1, self.handler.errorCaughtCalls)

        XCTAssertThrowsError(try self.channel.throwIfErrorCaught())
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
        self.channel.pipeline.fireUserInboundEventTriggered(())

        XCTAssertEqual(
            ["channelRegistered", "register", "userInboundEventTriggered"],
            self.handler.allTriggeredEvents()
        )
        XCTAssertNoThrow(try self.handler.checkValidity())
        XCTAssertEqual(1, self.handler.userInboundEventTriggeredCalls)
    }

    func testOutboundUserEvent() {
        self.channel.pipeline.triggerUserOutboundEvent((), promise: nil)

        XCTAssertEqual(
            ["channelRegistered", "register", "triggerUserOutboundEvent"],
            self.handler.allTriggeredEvents()
        )
        XCTAssertNoThrow(try self.handler.checkValidity())
        XCTAssertEqual(1, self.handler.triggerUserOutboundEventCalls)
    }
}
