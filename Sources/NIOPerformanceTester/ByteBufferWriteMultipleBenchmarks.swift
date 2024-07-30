//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

final class ByteBufferReadWriteMultipleIntegersBenchmark<I: FixedWidthInteger>: Benchmark {
    private let iterations: Int
    private let numberOfInts: Int
    private var buffer: ByteBuffer = ByteBuffer()

    init(iterations: Int, numberOfInts: Int) {
        self.iterations = iterations
        self.numberOfInts = numberOfInts
    }

    func setUp() throws {
        self.buffer.reserveCapacity(self.numberOfInts * MemoryLayout<I>.size)
    }

    func tearDown() {
    }

    func run() throws -> Int {
        var result: I = 0
        for _ in 0..<self.iterations {
            self.buffer.clear()
            for i in I(0)..<I(10) {
                self.buffer.writeInteger(i)
            }
            for _ in I(0)..<I(10) {
                result = result &+ self.buffer.readInteger(as: I.self)!
            }
        }
        precondition(result == I(self.iterations) * 45)
        return self.buffer.readableBytes
    }
}

final class ByteBufferMultiReadWriteTenIntegersBenchmark<I: FixedWidthInteger>: Benchmark {
    private let iterations: Int
    private var buffer: ByteBuffer = ByteBuffer()

    init(iterations: Int) {
        self.iterations = iterations
    }

    func setUp() throws {
        self.buffer.reserveCapacity(10 * MemoryLayout<I>.size)
    }

    func tearDown() {
    }

    func run() throws -> Int {
        var result: I = 0
        for _ in 0..<self.iterations {
            self.buffer.clear()
            self.buffer.writeMultipleIntegers(
                0,
                1,
                2,
                3,
                4,
                5,
                6,
                7,
                8,
                9,
                as: (I, I, I, I, I, I, I, I, I, I).self
            )
            let value = self.buffer.readMultipleIntegers(as: (I, I, I, I, I, I, I, I, I, I).self)!
            result = result &+ value.0
            result = result &+ value.1
            result = result &+ value.2
            result = result &+ value.3
            result = result &+ value.4
            result = result &+ value.5
            result = result &+ value.6
            result = result &+ value.7
            result = result &+ value.8
            result = result &+ value.9
        }
        precondition(result == I(self.iterations) * 45)
        return self.buffer.readableBytes
    }
}
