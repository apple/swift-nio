//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) YEARS Apple Inc. and the SwiftNIO project authors
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

class NIOAnyUnwrapTests: XCTestCase {
    
    func testSafeUnwrap_some() {
        let value = "value"
        let data = NIOAny(value)
        XCTAssertEqual(data.unwrap(as: String.self), value)
    }
    
    func testSafeUnwrap_nil() {
        let data = NIOAny("value")
        XCTAssertNil(data.safeUnwrap(as: Int.self))
    }
    
}
