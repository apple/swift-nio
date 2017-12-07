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

class SystemTest: XCTestCase {
    func testSystemCallWrapperPerformance() throws {
        try runSystemCallWrapperPerformanceTest(testAssertFunction: XCTAssert,
                                                debugModeAllowed: true)
    }

    func testErrorsWorkCorrectly() throws {
        var fds: [Int32] = [-1, -1]
        let pipeErr = pipe(&fds)
        precondition(pipeErr == 0, "pipe returned error")
        defer {
            close(fds[0])
            close(fds[1])
        }
        var randomBytes: UInt8 = 42
        do {
            _ = try withUnsafePointer(to: &randomBytes) { ptr in
                try Posix.setsockopt(socket: fds[0], level: -1, optionName: -1, optionValue: ptr, optionLen: 0)
            }
            XCTFail("success even though the call was invalid")
        } catch let e as IOError {
            XCTAssertEqual(ENOTSOCK, e.errnoCode)
            XCTAssert(e.description.contains("setsockopt"))
            XCTAssert(e.description.contains("\(ENOTSOCK)"))
            XCTAssert(e.localizedDescription.contains("\(ENOTSOCK)"), "\(e.localizedDescription)")
        } catch let e {
            XCTFail("wrong error thrown: \(e)")
        }
    }
}
