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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux) || os(Android)
import NIOFileSystem
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

    func testByteCountEquality() {
        let byteCount1 = ByteCount.bytes(10)
        let byteCount2 = ByteCount.bytes(20)
        XCTAssertEqual(byteCount1, byteCount1)
        XCTAssertNotEqual(byteCount1, byteCount2)
    }
}
#endif
