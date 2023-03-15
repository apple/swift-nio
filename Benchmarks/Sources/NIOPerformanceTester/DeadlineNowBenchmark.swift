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

public final class DeadlineNowBenchmark: Benchmark {
    private let iterations: Int

    public init(iterations: Int) {
        self.iterations = iterations
    }

    public func setUp() throws {
    }

    public func tearDown() {
    }

    public func run() -> Int {
        var counter: UInt64 = 0
        for _ in 0..<self.iterations {
            let now = NIODeadline.now().uptimeNanoseconds
            counter &+= now
        }
        return Int(truncatingIfNeeded: counter)
    }
}
