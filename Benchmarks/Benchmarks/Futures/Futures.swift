//
// Copyright (c) 2022 Ordo One AB.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//

import NIOPerformanceTester
import NIOCore
import Dispatch

import BenchmarkSupport
@main
extension BenchmarkRunner {}


@_dynamicReplacement(for: registerBenchmarks)
func benchmarks() {
    Benchmark.defaultConfiguration = .init(metrics:[.wallClock, .mallocCountTotal],
                                           warmupIterations: 0,
                                           scalingFactor: .kilo,
                                           maxDuration: .milliseconds(500),
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
