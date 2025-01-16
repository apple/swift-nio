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

    func testTimeAmountCappedOverflow() {
        let overflowCap = TimeAmount.nanoseconds(Int64.max)
        XCTAssertEqual(TimeAmount.microseconds(.max), overflowCap)
        XCTAssertEqual(TimeAmount.milliseconds(.max), overflowCap)
        XCTAssertEqual(TimeAmount.seconds(.max), overflowCap)
        XCTAssertEqual(TimeAmount.minutes(.max), overflowCap)
        XCTAssertEqual(TimeAmount.hours(.max), overflowCap)
    }

    func testTimeAmountCappedUnderflow() {
        let underflowCap = TimeAmount.nanoseconds(.min)
        XCTAssertEqual(TimeAmount.microseconds(.min), underflowCap)
        XCTAssertEqual(TimeAmount.milliseconds(.min), underflowCap)
        XCTAssertEqual(TimeAmount.seconds(.min), underflowCap)
        XCTAssertEqual(TimeAmount.minutes(.min), underflowCap)
        XCTAssertEqual(TimeAmount.hours(.min), underflowCap)
    }

    func testTimeAmountParsing() throws {
        // Test all supported hour formats
        XCTAssertEqual(try TimeAmount("2h"), .hours(2))
        XCTAssertEqual(try TimeAmount("2hr"), .hours(2))
        XCTAssertEqual(try TimeAmount("2hrs"), .hours(2))

        // Test all supported minute formats
        XCTAssertEqual(try TimeAmount("3m"), .minutes(3))
        XCTAssertEqual(try TimeAmount("3min"), .minutes(3))

        // Test all supported second formats
        XCTAssertEqual(try TimeAmount("4s"), .seconds(4))
        XCTAssertEqual(try TimeAmount("4sec"), .seconds(4))
        XCTAssertEqual(try TimeAmount("4secs"), .seconds(4))

        // Test all supported millisecond formats
        XCTAssertEqual(try TimeAmount("5ms"), .milliseconds(5))
        XCTAssertEqual(try TimeAmount("5millis"), .milliseconds(5))

        // Test all supported microsecond formats
        XCTAssertEqual(try TimeAmount("6us"), .microseconds(6))
        XCTAssertEqual(try TimeAmount("6µs"), .microseconds(6))
        XCTAssertEqual(try TimeAmount("6micros"), .microseconds(6))

        // Test all supported nanosecond formats
        XCTAssertEqual(try TimeAmount("7ns"), .nanoseconds(7))
        XCTAssertEqual(try TimeAmount("7nanos"), .nanoseconds(7))
    }

    func testTimeAmountParsingWithWhitespace() throws {
        XCTAssertEqual(try TimeAmount("5 s"), .seconds(5))
        XCTAssertEqual(try TimeAmount("100  ms"), .milliseconds(100))
        XCTAssertEqual(try TimeAmount("42    ns"), .nanoseconds(42))
        XCTAssertEqual(try TimeAmount(" 5s "), .seconds(5))
    }

    func testTimeAmountParsingCaseInsensitive() throws {
        XCTAssertEqual(try TimeAmount("5S"), .seconds(5))
        XCTAssertEqual(try TimeAmount("100MS"), .milliseconds(100))
        XCTAssertEqual(try TimeAmount("1HR"), .hours(1))
        XCTAssertEqual(try TimeAmount("30MIN"), .minutes(30))
    }

    func testTimeAmountParsingInvalidInput() throws {
        // Empty string
        XCTAssertThrowsError(try TimeAmount("")) { error in
            XCTAssertEqual(
                error as? TimeAmount.ValidationError,
                TimeAmount.ValidationError.invalidNumber("'' cannot be parsed as number and unit")
            )
        }

        // Invalid number
        XCTAssertThrowsError(try TimeAmount("abc")) { error in
            XCTAssertEqual(
                error as? TimeAmount.ValidationError,
                TimeAmount.ValidationError.invalidNumber("'abc' cannot be parsed as number and unit")
            )
        }

        // Unknown unit
        XCTAssertThrowsError(try TimeAmount("5x")) { error in
            XCTAssertEqual(
                error as? TimeAmount.ValidationError,
                TimeAmount.ValidationError.unsupportedUnit("Unknown unit 'x' in '5x'")
            )
        }

        // Missing number
        XCTAssertThrowsError(try TimeAmount("ms")) { error in
            XCTAssertEqual(
                error as? TimeAmount.ValidationError,
                TimeAmount.ValidationError.invalidNumber("'ms' cannot be parsed as number and unit")
            )
        }
    }

    func testTimeAmountPrettyPrint() {
        // Basic formatting
        XCTAssertEqual(TimeAmount.seconds(5).description, "5 s")
        XCTAssertEqual(TimeAmount.milliseconds(100).description, "100 ms")
        XCTAssertEqual(TimeAmount.microseconds(250).description, "250 us")
        XCTAssertEqual(TimeAmount.nanoseconds(42).description, "42 ns")

        // Unit selection based on value
        XCTAssertEqual(TimeAmount.nanoseconds(1_000).description, "1 us")
        XCTAssertEqual(TimeAmount.nanoseconds(1_000_000).description, "1 ms")
        XCTAssertEqual(TimeAmount.nanoseconds(1_000_000_000).description, "1 s")

        // Values with remainders
        XCTAssertEqual(TimeAmount.nanoseconds(1_500).description, "1500 ns")
        XCTAssertEqual(TimeAmount.nanoseconds(1_500_000).description, "1500 us")
        XCTAssertEqual(TimeAmount.nanoseconds(1_500_000_000).description, "1500 ms")

        // Negative values
        XCTAssertEqual(TimeAmount.seconds(-5).description, "-5 s")
        XCTAssertEqual(TimeAmount.milliseconds(-100).description, "-100 ms")
    }
}
