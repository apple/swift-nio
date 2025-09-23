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
final class BufferedReaderTests: XCTestCase {
    func testBufferedReaderSizeAndCapacity() async throws {
        let fs = FileSystem.shared
        try await fs.withFileHandle(forReadingAt: #filePath) { handle in
            var reader = handle.bufferedReader(capacity: .bytes(128 * 1024))
            XCTAssertEqual(reader.count, 0)
            XCTAssertEqual(reader.capacity, 128 * 1024)

            let byte = try await reader.read(.bytes(1))
            XCTAssertEqual(byte.readableBytes, 1)

            // Buffer should be non-empty; there's more than one byte in this file.
            XCTAssertGreaterThan(reader.count, 0)
            // It should be no greater than the buffer capacity, however.
            XCTAssertLessThanOrEqual(reader.count, reader.capacity)
        }
    }

    func testBufferedReaderReadFixedSize() async throws {
        let fs = FileSystem.shared
        let path = try await fs.temporaryFilePath()

        try await fs.withFileHandle(
            forWritingAt: path,
            options: .newFile(replaceExisting: false)
        ) { handle in
            var writer = handle.bufferedWriter()
            try await writer.write(contentsOf: repeatElement(0, count: 1024 * 1024))
            try await writer.flush()
        }

        try await fs.withFileHandle(forReadingAt: path) { handle in
            var reader = handle.bufferedReader()
            let allTheBytes = try await reader.read(.bytes(1024 * 1024))
            XCTAssertEqual(allTheBytes.readableBytes, 1024 * 1024)

            let noBytes = try await reader.read(.bytes(1024))
            XCTAssertEqual(noBytes.readableBytes, 0)
        }
    }

    func testBufferedReaderMultipleReads() async throws {
        let fs = FileSystem.shared
        let path = try await fs.temporaryFilePath()

        try await fs.withFileHandle(
            forWritingAt: path,
            options: .newFile(replaceExisting: false)
        ) { handle in
            var writer = handle.bufferedWriter()
            try await writer.write(contentsOf: repeatElement(0, count: 1024 * 1024))
            try await writer.flush()
        }

        try await fs.withFileHandle(forReadingAt: path) { handle in
            var reader = handle.bufferedReader()
            var allTheBytes = [UInt8]()

            while true {
                let byte = try await reader.read(.bytes(100))
                if byte.readableBytes == 0 { break }
                allTheBytes.append(contentsOf: byte.readableBytesView)
            }

            XCTAssertEqual(allTheBytes.count, 1024 * 1024)
        }
    }

    func testBufferedReaderReadingShort() async throws {
        let fs = FileSystem.shared
        try await fs.withFileHandle(forReadingAt: #filePath) { handle in
            var reader = handle.bufferedReader(capacity: .bytes(128))
            var buffer = ByteBuffer()
            while true {
                let chunk = try await reader.read(.bytes(128))
                buffer.writeImmutableBuffer(chunk)
                if chunk.readableBytes < 128 { break }
            }

            let info = try await handle.info()
            XCTAssertEqual(Int64(buffer.readableBytes), info.size)
        }
    }

    func testBufferedReaderReadWhile() async throws {
        let fs = FileSystem.shared
        let path = try await fs.temporaryFilePath()

        try await fs.withFileHandle(
            forWritingAt: path,
            options: .newFile(replaceExisting: false)
        ) { handle in
            var writer = handle.bufferedWriter()
            for byte in UInt8.min...UInt8.max {
                try await writer.write(contentsOf: repeatElement(byte, count: 1024))
            }
            try await writer.flush()
        }

        try await fs.withFileHandle(forReadingAt: path) { handle in
            var reader = handle.bufferedReader()
            let (zeros, isEOFZeros) = try await reader.read { $0 == 0 }
            XCTAssertEqual(zeros, ByteBuffer(bytes: Array(repeating: 0, count: 1024)))
            XCTAssertFalse(isEOFZeros)

            let (onesAndTwos, isEOFOnesAndTwos) = try await reader.read { $0 < 3 }
            var expectedOnesAndTwos = ByteBuffer()
            expectedOnesAndTwos.writeRepeatingByte(1, count: 1024)
            expectedOnesAndTwos.writeRepeatingByte(2, count: 1024)

            XCTAssertEqual(onesAndTwos, expectedOnesAndTwos)
            XCTAssertFalse(isEOFOnesAndTwos)

            let (threesThroughNines, isEOFThreesThroughNines) = try await reader.read { $0 < 10 }
            var expectedThreesThroughNines = ByteBuffer()
            for byte in UInt8(3)...9 {
                expectedThreesThroughNines.writeRepeatingByte(byte, count: 1024)
            }
            XCTAssertEqual(threesThroughNines, expectedThreesThroughNines)
            XCTAssertFalse(isEOFThreesThroughNines)

            let (theRest, isEOFTheRest) = try await reader.read { _ in true }
            XCTAssertEqual(theRest.readableBytes, 246 * 1024)
            XCTAssertTrue(isEOFTheRest)
        }
    }

    func testBufferedReaderDropFixedSize() async throws {
        let fs = FileSystem.shared
        let path = try await fs.temporaryFilePath()

        try await fs.withFileHandle(
            forWritingAt: path,
            options: .newFile(replaceExisting: false)
        ) { handle in
            var writer = handle.bufferedWriter()
            for byte in UInt8.min...UInt8.max {
                try await writer.write(contentsOf: repeatElement(byte, count: 1000))
            }
            try await writer.flush()
        }

        try await fs.withFileHandle(forReadingAt: path) { handle in
            var reader = handle.bufferedReader()
            try await reader.drop(1000)
            let ones = try await reader.read(.bytes(1000))
            XCTAssertEqual(ones, ByteBuffer(repeating: 1, count: 1000))

            try await reader.drop(1500)
            let threes = try await reader.read(.bytes(500))
            XCTAssertEqual(threes, ByteBuffer(repeating: 3, count: 500))

            // More than remains in the file.
            try await reader.drop(1_000_000)
            let empty = try await reader.read(.bytes(1000))
            XCTAssertEqual(empty.readableBytes, 0)
        }
    }

    func testBufferedReaderDropWhile() async throws {
        let fs = FileSystem.shared
        let path = try await fs.temporaryFilePath()

        try await fs.withFileHandle(
            forWritingAt: path,
            options: .newFile(replaceExisting: false)
        ) { handle in
            var writer = handle.bufferedWriter()
            for byte in UInt8.min...UInt8.max {
                try await writer.write(contentsOf: repeatElement(byte, count: 1024))
            }
            try await writer.flush()
        }

        try await fs.withFileHandle(forReadingAt: path) { handle in
            var reader = handle.bufferedReader()
            try await reader.drop(while: { $0 < 255 })
            let bytes = try await reader.read(.bytes(1024))
            XCTAssertEqual(bytes, ByteBuffer(repeating: 255, count: 1024))

            let empty = try await reader.read(.bytes(1))
            XCTAssertEqual(empty.readableBytes, 0)
        }
    }

    func testBufferedReaderReadingText() async throws {
        let fs = FileSystem.shared
        let path = try await fs.temporaryFilePath()

        try await fs.withFileHandle(
            forWritingAt: path,
            options: .newFile(replaceExisting: false)
        ) { handle in
            let text = """
                Here's to the crazy ones, the misfits, the rebels, the troublemakers, \
                the round pegs in the square holes, the ones who see things differently.
                """

            var writer = handle.bufferedWriter()
            try await writer.write(contentsOf: text.utf8)
            try await writer.flush()
        }

        try await fs.withFileHandle(forReadingAt: path) { file in
            var reader = file.bufferedReader()
            var words = [String]()

            func isWordIsh(_ byte: UInt8) -> Bool {
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"),
                    UInt8(ascii: "A")...UInt8(ascii: "Z"),
                    UInt8(ascii: "'"):
                    return true
                default:
                    return false
                }
            }

            repeat {
                // Gobble up whitespace etc..
                try await reader.drop(while: { !isWordIsh($0) })
                // Read the next word.
                var (characters, _) = try await reader.read(while: isWordIsh(_:))

                if characters.readableBytes == 0 {
                    break  // Done.
                } else {
                    words.append(characters.readString(length: characters.readableBytes)!)
                }
            } while true

            let expected: [String] = [
                "Here's",
                "to",
                "the",
                "crazy",
                "ones",
                "the",
                "misfits",
                "the",
                "rebels",
                "the",
                "troublemakers",
                "the",
                "round",
                "pegs",
                "in",
                "the",
                "square",
                "holes",
                "the",
                "ones",
                "who",
                "see",
                "things",
                "differently",
            ]

            XCTAssertEqual(words, expected)
        }
    }
}
