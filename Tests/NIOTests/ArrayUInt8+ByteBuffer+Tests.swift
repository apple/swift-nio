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

class Array_UInt8_ByteBuffer_Tests: XCTestCase {

    func testCreateArrayFromBuffer() {
        let testString = "some sample data"
        var buffer = ByteBuffer(ByteBufferView(testString.utf8))
        XCTAssertEqual(Array(from: &buffer), Array(testString.utf8))
        XCTAssertEqual(buffer.readableBytes, 0)
    }
    
}
