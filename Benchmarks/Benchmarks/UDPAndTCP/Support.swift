//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOPerformanceTester
import BenchmarkSupport

func runNIOBenchmark<B: NIOPerformanceTester.Benchmark>(benchmark: BenchmarkSupport.Benchmark,
                                                        running: B) throws {
    try running.setUp()
    defer {
        running.tearDown()
    }

    benchmark.startMeasurement()
    blackHole(try running.run())
    benchmark.stopMeasurement()
}

func runNIOBenchmark<B: NIOPerformanceTester.AsyncBenchmark>(benchmark: BenchmarkSupport.Benchmark,
                                                             running: B) async throws {
    try await running.setUp()
    defer {
        running.tearDown()
    }

    benchmark.startMeasurement()
    blackHole(try await running.run())
    benchmark.stopMeasurement()
}
