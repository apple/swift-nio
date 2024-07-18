//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics
import DequeModule
import NIOCore

private struct NoOpDelegate: NIOAsyncWriterSinkDelegate, @unchecked Sendable {
    typealias Element = Int
    let counter = ManagedAtomic(0)

    func didYield(contentsOf sequence: Deque<Int>) {
        counter.wrappingIncrement(by: sequence.count, ordering: .relaxed)
    }

    func didTerminate(error: Error?) {}
}

// This is unchecked Sendable because the Sink is not Sendable but the Sink is thread safe
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class NIOAsyncWriterSingleWritesBenchmark: AsyncBenchmark, @unchecked Sendable {
    private let iterations: Int
    private let delegate: NoOpDelegate
    private let writer: NIOAsyncWriter<Int, NoOpDelegate>
    private let sink: NIOAsyncWriter<Int, NoOpDelegate>.Sink

    init(iterations: Int) {
        self.iterations = iterations
        self.delegate = .init()
        let newWriter = NIOAsyncWriter<Int, NoOpDelegate>.makeWriter(
            isWritable: true,
            finishOnDeinit: false,
            delegate: self.delegate
        )
        self.writer = newWriter.writer
        self.sink = newWriter.sink
    }

    func setUp() async throws {}
    func tearDown() {
        self.writer.finish()
    }

    func run() async throws -> Int {
        for i in 0..<self.iterations {
            try await self.writer.yield(i)
        }
        return self.delegate.counter.load(ordering: .sequentiallyConsistent)
    }
}
