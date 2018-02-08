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

import NIO
import XCTest

class CompositeErrorTests: XCTestCase {
    func testEmptyCompositeError() {
        let err = NIOCompositeError(comprising: [])
        XCTAssertEqual(err.count, 0)

        for _ in err {
            XCTFail("Should not iterate")
        }

        XCTAssertNil(err.first)
        XCTAssertNil(err.last)
    }

    func testValuesInCompositeError() {
        class MyError: Error { }
        let innerErrors = [ChannelError.ioOnClosedChannel, ChannelError.alreadyClosed, ChannelError.connectPending]
        let err = NIOCompositeError(comprising: innerErrors)

        XCTAssertEqual(err.count, 3)

        let retrievedErrors = Array(err)
        XCTAssertEqual(retrievedErrors as! [ChannelError], innerErrors)
    }
}
