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
}
