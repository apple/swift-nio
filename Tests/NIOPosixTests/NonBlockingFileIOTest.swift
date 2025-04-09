//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics
import CNIOLinux
import NIOConcurrencyHelpers
import NIOCore
import XCTest

@testable import NIOPosix

class NonBlockingFileIOTest: XCTestCase {
    private var group: EventLoopGroup!
    private var eventLoop: EventLoop!
    private var allocator: ByteBufferAllocator!
    private var fileIO: NonBlockingFileIO!
    private var threadPool: NIOThreadPool!

    override func setUp() {
        super.setUp()
        self.allocator = ByteBufferAllocator()
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.threadPool = NIOThreadPool(numberOfThreads: 6)
        self.threadPool.start()
        self.fileIO = NonBlockingFileIO(threadPool: threadPool)
        self.eventLoop = self.group.next()
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.group?.syncShutdownGracefully())
        XCTAssertNoThrow(try self.threadPool?.syncShutdownGracefully())
        self.group = nil
        self.eventLoop = nil
        self.allocator = nil
        self.threadPool = nil
        self.fileIO = nil
        super.tearDown()
    }

    struct Counter: Sendable {
        private let _value: NIOLockedValueBox<Int>

        init(_ initialValue: Int) {
            self._value = NIOLockedValueBox(initialValue)
        }

        var value: Int {
            get {
                self._value.withLockedValue { $0 }
            }
            nonmutating set {
                self._value.withLockedValue { $0 = newValue }
            }
        }

        func increment(by delta: Int = 1) {
            self._value.withLockedValue { $0 += delta }
        }
    }

    func testBasicFileIOWorks() throws {
        let content = "hello"
        try withTemporaryFile(content: content) { (fileHandle, _) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: 5)
            var buf = try self.fileIO.read(
                fileRegion: fr,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            ).wait()
            XCTAssertEqual(content.utf8.count, buf.readableBytes)
            XCTAssertEqual(content, buf.readString(length: buf.readableBytes))
        }
    }

    func testOffsetWorks() throws {
        let content = "hello"
        try withTemporaryFile(content: content) { (fileHandle, _) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 3, endIndex: 5)
            var buf = try self.fileIO.read(
                fileRegion: fr,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            ).wait()
            XCTAssertEqual(2, buf.readableBytes)
            XCTAssertEqual("lo", buf.readString(length: buf.readableBytes))
        }
    }

    func testOffsetBeyondEOF() throws {
        let content = "hello"
        try withTemporaryFile(content: content) { (fileHandle, _) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 3000, endIndex: 3001)
            var buf = try self.fileIO.read(
                fileRegion: fr,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            ).wait()
            XCTAssertEqual(0, buf.readableBytes)
            XCTAssertEqual("", buf.readString(length: buf.readableBytes))
        }
    }

    func testEmptyReadWorks() throws {
        try withTemporaryFile { (fileHandle, _) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: 0)
            let buf = try self.fileIO.read(
                fileRegion: fr,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            ).wait()
            XCTAssertEqual(0, buf.readableBytes)
        }
    }

    func testReadingShortWorks() throws {
        let content = "hello"
        try withTemporaryFile(content: "hello") { (fileHandle, _) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: 10)
            var buf = try self.fileIO.read(
                fileRegion: fr,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            ).wait()
            XCTAssertEqual(content.utf8.count, buf.readableBytes)
            XCTAssertEqual(content, buf.readString(length: buf.readableBytes))
        }
    }

    func testDoesNotBlockTheThreadOrEventLoop() throws {
        var innerError: Error? = nil
        try withPipe { readFH, writeFH in
            let bufferFuture = self.fileIO.read(
                fileHandle: readFH,
                byteCount: 10,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            )

            do {
                try self.eventLoop.submit {
                    try writeFH.withUnsafeFileDescriptor { writeFD in
                        _ = try Posix.write(descriptor: writeFD, pointer: "X", size: 1)
                    }
                    try writeFH.close()
                }.wait()
                var buf = try bufferFuture.wait()
                XCTAssertEqual(1, buf.readableBytes)
                XCTAssertEqual("X", buf.readString(length: buf.readableBytes))
            } catch {
                innerError = error
            }
            return [readFH]
        }
        XCTAssertNil(innerError)
    }

    func testGettingErrorWhenEventLoopGroupIsShutdown() throws {
        self.threadPool.shutdownGracefully(queue: .global()) { err in
            XCTAssertNil(err)
        }

        try withPipe { readFH, writeFH in
            XCTAssertThrowsError(
                try self.fileIO.read(
                    fileHandle: readFH,
                    byteCount: 1,
                    allocator: self.allocator,
                    eventLoop: self.eventLoop
                ).wait()
            ) { error in
                XCTAssertTrue(error is NIOThreadPoolError.ThreadPoolInactive)
            }
            return [readFH, writeFH]
        }
    }

    func testChunkReadingWorks() throws {
        let content = "hello"
        let contentBytes = Array(content.utf8)
        let numCalls = Counter(0)
        try withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: 5)
            try self.fileIO.readChunked(
                fileRegion: fr,
                chunkSize: 1,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            ) { [eventLoop = self.eventLoop] buf in
                var buf = buf
                XCTAssertTrue(eventLoop!.inEventLoop)
                XCTAssertEqual(1, buf.readableBytes)
                XCTAssertEqual(contentBytes[numCalls.value], buf.readBytes(length: 1)?.first!)
                numCalls.increment()
                return eventLoop!.makeSucceededFuture(())
            }.wait()
        }
        XCTAssertEqual(content.utf8.count, numCalls.value)
    }

    func testChunkReadingCanBeAborted() throws {
        enum DummyError: Error { case dummy }
        let content = "hello"
        let contentBytes = Array(content.utf8)
        let numCalls = Counter(0)
        try withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: 5)
            XCTAssertThrowsError(
                try self.fileIO.readChunked(
                    fileRegion: fr,
                    chunkSize: 1,
                    allocator: self.allocator,
                    eventLoop: self.eventLoop
                ) { [eventLoop = self.eventLoop] buf in
                    var buf = buf
                    XCTAssertTrue(eventLoop!.inEventLoop)
                    XCTAssertEqual(1, buf.readableBytes)
                    XCTAssertEqual(contentBytes[numCalls.value], buf.readBytes(length: 1)?.first!)
                    numCalls.increment()
                    return eventLoop!.makeFailedFuture(DummyError.dummy)
                }.wait()
            ) { error in
                XCTAssertEqual(.dummy, error as? DummyError)
            }
        }
        XCTAssertEqual(1, numCalls.value)
    }

    func testChunkReadingWorksForIncrediblyLongChain() throws {
        let content = String(repeating: "X", count: 20 * 1024)
        let numCalls = Counter(0)
        let expectedByte = content.utf8.first!
        try withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            try self.fileIO.readChunked(
                fileHandle: fileHandle,
                fromOffset: 0,
                byteCount: content.utf8.count,
                chunkSize: 1,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            ) { [eventLoop = self.eventLoop] buf in
                XCTAssertTrue(eventLoop!.inEventLoop)
                XCTAssertEqual(1, buf.readableBytes)
                XCTAssertEqual(expectedByte, buf.readableBytesView.first)
                numCalls.increment()
                return eventLoop!.makeSucceededFuture(())
            }.wait()
        }
        XCTAssertEqual(content.utf8.count, numCalls.value)
    }

    func testReadingDifferentChunkSize() throws {
        let content = "0123456789"
        let numCalls = Counter(0)
        try withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: content.utf8.count)
            try self.fileIO.readChunked(
                fileRegion: fr,
                chunkSize: 2,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            ) { [eventLoop = self.eventLoop] buf in
                var buf = buf
                XCTAssertTrue(eventLoop!.inEventLoop)
                XCTAssertEqual(2, buf.readableBytes)
                let calls = numCalls.value
                XCTAssertEqual(Array("\(calls*2)\(calls*2 + 1)".utf8), buf.readBytes(length: 2)!)
                numCalls.increment()
                return eventLoop!.makeSucceededFuture(())
            }.wait()
        }
        XCTAssertEqual(content.utf8.count / 2, numCalls.value)
    }

    func testReadDoesNotReadShort() throws {
        var innerError: Error? = nil
        try withPipe { readFH, writeFH in
            let bufferFuture = self.fileIO.read(
                fileHandle: readFH,
                byteCount: 10,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            )
            do {
                for i in 0..<10 {
                    // this construction will cause 'read' to repeatedly return with 1 byte read
                    try self.eventLoop.scheduleTask(in: .milliseconds(50)) {
                        try writeFH.withUnsafeFileDescriptor { writeFD in
                            _ = try Posix.write(descriptor: writeFD, pointer: "\(i)", size: 1)
                        }
                    }.futureResult.wait()
                }
                try writeFH.close()

                var buf = try bufferFuture.wait()
                XCTAssertEqual(10, buf.readableBytes)
                XCTAssertEqual("0123456789", buf.readString(length: buf.readableBytes))
            } catch {
                innerError = error
            }
            return [readFH]
        }
        XCTAssertNil(innerError)
    }

    func testChunkReadingWhereByteCountIsNotAChunkSizeMultiplier() throws {
        let content = "prefix-12345-suffix"
        let allBytesActual = NIOLockedValueBox("")
        let allBytesExpected = String(content.dropFirst(7).dropLast(7))
        let numCalls = Counter(0)
        try withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 7, endIndex: 12)
            try self.fileIO.readChunked(
                fileRegion: fr,
                chunkSize: 3,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            ) { [eventLoop = self.eventLoop] buf in
                var buf = buf
                XCTAssertTrue(eventLoop!.inEventLoop)
                allBytesActual.withLockedValue {
                    $0 += buf.readString(length: buf.readableBytes) ?? "WRONG"
                }
                numCalls.increment()
                return eventLoop!.makeSucceededFuture(())
            }.wait()
        }
        XCTAssertEqual(allBytesExpected, allBytesActual.withLockedValue { $0 })
        XCTAssertEqual(2, numCalls.value)
    }

    func testReadMoreThanIntMaxBytesDoesntThrow() throws {
        try XCTSkipIf(MemoryLayout<size_t>.size == MemoryLayout<UInt32>.size)
        // here we try to read way more data back from the file than it contains but it serves the purpose
        // even on a small file the OS will return EINVAL if you try to read > INT_MAX bytes
        try withTemporaryFile(
            content: "some-dummy-content",
            { (filehandle, path) -> Void in
                let content = try self.fileIO.read(
                    fileHandle: filehandle,
                    // There's a runtime check above, use overflow addition to stop the compilation
                    // from failing on 32-bit platforms.
                    byteCount: Int(Int32.max) &+ 10,
                    allocator: .init(),
                    eventLoop: self.eventLoop
                ).wait()
                XCTAssertEqual(String(buffer: content), "some-dummy-content")
            }
        )
    }

    func testChunkedReadDoesNotReadShort() throws {
        var innerError: Error? = nil
        try withPipe { readFH, writeFH in
            let allBytes = NIOLockedValueBox("")
            let f = self.fileIO.readChunked(
                fileHandle: readFH,
                byteCount: 10,
                chunkSize: 3,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            ) { [eventLoop = self.eventLoop] buf in
                var buf = buf
                let byteCount = allBytes.withLockedValue { $0.utf8.count }
                if byteCount == 9 {
                    XCTAssertEqual(1, buf.readableBytes)
                } else {
                    XCTAssertEqual(3, buf.readableBytes)
                }
                allBytes.withLockedValue {
                    $0.append(buf.readString(length: buf.readableBytes) ?? "THIS IS WRONG")
                }
                return eventLoop!.makeSucceededFuture(())
            }

            do {
                for i in 0..<10 {
                    // this construction will cause 'read' to repeatedly return with 1 byte read
                    try self.eventLoop.scheduleTask(in: .milliseconds(50)) {
                        try writeFH.withUnsafeFileDescriptor { writeFD in
                            _ = try Posix.write(descriptor: writeFD, pointer: "\(i)", size: 1)
                        }
                    }.futureResult.wait()
                }
                try writeFH.close()

                try f.wait()
                XCTAssertEqual("0123456789", allBytes.withLockedValue { $0 })
            } catch {
                innerError = error
            }
            return [readFH]
        }
        XCTAssertNil(innerError)
    }

    func testChunkSizeMoreThanTotal() throws {
        let content = "0123456789"
        let numCalls = Counter(0)
        try withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: 5)
            try self.fileIO.readChunked(
                fileRegion: fr,
                chunkSize: 10,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            ) { [eventLoop = self.eventLoop] buf in
                var buf = buf
                XCTAssertTrue(eventLoop!.inEventLoop)
                XCTAssertEqual(5, buf.readableBytes)
                XCTAssertEqual("01234", buf.readString(length: buf.readableBytes) ?? "bad")
                numCalls.increment()
                return eventLoop!.makeSucceededFuture(())
            }.wait()
        }
        XCTAssertEqual(1, numCalls.value)
    }

    func testFileRegionReadFromPipeFails() throws {
        try withPipe { readFH, writeFH in
            try! writeFH.withUnsafeFileDescriptor { writeFD in
                _ = try! Posix.write(descriptor: writeFD, pointer: "ABC", size: 3)
            }
            let fr = FileRegion(fileHandle: readFH, readerIndex: 1, endIndex: 2)
            XCTAssertThrowsError(
                try self.fileIO.readChunked(
                    fileRegion: fr,
                    chunkSize: 10,
                    allocator: self.allocator,
                    eventLoop: self.eventLoop
                ) { [eventLoop = self.eventLoop] buf in
                    XCTFail("this shouldn't have been called")
                    return eventLoop!.makeSucceededFuture(())
                }.wait()
            ) { error in
                XCTAssertEqual(ESPIPE, (error as? IOError)?.errnoCode)
            }
            return [readFH, writeFH]
        }
    }

    func testReadFromNonBlockingPipeFails() throws {
        try withPipe { readFH, writeFH in
            do {
                try readFH.withUnsafeFileDescriptor { readFD in
                    let flags = try Posix.fcntl(descriptor: readFD, command: F_GETFL, value: 0)
                    let ret = try Posix.fcntl(descriptor: readFD, command: F_SETFL, value: flags | O_NONBLOCK)
                    assert(ret == 0, "unexpectedly, fcntl(\(readFD), F_SETFL, O_NONBLOCK) returned \(ret)")
                }
                try self.fileIO.readChunked(
                    fileHandle: readFH,
                    byteCount: 10,
                    chunkSize: 10,
                    allocator: self.allocator,
                    eventLoop: self.eventLoop
                ) { [eventLoop = self.eventLoop] buf in
                    XCTFail("this shouldn't have been called")
                    return eventLoop!.makeSucceededFuture(())
                }.wait()
                XCTFail("succeeded and shouldn't have")
            } catch let e as NonBlockingFileIO.Error where e == NonBlockingFileIO.Error.descriptorSetToNonBlocking {
                // OK
            } catch {
                XCTFail("wrong error \(error) caught")
            }
            return [readFH, writeFH]
        }
    }

    func testSeekPointerIsSetToFront() throws {
        let content = "0123456789"
        let numCalls = Counter(0)
        try withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            try self.fileIO.readChunked(
                fileHandle: fileHandle,
                byteCount: content.utf8.count,
                chunkSize: 9,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            ) { [eventLoop = self.eventLoop] buf in
                var buf = buf
                numCalls.increment()
                XCTAssertTrue(eventLoop!.inEventLoop)
                if numCalls.value == 1 {
                    XCTAssertEqual(9, buf.readableBytes)
                    XCTAssertEqual("012345678", buf.readString(length: buf.readableBytes) ?? "bad")
                } else {
                    XCTAssertEqual(1, buf.readableBytes)
                    XCTAssertEqual("9", buf.readString(length: buf.readableBytes) ?? "bad")
                }
                return eventLoop!.makeSucceededFuture(())
            }.wait()
        }
        XCTAssertEqual(2, numCalls.value)
    }

    func testReadingFileSize() throws {
        try withTemporaryFile(content: "0123456789") { (fileHandle, _) -> Void in
            let size = try self.fileIO.readFileSize(
                fileHandle: fileHandle,
                eventLoop: eventLoop
            ).wait()
            XCTAssertEqual(size, 10)
        }
    }

    func testChangeFileSizeShrink() throws {
        try withTemporaryFile(content: "0123456789") { (fileHandle, _) -> Void in
            try self.fileIO.changeFileSize(
                fileHandle: fileHandle,
                size: 1,
                eventLoop: eventLoop
            ).wait()
            let fileRegion = try FileRegion(fileHandle: fileHandle)
            var buf = try self.fileIO.read(
                fileRegion: fileRegion,
                allocator: allocator,
                eventLoop: eventLoop
            ).wait()
            XCTAssertEqual("0", buf.readString(length: buf.readableBytes))
        }
    }

    func testChangeFileSizeGrow() throws {
        try withTemporaryFile(content: "0123456789") { (fileHandle, _) -> Void in
            try self.fileIO.changeFileSize(
                fileHandle: fileHandle,
                size: 100,
                eventLoop: eventLoop
            ).wait()
            let fileRegion = try FileRegion(fileHandle: fileHandle)
            var buf = try self.fileIO.read(
                fileRegion: fileRegion,
                allocator: allocator,
                eventLoop: eventLoop
            ).wait()
            let zeros = (1...90).map { _ in UInt8(0) }
            guard let bytes = buf.readBytes(length: buf.readableBytes)?.suffix(from: 10) else {
                XCTFail("readBytes(length:) should not be nil")
                return
            }
            XCTAssertEqual(zeros, Array(bytes))
        }
    }

    func testWriting() throws {
        var buffer = allocator.buffer(capacity: 3)
        buffer.writeStaticString("123")

        try withTemporaryFile(content: "") { (fileHandle, path) in
            try self.fileIO.write(
                fileHandle: fileHandle,
                buffer: buffer,
                eventLoop: self.eventLoop
            ).wait()
            let offset = try fileHandle.withUnsafeFileDescriptor {
                try Posix.lseek(descriptor: $0, offset: 0, whence: SEEK_SET)
            }
            XCTAssertEqual(offset, 0)

            let readBuffer = try self.fileIO.read(
                fileHandle: fileHandle,
                byteCount: 3,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            ).wait()
            XCTAssertEqual(readBuffer.getString(at: 0, length: 3), "123")
        }
    }

    func testWriteMultipleTimes() throws {
        var buffer = allocator.buffer(capacity: 3)
        buffer.writeStaticString("xxx")

        try withTemporaryFile(content: "AAA") { (fileHandle, path) in
            for i in 0..<3 {
                buffer.writeString("\(i)")
                try self.fileIO.write(
                    fileHandle: fileHandle,
                    buffer: buffer,
                    eventLoop: self.eventLoop
                ).wait()
            }
            let offset = try fileHandle.withUnsafeFileDescriptor {
                try Posix.lseek(descriptor: $0, offset: 0, whence: SEEK_SET)
            }
            XCTAssertEqual(offset, 0)

            let expectedOutput = "xxx0xxx01xxx012"
            let readBuffer = try self.fileIO.read(
                fileHandle: fileHandle,
                byteCount: expectedOutput.utf8.count,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            ).wait()
            XCTAssertEqual(expectedOutput, String(decoding: readBuffer.readableBytesView, as: Unicode.UTF8.self))
        }
    }

    func testWritingWithOffset() throws {
        var buffer = allocator.buffer(capacity: 3)
        buffer.writeStaticString("123")

        try withTemporaryFile(content: "hello") { (fileHandle, _) -> Void in
            try self.fileIO.write(
                fileHandle: fileHandle,
                toOffset: 1,
                buffer: buffer,
                eventLoop: eventLoop
            ).wait()
            let offset = try fileHandle.withUnsafeFileDescriptor {
                try Posix.lseek(descriptor: $0, offset: 0, whence: SEEK_SET)
            }
            XCTAssertEqual(offset, 0)

            var readBuffer = try self.fileIO.read(
                fileHandle: fileHandle,
                byteCount: 5,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            ).wait()
            XCTAssertEqual(5, readBuffer.readableBytes)
            XCTAssertEqual("h123o", readBuffer.readString(length: readBuffer.readableBytes))
        }
    }

    // This is undefined behavior and may cause different
    // results on other platforms. Please add #if:s according
    // to platform requirements.
    func testWritingBeyondEOF() throws {
        var buffer = allocator.buffer(capacity: 3)
        buffer.writeStaticString("123")

        try withTemporaryFile(content: "hello") { (fileHandle, _) -> Void in
            try self.fileIO.write(
                fileHandle: fileHandle,
                toOffset: 6,
                buffer: buffer,
                eventLoop: eventLoop
            ).wait()

            let fileRegion = try FileRegion(fileHandle: fileHandle)
            var buf = try self.fileIO.read(
                fileRegion: fileRegion,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            ).wait()
            XCTAssertEqual(9, buf.readableBytes)
            XCTAssertEqual("hello", buf.readString(length: 5))
            XCTAssertEqual([UInt8(0)], buf.readBytes(length: 1))
            XCTAssertEqual("123", buf.readString(length: buf.readableBytes))
        }
    }

    func testFileOpenWorks() throws {
        let content = "123"
        try withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            try self.fileIO.openFile(_deprecatedPath: path, eventLoop: self.eventLoop).flatMapThrowing { vals in
                let (fh, fr) = vals
                try fh.withUnsafeFileDescriptor { fd in
                    XCTAssertGreaterThanOrEqual(fd, 0)
                }
                XCTAssertTrue(fh.isOpen)
                XCTAssertEqual(0, fr.readerIndex)
                XCTAssertEqual(3, fr.endIndex)
                try fh.close()
            }.wait()
        }
    }

    func testFileOpenWorksWithEmptyFile() throws {
        let content = ""
        try withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            try self.fileIO.openFile(_deprecatedPath: path, eventLoop: self.eventLoop).flatMapThrowing { vals in
                let (fh, fr) = vals
                try fh.withUnsafeFileDescriptor { fd in
                    XCTAssertGreaterThanOrEqual(fd, 0)
                }
                XCTAssertTrue(fh.isOpen)
                XCTAssertEqual(0, fr.readerIndex)
                XCTAssertEqual(0, fr.endIndex)
                try fh.close()
            }.wait()
        }
    }

    func testFileOpenFails() throws {
        do {
            try self.fileIO.openFile(
                _deprecatedPath: "/dev/null/this/does/not/exist",
                eventLoop: self.eventLoop
            ).map { _ in }.wait()
            XCTFail("should've thrown")
        } catch let e as IOError where e.errnoCode == ENOTDIR {
            // OK
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testOpeningFilesForWriting() {
        XCTAssertNoThrow(
            try withTemporaryDirectory { dir in
                try self.fileIO!.openFile(
                    _deprecatedPath: "\(dir)/file",
                    mode: .write,
                    flags: .allowFileCreation(),
                    eventLoop: self.eventLoop
                ).wait().close()
            }
        )
    }

    func testOpeningFilesForWritingFailsIfWeDontAllowItExplicitly() {
        XCTAssertThrowsError(
            try withTemporaryDirectory { dir in
                try self.fileIO!.openFile(
                    _deprecatedPath: "\(dir)/file",
                    mode: .write,
                    flags: .default,
                    eventLoop: self.eventLoop
                ).wait().close()
            }
        ) { error in
            XCTAssertEqual(ENOENT, (error as? IOError)?.errnoCode)
        }
    }

    func testOpeningFilesForWritingDoesNotAllowReading() {
        XCTAssertNoThrow(
            try withTemporaryDirectory { dir in
                let fileHandle = try self.fileIO!.openFile(
                    _deprecatedPath: "\(dir)/file",
                    mode: .write,
                    flags: .allowFileCreation(),
                    eventLoop: self.eventLoop
                ).wait()
                defer {
                    try! fileHandle.close()
                }
                XCTAssertEqual(
                    -1,  // read must fail
                    try fileHandle.withUnsafeFileDescriptor { fd -> ssize_t in
                        var data: UInt8 = 0
                        return withUnsafeMutableBytes(of: &data) { ptr in
                            read(fd, ptr.baseAddress, ptr.count)
                        }
                    }
                )
            }
        )
    }

    func testOpeningFilesForWritingAndReading() {
        XCTAssertNoThrow(
            try withTemporaryDirectory { dir in
                let fileHandle = try self.fileIO!.openFile(
                    _deprecatedPath: "\(dir)/file",
                    mode: [.write, .read],
                    flags: .allowFileCreation(),
                    eventLoop: self.eventLoop
                ).wait()
                defer {
                    try! fileHandle.close()
                }
                XCTAssertEqual(
                    0,  // read should read EOF
                    try fileHandle.withUnsafeFileDescriptor { fd -> ssize_t in
                        var data: UInt8 = 0
                        return withUnsafeMutableBytes(of: &data) { ptr in
                            read(fd, ptr.baseAddress, ptr.count)
                        }
                    }
                )
            }
        )
    }

    func testOpeningFilesForWritingDoesNotImplyTruncation() {
        XCTAssertNoThrow(
            try withTemporaryDirectory { dir in
                // open 1 + write
                try {
                    let fileHandle = try self.fileIO!.openFile(
                        _deprecatedPath: "\(dir)/file",
                        mode: [.write, .read],
                        flags: .allowFileCreation(),
                        eventLoop: self.eventLoop
                    ).wait()
                    defer {
                        try! fileHandle.close()
                    }
                    try fileHandle.withUnsafeFileDescriptor { fd in
                        var data = UInt8(ascii: "X")
                        XCTAssertEqual(
                            IOResult<Int>.processed(1),
                            try withUnsafeBytes(of: &data) { ptr in
                                try Posix.write(descriptor: fd, pointer: ptr.baseAddress!, size: ptr.count)
                            }
                        )
                    }
                }()
                // open 2 + write again + read
                try {
                    let fileHandle = try self.fileIO!.openFile(
                        _deprecatedPath: "\(dir)/file",
                        mode: [.write, .read],
                        flags: .default,
                        eventLoop: self.eventLoop
                    ).wait()
                    defer {
                        try! fileHandle.close()
                    }
                    try fileHandle.withUnsafeFileDescriptor { fd in
                        try Posix.lseek(descriptor: fd, offset: 0, whence: SEEK_END)
                        var data = UInt8(ascii: "Y")
                        XCTAssertEqual(
                            IOResult<Int>.processed(1),
                            try withUnsafeBytes(of: &data) { ptr in
                                try Posix.write(descriptor: fd, pointer: ptr.baseAddress!, size: ptr.count)
                            }
                        )
                    }
                    XCTAssertEqual(
                        2,  // both bytes
                        try fileHandle.withUnsafeFileDescriptor { fd -> ssize_t in
                            var data: UInt16 = 0
                            try Posix.lseek(descriptor: fd, offset: 0, whence: SEEK_SET)
                            let readReturn = withUnsafeMutableBytes(of: &data) { ptr in
                                read(fd, ptr.baseAddress, ptr.count)
                            }
                            XCTAssertEqual(
                                UInt16(bigEndian: (UInt16(UInt8(ascii: "X")) << 8) | UInt16(UInt8(ascii: "Y"))),
                                data
                            )
                            return readReturn
                        }
                    )
                }()
            }
        )
    }

    func testOpeningFilesForWritingCanUseTruncation() {
        XCTAssertNoThrow(
            try withTemporaryDirectory { dir in
                // open 1 + write
                try {
                    let fileHandle = try self.fileIO!.openFile(
                        _deprecatedPath: "\(dir)/file",
                        mode: [.write, .read],
                        flags: .allowFileCreation(),
                        eventLoop: self.eventLoop
                    ).wait()
                    defer {
                        try! fileHandle.close()
                    }
                    try fileHandle.withUnsafeFileDescriptor { fd in
                        var data = UInt8(ascii: "X")
                        XCTAssertEqual(
                            IOResult<Int>.processed(1),
                            try withUnsafeBytes(of: &data) { ptr in
                                try Posix.write(descriptor: fd, pointer: ptr.baseAddress!, size: ptr.count)
                            }
                        )
                    }
                }()
                // open 2 (with truncation) + write again + read
                try {
                    let fileHandle = try self.fileIO!.openFile(
                        _deprecatedPath: "\(dir)/file",
                        mode: [.write, .read],
                        flags: .posix(flags: O_TRUNC, mode: 0),
                        eventLoop: self.eventLoop
                    ).wait()
                    defer {
                        try! fileHandle.close()
                    }
                    try fileHandle.withUnsafeFileDescriptor { fd in
                        try Posix.lseek(descriptor: fd, offset: 0, whence: SEEK_END)
                        var data = UInt8(ascii: "Y")
                        XCTAssertEqual(
                            IOResult<Int>.processed(1),
                            try withUnsafeBytes(of: &data) { ptr in
                                try Posix.write(descriptor: fd, pointer: ptr.baseAddress!, size: ptr.count)
                            }
                        )
                    }
                    XCTAssertEqual(
                        1,  // read should read just one byte because we truncated the file
                        try fileHandle.withUnsafeFileDescriptor { fd -> ssize_t in
                            var data: UInt16 = 0
                            try Posix.lseek(descriptor: fd, offset: 0, whence: SEEK_SET)
                            let readReturn = withUnsafeMutableBytes(of: &data) { ptr in
                                read(fd, ptr.baseAddress, ptr.count)
                            }
                            XCTAssertEqual(UInt16(bigEndian: UInt16(UInt8(ascii: "Y")) << 8), data)
                            return readReturn
                        }
                    )
                }()
            }
        )
    }

    func testReadFromOffset() {
        XCTAssertNoThrow(
            try withTemporaryFile(content: "hello world") { (fileHandle, path) in
                let buffer = self.fileIO.read(
                    fileHandle: fileHandle,
                    fromOffset: 6,
                    byteCount: 5,
                    allocator: ByteBufferAllocator(),
                    eventLoop: self.eventLoop
                )
                XCTAssertNoThrow(
                    try XCTAssertEqual(
                        "world",
                        String(
                            decoding: buffer.wait().readableBytesView,
                            as: Unicode.UTF8.self
                        )
                    )
                )
            }
        )
    }

    func testReadChunkedFromOffset() {
        XCTAssertNoThrow(
            try withTemporaryFile(content: "hello world") { (fileHandle, path) in
                let numberOfCalls = Counter(0)
                try self.fileIO.readChunked(
                    fileHandle: fileHandle,
                    fromOffset: 6,
                    byteCount: 5,
                    chunkSize: 2,
                    allocator: .init(),
                    eventLoop: self.eventLoop
                ) { [eventLoop = self.eventLoop] buffer in
                    numberOfCalls.increment()
                    switch numberOfCalls.value {
                    case 1:
                        XCTAssertEqual("wo", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
                    case 2:
                        XCTAssertEqual("rl", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
                    case 3:
                        XCTAssertEqual("d", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
                    default:
                        XCTFail()
                    }
                    return eventLoop!.makeSucceededFuture(())
                }.wait()
            }
        )
    }

    func testReadChunkedFromOffsetAfterEOFDeliversExactlyOneChunk() {
        let numberOfCalls = Counter(0)
        XCTAssertNoThrow(
            try withTemporaryFile(content: "hello world") { (fileHandle, path) in
                try self.fileIO.readChunked(
                    fileHandle: fileHandle,
                    fromOffset: 100,
                    byteCount: 5,
                    chunkSize: 2,
                    allocator: .init(),
                    eventLoop: self.eventLoop
                ) { [eventLoop = self.eventLoop] buffer in
                    numberOfCalls.increment()
                    XCTAssertEqual(1, numberOfCalls.value)
                    XCTAssertEqual(0, buffer.readableBytes)
                    return eventLoop!.makeSucceededFuture(())
                }.wait()
            }
        )
    }

    func testReadChunkedFromEOFDeliversExactlyOneChunk() {
        let numberOfCalls = Counter(0)
        XCTAssertNoThrow(
            try withTemporaryFile(content: "") { (fileHandle, path) in
                try self.fileIO.readChunked(
                    fileHandle: fileHandle,
                    byteCount: 5,
                    chunkSize: 2,
                    allocator: .init(),
                    eventLoop: self.eventLoop
                ) { [eventLoop = self.eventLoop] buffer in
                    numberOfCalls.increment()
                    XCTAssertEqual(1, numberOfCalls.value)
                    XCTAssertEqual(0, buffer.readableBytes)
                    return eventLoop!.makeSucceededFuture(())
                }.wait()
            }
        )
    }

    func testReadFromOffsetAfterEOFDeliversExactlyOneChunk() {
        XCTAssertNoThrow(
            try withTemporaryFile(content: "hello world") { (fileHandle, path) in
                XCTAssertEqual(
                    0,
                    try self.fileIO.read(
                        fileHandle: fileHandle,
                        fromOffset: 100,
                        byteCount: 5,
                        allocator: .init(),
                        eventLoop: self.eventLoop
                    ).wait().readableBytes
                )
            }
        )
    }

    func testReadFromEOFDeliversExactlyOneChunk() {
        XCTAssertNoThrow(
            try withTemporaryFile(content: "") { (fileHandle, path) in
                XCTAssertEqual(
                    0,
                    try self.fileIO.read(
                        fileHandle: fileHandle,
                        byteCount: 5,
                        allocator: .init(),
                        eventLoop: self.eventLoop
                    ).wait().readableBytes
                )
            }
        )
    }

    func testReadChunkedFromOffsetFileRegion() {
        XCTAssertNoThrow(
            try withTemporaryFile(content: "hello world") { (fileHandle, path) in
                let numberOfCalls = Counter(0)
                let fileRegion = FileRegion(fileHandle: fileHandle, readerIndex: 6, endIndex: 11)
                try self.fileIO.readChunked(
                    fileRegion: fileRegion,
                    chunkSize: 2,
                    allocator: .init(),
                    eventLoop: self.eventLoop
                ) { [eventLoop = self.eventLoop] buffer in
                    numberOfCalls.increment()
                    switch numberOfCalls.value {
                    case 1:
                        XCTAssertEqual("wo", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
                    case 2:
                        XCTAssertEqual("rl", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
                    case 3:
                        XCTAssertEqual("d", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
                    default:
                        XCTFail()
                    }
                    return eventLoop!.makeSucceededFuture(())
                }.wait()
            }
        )
    }

    func testReadManyChunks() {
        let numberOfChunks = 2_000
        XCTAssertNoThrow(
            try withTemporaryFile(
                content: String(
                    repeating: "X",
                    count: numberOfChunks
                )
            ) { (fileHandle, path) in
                let numberOfCalls = ManagedAtomic(0)
                XCTAssertNoThrow(
                    try self.fileIO.readChunked(
                        fileHandle: fileHandle,
                        fromOffset: 0,
                        byteCount: numberOfChunks,
                        chunkSize: 1,
                        allocator: self.allocator,
                        eventLoop: self.eventLoop
                    ) { [eventLoop = self.eventLoop] buffer in
                        numberOfCalls.wrappingIncrement(ordering: .relaxed)
                        XCTAssertEqual(1, buffer.readableBytes)
                        XCTAssertEqual(UInt8(ascii: "X"), buffer.readableBytesView.first)
                        return eventLoop!.makeSucceededFuture(())
                    }.wait()
                )
                XCTAssertEqual(numberOfChunks, numberOfCalls.load(ordering: .relaxed))
            }
        )
    }

    func testThrowsErrorOnUnstartedPool() throws {
        withTemporaryFile(content: "hello, world") { fileHandle, path in
            let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer {
                XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
            }

            let expectation = XCTestExpectation(description: "Opened file")
            let threadPool = NIOThreadPool(numberOfThreads: 1)
            let fileIO = NonBlockingFileIO(threadPool: threadPool)
            fileIO.openFile(_deprecatedPath: path, eventLoop: eventLoopGroup.next()).whenFailure { (error) in
                XCTAssertTrue(error is NIOThreadPoolError.ThreadPoolInactive)
                expectation.fulfill()
            }

            self.wait(for: [expectation], timeout: 1.0)
        }
    }

    func testLStat() throws {
        XCTAssertNoThrow(
            try withTemporaryFile(content: "hello, world") { _, path in
                let stat = try self.fileIO.lstat(path: path, eventLoop: self.eventLoop).wait()
                XCTAssertEqual(12, stat.st_size)
                XCTAssertEqual(S_IFREG, S_IFMT & stat.st_mode)
            }
        )

        XCTAssertNoThrow(
            try withTemporaryDirectory { path in
                let stat = try self.fileIO.lstat(path: path, eventLoop: self.eventLoop).wait()
                XCTAssertEqual(S_IFDIR, S_IFMT & stat.st_mode)
            }
        )
    }

    func testSymlink() {
        XCTAssertNoThrow(
            try withTemporaryFile(content: "hello, world") { _, path in
                let symlink = "\(path).symlink"
                XCTAssertNoThrow(try self.fileIO.symlink(path: symlink, to: path, eventLoop: self.eventLoop).wait())

                XCTAssertEqual(path, try self.fileIO.readlink(path: symlink, eventLoop: self.eventLoop).wait())
                let stat = try self.fileIO.lstat(path: symlink, eventLoop: self.eventLoop).wait()
                XCTAssertEqual(S_IFLNK, S_IFMT & stat.st_mode)

                XCTAssertNoThrow(try self.fileIO.unlink(path: symlink, eventLoop: self.eventLoop).wait())
                XCTAssertThrowsError(try self.fileIO.lstat(path: symlink, eventLoop: self.eventLoop).wait()) { error in
                    XCTAssertEqual(ENOENT, (error as? IOError)?.errnoCode)
                }
            }
        )
    }

    func testCreateDirectory() {
        XCTAssertNoThrow(
            try withTemporaryDirectory { path in
                let dir = "\(path)/f1/f2///f3"
                XCTAssertNoThrow(
                    try self.fileIO.createDirectory(
                        path: dir,
                        withIntermediateDirectories: true,
                        mode: S_IRWXU,
                        eventLoop: self.eventLoop
                    ).wait()
                )

                let stat = try self.fileIO.lstat(path: dir, eventLoop: self.eventLoop).wait()
                XCTAssertEqual(S_IFDIR, S_IFMT & stat.st_mode)

                XCTAssertNoThrow(
                    try self.fileIO.createDirectory(
                        path: "\(dir)/f4",
                        withIntermediateDirectories: false,
                        mode: S_IRWXU,
                        eventLoop: self.eventLoop
                    ).wait()
                )

                let stat2 = try self.fileIO.lstat(path: dir, eventLoop: self.eventLoop).wait()
                XCTAssertEqual(S_IFDIR, S_IFMT & stat2.st_mode)

                let dir3 = "\(path)/f4/."
                XCTAssertNoThrow(
                    try self.fileIO.createDirectory(
                        path: dir3,
                        withIntermediateDirectories: true,
                        mode: S_IRWXU,
                        eventLoop: self.eventLoop
                    ).wait()
                )
            }
        )
    }

    func testListDirectory() {
        XCTAssertNoThrow(
            try withTemporaryDirectory { path in
                let file = "\(path)/file"
                let handle = try self.fileIO.openFile(
                    _deprecatedPath: file,
                    mode: .write,
                    flags: .allowFileCreation(),
                    eventLoop: self.eventLoop
                ).wait()
                defer {
                    try? handle.close()
                }

                let list = try self.fileIO.listDirectory(path: path, eventLoop: self.eventLoop).wait()
                XCTAssertEqual([".", "..", "file"], list.sorted(by: { $0.name < $1.name }).map(\.name))
            }
        )
    }

    func testRename() {
        XCTAssertNoThrow(
            try withTemporaryDirectory { path in
                let file = "\(path)/file"
                let handle = try self.fileIO.openFile(
                    _deprecatedPath: file,
                    mode: .write,
                    flags: .allowFileCreation(),
                    eventLoop: self.eventLoop
                ).wait()
                defer {
                    try? handle.close()
                }

                let stat = try self.fileIO.lstat(path: file, eventLoop: self.eventLoop).wait()
                XCTAssertEqual(S_IFREG, S_IFMT & stat.st_mode)

                let new = "\(path).new"
                XCTAssertNoThrow(try self.fileIO.rename(path: file, newName: new, eventLoop: self.eventLoop).wait())

                let stat2 = try self.fileIO.lstat(path: new, eventLoop: self.eventLoop).wait()
                XCTAssertEqual(S_IFREG, S_IFMT & stat2.st_mode)

                XCTAssertThrowsError(try self.fileIO.lstat(path: file, eventLoop: self.eventLoop).wait()) { error in
                    XCTAssertEqual(ENOENT, (error as? IOError)?.errnoCode)
                }
            }
        )
    }

    func testRemove() {
        XCTAssertNoThrow(
            try withTemporaryDirectory { path in
                let file = "\(path)/file"
                let handle = try self.fileIO.openFile(
                    _deprecatedPath: file,
                    mode: .write,
                    flags: .allowFileCreation(),
                    eventLoop: self.eventLoop
                ).wait()
                defer {
                    try? handle.close()
                }

                let stat = try self.fileIO.lstat(path: file, eventLoop: self.eventLoop).wait()
                XCTAssertEqual(S_IFREG, S_IFMT & stat.st_mode)

                XCTAssertNoThrow(try self.fileIO.remove(path: file, eventLoop: self.eventLoop).wait())
                XCTAssertThrowsError(try self.fileIO.lstat(path: file, eventLoop: self.eventLoop).wait()) { error in
                    XCTAssertEqual(ENOENT, (error as? IOError)?.errnoCode)
                }
            }
        )
    }

    func testChunkedReadingToleratesChunkHandlersWithForeignEventLoops() throws {
        let content = "hello"
        let contentBytes = Array(content.utf8)
        let numCalls = Counter(0)
        let otherGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try! otherGroup.syncShutdownGracefully()
        }
        try withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: 5)
            try self.fileIO.readChunked(
                fileRegion: fr,
                chunkSize: 1,
                allocator: self.allocator,
                eventLoop: self.eventLoop
            ) { [eventLoop = self.eventLoop] buf in
                var buf = buf
                XCTAssertTrue(eventLoop!.inEventLoop)
                XCTAssertEqual(1, buf.readableBytes)
                XCTAssertEqual(contentBytes[numCalls.value], buf.readBytes(length: 1)?.first!)
                numCalls.increment()
                return otherGroup.next().makeSucceededFuture(())
            }.wait()
        }
        XCTAssertEqual(content.utf8.count, numCalls.value)
    }

}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NonBlockingFileIOTest {
    func testAsyncBasicFileIOWorks() async throws {
        let content = "hello"
        try await withTemporaryFile(content: content) { (fileHandle, _) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: 5)
            var buf = try await self.fileIO.read(
                fileRegion: fr,
                allocator: self.allocator
            )
            XCTAssertEqual(content.utf8.count, buf.readableBytes)
            XCTAssertEqual(content, buf.readString(length: buf.readableBytes))
        }
    }

    func testAsyncOffsetWorks() async throws {
        let content = "hello"
        try await withTemporaryFile(content: content) { (fileHandle, _) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 3, endIndex: 5)
            var buf = try await self.fileIO.read(
                fileRegion: fr,
                allocator: self.allocator
            )
            XCTAssertEqual(2, buf.readableBytes)
            XCTAssertEqual("lo", buf.readString(length: buf.readableBytes))
        }
    }

    func testAsyncOffsetBeyondEOF() async throws {
        let content = "hello"
        try await withTemporaryFile(content: content) { (fileHandle, _) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 3000, endIndex: 3001)
            var buf = try await self.fileIO.read(
                fileRegion: fr,
                allocator: self.allocator
            )
            XCTAssertEqual(0, buf.readableBytes)
            XCTAssertEqual("", buf.readString(length: buf.readableBytes))
        }
    }

    func testAsyncEmptyReadWorks() async throws {
        try await withTemporaryFile { (fileHandle, _) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: 0)
            let buf = try await self.fileIO.read(
                fileRegion: fr,
                allocator: self.allocator
            )
            XCTAssertEqual(0, buf.readableBytes)
        }
    }

    func testAsyncReadingShortWorks() async throws {
        let content = "hello"
        try await withTemporaryFile(content: "hello") { (fileHandle, _) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: 10)
            var buf = try await self.fileIO.read(
                fileRegion: fr,
                allocator: self.allocator
            )
            XCTAssertEqual(content.utf8.count, buf.readableBytes)
            XCTAssertEqual(content, buf.readString(length: buf.readableBytes))
        }
    }

    func testAsyncDoesNotBlockTheThreadOrEventLoop() async throws {
        try await withPipe { [fileIO, allocator] readFH, writeFH in
            async let byteBufferTask = try await fileIO!.read(
                fileHandle: readFH,
                byteCount: 10,
                allocator: allocator!
            )
            do {
                try await self.threadPool.runIfActive {
                    try writeFH.withUnsafeFileDescriptor { writeFD in
                        _ = try Posix.write(descriptor: writeFD, pointer: "X", size: 1)
                    }
                    try writeFH.close()
                }
                var buf = try await byteBufferTask
                XCTAssertEqual(1, buf.readableBytes)
                XCTAssertEqual("X", buf.readString(length: buf.readableBytes))
            }
            return [readFH]
        }
    }

    func testAsyncGettingErrorWhenThreadPoolIsShutdown() async throws {
        try await self.threadPool.shutdownGracefully()

        try await withPipe { readFH, writeFH in
            do {
                _ = try await self.fileIO.read(
                    fileHandle: readFH,
                    byteCount: 1,
                    allocator: self.allocator
                )
                XCTFail("testAsyncGettingErrorWhenThreadPoolIsShutdown: fileIO.read should throw an error")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            return [readFH, writeFH]
        }
    }

    func testAsyncReadDoesNotReadShort() async throws {
        try await withPipe { [fileIO, allocator] readFH, writeFH in
            async let bufferTask = try await fileIO!.read(
                fileHandle: readFH,
                byteCount: 10,
                allocator: allocator!
            )
            for i in 0..<10 {
                try await Task.sleep(nanoseconds: 5_000_000)
                try await self.threadPool.runIfActive {
                    try writeFH.withUnsafeFileDescriptor { writeFD in
                        _ = try Posix.write(descriptor: writeFD, pointer: "\(i)", size: 1)
                    }
                }
            }
            try writeFH.close()

            var buf = try await bufferTask
            XCTAssertEqual(10, buf.readableBytes)
            XCTAssertEqual("0123456789", buf.readString(length: buf.readableBytes))
            return [readFH]
        }
    }

    func testAsyncReadMoreThanIntMaxBytesDoesntThrow() async throws {
        try XCTSkipIf(MemoryLayout<size_t>.size == MemoryLayout<UInt32>.size)
        // here we try to read way more data back from the file than it contains but it serves the purpose
        // even on a small file the OS will return EINVAL if you try to read > INT_MAX bytes
        try await withTemporaryFile(
            content: "some-dummy-content",
            { (filehandle, path) -> Void in
                let content = try await self.fileIO.read(
                    fileHandle: filehandle,
                    // There's a runtime check above, use overflow addition to stop the compilation
                    // from failing on 32-bit platforms.
                    byteCount: Int(Int32.max) &+ 10,
                    allocator: .init()
                )
                XCTAssertEqual(String(buffer: content), "some-dummy-content")
            }
        )
    }

    func testAsyncReadingFileSize() async throws {
        try await withTemporaryFile(content: "0123456789") { (fileHandle, _) -> Void in
            let size = try await self.fileIO.readFileSize(fileHandle: fileHandle)
            XCTAssertEqual(size, 10)
        }
    }

    func testAsyncChangeFileSizeShrink() async throws {
        try await withTemporaryFile(content: "0123456789") { (fileHandle, _) -> Void in
            try await self.fileIO.changeFileSize(
                fileHandle: fileHandle,
                size: 1
            )
            let fileRegion = try FileRegion(fileHandle: fileHandle)
            var buf = try await self.fileIO.read(
                fileRegion: fileRegion,
                allocator: self.allocator
            )
            XCTAssertEqual("0", buf.readString(length: buf.readableBytes))
        }
    }

    func testAsyncChangeFileSizeGrow() async throws {
        try await withTemporaryFile(content: "0123456789") { (fileHandle, _) -> Void in
            try await self.fileIO.changeFileSize(
                fileHandle: fileHandle,
                size: 100
            )
            let fileRegion = try FileRegion(fileHandle: fileHandle)
            var buf = try await self.fileIO.read(
                fileRegion: fileRegion,
                allocator: self.allocator
            )
            let zeros = (1...90).map { _ in UInt8(0) }
            guard let bytes = buf.readBytes(length: buf.readableBytes)?.suffix(from: 10) else {
                XCTFail("readBytes(length:) should not be nil")
                return
            }
            XCTAssertEqual(zeros, Array(bytes))
        }
    }

    func testAsyncWriting() async throws {
        try await withTemporaryFile(content: "") { (fileHandle, path) in
            var buffer = self.allocator.buffer(capacity: 3)
            buffer.writeStaticString("123")

            try await self.fileIO.write(
                fileHandle: fileHandle,
                buffer: buffer
            )
            let offset = try fileHandle.withUnsafeFileDescriptor {
                try Posix.lseek(descriptor: $0, offset: 0, whence: SEEK_SET)
            }
            XCTAssertEqual(offset, 0)

            let readBuffer = try await self.fileIO.read(
                fileHandle: fileHandle,
                byteCount: 3,
                allocator: self.allocator
            )
            XCTAssertEqual(readBuffer.getString(at: 0, length: 3), "123")
        }
    }

    func testAsyncWriteMultipleTimes() async throws {
        try await withTemporaryFile(content: "AAA") { (fileHandle, path) in
            var buffer = self.allocator.buffer(capacity: 3)
            buffer.writeStaticString("xxx")

            for i in 0..<3 {
                buffer.writeString("\(i)")
                try await self.fileIO.write(
                    fileHandle: fileHandle,
                    buffer: buffer
                )
            }
            let offset = try fileHandle.withUnsafeFileDescriptor {
                try Posix.lseek(descriptor: $0, offset: 0, whence: SEEK_SET)
            }
            XCTAssertEqual(offset, 0)

            let expectedOutput = "xxx0xxx01xxx012"
            let readBuffer = try await self.fileIO.read(
                fileHandle: fileHandle,
                byteCount: expectedOutput.utf8.count,
                allocator: self.allocator
            )
            XCTAssertEqual(expectedOutput, String(decoding: readBuffer.readableBytesView, as: Unicode.UTF8.self))
        }
    }

    func testAsyncWritingWithOffset() async throws {
        try await withTemporaryFile(content: "hello") { (fileHandle, _) -> Void in
            var buffer = self.allocator.buffer(capacity: 3)
            buffer.writeStaticString("123")

            try await self.fileIO.write(
                fileHandle: fileHandle,
                toOffset: 1,
                buffer: buffer
            )
            let offset = try fileHandle.withUnsafeFileDescriptor {
                try Posix.lseek(descriptor: $0, offset: 0, whence: SEEK_SET)
            }
            XCTAssertEqual(offset, 0)

            var readBuffer = try await self.fileIO.read(
                fileHandle: fileHandle,
                byteCount: 5,
                allocator: self.allocator
            )
            XCTAssertEqual(5, readBuffer.readableBytes)
            XCTAssertEqual("h123o", readBuffer.readString(length: readBuffer.readableBytes))
        }
    }

    // This is undefined behavior and may cause different
    // results on other platforms. Please add #if:s according
    // to platform requirements.
    func testAsyncWritingBeyondEOF() async throws {
        try await withTemporaryFile(content: "hello") { (fileHandle, _) -> Void in
            var buffer = self.allocator.buffer(capacity: 3)
            buffer.writeStaticString("123")

            try await self.fileIO.write(
                fileHandle: fileHandle,
                toOffset: 6,
                buffer: buffer
            )

            let fileRegion = try FileRegion(fileHandle: fileHandle)
            var buf = try await self.fileIO.read(
                fileRegion: fileRegion,
                allocator: self.allocator
            )
            XCTAssertEqual(9, buf.readableBytes)
            XCTAssertEqual("hello", buf.readString(length: 5))
            XCTAssertEqual([UInt8(0)], buf.readBytes(length: 1))
            XCTAssertEqual("123", buf.readString(length: buf.readableBytes))
        }
    }

    func testAsyncFileOpenWorks() async throws {
        let content = "123"
        try await withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            try await self.fileIO.withFileRegion(_deprecatedPath: path) { fr in
                try fr.fileHandle.withUnsafeFileDescriptor { fd in
                    XCTAssertGreaterThanOrEqual(fd, 0)
                }
                XCTAssertTrue(fr.fileHandle.isOpen)
                XCTAssertEqual(0, fr.readerIndex)
                XCTAssertEqual(3, fr.endIndex)
            }
        }
    }

    func testAsyncFileOpenWorksWithEmptyFile() async throws {
        let content = ""
        try await withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            try await self.fileIO.withFileRegion(_deprecatedPath: path) { fr in
                try fr.fileHandle.withUnsafeFileDescriptor { fd in
                    XCTAssertGreaterThanOrEqual(fd, 0)
                }
                XCTAssertTrue(fr.fileHandle.isOpen)
                XCTAssertEqual(0, fr.readerIndex)
                XCTAssertEqual(0, fr.endIndex)
            }
        }
    }

    func testAsyncFileOpenFails() async throws {
        do {
            _ = try await self.fileIO.withFileRegion(_deprecatedPath: "/dev/null/this/does/not/exist") { _ in }
            XCTFail("should've thrown")
        } catch let e as IOError where e.errnoCode == ENOTDIR {
            // OK
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testAsyncOpeningFilesForWriting() async throws {
        try await withTemporaryDirectory { dir in
            try await self.fileIO!.withFileHandle(
                _deprecatedPath: "\(dir)/file",
                mode: .write,
                flags: .allowFileCreation()
            ) { _ in }
        }
    }

    func testAsyncOpeningFilesForWritingFailsIfWeDontAllowItExplicitly() async throws {
        do {
            try await withTemporaryDirectory { dir in
                try await self.fileIO!.withFileHandle(
                    _deprecatedPath: "\(dir)/file",
                    mode: .write,
                    flags: .default
                ) { _ in }
            }
            XCTFail("testAsyncOpeningFilesForWritingFailsIfWeDontAllowItExplicitly: openFile should fail")
        } catch {
            XCTAssertEqual(ENOENT, (error as? IOError)?.errnoCode)
        }
    }

    func testAsyncOpeningFilesForWritingDoesNotAllowReading() async throws {
        try await withTemporaryDirectory { dir in
            try await self.fileIO!.withFileHandle(
                _deprecatedPath: "\(dir)/file",
                mode: .write,
                flags: .allowFileCreation()
            ) { fileHandle in
                XCTAssertEqual(
                    -1,  // read must fail
                    try fileHandle.withUnsafeFileDescriptor { fd -> ssize_t in
                        var data: UInt8 = 0
                        return withUnsafeMutableBytes(of: &data) { ptr in
                            read(fd, ptr.baseAddress, ptr.count)
                        }
                    }
                )
            }
        }
    }

    func testAsyncOpeningFilesForWritingAndReading() async throws {
        try await withTemporaryDirectory { dir in
            try await self.fileIO!.withFileHandle(
                _deprecatedPath: "\(dir)/file",
                mode: [.write, .read],
                flags: .allowFileCreation()
            ) { fileHandle in
                XCTAssertEqual(
                    0,  // read should read EOF
                    try fileHandle.withUnsafeFileDescriptor { fd -> ssize_t in
                        var data: UInt8 = 0
                        return withUnsafeMutableBytes(of: &data) { ptr in
                            read(fd, ptr.baseAddress, ptr.count)
                        }
                    }
                )
            }
        }
    }

    func testAsyncOpeningFilesForWritingDoesNotImplyTruncation() async throws {
        try await withTemporaryDirectory { dir in
            // open 1 + write
            do {
                try await self.fileIO.withFileHandle(
                    _deprecatedPath: "\(dir)/file",
                    mode: [.write, .read],
                    flags: .allowFileCreation()
                ) { fileHandle in
                    try fileHandle.withUnsafeFileDescriptor { fd in
                        var data = UInt8(ascii: "X")
                        XCTAssertEqual(
                            IOResult<Int>.processed(1),
                            try withUnsafeBytes(of: &data) { ptr in
                                try Posix.write(descriptor: fd, pointer: ptr.baseAddress!, size: ptr.count)
                            }
                        )
                    }
                }
            }

            // open 2 + write again + read
            do {
                try await self.fileIO!.withFileHandle(
                    _deprecatedPath: "\(dir)/file",
                    mode: [.write, .read],
                    flags: .default
                ) { fileHandle in
                    try fileHandle.withUnsafeFileDescriptor { fd in
                        try Posix.lseek(descriptor: fd, offset: 0, whence: SEEK_END)
                        var data = UInt8(ascii: "Y")
                        XCTAssertEqual(
                            IOResult<Int>.processed(1),
                            try withUnsafeBytes(of: &data) { ptr in
                                try Posix.write(descriptor: fd, pointer: ptr.baseAddress!, size: ptr.count)
                            }
                        )
                    }
                    XCTAssertEqual(
                        2,  // both bytes
                        try fileHandle.withUnsafeFileDescriptor { fd -> ssize_t in
                            var data: UInt16 = 0
                            try Posix.lseek(descriptor: fd, offset: 0, whence: SEEK_SET)
                            let readReturn = withUnsafeMutableBytes(of: &data) { ptr in
                                read(fd, ptr.baseAddress, ptr.count)
                            }
                            XCTAssertEqual(
                                UInt16(bigEndian: (UInt16(UInt8(ascii: "X")) << 8) | UInt16(UInt8(ascii: "Y"))),
                                data
                            )
                            return readReturn
                        }
                    )
                }
            }
        }
    }

    func testAsyncOpeningFilesForWritingCanUseTruncation() async throws {
        try await withTemporaryDirectory { dir in
            // open 1 + write
            do {
                try await self.fileIO!.withFileHandle(
                    _deprecatedPath: "\(dir)/file",
                    mode: [.write, .read],
                    flags: .allowFileCreation()
                ) { fileHandle in
                    try fileHandle.withUnsafeFileDescriptor { fd in
                        var data = UInt8(ascii: "X")
                        XCTAssertEqual(
                            IOResult<Int>.processed(1),
                            try withUnsafeBytes(of: &data) { ptr in
                                try Posix.write(descriptor: fd, pointer: ptr.baseAddress!, size: ptr.count)
                            }
                        )
                    }
                }
            }
            // open 2 (with truncation) + write again + read
            do {
                try await self.fileIO!.withFileHandle(
                    _deprecatedPath: "\(dir)/file",
                    mode: [.write, .read],
                    flags: .posix(flags: O_TRUNC, mode: 0)
                ) { fileHandle in
                    try fileHandle.withUnsafeFileDescriptor { fd in
                        try Posix.lseek(descriptor: fd, offset: 0, whence: SEEK_END)
                        var data = UInt8(ascii: "Y")
                        XCTAssertEqual(
                            IOResult<Int>.processed(1),
                            try withUnsafeBytes(of: &data) { ptr in
                                try Posix.write(descriptor: fd, pointer: ptr.baseAddress!, size: ptr.count)
                            }
                        )
                    }
                    XCTAssertEqual(
                        1,  // read should read just one byte because we truncated the file
                        try fileHandle.withUnsafeFileDescriptor { fd -> ssize_t in
                            var data: UInt16 = 0
                            try Posix.lseek(descriptor: fd, offset: 0, whence: SEEK_SET)
                            let readReturn = withUnsafeMutableBytes(of: &data) { ptr in
                                read(fd, ptr.baseAddress, ptr.count)
                            }
                            XCTAssertEqual(UInt16(bigEndian: UInt16(UInt8(ascii: "Y")) << 8), data)
                            return readReturn
                        }
                    )
                }
            }
        }
    }

    func testAsyncReadFromOffset() async throws {
        try await withTemporaryFile(content: "hello world") { (fileHandle, path) in
            let buffer = try await self.fileIO.read(
                fileHandle: fileHandle,
                fromOffset: 6,
                byteCount: 5,
                allocator: ByteBufferAllocator()
            )
            let string = String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self)
            XCTAssertEqual("world", string)
        }
    }

    func testAsyncReadFromOffsetAfterEOFDeliversExactlyOneChunk() async throws {
        try await withTemporaryFile(content: "hello world") { (fileHandle, path) in
            let readableBytes = try await self.fileIO.read(
                fileHandle: fileHandle,
                fromOffset: 100,
                byteCount: 5,
                allocator: .init()
            ).readableBytes
            XCTAssertEqual(0, readableBytes)
        }
    }

    func testAsyncReadFromEOFDeliversExactlyOneChunk() async throws {
        try await withTemporaryFile(content: "") { (fileHandle, path) in
            let readableBytes = try await self.fileIO.read(
                fileHandle: fileHandle,
                byteCount: 5,
                allocator: .init()
            ).readableBytes
            XCTAssertEqual(0, readableBytes)
        }
    }

    func testAsyncThrowsErrorOnUnstartedPool() async throws {
        await withTemporaryFile(content: "hello, world") { fileHandle, path in
            let threadPool = NIOThreadPool(numberOfThreads: 1)
            let fileIO = NonBlockingFileIO(threadPool: threadPool)
            do {
                try await fileIO.withFileRegion(_deprecatedPath: path) { _ in }
                XCTFail("testAsyncThrowsErrorOnUnstartedPool: openFile should throw an error")
            } catch {
            }
        }
    }

    func testAsyncLStat() async throws {
        try await withTemporaryFile(content: "hello, world") { _, path in
            let stat = try await self.fileIO.lstat(path: path)
            XCTAssertEqual(12, stat.st_size)
            XCTAssertEqual(S_IFREG, S_IFMT & stat.st_mode)
        }

        try await withTemporaryDirectory { path in
            let stat = try await self.fileIO.lstat(path: path)
            XCTAssertEqual(S_IFDIR, S_IFMT & stat.st_mode)
        }
    }

    func testAsyncSymlink() async throws {
        try await withTemporaryFile(content: "hello, world") { _, path in
            let symlink = "\(path).symlink"
            try await self.fileIO.symlink(path: symlink, to: path)

            let link = try await self.fileIO.readlink(path: symlink)
            XCTAssertEqual(path, link)
            let stat = try await self.fileIO.lstat(path: symlink)
            XCTAssertEqual(S_IFLNK, S_IFMT & stat.st_mode)

            try await self.fileIO.unlink(path: symlink)
            do {
                _ = try await self.fileIO.lstat(path: symlink)
                XCTFail("testAsyncSymlink: lstat should throw an error after unlink")
            } catch {
                XCTAssertEqual(ENOENT, (error as? IOError)?.errnoCode)
            }
        }
    }

    func testAsyncCreateDirectory() async throws {
        try await withTemporaryDirectory { path in
            let dir = "\(path)/f1/f2///f3"
            try await self.fileIO.createDirectory(path: dir, withIntermediateDirectories: true, mode: S_IRWXU)

            let stat = try await self.fileIO.lstat(path: dir)
            XCTAssertEqual(S_IFDIR, S_IFMT & stat.st_mode)

            try await self.fileIO.createDirectory(path: "\(dir)/f4", withIntermediateDirectories: false, mode: S_IRWXU)

            let stat2 = try await self.fileIO.lstat(path: dir)
            XCTAssertEqual(S_IFDIR, S_IFMT & stat2.st_mode)

            let dir3 = "\(path)/f4/."
            try await self.fileIO.createDirectory(path: dir3, withIntermediateDirectories: true, mode: S_IRWXU)
        }
    }

    func testAsyncListDirectory() async throws {
        try await withTemporaryDirectory { path in
            let file = "\(path)/file"
            try await self.fileIO.withFileHandle(
                _deprecatedPath: file,
                mode: .write,
                flags: .allowFileCreation()
            ) { handle in
                let list = try await self.fileIO.listDirectory(path: path)
                XCTAssertEqual([".", "..", "file"], list.sorted(by: { $0.name < $1.name }).map(\.name))
            }
        }
    }

    func testAsyncRename() async throws {
        try await withTemporaryDirectory { path in
            let file = "\(path)/file"
            try await self.fileIO.withFileHandle(
                _deprecatedPath: file,
                mode: .write,
                flags: .allowFileCreation()
            ) { handle in
                let stat = try await self.fileIO.lstat(path: file)
                XCTAssertEqual(S_IFREG, S_IFMT & stat.st_mode)

                let new = "\(path).new"
                try await self.fileIO.rename(path: file, newName: new)

                let stat2 = try await self.fileIO.lstat(path: new)
                XCTAssertEqual(S_IFREG, S_IFMT & stat2.st_mode)

                do {
                    _ = try await self.fileIO.lstat(path: file)
                    XCTFail("testAsyncRename: lstat should throw an error after file renamed")
                } catch {
                    XCTAssertEqual(ENOENT, (error as? IOError)?.errnoCode)
                }
            }
        }
    }

    func testAsyncRemove() async throws {
        try await withTemporaryDirectory { path in
            let file = "\(path)/file"
            try await self.fileIO.withFileHandle(
                _deprecatedPath: file,
                mode: .write,
                flags: .allowFileCreation()
            ) { handle in
                let stat = try await self.fileIO.lstat(path: file)
                XCTAssertEqual(S_IFREG, S_IFMT & stat.st_mode)

                try await self.fileIO.remove(path: file)
                do {
                    _ = try await self.fileIO.lstat(path: file)
                    XCTFail("testAsyncRemove: lstat should throw an error after file removed")
                } catch {
                    XCTAssertEqual(ENOENT, (error as? IOError)?.errnoCode)
                }
            }
        }
    }
}
