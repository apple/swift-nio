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

final class FileOpenOptionsTests: XCTestCase {
    private let expectedDefaults: FilePermissions = [
        .ownerReadWrite,
        .groupRead,
        .otherRead,
    ]

    func testReadOptions() {
        var options = OpenOptions.Read()
        XCTAssertEqual(FileDescriptor.OpenOptions(options), [])

        options.followSymbolicLinks = false
        options.closeOnExec = true
        XCTAssertEqual(FileDescriptor.OpenOptions(options), [.noFollow, .closeOnExec])
    }

    func testDirectoryOptions() {
        var options = OpenOptions.Directory()
        XCTAssertEqual(FileDescriptor.OpenOptions(options), [.directory])

        options.followSymbolicLinks = false
        XCTAssertEqual(FileDescriptor.OpenOptions(options), [.noFollow, .directory])

        options.followSymbolicLinks = true
        options.closeOnExec = true
        XCTAssertEqual(FileDescriptor.OpenOptions(options), [.directory, .closeOnExec])
    }

    func testWriteOpenOrCreate() {
        var options = OpenOptions.Write.modifyFile(createIfNecessary: true)
        XCTAssertEqual(options.existingFile, .open)
        XCTAssertEqual(options.permissionsForRegularFile, self.expectedDefaults)
        XCTAssertEqual(FileDescriptor.OpenOptions(options), [.create])

        options = OpenOptions.Write.modifyFile(createIfNecessary: true, permissions: .groupExecute)
        XCTAssertEqual(options.existingFile, .open)
        XCTAssertEqual(options.permissionsForRegularFile, .groupExecute)
        XCTAssertEqual(FileDescriptor.OpenOptions(options), [.create])

        options.followSymbolicLinks = false
        XCTAssertEqual(FileDescriptor.OpenOptions(options), [.create, .noFollow])
    }

    func testWriteTruncateOrCreate() {
        var options = OpenOptions.Write.newFile(replaceExisting: true)
        XCTAssertEqual(options.existingFile, .truncate)
        XCTAssertEqual(options.permissionsForRegularFile, self.expectedDefaults)
        XCTAssertEqual(FileDescriptor.OpenOptions(options), [.create, .truncate])

        options = OpenOptions.Write.newFile(replaceExisting: true, permissions: .groupExecute)
        XCTAssertEqual(options.existingFile, .truncate)
        XCTAssertEqual(options.permissionsForRegularFile, .groupExecute)
        XCTAssertEqual(FileDescriptor.OpenOptions(options), [.create, .truncate])

        options.followSymbolicLinks = false
        XCTAssertEqual(FileDescriptor.OpenOptions(options), [.create, .truncate, .noFollow])
    }

    func testWriteExclusiveOpen() {
        var options = OpenOptions.Write(existingFile: .open, newFile: nil)
        XCTAssertEqual(options.existingFile, .open)
        XCTAssertNil(options.newFile)
        XCTAssertEqual(FileDescriptor.OpenOptions(options), [])

        options.followSymbolicLinks = false
        XCTAssertEqual(FileDescriptor.OpenOptions(options), [.noFollow])
    }

    func testWriteExclusiveCreate() {
        var options = OpenOptions.Write.newFile(replaceExisting: false)
        XCTAssertEqual(options.existingFile, .none)
        XCTAssertEqual(options.permissionsForRegularFile, self.expectedDefaults)
        XCTAssertEqual(FileDescriptor.OpenOptions(options), [.create, .exclusiveCreate])

        options = OpenOptions.Write.newFile(replaceExisting: false, permissions: .groupExecute)
        XCTAssertEqual(options.existingFile, .none)
        XCTAssertEqual(options.permissionsForRegularFile, .groupExecute)
        XCTAssertEqual(FileDescriptor.OpenOptions(options), [.create, .exclusiveCreate])

        options.followSymbolicLinks = false
        XCTAssertEqual(FileDescriptor.OpenOptions(options), [.create, .exclusiveCreate, .noFollow])
    }
}
