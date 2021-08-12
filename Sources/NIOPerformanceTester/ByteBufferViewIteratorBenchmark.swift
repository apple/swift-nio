//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
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

final class ByteBufferViewIteratorBenchmark: Benchmark {
    private let iterations: Int
    private let bufferSize: Int
    private var buffer: ByteBuffer

    init(iterations: Int, bufferSize: Int) {
        self.iterations = iterations
        self.bufferSize = bufferSize
        self.buffer = ByteBufferAllocator().buffer(capacity: self.bufferSize)
    }

    func setUp() throws {
        self.buffer.writeBytes(Array(repeating: UInt8(ascii: "A"), count: self.bufferSize - 1))
        self.buffer.writeInteger(UInt8(ascii: "B"))
    }

    func tearDown() {
    }

    func run() -> Int {
        var which: UInt8 = 0
        for _ in 1...self.iterations {
            for byte in self.buffer.readableBytesView {
                if byte != UInt8(ascii: "A") {
                    which = byte
                }
            }
        }
        return Int(which)
    }

}
