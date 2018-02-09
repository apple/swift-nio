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
    
    private func temporaryFilePath() -> String {
        let fileManager = FileManager.default
        let filePath: String
        #if os(Linux)
            filePath = "/tmp/\(UUID().uuidString)"
        #else
            if #available(OSX 10.12, *) {
                filePath = "\(fileManager.temporaryDirectory.path)/\(UUID().uuidString)"
            } else {
                filePath = "/tmp/\(UUID().uuidString)"
            }
        #endif
        return filePath
    }

    func testWriteFileRegion() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
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

        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer({ $0.pipeline.add(handler: countingHandler) }).bind(to: "127.0.0.1", on: 0).wait()
        
        defer {
            _ = serverChannel.close()
        }
        
        let clientChannel = try ClientBootstrap(group: group).connect(to: serverChannel.localAddress!).wait()

        defer {
            _ = clientChannel.close()
        }
       
        let fileManager = FileManager.default
        let filePath = self.temporaryFilePath()
        defer {
            _ = try? FileManager.default.removeItem(atPath: filePath)
        }
        try content.write(toFile: filePath, atomically: false, encoding: .ascii)
        try clientChannel.writeAndFlush(data: NIOAny(FileRegion(file: filePath, readerIndex: 0, endIndex: bytes.count))).wait()
            
        var buffer = clientChannel.allocator.buffer(capacity: bytes.count)
        buffer.write(bytes: bytes)
        try countingHandler.assertReceived(buffer: buffer)
    }

    func testWriteEmptyFileRegionDoesNotHang() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let countingHandler = ByteCountingHandler(numBytes: 0, promise: group.next().newPromise())

        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer({ $0.pipeline.add(handler: countingHandler) }).bind(to: "127.0.0.1", on: 0).wait()

        defer {
            _ = serverChannel.close()
        }

        let clientChannel = try ClientBootstrap(group: group).connect(to: serverChannel.localAddress!).wait()

        defer {
            _ = clientChannel.close()
        }

        let filePath = self.temporaryFilePath()
        defer {
            _ = try? FileManager.default.removeItem(atPath: filePath)
        }
        try "".write(toFile: filePath, atomically: false, encoding: .ascii)

        var futures: [EventLoopFuture<()>] = []
        for _ in 0..<10 {
            futures.append(try clientChannel.write(data: NIOAny(FileRegion(file: filePath, readerIndex: 0, endIndex: 0))))
        }
        try clientChannel.writeAndFlush(data: NIOAny(FileRegion(file: filePath, readerIndex: 0, endIndex: 0))).wait()
        try futures.forEach { try $0.wait() }
    }

    func testOutstandingFileRegionsWork() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
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

        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer({ $0.pipeline.add(handler: countingHandler) }).bind(to: "127.0.0.1", on: 0).wait()

        defer {
            _ = serverChannel.close()
        }

        let clientChannel = try ClientBootstrap(group: group).connect(to: serverChannel.localAddress!).wait()

        defer {
            _ = clientChannel.close()
        }

        let fileManager = FileManager.default
        let filePath = self.temporaryFilePath()
        defer {
            _ = try? FileManager.default.removeItem(atPath: filePath)
        }
        try content.write(toFile: filePath, atomically: false, encoding: .ascii)
        do {
            () = try clientChannel.writeAndFlush(data: NIOAny(FileRegion(file: filePath, readerIndex: 0, endIndex: bytes.count))).thenThrowing {
                try FileRegion(file: filePath, readerIndex: 0, endIndex: bytes.count)
            }.then { (fileRegion: FileRegion) -> EventLoopFuture<()> in
                let frFuture = clientChannel.write(data: NIOAny(fileRegion))
                var buffer = clientChannel.allocator.buffer(capacity: bytes.count)
                buffer.write(bytes: bytes)
                let bbFuture = clientChannel.write(data: NIOAny(buffer))
                clientChannel.close(promise: nil)
                clientChannel.flush(promise: nil)
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

    func testWholeFileFileRegion() throws {
        try withTemporaryFile(content: "hello") { fd, path in
            let region = try FileRegion(file: path)
            defer {
                XCTAssertNoThrow(try region.close())
            }
            XCTAssertEqual(0, region.readerIndex)
            XCTAssertEqual(5, region.readableBytes)
            XCTAssertEqual(5, region.endIndex)
        }
    }

    func testWholeEmptyFileFileRegion() throws {
        try withTemporaryFile(content: "") { fd, path in
            let region = try FileRegion(file: path)
            defer {
                XCTAssertNoThrow(try region.close())
            }
            XCTAssertEqual(0, region.readerIndex)
            XCTAssertEqual(0, region.readableBytes)
            XCTAssertEqual(0, region.endIndex)
        }
    }
}
