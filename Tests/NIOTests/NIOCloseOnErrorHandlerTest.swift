//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import XCTest

final class DummyFailingHandler1: ChannelInboundHandler {
    typealias InboundIn = NIOAny

    struct DummyError1: Error {}

    func channelRead(context: ChannelHandlerContext, data _: NIOAny) {
        context.fireErrorCaught(DummyError1())
    }
}

class NIOCloseOnErrorHandlerTest: XCTestCase {
    private var eventLoop: EmbeddedEventLoop!
    private var channel: EmbeddedChannel!

    override func setUp() {
        super.setUp()

        eventLoop = EmbeddedEventLoop()
        channel = EmbeddedChannel(loop: eventLoop)
    }

    override func tearDown() {
        eventLoop = nil
        if channel.isActive {
            XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
        }

        super.tearDown()
    }

    func testChannelCloseOnError() throws {
        XCTAssertNoThrow(channel.pipeline.addHandlers([
            DummyFailingHandler1(),
            NIOCloseOnErrorHandler(),
        ]))

        XCTAssertNoThrow(try channel.connect(to: .init(ipAddress: "1.2.3.4", port: 5)).wait())
        XCTAssertTrue(channel.isActive)
        XCTAssertThrowsError(try channel.writeInbound("Hello World")) { XCTAssertTrue($0 is DummyFailingHandler1.DummyError1) }
        XCTAssertFalse(channel.isActive)
    }
}
