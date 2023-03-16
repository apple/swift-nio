//
// Copyright (c) 2022 Ordo One AB.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//

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
