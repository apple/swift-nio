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

#if compiler(>=5.5.2) && canImport(_Concurrency)
import NIOCore
import DequeModule
import Atomics

struct NoOpDelegate: NIOAsyncWriterSinkDelegate, @unchecked Sendable {
    typealias Element = Int
    let counter = ManagedAtomic(0)

    func didYield(contentsOf sequence: Deque<Int>) {
        counter.wrappingIncrement(by: sequence.count, ordering: .relaxed)
    }

    func didTerminate(error: Never?) {}
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class NIOAsyncWriterSingleWritesBenchmark: AsyncBenchmark {
    private let iterations: Int
    private var delegate: NoOpDelegate!
    private var writer: NIOAsyncWriter<Int, Never, NoOpDelegate>!
    private var sink: NIOAsyncWriter<Int, Never, NoOpDelegate>.Sink!

    init(iterations: Int) {
        self.iterations = iterations
    }

    func setUp() async throws {
        self.delegate = .init()
        let newWriter = NIOAsyncWriter<Int, Never, NoOpDelegate>.makeWriter(isWritable: true, delegate: self.delegate)
        self.writer = newWriter.writer
        self.sink = newWriter.sink
    }

    func tearDown() {
        self.writer = nil
    }

    func run() async throws -> Int {
        for i in 0..<self.iterations {
            try await self.writer.yield(i)
        }
        return self.delegate.counter.load(ordering: .sequentiallyConsistent)
    }
}
#endif
