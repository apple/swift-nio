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

    func testLoopBoundBoxCanBeInitialisedWithTakingValueOffLoopAndLaterSetToValue() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let loop = group.any()

        class NonSendableIntBox {
            var value: Int

            init(value: Int) {
                self.value = value
            }
        }

        let instance = NonSendableIntBox(value: 15)
        let sendableBox = NIOLoopBoundBox.makeBoxSendingValue(instance, as: NonSendableIntBox.self, eventLoop: loop)
        for _ in 0..<(100 - 15) {
            loop.execute {
                sendableBox.value.value += 1
            }
        }
        XCTAssertEqual(
            100,
            try loop.submit {
                sendableBox.value.value
            }.wait()
        )
    }

    func testInPlaceMutation() {
        var loopBound = NIOLoopBound(CoWValue(), eventLoop: loop)
        XCTAssertTrue(loopBound.value.mutateInPlace())

        let loopBoundBox = NIOLoopBoundBox(CoWValue(), eventLoop: loop)
        XCTAssertTrue(loopBoundBox.value.mutateInPlace())
    }

    func testWithValue() {
        var expectedValue = 0
        let loopBound = NIOLoopBoundBox(expectedValue, eventLoop: loop)
        for value in 1...100 {
            loopBound.withValue { boundValue in
                XCTAssertEqual(boundValue, expectedValue)
                boundValue = value
                expectedValue = value
            }
        }
        XCTAssertEqual(100, loopBound.value)
    }

    func testWithValueRethrows() {
        struct TestError: Error {}

        let loopBound = NIOLoopBoundBox(0, eventLoop: loop)
        XCTAssertThrowsError(
            try loopBound.withValue { boundValue in
                XCTAssertEqual(0, boundValue)
                boundValue = 10
                throw TestError()
            }
        )

        XCTAssertEqual(10, loopBound.value, "Ensure value is set even if we throw")
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
