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

import NIOCore

final class CircularBufferViewCopyToArrayBenchmark: Benchmark {
    private let iterations: Int
    private let size: Int
    private var buffer: CircularBuffer<UInt8>

    init(iterations: Int, size: Int) {
        self.iterations = iterations
        self.size = size
        self.buffer = CircularBuffer()
    }

    func setUp() throws {
        self.buffer = CircularBuffer(repeating: UInt8(0xfe), count: self.size)
    }

    func tearDown() {
    }

    func run() -> Int {
        var count = 0
        for _ in 0..<self.iterations {
            let array = Array(self.buffer)
            count &+= array.count
        }

        return count
    }
}
