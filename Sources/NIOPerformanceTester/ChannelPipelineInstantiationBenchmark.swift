//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
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

final class ChannelPipelineInstantiationBenchmark: Benchmark {
    private final class NoOpHandler: ChannelInboundHandler, Sendable {
        typealias InboundIn = Any
    }

    private var channel: EmbeddedChannel!
    private let runCount: Int
    private let handlerCount: Int

    init(runCount: Int, handlerCount: Int) {
        self.runCount = runCount
        self.handlerCount = handlerCount
    }

    func setUp() throws {
        self.channel = EmbeddedChannel()
    }

    func tearDown() {
        try! self.channel.close().wait()
        self.channel = nil
    }

    func run() -> Int {
        for _ in 0..<self.runCount {
            let pipeline = ChannelPipeline(channel: self.channel)
            if self.handlerCount > 0 {
                let syncOps = pipeline.syncOperations
                for _ in 0..<self.handlerCount {
                    try! syncOps.addHandler(NoOpHandler())
                }
            }
        }
        return self.runCount
    }
}
