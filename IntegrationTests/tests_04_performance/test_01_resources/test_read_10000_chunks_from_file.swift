//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

func run(identifier: String) {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer {
        try! group.syncShutdownGracefully()
    }
    let loop = group.next()
    let threadPool = NIOThreadPool(numberOfThreads: 1)
    threadPool.start()
    defer {
        try! threadPool.syncShutdownGracefully()
    }
    let fileIO = NonBlockingFileIO(threadPool: threadPool)

    let numberOfChunks = 10_000

    let allocator = ByteBufferAllocator()
    var fileBuffer = allocator.buffer(capacity: numberOfChunks)
    fileBuffer.writeString(String(repeating: "X", count: numberOfChunks))
    let path = NSTemporaryDirectory() + "/\(UUID())"
    let fileHandle = try! NIOFileHandle(
        path: path,
        mode: [.write, .read],
        flags: .allowFileCreation(posixMode: 0o600)
    )
    defer {
        unlink(path)
    }
    try! fileIO.write(
        fileHandle: fileHandle,
        buffer: fileBuffer,
        eventLoop: loop
    ).wait()

    let numberOfBytes = NIOAtomic<Int>.makeAtomic(value: 0)
    measure(identifier: identifier) {
        numberOfBytes.store(0)
        try! fileIO.readChunked(
            fileHandle: fileHandle,
            fromOffset: 0,
            byteCount: numberOfChunks,
            chunkSize: 1,
            allocator: allocator,
            eventLoop: loop
        ) { buffer in
            numberOfBytes.add(buffer.readableBytes)
            return loop.makeSucceededFuture(())
        }.wait()
        precondition(numberOfBytes.load() == numberOfChunks, "\(numberOfBytes.load()), \(numberOfChunks)")
        return numberOfBytes.load()
    }
}
