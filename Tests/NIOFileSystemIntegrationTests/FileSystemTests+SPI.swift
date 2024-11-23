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

import SystemPackage
import XCTest
@_spi(Testing) import _NIOFileSystem

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FileSystemTests {
    func testRemoveOneItemIgnoresNonExistentFile() async throws {
        let fs = FileSystem.shared
        let path = try await fs.temporaryFilePath()
        let removed = try await fs.removeOneItem(at: path)
        XCTAssertEqual(removed, 0)
    }
}
