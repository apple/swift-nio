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

import CNIOLinux
import NIOFS
import XCTest

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

#if canImport(Darwin)
private let S_IFREG = Darwin.S_IFREG
#elseif canImport(Glibc)
private let S_IFREG = Glibc.S_IFREG
#elseif canImport(Musl)
private let S_IFREG = Musl.S_IFREG
#endif

final class FileInfoTests: XCTestCase {
    private var status: CInterop.Stat {
        var status = CInterop.Stat()
        status.st_dev = 1
        status.st_mode = .init(S_IFREG | 0o777)
        status.st_nlink = 3
        status.st_ino = 4
        status.st_uid = 5
        status.st_gid = 6
        status.st_rdev = 7
        status.st_size = 8
        status.st_blocks = 9
        status.st_blksize = 10

        #if canImport(Darwin)
        status.st_atimespec = timespec(tv_sec: 0, tv_nsec: 0)
        status.st_mtimespec = timespec(tv_sec: 1, tv_nsec: 0)
        status.st_ctimespec = timespec(tv_sec: 2, tv_nsec: 0)
        status.st_birthtimespec = timespec(tv_sec: 3, tv_nsec: 0)
        status.st_flags = 11
        status.st_gen = 12
        #elseif canImport(Glibc) || canImport(Android)
        status.st_atim = timespec(tv_sec: 0, tv_nsec: 0)
        status.st_mtim = timespec(tv_sec: 1, tv_nsec: 0)
        status.st_ctim = timespec(tv_sec: 2, tv_nsec: 0)
        #endif

        return status
    }

    func testConversionFromStat() {
        let info = FileInfo(platformSpecificStatus: self.status)
        XCTAssertEqual(info.type, .regular)
        XCTAssertEqual(
            info.permissions,
            [.groupReadWriteExecute, .ownerReadWriteExecute, .otherReadWriteExecute]
        )
        XCTAssertEqual(info.userID, FileInfo.UserID(rawValue: 5))
        XCTAssertEqual(info.groupID, FileInfo.GroupID(rawValue: 6))
        XCTAssertEqual(info.size, 8)

        XCTAssertEqual(info.lastAccessTime, FileInfo.Timespec(seconds: 0, nanoseconds: 0))
        XCTAssertEqual(info.lastDataModificationTime, FileInfo.Timespec(seconds: 1, nanoseconds: 0))
        XCTAssertEqual(info.lastStatusChangeTime, FileInfo.Timespec(seconds: 2, nanoseconds: 0))
    }

    func testEquatableConformance() {
        let info = FileInfo(platformSpecificStatus: self.status)
        let other = FileInfo(platformSpecificStatus: self.status)
        XCTAssertEqual(info, other)

        func assertNotEqualAfterMutation(line: UInt = #line, _ mutate: (inout FileInfo) -> Void) {
            var modified = info
            mutate(&modified)
            XCTAssertNotEqual(info, modified, line: line)
        }

        assertNotEqualAfterMutation { $0.platformSpecificStatus!.st_dev += 1 }
        assertNotEqualAfterMutation { $0.platformSpecificStatus!.st_mode += 1 }
        assertNotEqualAfterMutation { $0.platformSpecificStatus!.st_nlink += 1 }
        assertNotEqualAfterMutation { $0.platformSpecificStatus!.st_ino += 1 }
        assertNotEqualAfterMutation { $0.platformSpecificStatus!.st_uid += 1 }
        assertNotEqualAfterMutation { $0.platformSpecificStatus!.st_gid += 1 }
        assertNotEqualAfterMutation { $0.platformSpecificStatus!.st_rdev += 1 }
        assertNotEqualAfterMutation { $0.platformSpecificStatus!.st_size += 1 }
        assertNotEqualAfterMutation { $0.platformSpecificStatus!.st_blocks += 1 }
        assertNotEqualAfterMutation { $0.platformSpecificStatus!.st_blksize += 1 }

        #if canImport(Darwin)
        assertNotEqualAfterMutation { $0.platformSpecificStatus!.st_atimespec.tv_sec += 1 }
        assertNotEqualAfterMutation { $0.platformSpecificStatus!.st_mtimespec.tv_sec += 1 }
        assertNotEqualAfterMutation { $0.platformSpecificStatus!.st_ctimespec.tv_sec += 1 }
        assertNotEqualAfterMutation { $0.platformSpecificStatus!.st_birthtimespec.tv_sec += 1 }
        assertNotEqualAfterMutation { $0.platformSpecificStatus!.st_flags += 1 }
        assertNotEqualAfterMutation { $0.platformSpecificStatus!.st_gen += 1 }
        #elseif canImport(Glibc) || canImport(Android)
        assertNotEqualAfterMutation { $0.platformSpecificStatus!.st_atim.tv_sec += 1 }
        assertNotEqualAfterMutation { $0.platformSpecificStatus!.st_mtim.tv_sec += 1 }
        assertNotEqualAfterMutation { $0.platformSpecificStatus!.st_ctim.tv_sec += 1 }
        #endif
    }

    func testHashableConformance() {
        let info = FileInfo(platformSpecificStatus: self.status)
        let other = FileInfo(platformSpecificStatus: self.status)
        XCTAssertEqual(Set([info, other]), [info])

        func assertDifferentHashValueAfterMutation(
            line: UInt = #line,
            _ mutate: (inout FileInfo) -> Void
        ) {
            // Hash values _should_ be unique but aren't guaranteed to be. Generate 100 different
            // versions of the value and expect that at least 80 different hash values.
            var modified = info
            var hashValues: Set<Int> = [info.hashValue]
            for _ in 1..<100 {
                mutate(&modified)
                hashValues.insert(modified.hashValue)
            }
            XCTAssertGreaterThanOrEqual(hashValues.count, 80, line: line)
        }

        assertDifferentHashValueAfterMutation { $0.platformSpecificStatus!.st_dev += 1 }
        assertDifferentHashValueAfterMutation { $0.platformSpecificStatus!.st_mode += 1 }
        assertDifferentHashValueAfterMutation { $0.platformSpecificStatus!.st_nlink += 1 }
        assertDifferentHashValueAfterMutation { $0.platformSpecificStatus!.st_ino += 1 }
        assertDifferentHashValueAfterMutation { $0.platformSpecificStatus!.st_uid += 1 }
        assertDifferentHashValueAfterMutation { $0.platformSpecificStatus!.st_gid += 1 }
        assertDifferentHashValueAfterMutation { $0.platformSpecificStatus!.st_rdev += 1 }
        assertDifferentHashValueAfterMutation { $0.platformSpecificStatus!.st_size += 1 }
        assertDifferentHashValueAfterMutation { $0.platformSpecificStatus!.st_blocks += 1 }
        assertDifferentHashValueAfterMutation { $0.platformSpecificStatus!.st_blksize += 1 }

        #if canImport(Darwin)
        assertDifferentHashValueAfterMutation {
            $0.platformSpecificStatus!.st_atimespec.tv_sec += 1
        }
        assertDifferentHashValueAfterMutation {
            $0.platformSpecificStatus!.st_mtimespec.tv_sec += 1
        }
        assertDifferentHashValueAfterMutation {
            $0.platformSpecificStatus!.st_ctimespec.tv_sec += 1
        }
        assertDifferentHashValueAfterMutation {
            $0.platformSpecificStatus!.st_birthtimespec.tv_sec += 1
        }
        assertDifferentHashValueAfterMutation { $0.platformSpecificStatus!.st_flags += 1 }
        assertDifferentHashValueAfterMutation { $0.platformSpecificStatus!.st_gen += 1 }
        #elseif canImport(Glibc) || canImport(Android)
        assertDifferentHashValueAfterMutation { $0.platformSpecificStatus!.st_atim.tv_sec += 1 }
        assertDifferentHashValueAfterMutation { $0.platformSpecificStatus!.st_mtim.tv_sec += 1 }
        assertDifferentHashValueAfterMutation { $0.platformSpecificStatus!.st_ctim.tv_sec += 1 }
        #endif
    }
}
