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

import Foundation
import NIOCore

final class CircularBufferIntoByteBufferBenchmark: Benchmark {
    private let iterations: Int
    private let bufferSize: Int
    private var circularBuffer: CircularBuffer<UInt8>
    private var buffer: ByteBuffer

    init(iterations: Int, bufferSize: Int) {
        self.iterations = iterations
        self.bufferSize = bufferSize
        self.circularBuffer = CircularBuffer<UInt8>(initialCapacity: self.bufferSize)
        self.buffer = ByteBufferAllocator().buffer(capacity: self.bufferSize)
    }

    func setUp() throws {
        for i in 0..<self.bufferSize {
            self.circularBuffer.append(UInt8(i % 256))
        }
    }

    func tearDown() {
    }

    func run() -> Int {
        for _ in 1...self.iterations {
            self.buffer.writeBytes(self.circularBuffer)
            self.buffer.setBytes(self.circularBuffer, at: 0)
            self.buffer.clear()
        }
        return 1
    }
}
