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

//
import XCTest

@testable import NIOCore

class IOErrorTest: XCTestCase {
    func testMemoryLayoutBelowThreshold() {
        XCTAssert(MemoryLayout<IOError>.size <= 24)
    }

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
    func testDeprecatedAPIStillFunctional() {
        XCTAssertNoThrow(IOError(errnoCode: 1, function: "anyFunc"))
    }
}
