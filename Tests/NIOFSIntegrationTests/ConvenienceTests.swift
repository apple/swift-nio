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

import Dispatch
import NIOCore
import NIOFS
import NIOPosix
import XCTest

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class ConvenienceTests: XCTestCase {
    override func setUpWithError() throws {
        #if os(Windows)
        throw XCTSkip("The NIOFileSystem family is not yet functional on Windows")
        #endif
    }

    static let fs = FileSystem.shared

    func testOneShotReadSizesAndRepeatedReads() async throws {
        try await Self.fs.withTemporaryDirectory { _, directoryPath in
            for size in [0, 1024, 1024 * 1024] {
                let path = NIOFilePath(FilePath(directoryPath).appending("file-\(size)"))
                let expected = (0..<size).map { UInt8(truncatingIfNeeded: $0) }
                try await expected.write(toFileAt: path)

                for _ in 0..<3 {
                    let actual = try await ByteBuffer(
                        contentsOf: path,
                        maximumSizeAllowed: .bytes(Int64(size + 1))
                    )
                    XCTAssertEqual(actual, ByteBuffer(bytes: expected))
                }
            }
        }
    }

    func testOneShotReadNonexistentFile() async throws {
        let path = try await Self.fs.temporaryFilePath()
        await XCTAssertThrowsFileSystemErrorAsync {
            try await ByteBuffer(contentsOf: path, maximumSizeAllowed: .bytes(1024))
        } onError: { error in
            XCTAssertEqual(error.code, .notFound)
        }
    }

    func testOneShotReadMaximumSizeFailureClosesDescriptor() async throws {
        try await Self.fs.withTemporaryDirectory { _, directoryPath in
            let path = NIOFilePath(FilePath(directoryPath).appending("too-large"))
            try await [UInt8](repeating: 1, count: 1024).write(toFileAt: path)

            await XCTAssertThrowsFileSystemErrorAsync {
                try await ByteBuffer(contentsOf: path, maximumSizeAllowed: .bytes(1023))
            } onError: { error in
                XCTAssertEqual(error.code, .resourceExhausted)
            }
        }
    }

    func testOneShotReadPermissionFailure() async throws {
        try await Self.fs.withTemporaryDirectory { _, directoryPath in
            let path = NIOFilePath(FilePath(directoryPath).appending("unreadable"))
            try await [1, 2, 3].write(toFileAt: path)
            try await Self.fs.withFileHandle(
                forReadingAndWritingAt: path,
                options: .modifyFile(createIfNecessary: false)
            ) { handle in
                try await handle.replacePermissions([])
            }

            do {
                _ = try await ByteBuffer(contentsOf: path, maximumSizeAllowed: .bytes(3))
                throw XCTSkip("The current user can read files without read permissions")
            } catch let skip as XCTSkip {
                throw skip
            } catch let error as FileSystemError {
                XCTAssertEqual(error.code, .permissionDenied)
            }
        }
    }

    func testOneShotWriteCreateOverwriteAndOffset() async throws {
        try await Self.fs.withTemporaryDirectory { _, directoryPath in
            let path = NIOFilePath(FilePath(directoryPath).appending("output"))
            let initial = [UInt8](repeating: 1, count: 1024 * 1024)
            let initialCount = try await initial.write(toFileAt: path)
            XCTAssertEqual(initialCount, Int64(initial.count))

            let replacement: [UInt8] = [2, 3, 4, 5]
            let replacementCount = try await replacement.write(
                toFileAt: path,
                options: .newFile(replaceExisting: true)
            )
            XCTAssertEqual(replacementCount, Int64(replacement.count))

            let offsetCount = try await [8, 9].write(
                toFileAt: path,
                absoluteOffset: 2,
                options: .modifyFile(createIfNecessary: false)
            )
            XCTAssertEqual(offsetCount, 2)

            let actual = try await ByteBuffer(contentsOf: path, maximumSizeAllowed: .bytes(16))
            XCTAssertEqual(actual, ByteBuffer(bytes: [2, 3, 8, 9]))
        }
    }

    func testOneShotEmptyWrite() async throws {
        try await Self.fs.withTemporaryDirectory { _, directoryPath in
            let path = NIOFilePath(FilePath(directoryPath).appending("empty"))
            let written = try await [UInt8]().write(toFileAt: path)
            XCTAssertEqual(written, 0)

            let actual = try await ByteBuffer(contentsOf: path, maximumSizeAllowed: .bytes(0))
            XCTAssertEqual(actual.readableBytes, 0)
        }
    }

    func testOneShotWriteFailureDoesNotMaterializeFile() async throws {
        try await Self.fs.withTemporaryDirectory { _, directoryPath in
            let path = NIOFilePath(
                FilePath(directoryPath).appending("missing").appending("output")
            )

            await XCTAssertThrowsFileSystemErrorAsync {
                try await [1, 2, 3].write(toFileAt: path)
            } onError: { error in
                XCTAssertEqual(error.code, .notFound)
            }

            let info = try await Self.fs.info(forFileAt: path)
            XCTAssertNil(info)
        }
    }

    func testOneShotReadsAtHighConcurrency() async throws {
        try await Self.fs.withTemporaryDirectory { _, directoryPath in
            let path = NIOFilePath(FilePath(directoryPath).appending("input"))
            let expected = [UInt8](repeating: 0x5a, count: 4096)
            try await expected.write(toFileAt: path)

            try await withThrowingTaskGroup(of: ByteBuffer.self) { group in
                for _ in 0..<512 {
                    group.addTask {
                        try await ByteBuffer(contentsOf: path, maximumSizeAllowed: .bytes(4096))
                    }
                }

                for try await actual in group {
                    XCTAssertEqual(actual, ByteBuffer(bytes: expected))
                }
            }
        }
    }

    func testCancelledQueuedOneShotReadDoesNotLeakDescriptor() async throws {
        let pool = NIOThreadPool(numberOfThreads: 1)
        pool.start()
        let fileSystem = FileSystem(threadPool: pool)
        let workerStarted = self.expectation(description: "thread-pool worker is occupied")
        let releaseWorker = DispatchSemaphore(value: 0)
        pool.submit { state in
            XCTAssertEqual(state, .active)
            workerStarted.fulfill()
            releaseWorker.wait()
        }
        await self.fulfillment(of: [workerStarted])

        do {
            try await Self.fs.withTemporaryDirectory { _, directoryPath in
                let path = NIOFilePath(FilePath(directoryPath).appending("input"))
                try await [1, 2, 3].write(toFileAt: path)

                let task = Task {
                    try await ByteBuffer(
                        contentsOf: path,
                        maximumSizeAllowed: .bytes(3),
                        fileSystem: fileSystem
                    )
                }
                task.cancel()
                releaseWorker.signal()

                do {
                    _ = try await task.value
                    XCTFail("Cancelled read unexpectedly succeeded")
                } catch is CancellationError {
                    // Expected.
                }
            }
        } catch {
            releaseWorker.signal()
            try await pool.shutdownGracefully()
            throw error
        }

        try await pool.shutdownGracefully()
    }

    func testCancelledQueuedOneShotWriteDoesNotMaterializeFile() async throws {
        let pool = NIOThreadPool(numberOfThreads: 1)
        pool.start()
        let fileSystem = FileSystem(threadPool: pool)
        let workerStarted = self.expectation(description: "thread-pool worker is occupied")
        let releaseWorker = DispatchSemaphore(value: 0)
        pool.submit { state in
            XCTAssertEqual(state, .active)
            workerStarted.fulfill()
            releaseWorker.wait()
        }
        await self.fulfillment(of: [workerStarted])

        do {
            try await Self.fs.withTemporaryDirectory { _, directoryPath in
                let path = NIOFilePath(FilePath(directoryPath).appending("output"))
                let task = Task {
                    try await [1, 2, 3].write(toFileAt: path, fileSystem: fileSystem)
                }
                task.cancel()
                releaseWorker.signal()

                do {
                    _ = try await task.value
                    XCTFail("Cancelled write unexpectedly succeeded")
                } catch is CancellationError {
                    // Expected.
                }

                let info = try await Self.fs.info(forFileAt: path)
                XCTAssertNil(info)
            }
        } catch {
            releaseWorker.signal()
            try await pool.shutdownGracefully()
            throw error
        }

        try await pool.shutdownGracefully()
    }

    func testWriteStringToFile() async throws {
        let path = try await Self.fs.temporaryFilePath()
        let bytesWritten = try await "some text".write(toFileAt: path)
        XCTAssertEqual(bytesWritten, 9)

        let bytes = try await ByteBuffer(contentsOf: path, maximumSizeAllowed: .bytes(1024))
        XCTAssertEqual(bytes, ByteBuffer(string: "some text"))
    }

    func testWriteSequenceToFile() async throws {
        let path = try await Self.fs.temporaryFilePath()
        let byteSequence = stride(from: UInt8(0), to: UInt8(64), by: 1)
        let bytesWritten = try await byteSequence.write(toFileAt: path)
        XCTAssertEqual(bytesWritten, 64)

        let bytes = try await ByteBuffer(contentsOf: path, maximumSizeAllowed: .bytes(1024))
        XCTAssertEqual(bytes, ByteBuffer(bytes: byteSequence))
    }

    func testWriteAsyncSequenceOfBytesToFile() async throws {
        let path = try await Self.fs.temporaryFilePath()
        let stream = AsyncStream(UInt8.self) { continuation in
            for byte in UInt8(0)..<64 {
                continuation.yield(byte)
            }
            continuation.finish()
        }

        let bytesWritten = try await stream.write(toFileAt: path)
        XCTAssertEqual(bytesWritten, 64)

        let bytes = try await ByteBuffer(contentsOf: path, maximumSizeAllowed: .bytes(1024))
        XCTAssertEqual(bytes, ByteBuffer(bytes: Array(0..<64)))
    }

    func testWriteAsyncSequenceOfChunksToFile() async throws {
        let path = try await Self.fs.temporaryFilePath()
        let stream = AsyncStream([UInt8].self) { continuation in
            for lowerByte in stride(from: UInt8(0), to: 64, by: 8) {
                continuation.yield(Array(lowerByte..<lowerByte + 8))
            }
            continuation.finish()
        }

        let bytesWritten = try await stream.write(toFileAt: path)
        XCTAssertEqual(bytesWritten, 64)

        let bytes = try await ByteBuffer(contentsOf: path, maximumSizeAllowed: .bytes(1024))
        XCTAssertEqual(bytes, ByteBuffer(bytes: Array(0..<64)))
    }

    // MARK: - String + FileSystem

    func testStringFromFullFile() async throws {
        let path = try await Self.fs.temporaryFilePath()
        try await "some text".write(toFileAt: path)

        let string = try await String(contentsOf: path, maximumSizeAllowed: .bytes(1024))
        XCTAssertEqual(string, "some text")
    }

    func testStringFromPartOfAFile() async throws {
        let path = try await Self.fs.temporaryFilePath()
        try await "some text".write(toFileAt: path)

        await XCTAssertThrowsFileSystemErrorAsync {
            try await String(contentsOf: path, maximumSizeAllowed: .bytes(4))
        }
    }

    // MARK: - Array + FileSystem
    func testArrayFromFullFile() async throws {
        let path = try await Self.fs.temporaryFilePath()
        try await Array("some text".utf8).write(toFileAt: path)
        let array = try await Array(contentsOf: path, maximumSizeAllowed: .bytes(1024))
        XCTAssertEqual(array, Array("some text".utf8))
    }
}
