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
import NIOCore
import XCTest

class TimeAmountTests: XCTestCase {
    func testTimeAmountConversion() {
        XCTAssertEqual(TimeAmount.nanoseconds(3), .nanoseconds(3))
        XCTAssertEqual(TimeAmount.microseconds(14), .nanoseconds(14_000))
        XCTAssertEqual(TimeAmount.milliseconds(15), .nanoseconds(15_000_000))
        XCTAssertEqual(TimeAmount.seconds(9), .nanoseconds(9_000_000_000))
        XCTAssertEqual(TimeAmount.minutes(2), .nanoseconds(120_000_000_000))
        XCTAssertEqual(TimeAmount.hours(6), .nanoseconds(21_600_000_000_000))
        XCTAssertEqual(TimeAmount.zero, .nanoseconds(0))
    }

    func testTimeAmountIsHashable() {
        let amounts: Set<TimeAmount> = [.seconds(1), .milliseconds(4), .seconds(1)]
        XCTAssertEqual(amounts, [.seconds(1), .milliseconds(4)])
    }
    
    func testTimeAmountDoesAddTime() {
        var lhs = TimeAmount.nanoseconds(0)
        let rhs = TimeAmount.nanoseconds(5)
        lhs += rhs
        XCTAssertEqual(lhs, .nanoseconds(5))
    }

    func testTimeAmountDoesSubtractTime() {
        var lhs = TimeAmount.nanoseconds(5)
        let rhs = TimeAmount.nanoseconds(5)
        lhs -= rhs
        XCTAssertEqual(lhs, .nanoseconds(0))
    }
}
