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

class FileRegionTest : XCTestCase {

    func testWriteFileRegion() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let numBytes = 16 * 1024

        var content = ""
        for i in 0..<numBytes {
            content.append("\(i)")
        }
        let bytes = Array(content.utf8)

        let countingHandler = ByteCountingHandler(numBytes: bytes.count, promise: group.next().newPromise())

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { $0.pipeline.add(handler: countingHandler) }
            .bind(host: "127.0.0.1", port: 0)
            .wait())

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!)
            .wait())

        defer {
            XCTAssertNoThrow(try clientChannel.close().wait())
        }

        try withTemporaryFile { _, filePath in
            let handle = try FileHandle(path: filePath)
            let fr = FileRegion(fileHandle: handle, readerIndex: 0, endIndex: bytes.count)
            defer {
                XCTAssertNoThrow(try handle.close())
            }
            try content.write(toFile: filePath, atomically: false, encoding: .ascii)
            try clientChannel.writeAndFlush(NIOAny(fr)).wait()
            var buffer = clientChannel.allocator.buffer(capacity: bytes.count)
            buffer.write(bytes: bytes)
            try countingHandler.assertReceived(buffer: buffer)
        }
    }

    func testWriteEmptyFileRegionDoesNotHang() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let countingHandler = ByteCountingHandler(numBytes: 0, promise: group.next().newPromise())

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { $0.pipeline.add(handler: countingHandler) }
            .bind(host: "127.0.0.1", port: 0)
            .wait())

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!)
            .wait())

        defer {
            XCTAssertNoThrow(try clientChannel.close().wait())
        }

        try withTemporaryFile { _, filePath in
            let handle = try FileHandle(path: filePath)
            let fr = FileRegion(fileHandle: handle, readerIndex: 0, endIndex: 0)
            defer {
                XCTAssertNoThrow(try handle.close())
            }
            try "".write(toFile: filePath, atomically: false, encoding: .ascii)

            var futures: [EventLoopFuture<Void>] = []
            for _ in 0..<10 {
                futures.append(clientChannel.write(NIOAny(fr)))
            }
            try clientChannel.writeAndFlush(NIOAny(fr)).wait()
            try futures.forEach { try $0.wait() }
        }
    }

    func testOutstandingFileRegionsWork() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let numBytes = 16 * 1024

        var content = ""
        for i in 0..<numBytes {
            content.append("\(i)")
        }
        let bytes = Array(content.utf8)

        let countingHandler = ByteCountingHandler(numBytes: bytes.count, promise: group.next().newPromise())

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { $0.pipeline.add(handler: countingHandler) }
            .bind(host: "127.0.0.1", port: 0)
            .wait())

        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!)
            .wait())

        defer {
            XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())
        }

        try withTemporaryFile { fd, filePath in
            let fh1 = try FileHandle(path: filePath)
            let fh2 = try FileHandle(path: filePath)
            let fr1 = FileRegion(fileHandle: fh1, readerIndex: 0, endIndex: bytes.count)
            let fr2 = FileRegion(fileHandle: fh2, readerIndex: 0, endIndex: bytes.count)
            defer {
                XCTAssertNoThrow(try fh1.close())
                XCTAssertNoThrow(try fh2.close())
            }
            try content.write(toFile: filePath, atomically: false, encoding: .ascii)
            do {
                () = try clientChannel.writeAndFlush(NIOAny(fr1)).then {
                    let frFuture = clientChannel.write(NIOAny(fr2))
                    var buffer = clientChannel.allocator.buffer(capacity: bytes.count)
                    buffer.write(bytes: bytes)
                    let bbFuture = clientChannel.write(NIOAny(buffer))
                    clientChannel.close(promise: nil)
                    clientChannel.flush()
                    return frFuture.then { bbFuture }
                }.wait()
                XCTFail("no error happened even though we closed before flush")
            } catch let e as ChannelError {
                XCTAssertEqual(ChannelError.alreadyClosed, e)
            } catch let e {
                XCTFail("unexpected error \(e)")
            }

            var buffer = clientChannel.allocator.buffer(capacity: bytes.count)
            buffer.write(bytes: bytes)
            try countingHandler.assertReceived(buffer: buffer)
        }
    }

    func testWholeFileFileRegion() throws {
        try withTemporaryFile(content: "hello") { fd, path in
            let handle = try FileHandle(path: path)
            let region = try FileRegion(fileHandle: handle)
            defer {
                XCTAssertNoThrow(try handle.close())
            }
            XCTAssertEqual(0, region.readerIndex)
            XCTAssertEqual(5, region.readableBytes)
            XCTAssertEqual(5, region.endIndex)
        }
    }

    func testWholeEmptyFileFileRegion() throws {
        try withTemporaryFile(content: "") { _, path in
            let handle = try FileHandle(path: path)
            let region = try FileRegion(fileHandle: handle)
            defer {
                XCTAssertNoThrow(try handle.close())
            }
            XCTAssertEqual(0, region.readerIndex)
            XCTAssertEqual(0, region.readableBytes)
            XCTAssertEqual(0, region.endIndex)
        }
    }

    func testFileRegionDuplicatesShareSeekPointer() throws {
        try withTemporaryFile(content: "0123456789") { fh1, path in
            let fr1 = FileRegion(fileHandle: fh1, readerIndex: 0, endIndex: 10)
            let fh2 = try fh1.duplicate()

            var fr1Bytes: [UInt8] = Array(repeating: 0, count: 5)
            var fr2Bytes = fr1Bytes
            try fh1.withUnsafeFileDescriptor { fd in
                let r = try Posix.read(descriptor: fd, pointer: &fr1Bytes, size: 5)
                XCTAssertEqual(r, IOResult<Int>.processed(5))
            }
            try fh2.withUnsafeFileDescriptor { fd in
                let r = try Posix.read(descriptor: fd, pointer: &fr2Bytes, size: 5)
                XCTAssertEqual(r, IOResult<Int>.processed(5))
            }
            XCTAssertEqual(Array("01234".utf8), fr1Bytes)
            XCTAssertEqual(Array("56789".utf8), fr2Bytes)

            defer {
                // fr2's underlying fd must be closed by us.
                XCTAssertNoThrow(try fh2.close())
            }
        }
    }

    func testMassiveFileRegionThatJustAboutWorks() {
        withTemporaryFile(content: "0123456789") { fh, path in
            // just in case someone uses 32bit platforms
            let readerIndex = UInt64(_UInt56.max) < UInt64(Int.max) ? Int(_UInt56.max) : Int.max
            let fr = FileRegion(fileHandle: fh, readerIndex: readerIndex, endIndex: Int.max)
            XCTAssertEqual(readerIndex, fr.readerIndex)
            XCTAssertEqual(Int.max, fr.endIndex)
        }
    }

    func testMassiveFileRegionReaderIndexWorks() {
        withTemporaryFile(content: "0123456789") { fh, path in
            // just in case someone uses 32bit platforms
            let readerIndex = (UInt64(_UInt56.max) < UInt64(Int.max) ? Int(_UInt56.max) : Int.max) - 1000
            var fr = FileRegion(fileHandle: fh, readerIndex: readerIndex, endIndex: Int.max)
            for i in 0..<1000 {
                XCTAssertEqual(readerIndex + i, fr.readerIndex)
                XCTAssertEqual(Int.max, fr.endIndex)
                fr.moveReaderIndex(forwardBy: 1)
            }
        }
    }

    func testFileRegionAndIODataFitsInACoupleOfEnums() throws {
        enum Level4 {
            case case1(FileRegion)
            case case2(FileRegion)
            case case3(IOData)
            case case4(IOData)
        }
        enum Level3 {
            case case1(Level4)
            case case2(Level4)
            case case3(Level4)
            case case4(Level4)
        }
        enum Level2 {
            case case1(Level3)
            case case2(Level3)
            case case3(Level3)
            case case4(Level3)
        }
        enum Level1 {
            case case1(Level2)
            case case2(Level2)
            case case3(Level2)
            case case4(Level2)
        }

        XCTAssertLessThanOrEqual(MemoryLayout<FileRegion>.size, 23)
        XCTAssertLessThanOrEqual(MemoryLayout<Level1>.size, 24)

        XCTAssertNoThrow(try withTemporaryFile(content: "0123456789") { fh, path in
            let fr = try FileRegion(fileHandle: fh)
            XCTAssertLessThanOrEqual(MemoryLayout.size(ofValue: Level1.case1(.case2(.case3(.case4(.fileRegion(fr)))))), 24)
            XCTAssertLessThanOrEqual(MemoryLayout.size(ofValue: Level1.case1(.case3(.case4(.case1(fr))))), 24)
        })
    }
}
