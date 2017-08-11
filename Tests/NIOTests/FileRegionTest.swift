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

import Foundation
import XCTest
@testable import NIO

class FileRegionTest : XCTestCase {
    
    func testWriteFileRegion() throws {
        let group = try MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            _ = try? group.close()
        }
        
        let numBytes = 16 * 1024
        
        var content = ""
        for i in 0..<numBytes {
            content.append("\(i)")
        }
        let bytes = content.data(using: .ascii)!

        
        let countingHandler = ByteCountingHandler(numBytes: bytes.count, promise: group.next().newPromise())

        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .handler(childHandler: countingHandler).bind(to: "127.0.0.1", on: 0).wait()
        
        defer {
            _ = serverChannel.close()
        }
        
        let clientChannel = try ClientBootstrap(group: group).connect(to: serverChannel.localAddress!).wait()

        defer {
            _ = clientChannel.close()
        }
       
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
        defer {
            _ = try? fileManager.removeItem(atPath: filePath)
        }
        try content.write(toFile: filePath, atomically: false, encoding: .ascii)
        try clientChannel.writeAndFlush(data: IOData(FileRegion(file: filePath, readerIndex: 0, endIndex: bytes.count))).wait()
            
        var buffer = clientChannel.allocator.buffer(capacity: bytes.count)
        buffer.write(data: bytes)
        try countingHandler.assertReceived(buffer: buffer)
    }

    private final class ByteCountingHandler : ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        
        private let numBytes: Int
        private let promise: Promise<ByteBuffer>
        private var buffer: ByteBuffer!
        
        init(numBytes: Int, promise: Promise<ByteBuffer>) {
            self.numBytes = numBytes
            self.promise = promise
        }
        
        func handlerAdded(ctx: ChannelHandlerContext) {
            buffer = ctx.channel!.allocator.buffer(capacity: numBytes)
        }
        
        func channelRead(ctx: ChannelHandlerContext, data: IOData) {
            var currentBuffer = self.unwrapInboundIn(data)
            buffer.write(buffer: &currentBuffer)
            
            if buffer.readableBytes == numBytes {
                promise.succeed(result: buffer)
            }
        }
        
        func assertReceived(buffer: ByteBuffer) throws {
            let received = try promise.futureResult.wait()
            XCTAssertEqual(buffer, received)
        }
    }
}
