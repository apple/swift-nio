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

final class WebSocketFrameEncoderBenchmark {
    private let channel: EmbeddedChannel
    private let dataSize: Int
    private let data: ByteBuffer
    private let runCount: Int
    private let dataStrategy: DataStrategy
    private let cowStrategy: CoWStrategy
    private var maskingKey: WebSocketMaskingKey?
    private var frame: WebSocketFrame?

    init(dataSize: Int, runCount: Int, dataStrategy: DataStrategy, cowStrategy: CoWStrategy, maskingKeyStrategy: MaskingKeyStrategy) {
        frame = nil
        channel = EmbeddedChannel()
        self.dataSize = dataSize
        self.runCount = runCount
        self.dataStrategy = dataStrategy
        self.cowStrategy = cowStrategy
        data = ByteBufferAllocator().buffer(size: dataSize, dataStrategy: dataStrategy)
        maskingKey = maskingKeyStrategy == MaskingKeyStrategy.always ? [0x80, 0x08, 0x10, 0x01] : nil
    }
}

extension WebSocketFrameEncoderBenchmark {
    enum DataStrategy {
        case spaceAtFront
        case noSpaceAtFront
    }
}

extension WebSocketFrameEncoderBenchmark {
    enum CoWStrategy {
        case always
        case never
    }
}

extension WebSocketFrameEncoderBenchmark {
    enum MaskingKeyStrategy {
        case always
        case never
    }
}

extension WebSocketFrameEncoderBenchmark: Benchmark {
    func setUp() throws {
        // We want the pipeline walk to have some cost.
        try! channel.pipeline.addHandler(WriteConsumingHandler()).wait()
        for _ in 0 ..< 3 {
            try! channel.pipeline.addHandler(NoOpOutboundHandler()).wait()
        }
        try! channel.pipeline.addHandler(WebSocketFrameEncoder()).wait()
        frame = WebSocketFrame(opcode: .binary, maskKey: maskingKey, data: data, extensionData: nil)
    }

    func tearDown() {
        _ = try! channel.finish()
    }

    func run() throws -> Int {
        switch cowStrategy {
        case .always:
            let frame = self.frame!
            return runWithCoWs(frame: frame)
        case .never:
            return runWithoutCoWs()
        }
    }

    private func runWithCoWs(frame: WebSocketFrame) -> Int {
        for _ in 0 ..< runCount {
            channel.write(frame, promise: nil)
        }
        return 1
    }

    private func runWithoutCoWs() -> Int {
        for _ in 0 ..< runCount {
            // To avoid CoWs this has to be a new buffer every time. This is expensive, sadly, so tests using this strategy
            // must do fewer iterations.
            let data = channel.allocator.buffer(size: dataSize, dataStrategy: dataStrategy)
            let frame = WebSocketFrame(opcode: .binary, maskKey: maskingKey, data: data, extensionData: nil)
            channel.write(frame, promise: nil)
        }
        return 1
    }
}

private extension ByteBufferAllocator {
    func buffer(size: Int, dataStrategy: WebSocketFrameEncoderBenchmark.DataStrategy) -> ByteBuffer {
        var data: ByteBuffer

        switch dataStrategy {
        case .noSpaceAtFront:
            data = buffer(capacity: size)
        case .spaceAtFront:
            data = buffer(capacity: size + 16)
            data.moveWriterIndex(forwardBy: 16)
            data.moveReaderIndex(forwardBy: 16)
        }

        data.writeBytes(repeatElement(0, count: size))
        return data
    }
}

private final class NoOpOutboundHandler: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any
}

private final class WriteConsumingHandler: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Never

    func write(context _: ChannelHandlerContext, data _: NIOAny, promise: EventLoopPromise<Void>?) {
        promise?.succeed(())
    }
}
