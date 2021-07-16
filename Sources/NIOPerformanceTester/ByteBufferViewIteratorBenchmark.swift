//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIO

final class ByteBufferViewIteratorBenchmark: Benchmark {
    private let iterations: Int
    private let bufferSize: Int
    private var buffer: ByteBuffer

    init(iterations: Int, bufferSize: Int) {
        self.iterations = iterations
        self.bufferSize = bufferSize
        buffer = ByteBufferAllocator().buffer(capacity: self.bufferSize)
    }

    func setUp() throws {
        buffer.writeBytes(Array(repeating: UInt8(ascii: "A"), count: bufferSize - 1))
        buffer.writeInteger(UInt8(ascii: "B"))
    }

    func tearDown() {}

    func run() -> Int {
        var which: UInt8 = 0
        for _ in 1 ... iterations {
            for byte in buffer.readableBytesView {
                if byte != UInt8(ascii: "A") {
                    which = byte
                }
            }
        }
        return Int(which)
    }
}
