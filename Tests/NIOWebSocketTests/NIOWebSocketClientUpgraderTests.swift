//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOWebSocket
import XCTest

/// a mock random number generator which will return the given `numbers` in order
private struct TestRandomNumberGenerator: RandomNumberGenerator {
    var numbers: [UInt64]
    var nextRandomNumberIndex: Int
    init(numbers: [UInt64], nextRandomNumberIndex: Int = 0) {
        self.numbers = numbers
        self.nextRandomNumberIndex = nextRandomNumberIndex
    }
    mutating func next() -> UInt64 {
        defer { nextRandomNumberIndex += 1 }
        return numbers[nextRandomNumberIndex % numbers.count]
    }
}

final class NIOWebSocketClientUpgraderTests: XCTestCase {
    func testRandomRequestKey() {
        var generator = TestRandomNumberGenerator(numbers: [10, 11])
        let requestKey = NIOWebSocketClientUpgrader.randomRequestKey(using: &generator)
        XCTAssertEqual(requestKey, "AAAAAAAAAAoAAAAAAAAACw==")
    }
    func testRandomRequestKeyWithSystemRandomNumberGenerator() {
        XCTAssertEqual(
            NIOWebSocketClientUpgrader.randomRequestKey().count,
            24,
            "request key must be exactly 16 bytes long and this corresponds to 24 characters in base64"
        )
    }
}
