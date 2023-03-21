//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOPerformanceTester
import NIOCore
import Dispatch
import Benchmark

let benchmarks = {
    Benchmark.defaultConfiguration = .init(metrics:[.wallClock, .mallocCountTotal, .throughput],
                                           warmupIterations: 0,
                                           maxDuration: .seconds(1),
                                           maxIterations: Int.max)

   Benchmark("future_whenallsucceed_100k_immediately_succeeded_off_loop") { benchmark in
        let loop = group.next()
        let expected = Array(0..<100_000)
        let futures = expected.map { loop.makeSucceededFuture($0) }
        let allSucceeded = try! EventLoopFuture.whenAllSucceed(futures, on: loop).wait()
        blackHole(allSucceeded.count)
    }

    Benchmark("future_whenallsucceed_100k_immediately_succeeded_on_loop") { benchmark in
        let loop = group.next()
        let expected = Array(0..<100_000)
        let allSucceeded = try! loop.makeSucceededFuture(()).flatMap { _ -> EventLoopFuture<[Int]> in
            let futures = expected.map { loop.makeSucceededFuture($0) }
            return EventLoopFuture.whenAllSucceed(futures, on: loop)
        }.wait()
        blackHole(allSucceeded.count)
    }

    Benchmark("future_whenallsucceed_10k_deferred_off_loop") { benchmark in
        let loop = group.next()
        let expected = Array(0..<10_000)
        let promises = expected.map { _ in loop.makePromise(of: Int.self) }
        let allSucceeded = EventLoopFuture.whenAllSucceed(promises.map { $0.futureResult }, on: loop)
        for (index, promise) in promises.enumerated() {
            promise.succeed(index)
        }
        blackHole(try! allSucceeded.wait().count)
    }

    Benchmark("future_whenallsucceed_10k_deferred_on_loop") { benchmark in
        let loop = group.next()
        let expected = Array(0..<10_000)
        let promises = expected.map { _ in loop.makePromise(of: Int.self) }
        let allSucceeded = try! loop.makeSucceededFuture(()).flatMap { _ -> EventLoopFuture<[Int]> in
            let result = EventLoopFuture.whenAllSucceed(promises.map { $0.futureResult }, on: loop)
            for (index, promise) in promises.enumerated() {
                promise.succeed(index)
            }
            return result
        }.wait()
        blackHole(allSucceeded.count)
    }

    Benchmark("future_whenallcomplete_100k_immediately_succeeded_off_loop") { benchmark in
        let loop = group.next()
        let expected = Array(0..<100_000)
        let futures = expected.map { loop.makeSucceededFuture($0) }
        let allSucceeded = try! EventLoopFuture.whenAllComplete(futures, on: loop).wait()
        blackHole(allSucceeded.count)
    }

    Benchmark("future_whenallcomplete_100k_immediately_succeeded_on_loop") { benchmark in
        let loop = group.next()
        let expected = Array(0..<100_000)
        let allSucceeded = try! loop.makeSucceededFuture(()).flatMap { _ -> EventLoopFuture<[Result<Int, Error>]> in
            let futures = expected.map { loop.makeSucceededFuture($0) }
            return EventLoopFuture.whenAllComplete(futures, on: loop)
        }.wait()
        blackHole(allSucceeded.count)
    }

    Benchmark("future_whenallcomplete_10k_deferred_off_loop") { benchmark in
        let loop = group.next()
        let expected = Array(0..<10_000)
        let promises = expected.map { _ in loop.makePromise(of: Int.self) }
        let allSucceeded = EventLoopFuture.whenAllComplete(promises.map { $0.futureResult }, on: loop)
        for (index, promise) in promises.enumerated() {
            promise.succeed(index)
        }
        blackHole(try! allSucceeded.wait().count)
    }

    Benchmark("future_whenallcomplete_100k_deferred_on_loop") { benchmark in
        let loop = group.next()
        let expected = Array(0..<100_000)
        let promises = expected.map { _ in loop.makePromise(of: Int.self) }
        let allSucceeded = try! loop.makeSucceededFuture(()).flatMap { _ -> EventLoopFuture<[Result<Int, Error>]> in
            let result = EventLoopFuture.whenAllComplete(promises.map { $0.futureResult }, on: loop)
            for (index, promise) in promises.enumerated() {
                promise.succeed(index)
            }
            return result
        }.wait()
        blackHole(allSucceeded.count)
    }

    Benchmark("future_reduce_10k_futures") { benchmark in
        let el1 = group.next()

        let futures = (1...10_000).map { i in el1.makeSucceededFuture(i) }
        blackHole(try! EventLoopFuture<Int>.reduce(0, futures, on: el1, +).wait())
    }

    Benchmark("future_reduce_into_10k_futures") { benchmark in
        let el1 = group.next()

        let futures = (1...10_000).map { i in el1.makeSucceededFuture(i) }
        blackHole(try! EventLoopFuture<Int>.reduce(into: 0, futures, on: el1, { $0 += $1 }).wait())
    }
}
