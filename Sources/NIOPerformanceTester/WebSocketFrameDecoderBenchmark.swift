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
    private var data: ByteBuffer

    init(dataSize: Int, runCount: Int) {
        self.channel = EmbeddedChannel()
        self.data = ByteBufferAllocator().buffer(capacity: dataSize)
        self.runCount = runCount
    }
}

extension WebSocketFrameDecoderBenchmark: Benchmark {

    func setUp() throws {
        self.data.writeBytes([0x81, 0x00]) // empty websocket
        try self.channel.pipeline.addHandler(ByteToMessageHandler(WebSocketFrameDecoder())).wait()
    }

    func tearDown() {
        _ = try! self.channel.finish()
    }

    func run() throws  -> Int{
        for _ in 0..<runCount {
            try self.channel.writeInbound(self.data)
            let _: WebSocketFrame? =  try self.channel.readInbound()
        }
        return 1
    }
}
