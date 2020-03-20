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

class String_ByteBuffer_Tests: XCTestCase {

    func testCreateStringFromBuffer() {
        let testString = "some sample data"
        var buffer = ByteBuffer(ByteBufferView(testString.utf8))
        XCTAssertEqual(String(from: &buffer), testString)
        XCTAssertEqual(buffer.readableBytes, 0)
    }
    
}
