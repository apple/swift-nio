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
import NIOCore
@_spi(Testing) import NIOFileSystem
@preconcurrency import SystemPackage
import XCTest

extension FilePath {
    static let testData = FilePath(#filePath)
        .removingLastComponent()  // FileHandleTests.swift
        .appending("Test Data")
        .lexicallyNormalized()

    static let testDataReadme = Self.testData.appending("README.md")
    static let testDataReadmeSymlink = Self.testData.appending("README.md.symlink")
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FileSystem {
    func temporaryFilePath(
        _ function: String = #function,
        inTemporaryDirectory: Bool = true
    ) async throws -> FilePath {
        if inTemporaryDirectory {
            let directory = try await self.temporaryDirectory
            return self.temporaryFilePath(function, inDirectory: directory)
        } else {
            return self.temporaryFilePath(function, inDirectory: nil)
        }
    }

    func temporaryFilePath(
        _ function: String = #function,
        inDirectory directory: FilePath?
    ) -> FilePath {
        let index = function.firstIndex(of: "(")!
        let functionName = function.prefix(upTo: index)
        let random = UInt32.random(in: .min ... .max)
        let fileName = "\(functionName)-\(random)"

        if let directory = directory {
            return directory.appending(fileName)
        } else {
            return FilePath(fileName)
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class FileSystemTests: XCTestCase {
    var fs: FileSystem { return .shared }

    func testOpenFileForReading() async throws {
        try await self.fs.withFileHandle(forReadingAt: .testDataReadme) { file in
            let info = try await file.info()
            XCTAssertEqual(info.type, .regular)
            XCTAssertGreaterThan(info.size, 0)
        }
    }

    func testOpenFileForReadingFollowsSymlink() async throws {
        try await self.fs.withFileHandle(forReadingAt: .testDataReadmeSymlink) { file in
            let info = try await file.info()
            XCTAssertEqual(info.type, .regular)
        }
    }

    func testOpenSymlinkForReadingWithoutFollow() async throws {
        await XCTAssertThrowsFileSystemErrorAsync {
            try await self.fs.withFileHandle(
                forReadingAt: .testDataReadmeSymlink,
                options: OpenOptions.Read(followSymbolicLinks: false)
            ) { _ in
            }
        } onError: { error in
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    func testOpenNonExistentFileForReading() async throws {
        let path = try await self.fs.temporaryFilePath()
        await XCTAssertThrowsFileSystemErrorAsync {
            try await self.fs.withFileHandle(forReadingAt: path) { _ in }
        } onError: { error in
            XCTAssertEqual(error.code, .notFound)
        }
    }

    func testOpenFileWhereIntermediateIsNotADirectory() async throws {
        let path = FilePath(#filePath).appending("foobar")

        // For reading:
        await XCTAssertThrowsFileSystemErrorAsync {
            try await self.fs.withFileHandle(forReadingAt: path) { _ in
                XCTFail("File unexpectedly opened")
            }
        } onError: { error in
            XCTAssertEqual(error.code, .notFound)
        }

        // For writing:
        await XCTAssertThrowsFileSystemErrorAsync {
            try await self.fs.withFileHandle(forWritingAt: path) { _ in
                XCTFail("File unexpectedly opened")
            }
        } onError: { error in
            XCTAssertEqual(error.code, .notFound)
        }

        // As a directory:
        await XCTAssertThrowsFileSystemErrorAsync {
            try await self.fs.withDirectoryHandle(atPath: path) { _ in
                XCTFail("File unexpectedly opened")
            }
        } onError: { error in
            XCTAssertEqual(error.code, .notFound)
        }
    }

    func testOpenFileForWriting() async throws {
        let path = try await self.fs.temporaryFilePath()
        try await self.fs.withFileHandle(
            forWritingAt: path,
            options: .newFile(replaceExisting: false)
        ) { file in
            let info = try await file.info()
            XCTAssertEqual(info.type, .regular)
            XCTAssertEqual(info.size, 0)
        }
    }

    func testOpenNonExistentFileForWritingWithoutCreating() async throws {
        let path = try await self.fs.temporaryFilePath()
        await XCTAssertThrowsFileSystemErrorAsync {
            try await self.fs.withFileHandle(
                forWritingAt: path,
                options: .modifyFile(createIfNecessary: false)
            ) { _ in }
        } onError: { error in
            XCTAssertEqual(error.code, .notFound)
        }
    }

    func testOpenForWritingFollowingSymlink() async throws {
        let path = try await self.fs.temporaryFilePath()
        try await self.fs.withFileHandle(
            forWritingAt: path,
            options: .newFile(replaceExisting: false)
        ) { _ in }

        let link = try await self.fs.temporaryFilePath()
        try await self.fs.createSymbolicLink(at: link, withDestination: path)

        // Open via the link and write.
        try await self.fs.withFileHandle(
            forWritingAt: link,
            options: .modifyFile(createIfNecessary: false)
        ) { file in
            let info = try await file.info()
            XCTAssertEqual(info.type, .regular)

            try await file.write(contentsOf: [0, 1, 2], toAbsoluteOffset: 0)
        }

        let contents = try await ByteBuffer(
            contentsOf: path,
            maximumSizeAllowed: .bytes(1024),
            fileSystem: self.fs
        )
        XCTAssertEqual(contents, ByteBuffer(bytes: [0, 1, 2]))
    }

    func testOpenNonExistentFileForWritingWithMaterialization() async throws {
        for isAbsolute in [true, false] {
            let path = try await self.fs.temporaryFilePath(inTemporaryDirectory: isAbsolute)
            XCTAssertEqual(path.isAbsolute, isAbsolute)

            await XCTAssertThrowsErrorAsync {
                try await self.fs.withFileHandle(
                    forWritingAt: path,
                    options: .newFile(replaceExisting: false)
                ) { file in
                    // The file hasn't materialized yet, so no file at the expected path
                    // should exist.
                    let info = try await self.fs.info(forFileAt: path)
                    XCTAssertNil(info)

                    try await file.write(
                        contentsOf: repeatElement(0, count: 1024),
                        toAbsoluteOffset: 0
                    )
                    throw CancellationError()
                }
            } onError: { error in
                XCTAssert(error is CancellationError)
            }

            // Threw in the 'with' block; the file shouldn't exist anymore.
            let info = try await self.fs.info(forFileAt: path)
            XCTAssertNil(info)
        }
    }

    func testOpenExistingFileForWritingWithMaterialization() async throws {
        for isAbsolute in [true, false] {
            let path = try await self.fs.temporaryFilePath(inTemporaryDirectory: isAbsolute)
            XCTAssertEqual(path.isAbsolute, isAbsolute)

            // Avoid dirtying the current working directory.
            if path.isRelative {
                self.addTeardownBlock { [fileSystem = self.fs] in
                    try await fileSystem.removeItem(at: path)
                }
            }

            // Create a file and write some data to it.
            try await self.fs.withFileHandle(
                forWritingAt: path,
                options: .newFile(replaceExisting: false)
            ) { file in
                _ = try await file.write(contentsOf: [0, 1, 2], toAbsoluteOffset: 0)
            }

            // File must exist now.
            let info = try await self.fs.info(forFileAt: path)
            XCTAssertNotNil(info)

            // Open the existing file and truncate it. Write different bytes to it but then throw an
            // error. The changes shouldn't persist because of the error.
            await XCTAssertThrowsErrorAsync {
                try await self.fs.withFileHandle(
                    forWritingAt: path,
                    options: .newFile(replaceExisting: true)
                ) { file in
                    try await file.write(contentsOf: [3, 4, 5], toAbsoluteOffset: 0)
                    throw CancellationError()
                }
            } onError: { error in
                XCTAssert(error is CancellationError)
            }

            // Read the file again, it should contain the original bytes.
            let bytes = try await ByteBuffer(contentsOf: path, maximumSizeAllowed: .megabytes(1))
            XCTAssertEqual(bytes, ByteBuffer(bytes: [0, 1, 2]))
        }
    }

    func testOpenFileForReadingAndWriting() async throws {
        let path = try await self.fs.temporaryFilePath()
        try await self.fs.withFileHandle(
            forReadingAndWritingAt: path,
            options: .newFile(replaceExisting: false)
        ) {
            file in
            let info = try await file.info()
            XCTAssertEqual(info.type, .regular)
            XCTAssertEqual(info.size, 0)
        }
    }

    func testOpenNonExistentFileForReadingAndWritingWithoutCreating() async throws {
        let path = try await self.fs.temporaryFilePath()
        await XCTAssertThrowsFileSystemErrorAsync {
            try await self.fs.withFileHandle(
                forReadingAndWritingAt: path,
                options: .modifyFile(createIfNecessary: false)
            ) {
                _ in
            }
        } onError: { error in
            XCTAssertEqual(error.code, .notFound)
        }
    }

    func testOpenDirectory() async throws {
        try await self.fs.withDirectoryHandle(atPath: .testData) { dir in
            let info = try await dir.info()
            XCTAssertEqual(info.type, .directory)
            XCTAssertGreaterThan(info.size, 0)
        }
    }

    func testOpenNonExistentDirectory() async throws {
        let path = try await self.fs.temporaryFilePath()
        await XCTAssertThrowsFileSystemErrorAsync {
            try await self.fs.withDirectoryHandle(atPath: path) { _ in }
        } onError: { error in
            XCTAssertEqual(error.code, .notFound)
        }
    }

    func testOpenDirectoryFollowingSymlink() async throws {
        let path = try await self.fs.temporaryFilePath()
        try await self.fs.createDirectory(at: path, withIntermediateDirectories: true)

        let link = try await self.fs.temporaryFilePath()
        try await self.fs.createSymbolicLink(at: link, withDestination: path)

        try await self.fs.withDirectoryHandle(atPath: link) { dir in
            let info = try await dir.info()
            XCTAssertEqual(info.type, .directory)
        }
    }

    func testOpenNonExistentFileForWritingRelativeToDirectoryWithMaterialization() async throws {
        // (false, false) isn't supported.
        let isPathAbsolute: [(Bool, Bool)] = [(true, true), (true, false), (false, true)]

        for (isDirectoryAbsolute, isFileAbsolute) in isPathAbsolute {
            let directoryPath = try await self.fs.temporaryFilePath(
                inTemporaryDirectory: isDirectoryAbsolute
            )
            XCTAssertEqual(directoryPath.isAbsolute, isDirectoryAbsolute)

            // Avoid dirtying the current working directory.
            if directoryPath.isRelative {
                self.addTeardownBlock { [fileSystem = self.fs] in
                    try await fileSystem.removeItem(at: directoryPath)
                }
            }

            // Create the directory and open it
            try await self.fs.createDirectory(at: directoryPath, withIntermediateDirectories: true)
            try await self.fs.withDirectoryHandle(atPath: directoryPath) { directory in
                let filePath = try await self.fs.temporaryFilePath(
                    inTemporaryDirectory: isFileAbsolute
                )

                XCTAssertEqual(filePath.isAbsolute, isFileAbsolute)

                // Create the file and throw.
                await XCTAssertThrowsErrorAsync {
                    try await directory.withFileHandle(
                        forWritingAt: filePath,
                        options: .newFile(replaceExisting: false)
                    ) { handle in
                        throw CancellationError()
                    }
                } onError: { error in
                    XCTAssert(error is CancellationError)
                }

                // The file shouldn't exist.
                await XCTAssertThrowsFileSystemErrorAsync {
                    try await directory.withFileHandle(forReadingAt: filePath) { _ in }
                } onError: { error in
                    XCTAssertEqual(error.code, .notFound)
                }
            }
        }
    }

    func testOpenExistingFileForWritingRelativeToDirectoryWithMaterialization() async throws {
        // (false, false) isn't supported.
        let isPathAbsolute: [(Bool, Bool)] = [(true, true), (true, false), (false, true)]

        for (isDirectoryAbsolute, isFileAbsolute) in isPathAbsolute {
            let directoryPath = try await self.fs.temporaryFilePath(
                inTemporaryDirectory: isDirectoryAbsolute
            )

            XCTAssertEqual(directoryPath.isAbsolute, isDirectoryAbsolute)

            if directoryPath.isRelative {
                self.addTeardownBlock { [fileSystem = self.fs] in
                    try await fileSystem.removeItem(at: directoryPath, recursively: true)
                }
            }

            // Create the directory and open it
            try await self.fs.createDirectory(at: directoryPath, withIntermediateDirectories: true)
            try await self.fs.withDirectoryHandle(atPath: directoryPath) { directory in
                let filePath = try await self.fs.temporaryFilePath(
                    inTemporaryDirectory: isFileAbsolute
                )

                XCTAssertEqual(filePath.isAbsolute, isFileAbsolute)

                // Create the file and write some bytes.
                try await directory.withFileHandle(
                    forWritingAt: filePath,
                    options: .newFile(replaceExisting: false)
                ) { file in
                    _ = try await file.write(
                        contentsOf: repeatElement(0, count: 1024),
                        toAbsoluteOffset: 0
                    )
                }

                // Create the file and throw.
                await XCTAssertThrowsErrorAsync {
                    try await directory.withFileHandle(
                        forWritingAt: filePath,
                        options: .newFile(replaceExisting: true)
                    ) { handle in
                        throw CancellationError()
                    }
                } onError: { error in
                    XCTAssert(error is CancellationError)
                }

                // The file should contain the original bytes.
                try await directory.withFileHandle(forReadingAt: filePath) { file in
                    let bytes = try await file.readToEnd(maximumSizeAllowed: .megabytes(1))
                    XCTAssertEqual(bytes, ByteBuffer(repeating: 0, count: 1024))
                }
            }
        }
    }

    func testCreateDirectory() async throws {
        let path = try await self.fs.temporaryFilePath()
        try await self.fs.createDirectory(
            at: path,
            withIntermediateDirectories: false,
            permissions: nil
        )

        try await self.fs.withDirectoryHandle(atPath: path) { dir in
            let info = try await dir.info()
            XCTAssertEqual(info.type, .directory)
            XCTAssertGreaterThan(info.size, 0)
        }
    }

    func testCreateDirectoryWithIntermediatePaths() async throws {
        var path = try await self.fs.temporaryFilePath()
        for i in 0..<100 {
            path.append("\(i)")
        }

        try await self.fs.createDirectory(
            at: path,
            withIntermediateDirectories: true,
            permissions: nil
        )

        try await self.fs.withDirectoryHandle(atPath: path) { dir in
            let info = try await dir.info()
            XCTAssertEqual(info.type, .directory)
            XCTAssertGreaterThan(info.size, 0)
        }
    }

    func testCreateDirectoryAtPathWhichExists() async throws {
        let path = try await self.fs.temporaryFilePath()
        try await self.fs.withFileHandle(
            forWritingAt: path,
            options: .newFile(replaceExisting: false)
        ) { _ in }

        await XCTAssertThrowsFileSystemErrorAsync {
            try await self.fs.createDirectory(at: path, withIntermediateDirectories: true)
        } onError: { error in
            XCTAssertEqual(error.code, .fileAlreadyExists)
        }
    }

    func testCreateDirectoryAtPathWhereParentDoesNotExist() async throws {
        let parent = try await self.fs.temporaryFilePath()
        let path = parent.appending("path")

        await XCTAssertThrowsFileSystemErrorAsync {
            try await self.fs.createDirectory(at: path, withIntermediateDirectories: false)
        } onError: { error in
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    func testCurrentWorkingDirectory() async throws {
        let directory = try await self.fs.currentWorkingDirectory
        XCTAssert(!directory.isEmpty)
        XCTAssert(directory.isAbsolute)
    }

    func testTemporaryDirectory() async throws {
        let directory = try await self.fs.temporaryDirectory
        XCTAssert(!directory.isEmpty)
        XCTAssert(directory.isAbsolute)
    }

    func testInfo() async throws {
        let info = try await self.fs.info(forFileAt: .testDataReadme, infoAboutSymbolicLink: false)
        XCTAssertEqual(info?.type, .regular)
        XCTAssertGreaterThan(info?.size ?? -1, Int64(0))
    }

    func testInfoResolvingSymbolicLinks() async throws {
        let info = try await self.fs.info(
            forFileAt: .testDataReadmeSymlink,
            infoAboutSymbolicLink: false
        )
        XCTAssertEqual(info?.type, .regular)
        XCTAssertGreaterThan(info?.size ?? -1, Int64(0))
    }

    func testInfoWithoutResolvingSymbolicLinks() async throws {
        let info = try await self.fs.info(
            forFileAt: .testDataReadmeSymlink,
            infoAboutSymbolicLink: true
        )
        XCTAssertEqual(info?.type, .symlink)
        XCTAssertGreaterThan(info?.size ?? -1, Int64(0))
    }

    func testCreateSymbolicLink() async throws {
        let path = try await self.fs.temporaryFilePath()
        let destination = FilePath.testDataReadme

        try await self.fs.createSymbolicLink(at: path, withDestination: destination)
        let info = try await self.fs.info(forFileAt: destination, infoAboutSymbolicLink: true)
        let infoViaLink = try await self.fs.info(forFileAt: path, infoAboutSymbolicLink: false)
        XCTAssertEqual(info, infoViaLink)
    }

    func testDestinationOfSymbolicLink() async throws {
        do {
            // Relative symbolic link.
            let destination = try await self.fs.destinationOfSymbolicLink(
                at: .testDataReadmeSymlink
            )
            XCTAssertEqual(destination, "README.md")
        }

        do {
            // Absolute symbolic link.
            let path = try await self.fs.temporaryFilePath()
            try await self.fs.createSymbolicLink(at: path, withDestination: .testDataReadme)
            let destination = try await self.fs.destinationOfSymbolicLink(at: path)
            XCTAssertEqual(destination, .testDataReadme)
        }
    }

    func testCopySingleFile() async throws {
        let path = try await self.fs.temporaryFilePath()
        try await self.fs.copyItem(at: .testDataReadme, to: path)

        try await self.fs.withFileHandle(forReadingAt: path) { copy in
            try await self.fs.withFileHandle(forReadingAt: .testDataReadme) { original in
                let originalContents = try await original.readToEnd(
                    maximumSizeAllowed: .bytes(1024 * 1024)
                )
                let copyContents = try await copy.readToEnd(maximumSizeAllowed: .bytes(1024 * 1024))
                XCTAssertEqual(originalContents, copyContents)
            }
        }
    }

    func testCopyLargeFile() async throws {
        let sourcePath = try await self.fs.temporaryFilePath()
        let destPath = try await self.fs.temporaryFilePath()
        let sourceInfo = try await self.fs.withFileHandle(
            forWritingAt: sourcePath,
            options: .newFile(replaceExisting: false)
        ) { file in
            // On Linux we use sendfile to copy which has a limit of 2GB; write at least that much
            // to much sure we handle files above that size correctly.
            var bytesToWrite: Int64 = 3 * 1024 * 1024 * 1024
            var offset: Int64 = 0
            // Write a blob a handful of times to avoid consuming too much memory in one go.
            let blob = [UInt8](repeating: 0, count: 1024 * 1024 * 32)  // 32MB
            while bytesToWrite > 0 {
                try await file.write(contentsOf: blob, toAbsoluteOffset: offset)
                offset += Int64(blob.count)
                bytesToWrite -= Int64(blob.count)
            }

            return try await file.info()
        }

        try await self.fs.copyItem(at: sourcePath, to: destPath)
        let destInfo = try await self.fs.info(forFileAt: destPath)
        XCTAssertEqual(destInfo?.size, sourceInfo.size)
    }

    func testCopySingleFileCopiesAttributesAndPermissions() async throws {
        let original = try await self.fs.temporaryFilePath()
        let copy = try await self.fs.temporaryFilePath()

        try await self.fs.withFileHandle(
            forWritingAt: original,
            options: .newFile(replaceExisting: false, permissions: .ownerReadWrite)
        ) { file1 in
            do {
                try await file1.updateValueForAttribute([0, 1, 2, 3], attribute: "foo")
            } catch let error as FileSystemError where error.code == .unsupported {
                // Extended attributes are not always supported; swallow the error if we hit it.
            }
        }

        try await self.fs.copyItem(at: original, to: copy)

        try await self.fs.withFileHandle(forReadingAt: copy) { file2 in
            let info = try await file2.info()
            XCTAssertEqual(info.permissions, [.ownerReadWrite])

            do {
                let value = try await file2.valueForAttribute("foo")
                XCTAssertEqual(value, [0, 1, 2, 3])
            } catch let error as FileSystemError where error.code == .unsupported {
                // Extended attributes are not always supported; swallow the error if we hit it.
            }
        }
    }

    func testCopySymlink() async throws {
        let copy = try await self.fs.temporaryFilePath()
        try await self.fs.copyItem(at: .testDataReadmeSymlink, to: copy)

        let info = try await self.fs.info(forFileAt: copy, infoAboutSymbolicLink: true)
        XCTAssertEqual(info?.type, .symlink)

        let destination = try await self.fs.destinationOfSymbolicLink(at: copy)
        XCTAssertEqual(destination, "README.md")
    }

    func testCopyEmptyDirectory() async throws {
        let path = try await self.fs.temporaryFilePath()
        try await self.fs.createDirectory(at: path, withIntermediateDirectories: false)

        let copy = try await self.fs.temporaryFilePath()
        try await self.fs.copyItem(at: path, to: copy)

        try await self.checkDirectoriesMatch(path, copy)
    }

    func testCopyGeneratedTreeStructure() async throws {
        let path = try await self.fs.temporaryFilePath()
        let items = try await self.generateDirectoryStructure(
            root: path,
            maxDepth: 4,
            maxFilesPerDirectory: 10
        )

        let copy = try await self.fs.temporaryFilePath()
        do {
            try await self.fs.copyItem(at: path, to: copy)
        } catch {
            // Leave breadcrumbs to make debugging easier.
            XCTFail("Failed to copy \(items) from '\(path)' to '\(copy)'")
            throw error
        }

        do {
            try await self.checkDirectoriesMatch(path, copy)
        } catch {
            // Leave breadcrumbs to make debugging easier.
            XCTFail("Failed to validate \(items) copied from '\(path)' to '\(copy)'")
            throw error
        }
    }

    func testCopySelectively() async throws {
        let path = try await self.fs.temporaryFilePath()

        // Only generate regular files. They'll be in the format 'file-N-regular'.
        let _ = try await self.generateDirectoryStructure(
            root: path,
            maxDepth: 1,
            maxFilesPerDirectory: 10,
            directoryProbability: 0.0,
            symbolicLinkProbability: 0.0
        )

        let copyPath = try await self.fs.temporaryFilePath()
        try await self.fs.copyItem(at: path, to: copyPath) { _, error in
            throw error
        } shouldCopyFile: { source, destination in
            // Copy the directory and 'file-1-regular'
            return (source == path) || (source.lastComponent!.string == "file-0-regular")
        }

        let paths = try await self.fs.withDirectoryHandle(atPath: copyPath) { dir in
            try await dir.listContents().reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(paths.first?.name, "file-0-regular")
    }

    func testCopyNonExistentFile() async throws {
        let source = try await self.fs.temporaryFilePath()
        let destination = try await self.fs.temporaryFilePath()

        await XCTAssertThrowsFileSystemErrorAsync {
            try await self.fs.copyItem(at: source, to: destination)
        } onError: { error in
            XCTAssertEqual(error.code, .notFound)
        }
    }

    func testCopyToExistingDestination() async throws {
        let source = try await self.fs.temporaryFilePath()
        let destination = try await self.fs.temporaryFilePath()

        // Touch both files.
        for path in [source, destination] {
            try await self.fs.withFileHandle(
                forWritingAt: path,
                options: .newFile(replaceExisting: false)
            ) { _ in }
        }

        await XCTAssertThrowsFileSystemErrorAsync {
            try await self.fs.copyItem(at: source, to: destination)
        } onError: { error in
            XCTAssertEqual(error.code, .fileAlreadyExists)
        }
    }

    func testRemoveSingleFile() async throws {
        let path = try await self.fs.temporaryFilePath()
        try await self.fs.withFileHandle(
            forWritingAt: path,
            options: .newFile(replaceExisting: false)
        ) { _ in }

        let infoAfterCreation = try await self.fs.info(forFileAt: path)
        XCTAssertNotNil(infoAfterCreation)

        let removed = try await self.fs.removeItem(at: path)
        XCTAssertEqual(removed, 1)

        let infoAfterRemoval = try await self.fs.info(forFileAt: path)
        XCTAssertNil(infoAfterRemoval)
    }

    func testRemoveNonExistentFile() async throws {
        let path = try await self.fs.temporaryFilePath()
        let info = try await self.fs.info(forFileAt: path)
        XCTAssertNil(info)
        let removed = try await self.fs.removeItem(at: path)
        XCTAssertEqual(removed, 0)
    }

    func testRemoveDirectory() async throws {
        let path = try await self.fs.temporaryFilePath()
        let created = try await self.generateDirectoryStructure(
            root: path,
            maxDepth: 3,
            maxFilesPerDirectory: 10
        )

        let infoAfterCreation = try await self.fs.info(forFileAt: path)
        XCTAssertNotNil(infoAfterCreation)

        // Removing a non-empty directory recursively should throw 'notEmpty'
        await XCTAssertThrowsFileSystemErrorAsync {
            try await self.fs.removeItem(at: path, recursively: false)
        } onError: { error in
            XCTAssertEqual(error.code, .notEmpty)
        }

        let removed = try await self.fs.removeItem(at: path)
        XCTAssertEqual(created, removed)

        let infoAfterRemoval = try await self.fs.info(forFileAt: path)
        XCTAssertNil(infoAfterRemoval)
    }

    func testMoveRegularFile() async throws {
        let source = try await self.fs.temporaryFilePath()
        try await self.fs.withFileHandle(
            forWritingAt: source,
            options: .newFile(replaceExisting: false)
        ) { _ in }
        let destination = try await self.fs.temporaryFilePath()

        do {
            let sourceInfo = try await self.fs.info(forFileAt: source)
            XCTAssertNotNil(sourceInfo)
            let destinationInfo = try await self.fs.info(forFileAt: destination)
            XCTAssertNil(destinationInfo)
        }

        try await self.fs.moveItem(at: source, to: destination)

        do {
            let sourceInfo = try await self.fs.info(forFileAt: source)
            XCTAssertNil(sourceInfo)
            let destinationInfo = try await self.fs.info(forFileAt: destination)
            XCTAssertNotNil(destinationInfo)
        }
    }

    func testMoveSymbolicLink() async throws {
        let source = try await self.fs.temporaryFilePath()
        let destination = try await self.fs.temporaryFilePath()

        try await self.fs.createSymbolicLink(at: source, withDestination: .testDataReadme)

        do {
            let sourceInfo = try await self.fs.info(forFileAt: source, infoAboutSymbolicLink: true)
            XCTAssertNotNil(sourceInfo)
            XCTAssertEqual(sourceInfo?.type, .symlink)
            let destinationInfo = try await self.fs.info(forFileAt: destination)
            XCTAssertNil(destinationInfo)
        }

        try await self.fs.moveItem(at: source, to: destination)

        do {
            let sourceInfo = try await self.fs.info(forFileAt: source)
            XCTAssertNil(sourceInfo)
            let destinationInfo = try await self.fs.info(
                forFileAt: destination,
                infoAboutSymbolicLink: true
            )
            XCTAssertNotNil(destinationInfo)
            XCTAssertEqual(destinationInfo?.type, .symlink)
        }

        let linkDestination = try await self.fs.destinationOfSymbolicLink(at: destination)
        XCTAssertEqual(linkDestination, .testDataReadme)
    }

    func testMoveDirectory() async throws {
        let source = try await self.fs.temporaryFilePath()
        let destination = try await self.fs.temporaryFilePath()

        try await self.fs.createDirectory(at: source, withIntermediateDirectories: true)
        try await self.fs.withFileHandle(
            forWritingAt: source.appending("foo"),
            options: .newFile(replaceExisting: false)
        ) { _ in }

        do {
            let sourceInfo = try await self.fs.info(forFileAt: source, infoAboutSymbolicLink: false)
            XCTAssertNotNil(sourceInfo)
            XCTAssertEqual(sourceInfo?.type, .directory)
            let destinationInfo = try await self.fs.info(forFileAt: destination)
            XCTAssertNil(destinationInfo)
        }

        try await self.fs.moveItem(at: source, to: destination)

        let sourceInfo = try await self.fs.info(forFileAt: source)
        XCTAssertNil(sourceInfo)

        let items = try await self.fs.withDirectoryHandle(atPath: destination) { directory in
            try await directory.listContents().reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "foo")
    }

    func testMoveWhenSourceDoesNotExist() async throws {
        let source = try await self.fs.temporaryFilePath()
        let destination = try await self.fs.temporaryFilePath()

        await XCTAssertThrowsFileSystemErrorAsync {
            try await self.fs.moveItem(at: source, to: destination)
        } onError: { error in
            XCTAssertEqual(error.code, .notFound)
        }
    }

    func testMoveWhenDestinationAlreadyExists() async throws {
        let source = try await self.fs.temporaryFilePath()
        let destination = try await self.fs.temporaryFilePath()
        for path in [source, destination] {
            try await self.fs.withFileHandle(
                forWritingAt: path,
                options: .newFile(replaceExisting: false)
            ) { _ in }
        }

        await XCTAssertThrowsFileSystemErrorAsync {
            try await self.fs.moveItem(at: source, to: destination)
        } onError: { error in
            XCTAssertEqual(error.code, .fileAlreadyExists)
        }
    }

    func testReplaceFile(_ existingType: FileType?, with replacementType: FileType) async throws {
        func makeRegularFile(at path: FilePath) async throws {
            try await self.fs.withFileHandle(
                forWritingAt: path,
                options: .newFile(replaceExisting: false)
            ) { _ in }
        }

        func makeSymbolicLink(at path: FilePath) async throws {
            try await self.fs.createSymbolicLink(at: path, withDestination: "/whatever")
        }

        func makeDirectory(at path: FilePath) async throws {
            try await self.fs.createDirectory(at: path, withIntermediateDirectories: true)
        }

        func makeFile(ofType type: FileType, at path: FilePath) async throws {
            switch type {
            case .regular:
                try await makeRegularFile(at: path)
            case .symlink:
                try await makeSymbolicLink(at: path)
            case .directory:
                try await makeDirectory(at: path)
            default:
                XCTFail("Unexpected file type '\(type)'")
            }
        }

        let existingPath = try await self.fs.temporaryFilePath()
        let replacementPath = try await self.fs.temporaryFilePath()
        if let existingType = existingType {
            try await makeFile(ofType: existingType, at: existingPath)
        }
        try await makeFile(ofType: replacementType, at: replacementPath)

        try await self.fs.replaceItem(at: existingPath, withItemAt: replacementPath)

        let sourceInfo = try await self.fs.info(
            forFileAt: existingPath,
            infoAboutSymbolicLink: true
        )
        XCTAssertNotNil(sourceInfo)
        XCTAssertEqual(sourceInfo?.type, replacementType)

        let destinationInfo = try await self.fs.info(
            forFileAt: replacementPath,
            infoAboutSymbolicLink: true
        )
        XCTAssertNil(destinationInfo)
    }

    func testReplaceRegularFileWithRegularFile() async throws {
        try await self.testReplaceFile(.regular, with: .regular)
    }

    func testReplaceRegularFileWithSymbolicLink() async throws {
        try await self.testReplaceFile(.regular, with: .symlink)
    }

    func testReplaceRegularFileWithDirectory() async throws {
        try await self.testReplaceFile(.regular, with: .directory)
    }

    func testReplaceSymbolicLinkWithRegularFile() async throws {
        try await self.testReplaceFile(.symlink, with: .regular)
    }

    func testReplaceSymbolicLinkWithSymbolicLink() async throws {
        try await self.testReplaceFile(.symlink, with: .symlink)
    }

    func testReplaceSymbolicLinkWithDirectory() async throws {
        try await self.testReplaceFile(.symlink, with: .directory)
    }

    func testReplaceDirectoryWithRegularFile() async throws {
        try await self.testReplaceFile(.directory, with: .regular)
    }

    func testReplaceDirectoryWithSymbolicLink() async throws {
        try await self.testReplaceFile(.directory, with: .symlink)
    }

    func testReplaceDirectoryWithDirectory() async throws {
        try await self.testReplaceFile(.directory, with: .directory)
    }

    func testReplaceNothingWithRegularFile() async throws {
        try await self.testReplaceFile(.none, with: .regular)
    }

    func testReplaceNothingWithSymbolicLink() async throws {
        try await self.testReplaceFile(.none, with: .symlink)
    }

    func testReplaceNothingWithDirectory() async throws {
        try await self.testReplaceFile(.none, with: .directory)
    }

    func testReplaceWhenExistingFileDoesNotExist() async throws {
        let existing = try await self.fs.temporaryFilePath()
        let replacement = try await self.fs.temporaryFilePath()

        await XCTAssertThrowsFileSystemErrorAsync {
            try await self.fs.replaceItem(at: replacement, withItemAt: existing)
        } onError: { error in
            XCTAssertEqual(error.code, .notFound)
        }
    }

    func testWithFileSystem() async throws {
        try await withFileSystem(numberOfThreads: 1) { fs in
            let info = try await fs.info(forFileAt: .testDataReadme)
            XCTAssertEqual(info?.type, .regular)
        }
    }

    func testListContentsOfLargeDirectory() async throws {
        let path = try await self.fs.temporaryFilePath()
        try await self.fs.createDirectory(at: path, withIntermediateDirectories: true)

        try await self.fs.withDirectoryHandle(atPath: path) { handle in
            for i in 0..<1024 {
                try await self.fs.withFileHandle(
                    forWritingAt: path.appending("\(i)"),
                    options: .newFile(replaceExisting: false)
                ) { _ in }
            }

            let names = try await handle.listContents().reduce(into: []) {
                $0.append($1.name.string)
            }

            let expected = (0..<1024).map {
                String($0)
            }

            XCTAssertEqual(names.sorted(), expected.sorted())
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FileSystemTests {
    private func checkDirectoriesMatch(_ root1: FilePath, _ root2: FilePath) async throws {
        func namesAndTypes(_ root: FilePath) async throws -> [(FilePath.Component, FileType)] {
            try await self.fs.withDirectoryHandle(atPath: root) { dir in
                try await dir.listContents()
                    .reduce(into: []) { $0.append($1) }
                    .map { ($0.name, $0.type) }
                    .sorted(by: { lhs, rhs in lhs.0.string < rhs.0.string })
            }
        }

        // Check if all named entries and types match.
        let root1Entries = try await namesAndTypes(root1)
        let root2Entries = try await namesAndTypes(root2)
        XCTAssertEqual(root1Entries.map { $0.0 }, root2Entries.map { $0.0 })
        XCTAssertEqual(root1Entries.map { $0.1 }, root2Entries.map { $0.1 })

        // Now look at regular files: are they all the same?
        for (path, type) in root1Entries where type == .regular {
            try await self.checkRegularFilesMatch(root1.appending(path), root2.appending(path))
        }

        // Are symbolic links all the same?
        for (path, type) in root1Entries where type == .symlink {
            try await self.checkSymbolicLinksMatch(root1.appending(path), root2.appending(path))
        }

        // Finally, check directories.
        for (path, type) in root1Entries where type == .directory {
            try await self.checkDirectoriesMatch(root1.appending(path), root2.appending(path))
        }
    }

    private func checkRegularFilesMatch(_ path1: FilePath, _ path2: FilePath) async throws {
        try await self.fs.withFileHandle(forReadingAt: path1) { file1 in
            try await self.fs.withFileHandle(forReadingAt: path2) { file2 in
                let info1 = try await file1.info()
                let info2 = try await file2.info()
                XCTAssertEqual(info1.type, info2.type)
                XCTAssertEqual(info1.size, info2.size)
                XCTAssertEqual(info1.permissions, info2.permissions)

                let file1Contents = try await file1.readToEnd(
                    maximumSizeAllowed: .bytes(1024 * 1024)
                )
                let file2Contents = try await file2.readToEnd(
                    maximumSizeAllowed: .bytes(1024 * 1024)
                )
                XCTAssertEqual(file1Contents, file2Contents)

                do {
                    let file1Attributes = try await file1.attributeNames().sorted()
                    let file2Attributes = try await file2.attributeNames().sorted()
                    XCTAssertEqual(file1Attributes, file2Attributes)

                    for attribute in file1Attributes {
                        let value1 = try await file1.valueForAttribute(attribute)
                        let value2 = try await file2.valueForAttribute(attribute)
                        XCTAssertEqual(value1, value2)
                    }
                } catch let error as FileSystemError where error.code == .unsupported {
                    // Extended attributes aren't supported on all platforms, so swallow any
                    // unavailable errors.
                }
            }
        }
    }

    private func checkSymbolicLinksMatch(_ path1: FilePath, _ path2: FilePath) async throws {
        let destination1 = try await self.fs.destinationOfSymbolicLink(at: path1)
        let destination2 = try await self.fs.destinationOfSymbolicLink(at: path2)
        XCTAssertEqual(destination1, destination2)
    }

    private func generateDirectoryStructure(
        root: FilePath,
        maxDepth: Int,
        maxFilesPerDirectory: Int,
        directoryProbability: Double = 0.3,
        symbolicLinkProbability: Double = 0.2
    ) async throws -> Int {
        guard maxDepth > 0 else { return 0 }

        func makeDirectory() -> Bool {
            Double.random(in: 0..<1.0) <= directoryProbability
        }

        func makeSymbolicLink() -> Bool {
            Double.random(in: 0..<1.0) <= symbolicLinkProbability
        }

        try await self.fs.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            permissions: nil
        )

        let itemsInThisDir = Int.random(in: 1...maxFilesPerDirectory)
        var itemsCreated = 1

        guard itemsInThisDir > 0 else {
            return itemsCreated
        }

        let dirsToMake = try await self.fs.withDirectoryHandle(atPath: root) { dir in
            var directoriesToMake = [FilePath]()

            for i in 0..<itemsInThisDir {
                if makeDirectory() {
                    directoriesToMake.append(root.appending("file-\(i)-directory"))
                } else if makeSymbolicLink() {
                    let path = "file-\(i)-symlink"
                    try await self.fs.createSymbolicLink(
                        at: root.appending(path),
                        withDestination: "nonexistent-destination"
                    )
                    itemsCreated += 1
                } else {
                    let path = root.appending("file-\(i)-regular")
                    try await self.fs.withFileHandle(
                        forWritingAt: path,
                        options: .newFile(replaceExisting: false)
                    ) { file in
                        if Bool.random() {
                            let byteCount = (32...128).randomElement()!
                            do {
                                try await file.updateValueForAttribute(
                                    Array(repeating: 0, count: byteCount),
                                    attribute: "attribute-\(i)"
                                )
                            } catch let error as FileSystemError where error.code == .unsupported {
                                // Extended attributes are not supported on all platforms. Ignore
                                // errors if that's the case.
                                ()
                            }
                        }

                        let byteCount = (512...1024).randomElement()!
                        try await file.write(
                            contentsOf: Array(repeating: 0, count: byteCount),
                            toAbsoluteOffset: 0
                        )
                    }
                    itemsCreated += 1
                }
            }

            return directoriesToMake
        }

        for path in dirsToMake {
            itemsCreated += try await self.generateDirectoryStructure(
                root: path,
                maxDepth: maxDepth - 1,
                maxFilesPerDirectory: maxFilesPerDirectory,
                directoryProbability: directoryProbability,
                symbolicLinkProbability: symbolicLinkProbability
            )
        }

        return itemsCreated
    }

    func testCreateTemporaryDirectory() async throws {
        let validTemporaryDirectoryTemplates = [
            "ValidTemporaryDirectoryXXX", "ValidTemporaryDirectoryXXXX",
            "ValidTemporaryDirectoryXXXXX", "ValidTemporaryDirectoryXXXXXX",
            "XXXXX", "fooXbarXXXX", "foo.barXXXX",
        ]

        for templateString in validTemporaryDirectoryTemplates {
            let template = FilePath(templateString)

            // A random ending consisting only of 'X's could be generated, making the template
            // equal to the generated file path, but the probability of this happening three
            // times in a row is very low.
            var temporaryDirectoryPath: FilePath?

            attempt: for _ in 1...3 {
                do {
                    temporaryDirectoryPath = try await self.fs.createTemporaryDirectory(
                        template: template
                    )
                    break attempt
                } catch let error as FileSystemError where error.code == .fileAlreadyExists {
                    // Try again.
                    continue
                } catch {
                    XCTFail("Unexpected error creating temporary file")
                    return
                }
            }

            guard let temporaryDirectoryPath = temporaryDirectoryPath else {
                return XCTFail("Ran out of attempts to create a unique temporary directory")
            }

            // Clean up after ourselves.
            self.addTeardownBlock { [fileSystem = self.fs] in
                try await fileSystem.removeItem(at: temporaryDirectoryPath)
            }

            guard let info = try await self.fs.info(forFileAt: temporaryDirectoryPath) else {
                return XCTFail("The temporary directory could not be accessed.")
            }

            XCTAssertEqual(info.type, .directory)
            XCTAssertGreaterThan(info.size, 0)
        }
    }

    func testCreateTemporaryDirectoryInvalidTemplate() async throws {
        let invalidTemporaryDirectoryTemplates = [
            "", "InalidTemporaryDirectory", "InvalidTemporaryDirectoryX",
            "InvalidTemporaryDirectoryXX", "Invalidxxx", "InvalidXxX",
        ]
        for templateString in invalidTemporaryDirectoryTemplates {
            let template = FilePath(templateString)
            await XCTAssertThrowsFileSystemErrorAsync {
                try await self.fs.createTemporaryDirectory(template: template)
            } onError: { error in
                XCTAssertEqual(error.code, .invalidArgument)
            }
        }
    }

    func testCreateTemporaryDirectoryWithIntermediatePaths() async throws {
        let templateString = "\(#function)"
        let templateRoot = FilePath(templateString)
        var template = templateRoot
        for i in 0..<10 {
            template.append("\(i)")
        }
        template.append("pattern-XXXXXX")
        let temporaryDirectoryPath = try await self.fs.createTemporaryDirectory(template: template)

        self.addTeardownBlock { [fileSystem = self.fs] in
            try await fileSystem.removeItem(at: templateRoot, recursively: true)
        }

        guard
            let info = try await self.fs.info(
                forFileAt: temporaryDirectoryPath,
                infoAboutSymbolicLink: false
            )
        else {
            XCTFail("The temporary directory could not be accessed.")
            return
        }
        XCTAssertEqual(info.type, .directory)
        XCTAssertGreaterThan(info.size, 0)
    }

    func testReadChunksRange() async throws {
        try await self.fs.withFileHandle(forReadingAt: FilePath(#filePath)) { handle in
            let info = try await handle.info()
            let size = info.size
            let endIndex = size + 1

            let ranges: [(Range<Int64>, Int)] = [
                (0..<0, 0),
                (0..<1, 1),
                (0..<endIndex, Int(size)),
                (1..<endIndex, Int(size - 1)),
                (0..<endIndex + 1, Int(size)),
                (1..<endIndex + 1, Int(size - 1)),
                (0..<Int64.max, Int(size)),
            ]

            for (range, expected) in ranges {
                let byteCount = try await handle.readChunks(in: range).reduce(into: 0) {
                    $0 += $1.readableBytes
                }

                XCTAssertEqual(byteCount, expected)
            }
        }
    }

    func testReadChunksClosedRange() async throws {
        try await self.fs.withFileHandle(forReadingAt: FilePath(#filePath)) { handle in
            let info = try await handle.info()
            let size = info.size
            let endIndex = size + 1

            let ranges: [(ClosedRange<Int64>, Int)] = [
                (0...0, 1),
                (0...1, 2),
                // Clamped to file size.
                (0...endIndex, Int(info.size)),
                (0...(endIndex - 1), Int(info.size)),
                // Short one byte.
                (1...(endIndex - 1), Int(info.size - 1)),
                (1...endIndex, Int(info.size - 1)),
                (0...(Int64.max - 1), Int(size)),
            ]

            for (range, expected) in ranges {
                let byteCount = try await handle.readChunks(in: range).reduce(into: 0) {
                    $0 += $1.readableBytes
                }
                XCTAssertEqual(byteCount, expected)
            }
        }
    }

    func testReadChunksPartialRangeUpTo() async throws {
        try await self.fs.withFileHandle(forReadingAt: FilePath(#filePath)) { handle in
            let info = try await handle.info()
            let size = info.size
            let endIndex = size + 1

            let ranges: [(PartialRangeUpTo<Int64>, Int)] = [
                (..<0, 0),
                (..<1, 1),
                // Clamped to file size.
                (..<endIndex, Int(info.size)),
                // Exactly the file size.
                (..<(endIndex - 1), Int(info.size)),
                // One byte short.
                (..<(endIndex - 2), Int(info.size - 1)),
                (..<Int64.max, Int(size)),
            ]

            for (range, expected) in ranges {
                let byteCount = try await handle.readChunks(in: range).reduce(into: 0) {
                    $0 += $1.readableBytes
                }

                XCTAssertEqual(byteCount, expected)
            }
        }
    }

    func testReadChunksPartialRangeThrough() async throws {
        try await self.fs.withFileHandle(forReadingAt: FilePath(#filePath)) { handle in
            let info = try await handle.info()
            let size = info.size
            let endIndex = size + 1

            let ranges: [(PartialRangeThrough<Int64>, Int)] = [
                (...0, 1),
                (...1, 2),
                // Clamped to size.
                (...endIndex, Int(info.size)),
                (...(endIndex - 1), Int(info.size)),
                // Exact size.
                (...(endIndex - 2), Int(info.size)),
                // One byte short
                (...(endIndex - 3), Int(info.size - 1)),
                (...(Int64.max - 1), Int(size)),
            ]

            for (range, expected) in ranges {
                let byteCount = try await handle.readChunks(in: range).reduce(into: 0) {
                    $0 += $1.readableBytes
                }

                XCTAssertEqual(byteCount, expected)
            }
        }
    }

    func testReadChunksPartialRangeFrom() async throws {
        try await self.fs.withFileHandle(forReadingAt: FilePath(#filePath)) { handle in
            let info = try await handle.info()
            let size = info.size
            let endIndex = size + 1

            let ranges: [(PartialRangeFrom<Int64>, Int)] = [
                (0..., Int(size)),
                (1..., Int(size - 1)),
                (endIndex..., 0),
                ((endIndex - 1)..., 0),
                ((endIndex - 2)..., 1),
            ]

            for (range, expected) in ranges {
                let byteCount = try await handle.readChunks(in: range).reduce(into: 0) {
                    $0 += $1.readableBytes
                }

                XCTAssertEqual(byteCount, expected, "\(range)")
            }
        }
    }

    func testReadChunksUnboundedRange() async throws {
        try await self.fs.withFileHandle(forReadingAt: FilePath(#filePath)) { handle in
            let info = try await handle.info()
            let size = info.size

            let byteCount = try await handle.readChunks(in: ...).reduce(into: 0) {
                $0 += $1.readableBytes
            }

            XCTAssertEqual(byteCount, Int(size))
        }
    }
}
#endif
