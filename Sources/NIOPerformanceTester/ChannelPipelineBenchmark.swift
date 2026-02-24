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

final class ChannelPipelineBenchmark: Benchmark {
    private final class NoOpHandler: ChannelInboundHandler, RemovableChannelHandler, Sendable {
        typealias InboundIn = Any
    }
    private final class ConsumingHandler: ChannelInboundHandler, RemovableChannelHandler, Sendable {
        typealias InboundIn = Any

        func channelReadComplete(context: ChannelHandlerContext) {
        }
    }

    private let channel: EmbeddedChannel
    private let runCount: Int
    private let extraHandlers = 4
    private var handlers: [RemovableChannelHandler & Sendable] = []

    init(runCount: Int) {
        self.channel = EmbeddedChannel()
        self.runCount = runCount
    }

    func setUp() throws {
        for _ in 0..<self.extraHandlers {
            let handler = NoOpHandler()
            self.handlers.append(handler)
            try self.channel.pipeline.addHandler(handler).wait()
        }
        let handler = ConsumingHandler()
        self.handlers.append(handler)
        try self.channel.pipeline.addHandler(handler).wait()
    }

    func tearDown() {
        let handlersToRemove = self.handlers
        self.handlers.removeAll()
        for handler in handlersToRemove {
            try! self.channel.pipeline.removeHandler(handler).wait()
        }
    }

    func run() -> Int {
        for _ in 0..<self.runCount {
            self.channel.pipeline.fireChannelReadComplete()
        }
        return 1
    }
}
