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
import XCTest

final class DummyFailingHandler1: ChannelInboundHandler, Sendable {
    typealias InboundIn = NIOAny

    struct DummyError1: Error {}

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireErrorCaught(DummyError1())
    }
}

class NIOCloseOnErrorHandlerTest: XCTestCase {
    private var eventLoop: EmbeddedEventLoop!
    private var channel: EmbeddedChannel!

    override func setUp() {
        super.setUp()

        self.eventLoop = EmbeddedEventLoop()
        self.channel = EmbeddedChannel(loop: self.eventLoop)
    }

    override func tearDown() {
        self.eventLoop = nil
        if self.channel.isActive {
            XCTAssertNoThrow(XCTAssertTrue(try self.channel.finish().isClean))
        }

        super.tearDown()
    }

    func testChannelCloseOnError() throws {
        XCTAssertNoThrow(
            self.channel.pipeline.addHandlers([
                DummyFailingHandler1(),
                NIOCloseOnErrorHandler(),
            ])
        )

        XCTAssertNoThrow(try self.channel.connect(to: .init(ipAddress: "1.2.3.4", port: 5)).wait())
        XCTAssertTrue(self.channel.isActive)
        XCTAssertThrowsError(try self.channel.writeInbound("Hello World")) {
            XCTAssertTrue($0 is DummyFailingHandler1.DummyError1)
        }
        XCTAssertFalse(self.channel.isActive)
    }

}
