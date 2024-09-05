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

import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest

final class NIOLoopBoundTests: XCTestCase {
    private var loop: EmbeddedEventLoop!

    func testLoopBoundIsSendableWithNonSendableValue() {
        let nonSendable = NotSendable()
        let sendable = NIOLoopBound(nonSendable, eventLoop: self.loop)
        let sendableBox = NIOLoopBoundBox(nonSendable, eventLoop: self.loop)

        XCTAssert(sendable.value === nonSendable)
        XCTAssert(sendableBox.value === nonSendable)

        sendableBlackhole(sendable)
        sendableBlackhole(sendableBox)
    }

    func testLoopBoundBoxCanBeInitialisedWithNilOffLoopAndLaterSetToValue() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let loop = group.any()

        let sendableBox = NIOLoopBoundBox.makeEmptyBox(valueType: NotSendable.self, eventLoop: loop)
        XCTAssertNoThrow(
            try loop.submit {
                sendableBox.value = NotSendable()
            }.wait()
        )
        XCTAssertNoThrow(
            try loop.submit {
                XCTAssertNotNil(sendableBox.value)
            }.wait()
        )
    }

    func testLoopBoundBoxCanBeInitialisedWithSendableValueOffLoopAndLaterSetToValue() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let loop = group.any()

        let sendableBox = NIOLoopBoundBox.makeBoxSendingValue(15, as: Int.self, eventLoop: loop)
        for _ in 0..<(100 - 15) {
            loop.execute {
                sendableBox.value += 1
            }
        }
        XCTAssertEqual(
            100,
            try loop.submit {
                sendableBox.value
            }.wait()
        )
    }

    func testInPlaceMutation() {
        var loopBound = NIOLoopBound(CoWValue(), eventLoop: loop)
        XCTAssertTrue(loopBound.value.mutateInPlace())

        let loopBoundBox = NIOLoopBoundBox(CoWValue(), eventLoop: loop)
        XCTAssertTrue(loopBoundBox.value.mutateInPlace())
    }

    // MARK: - Helpers
    func sendableBlackhole<S: Sendable>(_ sendableThing: S) {}

    // MARK: - Setup/teardown
    override func setUp() {
        self.loop = EmbeddedEventLoop()
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.loop?.syncShutdownGracefully())
        self.loop = nil
    }
}

final class NotSendable {}

@available(*, unavailable)
extension NotSendable: Sendable {}
