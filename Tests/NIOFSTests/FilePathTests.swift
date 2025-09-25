//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@_spi(Testing) @testable import NIOFS
import SystemPackage
import XCTest

#if canImport(System)
import System
#endif

final class FilePathTests: XCTestCase {
    /// Tests that the conversion of a SystemPackage.FilePath instance to a NIOFilePath instance (and vice-versa) results in the same underlying object.
    func testConversion() {
        // Create a NIOFilePath and SystemPackage.FilePath instance, both pointing to "/foo/bar/../baz"
        let filePathNIO = NIOFilePath("/foo/bar/../baz")
        let filePathSystemPackage = SystemPackage.FilePath("/foo/bar/../baz")

        // Convert the NIOFilePath instance to a SystemPackage.FilePath one, and check if the result matches the
        // directly initialized SystemPackage.FilePath instance
        XCTAssertEqual(SystemPackage.FilePath(filePathNIO), filePathSystemPackage)

        // Now do the opposite: convert the SystemPackage.FilePath instance to a NIOFilePath, and check if the result
        // matches the directly initialized NIOFilePath instance
        let systemPackageFilePathConvertedToNIO = NIOFilePath(filePathSystemPackage)
        XCTAssertEqual(systemPackageFilePathConvertedToNIO, filePathNIO)
    }
}
