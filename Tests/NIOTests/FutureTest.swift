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

enum FutureTestError : Error {
    case example
}

class FutureTest : XCTestCase {
    func testFutureFulfilledIfHasResult() throws {
        let eventLoop = EmbeddedEventLoop()
        let f = Future(eventLoop: eventLoop, checkForPossibleDeadlock: true, result: 5)
        XCTAssertTrue(f.fulfilled)
    }

    func testFutureFulfilledIfHasError() throws {
        let eventLoop = EmbeddedEventLoop()
        let f = Future<Void>(eventLoop: eventLoop, checkForPossibleDeadlock: true, error: FutureTestError.example)
        XCTAssertTrue(f.fulfilled)
    }
}
