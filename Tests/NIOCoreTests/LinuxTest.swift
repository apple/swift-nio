//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2025 Apple Inc. and the SwiftNIO project authors
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
    func testCoreCountCgroup1RestrictionWithVariousIntegerFormats() throws {
        #if os(Linux) || os(Android)
        // Test various integer formats in cgroup files
        let testCases = [
            ("42", "100000", 1),  // Simple integer
            ("0", "100000", nil),  // Zero should be rejected
        ]

        for (quotaContent, periodContent, expectedResult) in testCases {
            try withTemporaryFile(content: quotaContent) { (_, quotaPath) -> Void in
                try withTemporaryFile(content: periodContent) { (_, periodPath) -> Void in
                    let result = Linux.coreCountCgroup1Restriction(quota: quotaPath, period: periodPath)
                    XCTAssertEqual(result, expectedResult, "Failed for quota '\(quotaContent)'")
                }
            }
        }

        // Test invalid integer cases
        let invalidCases = ["abc", "12abc", ""]
        for invalidContent in invalidCases {
            try withTemporaryFile(content: invalidContent) { (_, quotaPath) -> Void in
                try withTemporaryFile(content: "100000") { (_, periodPath) -> Void in
                    let result = Linux.coreCountCgroup1Restriction(quota: quotaPath, period: periodPath)
                    XCTAssertNil(result, "Should return nil for invalid quota '\(invalidContent)'")
                }
            }
        }
        #endif
    }

    func testCoreCountWithMultipleRanges() throws {
        #if os(Linux) || os(Android)
        // Test coreCount function with multiple CPU ranges
        let content = "0,2,4-6"  // Should count as 5 cores: 0,2,4,5,6
        try withTemporaryFile(content: content) { (_, path) -> Void in
            let result = Linux.coreCount(cpuset: path)
            XCTAssertEqual(result, 5)
        }
        #endif
    }

    func testCoreCountWithSingleRange() throws {
        #if os(Linux) || os(Android)
        let content = "0-3"  // Should count as 4 cores
        try withTemporaryFile(content: content) { (_, path) -> Void in
            let result = Linux.coreCount(cpuset: path)
            XCTAssertEqual(result, 4)
        }
        #endif
    }

    func testCoreCountWithEmptyFile() throws {
        #if os(Linux) || os(Android)
        try withTemporaryFile(content: "") { (_, path) -> Void in
            let result = Linux.coreCount(cpuset: path)
            XCTAssertNil(result)  // Empty file should return nil
        }
        #endif
    }

    func testCoreCountReadsOnlyFirstLine() throws {
        #if os(Linux) || os(Android)
        // Test that coreCount only processes the first line of the file
        let content = "0-1\n2-3\n4-5"  // First line should be "0-1" = 2 cores
        try withTemporaryFile(content: content) { (_, path) -> Void in
            let result = Linux.coreCount(cpuset: path)
            XCTAssertEqual(result, 2)  // Should only process first line
        }
        #endif
    }

    func testCoreCountWithSimpleCpuset() throws {
        #if os(Linux) || os(Android)
        // Test coreCount function with simple cpuset formats
        let testCases = [
            ("0", 1),  // Single core
            ("0-3", 4),  // Range 0,1,2,3
            ("5-7", 3),  // Range 5,6,7
            ("10-10", 1),  // Single core as range
        ]

        for (input, expected) in testCases {
            try withTemporaryFile(content: input) { (_, path) -> Void in
                let result = Linux.coreCount(cpuset: path)
                XCTAssertEqual(result, expected, "Failed for input '\(input)'")
            }
        }
        #endif
    }

    func testCoreCountWithComplexCpuset() throws {
        #if os(Linux) || os(Android)
        // Test more complex cpuset formats
        let cpusets = [
            ("0", 1),
            ("0,2", 2),
            ("0-1,4-5", 4),  // Two ranges: 0,1 and 4,5
            ("0,2-4,7,9-10", 7),  // Mixed: 0, 2,3,4, 7, 9,10
        ]
        for (cpuset, count) in cpusets {
            try withTemporaryFile(content: cpuset) { (_, path) -> Void in
                XCTAssertEqual(Linux.coreCount(cpuset: path), count)
            }
        }
        #endif
    }

    func testCoreCountQuota() throws {
        #if os(Linux) || os(Android)
        let coreCountQuoats = [
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
            ("100000", "0", nil),
        ]
        for (quota, period, count) in coreCountQuoats {
            try withTemporaryFile(content: quota) { (_, quotaPath) -> Void in
                try withTemporaryFile(content: period) { (_, periodPath) -> Void in
                    XCTAssertEqual(Linux.coreCountCgroup1Restriction(quota: quotaPath, period: periodPath), count)
                }
            }
        }
        #endif
    }

    func testCoreCountCpuset() throws {
        #if os(Linux) || os(Android)
        let cpusets = [
            ("0", 1),
            ("0,3", 2),
            ("0-3", 4),
            ("0-3,7", 5),
            ("0-3,7\n", 5),
            ("0,2-4,6,7,9-11", 9),
            ("", nil),
        ]
        for (cpuset, count) in cpusets {
            try withTemporaryFile(content: cpuset) { (_, path) -> Void in
                XCTAssertEqual(Linux.coreCount(cpuset: path), count)
            }
        }
        #endif
    }

    func testCoreCountCgroup2() throws {
        #if os(Linux) || os(Android)
        let contents = [
            ("max 100000", nil),
            ("75000 100000", 1),
            ("200000 100000", 2),
        ]
        for (content, count) in contents {
            try withTemporaryFile(content: content) { (_, path) in
                XCTAssertEqual(Linux.coreCountCgroup2Restriction(cpuMaxPath: path), count)
            }
        }
        #endif
    }

    func testParseV2CgroupLine() throws {
        #if os(Linux) || os(Android)
        let testCases: [(String, String?)] = [
            // Valid cgroup v2 formats
            ("0::/", "/"),  // Root cgroup
            ("0::/user.slice", "/user.slice"),  // User slice
            ("0::/docker/container123", "/docker/container123"),  // Docker container
            ("0::/", "/"),  // This should work with omittingEmptySubsequences: false
            ("0::///", "///"),  // Multiple slashes should be preserved
            ("0::/a/b/c", "/a/b/c"),  // Normal nested path
            ("0::/.hidden", "/.hidden"),  // Hidden directory
            ("0::/path:extra", "/path:extra"),  // Test we're limiting to 2 splits maximum

            // Invalid formats that should return nil
            ("1::/", nil),  // Not hierarchy 0
            ("0:name:/", nil),  // Has cgroup name (v1 format)
            ("0", nil),  // Missing colons
            ("0:", nil),  // Missing second colon
            (":", nil),  // Only one colon
            ("::/", nil),  // Missing hierarchy number
            ("", nil),  // Empty string
        ]

        for (input, expected) in testCases {
            let result = Linux.parseV2CgroupLine(Substring(input))
            XCTAssertEqual(
                result,
                expected,
                "Failed parsing '\(input)' - expected '\(expected ?? "nil")' but got '\(result ?? "nil")'"
            )
        }
        #endif
    }
}
