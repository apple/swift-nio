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
@testable import NIOWebSocket

class Base64Test: XCTestCase {
    func testEncodeEmptyData() throws {
        let data = [UInt8]()
        let encodedData = String(base64Encoding: data)
        XCTAssertEqual(encodedData.count, 0)
    }

    func testBase64EncodingArrayOfNulls() throws {
        let data = Array(repeating: UInt8(0), count: 10)
        let encodedData = String(base64Encoding: data)
        XCTAssertEqual(encodedData, "AAAAAAAAAAAAAA==")
    }

    func testBase64EncodingAllTheBytesSequentially() throws {
        let data = Array(UInt8(0)...UInt8(255))
        let encodedData = String(base64Encoding: data)
        XCTAssertEqual(encodedData, "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5fYGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn+AgYKDhIWGh4iJiouMjY6PkJGSk5SVlpeYmZqbnJ2en6ChoqOkpaanqKmqq6ytrq+wsbKztLW2t7i5uru8vb6/wMHCw8TFxsfIycrLzM3Oz9DR0tPU1dbX2Nna29zd3t/g4eLj5OXm5+jp6uvs7e7v8PHy8/T19vf4+fr7/P3+/w==")
    }
}
