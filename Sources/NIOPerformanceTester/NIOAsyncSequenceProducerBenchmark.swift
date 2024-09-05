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

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class NIOAsyncSequenceProducerBenchmark: AsyncBenchmark, NIOAsyncSequenceProducerDelegate, @unchecked Sendable {
    fileprivate typealias SequenceProducer = NIOThrowingAsyncSequenceProducer<
        Int, Error, NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark, NIOAsyncSequenceProducerBenchmark
    >

    private let iterations: Int
    private var iterator: SequenceProducer.AsyncIterator!
    private var source: SequenceProducer.Source!
    private let elements = Array(repeating: 1, count: 1000)

    init(iterations: Int) {
        self.iterations = iterations
    }

    func setUp() async throws {
        let producer = SequenceProducer.makeSequence(
            backPressureStrategy: .init(lowWatermark: 100, highWatermark: 500),
            finishOnDeinit: false,
            delegate: self
        )
        self.iterator = producer.sequence.makeAsyncIterator()
        self.source = producer.source
    }
    func tearDown() {
        self.iterator = nil
        self.source = nil
    }

    func run() async throws -> Int {
        var counter = 0

        while let i = try await self.iterator.next(), counter < self.iterations {
            counter += i
        }
        return counter
    }

    func produceMore() {
        _ = self.source.yield(contentsOf: self.elements)
    }
    func didTerminate() {}
}
