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

public final class ByteBufferViewCopyToArrayBenchmark: Benchmark {
    private let iterations: Int
    private let size: Int
    private var view: ByteBufferView

    public init(iterations: Int, size: Int) {
        self.iterations = iterations
        self.size = size
        self.view = ByteBufferView()
    }

    public func setUp() throws {
        self.view = ByteBuffer(repeating: 0xfe, count: self.size).readableBytesView
    }

    public func tearDown() {
    }

    public func run() -> Int {
        var count = 0
        for _ in 0..<self.iterations {
            let array = Array(self.view)
            count &+= array.count
        }

        return count
    }
}
