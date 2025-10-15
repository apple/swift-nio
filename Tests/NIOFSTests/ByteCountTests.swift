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

import NIOFS
import XCTest

class ByteCountTests: XCTestCase {
    func testByteCountBytes() {
        let byteCount = ByteCount.bytes(10)
        XCTAssertEqual(byteCount.bytes, 10)
    }

    func testByteCountKilobytes() {
        let byteCount = ByteCount.kilobytes(10)
        XCTAssertEqual(byteCount.bytes, 10_000)
    }

    func testByteCountMegabytes() {
        let byteCount = ByteCount.megabytes(10)
        XCTAssertEqual(byteCount.bytes, 10_000_000)
    }

    func testByteCountGigabytes() {
        let byteCount = ByteCount.gigabytes(10)
        XCTAssertEqual(byteCount.bytes, 10_000_000_000)
    }

    func testByteCountKibibytes() {
        let byteCount = ByteCount.kibibytes(10)
        XCTAssertEqual(byteCount.bytes, 10_240)
    }

    func testByteCountMebibytes() {
        let byteCount = ByteCount.mebibytes(10)
        XCTAssertEqual(byteCount.bytes, 10_485_760)
    }

    func testByteCountGibibytes() {
        let byteCount = ByteCount.gibibytes(10)
        XCTAssertEqual(byteCount.bytes, 10_737_418_240)
    }

    func testByteCountUnlimited() {
        let byteCount = ByteCount.unlimited
        XCTAssertEqual(byteCount.bytes, .max)
    }

    func testByteCountEquality() {
        let byteCount1 = ByteCount.bytes(10)
        let byteCount2 = ByteCount.bytes(20)
        XCTAssertEqual(byteCount1, byteCount1)
        XCTAssertNotEqual(byteCount1, byteCount2)
    }

    func testByteCountZero() {
        let byteCount = ByteCount.zero
        XCTAssertEqual(byteCount.bytes, 0)
    }

    func testByteCountAddition() {
        let byteCount1 = ByteCount.bytes(10)
        let byteCount2 = ByteCount.bytes(20)
        let sum = byteCount1 + byteCount2
        XCTAssertEqual(sum.bytes, 30)
    }

    func testByteCountSubtraction() {
        let byteCount1 = ByteCount.bytes(30)
        let byteCount2 = ByteCount.bytes(20)
        let difference = byteCount1 - byteCount2
        XCTAssertEqual(difference.bytes, 10)
    }

    func testByteCountComparison() {
        let byteCount1 = ByteCount.bytes(10)
        let byteCount2 = ByteCount.bytes(20)
        XCTAssertLessThan(byteCount1, byteCount2)
        XCTAssertGreaterThan(byteCount2, byteCount1)
    }
}
