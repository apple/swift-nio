//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux) || os(Android)
import NIOFileSystem
import NIOFileSystemFoundationCompat
import XCTest

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class FileSystemBytesConformanceTests: XCTestCase {
    func testTimepecToDate() async throws {
        XCTAssertEqual(
            FileInfo.Timespec(seconds: 0, nanoseconds: 0).date,
            Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(
            FileInfo.Timespec(seconds: 1, nanoseconds: 0).date,
            Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(
            FileInfo.Timespec(seconds: 1, nanoseconds: 1).date,
            Date(timeIntervalSince1970: 1.000000001)
        )
    }
}
#endif
