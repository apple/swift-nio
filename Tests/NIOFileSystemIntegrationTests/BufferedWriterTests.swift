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
import XCTest

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class BufferedWriterTests: XCTestCase {
    func testBufferedWriter() async throws {
        let fs = FileSystem.shared
        let path = try await fs.temporaryFilePath()

        try await fs.withFileHandle(
            forReadingAndWritingAt: path,
            options: .newFile(replaceExisting: false)
        ) { file in
            let bufferSize = 8192
            var writer = file.bufferedWriter(capacity: .bytes(Int64(bufferSize)))
            XCTAssertEqual(writer.bufferedBytes, 0)

            // Write a full buffers worth of bytes, should be flushed immediately.
            try await writer.write(contentsOf: repeatElement(0, count: bufferSize))
            XCTAssertEqual(writer.bufferedBytes, 0)

            // Write just under a buffer.
            try await writer.write(contentsOf: repeatElement(1, count: bufferSize - 1))
            XCTAssertEqual(writer.bufferedBytes, bufferSize - 1)

            // Try to read the as-yet-unwritten bytes.
            let emptyChunk = try await file.readChunk(
                fromAbsoluteOffset: Int64(bufferSize),
                length: .bytes(Int64(bufferSize - 1))
            )
            XCTAssertEqual(emptyChunk.readableBytes, 0)

            // Write one more byte to flush out the buffer.
            try await writer.write(contentsOf: repeatElement(1, count: 1))
            XCTAssertEqual(writer.bufferedBytes, 0)

            // Try to read now that the bytes have been finished.
            let chunk = try await file.readChunk(
                fromAbsoluteOffset: Int64(bufferSize),
                length: .bytes(Int64(bufferSize))
            )
            XCTAssertEqual(chunk, ByteBuffer(repeating: 1, count: bufferSize))
        }
    }

    func testBufferedWriterAsyncSequenceOfBytes() async throws {
        let fs = FileSystem.shared
        let path = try await fs.temporaryFilePath()

        try await fs.withFileHandle(
            forReadingAndWritingAt: path,
            options: .newFile(replaceExisting: false)
        ) { file in
            let bufferSize = 8192
            var writer = file.bufferedWriter(capacity: .bytes(Int64(bufferSize)))
            XCTAssertEqual(writer.bufferedBytes, 0)

            let streamOfBytes = AsyncStream(UInt8.self) { continuation in
                for _ in 0..<16384 {
                    continuation.yield(0)
                }
                continuation.finish()
            }

            var written = try await writer.write(contentsOf: streamOfBytes)
            XCTAssertEqual(written, 16384)
            XCTAssertEqual(writer.bufferedBytes, 0)

            let streamOfChunks = AsyncStream([UInt8].self) { continuation in
                for _ in stride(from: 0, to: 16384, by: 1024) {
                    continuation.yield(Array(repeating: 0, count: 1024))
                }
                continuation.finish()
            }

            written = try await writer.write(contentsOf: streamOfChunks)
            XCTAssertEqual(written, 16384)
            XCTAssertEqual(writer.bufferedBytes, 0)

            let bytes = try await file.readToEnd(maximumSizeAllowed: .bytes(1024 * 1024))
            XCTAssertEqual(bytes.readableBytes, 16384 * 2)
            XCTAssertTrue(bytes.readableBytesView.allSatisfy { $0 == 0 })
        }
    }

    func testBufferedWriterManualFlushing() async throws {
        let fs = FileSystem.shared
        let path = try await fs.temporaryFilePath()

        try await fs.withFileHandle(
            forReadingAndWritingAt: path,
            options: .newFile(replaceExisting: false)
        ) { file in
            var writer = file.bufferedWriter(capacity: .bytes(1024))
            try await writer.write(contentsOf: Array(repeating: 0, count: 128))
            XCTAssertEqual(writer.bufferedBytes, 128)

            try await writer.flush()
            XCTAssertEqual(writer.bufferedBytes, 0)
        }
    }

    func testBufferedWriterReclaimsStorageAfterLargeWrite() async throws {
        let fs = FileSystem.shared
        let path = try await fs.temporaryFilePath()

        try await fs.withFileHandle(
            forReadingAndWritingAt: path,
            options: .newFile(replaceExisting: false)
        ) { file in
            let bufferSize = 128
            var writer = file.bufferedWriter(capacity: .bytes(Int64(bufferSize)))
            XCTAssertEqual(writer.bufferCapacity, 0)

            // Fill up the buffer. The capacity should be >= the buffer size.
            try await writer.write(contentsOf: Array(repeating: 0, count: bufferSize))
            XCTAssertEqual(writer.bufferedBytes, 0)
            XCTAssertGreaterThanOrEqual(writer.bufferCapacity, bufferSize)

            // Writes which take its internal buffer capacity over double its configured capacity
            // will result in memory being reclaimed.
            let doubleSize = bufferSize * 2
            try await writer.write(contentsOf: Array(repeating: 1, count: doubleSize + 1))
            XCTAssertEqual(writer.bufferedBytes, 0)
            XCTAssertEqual(writer.bufferCapacity, 0)
        }
    }
}
#endif
