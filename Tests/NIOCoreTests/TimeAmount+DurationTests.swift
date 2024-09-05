//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest

@testable import NIOCore

class TimeAmountDurationTests: XCTestCase {
    func testTimeAmountFromDurationConversion() throws {
        guard #available(macOS 13, iOS 16, tvOS 16, watchOS 9, *) else {
            throw XCTSkip("Required API is not available for this test.")
        }
        XCTAssertEqual(
            TimeAmount(Duration(secondsComponent: 0, attosecondsComponent: 0)),
            .nanoseconds(0)
        )
        XCTAssertEqual(
            TimeAmount(Duration(secondsComponent: 0, attosecondsComponent: 1_000_000_001)),
            .nanoseconds(1)
        )
        XCTAssertEqual(
            TimeAmount(Duration(secondsComponent: 0, attosecondsComponent: 999_999_999)),
            .nanoseconds(0)
        )
        XCTAssertEqual(
            TimeAmount(Duration(secondsComponent: 42, attosecondsComponent: 1_000_000_001)),
            .nanoseconds(42_000_000_001)
        )
        XCTAssertEqual(
            TimeAmount(Duration(secondsComponent: 42, attosecondsComponent: 999_999_999)),
            .nanoseconds(42_000_000_000)
        )
        XCTAssertEqual(
            TimeAmount(Duration(secondsComponent: 0, attosecondsComponent: -1_000_000_000)),
            .nanoseconds(-1)
        )
        XCTAssertEqual(
            TimeAmount(Duration(secondsComponent: 0, attosecondsComponent: -999_999_999)),
            .nanoseconds(0)
        )
        XCTAssertEqual(
            TimeAmount(Duration(secondsComponent: 1, attosecondsComponent: -1_000_000_000_000_000_000)),
            .nanoseconds(0)
        )
        XCTAssertEqual(
            TimeAmount(Duration(secondsComponent: 1, attosecondsComponent: -1_000_000_000_000_000_001)),
            .nanoseconds(0)
        )
        XCTAssertEqual(
            TimeAmount(Duration(secondsComponent: 1, attosecondsComponent: -1_000_000_001_000_000_000)),
            .nanoseconds(-1)
        )
        XCTAssertEqual(
            TimeAmount(Duration.nanoseconds(Int64.max)),
            .nanoseconds(Int64.max)
        )
        XCTAssertEqual(
            TimeAmount(Duration.nanoseconds(Int64.max) + .nanoseconds(1)),
            .nanoseconds(Int64.max)
        )
    }

    func testTimeAmountToDurationLosslessRountTrip() throws {
        guard #available(macOS 13, iOS 16, tvOS 16, watchOS 9, *) else {
            throw XCTSkip("Required API is not available for this test.")
        }
        for amount in [
            TimeAmount.zero,
            TimeAmount.seconds(1),
            TimeAmount.seconds(-1),
            TimeAmount.nanoseconds(1),
            TimeAmount.nanoseconds(-1),
            TimeAmount.nanoseconds(.max),
            TimeAmount.nanoseconds(.min),
        ] {
            XCTAssertEqual(TimeAmount(Duration(amount)), amount)
        }
    }

    func testDurationToTimeAmountLossyRoundTrip() throws {
        guard #available(macOS 13, iOS 16, tvOS 16, watchOS 9, *) else {
            throw XCTSkip("Required API is not available for this test.")
        }
        for duration in [
            Duration.zero,
            Duration.seconds(1),
            Duration.seconds(-1),
            Duration.nanoseconds(Int64.max),
            Duration.nanoseconds(Int64.min),
            Duration.nanoseconds(Int64.max) + Duration.nanoseconds(1),
            Duration.nanoseconds(Int64.min) - Duration.nanoseconds(1),
            Duration(secondsComponent: 0, attosecondsComponent: 1),
            Duration(secondsComponent: 0, attosecondsComponent: 1_000_000_000),
            Duration(secondsComponent: 0, attosecondsComponent: 1_500_000_000),
            Duration(secondsComponent: 0, attosecondsComponent: 1_000_000_001),
            Duration(secondsComponent: 0, attosecondsComponent: 0_999_999_999),
            Duration(secondsComponent: 0, attosecondsComponent: -1),
            Duration(secondsComponent: 0, attosecondsComponent: -1_000_000_000),
            Duration(secondsComponent: 0, attosecondsComponent: -1_500_000_000),
            Duration(secondsComponent: 0, attosecondsComponent: -1_000_000_001),
            Duration(secondsComponent: 0, attosecondsComponent: -0_999_999_999),
        ] {
            let duration_ = Duration(TimeAmount(duration))
            XCTAssertEqual(duration_.nanosecondsClamped, duration.nanosecondsClamped)
        }
    }
}
