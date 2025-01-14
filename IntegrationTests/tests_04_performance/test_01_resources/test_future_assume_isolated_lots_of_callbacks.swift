//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOEmbedded

// This test is an equivalent of test_future_lots_of_callbacks.swift. It should
// have the same allocations as that test, and any difference is a bug.
func run(identifier: String) {
    measure(identifier: identifier) {
        struct MyError: Error {}
        @inline(never)
        func doThenAndFriends(loop: EventLoop) {
            let p = loop.makePromise(of: Int.self)
            let f = p.futureResult.assumeIsolated().flatMap { (r: Int) -> EventLoopFuture<Int> in
                // This call allocates a new Future, and
                // so does flatMap(), so this is two Futures.
                loop.makeSucceededFuture(r + 1)
            }.flatMapThrowing { (r: Int) -> Int in
                // flatMapThrowing allocates a new Future, and calls `flatMap`
                // which also allocates, so this is two.
                r + 2
            }.map { (r: Int) -> Int in
                // map allocates a new future, and calls `flatMap` which
                // also allocates, so this is two.
                r + 2
            }.flatMapThrowing { (r: Int) -> Int in
                // flatMapThrowing allocates a future on the error path and
                // calls `flatMap`, which also allocates, so this is two.
                throw MyError()
            }.flatMapError { (err: Error) -> EventLoopFuture<Int?> in
                // This call allocates a new Future, and so does flatMapError,
                // so this is two Futures.
                loop.makeFailedFuture(err)
            }.flatMapErrorThrowing { (err: Error) -> Int? in
                // flatMapError allocates a new Future, and calls flatMapError,
                // so this is two Futures
                throw err
            }.recover { (err: Error) -> Int? in
                // recover allocates a future, and calls flatMapError, so
                // this is two Futures.
                nil
            }.unwrap { () -> Int in
                // unwrap calls map, with an extra closure, so this is three.
                1
            }.always { (Int) -> Void in
                // This is a do-nothing call, but it can't be optimised out.
                // always calls whenComplete but adds a new closure, so it allocates
                // two times.
                _ = 1 + 1
            }.flatMapResult { (Int) -> Result<Int?, Error> in
                // flatMapResult allocates a new future and creates a _whenComplete closure,
                // so this is two.
                .success(5)
            }
            .unwrap(orReplace: 5)  // Same as unwrap above, this is three.

            // Add some when*.
            f.whenSuccess {
                // whenSuccess should be just one.
                _ = $0 + 1
            }
            f.whenFailure { _ in
                // whenFailure should also be just one.
                fatalError()
            }
            f.whenComplete {
                // whenComplete should also be just one.
                switch $0 {
                case .success:
                    ()
                case .failure:
                    fatalError()
                }
            }

            p.assumeIsolated().succeed(0)

            // Wait also allocates a lock.
            _ = try! f.nonisolated().wait()
        }
        @inline(never)
        func doAnd(loop: EventLoop) {
            // This isn't relevant to this test, but we keep it here to keep the numbers lining up.
            let p1 = loop.makePromise(of: Int.self)
            let p2 = loop.makePromise(of: Int.self)
            let p3 = loop.makePromise(of: Int.self)

            // Each call to and() allocates a Future. The calls to
            // and(result:) allocate two.

            let f = p1.futureResult
                .and(p2.futureResult)
                .and(p3.futureResult)
                .and(value: 1)
                .and(value: 1)

            p1.succeed(1)
            p2.succeed(1)
            p3.succeed(1)
            _ = try! f.wait()
        }

        let el = EmbeddedEventLoop()
        for _ in 0..<1000 {
            doThenAndFriends(loop: el)
            doAnd(loop: el)
        }
        return 1000
    }
}
