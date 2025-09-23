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

import NIOCore
import NIOFS
import XCTest

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class ConvenienceTests: XCTestCase {
    static let fs = FileSystem.shared

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
