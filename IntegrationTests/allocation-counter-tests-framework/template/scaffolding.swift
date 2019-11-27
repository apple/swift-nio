//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import AtomicCounter
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin
#else
import Glibc
#endif

func measureAll(_ fn: () -> Int) -> [[String: Int]] {
    func measureOne(_ fn: () -> Int) -> [String: Int] {
        AtomicCounter.reset_free_counter()
        AtomicCounter.reset_malloc_counter()
        AtomicCounter.reset_malloc_bytes_counter()
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
        autoreleasepool {
            _ = fn()
        }
#else
        _ = fn()
#endif
        usleep(100_000) // allocs/frees happen on multiple threads, allow some cool down time
        let frees = AtomicCounter.read_free_counter()
        let mallocs = AtomicCounter.read_malloc_counter()
        let mallocedBytes = AtomicCounter.read_malloc_bytes_counter()
        return [
            "total_allocations": mallocs,
            "total_allocated_bytes": mallocedBytes,
            "remaining_allocations": mallocs - frees
        ]
    }

    _ = measureOne(fn) /* pre-heat and throw away */
    usleep(100_000) // allocs/frees happen on multiple threads, allow some cool down time
    var measurements: [[String: Int]] = []
    for _ in 0..<10 {
        measurements.append(measureOne(fn))
    }
    return measurements
}

func measureAndPrint(desc: String, fn: () -> Int) -> Void {
    let measurements = measureAll(fn)
    for k in measurements[0].keys {
        let vs = measurements.map { $0[k]! }
        print("\(desc).\(k): \(vs.min() ?? -1)")
    }
    print("DEBUG: \(measurements)")
}

public func measure(identifier: String, _ body: () -> Int) {
    measureAndPrint(desc: identifier) {
        return body()
    }
}
