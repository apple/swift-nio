//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore
import NIOEmbedded
import NIOWebSocket

final class WebSocketFrameEncoderBenchmark {
    private let channel: EmbeddedChannel
    private let dataSize: Int
    private let data: ByteBuffer
    private let runCount: Int
    private let dataStrategy: DataStrategy
    private let cowStrategy: CoWStrategy
    private var maskingKey: Optional<WebSocketMaskingKey>
    private var frame: Optional<WebSocketFrame>

    init(
        dataSize: Int,
        runCount: Int,
        dataStrategy: DataStrategy,
        cowStrategy: CoWStrategy,
        maskingKeyStrategy: MaskingKeyStrategy
    ) {
        self.frame = nil
        self.channel = EmbeddedChannel()
        self.dataSize = dataSize
        self.runCount = runCount
        self.dataStrategy = dataStrategy
        self.cowStrategy = cowStrategy
        self.data = ByteBufferAllocator().buffer(size: dataSize, dataStrategy: dataStrategy)
        self.maskingKey = maskingKeyStrategy == MaskingKeyStrategy.always ? [0x80, 0x08, 0x10, 0x01] : nil
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
        try! self.channel.pipeline.syncOperations.addHandler(WriteConsumingHandler())
        for _ in 0..<3 {
            try! self.channel.pipeline.syncOperations.addHandler(NoOpOutboundHandler())
        }
        try! self.channel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder())
        self.frame = WebSocketFrame(opcode: .binary, maskKey: self.maskingKey, data: self.data, extensionData: nil)
    }

    func tearDown() {
        _ = try! self.channel.finish()
    }

    func run() throws -> Int {
        switch self.cowStrategy {
        case .always:
            let frame = self.frame!
            return self.runWithCoWs(frame: frame)
        case .never:
            return self.runWithoutCoWs()
        }
    }

    private func runWithCoWs(frame: WebSocketFrame) -> Int {
        for _ in 0..<self.runCount {
            self.channel.write(frame, promise: nil)
        }
        return 1
    }

    private func runWithoutCoWs() -> Int {
        for _ in 0..<self.runCount {
            // To avoid CoWs this has to be a new buffer every time. This is expensive, sadly, so tests using this strategy
            // must do fewer iterations.
            let data = self.channel.allocator.buffer(size: self.dataSize, dataStrategy: self.dataStrategy)
            let frame = WebSocketFrame(opcode: .binary, maskKey: self.maskingKey, data: data, extensionData: nil)
            self.channel.write(frame, promise: nil)
        }
        return 1
    }
}

extension ByteBufferAllocator {
    fileprivate func buffer(size: Int, dataStrategy: WebSocketFrameEncoderBenchmark.DataStrategy) -> ByteBuffer {
        var data: ByteBuffer

        switch dataStrategy {
        case .noSpaceAtFront:
            data = self.buffer(capacity: size)
        case .spaceAtFront:
            data = self.buffer(capacity: size + 16)
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

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        promise?.succeed(())
    }
}
