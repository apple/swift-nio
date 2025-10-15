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

@_spi(Testing) import NIOFS
import XCTest

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

final class FileTypeTests: XCTestCase {
    func testFileTypeEquatable() {
        let types = FileType.allCases
        // Use indices to avoid using the `Equatable` conformance to write the tests.
        for index in types.indices {
            XCTAssertEqual(types[index], types[index])
            for otherIndex in types.indices where otherIndex != index {
                XCTAssertNotEqual(types[index], types[otherIndex])
            }
        }
    }

    func testFileTypeHashable() {
        // Tests there is `Hashable` conformance is sufficient as we rely on the compiler
        // synthesising the implementation.
        let types = FileType.allCases
        let unique = Set(types)
        XCTAssertEqual(types.count, unique.count)
    }

    func testCustomStringConvertible() {
        XCTAssertEqual(String(describing: FileType.block), "block")
        XCTAssertEqual(String(describing: FileType.character), "character")
        XCTAssertEqual(String(describing: FileType.directory), "directory")
        XCTAssertEqual(String(describing: FileType.fifo), "fifo")
        XCTAssertEqual(String(describing: FileType.regular), "regular")
        XCTAssertEqual(String(describing: FileType.socket), "socket")
        XCTAssertEqual(String(describing: FileType.symlink), "symlink")
        XCTAssertEqual(String(describing: FileType.unknown), "unknown")
        XCTAssertEqual(String(describing: FileType.whiteout), "whiteout")
    }

    func testConversionFromModeT() {
        XCTAssertEqual(FileType(platformSpecificMode: S_IFIFO), .fifo)
        XCTAssertEqual(FileType(platformSpecificMode: S_IFCHR), .character)
        XCTAssertEqual(FileType(platformSpecificMode: S_IFDIR), .directory)
        XCTAssertEqual(FileType(platformSpecificMode: S_IFBLK), .block)
        XCTAssertEqual(FileType(platformSpecificMode: S_IFREG), .regular)
        XCTAssertEqual(FileType(platformSpecificMode: S_IFLNK), .symlink)
        XCTAssertEqual(FileType(platformSpecificMode: S_IFSOCK), .socket)
        #if canImport(Darwin)
        XCTAssertEqual(FileType(platformSpecificMode: S_IFWHT), .whiteout)
        #endif
    }

    func testConversionFromDirentType() {
        XCTAssertEqual(FileType(direntType: numericCast(DT_FIFO)), .fifo)
        XCTAssertEqual(FileType(direntType: numericCast(DT_CHR)), .character)
        XCTAssertEqual(FileType(direntType: numericCast(DT_DIR)), .directory)
        XCTAssertEqual(FileType(direntType: numericCast(DT_BLK)), .block)
        XCTAssertEqual(FileType(direntType: numericCast(DT_REG)), .regular)
        XCTAssertEqual(FileType(direntType: numericCast(DT_LNK)), .symlink)
        XCTAssertEqual(FileType(direntType: numericCast(DT_SOCK)), .socket)
        #if canImport(Darwin)
        XCTAssertEqual(FileType(direntType: numericCast(DT_WHT)), .whiteout)
        #endif
    }
}
