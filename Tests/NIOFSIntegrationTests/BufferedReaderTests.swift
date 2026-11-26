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
    override func setUpWithError() throws {
        #if os(Windows)
        throw XCTSkip("The NIOFileSystem family is not yet functional on Windows")
        #endif
    }

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

    // These tests use FIFOs and pipes, which are created with POSIX calls that are unavailable on Windows.
    #if !os(Windows)
    func testBufferedReaderOnFIFOWithSplitWrites() async throws {
        let fifoPath = try await self.makeTemporaryFIFO()

        try await withFIFOPeer(at: fifoPath) { peer in
            try peer.withOpenFIFO(.write) { fd in
                try peer.writeAll(fd, ByteBuffer(string: "hello "))
                try peer.waitForRelease()
                try peer.writeAll(fd, ByteBuffer(string: "world\n"))
            }
        } test: { peer in
            try await FileSystem.shared.withFileHandle(forReadingAt: NIOFilePath(fifoPath)) { handle in
                var reader = handle.bufferedReader()

                // The peer has only written part of what it will write. A read which is shorter than
                // we asked for isn't the end of the file.
                let first = try await reader.read(.bytes(3))
                XCTAssertEqual(String(buffer: first), "hel")

                peer.release()

                let (bytes, readEOF) = try await reader.read(while: { $0 != UInt8(ascii: "\n") })
                XCTAssertEqual(String(buffer: bytes), "lo world")
                XCTAssertFalse(readEOF)

                // The newline remains, and the peer then closes its end.
                let newline = try await reader.read(.bytes(64))
                XCTAssertEqual(String(buffer: newline), "\n")

                let (rest, restReadEOF) = try await reader.read(while: { _ in true })
                XCTAssertEqual(rest.readableBytes, 0)
                XCTAssertTrue(restReadEOF)
            }
        }
    }

    func testBufferedReaderOnPipeWithSplitWrites() async throws {
        try await withPipePeer(peerEnd: .write) { peer, fd in
            try peer.writeAll(fd, ByteBuffer(string: "hello "))
            try peer.waitForRelease()
            try peer.writeAll(fd, ByteBuffer(string: "world\n"))
        } test: { peer, path in
            try await FileSystem.shared.withFileHandle(forReadingAt: NIOFilePath(path)) { handle in
                // The reader relies on a pipe being reported as a FIFO to know that it can't seek.
                let info = try await handle.info()
                XCTAssertEqual(info.type, .fifo)

                var reader = handle.bufferedReader()

                // The peer has only written part of what it will write. A read which is shorter than
                // we asked for isn't the end of the file.
                let first = try await reader.read(.bytes(3))
                XCTAssertEqual(String(buffer: first), "hel")

                peer.release()

                let (bytes, readEOF) = try await reader.read(while: { $0 != UInt8(ascii: "\n") })
                XCTAssertEqual(String(buffer: bytes), "lo world")
                XCTAssertFalse(readEOF)

                // The newline remains, and the peer then closes its end.
                let (rest, restReadEOF) = try await reader.read(while: { _ in true })
                XCTAssertEqual(String(buffer: rest), "\n")
                XCTAssertTrue(restReadEOF)
            }
        }
    }

    func testBufferedReaderDropOnFIFOConsumesBytes() async throws {
        let fifoPath = try await self.makeTemporaryFIFO()

        try await withFIFOPeer(at: fifoPath) { peer in
            try peer.withOpenFIFO(.write) { fd in
                try peer.writeAll(fd, ByteBuffer(string: "0123456789ABCDEF"))
            }
        } test: { peer in
            try await FileSystem.shared.withFileHandle(forReadingAt: NIOFilePath(fifoPath)) { handle in
                var reader = handle.bufferedReader(capacity: .bytes(4))

                let head = try await reader.read(.bytes(2))
                XCTAssertEqual(String(buffer: head), "01")

                // This is more than the reader has buffered so some of the bytes to drop must be read
                // from the FIFO and thrown away: there's no way to skip ahead by changing the offset.
                try await reader.drop(10)

                let tail = try await reader.read(.bytes(2))
                XCTAssertEqual(String(buffer: tail), "CD")
            }
        }
    }

    func testBufferedReaderOnFIFOWithNonZeroInitialOffsetThrows() async throws {
        let fifoPath = try await self.makeTemporaryFIFO()

        try await withFIFOPeer(at: fifoPath) { peer in
            try peer.withOpenFIFO(.write) { fd in
                try peer.waitForRelease()
            }
        } test: { peer in
            try await FileSystem.shared.withFileHandle(forReadingAt: NIOFilePath(fifoPath)) { handle in
                var reader = handle.bufferedReader(startingAtAbsoluteOffset: 5)

                await XCTAssertThrowsFileSystemErrorAsync {
                    try await reader.read(.bytes(1))
                } onError: { error in
                    XCTAssertEqual(error.code, .unsupported)
                }

                peer.release()
            }
        }
    }

    func testBufferedReaderDropOnFIFOWithNonZeroInitialOffsetThrows() async throws {
        let fifoPath = try await self.makeTemporaryFIFO()

        try await withFIFOPeer(at: fifoPath) { peer in
            try peer.withOpenFIFO(.write) { fd in
                try peer.waitForRelease()
            }
        } test: { peer in
            try await FileSystem.shared.withFileHandle(forReadingAt: NIOFilePath(fifoPath)) { handle in
                var reader = handle.bufferedReader(startingAtAbsoluteOffset: 5)

                // Dropping before anything has been read can't skip ahead in an unseekable file.
                await XCTAssertThrowsFileSystemErrorAsync {
                    try await reader.drop(10)
                } onError: { error in
                    XCTAssertEqual(error.code, .unsupported)
                }

                peer.release()
            }
        }
    }

    func testBufferedReaderReadReturnsWhatIsAvailableOnFIFO() async throws {
        let fifoPath = try await self.makeTemporaryFIFO()

        // The peer writes less than will be asked for, then stays connected without writing anything else:
        // a further read of the FIFO blocks until the peer is released.
        try await withFIFOPeer(at: fifoPath) { peer in
            try peer.withOpenFIFO(.write) { fd in
                try peer.writeAll(fd, ByteBuffer(string: "abc"))
                try peer.waitForRelease(timeout: .seconds(10))
            }
        } test: { peer in
            try await FileSystem.shared.withFileHandle(forReadingAt: NIOFilePath(fifoPath)) { handle in
                var reader = handle.bufferedReader()

                // The reader returns the bytes which are available. A short result doesn't mean the end of
                // the file, so it mustn't wait for the 61 other bytes.
                let start = NIODeadline.now()
                let bytes = try await reader.read(.bytes(64))
                let elapsed = NIODeadline.now() - start
                XCTAssertEqual(String(buffer: bytes), "abc")
                XCTAssertLessThan(elapsed, .seconds(2), "Reading took \(elapsed)")

                peer.release()
            }
        }
    }

    func testBufferedReaderDropPastEndOfFileOnFIFO() async throws {
        let fifoPath = try await self.makeTemporaryFIFO()

        try await withFIFOPeer(at: fifoPath) { peer in
            try peer.withOpenFIFO(.write) { fd in
                try peer.writeAll(fd, ByteBuffer(string: "hello"))
            }
        } test: { peer in
            try await FileSystem.shared.withFileHandle(forReadingAt: NIOFilePath(fifoPath)) { handle in
                var reader = handle.bufferedReader()

                // There are fewer bytes than are being dropped: dropping stops at the end of the file.
                try await reader.drop(100)

                let (bytes, readEOF) = try await reader.read(while: { _ in true })
                XCTAssertEqual(bytes.readableBytes, 0)
                XCTAssertTrue(readEOF)
            }
        }
    }

    func testBufferedReaderDropWhileAcrossSplitWritesOnFIFO() async throws {
        let fifoPath = try await self.makeTemporaryFIFO()

        try await withFIFOPeer(at: fifoPath) { peer in
            try peer.withOpenFIFO(.write) { fd in
                try peer.writeAll(fd, ByteBuffer(string: "aaa"))
                try peer.waitForRelease()
                try peer.writeAll(fd, ByteBuffer(string: "aab"))
            }
        } test: { peer in
            try await FileSystem.shared.withFileHandle(forReadingAt: NIOFilePath(fifoPath)) { handle in
                var reader = handle.bufferedReader()

                let first = try await reader.read(.bytes(1))
                XCTAssertEqual(String(buffer: first), "a")

                peer.release()

                // The predicate holds for everything which has been written so far, and for the start of
                // what the peer writes next.
                try await reader.drop(while: { $0 == UInt8(ascii: "a") })

                let rest = try await reader.read(.bytes(64))
                XCTAssertEqual(String(buffer: rest), "b")
            }
        }
    }
    #endif  // !os(Windows)

    #if os(Linux)
    func testBufferedReaderReadsLinesOfProcFile() async throws {
        // Procfs files return no more than about a page for each read. A short read isn't the end of the file,
        // and the file is much larger than a page: a test process has far more memory mappings than fit in one.
        try await FileSystem.shared.withFileHandle(forReadingAt: "/proc/self/maps") { handle in
            var reader = handle.bufferedReader()
            var byteCount = 0
            while true {
                let (line, readEOF) = try await reader.read(while: { $0 != UInt8(ascii: "\n") })
                if readEOF {
                    // The file ends with a newline, so nothing follows the last one.
                    XCTAssertEqual(line.readableBytes, 0, "The last line is incomplete")
                    break
                }
                byteCount += line.readableBytes + 1
                try await reader.drop(1)
            }
            XCTAssertGreaterThan(byteCount, 4096)
        }
    }
    #endif  // os(Linux)
}
