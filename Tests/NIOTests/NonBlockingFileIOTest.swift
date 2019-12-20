//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
@testable import NIO

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

    func testBasicFileIOWorks() throws {
        let content = "hello"
        try withTemporaryFile(content: content) { (fileHandle, _) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: 5)
            var buf = try self.fileIO.read(fileRegion: fr,
                                           allocator: self.allocator,
                                           eventLoop: self.eventLoop).wait()
            XCTAssertEqual(content.utf8.count, buf.readableBytes)
            XCTAssertEqual(content, buf.readString(length: buf.readableBytes))
        }
    }

    func testOffsetWorks() throws {
        let content = "hello"
        try withTemporaryFile(content: content) { (fileHandle, _) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 3, endIndex: 5)
            var buf = try self.fileIO.read(fileRegion: fr,
                                           allocator: self.allocator,
                                           eventLoop: self.eventLoop).wait()
            XCTAssertEqual(2, buf.readableBytes)
            XCTAssertEqual("lo", buf.readString(length: buf.readableBytes))
        }
    }

    func testOffsetBeyondEOF() throws {
        let content = "hello"
        try withTemporaryFile(content: content) { (fileHandle, _) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 3000, endIndex: 3001)
            var buf = try self.fileIO.read(fileRegion: fr,
                                           allocator: self.allocator,
                                           eventLoop: self.eventLoop).wait()
            XCTAssertEqual(0, buf.readableBytes)
            XCTAssertEqual("", buf.readString(length: buf.readableBytes))
        }
    }

    func testEmptyReadWorks() throws {
        try withTemporaryFile { (fileHandle, _) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: 0)
            let buf = try self.fileIO.read(fileRegion: fr,
                                           allocator: self.allocator,
                                           eventLoop: self.eventLoop).wait()
            XCTAssertEqual(0, buf.readableBytes)
        }
    }

    func testReadingShortWorks() throws {
        let content = "hello"
        try withTemporaryFile(content: "hello") { (fileHandle, _) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: 10)
            var buf = try self.fileIO.read(fileRegion: fr,
                                           allocator: self.allocator,
                                           eventLoop: self.eventLoop).wait()
            XCTAssertEqual(content.utf8.count, buf.readableBytes)
            XCTAssertEqual(content, buf.readString(length: buf.readableBytes))
        }
    }

    func testDoesNotBlockTheThreadOrEventLoop() throws {
        var innerError: Error? = nil
        try withPipe { readFH, writeFH in
            let bufferFuture = self.fileIO.read(fileHandle: readFH,
                                                byteCount: 10,
                                                allocator: self.allocator,
                                                eventLoop: self.eventLoop)

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
            do {
                _ = try self.fileIO.read(fileHandle: readFH,
                                         byteCount: 1,
                                         allocator: self.allocator,
                                         eventLoop: self.eventLoop).wait()
                XCTFail("should've thrown")
            } catch let e as ChannelError {
                XCTAssertEqual(ChannelError.ioOnClosedChannel, e)
            } catch {
                XCTFail("unexpected error \(error)")
            }
            return [readFH, writeFH]
        }
    }

    func testChunkReadingWorks() throws {
        let content = "hello"
        let contentBytes = Array(content.utf8)
        var numCalls = 0
        try withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: 5)
            try self.fileIO.readChunked(fileRegion: fr,
                                        chunkSize: 1,
                                        allocator: self.allocator,
                                        eventLoop: self.eventLoop) { buf in
                                    var buf = buf
                                    XCTAssertTrue(self.eventLoop.inEventLoop)
                                    XCTAssertEqual(1, buf.readableBytes)
                                    XCTAssertEqual(contentBytes[numCalls], buf.readBytes(length: 1)?.first!)
                                    numCalls += 1
                                    return self.eventLoop.makeSucceededFuture(())
                }.wait()
        }
        XCTAssertEqual(content.utf8.count, numCalls)
    }

    func testChunkReadingCanBeAborted() throws {
        enum DummyError: Error { case dummy }
        let content = "hello"
        let contentBytes = Array(content.utf8)
        var numCalls = 0
        withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: 5)
            do {
                try self.fileIO.readChunked(fileRegion: fr,
                                            chunkSize: 1,
                                            allocator: self.allocator,
                                            eventLoop: self.eventLoop) { buf in
                                                var buf = buf
                                        XCTAssertTrue(self.eventLoop.inEventLoop)
                                        XCTAssertEqual(1, buf.readableBytes)
                                        XCTAssertEqual(contentBytes[numCalls], buf.readBytes(length: 1)?.first!)
                                        numCalls += 1
                                        return self.eventLoop.makeFailedFuture(DummyError.dummy)
                    }.wait()
                XCTFail("call successful but should've failed")
            } catch let e as DummyError where e == .dummy {
                // ok
            } catch {
                XCTFail("wrong error \(error) caught")
            }
        }
        XCTAssertEqual(1, numCalls)
    }

    func testFailedIO() throws {
        enum DummyError: Error { case dummy }
        let unconnectedSockFH = NIOFileHandle(descriptor: socket(AF_UNIX, Posix.SOCK_STREAM, 0))
        defer {
            XCTAssertNoThrow(try unconnectedSockFH.close())
        }
        do {
            try self.fileIO.readChunked(fileHandle: unconnectedSockFH,
                                        byteCount: 5,
                                        chunkSize: 1,
                                        allocator: self.allocator,
                                        eventLoop: self.eventLoop) { buf in
                                            XCTFail("shouldn't have been called")
                                            return self.eventLoop.makeSucceededFuture(())
                }.wait()
            XCTFail("call successful but should've failed")
        } catch let e as IOError {
            #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
                XCTAssertEqual(ENOTCONN, e.errnoCode)
            #else
                XCTAssertEqual(EINVAL, e.errnoCode)
            #endif
        } catch {
            XCTFail("wrong error \(error) caught")
        }
    }

    func testChunkReadingWorksForIncrediblyLongChain() throws {
        let content = String(repeatElement("X", count: 20*1024))
        var numCalls = 0
        let expectedByte = content.utf8.first!
        try withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: content.utf8.count)
            try self.fileIO.readChunked(fileRegion: fr,
                                        chunkSize: 1,
                                        allocator: self.allocator,
                                        eventLoop: self.eventLoop) { buf in
                                            var buf = buf
                                            XCTAssertTrue(self.eventLoop.inEventLoop)
                                            XCTAssertEqual(1, buf.readableBytes)
                                            XCTAssertEqual(expectedByte, buf.readBytes(length: 1)!.first!)
                                            numCalls += 1
                                            return self.eventLoop.makeSucceededFuture(())
                }.wait()
        }
        XCTAssertEqual(content.utf8.count, numCalls)
    }

    func testReadingDifferentChunkSize() throws {
        let content = "0123456789"
        var numCalls = 0
        try withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: content.utf8.count)
            try self.fileIO.readChunked(fileRegion: fr,
                                        chunkSize: 2,
                                        allocator: self.allocator,
                                        eventLoop: self.eventLoop) { buf in
                                            var buf = buf
                                            XCTAssertTrue(self.eventLoop.inEventLoop)
                                            XCTAssertEqual(2, buf.readableBytes)
                                            XCTAssertEqual(Array("\(numCalls*2)\(numCalls*2 + 1)".utf8), buf.readBytes(length: 2)!)
                                            numCalls += 1
                                            return self.eventLoop.makeSucceededFuture(())
                }.wait()
        }
        XCTAssertEqual(content.utf8.count/2, numCalls)
    }

    func testReadDoesNotReadShort() throws {
        var innerError: Error? = nil
        try withPipe { readFH, writeFH in
            let bufferFuture = self.fileIO.read(fileHandle: readFH,
                                                byteCount: 10,
                                                allocator: self.allocator,
                                                eventLoop: self.eventLoop)
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
        var allBytesActual = ""
        let allBytesExpected = String(content.dropFirst(7).dropLast(7))
        var numCalls = 0
        try withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 7, endIndex: 12)
            try self.fileIO.readChunked(fileRegion: fr,
                                        chunkSize: 3,
                                        allocator: self.allocator,
                                        eventLoop: self.eventLoop) { buf in
                                            var buf = buf
                                            XCTAssertTrue(self.eventLoop.inEventLoop)
                                            allBytesActual += buf.readString(length: buf.readableBytes) ?? "WRONG"
                                            numCalls += 1
                                            return self.eventLoop.makeSucceededFuture(())
                }.wait()
        }
        XCTAssertEqual(allBytesExpected, allBytesActual)
        XCTAssertEqual(2, numCalls)
    }

    func testChunkedReadDoesNotReadShort() throws {
        var innerError: Error? = nil
        try withPipe { readFH, writeFH in
            var allBytes = ""
            let f = self.fileIO.readChunked(fileHandle: readFH,
                                            byteCount: 10,
                                            chunkSize: 3,
                                            allocator: self.allocator,
                                            eventLoop: self.eventLoop) { buf in
                                                var buf = buf
                                                if allBytes.utf8.count == 9 {
                                                    XCTAssertEqual(1, buf.readableBytes)
                                                } else {
                                                    XCTAssertEqual(3, buf.readableBytes)
                                                }
                                                allBytes.append(buf.readString(length: buf.readableBytes) ?? "THIS IS WRONG")
                                                return self.eventLoop.makeSucceededFuture(())
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
                XCTAssertEqual("0123456789", allBytes)
            } catch {
                innerError = error
            }
            return [readFH]
        }
        XCTAssertNil(innerError)
    }

    func testChunkSizeMoreThanTotal() throws {
        let content = "0123456789"
        var numCalls = 0
        try withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            let fr = FileRegion(fileHandle: fileHandle, readerIndex: 0, endIndex: 5)
            try self.fileIO.readChunked(fileRegion: fr,
                                        chunkSize: 10,
                                        allocator: self.allocator,
                                        eventLoop: self.eventLoop) { buf in
                                    var buf = buf
                                    XCTAssertTrue(self.eventLoop.inEventLoop)
                                    XCTAssertEqual(5, buf.readableBytes)
                                    XCTAssertEqual("01234", buf.readString(length: buf.readableBytes) ?? "bad")
                                    numCalls += 1
                                    return self.eventLoop.makeSucceededFuture(())
                }.wait()
        }
        XCTAssertEqual(1, numCalls)
    }

    func testFileRegionReadFromPipeFails() throws {
        try withPipe { readFH, writeFH in
            try! writeFH.withUnsafeFileDescriptor { writeFD in
                _ = try! Posix.write(descriptor: writeFD, pointer: "ABC", size: 3)
            }
            let fr = FileRegion(fileHandle: readFH, readerIndex: 1, endIndex: 2)
            do {
                try self.fileIO.readChunked(fileRegion: fr,
                                            chunkSize: 10,
                                            allocator: self.allocator,
                                            eventLoop: self.eventLoop) { buf in
                                                XCTFail("this shouldn't have been called")
                                                return self.eventLoop.makeSucceededFuture(())
                    }.wait()
                XCTFail("succeeded and shouldn't have")
            } catch let e as IOError where e.errnoCode == ESPIPE {
                // OK
            } catch {
                XCTFail("wrong error \(error) caught")
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
                try self.fileIO.readChunked(fileHandle: readFH,
                                            byteCount: 10,
                                            chunkSize: 10,
                                            allocator: self.allocator,
                                            eventLoop: self.eventLoop) { buf in
                                                XCTFail("this shouldn't have been called")
                                                return self.eventLoop.makeSucceededFuture(())
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
        var numCalls = 0
        try withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            try self.fileIO.readChunked(fileHandle: fileHandle,
                                        byteCount: content.utf8.count,
                                        chunkSize: 9,
                                        allocator: self.allocator,
                                        eventLoop: self.eventLoop) { buf in
                                            var buf = buf
                                            numCalls += 1
                                            XCTAssertTrue(self.eventLoop.inEventLoop)
                                            if numCalls == 1 {
                                                XCTAssertEqual(9, buf.readableBytes)
                                                XCTAssertEqual("012345678", buf.readString(length: buf.readableBytes) ?? "bad")
                                            } else {
                                                XCTAssertEqual(1, buf.readableBytes)
                                                XCTAssertEqual("9", buf.readString(length: buf.readableBytes) ?? "bad")
                                            }
                                            return self.eventLoop.makeSucceededFuture(())
                }.wait()
        }
        XCTAssertEqual(2, numCalls)
    }

    func testWriting() throws {
        var buffer = allocator.buffer(capacity: 3)
        buffer.writeStaticString("123")

        try withTemporaryFile(content: "") { (fileHandle, path) in
            try self.fileIO.write(fileHandle: fileHandle,
                                  buffer: buffer,
                                  eventLoop: self.eventLoop).wait()
            let offset = try fileHandle.withUnsafeFileDescriptor {
                try Posix.lseek(descriptor: $0, offset: 0, whence: SEEK_SET)
            }
            XCTAssertEqual(offset, 0)

            let readBuffer = try self.fileIO.read(fileHandle: fileHandle,
                                                  byteCount: 3,
                                                  allocator: self.allocator,
                                                  eventLoop: self.eventLoop).wait()
            XCTAssertEqual(readBuffer.getString(at: 0, length: 3), "123")
        }
    }

    func testWriteMultipleTimes() throws {
        var buffer = allocator.buffer(capacity: 3)
        buffer.writeStaticString("xxx")

        try withTemporaryFile(content: "AAA") { (fileHandle, path) in
            for i in 0 ..< 3 {
                buffer.writeString("\(i)")
                try self.fileIO.write(fileHandle: fileHandle,
                                      buffer: buffer,
                                      eventLoop: self.eventLoop).wait()
            }
            let offset = try fileHandle.withUnsafeFileDescriptor {
                try Posix.lseek(descriptor: $0, offset: 0, whence: SEEK_SET)
            }
            XCTAssertEqual(offset, 0)

            let expectedOutput = "xxx0xxx01xxx012"
            let readBuffer = try self.fileIO.read(fileHandle: fileHandle,
                                                  byteCount: expectedOutput.utf8.count,
                                                  allocator: self.allocator,
                                                  eventLoop: self.eventLoop).wait()
            XCTAssertEqual(expectedOutput, String(decoding: readBuffer.readableBytesView, as: Unicode.UTF8.self))
        }
    }

    func testFileOpenWorks() throws {
        let content = "123"
        try withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            let (fh, fr) = try self.fileIO.openFile(path: path, eventLoop: self.eventLoop).wait()
            try fh.withUnsafeFileDescriptor { fd in
                XCTAssertGreaterThanOrEqual(fd, 0)
            }
            XCTAssertTrue(fh.isOpen)
            XCTAssertEqual(0, fr.readerIndex)
            XCTAssertEqual(3, fr.endIndex)
            try fh.close()
        }
    }

    func testFileOpenWorksWithEmptyFile() throws {
        let content = ""
        try withTemporaryFile(content: content) { (fileHandle, path) -> Void in
            let (fh, fr) = try self.fileIO.openFile(path: path, eventLoop: self.eventLoop).wait()
            try fh.withUnsafeFileDescriptor { fd in
                XCTAssertGreaterThanOrEqual(fd, 0)
            }
            XCTAssertTrue(fh.isOpen)
            XCTAssertEqual(0, fr.readerIndex)
            XCTAssertEqual(0, fr.endIndex)
            try fh.close()
        }
    }

    func testFileOpenFails() throws {
        do {
            _ = try self.fileIO.openFile(path: "/dev/null/this/does/not/exist", eventLoop: self.eventLoop).wait()
            XCTFail("should've thrown")
        } catch let e as IOError where e.errnoCode == ENOTDIR {
            // OK
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testOpeningFilesForWriting() {
        XCTAssertNoThrow(try withTemporaryDirectory { dir in
            try self.fileIO!.openFile(path: "\(dir)/file",
                mode: .write,
                flags: .allowFileCreation(),
                eventLoop: self.eventLoop).wait().close()
        })
    }

    func testOpeningFilesForWritingFailsIfWeDontAllowItExplicitly() {
        XCTAssertThrowsError(try withTemporaryDirectory { dir in
            try self.fileIO!.openFile(path: "\(dir)/file",
                mode: .write,
                flags: .default,
                eventLoop: self.eventLoop).wait().close()
        }) { error in
            XCTAssertEqual(ENOENT, (error as? IOError)?.errnoCode)
        }
    }

    func testOpeningFilesForWritingDoesNotAllowReading() {
        XCTAssertNoThrow(try withTemporaryDirectory { dir in
            let fileHandle = try self.fileIO!.openFile(path: "\(dir)/file",
                mode: .write,
                flags: .allowFileCreation(),
                eventLoop: self.eventLoop).wait()
            defer {
                try! fileHandle.close()
            }
            XCTAssertEqual(-1 /* read must fail */,
                           try fileHandle.withUnsafeFileDescriptor { fd -> ssize_t in
                            var data: UInt8 = 0
                            return withUnsafeMutableBytes(of: &data) { ptr in
                                read(fd, ptr.baseAddress, ptr.count)
                            }
            })
        })
    }

    func testOpeningFilesForWritingAndReading() {
        XCTAssertNoThrow(try withTemporaryDirectory { dir in
            let fileHandle = try self.fileIO!.openFile(path: "\(dir)/file",
                mode: [.write, .read],
                flags: .allowFileCreation(),
                eventLoop: self.eventLoop).wait()
            defer {
                try! fileHandle.close()
            }
            XCTAssertEqual(0 /* read should read EOF */,
                try fileHandle.withUnsafeFileDescriptor { fd -> ssize_t in
                    var data: UInt8 = 0
                    return withUnsafeMutableBytes(of: &data) { ptr in
                        read(fd, ptr.baseAddress, ptr.count)
                    }
            })
        })
    }

    func testOpeningFilesForWritingDoesNotImplyTruncation() {
        XCTAssertNoThrow(try withTemporaryDirectory { dir in
            // open 1 + write
            try {
                let fileHandle = try self.fileIO!.openFile(path: "\(dir)/file",
                    mode: [.write, .read],
                    flags: .allowFileCreation(),
                    eventLoop: self.eventLoop).wait()
                defer {
                    try! fileHandle.close()
                }
                try fileHandle.withUnsafeFileDescriptor { fd in
                    var data = UInt8(ascii: "X")
                    XCTAssertEqual(IOResult<Int>.processed(1),
                                   try withUnsafeBytes(of: &data) { ptr in
                                    try Posix.write(descriptor: fd, pointer: ptr.baseAddress!, size: ptr.count)
                    })
                }
            }()
            // open 2 + write again + read
            try {
                let fileHandle = try self.fileIO!.openFile(path: "\(dir)/file",
                    mode: [.write, .read],
                    flags: .default,
                    eventLoop: self.eventLoop).wait()
                defer {
                    try! fileHandle.close()
                }
                try fileHandle.withUnsafeFileDescriptor { fd in
                    try Posix.lseek(descriptor: fd, offset: 0, whence: SEEK_END)
                    var data = UInt8(ascii: "Y")
                    XCTAssertEqual(IOResult<Int>.processed(1),
                                   try withUnsafeBytes(of: &data) { ptr in
                                    try Posix.write(descriptor: fd, pointer: ptr.baseAddress!, size: ptr.count)
                    })
                }
                XCTAssertEqual(2 /* both bytes */,
                    try fileHandle.withUnsafeFileDescriptor { fd -> ssize_t in
                        var data: UInt16 = 0
                        try Posix.lseek(descriptor: fd, offset: 0, whence: SEEK_SET)
                        let readReturn = withUnsafeMutableBytes(of: &data) { ptr in
                            read(fd, ptr.baseAddress, ptr.count)
                        }
                        XCTAssertEqual(UInt16(bigEndian: (UInt16(UInt8(ascii: "X")) << 8) | UInt16(UInt8(ascii: "Y"))),
                                       data)
                        return readReturn
                    })
            }()
        })
    }

    func testOpeningFilesForWritingCanUseTruncation() {
        XCTAssertNoThrow(try withTemporaryDirectory { dir in
            // open 1 + write
            try {
                let fileHandle = try self.fileIO!.openFile(path: "\(dir)/file",
                    mode: [.write, .read],
                    flags: .allowFileCreation(),
                    eventLoop: self.eventLoop).wait()
                defer {
                    try! fileHandle.close()
                }
                try fileHandle.withUnsafeFileDescriptor { fd in
                    var data = UInt8(ascii: "X")
                    XCTAssertEqual(IOResult<Int>.processed(1),
                                   try withUnsafeBytes(of: &data) { ptr in
                                    try Posix.write(descriptor: fd, pointer: ptr.baseAddress!, size: ptr.count)
                        })
                }
                }()
            // open 2 (with truncation) + write again + read
            try {
                let fileHandle = try self.fileIO!.openFile(path: "\(dir)/file",
                    mode: [.write, .read],
                    flags: .posix(flags: O_TRUNC, mode: 0),
                    eventLoop: self.eventLoop).wait()
                defer {
                    try! fileHandle.close()
                }
                try fileHandle.withUnsafeFileDescriptor { fd in
                    try Posix.lseek(descriptor: fd, offset: 0, whence: SEEK_END)
                    var data = UInt8(ascii: "Y")
                    XCTAssertEqual(IOResult<Int>.processed(1),
                                   try withUnsafeBytes(of: &data) { ptr in
                                    try Posix.write(descriptor: fd, pointer: ptr.baseAddress!, size: ptr.count)
                        })
                }
                XCTAssertEqual(1 /* read should read just one byte because we truncated the file */,
                    try fileHandle.withUnsafeFileDescriptor { fd -> ssize_t in
                        var data: UInt16 = 0
                        try Posix.lseek(descriptor: fd, offset: 0, whence: SEEK_SET)
                        let readReturn = withUnsafeMutableBytes(of: &data) { ptr in
                            read(fd, ptr.baseAddress, ptr.count)
                        }
                        XCTAssertEqual(UInt16(bigEndian: UInt16(UInt8(ascii: "Y")) << 8), data)
                        return readReturn
                    })
                }()
            })
    }

    func testReadFromOffset() {
        XCTAssertNoThrow(try withTemporaryFile(content: "hello world") { (fileHandle, path) in
            let buffer = self.fileIO.read(fileHandle: fileHandle,
                                          fromOffset: 6,
                                          byteCount: 5,
                                          allocator: ByteBufferAllocator(),
                                          eventLoop: self.eventLoop)
            XCTAssertNoThrow(try XCTAssertEqual("world",
                                                String(decoding: buffer.wait().readableBytesView,
                                                       as: Unicode.UTF8.self)))
        })
    }

    func testReadChunkedFromOffset() {
        XCTAssertNoThrow(try withTemporaryFile(content: "hello world") { (fileHandle, path) in
            var numberOfCalls = 0
            try self.fileIO.readChunked(fileHandle: fileHandle,
                                        fromOffset: 6,
                                        byteCount: 5,
                                        chunkSize: 2,
                                        allocator: .init(),
                                        eventLoop: self.eventLoop) { buffer in
                numberOfCalls += 1
                switch numberOfCalls {
                case 1:
                    XCTAssertEqual("wo", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
                case 2:
                    XCTAssertEqual("rl", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
                case 3:
                    XCTAssertEqual("d", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
                default:
                    XCTFail()
                }
                return self.eventLoop.makeSucceededFuture(())
            }.wait()
        })
    }

    func testReadChunkedFromNegativeOffsetFails() {
        XCTAssertThrowsError(try withTemporaryFile(content: "hello world") { (fileHandle, path) in
            try self.fileIO.readChunked(fileHandle: fileHandle,
                                        fromOffset: -1,
                                        byteCount: 5,
                                        chunkSize: 2,
                                        allocator: .init(),
                                        eventLoop: self.eventLoop) { _ in
                XCTFail("shouldn't be called")
                return self.eventLoop.makeSucceededFuture(())
            }.wait()
        }) { error in
            XCTAssertEqual(EINVAL, (error as? IOError)?.errnoCode)
        }
    }

    func testReadChunkedFromOffsetAfterEOFDeliversExactlyOneChunk() {
        var numberOfCalls = 0
        XCTAssertNoThrow(try withTemporaryFile(content: "hello world") { (fileHandle, path) in
            try self.fileIO.readChunked(fileHandle: fileHandle,
                                        fromOffset: 100,
                                        byteCount: 5,
                                        chunkSize: 2,
                                        allocator: .init(),
                                        eventLoop: self.eventLoop) { buffer in
                numberOfCalls += 1
                XCTAssertEqual(1, numberOfCalls)
                XCTAssertEqual(0, buffer.readableBytes)
                return self.eventLoop.makeSucceededFuture(())
            }.wait()
        })
    }

    func testReadChunkedFromEOFDeliversExactlyOneChunk() {
        var numberOfCalls = 0
        XCTAssertNoThrow(try withTemporaryFile(content: "") { (fileHandle, path) in
            try self.fileIO.readChunked(fileHandle: fileHandle,
                                        byteCount: 5,
                                        chunkSize: 2,
                                        allocator: .init(),
                                        eventLoop: self.eventLoop) { buffer in
                numberOfCalls += 1
                XCTAssertEqual(1, numberOfCalls)
                XCTAssertEqual(0, buffer.readableBytes)
                return self.eventLoop.makeSucceededFuture(())
            }.wait()
        })
    }

    func testReadFromOffsetAfterEOFDeliversExactlyOneChunk() {
        XCTAssertNoThrow(try withTemporaryFile(content: "hello world") { (fileHandle, path) in
            XCTAssertEqual(0,
                           try self.fileIO.read(fileHandle: fileHandle,
                                                fromOffset: 100,
                                                byteCount: 5,
                                                allocator: .init(),
                                                eventLoop: self.eventLoop).wait().readableBytes)
        })
    }

    func testReadFromEOFDeliversExactlyOneChunk() {
        XCTAssertNoThrow(try withTemporaryFile(content: "") { (fileHandle, path) in
            XCTAssertEqual(0,
                           try self.fileIO.read(fileHandle: fileHandle,
                                                byteCount: 5,
                                                allocator: .init(),
                                                eventLoop: self.eventLoop).wait().readableBytes)
        })
    }

    func testReadChunkedFromOffsetFileRegion() {
        XCTAssertNoThrow(try withTemporaryFile(content: "hello world") { (fileHandle, path) in
            var numberOfCalls = 0
            let fileRegion = FileRegion(fileHandle: fileHandle, readerIndex: 6, endIndex: 11)
            try self.fileIO.readChunked(fileRegion: fileRegion,
                                        chunkSize: 2,
                                        allocator: .init(),
                                        eventLoop: self.eventLoop) { buffer in
                numberOfCalls += 1
                switch numberOfCalls {
                case 1:
                    XCTAssertEqual("wo", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
                case 2:
                    XCTAssertEqual("rl", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
                case 3:
                    XCTAssertEqual("d", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
                default:
                    XCTFail()
                }
                return self.eventLoop.makeSucceededFuture(())
            }.wait()
        })
    }

}
