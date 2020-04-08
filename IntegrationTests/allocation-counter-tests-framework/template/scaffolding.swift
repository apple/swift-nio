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

func waitForThreadsToQuiesce(shouldReachZero: Bool) {
    func getUnfreed() -> Int {
        return AtomicCounter.read_malloc_counter() - AtomicCounter.read_free_counter()
    }

    var oldNumberOfUnfreed = getUnfreed()
    var count = 0
    repeat {
        guard count < 100 else {
            print("WARNING: Giving up, shouldReachZero=\(shouldReachZero), unfreeds=\(oldNumberOfUnfreed)")
            return
        }
        count += 1
        usleep(shouldReachZero ? 50_000 : 200_000) // allocs/frees happen on multiple threads, allow some cool down time
        let newNumberOfUnfreed = getUnfreed()
        if oldNumberOfUnfreed == newNumberOfUnfreed && (!shouldReachZero || newNumberOfUnfreed <= 0) {
            // nothing happened in the last 100ms, let's assume everything's
            // calmed down already.
            if count > 5 || newNumberOfUnfreed != 0 {
                print("DEBUG: After waiting \(count) times, we quiesced to unfreeds=\(newNumberOfUnfreed)")
            }
            return
        }
        oldNumberOfUnfreed = newNumberOfUnfreed
    } while true
}

func measureAll(_ fn: () -> Int) -> [[String: Int]] {
    func measureOne(throwAway: Bool = false, _ fn: () -> Int) -> [String: Int]? {
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
        waitForThreadsToQuiesce(shouldReachZero: !throwAway)
        let frees = AtomicCounter.read_free_counter()
        let mallocs = AtomicCounter.read_malloc_counter()
        let mallocedBytes = AtomicCounter.read_malloc_bytes_counter()
        if mallocs - frees < 0 {
            print("WARNING: negative remaining allocation count, skipping.")
            return nil
        }
        return [
            "total_allocations": mallocs,
            "total_allocated_bytes": mallocedBytes,
            "remaining_allocations": mallocs - frees
        ]
    }

    _ = measureOne(throwAway: true, fn) /* pre-heat and throw away */

    var measurements: [[String: Int]] = []
    for _ in 0..<10 {
        if let results = measureOne(fn) {
            measurements.append(results)
        }
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
