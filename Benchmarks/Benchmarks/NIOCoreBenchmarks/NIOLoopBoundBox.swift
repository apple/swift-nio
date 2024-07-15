//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
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
import Benchmark

func runNIOLoopBoundBoxInPlaceMutation(benchmark: Benchmark) {
    let embeddedEventLoop = EmbeddedEventLoop()
    let boundBox = NIOLoopBoundBox([Int](), eventLoop: embeddedEventLoop)
    boundBox.value.reserveCapacity(1)

    benchmark.startMeasurement()

    for _ in benchmark.scaledIterations {
        boundBox.value.removeAll(keepingCapacity: true)
        boundBox.value.append(1)
    }

    benchmark.stopMeasurement()

    precondition(boundBox.value.count == 1)
    precondition(boundBox.value.reduce(0, +) == 1)
}
