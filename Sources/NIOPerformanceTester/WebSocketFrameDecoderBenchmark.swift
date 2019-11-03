//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOWebSocket

final class WebSocketFrameDecoderBenchmark {

    private let channel: EmbeddedChannel
    private let runCount: Int
    private let dataSize: Int
    private var maskKey: WebSocketMaskingKey?
    private var data: ByteBuffer

    init(dataSize: Int, runCount: Int, withMaskKey: Bool = false) {
        self.channel = EmbeddedChannel()
        self.dataSize = dataSize
        self.data = ByteBufferAllocator().buffer(capacity: dataSize)
        self.runCount = runCount
        if withMaskKey {
            self.maskKey = [0x80, 0x08, 0x10, 0x01]
            self.data.webSocketMask(self.maskKey!)
        }
    }
}

extension WebSocketFrameDecoderBenchmark: Benchmark {

    func setUp() throws {
        self.data = ByteBufferAllocator().buffer(size: self.dataSize)
        try self.channel.pipeline.addHandler(ByteToMessageHandler(WebSocketFrameDecoder())).wait()
    }

    func tearDown() {
        _ = try! self.channel.finish()
    }

    func run() throws -> Int {
        if let maskKey = self.maskKey {
            return try self.run(with: maskKey)
        } else {
            return try self.runWithoutMaskKey()
        }
    }

    private func runWithoutMaskKey() throws -> Int {
        for _ in 0..<self.runCount {
            try self.channel.writeInbound(self.data)
            let _: WebSocketFrame? =  try self.channel.readInbound()
        }
        return 1
    }

    private func run(with maskKey: WebSocketMaskingKey) throws -> Int {
        for _ in 0..<self.runCount {
            self.data.webSocketUnmask(maskKey)
            try self.channel.writeInbound(self.data)
            let _: WebSocketFrame? =  try self.channel.readInbound()
        }
        return 1
    }
}

extension ByteBufferAllocator {
    fileprivate func buffer(size: Int) -> ByteBuffer {
        var data = self.buffer(capacity: size)
        let bytes = size / 8
        data.writeBytes([0x81] + Array(repeatElement(0, count: bytes - 1)))
        return data
    }
}
