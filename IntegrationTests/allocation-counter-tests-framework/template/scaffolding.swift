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

import AtomicCounter
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#else
#error("The integration test scaffolding was unable to identify your C library.")
#endif

func waitForThreadsToQuiesce(shouldReachZero: Bool) {
    func getUnfreed() -> Int {
        AtomicCounter.read_malloc_counter() - AtomicCounter.read_free_counter()
    }

    var oldNumberOfUnfreed = getUnfreed()
    var count = 0
    repeat {
        guard count < 100 else {
            print("WARNING: Giving up, shouldReachZero=\(shouldReachZero), unfreeds=\(oldNumberOfUnfreed)")
            return
        }
        count += 1
        // allocs/frees happen on multiple threads, allow some cool down time
        usleep(shouldReachZero ? 50_000 : 200_000)
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

struct Measurement {
    var totalAllocations: Int
    var totalAllocatedBytes: Int
    var remainingAllocations: Int
    var leakedFDs: [CInt]
}

extension Array where Element == Measurement {
    private func printIntegerMetric(
        _ keyPath: KeyPath<Measurement, Int>,
        description desc: String,
        metricName k: String
    ) {
        let vs = self.map { $0[keyPath: keyPath] }
        print("\(desc).\(k): \(vs.min() ?? -1)")
    }

    func printTotalAllocations(description: String) {
        self.printIntegerMetric(\.totalAllocations, description: description, metricName: "total_allocations")
    }

    func printTotalAllocatedBytes(description: String) {
        self.printIntegerMetric(\.totalAllocatedBytes, description: description, metricName: "total_allocated_bytes")
    }

    func printRemainingAllocations(description: String) {
        self.printIntegerMetric(\.remainingAllocations, description: description, metricName: "remaining_allocations")
    }

    func printLeakedFDs(description desc: String) {
        let vs = self.map { $0.leakedFDs }.filter { !$0.isEmpty }
        print("\(desc).leaked_fds: \(vs.first.map { $0.count } ?? 0)")
    }
}

func measureAll(trackFDs: Bool, _ fn: () -> Int) -> [Measurement] {
    func measureOne(throwAway: Bool = false, trackFDs: Bool, _ fn: () -> Int) -> Measurement? {
        AtomicCounter.reset_free_counter()
        AtomicCounter.reset_malloc_counter()
        AtomicCounter.reset_malloc_bytes_counter()

        if trackFDs {
            AtomicCounter.begin_tracking_fds()
        }

        #if canImport(Darwin)
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
        var leakedFDs: [CInt] = []
        if trackFDs {
            let leaks = AtomicCounter.stop_tracking_fds()
            defer {
                free(leaks.leaked)
            }
            leakedFDs = Array(UnsafeBufferPointer(start: leaks.leaked, count: leaks.count))
        }
        if mallocs - frees < 0 {
            print("WARNING: negative remaining allocation count, skipping.")
            return nil
        }
        return Measurement(
            totalAllocations: mallocs,
            totalAllocatedBytes: mallocedBytes,
            remainingAllocations: mallocs - frees,
            leakedFDs: leakedFDs
        )
    }

    _ = measureOne(throwAway: true, trackFDs: trackFDs, fn)  // pre-heat and throw away

    var measurements: [Measurement] = []
    for _ in 0..<10 {
        if let results = measureOne(trackFDs: trackFDs, fn) {
            measurements.append(results)
        }
    }
    return measurements
}

func measureAndPrint(desc: String, trackFDs: Bool, fn: () -> Int) {
    let measurements = measureAll(trackFDs: trackFDs, fn)
    measurements.printTotalAllocations(description: desc)
    measurements.printRemainingAllocations(description: desc)
    measurements.printTotalAllocatedBytes(description: desc)
    measurements.printLeakedFDs(description: desc)

    print("DEBUG: \(measurements)")
}

public func measure(identifier: String, trackFDs: Bool = false, _ body: () -> Int) {
    measureAndPrint(desc: identifier, trackFDs: trackFDs) {
        body()
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
func measureAll(trackFDs: Bool, _ fn: @escaping () async -> Int) -> [Measurement] {
    func measureOne(throwAway: Bool = false, trackFDs: Bool, _ fn: @escaping () async -> Int) -> Measurement? {
        func run(_ fn: @escaping () async -> Int) {
            let group = DispatchGroup()
            group.enter()
            Task {
                _ = await fn()
                group.leave()
            }
            group.wait()
        }

        if trackFDs {
            AtomicCounter.begin_tracking_fds()
        }

        AtomicCounter.reset_free_counter()
        AtomicCounter.reset_malloc_counter()
        AtomicCounter.reset_malloc_bytes_counter()

        #if canImport(Darwin)
        autoreleasepool {
            run(fn)
        }
        #else
        run(fn)
        #endif
        waitForThreadsToQuiesce(shouldReachZero: !throwAway)
        let frees = AtomicCounter.read_free_counter()
        let mallocs = AtomicCounter.read_malloc_counter()
        let mallocedBytes = AtomicCounter.read_malloc_bytes_counter()
        var leakedFDs: [CInt] = []
        if trackFDs {
            let leaks = AtomicCounter.stop_tracking_fds()
            defer {
                free(leaks.leaked)
            }
            leakedFDs = Array(UnsafeBufferPointer(start: leaks.leaked, count: leaks.count))
        }
        if mallocs - frees < 0 {
            print("WARNING: negative remaining allocation count, skipping.")
            return nil
        }
        return Measurement(
            totalAllocations: mallocs,
            totalAllocatedBytes: mallocedBytes,
            remainingAllocations: mallocs - frees,
            leakedFDs: leakedFDs
        )
    }

    _ = measureOne(throwAway: true, trackFDs: trackFDs, fn)  // pre-heat and throw away

    var measurements: [Measurement] = []
    for _ in 0..<10 {
        if let results = measureOne(trackFDs: trackFDs, fn) {
            measurements.append(results)
        }
    }
    return measurements
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
func measureAndPrint(desc: String, trackFDs: Bool, fn: @escaping () async -> Int) {
    let measurements = measureAll(trackFDs: trackFDs, fn)
    measurements.printTotalAllocations(description: desc)
    measurements.printRemainingAllocations(description: desc)
    measurements.printTotalAllocatedBytes(description: desc)
    measurements.printLeakedFDs(description: desc)
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public func measure(identifier: String, trackFDs: Bool = false, _ body: @escaping () async -> Int) {
    measureAndPrint(desc: identifier, trackFDs: trackFDs, fn: body)
}
