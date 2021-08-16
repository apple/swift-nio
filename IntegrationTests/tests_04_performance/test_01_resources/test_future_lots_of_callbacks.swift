//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
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

func run(identifier: String) {
    measure(identifier: identifier) {
        struct MyError: Error { }
        @inline(never)
        func doThenAndFriends(loop: EventLoop) {
            let p = loop.makePromise(of: Int.self)
            let f = p.futureResult.flatMap { (r: Int) -> EventLoopFuture<Int> in
                // This call allocates a new Future, and
                // so does flatMap(), so this is two Futures.
                return loop.makeSucceededFuture(r + 1)
            }.flatMapThrowing { (r: Int) -> Int in
                // flatMapThrowing allocates a new Future, and calls `flatMap`
                // which also allocates, so this is two.
                return r + 2
            }.map { (r: Int) -> Int in
                // map allocates a new future, and calls `flatMap` which
                // also allocates, so this is two.
                return r + 2
            }.flatMapThrowing { (r: Int) -> Int in
                // flatMapThrowing allocates a future on the error path and
                // calls `flatMap`, which also allocates, so this is two.
                throw MyError()
            }.flatMapError { (err: Error) -> EventLoopFuture<Int> in
                // This call allocates a new Future, and so does flatMapError,
                // so this is two Futures.
                return loop.makeFailedFuture(err)
            }.flatMapErrorThrowing { (err: Error) -> Int in
                // flatMapError allocates a new Future, and calls flatMapError,
                // so this is two Futures
                throw err
            }.recover { (err: Error) -> Int in
                // recover allocates a future, and calls flatMapError, so
                // this is two Futures.
                return 1
            }
            p.succeed(0)

            // Wait also allocates a lock.
            _ = try! f.wait()
        }
        @inline(never)
        func doAnd(loop: EventLoop) {
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
        for _ in 0..<1000  {
            doThenAndFriends(loop: el)
            doAnd(loop: el)
        }
        return 1000
    }
}
