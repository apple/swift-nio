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
        try withPipe { readFD, writeFD in
            var randomBytes: UInt8 = 42
            do {
                _ = try withUnsafePointer(to: &randomBytes) { ptr in
                    try readFD.withUnsafeFileDescriptor { readFD in
                        try Posix.setsockopt(socket: readFD, level: -1, optionName: -1, optionValue: ptr, optionLen: 0)
                    }
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
            return [readFD, writeFD]
        }
    }
}
