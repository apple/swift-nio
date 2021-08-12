//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
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

final class ByteToMessageDecoderDecodeManySmallsBenchmark: Benchmark {
    private let iterations: Int
    private let buffer: ByteBuffer
    private let channel: EmbeddedChannel

    init(iterations: Int, bufferSize: Int) {
        self.iterations = iterations
        self.buffer = ByteBuffer(repeating: 0, count: bufferSize)
        self.channel = EmbeddedChannel(handler: ByteToMessageHandler(Decoder()))
    }

    func setUp() throws {
        try self.channel.connect(to: .init(ipAddress: "1.2.3.4", port: 5)).wait()
    }

    func tearDown() {
        precondition(try! self.channel.finish().isClean)
    }

    func run() -> Int {
        for _ in 1...self.iterations {
            try! self.channel.writeInbound(self.buffer)
        }
        return Int(self.buffer.readableBytes)
    }

    struct Decoder: ByteToMessageDecoder {
        typealias InboundOut = Never

        func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
            if buffer.readSlice(length: 16) == nil {
                return .needMoreData
            } else {
                return .continue
            }
        }
    }
}
