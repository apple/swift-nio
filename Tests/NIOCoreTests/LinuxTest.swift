//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
@testable import NIOCore

class LinuxTest: XCTestCase {
    func testCoreCountQuota() throws {
        #if os(Linux) || os(Android)
        try [
            ("50000", "100000", 1),
            ("100000", "100000", 1),
            ("100000\n", "100000", 1),
            ("100000", "100000\n", 1),
            ("150000", "100000", 2),
            ("200000", "100000", 2),
            ("-1", "100000", nil),
            ("100000", "-1", nil),
            ("", "100000", nil),
            ("100000", "", nil),
            ("100000", "0", nil)
        ].forEach { quota, period, count in
            try withTemporaryFile(content: quota) { (_, quotaPath) -> Void in
                try withTemporaryFile(content: period) { (_, periodPath) -> Void in
                    XCTAssertEqual(Linux.coreCount(quota: quotaPath, period: periodPath), count)
                }
            }
        }
        #endif
    }

    func testCoreCountCpuset() throws {
        #if os(Linux) || os(Android)
        try [
            ("0", 1),
            ("0,3", 2),
            ("0-3", 4),
            ("0-3,7", 5),
            ("0-3,7\n", 5),
            ("0,2-4,6,7,9-11", 9),
            ("", nil)
        ].forEach { cpuset, count in
            try withTemporaryFile(content: cpuset) { (_, path) -> Void in
                XCTAssertEqual(Linux.coreCount(cpuset: path), count)
            }
        }
        #endif
    }
}
