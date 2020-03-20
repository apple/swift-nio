//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import NIO
@testable import NIOFoundationCompat

class Data_ByteBuffer_Tests: XCTestCase {

    func testCreateDataFromBuffer() {
        let testString = "some sample bytes"
        var buffer = ByteBuffer(ByteBufferView(testString.utf8))
        let data = Data(from: &buffer)
        XCTAssertEqual(Array(data), Array(testString.utf8))
        XCTAssertEqual(buffer.readableBytes, 0)
    }
    
}
