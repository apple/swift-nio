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

import NIOCore
@_spi(Testing) import NIOFS
import NIOFoundationCompat
import NIOPosix
import XCTest

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
final class FileHandleTests: XCTestCase {
    override func setUpWithError() throws {
        #if os(Windows)
        throw XCTSkip("The NIOFileSystem family is not yet functional on Windows")
        #endif
    }

    static let thisFile = FilePath(#filePath)
    static let testData = FilePath(#filePath)
        .removingLastComponent()  // FileHandleTests.swift
        .appending("Test Data")
        .lexicallyNormalized()

    private static func temporaryFileName() -> FilePath {
        FilePath("swift-filesystem-tests-\(UInt64.random(in: .min ... .max))")
    }

    func withTemporaryFile(
        autoClose: Bool = true,
        _ execute: @Sendable (SystemFileHandle) async throws -> Void
    ) async throws {
        let path = try await FilePath("\(FileSystem.shared.temporaryDirectory)/\(Self.temporaryFileName())")
        defer {
            // Remove the file when we're done.
            XCTAssertNoThrow(try Libc.remove(path).get())
        }

        try await withHandle(
            forFileAtPath: path,
            accessMode: .readWrite,
            options: [.create, .exclusiveCreate],
            permissions: .ownerReadWrite,
            autoClose: autoClose
        ) { handle in
            try await execute(handle)
        }
    }

    func withTestDataDirectory(
        autoClose: Bool = true,
        _ execute: @Sendable (SystemFileHandle) async throws -> Void
    ) async throws {
        try await self.withHandle(
            forFileAtPath: Self.testData,
            accessMode: .readOnly,
            options: [.directory, .nonBlocking],
            autoClose: autoClose
        ) {
            try await execute($0)
        }
    }

    private static func removeFile(atPath path: FilePath) {
        XCTAssertNoThrow(try Libc.remove(path).get())
    }

    func withHandle(
        forFileAtPath path: FilePath,
        accessMode: FileDescriptor.AccessMode = .readOnly,
        options: FileDescriptor.OpenOptions = [],
        permissions: FilePermissions? = nil,
        autoClose: Bool = true,
        _ execute: @Sendable (SystemFileHandle) async throws -> Void
    ) async throws {
        let descriptor = try FileDescriptor.open(
            path,
            accessMode,
            options: options,
            permissions: permissions
        )
        let handle = SystemFileHandle(
            takingOwnershipOf: descriptor,
            path: path,
            threadPool: .singleton
        )

        do {
            try await execute(handle)
            if autoClose {
                try? await handle.close()
            }
        } catch let skip as XCTSkip {
            try? await handle.close()
            throw skip
        } catch {
            XCTFail("Test threw error: '\(error)'")
            // Always close on error.
            try await handle.close()
        }
    }

    func testInfo() async throws {
        try await self.withHandle(forFileAtPath: Self.thisFile) { handle in
            let info = try await handle.info()
            // It's hard to make more assertions than this...
            XCTAssertEqual(info.type, .regular)
            XCTAssertGreaterThan(info.size, 1024)
        }

        try await self.withTemporaryFile { handle in
            let info = try await handle.info()
            // It's hard to make more assertions than this...
            XCTAssertEqual(info.type, .regular)
            XCTAssertEqual(info.size, 0)
        }
    }

    func testExtendedAttributes() async throws {
        let attribute = "attribute-name"
        try await self.withTemporaryFile { handle in
            do {
                // We just created this but we can't assert that there won't be any attributes
                // (who knows what the filesystem will do?) so we'll use this number as a baseline.
                var originalAttributes = try await handle.attributeNames()
                originalAttributes.sort()

                // There should be no value for this attribute, yet.
                let value = try await handle.valueForAttribute(attribute)
                XCTAssertEqual(value, [])

                // Set a value.
                let someBytes = Array("hello, world".utf8)
                try await handle.updateValueForAttribute(someBytes, attribute: attribute)

                // Retrieve it again.
                let retrieved = try await handle.valueForAttribute(attribute)
                XCTAssertEqual(retrieved, someBytes)

                // There should be an attribute now.
                let attributes = try await handle.attributeNames()
                XCTAssert(Set(attributes).isSuperset(of: originalAttributes))

                // Remove it.
                try await handle.removeValueForAttribute(attribute)

                // Should be back to the original values.
                var maybeOriginalAttributes = try await handle.attributeNames()
                maybeOriginalAttributes.sort()
                XCTAssertEqual(originalAttributes, maybeOriginalAttributes)
            } catch let error as FileSystemError where error.code == .unsupported {
                throw XCTSkip("Extended attributes are not supported on this platform.")
            }
        }
    }

    func testListExtendedAttributes() async throws {
        try await self.withTemporaryFile { handle in
            do {
                // Set some attributes.
                let attributeNames = Set((0..<5).map { "attr-\($0)" })
                for attribute in attributeNames {
                    try await handle.updateValueForAttribute([0, 1, 2], attribute: attribute)
                }

                // List the attributes.
                let attributes = try await handle.attributeNames()
                XCTAssert(Set(attributes).isSuperset(of: attributeNames))
            } catch let error as FileSystemError where error.code == .unsupported {
                throw XCTSkip("Extended attributes are not supported on this platform.")
            }
        }
    }

    func testUpdatePermissions() async throws {
        try await self.withTemporaryFile { handle in
            let info = try await handle.info()
            // Default permissions we use for temporary files.
            XCTAssertEqual(info.permissions, .ownerReadWrite)

            try await handle.replacePermissions(.ownerReadWriteExecute)
            let actual = try await handle.info().permissions
            XCTAssertEqual(actual, .ownerReadWriteExecute)
        }
    }

    func testAddPermissions() async throws {
        try await self.withTemporaryFile { handle in
            let info = try await handle.info()
            // Default permissions we use for temporary files.
            XCTAssertEqual(info.permissions, .ownerReadWrite)

            let computed = try await handle.addPermissions(.ownerExecute)
            let actual = try await handle.info().permissions
            XCTAssertEqual(computed, actual)
            XCTAssertEqual(computed, .ownerReadWriteExecute)
        }
    }

    func testRemovePermissions() async throws {
        try await self.withTemporaryFile { handle in
            let info = try await handle.info()
            // Default permissions we use for temporary files.
            XCTAssertEqual(info.permissions, .ownerReadWrite)

            // Set execute so we can remove it.
            try await handle.replacePermissions(.ownerReadWriteExecute)

            // Remove owner execute.
            let computed = try await handle.removePermissions(.ownerExecute)
            let actual = try await handle.info().permissions
            XCTAssertEqual(computed, actual)
            XCTAssertEqual(computed, .ownerReadWrite)
        }
    }

    func testWithUnsafeDescriptor() async throws {
        try await self.withTemporaryFile { handle in
            // Check we can successfully return a value.
            let value = try await handle.withUnsafeDescriptor { descriptor in
                42
            }
            XCTAssertEqual(value, 42)
        }
    }

    func testDetach() async throws {
        try await self.withTemporaryFile(autoClose: false) { handle in
            let descriptor = try handle.detachUnsafeFileDescriptor()
            // We don't need this: just close it.
            XCTAssertNoThrow(try descriptor.close())
            // Closing a detached handle is a no-op.
            try await handle.close()
            // All other methods should throw.
            try await Self.testAllMethodsThrowClosed(handle)
        }
    }

    func testClose() async throws {
        try await self.withHandle(forFileAtPath: Self.thisFile, autoClose: false) { handle in
            // Close.
            try await handle.close()
            // Closing is idempotent: this is fine.
            try await handle.close()
            // All other methods should throw.
            try await Self.testAllMethodsThrowClosed(handle)
        }
    }

    func testReadChunk() async throws {
        try await self.withHandle(forFileAtPath: Self.thisFile) { handle in
            do {
                // Zero offset.
                let bytes = try await handle.readChunk(fromAbsoluteOffset: 0, length: .bytes(80))
                let line = String(buffer: bytes)
                XCTAssertEqual(line, "//===----------------------------------------------------------------------===//")
            }

            do {
                // Non-zero offset.
                let bytes = try await handle.readChunk(fromAbsoluteOffset: 5, length: .bytes(10))
                let line = String(buffer: bytes)
                XCTAssertEqual(line, "----------")
            }

            do {
                // Length longer than file.
                let info = try await handle.info()
                let bytes = try await handle.readChunk(
                    fromAbsoluteOffset: 0,
                    length: .bytes(info.size + 10)
                )
                // Bytes should not be larger than the file.
                XCTAssertEqual(bytes.readableBytes, Int(info.size))
            }
        }
    }

    func testReadWholeFile() async throws {
        try await self.withHandle(forFileAtPath: Self.thisFile) { handle in
            // Check errors are thrown if we don't allow enough bytes.
            await XCTAssertThrowsFileSystemErrorAsync {
                try await handle.readToEnd(maximumSizeAllowed: .bytes(0))
            } onError: { error in
                XCTAssertEqual(error.code, .resourceExhausted)
            }

            // Validate that we can read the whole file when at the limit.
            let info = try await handle.info()
            let contents = try await handle.readToEnd(maximumSizeAllowed: .bytes(info.size))
            // Compare against the data as read by Foundation.
            let readByFoundation = try Data(contentsOf: URL(fileURLWithPath: Self.thisFile.string))
            XCTAssertEqual(
                contents,
                ByteBuffer(data: readByFoundation),
                "Contents of \(Self.thisFile) differ to that read by Foundation"
            )
        }
    }

    // These tests create FIFOs via `mkfifo`, which is unavailable on Windows.
    #if !os(Windows)
    func testWriteAndReadUnseekableFile() async throws {
        let privateTempDirPath = try await FileSystem.shared.createTemporaryDirectory(template: "test-XXX")
        self.addTeardownBlock {
            try await FileSystem.shared.removeItem(at: privateTempDirPath, recursively: true)
        }

        let fifoPath = FilePath(privateTempDirPath).appending("fifo")
        guard mkfifo(fifoPath.string, 0o644) == 0 else {
            XCTFail("Error calling mkfifo.")
            return
        }

        // Only reading no bytes at all is end-of-file, so for 'readToEnd' to return the FIFO must have no
        // writers left once the bytes have been read. A handle opened for reading and writing is itself a
        // writer, so read from a read-only handle and write with a separate descriptor which is closed.
        try await self.withHandle(forFileAtPath: fifoPath, accessMode: .readOnly, options: .nonBlocking) {
            handle in
            let someBytes = ByteBuffer(repeating: 42, count: 1546)
            let writer = try FileDescriptor.open(fifoPath, .writeOnly)
            _ = try writer.closeAfter {
                try writer.writeAll(someBytes.readableBytesView)
            }

            let readSomeBytes = try await handle.readToEnd(maximumSizeAllowed: .bytes(1546))
            XCTAssertEqual(readSomeBytes, someBytes)
        }
    }

    func testWriteAndReadUnseekableFileOverMaximumSizeAllowedThrowsError() async throws {
        let privateTempDirPath = try await FileSystem.shared.createTemporaryDirectory(template: "test-XXX")
        self.addTeardownBlock {
            try await FileSystem.shared.removeItem(at: privateTempDirPath, recursively: true)
        }

        let fifoPath = FilePath(privateTempDirPath).appending("fifo")
        guard mkfifo(fifoPath.string, 0o644) == 0 else {
            XCTFail("Error calling mkfifo.")
            return
        }

        // Reading continues until there are no bytes left and no writers, so don't hold the FIFO open for
        // writing in the handle being read: read from a read-only handle and write with a separate
        // descriptor which is closed.
        try await self.withHandle(forFileAtPath: fifoPath, accessMode: .readOnly, options: .nonBlocking) {
            handle in
            let someBytes = [UInt8](repeating: 42, count: 10)
            let writer = try FileDescriptor.open(fifoPath, .writeOnly)
            _ = try writer.closeAfter {
                try writer.writeAll(someBytes)
            }

            await XCTAssertThrowsFileSystemErrorAsync {
                try await handle.readToEnd(maximumSizeAllowed: .bytes(9))
            } onError: { error in
                XCTAssertEqual(error.code, .resourceExhausted)
            }
        }
    }

    func testWriteAndReadUnseekableFileWithOffsetsThrows() async throws {
        let privateTempDirPath = try await FileSystem.shared.createTemporaryDirectory(template: "test-XXX")
        self.addTeardownBlock {
            try await FileSystem.shared.removeItem(at: privateTempDirPath, recursively: true)
        }

        let fifoPath = FilePath(privateTempDirPath).appending("fifo")
        guard mkfifo(fifoPath.string, 0o644) == 0 else {
            XCTFail("Error calling mkfifo.")
            return
        }

        try await self.withHandle(forFileAtPath: fifoPath, accessMode: .readWrite) {
            handle in
            let someBytes = [UInt8](repeating: 42, count: 1546)

            await XCTAssertThrowsErrorAsync {
                try await handle.write(contentsOf: someBytes, toAbsoluteOffset: 42)
                XCTFail("Should have thrown")
            } onError: { error in
                let fileSystemError = error as! FileSystemError
                XCTAssertEqual(fileSystemError.code, .unsupported)
                XCTAssertEqual(fileSystemError.message, "File is unseekable.")
            }

            await XCTAssertThrowsErrorAsync {
                _ = try await handle.readToEnd(fromAbsoluteOffset: 42, maximumSizeAllowed: .bytes(1))
                XCTFail("Should have thrown")
            } onError: { error in
                let fileSystemError = error as! FileSystemError
                XCTAssertEqual(fileSystemError.code, .unsupported)
                XCTAssertEqual(fileSystemError.message, "File is unseekable.")
            }
        }
    }
    #endif  // !os(Windows)

    // MARK: - Pipes, FIFOs and repeated chunked reads

    #if !os(Windows)
    func testReadChunksOnFIFOWithSplitWrites() async throws {
        let fifoPath = try await self.makeTemporaryFIFO()

        try await withFIFOPeer(at: fifoPath) { peer in
            try peer.withOpenFIFO(.write) { fd in
                try peer.writeAll(fd, ByteBuffer(string: "hello "))
                try peer.waitForRelease()
                try peer.writeAll(fd, ByteBuffer(string: "world\n"))
            }
        } test: { peer in
            try await FileSystem.shared.withFileHandle(forReadingAt: NIOFilePath(fifoPath)) { handle in
                var iterator = handle.readChunks().makeAsyncIterator()

                // The peer has only written part of what it will write. A chunk which is shorter than
                // we asked for isn't the end of the file.
                let first = try await iterator.next()
                XCTAssertEqual(first.map { String(buffer: $0) }, "hello ")

                peer.release()

                var rest = ByteBuffer()
                while let chunk = try await iterator.next() {
                    XCTAssertGreaterThan(chunk.readableBytes, 0, "Chunks must not be empty")
                    rest.writeImmutableBuffer(chunk)
                }
                XCTAssertEqual(String(buffer: rest), "world\n")

                // The sequence is finished.
                let end = try await iterator.next()
                XCTAssertNil(end)
            }
        }
    }

    func testReadChunksOnPipeWithSplitWrites() async throws {
        try await withPipePeer(peerEnd: .write) { peer, fd in
            try peer.writeAll(fd, ByteBuffer(string: "hello "))
            try peer.waitForRelease()
            try peer.writeAll(fd, ByteBuffer(string: "world\n"))
        } test: { peer, path in
            try await FileSystem.shared.withFileHandle(forReadingAt: NIOFilePath(path)) { handle in
                var iterator = handle.readChunks().makeAsyncIterator()

                // The peer has only written part of what it will write. A chunk which is shorter than
                // we asked for isn't the end of the file.
                let first = try await iterator.next()
                XCTAssertEqual(first.map { String(buffer: $0) }, "hello ")

                peer.release()

                var rest = ByteBuffer()
                while let chunk = try await iterator.next() {
                    XCTAssertGreaterThan(chunk.readableBytes, 0, "Chunks must not be empty")
                    rest.writeImmutableBuffer(chunk)
                }
                XCTAssertEqual(String(buffer: rest), "world\n")
            }
        }
    }

    #if canImport(Darwin)
    func testReadChunksWithRangeOnTerminal() async throws {
        // Reading a terminal at an offset fails with ENXIO on Darwin, rather than the ESPIPE which pipes and
        // FIFOs give (and terminals give on Linux). Like a pipe, a terminal can still be read from the start.
        try await withPseudoTerminal { terminal in
            try await FileSystem.shared.withFileHandle(forReadingAt: NIOFilePath(terminal.path)) { handle in
                // A terminal is a character device, so it's only found to be unseekable when it's read.
                let info = try await handle.info()
                XCTAssertEqual(info.type, .character)

                try terminal.write(ByteBuffer(string: "hello\n"))

                // A terminal doesn't end until it's closed, so only read as much as was written.
                var bytes = ByteBuffer()
                for try await chunk in handle.readChunks(in: 0..<6) {
                    bytes.writeImmutableBuffer(chunk)
                }
                XCTAssertEqual(String(buffer: bytes), "hello\n")
            }
        }
    }

    func testReadingTerminalAtNonZeroOffsetThrows() async throws {
        // Like a FIFO, a terminal can only be read from offset zero. Reading it at another offset fails with
        // ENXIO on Darwin, rather than the ESPIPE which FIFOs give.
        try await withPseudoTerminal { terminal in
            try await FileSystem.shared.withFileHandle(forReadingAt: NIOFilePath(terminal.path)) { handle in
                // There's something to read, so an implementation which read the terminal regardless of the
                // offset wouldn't block.
                try terminal.write(ByteBuffer(string: "hello\n"))

                await XCTAssertThrowsFileSystemErrorAsync {
                    try await handle.readChunk(fromAbsoluteOffset: 5, length: .bytes(6))
                } onError: { error in
                    XCTAssertEqual(error.code, .unsupported)
                    XCTAssertEqual(error.message, "File is unseekable.")
                }

                await XCTAssertThrowsFileSystemErrorAsync {
                    for try await _ in handle.readChunks(in: 5..<10) {}
                } onError: { error in
                    XCTAssertEqual(error.code, .unsupported)
                }
            }
        }
    }
    #endif

    func testReadChunksWithRangeOnFIFO() async throws {
        let fifoPath = try await self.makeTemporaryFIFO()

        try await withFIFOPeer(at: fifoPath) { peer in
            try peer.withOpenFIFO(.write) { fd in
                try peer.writeAll(fd, ByteBuffer(string: "hello world\n"))
            }
        } test: { peer in
            try await FileSystem.shared.withFileHandle(forReadingAt: NIOFilePath(fifoPath)) { handle in
                // A FIFO can't seek, but a range which starts at zero is fine: it limits the number of
                // bytes which are read.
                var bytes = ByteBuffer()
                for try await chunk in handle.readChunks(in: 0..<8, chunkLength: .bytes(5)) {
                    XCTAssertLessThanOrEqual(chunk.readableBytes, 5)
                    bytes.writeImmutableBuffer(chunk)
                }
                XCTAssertEqual(String(buffer: bytes), "hello wo")
            }
        }
    }

    func testReadChunksWithRangeNotStartingAtZeroOnFIFOThrows() async throws {
        let fifoPath = try await self.makeTemporaryFIFO()

        try await withFIFOPeer(at: fifoPath) { peer in
            try peer.withOpenFIFO(.write) { fd in
                try peer.writeAll(fd, ByteBuffer(string: "hello world"))
            }
        } test: { _ in
            try await FileSystem.shared.withFileHandle(forReadingAt: NIOFilePath(fifoPath)) { handle in
                // A FIFO can only be read from the start, so a range which doesn't start at zero can't be read.
                // There's something to read, so an implementation which read the FIFO regardless of the range
                // wouldn't block.
                await XCTAssertThrowsFileSystemErrorAsync {
                    for try await _ in handle.readChunks(in: 5..<10) {}
                } onError: { error in
                    XCTAssertEqual(error.code, .unsupported)
                }
            }
        }
    }

    func testReadChunkAtNonZeroOffsetOnFIFOThrows() async throws {
        let fifoPath = try await self.makeTemporaryFIFO()

        try await withFIFOPeer(at: fifoPath) { peer in
            try peer.withOpenFIFO(.write) { fd in
                try peer.writeAll(fd, ByteBuffer(string: "hello world"))
            }
        } test: { _ in
            try await FileSystem.shared.withFileHandle(forReadingAt: NIOFilePath(fifoPath)) { handle in
                let first = try await handle.readChunk(fromAbsoluteOffset: 0, length: .bytes(5))
                XCTAssertEqual(String(buffer: first), "hello")

                // A FIFO can't seek, so it can only be read from offset zero. Any other offset throws, even
                // the one which follows on from the last read. There's more to read, so an implementation which
                // read the FIFO regardless of the offset wouldn't block.
                for offset: Int64 in [5, 100] {
                    await XCTAssertThrowsFileSystemErrorAsync {
                        try await handle.readChunk(fromAbsoluteOffset: offset, length: .bytes(6))
                    } onError: { error in
                        XCTAssertEqual(error.code, .unsupported)
                        XCTAssertEqual(error.message, "File is unseekable.")
                    }
                }

                // Reading from offset zero again reads the next bytes, not the start of the FIFO.
                let next = try await handle.readChunk(fromAbsoluteOffset: 0, length: .bytes(6))
                XCTAssertEqual(String(buffer: next), " world")
            }
        }
    }

    func testReadToEndOnFIFOWithSplitWrites() async throws {
        let fifoPath = try await self.makeTemporaryFIFO()

        try await withFIFOPeer(at: fifoPath) { peer in
            try peer.withOpenFIFO(.write) { fd in
                try peer.writeAll(fd, ByteBuffer(string: "hello "))
                try peer.waitForRelease()
                try peer.writeAll(fd, ByteBuffer(string: "world\n"))
            }
        } test: { peer in
            try await FileSystem.shared.withFileHandle(forReadingAt: NIOFilePath(fifoPath)) { handle in
                async let contents = handle.readToEnd(maximumSizeAllowed: .mebibytes(1))

                // 'readToEnd' can't be signalled part way through, so the peer's second write has to be
                // released after a delay instead. This test may pass spuriously for an implementation
                // which stops at the first short read if the delay is shorter than the time it takes
                // to start reading, but that's unlikely with this much time.
                try await Task.sleep(nanoseconds: 250_000_000)
                peer.release()

                let result = try await contents
                XCTAssertEqual(String(buffer: result), "hello world\n")
            }
        }
    }

    func testReadToEndOnFIFOThatExceedsMaximumSizeDoesNotLeaveAReadInFlight() async throws {
        let fifoPath = try await self.makeTemporaryFIFO()

        // The peer writes more than is allowed, then stays connected without writing anything else: any
        // further read of the FIFO blocks until the peer is released.
        try await withFIFOPeer(at: fifoPath) { peer in
            try peer.withOpenFIFO(.write) { fd in
                try peer.writeAll(fd, ByteBuffer(string: "0123456789"))
                try peer.waitForRelease(timeout: .seconds(10))
            }
        } test: { peer in
            let handle = try await FileSystem.shared.openFile(forReadingAt: NIOFilePath(fifoPath))

            await XCTAssertThrowsFileSystemErrorAsync {
                try await handle.readToEnd(maximumSizeAllowed: .bytes(5))
            } onError: { error in
                XCTAssertEqual(error.code, .resourceExhausted)
            }

            // On some platforms closing a file waits for reads which are in progress to finish. Reading the
            // FIFO further than necessary to find that it has too many bytes would leave a read in progress
            // which doesn't finish until the peer writes or disconnects.
            let start = NIODeadline.now()
            try await handle.close()
            let elapsed = NIODeadline.now() - start
            XCTAssertLessThan(elapsed, .seconds(2), "Closing the handle took \(elapsed)")

            peer.release()
        }
    }

    func testReadToEndOnPipeWithSplitWrites() async throws {
        try await withPipePeer(peerEnd: .write) { peer, fd in
            try peer.writeAll(fd, ByteBuffer(string: "hello "))
            try peer.waitForRelease()
            try peer.writeAll(fd, ByteBuffer(string: "world\n"))
        } test: { peer, path in
            try await FileSystem.shared.withFileHandle(forReadingAt: NIOFilePath(path)) { handle in
                async let contents = handle.readToEnd(maximumSizeAllowed: .mebibytes(1))

                // As for a FIFO, the peer's second write is released after a delay, which is long enough
                // for reading to have started.
                try await Task.sleep(nanoseconds: 250_000_000)
                peer.release()

                let result = try await contents
                XCTAssertEqual(String(buffer: result), "hello world\n")
            }
        }
    }

    func testDirectoryHandleReadFIFOWaitsForDataFromConnectedWriter() async throws {
        try await FileSystem.shared.withTemporaryDirectory { directory, directoryPath in
            let fifoPath = FilePath(directoryPath).appending("fifo")
            try makeFIFO(at: fifoPath)

            try await withFIFOPeer(at: fifoPath) { peer in
                try peer.withOpenFIFO(.write) { fd in
                    peer.reachMilestone()
                    try peer.waitForRelease()
                    try peer.writeAll(fd, ByteBuffer(string: "hello"))
                }
            } test: { peer in
                let handle = try await directory.openFile(forReadingAt: "fifo", options: OpenOptions.Read())

                let bytes: ByteBuffer
                do {
                    // Make sure that the writer is connected before reading. Whether or not opening the
                    // file waits for it, there is now a writer and it hasn't written anything.
                    try await peer.waitForMilestone()

                    // Reading must wait for the writer, it mustn't fail because there's nothing to read yet.
                    // The peer is released after a delay as the read is blocked until then: an implementation
                    // which fails the read does so immediately, well within the delay.
                    async let chunk = handle.readChunk(fromAbsoluteOffset: 0, length: .bytes(64))
                    try await Task.sleep(nanoseconds: 100_000_000)
                    peer.release()
                    bytes = try await chunk
                } catch {
                    try? await handle.close()
                    throw error
                }
                try await handle.close()

                XCTAssertEqual(String(buffer: bytes), "hello")
            }
        }
    }

    func testDirectoryHandleReadFIFOBeforeWriterConnects() async throws {
        try await FileSystem.shared.withTemporaryDirectory { directory, directoryPath in
            let fifoPath = FilePath(directoryPath).appending("fifo")
            try makeFIFO(at: fifoPath)

            try await withFIFOPeer(at: fifoPath) { peer in
                try peer.waitForRelease()
                try peer.withOpenFIFO(.write) { fd in
                    try peer.writeAll(fd, ByteBuffer(string: "hello"))
                }
            } test: { peer in
                // Let the writer connect once the test is opening the read end. The test may not have started
                // to open it by the time the writer connects, so this can't show that opening waits for the
                // writer: 'testDirectoryHandleOpensFilesInBlockingMode' checks that instead.
                peer.release()
                let handle = try await directory.openFile(forReadingAt: "fifo", options: OpenOptions.Read())

                let bytes: ByteBuffer
                do {
                    // The writer may not have written anything yet: that's not the same as the end of the file.
                    bytes = try await handle.readChunk(fromAbsoluteOffset: 0, length: .bytes(64))
                } catch {
                    try? await handle.close()
                    throw error
                }
                try await handle.close()

                XCTAssertEqual(String(buffer: bytes), "hello")
            }
        }
    }

    func testDirectoryHandleOpenFIFOForWritingWaitsForReader() async throws {
        try await FileSystem.shared.withTemporaryDirectory { directory, directoryPath in
            let fifoPath = FilePath(directoryPath).appending("fifo")
            try makeFIFO(at: fifoPath)

            let received = try await withFIFOPeer(at: fifoPath, returning: ByteBuffer.self) { peer in
                try peer.waitForRelease()
                return try peer.withOpenFIFO(.read) { fd in
                    try peer.readToEOF(fd)
                }
            } test: { peer in
                // Let the reader connect once the test is opening the write end. Opening must wait for the
                // reader rather than fail. The test may not have started to open it by the time the reader
                // connects, so this can't show that: 'testDirectoryHandleOpensFilesInBlockingMode' checks
                // that instead.
                peer.release()
                let handle = try await directory.openFile(
                    forWritingAt: "fifo",
                    options: .modifyFile(createIfNecessary: false)
                )

                do {
                    try await handle.write(contentsOf: Array("hello".utf8), toAbsoluteOffset: 0)
                } catch {
                    try? await handle.close()
                    throw error
                }
                try await handle.close()
            }
            XCTAssertEqual(String(buffer: received), "hello")
        }
    }

    func testDirectoryHandleWriteToFullFIFOWaitsForReader() async throws {
        try await FileSystem.shared.withTemporaryDirectory { directory, directoryPath in
            let fifoPath = FilePath(directoryPath).appending("fifo")
            try makeFIFO(at: fifoPath)

            // This is much larger than the capacity of a pipe.
            let payload = ByteBuffer(bytes: (0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7) })

            let received = try await withFIFOPeer(at: fifoPath, returning: ByteBuffer.self) { peer in
                try peer.withOpenFIFO(.read) { fd in
                    // Leave the FIFO to fill up before draining it.
                    try peer.waitForFIFOToFill()
                    return try peer.readToEOF(fd)
                }
            } test: { peer in
                let handle = try await directory.openFile(
                    forWritingAt: "fifo",
                    options: .modifyFile(createIfNecessary: false)
                )

                do {
                    // Writing must wait for space in the pipe rather than fail when it's full.
                    let written = try await handle.write(contentsOf: payload, toAbsoluteOffset: 0)
                    XCTAssertEqual(written, Int64(payload.readableBytes))
                } catch {
                    try? await handle.close()
                    throw error
                }
                try await handle.close()
            }
            XCTAssertEqual(received.readableBytes, payload.readableBytes)
            XCTAssertTrue(received == payload, "The bytes received weren't the bytes written")
        }
    }

    func testDirectoryHandleOpensFilesInBlockingMode() async throws {
        // Opening, reading and writing a FIFO must wait for the other end. In non-blocking mode they would
        // instead fail, or report the end of the file early. Whether a test of a FIFO catches that depends
        // on whether the test or its peer acts first, which a test can't control, so check the mode itself.
        func isNonBlocking(_ handle: some FileHandleProtocol) async throws -> Bool {
            try await handle.withUnsafeDescriptor { descriptor in
                fcntl(descriptor.rawValue, F_GETFL) & O_NONBLOCK != 0
            }
        }

        try await FileSystem.shared.withTemporaryDirectory { directory, _ in
            try await directory.withFileHandle(
                forReadingAndWritingAt: "file",
                options: .modifyFile(createIfNecessary: true)
            ) { handle in
                let nonBlocking = try await isNonBlocking(handle)
                XCTAssertFalse(nonBlocking, "Opened for reading and writing in non-blocking mode")
            }

            try await directory.withFileHandle(
                forWritingAt: "file",
                options: .modifyFile(createIfNecessary: false)
            ) { handle in
                let nonBlocking = try await isNonBlocking(handle)
                XCTAssertFalse(nonBlocking, "Opened for writing in non-blocking mode")
            }

            try await directory.withFileHandle(forReadingAt: "file") { handle in
                let nonBlocking = try await isNonBlocking(handle)
                XCTAssertFalse(nonBlocking, "Opened for reading in non-blocking mode")
            }
        }
    }

    // These check the test support rather than NIOFS. If the peer of a FIFO or pipe raised SIGPIPE when it
    // wrote without a reader, a test which failed part way through would terminate the whole test process.
    func testFIFOPeerWritingWithoutAReaderDoesNotRaiseSIGPIPE() async throws {
        let fifoPath = try await self.makeTemporaryFIFO()

        do {
            try await withFIFOPeer(at: fifoPath) { peer in
                try peer.withOpenFIFO(.write) { fd in
                    try peer.waitForRelease()
                    try peer.writeAll(fd, ByteBuffer(string: "nobody is listening"))
                }
            } test: { peer in
                // Connect to the peer, then disconnect before it writes.
                let handle = try await FileSystem.shared.openFile(forReadingAt: NIOFilePath(fifoPath))
                try await handle.close()
                peer.release()
            }
            XCTFail("The peer's write should have failed")
        } catch let error as Errno {
            XCTAssertEqual(error, .brokenPipe)
        }
    }

    func testPipePeerWritingWithoutAReaderDoesNotRaiseSIGPIPE() async throws {
        do {
            try await withPipePeer(peerEnd: .write) { peer, fd in
                // The pipe has no reader once the test has finished.
                try peer.waitForTestToFinish()
                try peer.writeAll(fd, ByteBuffer(string: "nobody is listening"))
            } test: { _, path in
                let handle = try await FileSystem.shared.openFile(forReadingAt: NIOFilePath(path))
                try await handle.close()
            }
            XCTFail("The peer's write should have failed")
        } catch let error as Errno {
            XCTAssertEqual(error, .brokenPipe)
        }
    }

    func testReadChunksTwiceOnRegularFile() async throws {
        let fs = FileSystem.shared
        let path = try await fs.temporaryFilePath()
        self.addTeardownBlock {
            try await fs.removeItem(at: path)
        }

        let contents = (0..<(4 * 1024 + 123)).map { UInt8(truncatingIfNeeded: $0) }
        try await fs.withFileHandle(
            forWritingAt: path,
            options: .newFile(replaceExisting: false)
        ) { handle in
            _ = try await handle.write(contentsOf: contents, toAbsoluteOffset: 0)
        }

        try await fs.withFileHandle(forReadingAt: path) { handle in
            for iteration in 1...2 {
                var bytes = ByteBuffer()
                for try await chunk in handle.readChunks(chunkLength: .bytes(512)) {
                    XCTAssertLessThanOrEqual(chunk.readableBytes, 512)
                    bytes.writeImmutableBuffer(chunk)
                }

                XCTAssertEqual(bytes.readableBytes, contents.count, "Wrong number of bytes in iteration \(iteration)")
                XCTAssertTrue(
                    Array(bytes.readableBytesView) == contents,
                    "The bytes read in iteration \(iteration) weren't the bytes written"
                )
            }
        }
    }

    func testReadChunksReadsFromTheStartRegardlessOfDescriptorPosition() async throws {
        let fs = FileSystem.shared
        let path = try await fs.temporaryFilePath()
        self.addTeardownBlock {
            try await fs.removeItem(at: path)
        }

        let contents = (0..<(4 * 1024 + 123)).map { UInt8(truncatingIfNeeded: $0) }
        try await fs.withFileHandle(
            forWritingAt: path,
            options: .newFile(replaceExisting: false)
        ) { handle in
            _ = try await handle.write(contentsOf: contents, toAbsoluteOffset: 0)
        }

        try await fs.withFileHandle(forReadingAt: path) { handle in
            // Move the file position, which is shared by everything using the descriptor.
            _ = try await handle.withUnsafeDescriptor { descriptor in
                try descriptor.seek(offset: 1000, from: .start)
            }

            var bytes = ByteBuffer()
            for try await chunk in handle.readChunks(chunkLength: .bytes(512)) {
                bytes.writeImmutableBuffer(chunk)
            }

            XCTAssertEqual(bytes.readableBytes, contents.count)
            XCTAssertTrue(
                Array(bytes.readableBytesView) == contents,
                "The bytes read weren't the bytes written"
            )
        }
    }

    #if os(Linux)
    func testReadToEndOfProcFile() async throws {
        // Procfs files report a size of zero and return no more than about a page for each read. A short read
        // isn't the end of the file, and the file is much larger than a page: a test process has far more
        // memory mappings than fit in one.
        let path: NIOFilePath = "/proc/self/maps"

        let contents = try await FileSystem.shared.withFileHandle(forReadingAt: path) { handle in
            try await handle.readToEnd(maximumSizeAllowed: .mebibytes(16))
        }
        XCTAssertGreaterThan(contents.readableBytes, 4096)
        XCTAssertEqual(contents.readableBytesView.last, UInt8(ascii: "\n"))

        let string = try await String(contentsOf: path, maximumSizeAllowed: .mebibytes(16))
        XCTAssertGreaterThan(string.utf8.count, 4096)
        XCTAssertTrue(string.hasSuffix("\n"))
    }
    #endif  // os(Linux)
    #endif  // !os(Windows)

    func testReadWholeFileWithOffsets() async throws {
        try await self.withHandle(forFileAtPath: Self.thisFile) { handle in
            let info = try await handle.info()

            // We should be able to do a zero-length read at the end of the file with a max size
            // allowed of zero.
            let empty = try await handle.readToEnd(
                fromAbsoluteOffset: info.size,
                maximumSizeAllowed: .bytes(0)
            )
            XCTAssertEqual(empty.readableBytes, 0)

            // Read the last 100 bytes.
            let bytes = try await handle.readToEnd(
                fromAbsoluteOffset: info.size - 100,
                maximumSizeAllowed: .bytes(100)
            )

            // Compare against the data as read by Foundation.
            let readByFoundation = try Data(contentsOf: URL(fileURLWithPath: Self.thisFile.string))
            let tail = readByFoundation.dropFirst(readByFoundation.count - 100)
            XCTAssertEqual(
                bytes,
                ByteBuffer(data: tail),
                "Contents of \(Self.thisFile) differ to that read by Foundation"
            )
        }
    }

    func testReadFileAsChunks() async throws {
        try await self.withHandle(forFileAtPath: Self.thisFile) { handle in
            var bytes = ByteBuffer()

            for try await chunk in handle.readChunks(in: ..., chunkLength: .bytes(128)) {
                XCTAssertLessThanOrEqual(chunk.readableBytes, 128)
                bytes.writeImmutableBuffer(chunk)
            }

            var contents = try await handle.readToEnd(maximumSizeAllowed: .bytes(1024 * 1024))
            XCTAssertEqual(
                bytes,
                contents,
                """
                Read \(bytes.readableBytes) which were different to the \(contents.readableBytes) expected bytes.
                """
            )

            // Read from an offset.
            bytes.clear()
            for try await chunk in handle.readChunks(in: 100..., chunkLength: .bytes(128)) {
                XCTAssertLessThanOrEqual(chunk.readableBytes, 128)
                bytes.writeImmutableBuffer(chunk)
            }

            contents.moveReaderIndex(forwardBy: 100)
            XCTAssertEqual(
                bytes,
                contents,
                """
                Read \(bytes.readableBytes) which were different to the \(contents.readableBytes) \
                expected bytes.
                """
            )
        }
    }

    func testReadEmptyRange() async throws {
        try await self.withHandle(forFileAtPath: Self.thisFile) { handle in
            // No bytes should be read.
            for try await _ in handle.readChunks(in: 0..<0, chunkLength: .bytes(128)) {
                XCTFail("We shouldn't read any chunks.")
            }

            // No bytes should be read.
            for try await _ in handle.readChunks(in: 100..<100, chunkLength: .bytes(128)) {
                XCTFail("We shouldn't read any chunks.")
            }
        }
    }

    enum RangeType {
        case closed(ClosedRange<Int64>)
        case partialThrough(PartialRangeThrough<Int64>)
        case partialUpTo(PartialRangeUpTo<Int64>)
    }

    static func testReadEndOffsetExceedsEOF(range: RangeType, handle: SystemFileHandle) async throws {
        var bytes = ByteBuffer()
        let fileChunks: FileChunks

        switch range {
        case .closed(let offsets):
            fileChunks = handle.readChunks(in: offsets, chunkLength: .bytes(128))
        case .partialUpTo(let offsets):
            fileChunks = handle.readChunks(in: offsets, chunkLength: .bytes(128))
        case .partialThrough(let offsets):
            fileChunks = handle.readChunks(in: offsets, chunkLength: .bytes(128))
        }

        for try await chunk in fileChunks {
            XCTAssertLessThanOrEqual(chunk.readableBytes, 128)
            bytes.writeImmutableBuffer(chunk)
        }

        // We should read bytes only before the EOF.
        let contents = try await handle.readToEnd(maximumSizeAllowed: .bytes(1024 * 1024))
        XCTAssertEqual(bytes, contents)
    }

    func testReadEndOffsetExceedsEOFClosedrange() async throws {
        try await self.withHandle(forFileAtPath: Self.thisFile) { handle in
            let info = try await handle.info()
            try await Self.testReadEndOffsetExceedsEOF(
                range: .closed(0...(info.size + 3)),
                handle: handle
            )
        }
    }

    func testReadEndOffsetExceedsEOFPartialThrough() async throws {
        try await self.withHandle(forFileAtPath: Self.thisFile) { handle in
            let info = try await handle.info()
            try await Self.testReadEndOffsetExceedsEOF(
                range: .partialThrough(...(info.size + 3)),
                handle: handle
            )
        }
    }

    func testReadEndOffsetExceedsEOFPartialUpTo() async throws {
        try await self.withHandle(forFileAtPath: Self.thisFile) { handle in
            let info = try await handle.info()
            try await Self.testReadEndOffsetExceedsEOF(
                range: .partialUpTo(..<(info.size + 3)),
                handle: handle
            )
        }
    }

    func testReadRangeShorterThanChunklength() async throws {
        // Reading chunks of bytes from within a range that is shorter than the chunklength
        // and the length of the file.
        try await self.withHandle(forFileAtPath: Self.thisFile) { handle in
            var bytes = ByteBuffer()
            for try await chunk in handle.readChunks(in: 0...120, chunkLength: .bytes(128)) {
                XCTAssertEqual(chunk.readableBytes, 121)
                bytes.writeImmutableBuffer(chunk)
            }

            // We should only read bytes from within the range.
            XCTAssertEqual(
                bytes.readableBytes,
                121,
                """
                Read \(bytes.readableBytes) which were different to the 121 \
                expected bytes.
                """
            )
        }
    }

    func testReadRangeLongerThanChunkAndNotMultipleOfChunkLength() async throws {
        // Reading chunks of bytes from within a range longer than the chunklength
        // and with size not a multiple of the chunklength.
        try await self.withHandle(forFileAtPath: Self.thisFile) { handle in
            var bytes = ByteBuffer()
            for try await chunk in handle.readChunks(in: 0...200, chunkLength: .bytes(128)) {
                XCTAssertLessThanOrEqual(chunk.readableBytes, 128)
                bytes.writeImmutableBuffer(chunk)
            }

            // We should only read bytes from within the range.
            XCTAssertEqual(
                bytes.readableBytes,
                201,
                """
                Read \(bytes.readableBytes) which were different to the 201 \
                expected bytes.
                """
            )
        }
    }

    func testReadPartialFromRange() async throws {
        // Reading chunks of bytes from a PartialRangeFrom.
        try await self.withHandle(forFileAtPath: Self.thisFile) { handle in
            var bytes = ByteBuffer()
            for try await chunk in handle.readChunks(in: 0..., chunkLength: .bytes(128)) {
                XCTAssertLessThanOrEqual(chunk.readableBytes, 128)
                bytes.writeImmutableBuffer(chunk)
            }
            let contents = try await handle.readToEnd(maximumSizeAllowed: .bytes(1024 * 1024))

            // We should read bytes until EOF.
            XCTAssertEqual(
                bytes.readableBytes,
                contents.readableBytes,
                """
                Read \(bytes.readableBytes) which were different to the \(contents.readableBytes) \
                expected bytes.
                """
            )
        }
    }

    func testUnboundedRange() async throws {
        // Reading chunks of bytes from an UnboundedRange.
        try await self.withHandle(forFileAtPath: Self.thisFile) { handle in
            var bytes = ByteBuffer()
            for try await chunk in handle.readChunks(in: ..., chunkLength: .bytes(128)) {
                XCTAssertLessThanOrEqual(chunk.readableBytes, 128)
                bytes.writeImmutableBuffer(chunk)
            }
            let contents = try await handle.readToEnd(maximumSizeAllowed: .bytes(1024 * 1024))

            // We should read bytes until EOF.
            XCTAssertEqual(
                bytes.readableBytes,
                contents.readableBytes,
                """
                Read \(bytes.readableBytes) which were different to the \(contents.readableBytes) \
                expected bytes.
                """
            )
        }
    }

    func testReadPartialRange() async throws {
        // Reading chunks of bytes from a PartialRangeThrough with the upper bound inside the file.
        try await self.withHandle(forFileAtPath: Self.thisFile) { handle in
            var bytes = ByteBuffer()
            let contents = try await handle.readToEnd(maximumSizeAllowed: .bytes(1024 * 1024))

            for try await chunk in handle.readChunks(in: ...200, chunkLength: .bytes(128)) {
                XCTAssertLessThanOrEqual(chunk.readableBytes, 128)
                bytes.writeImmutableBuffer(chunk)
            }

            // We should read the first bytes from the beginning of the file, until reaching the
            // upper bound of the range (inclusive).
            XCTAssertEqual(bytes, contents.getSlice(at: contents.readerIndex, length: 201))

            bytes.clear()

            for try await chunk in handle.readChunks(in: ..<200, chunkLength: .bytes(128)) {
                XCTAssertLessThanOrEqual(chunk.readableBytes, 128)
                bytes.writeImmutableBuffer(chunk)
            }

            // We should read the first bytes from the beginning of the file, until reaching the
            // upper bound of the range (inclusive).
            XCTAssertEqual(bytes, contents.getSlice(at: contents.readerIndex, length: 200))
        }
    }

    func testReadChunksOverloadAmbiguity() async throws {
        try await self.withHandle(forFileAtPath: Self.thisFile) { handle in
            // Seven possibilities for range:
            // 1. ...
            // 2. x...y
            // 3. x..<y
            // 4. x...
            // 5. ..<y
            // 6. ...y
            // 7. no value (i.e. default)
            //
            // Two possibilities for chunk length:
            // 1. value
            // 2. no value (i.e. default)
            //
            // Two possibilities for type:
            // 1. value
            // 2. no value (i.e. default)
            //
            // This makes 28 combinations which should all be representable.

            // Unbounded range.
            _ = handle.readChunks(in: ..., chunkLength: .mebibytes(1))
            _ = handle.readChunks(in: ...)

            // Closed range.
            _ = handle.readChunks(in: 0...1, chunkLength: .mebibytes(1))
            _ = handle.readChunks(in: 0...1)

            // Range.
            _ = handle.readChunks(in: 0..<1, chunkLength: .mebibytes(1))
            _ = handle.readChunks(in: 0..<1)

            // Partial range from.
            _ = handle.readChunks(in: 0..., chunkLength: .mebibytes(1))
            _ = handle.readChunks(in: 0...)

            // Partial range up to.
            _ = handle.readChunks(in: ..<1, chunkLength: .mebibytes(1))
            _ = handle.readChunks(in: ..<1)

            // Partial range through.
            _ = handle.readChunks(in: ...1, chunkLength: .mebibytes(1))
            _ = handle.readChunks(in: ...1)

            // No range.
            _ = handle.readChunks(chunkLength: .mebibytes(1))
            _ = handle.readChunks()
        }
    }

    func testCloseWhileReadingFromFile() async throws {
        try await self.testCloseOrDetachMidRead(close: true)
    }

    func testDetachWhileReadingFromFile() async throws {
        try await self.testCloseOrDetachMidRead(close: false)
    }

    func testCloseBeforeReadingFromFile() async throws {
        try await self.testCloseOrDetachBeforeRead(close: true)
    }

    func testDetachBeforeReadingFromFile() async throws {
        try await self.testCloseOrDetachBeforeRead(close: false)
    }

    private func testCloseOrDetachMidRead(close: Bool) async throws {
        func testCloseWhileReadingFromFile() async throws {
            try await self.withHandle(forFileAtPath: Self.thisFile, autoClose: false) { handle in
                var bytes = ByteBuffer()
                var iterator = handle.readChunks(chunkLength: .bytes(1)).makeAsyncIterator()
                // Read the first 10 bytes.
                for _ in 0..<10 {
                    if let chunk = try await iterator.next() {
                        bytes.writeImmutableBuffer(chunk)
                    }
                }

                XCTAssertEqual(bytes.readableBytes, 10)

                // Closing (or detaching) mid-read is weird but we should tolerate it.
                if close {
                    try await handle.close()
                } else {
                    let descriptor = try handle.detachUnsafeFileDescriptor()
                    try descriptor.close()
                }

                // Resume iteration: we will be able to read any buffered bytes before the iterator
                // eventually throws as it tries to read more from a closed file. We tolerate any number
                // of buffered chunks (including zero).
                do {
                    while let next = try await iterator.next() {
                        bytes.writeImmutableBuffer(next)
                    }
                    XCTFail("Iterator did not eventually throw for closed file.")
                } catch let error as FileSystemError {
                    XCTAssertEqual(error.code, .closed)
                    // The cause *shouldn't* be a system call failure: we should catch the close in
                    // user space rather than the kernel trying to read from an already closed
                    // descriptor (the descriptor value may be reused by a newly opened file).
                    XCTAssertFalse(error.cause is FileSystemError.SystemCallError)
                }
            }
        }
    }

    private func testCloseOrDetachBeforeRead(close: Bool) async throws {
        try await self.withHandle(forFileAtPath: Self.thisFile, autoClose: false) { handle in
            if close {
                try await handle.close()
            } else {
                let descriptor = try handle.detachUnsafeFileDescriptor()
                try descriptor.close()
            }

            var iterator = handle.readChunks().makeAsyncIterator()
            await XCTAssertThrowsFileSystemErrorAsync {
                try await iterator.next()
            } onError: { error in
                XCTAssertEqual(error.code, .closed)
            }
        }
    }

    func testWriteBytes() async throws {
        try await withTemporaryFile { handle in
            let someBytes = ByteBuffer(repeating: 42, count: 1024)
            try await handle.write(contentsOf: someBytes.readableBytesView, toAbsoluteOffset: 0)

            let readSomeBytes = try await handle.readToEnd(maximumSizeAllowed: .bytes(1024))
            XCTAssertEqual(readSomeBytes, someBytes)

            let moreBytes = ByteBuffer(repeating: 13, count: 1024)
            try await handle.write(contentsOf: moreBytes.readableBytesView, toAbsoluteOffset: 512)

            let readMoreBytes = try await handle.readToEnd(
                fromAbsoluteOffset: 512,
                maximumSizeAllowed: .bytes(1024)
            )
            XCTAssertEqual(readMoreBytes, moreBytes)

            var allTheBytes = try await handle.readToEnd(maximumSizeAllowed: .bytes(1536))
            let firstBytes = allTheBytes.readSlice(length: 512)!
            XCTAssertTrue(firstBytes.readableBytesView.allSatisfy({ $0 == 42 }))
            XCTAssertTrue(allTheBytes.readableBytesView.allSatisfy({ $0 == 13 }))
        }
    }

    func testWriteByteBuffer() async throws {
        try await withTemporaryFile { handle in
            let someBytes = ByteBuffer(repeating: 42, count: 1024)
            try await handle.write(contentsOf: someBytes, toAbsoluteOffset: 0)

            let readSomeBytes = try await handle.readToEnd(maximumSizeAllowed: .bytes(1024))
            XCTAssertEqual(readSomeBytes, someBytes)

            let moreBytes = ByteBuffer(repeating: 13, count: 1024)
            try await handle.write(contentsOf: moreBytes, toAbsoluteOffset: 512)

            let readMoreBytes = try await handle.readToEnd(
                fromAbsoluteOffset: 512,
                maximumSizeAllowed: .bytes(1024)
            )
            XCTAssertEqual(readMoreBytes, moreBytes)

            var allTheBytes = try await handle.readToEnd(maximumSizeAllowed: .bytes(1536))
            let firstBytes = allTheBytes.readSlice(length: 512)!
            XCTAssertTrue(firstBytes.readableBytesView.allSatisfy({ $0 == 42 }))
            XCTAssertTrue(allTheBytes.readableBytesView.allSatisfy({ $0 == 13 }))
        }
    }

    func testWriteSequenceOfBytes() async throws {
        try await withTemporaryFile { handle in
            let byteSequence = UInt8(0)..<UInt8(64)
            var offset = Int64(0)
            offset += try await Int64(
                handle.write(contentsOf: byteSequence, toAbsoluteOffset: offset)
            )
            XCTAssertEqual(offset, 64)
            offset += try await Int64(
                handle.write(contentsOf: byteSequence, toAbsoluteOffset: offset)
            )
            XCTAssertEqual(offset, 128)

            let bytes = try await handle.readToEnd(maximumSizeAllowed: .bytes(128))
            XCTAssertEqual(bytes, ByteBuffer(bytes: Array(byteSequence) + Array(byteSequence)))
        }
    }

    private static func testAllMethodsThrowClosed(_ handle: SystemFileHandle) async throws {
        // All other operations should fail.
        try await assertThrowsErrorClosed { try await handle.info() }
        try await assertThrowsErrorClosed { try await handle.withUnsafeDescriptor { _ in } }
        try await assertThrowsErrorClosed { try handle.detachUnsafeFileDescriptor() }
        try await assertThrowsErrorClosed { try await handle.synchronize() }

        // Extended attributes
        try await assertThrowsErrorClosed { try await handle.attributeNames() }
        try await assertThrowsErrorClosed { try await handle.valueForAttribute("foo") }
        try await assertThrowsErrorClosed {
            try await handle.updateValueForAttribute([], attribute: "foo")
        }
        try await assertThrowsErrorClosed { try await handle.removeValueForAttribute("foo") }

        // Permissions
        let perms = FilePermissions.ownerReadWrite
        try await assertThrowsErrorClosed { try await handle.replacePermissions(perms) }
        try await assertThrowsErrorClosed { try await handle.addPermissions(perms) }
        try await assertThrowsErrorClosed { try await handle.removePermissions(perms) }
    }

    func testListContents() async throws {
        try await self.withTestDataDirectory { handle in
            let entries = try await handle.listContents()
                .reduce(into: []) { $0.append($1) }
            Self.verifyContentsOfTestData(entries)
        }
    }

    func testListContentsRecursively() async throws {
        try await self.withTestDataDirectory { handle in
            let entries = try await handle.listContents(recursive: true)
                .reduce(into: []) { $0.append($1) }
            Self.verifyContentsOfTestData(entries, recursive: true)
        }
    }

    func testListContentsBatched() async throws {
        try await self.withTestDataDirectory { handle in
            let entries = try await handle.listContents()
                .batched()
                .reduce(into: []) { $0.append(contentsOf: $1) }
            Self.verifyContentsOfTestData(entries)
        }
    }

    func testListContentsRecursivelyBatched() async throws {
        try await self.withTestDataDirectory { handle in
            let entries = try await handle.listContents(recursive: true)
                .batched()
                .reduce(into: []) { $0.append(contentsOf: $1) }
            Self.verifyContentsOfTestData(entries, recursive: true)
        }
    }

    private static func verifyContentsOfTestData(
        _ entries: [DirectoryEntry],
        recursive: Bool = false
    ) {
        var expected: [DirectoryEntry] = [
            .init(path: NIOFilePath(Self.testData.appending("README.md")), type: .regular)!,
            .init(path: NIOFilePath(Self.testData.appending("Foo")), type: .directory)!,
            .init(path: NIOFilePath(Self.testData.appending("README.md.symlink")), type: .symlink)!,
            .init(path: NIOFilePath(Self.testData.appending("Foo.symlink")), type: .symlink)!,
        ]

        if recursive {
            let path = Self.testData.appending(["Foo", "README.txt"])
            expected.append(.init(path: NIOFilePath(path), type: .regular)!)
        }

        for entry in expected {
            XCTAssert(entries.contains(entry), "Did not find expected entry '\(entry)'")
        }
    }

    func testOpenRelativeDirectory() async throws {
        try await self.withTestDataDirectory { testData in
            for path in ["Foo", "Foo.symlink"] {
                // Open a subdirectory.
                try await testData.withDirectoryHandle(atPath: NIOFilePath(path)) { foo in
                    let fooInfo = try await foo.info()
                    XCTAssertEqual(fooInfo.type, .directory)

                    // Open its parent, i.e. back to "Test Data".
                    try await foo.withDirectoryHandle(atPath: "..") { fooParent in
                        let fooParentInfo = try await fooParent.info()
                        XCTAssertEqual(fooParentInfo.type, .directory)

                        let entries = try await fooParent.listContents()
                            .reduce(into: []) { $0.append($1) }

                        Self.verifyContentsOfTestData(entries)
                    }
                }
            }
        }
    }

    func testOpenRelativeFile() async throws {
        try await self.withTestDataDirectory { testData in
            // Open a regular file.
            let contents = try await testData.withFileHandle(forReadingAt: "README.md") { file in
                let info = try await file.info()
                XCTAssertEqual(info.type, .regular)
                return try await file.readToEnd(maximumSizeAllowed: .bytes(1024 * 1024))
            }

            // Open the symlink should open the target.
            try await testData.withFileHandle(forReadingAt: "README.md.symlink") { file in
                let info = try await file.info()
                XCTAssertEqual(info.type, .regular)

                let other = try await file.readToEnd(maximumSizeAllowed: .bytes(1024 * 1024))
                XCTAssertEqual(contents, other)
            }
        }
    }

    func testOpenCreateForFileWhichExists() async throws {
        try await self.withTestDataDirectory { dir in
            try await dir.withFileHandle(
                forWritingAt: "README.md",
                options: .modifyFile(createIfNecessary: true)
            ) { file in
                let info = try await file.info()
                XCTAssertEqual(info.type, .regular)
                XCTAssertGreaterThan(info.size, 0)
            }
        }
    }

    func testOpenCreateForFileWhichDoesNotExist() async throws {
        try await self.withTestDataDirectory { dir in
            let path = Self.temporaryFileName()
            defer {
                Self.removeFile(atPath: Self.testData.appending(path.string))
            }

            try await dir.withFileHandle(
                forWritingAt: NIOFilePath(path),
                options: .modifyFile(createIfNecessary: true)
            ) { handle in
                let info = try await handle.info()
                XCTAssertEqual(info.size, 0)
                XCTAssertEqual(info.type, .regular)
            }
        }
    }

    func testOpenExclusiveCreateForFileWhichExists() async throws {
        try await self.withTestDataDirectory { dir in
            await XCTAssertThrowsFileSystemErrorAsync {
                try await dir.withFileHandle(
                    forWritingAt: "README.md",
                    options: .newFile(replaceExisting: false)
                ) { _ in
                }
            } onError: { error in
                XCTAssertEqual(error.code, .fileAlreadyExists)
            }
        }
    }

    func testOpenExclusiveCreateForFileWhichExistsWithoutOTMPFILE() async throws {
        // Takes the path where 'O_TMPFILE' doesn't exist, so materializing the file is done via
        // creating a temporary file and then renaming it using 'renamex_np'/'renameat2' (Darwin/Linux).
        let temporaryDirectory = try await FileSystem.shared.temporaryDirectory
        let path = FilePath(temporaryDirectory).appending(Self.temporaryFileName().components)
        let handle = try SystemFileHandle.syncOpenWithMaterialization(
            atPath: path,
            mode: .writeOnly,
            options: [.exclusiveCreate, .create],
            permissions: .ownerReadWrite,
            threadPool: .singleton,
            useTemporaryFileIfPossible: false
        ).get()

        // Closing shouldn't throw and the file should now be visible.
        try await handle.close()
        let info = try await FileSystem.shared.info(forFileAt: NIOFilePath(path))
        XCTAssertNotNil(info)
    }

    func testOpenExclusiveCreateForFileWhichExistsWithoutOTMPFILEOrRenameat2() async throws {
        // Takes the path where 'O_TMPFILE' doesn't exist, so materializing the file is done via
        // creating a temporary file and then renaming it using 'renameat2' and then takes a further
        // fallback path where 'renameat2' returns EINVAL so the 'rename' is used in combination
        // with 'stat'. This path is only reachable on Linux.
        #if canImport(Glibc) || canImport(Musl) || canImport(Bionic)
        let temporaryDirectory = FilePath(try await FileSystem.shared.temporaryDirectory)
        let path = temporaryDirectory.appending(Self.temporaryFileName().components)
        let handle = try SystemFileHandle.syncOpenWithMaterialization(
            atPath: path,
            mode: .writeOnly,
            options: [.exclusiveCreate, .create],
            permissions: .ownerReadWrite,
            threadPool: .singleton,
            useTemporaryFileIfPossible: false
        ).get()

        // Close, but take the path where 'renameat2' fails with EINVAL. This shouldn't throw and
        // the file should be available.
        let result = handle.sendableView._close(materialize: true, simulatedRenameat2Errno: .invalidArgument)
        try result.get()

        let info = try await FileSystem.shared.info(forFileAt: NIOFilePath(path))
        XCTAssertNotNil(info)
        #else
        throw XCTSkip("This test requires 'renameat2' which isn't supported on this platform")
        #endif
    }

    func testOpenExclusiveCreateWithoutOTMPFILEOrRenameat2ENOSYS() async throws {
        // As above, but takes the fallback path where 'renameat2' fails with ENOSYS (the syscall
        // isn't implemented by the filesystem, as on some FUSE-backed Android storage). The
        // exclusive create should still succeed via 'stat' + 'rename'. Only reachable on Linux.
        #if canImport(Glibc) || canImport(Musl) || canImport(Bionic)
        let temporaryDirectory = FilePath(try await FileSystem.shared.temporaryDirectory)
        let path = temporaryDirectory.appending(Self.temporaryFileName().components)
        let handle = try SystemFileHandle.syncOpenWithMaterialization(
            atPath: path,
            mode: .writeOnly,
            options: [.exclusiveCreate, .create],
            permissions: .ownerReadWrite,
            threadPool: .singleton,
            useTemporaryFileIfPossible: false
        ).get()

        let result = handle.sendableView._close(materialize: true, simulatedRenameat2Errno: .noFunction)
        try result.get()

        let info = try await FileSystem.shared.info(forFileAt: NIOFilePath(path))
        XCTAssertNotNil(info)
        #else
        throw XCTSkip("This test requires 'renameat2' which isn't supported on this platform")
        #endif
    }

    func testOpenNonExclusiveWithoutOTMPFILEOrRenameat2ENOSYS() async throws {
        // Takes the path where 'O_TMPFILE' doesn't exist so a temporary file is created and renamed
        // into place, then the fallback path where the 'renameat2' syscall fails with ENOSYS (not
        // implemented by the filesystem, as on some FUSE-backed Android storage). A non-exclusive
        // materialization should fall back to a plain 'rename'. Only reachable on Linux.
        #if canImport(Glibc) || canImport(Musl) || canImport(Bionic)
        let temporaryDirectory = FilePath(try await FileSystem.shared.temporaryDirectory)
        let path = temporaryDirectory.appending(Self.temporaryFileName().components)
        let handle = try SystemFileHandle.syncOpenWithMaterialization(
            atPath: path,
            mode: .writeOnly,
            options: [.truncate, .create],
            permissions: .ownerReadWrite,
            threadPool: .singleton,
            useTemporaryFileIfPossible: false
        ).get()

        let result = handle.sendableView._close(materialize: true, simulatedRenameat2Errno: .noFunction)
        try result.get()

        let info = try await FileSystem.shared.info(forFileAt: NIOFilePath(path))
        XCTAssertNotNil(info)
        #else
        throw XCTSkip("This test requires 'renameat2' which isn't supported on this platform")
        #endif
    }

    func testOpenExclusiveCreateForFileWhichDoesNotExist() async throws {
        try await self.withTestDataDirectory { dir in
            let path = Self.temporaryFileName()
            defer {
                Self.removeFile(atPath: Self.testData.appending(path.string))
            }

            try await dir.withFileHandle(
                forWritingAt: NIOFilePath(path),
                options: .newFile(replaceExisting: false)
            ) { handle in
                let info = try await handle.info()
                XCTAssertEqual(info.size, 0)
                XCTAssertEqual(info.type, .regular)
            }
        }
    }

    func testOpenCreateOrTruncateForFileWhichExists() async throws {
        try await self.withTestDataDirectory { dir in
            let path = Self.temporaryFileName()
            defer {
                Self.removeFile(atPath: Self.testData.appending(path.string))
            }

            // Create a file and write some junk to it. We need to truncate it in a moment.
            try await dir.withFileHandle(
                forWritingAt: NIOFilePath(path),
                options: .newFile(replaceExisting: false)
            ) { handle in
                try await handle.write(
                    contentsOf: Array(repeating: 0, count: 1024),
                    toAbsoluteOffset: 0
                )
                let info = try await handle.info()
                XCTAssertEqual(info.size, 1024)
            }

            // Already exists; shouldn't throw.
            try await dir.withFileHandle(
                forWritingAt: NIOFilePath(path),
                options: .newFile(replaceExisting: true)
            ) { file in
                let info = try await file.info()
                XCTAssertEqual(info.type, .regular)
                XCTAssertGreaterThanOrEqual(info.size, 0)
            }
        }
    }

    func testOpenCreateOrTruncateForFileWhichDoesNotExist() async throws {
        try await self.withTestDataDirectory { dir in
            let path = Self.temporaryFileName()
            defer {
                Self.removeFile(atPath: Self.testData.appending(path.string))
            }

            // Should not exist, should not throw.
            try await dir.withFileHandle(
                forWritingAt: NIOFilePath(path),
                options: .newFile(replaceExisting: true)
            ) { file in
                let info = try await file.info()
                XCTAssertEqual(info.type, .regular)
                XCTAssertGreaterThanOrEqual(info.size, 0)
            }
        }
    }

    func testOpenMustExistForFileWhichExists() async throws {
        try await self.withTestDataDirectory { dir in
            // Exists, must not throw.
            try await dir.withFileHandle(
                forWritingAt: "README.md",
                options: .modifyFile(createIfNecessary: false)
            ) { file in
                let info = try await file.info()
                XCTAssertEqual(info.type, .regular)
                XCTAssertGreaterThanOrEqual(info.size, 0)
            }
        }
    }

    func testOpenMustExistForFileWhichDoesNotExist() async throws {
        try await self.withTestDataDirectory { dir in
            let path = Self.temporaryFileName()
            await XCTAssertThrowsFileSystemErrorAsync {
                try await dir.withFileHandle(
                    forWritingAt: NIOFilePath(path),
                    options: .modifyFile(createIfNecessary: false)
                ) { file in
                    XCTFail("Unexpectedly opened \(path)")
                }
            } onError: { error in
                XCTAssertEqual(error.code, .notFound)
            }
        }
    }

    func testResizeFile() async throws {
        try await self.withTemporaryFile { handle in
            try await handle.write(
                contentsOf: Array(repeating: 0, count: 1024),
                toAbsoluteOffset: 0
            )

            try await handle.resize(to: .bytes(1000))
            let newSize1 = try await handle.info().size
            XCTAssertEqual(newSize1, 1000)

            try await handle.resize(to: .bytes(1025))
            let newSize2 = try await handle.info().size
            XCTAssertEqual(newSize2, 1025)

            try await handle.resize(to: .bytes(0))
            let newSize3 = try await handle.info().size
            XCTAssertEqual(newSize3, 0)
        }
    }

    func testResizeFileErrors() async throws {
        try await self.withTemporaryFile { handle in
            try await handle.write(
                contentsOf: Array(repeating: 0, count: 1024),
                toAbsoluteOffset: 0
            )

            await XCTAssertThrowsFileSystemErrorAsync {
                try await handle.resize(to: .bytes(-2))
            } onError: { error in
                XCTAssertEqual(error.code, .invalidArgument)
            }
        }
    }

    func testSetLastAccesTime() async throws {
        try await self.withTemporaryFile { handle in
            let originalLastDataModificationTime = try await handle.info().lastDataModificationTime
            let originalLastAccessTime = try await handle.info().lastAccessTime

            try await handle.setTimes(
                lastAccess: FileInfo.Timespec(seconds: 10, nanoseconds: 5),
                lastDataModification: nil
            )

            let actualLastAccessTime = try await handle.info().lastAccessTime
            XCTAssertEqual(actualLastAccessTime, FileInfo.Timespec(seconds: 10, nanoseconds: 5))
            XCTAssertNotEqual(actualLastAccessTime, originalLastAccessTime)

            let actualLastDataModificationTime = try await handle.info().lastDataModificationTime
            XCTAssertEqual(actualLastDataModificationTime, originalLastDataModificationTime)
        }
    }

    func testSetLastDataModificationTime() async throws {
        try await self.withTemporaryFile { handle in
            let originalLastDataModificationTime = try await handle.info().lastDataModificationTime
            let originalLastAccessTime = try await handle.info().lastAccessTime

            try await handle.setTimes(
                lastAccess: nil,
                lastDataModification: FileInfo.Timespec(seconds: 10, nanoseconds: 5)
            )

            let actualLastDataModificationTime = try await handle.info().lastDataModificationTime
            XCTAssertEqual(actualLastDataModificationTime, FileInfo.Timespec(seconds: 10, nanoseconds: 5))
            XCTAssertNotEqual(actualLastDataModificationTime, originalLastDataModificationTime)

            let actualLastAccessTime = try await handle.info().lastAccessTime
            XCTAssertEqual(actualLastAccessTime, originalLastAccessTime)
        }
    }

    func testSetLastAccessAndLastDataModificationTimes() async throws {
        try await self.withTemporaryFile { handle in
            let originalLastDataModificationTime = try await handle.info().lastDataModificationTime
            let originalLastAccessTime = try await handle.info().lastAccessTime

            try await handle.setTimes(
                lastAccess: FileInfo.Timespec(seconds: 20, nanoseconds: 25),
                lastDataModification: FileInfo.Timespec(seconds: 10, nanoseconds: 5)
            )

            let actualLastAccessTime = try await handle.info().lastAccessTime
            XCTAssertEqual(actualLastAccessTime, FileInfo.Timespec(seconds: 20, nanoseconds: 25))
            XCTAssertNotEqual(actualLastAccessTime, originalLastAccessTime)

            let actualLastDataModificationTime = try await handle.info().lastDataModificationTime
            XCTAssertEqual(actualLastDataModificationTime, FileInfo.Timespec(seconds: 10, nanoseconds: 5))
            XCTAssertNotEqual(actualLastDataModificationTime, originalLastDataModificationTime)
        }
    }

    func testSetLastAccessAndLastDataModificationTimesToNil() async throws {
        try await self.withTemporaryFile { handle in
            // Set some random value for both times, only to be overwritten by the current time
            // right after.
            try await handle.setTimes(
                lastAccess: FileInfo.Timespec(seconds: 1, nanoseconds: 0),
                lastDataModification: FileInfo.Timespec(seconds: 1, nanoseconds: 0)
            )

            var actualLastAccessTime = try await handle.info().lastAccessTime
            XCTAssertEqual(actualLastAccessTime, FileInfo.Timespec(seconds: 1, nanoseconds: 0))

            var actualLastDataModificationTime = try await handle.info().lastDataModificationTime
            XCTAssertEqual(actualLastDataModificationTime, FileInfo.Timespec(seconds: 1, nanoseconds: 0))

            try await handle.setTimes(
                lastAccess: nil,
                lastDataModification: nil
            )
            let estimatedCurrentTimeInSeconds = Date.now.timeIntervalSince1970

            // Assert that the times are equal to the current time, with up to a second difference
            // to avoid timing flakiness. Both the last accessed and last modification times should
            // also equal each other.
            actualLastAccessTime = try await handle.info().lastAccessTime
            let actualLastAccessTimeNanosecondsInSeconds = Double(actualLastAccessTime.nanoseconds) / 1e+9
            let actualLastAccessTimeInSeconds =
                Double(actualLastAccessTime.seconds) + actualLastAccessTimeNanosecondsInSeconds
            XCTAssertEqual(actualLastAccessTimeInSeconds, estimatedCurrentTimeInSeconds, accuracy: 1)
            actualLastDataModificationTime = try await handle.info().lastDataModificationTime
            XCTAssertEqual(actualLastDataModificationTime.seconds, actualLastAccessTime.seconds)
        }
    }

    func testTouchFile() async throws {
        try await self.withTemporaryFile { handle in
            // Set some random value for both times, only to be overwritten by the current time
            // right after.
            try await handle.setTimes(
                lastAccess: FileInfo.Timespec(seconds: 1, nanoseconds: 0),
                lastDataModification: FileInfo.Timespec(seconds: 1, nanoseconds: 0)
            )

            var actualLastAccessTime = try await handle.info().lastAccessTime
            XCTAssertEqual(actualLastAccessTime, FileInfo.Timespec(seconds: 1, nanoseconds: 0))

            var actualLastDataModificationTime = try await handle.info().lastDataModificationTime
            XCTAssertEqual(actualLastDataModificationTime, FileInfo.Timespec(seconds: 1, nanoseconds: 0))

            try await handle.touch()
            let estimatedCurrentTimeInSeconds = Date.now.timeIntervalSince1970

            // Assert that the times are equal to the current time, with up to a second difference
            // to avoid timing flakiness. Both the last accessed and last modification times should
            // also equal each other.
            actualLastAccessTime = try await handle.info().lastAccessTime
            let actualLastAccessTimeNanosecondsInSeconds = Double(actualLastAccessTime.nanoseconds) / 1e+9
            let actualLastAccessTimeInSeconds =
                Double(actualLastAccessTime.seconds) + actualLastAccessTimeNanosecondsInSeconds
            XCTAssertEqual(actualLastAccessTimeInSeconds, estimatedCurrentTimeInSeconds, accuracy: 1)
            actualLastDataModificationTime = try await handle.info().lastDataModificationTime
            XCTAssertEqual(actualLastDataModificationTime.seconds, actualLastAccessTime.seconds)
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private func assertThrowsErrorClosed<R>(
    line: UInt = #line,
    _ expression: () async throws -> R
) async throws {
    await XCTAssertThrowsFileSystemErrorAsync {
        try await expression()
    } onError: { error in
        XCTAssertEqual(error.code, .closed)
    }
}
