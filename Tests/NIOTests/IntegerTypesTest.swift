//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
@testable import NIO

public class IntegerTypesTest: XCTestCase {
    func testNextPowerOfOfTwoZero() {
        XCTAssertEqual(1, (0 as UInt).nextPowerOf2())
        XCTAssertEqual(1, (0 as UInt16).nextPowerOf2())
        XCTAssertEqual(1, (0 as UInt32).nextPowerOf2())
        XCTAssertEqual(1, (0 as UInt64).nextPowerOf2())
        XCTAssertEqual(1, (0 as Int).nextPowerOf2())
        XCTAssertEqual(1, (0 as Int16).nextPowerOf2())
        XCTAssertEqual(1, (0 as Int32).nextPowerOf2())
        XCTAssertEqual(1, (0 as Int64).nextPowerOf2())
    }

    func testNextPowerOfTwoOfOne() {
        XCTAssertEqual(1, (1 as UInt).nextPowerOf2())
        XCTAssertEqual(1, (1 as UInt16).nextPowerOf2())
        XCTAssertEqual(1, (1 as UInt32).nextPowerOf2())
        XCTAssertEqual(1, (1 as UInt64).nextPowerOf2())
        XCTAssertEqual(1, (1 as Int).nextPowerOf2())
        XCTAssertEqual(1, (1 as Int16).nextPowerOf2())
        XCTAssertEqual(1, (1 as Int32).nextPowerOf2())
        XCTAssertEqual(1, (1 as Int64).nextPowerOf2())
    }

    func testNextPowerOfTwoOfTwo() {
        XCTAssertEqual(2, (2 as UInt).nextPowerOf2())
        XCTAssertEqual(2, (2 as UInt16).nextPowerOf2())
        XCTAssertEqual(2, (2 as UInt32).nextPowerOf2())
        XCTAssertEqual(2, (2 as UInt64).nextPowerOf2())
        XCTAssertEqual(2, (2 as Int).nextPowerOf2())
        XCTAssertEqual(2, (2 as Int16).nextPowerOf2())
        XCTAssertEqual(2, (2 as Int32).nextPowerOf2())
        XCTAssertEqual(2, (2 as Int64).nextPowerOf2())
    }

    func testNextPowerOfTwoOfThree() {
        XCTAssertEqual(4, (3 as UInt).nextPowerOf2())
        XCTAssertEqual(4, (3 as UInt16).nextPowerOf2())
        XCTAssertEqual(4, (3 as UInt32).nextPowerOf2())
        XCTAssertEqual(4, (3 as UInt64).nextPowerOf2())
        XCTAssertEqual(4, (3 as Int).nextPowerOf2())
        XCTAssertEqual(4, (3 as Int16).nextPowerOf2())
        XCTAssertEqual(4, (3 as Int32).nextPowerOf2())
        XCTAssertEqual(4, (3 as Int64).nextPowerOf2())
    }

    func testNextPowerOfTwoOfFour() {
        XCTAssertEqual(4, (4 as UInt).nextPowerOf2())
        XCTAssertEqual(4, (4 as UInt16).nextPowerOf2())
        XCTAssertEqual(4, (4 as UInt32).nextPowerOf2())
        XCTAssertEqual(4, (4 as UInt64).nextPowerOf2())
        XCTAssertEqual(4, (4 as Int).nextPowerOf2())
        XCTAssertEqual(4, (4 as Int16).nextPowerOf2())
        XCTAssertEqual(4, (4 as Int32).nextPowerOf2())
        XCTAssertEqual(4, (4 as Int64).nextPowerOf2())
    }

    func testNextPowerOfTwoOfFive() {
        XCTAssertEqual(8, (5 as UInt).nextPowerOf2())
        XCTAssertEqual(8, (5 as UInt16).nextPowerOf2())
        XCTAssertEqual(8, (5 as UInt32).nextPowerOf2())
        XCTAssertEqual(8, (5 as UInt64).nextPowerOf2())
        XCTAssertEqual(8, (5 as Int).nextPowerOf2())
        XCTAssertEqual(8, (5 as Int16).nextPowerOf2())
        XCTAssertEqual(8, (5 as Int32).nextPowerOf2())
        XCTAssertEqual(8, (5 as Int64).nextPowerOf2())
    }

    func testDescriptionUInt24() {
        XCTAssertEqual("0", _UInt24.min.description)
        XCTAssertEqual("16777215", _UInt24.max.description)
        XCTAssertEqual("12345678", _UInt24(12345678).description)
        XCTAssertEqual("1", _UInt24(1).description)
        XCTAssertEqual("8388608", _UInt24(1 << 23).description)
    }

    func testDescriptionUInt56() {
        XCTAssertEqual("0", _UInt56.min.description)
        XCTAssertEqual("72057594037927935", _UInt56.max.description)
        XCTAssertEqual("12345678901234567", _UInt56(12345678901234567 as UInt64).description)
        XCTAssertEqual("1", _UInt56(1).description)
        XCTAssertEqual("36028797018963968", _UInt56(1 << 55).description)
    }
}
