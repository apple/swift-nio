//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Benchmark

let benchmarks = {
    let defaultMetrics: [BenchmarkMetric] = [
        .mallocCountTotal,
    ]

    Benchmark(
        "TCPEcho",
        configuration: .init(
            metrics: defaultMetrics,
            timeUnits: .milliseconds,
            scalingFactor: .mega
        )
    ) { benchmark in
        try runTCPEcho(numberOfWrites: benchmark.scaledIterations.upperBound)
    }
}
