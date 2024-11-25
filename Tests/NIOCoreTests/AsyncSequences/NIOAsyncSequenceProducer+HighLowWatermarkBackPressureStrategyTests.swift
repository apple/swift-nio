//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import XCTest

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class NIOAsyncSequenceProducerBackPressureStrategiesHighLowWatermarkTests: XCTestCase {
    private var strategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark!

    override func setUp() {
        super.setUp()

        self.strategy = .init(
            lowWatermark: 5,
            highWatermark: 10
        )
    }

    override func tearDown() {
        self.strategy = nil

        super.tearDown()
    }

    func testDidYield_whenBelowHighWatermark() {
        XCTAssertTrue(self.strategy.didYield(bufferDepth: 5))
    }

    func testDidYield_whenAboveHighWatermark() {
        XCTAssertFalse(self.strategy.didYield(bufferDepth: 15))
    }

    func testDidYield_whenAtHighWatermark() {
        XCTAssertFalse(self.strategy.didYield(bufferDepth: 10))
    }

    func testDidConsume_whenBelowLowWatermark() {
        XCTAssertTrue(self.strategy.didConsume(bufferDepth: 4))
    }

    func testDidConsume_whenAboveLowWatermark() {
        XCTAssertTrue(self.strategy.didConsume(bufferDepth: 6))
    }

    func testDidConsume_whenAtLowWatermark() {
        XCTAssertTrue(self.strategy.didConsume(bufferDepth: 5))
    }

    func testDidYieldWhenNoOutstandingDemand() {
        // Hit the high watermark
        XCTAssertFalse(self.strategy.didYield(bufferDepth: 10))
        // Drop below it, don't read.
        XCTAssertFalse(self.strategy.didConsume(bufferDepth: 7))
        // Yield more, still above the low watermark, so don't produce more.
        XCTAssertFalse(self.strategy.didYield(bufferDepth: 8))
        // Drop below low watermark to start producing again.
        XCTAssertTrue(self.strategy.didConsume(bufferDepth: 4))
    }
}
