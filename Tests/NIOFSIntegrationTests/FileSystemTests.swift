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

import NIOConcurrencyHelpers
import NIOCore
@_spi(Testing) @testable import NIOFS
import SystemPackage
import XCTest

extension NIOFilePath {
    static let testData = NIOFilePath(
        FilePath(#filePath)
            .removingLastComponent()  // FileHandleTests.swift
            .appending("Test Data")
            .lexicallyNormalized()
    )

    static let testDataReadme = NIOFilePath(Self.testData.underlying.appending("README.md"))
    static let testDataReadmeSymlink = NIOFilePath(Self.testData.underlying.appending("README.md.symlink"))
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FileSystem {
    func temporaryFilePath(
        _ function: String = #function,
        inTemporaryDirectory: Bool = true
    ) async throws -> NIOFilePath {
        if inTemporaryDirectory {
            let directory = (try await self.temporaryDirectory).underlying
            return self.temporaryFilePath(function, inDirectory: directory)
        } else {
            return self.temporaryFilePath(function, inDirectory: nil)
        }
    }

    func temporaryFilePath(
        _ function: String = #function,
        inDirectory directory: FilePath?
    ) -> NIOFilePath {
        let index = function.firstIndex(of: "(")!
        let functionName = function.prefix(upTo: index)
        let random = UInt32.random(in: .min ... .max)
        let fileName = "\(functionName)-\(random)"

        if let directory = directory {
            return NIOFilePath(directory.appending(fileName))
        } else {
            return NIOFilePath(fileName)
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class FileSystemTests: XCTestCase {
    var fs: FileSystem { .shared }

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
        let path = NIOFilePath(FilePath(#filePath).appending("foobar"))

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
            XCTAssertEqual(path.underlying.isAbsolute, isAbsolute)

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
            XCTAssertEqual(path.underlying.isAbsolute, isAbsolute)

            // Avoid dirtying the current working directory.
            if path.underlying.isRelative {
                self.addTeardownBlock { [fileSystem = self.fs] in
                    try await fileSystem.removeItem(at: path, strategy: .platformDefault)
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

    func testDetachUnsafeDescriptorForFileOpenedWithMaterialization() async throws {
        let path = try await self.fs.temporaryFilePath()
        let descriptor = try await self.fs.withFileHandle(forWritingAt: path) { handle in
            _ = try await handle.withBufferedWriter { writer in
                try await writer.write(contentsOf: repeatElement(0, count: 1024))
            }

            return try handle.detachUnsafeFileDescriptor()
        }

        try descriptor.writeAll(toAbsoluteOffset: 1024, repeatElement(1, count: 1024))

        var buffer = try await ByteBuffer(
            contentsOf: path,
            maximumSizeAllowed: .mebibytes(2),
            fileSystem: self.fs
        )

        XCTAssertEqual(buffer.readBytes(length: 1024), Array(repeating: 0, count: 1024))
        XCTAssertEqual(buffer.readBytes(length: 1024), Array(repeating: 1, count: 1024))
        XCTAssertEqual(buffer.readableBytes, 0)
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
            XCTAssertEqual(directoryPath.underlying.isAbsolute, isDirectoryAbsolute)

            // Avoid dirtying the current working directory.
            if directoryPath.underlying.isRelative {
                self.addTeardownBlock { [fileSystem = self.fs] in
                    try await fileSystem.removeItem(at: directoryPath, strategy: .platformDefault)
                }
            }

            // Create the directory and open it
            try await self.fs.createDirectory(at: directoryPath, withIntermediateDirectories: true)
            try await self.fs.withDirectoryHandle(atPath: directoryPath) { directory in
                let filePath = try await self.fs.temporaryFilePath(
                    inTemporaryDirectory: isFileAbsolute
                )

                XCTAssertEqual(filePath.underlying.isAbsolute, isFileAbsolute)

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

            XCTAssertEqual(directoryPath.underlying.isAbsolute, isDirectoryAbsolute)

            if directoryPath.underlying.isRelative {
                self.addTeardownBlock { [fileSystem = self.fs] in
                    try await fileSystem.removeItem(at: directoryPath, strategy: .platformDefault, recursively: true)
                }
            }

            // Create the directory and open it
            try await self.fs.createDirectory(at: directoryPath, withIntermediateDirectories: true)
            try await self.fs.withDirectoryHandle(atPath: directoryPath) { directory in
                let filePath = try await self.fs.temporaryFilePath(
                    inTemporaryDirectory: isFileAbsolute
                )

                XCTAssertEqual(filePath.underlying.isAbsolute, isFileAbsolute)

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
        var path = try await self.fs.temporaryFilePath().underlying
        for i in 0..<100 {
            path.append("\(i)")
        }

        try await self.fs.createDirectory(
            at: NIOFilePath(path),
            withIntermediateDirectories: true,
            permissions: nil
        )

        try await self.fs.withDirectoryHandle(atPath: NIOFilePath(path)) { dir in
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
        let parent = try await self.fs.temporaryFilePath().underlying
        let path = NIOFilePath(parent.appending("path"))

        await XCTAssertThrowsFileSystemErrorAsync {
            try await self.fs.createDirectory(at: path, withIntermediateDirectories: false)
        } onError: { error in
            XCTAssertEqual(error.code, .invalidArgument)
        }
    }

    func testCreateDirectoryIsIdempotentWhenAlreadyExists() async throws {
        let path = try await self.fs.temporaryFilePath()

        try await self.fs.createDirectory(at: path, withIntermediateDirectories: false)

        try await self.fs.createDirectory(at: path, withIntermediateDirectories: false)
        try await self.fs.createDirectory(at: path, withIntermediateDirectories: true)

        try await self.fs.withDirectoryHandle(atPath: path) { dir in
            let info = try await dir.info()
            XCTAssertEqual(info.type, .directory)
            XCTAssertGreaterThan(info.size, 0)
        }
    }

    func testCreateDirectoryThroughSymlinkToExistingDirectoryIsIdempotent() async throws {
        let realDir = try await self.fs.temporaryFilePath()
        try await self.fs.createDirectory(at: realDir, withIntermediateDirectories: false)

        let linkPath = try await self.fs.temporaryFilePath()
        try await self.fs.createSymbolicLink(at: linkPath, withDestination: realDir)

        try await self.fs.createDirectory(at: linkPath, withIntermediateDirectories: false)

        try await self.fs.withDirectoryHandle(atPath: linkPath) { dir in
            let info = try await dir.info()
            XCTAssertEqual(info.type, .directory)
            XCTAssertGreaterThan(info.size, 0)
        }
    }

    func testCurrentWorkingDirectory() async throws {
        let directory = try await self.fs.currentWorkingDirectory
        XCTAssert(!directory.underlying.isEmpty)
        XCTAssert(directory.underlying.isAbsolute)
    }

    func testTemporaryDirectory() async throws {
        let directory = try await self.fs.temporaryDirectory
        XCTAssert(!directory.underlying.isEmpty)
        XCTAssert(directory.underlying.isAbsolute)
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
        let destination = NIOFilePath.testDataReadme

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
        self.addTeardownBlock { [fs] in
            _ = try? await fs.removeItem(at: sourcePath, strategy: .platformDefault)
            _ = try? await fs.removeItem(at: destPath, strategy: .platformDefault)
        }

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

    /// This is is not quite the same as sequential, different code paths are used.
    /// Tests using this ensure use of the parallel paths (which are more complex) while keeping actual
    /// parallelism to minimal levels to make debugging simpler.
    private static let minimalParallel: CopyStrategy = try! .parallel(maxDescriptors: 2)

    func testCopyEmptyDirectorySequential() async throws {
        try await testCopyEmptyDirectory(.sequential)
    }

    func testCopyEmptyDirectoryParallelMinimal() async throws {
        try await testCopyEmptyDirectory(Self.minimalParallel)
    }

    func testCopyEmptyDirectoryParallelDefault() async throws {
        try await testCopyEmptyDirectory(.platformDefault)
    }

    private func testCopyEmptyDirectory(
        _ copyStrategy: CopyStrategy
    ) async throws {
        let path = try await self.fs.temporaryFilePath()
        try await self.fs.createDirectory(at: path, withIntermediateDirectories: false)

        let copy = try await self.fs.temporaryFilePath()
        try await self.fs.copyItem(at: path, to: copy, strategy: copyStrategy)

        try await self.checkDirectoriesMatch(path, copy)
    }

    func testCopyDirectoryToExistingDestinationSequential() async throws {
        try await self.testCopyDirectoryToExistingDestination(.sequential)
    }

    func testCopyDirectoryToExistingDestinationParallelMinimal() async throws {
        try await self.testCopyDirectoryToExistingDestination(Self.minimalParallel)
    }

    func testCopyDirectoryToExistingDestinationParallelDefault() async throws {
        try await self.testCopyDirectoryToExistingDestination(.platformDefault)
    }

    private func testCopyDirectoryToExistingDestination(
        _ strategy: CopyStrategy
    ) async throws {
        let path1 = try await self.fs.temporaryFilePath()
        let path2 = try await self.fs.temporaryFilePath()
        try await self.fs.createDirectory(at: path1, withIntermediateDirectories: false)
        try await self.fs.createDirectory(at: path2, withIntermediateDirectories: false)

        await XCTAssertThrowsErrorAsync {
            try await self.fs.copyItem(at: path1, to: path2, strategy: strategy)
        }
    }

    func testCopyOnGeneratedTreeStructureSequential() async throws {
        try await testAnyCopyStrategyOnGeneratedTreeStructure(.sequential)
    }

    func testCopyOnGeneratedTreeStructureParallelMinimal() async throws {
        try await testAnyCopyStrategyOnGeneratedTreeStructure(Self.minimalParallel)
    }

    func testCopyOnGeneratedTreeStructureParallelDefault() async throws {
        try await testAnyCopyStrategyOnGeneratedTreeStructure(.platformDefault)
    }

    private func testAnyCopyStrategyOnGeneratedTreeStructure(
        _ copyStrategy: CopyStrategy,
        line: UInt = #line
    ) async throws {
        let path = try await self.fs.temporaryFilePath()
        let items = try await self.generateDirectoryStructure(
            root: path,
            maxDepth: 4,
            maxFilesPerDirectory: 10
        )

        let copy = try await self.fs.temporaryFilePath()
        do {
            try await self.fs.copyItem(at: path, to: copy, strategy: copyStrategy)
        } catch {
            // Leave breadcrumbs to make debugging easier.
            XCTFail(
                "Using \(copyStrategy) failed to copy \(items) from '\(path)' to '\(copy)'",
                line: line
            )
            throw error
        }

        do {
            try await self.checkDirectoriesMatch(path, copy)
        } catch {
            // Leave breadcrumbs to make debugging easier.
            XCTFail(
                "Using \(copyStrategy) failed to validate \(items) copied from '\(path)' to '\(copy)'",
                line: line
            )
            throw error
        }
    }

    func testCopySelectivelySequential() async throws {
        try await testCopySelectively(.sequential)
    }

    func testCopySelectivelyParallelMinimal() async throws {
        try await testCopySelectively(Self.minimalParallel)
    }

    func testCopySelectivelyParallelDefault() async throws {
        try await testCopySelectively(.platformDefault)
    }

    private func testCopySelectively(
        _ copyStrategy: CopyStrategy,
        line: UInt = #line
    ) async throws {
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
        try await self.fs.copyItem(at: path, to: copyPath, strategy: copyStrategy) { _, error in
            throw error
        } shouldCopyItem: { source, destination in
            // Copy the directory and 'file-1-regular'
            (source.path == path) || (source.path.underlying.lastComponent!.string == "file-0-regular")
        }

        let paths = try await self.fs.withDirectoryHandle(atPath: copyPath) { dir in
            try await dir.listContents().reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(paths.first?.name, "file-0-regular")
    }

    func testCopyCancelledPartWayThroughSequential() async throws {
        try await testCopyCancelledPartWayThrough(.sequential)
    }

    func testCopyCancelledPartWayThroughParallelMinimal() async throws {
        try await testCopyCancelledPartWayThrough(Self.minimalParallel)
    }

    func testCopyCancelledPartWayThroughParallelDefault() async throws {
        try await testCopyCancelledPartWayThrough(.platformDefault)
    }

    private func testCopyCancelledPartWayThrough(
        _ copyStrategy: CopyStrategy,
        line: UInt = #line
    ) async throws {
        // Whitebox testing to cover specific scenarios
        switch copyStrategy.wrapped {
        case let .parallel(maxDescriptors):
            // The use of nested directories here allows us to rely on deterministic ordering
            // of the shouldCopy calls that are used to trigger the cancel. If we used files then directory
            // listing is not deterministic in general and that could make tests unreliable.
            // If maxDescriptors gets too high the resulting recursion might result in the test failing.
            // At that stage the tests would need some rework, but it's not viewed as likely given that
            // the maxDescriptors defaults should remain small.

            // Each dir consumes two descriptors, so this source can cover all scenarios.
            let depth = maxDescriptors + 1
            let path = try await self.fs.temporaryFilePath()
            try await self.generateDeterministicDirectoryStructure(
                root: path,
                structure: TestFileStructure.makeNestedDirs(depth) {
                    .init("dir-\(depth - $0)")!
                }
            )

            // This covers cancelling before/at the point we reach the limit.
            // If the maxDescriptors is sufficiently low we simply can't trigger
            // inside that phase so don't try.
            if maxDescriptors >= 4 {
                try await testCopyCancelledPartWayThrough(copyStrategy, "early_complete", path) {
                    $0.name == "dir-0"
                }
            }

            // This covers completing after we reach the steady state phase.
            let triggerAt = "dir-\(maxDescriptors / 2 + 1)"
            try await testCopyCancelledPartWayThrough(copyStrategy, "late_complete", path) {
                $0.name == triggerAt
            }
        case .sequential:
            // nothing much to whitebox test here
            break
        }
        // Keep doing random ones as a sort of fuzzing, it previously highlighted some interesting cases
        // that are now covered in the whitebox tests above
        let randomPath = try await self.fs.temporaryFilePath()
        let _ = try await self.generateDirectoryStructure(
            root: randomPath,
            // Ensure:
            // - Parallelism is possible in directory scans.
            // - There are sub directories underneath the point we trigger cancel
            maxDepth: 4,
            maxFilesPerDirectory: 10,
            directoryProbability: 1.0,
            symbolicLinkProbability: 0.0
        )
        try await testCopyCancelledPartWayThrough(
            copyStrategy,
            "randomly generated",
            randomPath
        ) { source in
            source.path != randomPath && NIOFilePath(source.path.underlying.removingLastComponent()) != randomPath
        }
    }

    private func testCopyCancelledPartWayThrough(
        _ copyStrategy: CopyStrategy,
        _ description: String,
        _ path: NIOFilePath,
        triggerCancel: @escaping @Sendable (DirectoryEntry) -> Bool,
        line: UInt = #line
    ) async throws {

        let copyPath = try await self.fs.temporaryFilePath()

        let requestedCancel = NIOLockedValueBox<Bool>(false)
        let cancelRequested = expectation(description: "cancel requested")

        let task = Task { [fs] in
            try await fs.copyItem(at: path, to: copyPath, strategy: copyStrategy) { _, error in
                throw error
            } shouldCopyItem: { source, destination in
                // Abuse shouldCopy to trigger the cancellation after getting some way in.
                if triggerCancel(source) {
                    let shouldSleep = requestedCancel.withLockedValue { requested in
                        if !requested {
                            requested = true
                            cancelRequested.fulfill()
                            return true
                        }

                        return requested
                    }
                    // Give the cancellation time to kick in, this should be more than plenty.
                    if shouldSleep {
                        do {
                            try await Task.sleep(nanoseconds: 3_000_000_000)
                            XCTFail("\(description) Should have been cancelled by now!")
                        } catch is CancellationError {
                            // This is fine - we got cancelled as desired, let the rest of the in flight
                            // logic wind down cleanly (we hope/assert)
                        } catch let error {
                            XCTFail("\(description) just expected a cancellation error not \(error)")
                        }
                    }
                }
                return true
            }

            return "completed the copy"
        }

        // Timeout notes: locally this should be fine as a second but on a loaded
        // CI instance this test can be flaky at that level.
        // Since testing cancellation is deemed highly desirable this is retained at
        // quite relaxed thresholds.
        // If this threshold remains insufficient for stable use then this test is likely
        // not tenable to run in CI
        await fulfillment(of: [cancelRequested], timeout: 5)
        task.cancel()
        let result = await task.result
        switch result {
        case let .success(msg):
            XCTFail("\(description) expected the cancellation to have happened : \(msg)")

        case let .failure(err):
            if err is CancellationError {
                // success
            } else {
                XCTFail("\(description) expected CancellationError not \(err)")
            }
        }
        // We can't assert anything about the state of the copy,
        // it might happen to all finish in time depending on scheduling.
    }

    func testCopyNonExistentFileSequential() async throws {
        try await testCopyNonExistentFile(.sequential)
    }

    func testCopyNonExistentFileParallelMinimal() async throws {
        try await testCopyNonExistentFile(Self.minimalParallel)
    }

    func testCopyNonExistentFileParallelDefault() async throws {
        try await testCopyNonExistentFile(.platformDefault)
    }

    private func testCopyNonExistentFile(
        _ copyStrategy: CopyStrategy,
        line: UInt = #line
    ) async throws {
        let source = try await self.fs.temporaryFilePath()
        let destination = try await self.fs.temporaryFilePath()

        await XCTAssertThrowsFileSystemErrorAsync {
            try await self.fs.copyItem(at: source, to: destination, strategy: copyStrategy)
        } onError: { error in
            XCTAssertEqual(error.code, .notFound)
        }
    }

    func testCopyToExistingDestinationSequential() async throws {
        try await testCopyToExistingDestination(.sequential)
    }

    func testCopyToExistingDestinationParallelMinimal() async throws {
        try await testCopyToExistingDestination(Self.minimalParallel)
    }

    func testCopyToExistingDestinationParallelDefault() async throws {
        try await testCopyToExistingDestination(.platformDefault)
    }

    private func testCopyToExistingDestination(
        _ copyStrategy: CopyStrategy,
        line: UInt = #line
    ) async throws {
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
            try await self.fs.copyItem(at: source, to: destination, strategy: copyStrategy)
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

        let removed = try await self.fs.removeItem(at: path, strategy: .platformDefault)
        XCTAssertEqual(removed, 1)

        let infoAfterRemoval = try await self.fs.info(forFileAt: path)
        XCTAssertNil(infoAfterRemoval)
    }

    func testRemoveNonExistentFile() async throws {
        let path = try await self.fs.temporaryFilePath()
        let info = try await self.fs.info(forFileAt: path)
        XCTAssertNil(info)
        let removed = try await self.fs.removeItem(at: path, strategy: .platformDefault)
        XCTAssertEqual(removed, 0)
    }

    func testRemoveDirectorySequentially() async throws {
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
            try await self.fs.removeItem(at: path, strategy: .sequential, recursively: false)
        } onError: { error in
            XCTAssertEqual(error.code, .notEmpty)
        }

        let removed = try await self.fs.removeItem(at: path, strategy: .sequential)
        XCTAssertEqual(created, removed)

        let infoAfterRemoval = try await self.fs.info(forFileAt: path)
        XCTAssertNil(infoAfterRemoval)
    }

    func testRemoveDirectoryConcurrently() async throws {
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
            try await self.fs.removeItem(at: path, strategy: .parallel(maxDescriptors: 2), recursively: false)
        } onError: { error in
            XCTAssertEqual(error.code, .notEmpty)
        }

        let removed = try await self.fs.removeItem(at: path, strategy: .parallel(maxDescriptors: 2))
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
            forWritingAt: NIOFilePath(source.underlying.appending("foo")),
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
        func makeRegularFile(at path: NIOFilePath) async throws {
            try await self.fs.withFileHandle(
                forWritingAt: path,
                options: .newFile(replaceExisting: false)
            ) { _ in }
        }

        func makeSymbolicLink(at path: NIOFilePath) async throws {
            try await self.fs.createSymbolicLink(at: path, withDestination: "/whatever")
        }

        func makeDirectory(at path: NIOFilePath) async throws {
            try await self.fs.createDirectory(at: path, withIntermediateDirectories: true)
        }

        func makeFile(ofType type: FileType, at path: NIOFilePath) async throws {
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
                    forWritingAt: NIOFilePath(path.underlying.appending("\(i)")),
                    options: .newFile(replaceExisting: false)
                ) { _ in }
            }

            let names = try await handle.listContents().reduce(into: []) {
                $0.append($1.name)
            }

            let expected = (0..<1024).map {
                String($0)
            }

            XCTAssertEqual(names.sorted(), expected.sorted())
        }
    }

    func testWithTemporaryDirectory() async throws {
        let fs = FileSystem.shared

        let createdPath = try await fs.withTemporaryDirectory { directory, path in
            let root = try await fs.temporaryDirectory
            XCTAssert(path.underlying.starts(with: root.underlying))
            return path
        }

        // Directory shouldn't exist any more.
        let info = try await fs.info(forFileAt: createdPath)
        XCTAssertNil(info)
    }

    func testWithTemporaryDirectoryPrefix() async throws {
        let fs = FileSystem.shared
        let prefix = try await fs.currentWorkingDirectory

        let createdPath = try await fs.withTemporaryDirectory(prefix: prefix) { directory, path in
            XCTAssert(path.underlying.starts(with: prefix.underlying))
            return path
        }

        // Directory shouldn't exist any more.
        let info = try await fs.info(forFileAt: createdPath)
        XCTAssertNil(info)
    }

    func testWithTemporaryDirectoryRemovesContents() async throws {
        let fs = FileSystem.shared
        let createdPath = try await fs.withTemporaryDirectory { directory, path in
            for name in ["foo", "bar", "baz"] {
                try await directory.withFileHandle(forWritingAt: NIOFilePath(name)) { fh in
                    _ = try await fh.write(contentsOf: [1, 2, 3], toAbsoluteOffset: 0)
                }
            }

            let entries = try await directory.listContents().reduce(into: []) { $0.append($1) }
            let names = entries.map { $0.name }
            XCTAssertEqual(names.sorted(), ["bar", "baz", "foo"])

            return path
        }

        // Directory shouldn't exist any more.
        let info = try await fs.info(forFileAt: createdPath)
        XCTAssertNil(info)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FileSystemTests {
    private func checkDirectoriesMatch(_ root1: NIOFilePath, _ root2: NIOFilePath) async throws {
        func namesAndTypes(_ root: NIOFilePath) async throws -> [(String, FileType)] {
            try await self.fs.withDirectoryHandle(atPath: root) { dir in
                try await dir.listContents()
                    .reduce(into: []) { $0.append($1) }
                    .map { ($0.name, $0.type) }
                    .sorted(by: { lhs, rhs in lhs.0 < rhs.0 })
            }
        }

        // Check if all named entries and types match.
        let root1Entries = try await namesAndTypes(root1)
        let root2Entries = try await namesAndTypes(root2)
        XCTAssertEqual(root1Entries.map { $0.0 }, root2Entries.map { $0.0 })
        XCTAssertEqual(root1Entries.map { $0.1 }, root2Entries.map { $0.1 })

        // Now look at regular files: are they all the same?
        for (path, type) in root1Entries where type == .regular {
            try await self.checkRegularFilesMatch(
                NIOFilePath(root1.underlying.appending(path)),
                NIOFilePath(root2.underlying.appending(path))
            )
        }

        // Are symbolic links all the same?
        for (path, type) in root1Entries where type == .symlink {
            try await self.checkSymbolicLinksMatch(
                NIOFilePath(root1.underlying.appending(path)),
                NIOFilePath(root2.underlying.appending(path))
            )
        }

        // Finally, check directories.
        for (path, type) in root1Entries where type == .directory {
            try await self.checkDirectoriesMatch(
                NIOFilePath(root1.underlying.appending(path)),
                NIOFilePath(root2.underlying.appending(path))
            )
        }
    }

    private func checkRegularFilesMatch(_ path1: NIOFilePath, _ path2: NIOFilePath) async throws {
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

    private func checkSymbolicLinksMatch(_ path1: NIOFilePath, _ path2: NIOFilePath) async throws {
        let destination1 = try await self.fs.destinationOfSymbolicLink(at: path1)
        let destination2 = try await self.fs.destinationOfSymbolicLink(at: path2)
        XCTAssertEqual(destination1, destination2)
    }

    /// Declare a directory structure in code to make with ``generateDeterministicDirectoryStructure``
    fileprivate enum TestFileStructure {
        case dir(_ name: FilePath.Component, _ contents: [TestFileStructure] = [])
        case file(_ name: FilePath.Component)
        // don't care about the destination yet
        case symbolicLink(_ name: FilePath.Component)

        static func makeNestedDirs(
            _ depth: Int,
            namer: (Int) -> FilePath.Component = { .init("dir-\($0)")! }
        ) -> [TestFileStructure] {
            let name = namer(depth)
            guard depth > 0 else {
                return []
            }
            return [.dir(name, makeNestedDirs(depth - 1, namer: namer))]
        }

        static func makeManyFiles(
            _ num: Int,
            namer: (Int) -> FilePath.Component = { .init("file-\($0)")! }
        ) -> [TestFileStructure] {
            (0..<num).map { .file(namer($0)) }
        }
    }

    /// This generates a directory structure to cover specific scenarios easily
    private func generateDeterministicDirectoryStructure(
        root: NIOFilePath,
        structure: [TestFileStructure]
    ) async throws {
        // always make root
        try await self.fs.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            permissions: nil
        )

        for item in structure {
            switch item {
            case let .dir(name, contents):
                try await self.generateDeterministicDirectoryStructure(
                    root: NIOFilePath(root.underlying.appending(name)),
                    structure: contents
                )
            case let .file(name):
                try await self.makeTestFile(NIOFilePath(root.underlying.appending(name)))
            case let .symbolicLink(name):
                try await self.fs.createSymbolicLink(
                    at: NIOFilePath(root.underlying.appending(name)),
                    withDestination: "nonexistent-destination"
                )
            }
        }
    }

    fileprivate func makeTestFile(
        _ path: NIOFilePath,
        tryAddAttribute: String? = .none
    ) async throws {
        try await self.fs.withFileHandle(
            forWritingAt: path,
            options: .newFile(replaceExisting: false)
        ) { file in
            if let tryAddAttribute {
                let byteCount = (32...128).randomElement()!
                do {
                    try await file.updateValueForAttribute(
                        Array(repeating: 0, count: byteCount),
                        attribute: tryAddAttribute
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
    }

    private func generateDirectoryStructure(
        root: NIOFilePath,
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
                    directoriesToMake.append(root.underlying.appending("file-\(i)-directory"))
                } else if makeSymbolicLink() {
                    let path = "file-\(i)-symlink"
                    try await self.fs.createSymbolicLink(
                        at: NIOFilePath(root.underlying.appending(path)),
                        withDestination: "nonexistent-destination"
                    )
                    itemsCreated += 1
                } else {
                    let path = root.underlying.appending("file-\(i)-regular")
                    let attribute: String? = Bool.random() ? .some("attribute-{\(i)}") : .none
                    try await makeTestFile(NIOFilePath(path), tryAddAttribute: attribute)
                    itemsCreated += 1
                }
            }

            return directoriesToMake
        }

        for path in dirsToMake {
            itemsCreated += try await self.generateDirectoryStructure(
                root: NIOFilePath(path),
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
            let template = NIOFilePath(templateString)

            // A random ending consisting only of 'X's could be generated, making the template
            // equal to the generated file path, but the probability of this happening three
            // times in a row is very low.
            var temporaryDirectoryPath: NIOFilePath?

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
                try await fileSystem.removeItem(at: temporaryDirectoryPath, strategy: .platformDefault)
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
            let template = NIOFilePath(templateString)
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
        let temporaryDirectoryPath = try await self.fs.createTemporaryDirectory(
            template: NIOFilePath(template)
        )

        self.addTeardownBlock { [fileSystem = self.fs] in
            try await fileSystem.removeItem(
                at: NIOFilePath(templateRoot),
                strategy: .platformDefault,
                recursively: true
            )
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

    func testTemporaryDirectoryRespectsEnvironment() async throws {
        if let envTmpDir = getenv("TMPDIR") {
            let envTmpDirString = String(cString: envTmpDir)
            let fsTempDirectory = try await fs.temporaryDirectory
            XCTAssertEqual(fsTempDirectory.underlying, FilePath(envTmpDirString))
        }
    }

    func testReadChunksRange() async throws {
        try await self.fs.withFileHandle(forReadingAt: NIOFilePath(#filePath)) { handle in
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
        try await self.fs.withFileHandle(forReadingAt: NIOFilePath(#filePath)) { handle in
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
        try await self.fs.withFileHandle(forReadingAt: NIOFilePath(#filePath)) { handle in
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
        try await self.fs.withFileHandle(forReadingAt: NIOFilePath(#filePath)) { handle in
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
        try await self.fs.withFileHandle(forReadingAt: NIOFilePath(#filePath)) { handle in
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
        try await self.fs.withFileHandle(forReadingAt: NIOFilePath(#filePath)) { handle in
            let info = try await handle.info()
            let size = info.size

            let byteCount = try await handle.readChunks(in: ...).reduce(into: 0) {
                $0 += $1.readableBytes
            }

            XCTAssertEqual(byteCount, Int(size))
        }
    }

    func testReadMoreThanByteBufferCapacity() async throws {
        let path = try await self.fs.temporaryFilePath()

        try await self.fs.withFileHandle(forReadingAndWritingAt: path) { fileHandle in
            await XCTAssertThrowsFileSystemErrorAsync {
                // Set `maximumSizeAllowed` to 1 byte more than can be written to `ByteBuffer`.
                try await fileHandle.readToEnd(
                    maximumSizeAllowed: .byteBufferCapacity + .bytes(1)
                )
            } onError: { error in
                XCTAssertEqual(error.code, .resourceExhausted)
            }
        }
    }

    func testReadWithUnlimitedMaximumSizeAllowed() async throws {
        let path = try await self.fs.temporaryFilePath()

        try await self.fs.withFileHandle(forReadingAndWritingAt: path) { fileHandle in
            await XCTAssertNoThrowAsync(
                try await fileHandle.readToEnd(maximumSizeAllowed: .unlimited)
            )
        }
    }

    func testReadIntoArray() async throws {
        let path = try await self.fs.temporaryFilePath()

        try await self.fs.withFileHandle(forReadingAndWritingAt: path) { fileHandle in
            _ = try await fileHandle.write(contentsOf: [0, 1, 2], toAbsoluteOffset: 0)
        }

        let contents = try await Array(contentsOf: path, maximumSizeAllowed: .bytes(1024))

        XCTAssertEqual(contents, [0, 1, 2])
    }

    func testReadIntoArraySlice() async throws {
        let path = try await self.fs.temporaryFilePath()

        try await self.fs.withFileHandle(forReadingAndWritingAt: path) { fileHandle in
            _ = try await fileHandle.write(contentsOf: [0, 1, 2], toAbsoluteOffset: 0)
        }

        let contents = try await ArraySlice(contentsOf: path, maximumSizeAllowed: .bytes(1024))

        XCTAssertEqual(contents, [0, 1, 2])
    }
}
