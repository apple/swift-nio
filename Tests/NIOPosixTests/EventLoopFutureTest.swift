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

import Atomics
import Dispatch
import NIOConcurrencyHelpers
import NIOEmbedded
import NIOPosix
import XCTest

@testable import NIOCore

enum EventLoopFutureTestError: Error {
    case example
}

class EventLoopFutureTest: XCTestCase {
    func testFutureFulfilledIfHasResult() throws {
        let eventLoop = EmbeddedEventLoop()
        let f = EventLoopFuture(eventLoop: eventLoop, value: 5)
        XCTAssertTrue(f.isFulfilled)
    }

    func testFutureFulfilledIfHasError() throws {
        let eventLoop = EmbeddedEventLoop()
        let f = EventLoopFuture<Void>(eventLoop: eventLoop, error: EventLoopFutureTestError.example)
        XCTAssertTrue(f.isFulfilled)
    }

    func testFoldWithMultipleEventLoops() throws {
        let nThreads = 3
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: nThreads)
        defer {
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }

        let eventLoop0 = eventLoopGroup.next()
        let eventLoop1 = eventLoopGroup.next()
        let eventLoop2 = eventLoopGroup.next()

        XCTAssert(eventLoop0 !== eventLoop1)
        XCTAssert(eventLoop1 !== eventLoop2)
        XCTAssert(eventLoop0 !== eventLoop2)

        let f0: EventLoopFuture<[Int]> = eventLoop0.submit { [0] }
        let f1s: [EventLoopFuture<Int>] = (1...4).map { id in eventLoop1.submit { id } }
        let f2s: [EventLoopFuture<Int>] = (5...8).map { id in eventLoop2.submit { id } }

        var fN = f0.fold(f1s) { (f1Value: [Int], f2Value: Int) -> EventLoopFuture<[Int]> in
            XCTAssert(eventLoop0.inEventLoop)
            return eventLoop1.makeSucceededFuture(f1Value + [f2Value])
        }

        fN = fN.fold(f2s) { (f1Value: [Int], f2Value: Int) -> EventLoopFuture<[Int]> in
            XCTAssert(eventLoop0.inEventLoop)
            return eventLoop2.makeSucceededFuture(f1Value + [f2Value])
        }

        let allValues = try fN.wait()
        XCTAssert(fN.eventLoop === f0.eventLoop)
        XCTAssert(fN.isFulfilled)
        XCTAssertEqual(allValues, [0, 1, 2, 3, 4, 5, 6, 7, 8])
    }

    func testFoldWithSuccessAndAllSuccesses() throws {
        let eventLoop = EmbeddedEventLoop()
        let secondEventLoop = EmbeddedEventLoop()
        let f0 = eventLoop.makeSucceededFuture([0])

        let futures: [EventLoopFuture<Int>] = (1...5).map { (id: Int) in secondEventLoop.makeSucceededFuture(id) }

        let fN = f0.fold(futures) { (f1Value: [Int], f2Value: Int) -> EventLoopFuture<[Int]> in
            XCTAssert(eventLoop.inEventLoop)
            return secondEventLoop.makeSucceededFuture(f1Value + [f2Value])
        }

        let allValues = try fN.wait()
        XCTAssert(fN.eventLoop === f0.eventLoop)
        XCTAssert(fN.isFulfilled)
        XCTAssertEqual(allValues, [0, 1, 2, 3, 4, 5])
    }

    func testFoldWithSuccessAndOneFailure() throws {
        struct E: Error {}
        let eventLoop = EmbeddedEventLoop()
        let secondEventLoop = EmbeddedEventLoop()
        let f0: EventLoopFuture<Int> = eventLoop.makeSucceededFuture(0)

        let promises: [EventLoopPromise<Int>] = (0..<100).map { (_: Int) in secondEventLoop.makePromise() }
        var futures = promises.map { $0.futureResult }
        let failedFuture: EventLoopFuture<Int> = secondEventLoop.makeFailedFuture(E())
        futures.insert(failedFuture, at: futures.startIndex)

        let fN = f0.fold(futures) { (f1Value: Int, f2Value: Int) -> EventLoopFuture<Int> in
            XCTAssert(eventLoop.inEventLoop)
            return secondEventLoop.makeSucceededFuture(f1Value + f2Value)
        }

        _ = promises.map { $0.succeed(0) }
        XCTAssert(fN.isFulfilled)
        XCTAssertThrowsError(try fN.wait()) { error in
            XCTAssertNotNil(error as? E)
        }
    }

    func testFoldWithSuccessAndEmptyFutureList() throws {
        let eventLoop = EmbeddedEventLoop()
        let f0 = eventLoop.makeSucceededFuture(0)

        let futures: [EventLoopFuture<Int>] = []

        let fN = f0.fold(futures) { (f1Value: Int, f2Value: Int) -> EventLoopFuture<Int> in
            XCTAssert(eventLoop.inEventLoop)
            return eventLoop.makeSucceededFuture(f1Value + f2Value)
        }

        let summationResult = try fN.wait()
        XCTAssert(fN.isFulfilled)
        XCTAssertEqual(summationResult, 0)
    }

    func testFoldWithFailureAndEmptyFutureList() throws {
        struct E: Error {}
        let eventLoop = EmbeddedEventLoop()
        let f0: EventLoopFuture<Int> = eventLoop.makeFailedFuture(E())

        let futures: [EventLoopFuture<Int>] = []

        let fN = f0.fold(futures) { (f1Value: Int, f2Value: Int) -> EventLoopFuture<Int> in
            XCTAssert(eventLoop.inEventLoop)
            return eventLoop.makeSucceededFuture(f1Value + f2Value)
        }

        XCTAssert(fN.isFulfilled)
        XCTAssertThrowsError(try fN.wait()) { error in
            XCTAssertNotNil(error as? E)
        }
    }

    func testFoldWithFailureAndAllSuccesses() throws {
        struct E: Error {}
        let eventLoop = EmbeddedEventLoop()
        let secondEventLoop = EmbeddedEventLoop()
        let f0: EventLoopFuture<Int> = eventLoop.makeFailedFuture(E())

        let promises: [EventLoopPromise<Int>] = (0..<100).map { (_: Int) in secondEventLoop.makePromise() }
        let futures = promises.map { $0.futureResult }

        let fN = f0.fold(futures) { (f1Value: Int, f2Value: Int) -> EventLoopFuture<Int> in
            XCTAssert(eventLoop.inEventLoop)
            return secondEventLoop.makeSucceededFuture(f1Value + f2Value)
        }

        _ = promises.map { $0.succeed(1) }
        XCTAssert(fN.isFulfilled)
        XCTAssertThrowsError(try fN.wait()) { error in
            XCTAssertNotNil(error as? E)
        }
    }

    func testFoldWithFailureAndAllUnfulfilled() throws {
        struct E: Error {}
        let eventLoop = EmbeddedEventLoop()
        let secondEventLoop = EmbeddedEventLoop()
        let f0: EventLoopFuture<Int> = eventLoop.makeFailedFuture(E())

        let promises: [EventLoopPromise<Int>] = (0..<100).map { (_: Int) in secondEventLoop.makePromise() }
        let futures = promises.map { $0.futureResult }

        let fN = f0.fold(futures) { (f1Value: Int, f2Value: Int) -> EventLoopFuture<Int> in
            XCTAssert(eventLoop.inEventLoop)
            return secondEventLoop.makeSucceededFuture(f1Value + f2Value)
        }

        XCTAssert(fN.isFulfilled)
        XCTAssertThrowsError(try fN.wait()) { error in
            XCTAssertNotNil(error as? E)
        }
    }

    func testFoldWithFailureAndAllFailures() throws {
        struct E: Error {}
        let eventLoop = EmbeddedEventLoop()
        let secondEventLoop = EmbeddedEventLoop()
        let f0: EventLoopFuture<Int> = eventLoop.makeFailedFuture(E())

        let futures: [EventLoopFuture<Int>] = (0..<100).map { (_: Int) in secondEventLoop.makeFailedFuture(E()) }

        let fN = f0.fold(futures) { (f1Value: Int, f2Value: Int) -> EventLoopFuture<Int> in
            XCTAssert(eventLoop.inEventLoop)
            return secondEventLoop.makeSucceededFuture(f1Value + f2Value)
        }

        XCTAssert(fN.isFulfilled)
        XCTAssertThrowsError(try fN.wait()) { error in
            XCTAssertNotNil(error as? E)
        }
    }

    func testAndAllWithEmptyFutureList() throws {
        let eventLoop = EmbeddedEventLoop()
        let futures: [EventLoopFuture<Void>] = []

        let fN = EventLoopFuture.andAllSucceed(futures, on: eventLoop)

        XCTAssert(fN.isFulfilled)
    }

    func testAndAllWithAllSuccesses() throws {
        let eventLoop = EmbeddedEventLoop()
        let promises: [EventLoopPromise<Void>] = (0..<100).map { (_: Int) in eventLoop.makePromise() }
        let futures = promises.map { $0.futureResult }

        let fN = EventLoopFuture.andAllSucceed(futures, on: eventLoop)
        _ = promises.map { $0.succeed(()) }
        () = try fN.wait()
    }

    func testAndAllWithAllFailures() throws {
        struct E: Error {}
        let eventLoop = EmbeddedEventLoop()
        let promises: [EventLoopPromise<Void>] = (0..<100).map { (_: Int) in eventLoop.makePromise() }
        let futures = promises.map { $0.futureResult }

        let fN = EventLoopFuture.andAllSucceed(futures, on: eventLoop)
        _ = promises.map { $0.fail(E()) }
        XCTAssertThrowsError(try fN.wait()) { error in
            XCTAssertNotNil(error as? E)
        }
    }

    func testAndAllWithOneFailure() throws {
        struct E: Error {}
        let eventLoop = EmbeddedEventLoop()
        var promises: [EventLoopPromise<Void>] = (0..<100).map { (_: Int) in eventLoop.makePromise() }
        _ = promises.map { $0.succeed(()) }
        let failedPromise = eventLoop.makePromise(of: Void.self)
        failedPromise.fail(E())
        promises.append(failedPromise)

        let futures = promises.map { $0.futureResult }

        let fN = EventLoopFuture.andAllSucceed(futures, on: eventLoop)
        XCTAssertThrowsError(try fN.wait()) { error in
            XCTAssertNotNil(error as? E)
        }
    }

    func testReduceWithAllSuccesses() throws {
        let eventLoop = EmbeddedEventLoop()
        let promises: [EventLoopPromise<Int>] = (0..<5).map { (_: Int) in eventLoop.makePromise() }
        let futures = promises.map { $0.futureResult }

        let fN: EventLoopFuture<[Int]> = EventLoopFuture<[Int]>.reduce(into: [], futures, on: eventLoop) {
            $0.append($1)
        }
        for i in 1...5 {
            promises[i - 1].succeed((i))
        }
        let results = try fN.wait()
        XCTAssertEqual(results, [1, 2, 3, 4, 5])
        XCTAssert(fN.eventLoop === eventLoop)
    }

    func testReduceWithOnlyInitialValue() throws {
        let eventLoop = EmbeddedEventLoop()
        let futures: [EventLoopFuture<Int>] = []

        let fN: EventLoopFuture<[Int]> = EventLoopFuture<[Int]>.reduce(into: [], futures, on: eventLoop) {
            $0.append($1)
        }

        let results = try fN.wait()
        XCTAssertEqual(results, [])
        XCTAssert(fN.eventLoop === eventLoop)
    }

    func testReduceWithAllFailures() throws {
        struct E: Error {}
        let eventLoop = EmbeddedEventLoop()
        let promises: [EventLoopPromise<Int>] = (0..<100).map { (_: Int) in eventLoop.makePromise() }
        let futures = promises.map { $0.futureResult }

        let fN: EventLoopFuture<Int> = EventLoopFuture<Int>.reduce(0, futures, on: eventLoop) { $0 + $1 }
        _ = promises.map { $0.fail(E()) }
        XCTAssert(fN.eventLoop === eventLoop)
        XCTAssertThrowsError(try fN.wait()) { error in
            XCTAssertNotNil(error as? E)
        }
    }

    func testReduceWithOneFailure() throws {
        struct E: Error {}
        let eventLoop = EmbeddedEventLoop()
        var promises: [EventLoopPromise<Int>] = (0..<100).map { (_: Int) in eventLoop.makePromise() }
        _ = promises.map { $0.succeed((1)) }
        let failedPromise = eventLoop.makePromise(of: Int.self)
        failedPromise.fail(E())
        promises.append(failedPromise)

        let futures = promises.map { $0.futureResult }

        let fN: EventLoopFuture<Int> = EventLoopFuture<Int>.reduce(0, futures, on: eventLoop) { $0 + $1 }
        XCTAssert(fN.eventLoop === eventLoop)
        XCTAssertThrowsError(try fN.wait()) { error in
            XCTAssertNotNil(error as? E)
        }
    }

    func testReduceWhichDoesFailFast() throws {
        struct E: Error {}
        let eventLoop = EmbeddedEventLoop()
        var promises: [EventLoopPromise<Int>] = (0..<100).map { (_: Int) in eventLoop.makePromise() }

        let failedPromise = eventLoop.makePromise(of: Int.self)
        promises.insert(failedPromise, at: promises.startIndex)

        let futures = promises.map { $0.futureResult }
        let fN: EventLoopFuture<Int> = EventLoopFuture<Int>.reduce(0, futures, on: eventLoop) { $0 + $1 }

        failedPromise.fail(E())

        XCTAssertTrue(fN.isFulfilled)
        XCTAssert(fN.eventLoop === eventLoop)
        XCTAssertThrowsError(try fN.wait()) { error in
            XCTAssertNotNil(error as? E)
        }
    }

    func testReduceIntoWithAllSuccesses() throws {
        let eventLoop = EmbeddedEventLoop()
        let futures: [EventLoopFuture<Int>] = [1, 2, 2, 3, 3, 3].map { (id: Int) in eventLoop.makeSucceededFuture(id) }

        let fN: EventLoopFuture<[Int: Int]> = EventLoopFuture<[Int: Int]>.reduce(into: [:], futures, on: eventLoop) {
            (freqs, elem) in
            if let value = freqs[elem] {
                freqs[elem] = value + 1
            } else {
                freqs[elem] = 1
            }
        }

        let results = try fN.wait()
        XCTAssertEqual(results, [1: 1, 2: 2, 3: 3])
        XCTAssert(fN.eventLoop === eventLoop)
    }

    func testReduceIntoWithEmptyFutureList() throws {
        let eventLoop = EmbeddedEventLoop()
        let futures: [EventLoopFuture<Int>] = []

        let fN: EventLoopFuture<[Int: Int]> = EventLoopFuture<[Int: Int]>.reduce(into: [:], futures, on: eventLoop) {
            (freqs, elem) in
            if let value = freqs[elem] {
                freqs[elem] = value + 1
            } else {
                freqs[elem] = 1
            }
        }

        let results = try fN.wait()
        XCTAssert(results.isEmpty)
        XCTAssert(fN.eventLoop === eventLoop)
    }

    func testReduceIntoWithAllFailure() throws {
        struct E: Error {}
        let eventLoop = EmbeddedEventLoop()
        let futures: [EventLoopFuture<Int>] = [1, 2, 2, 3, 3, 3].map { (id: Int) in eventLoop.makeFailedFuture(E()) }

        let fN: EventLoopFuture<[Int: Int]> = EventLoopFuture<[Int: Int]>.reduce(into: [:], futures, on: eventLoop) {
            (freqs, elem) in
            if let value = freqs[elem] {
                freqs[elem] = value + 1
            } else {
                freqs[elem] = 1
            }
        }

        XCTAssert(fN.isFulfilled)
        XCTAssert(fN.eventLoop === eventLoop)
        XCTAssertThrowsError(try fN.wait()) { error in
            XCTAssertNotNil(error as? E)
        }
    }

    func testReduceIntoWithMultipleEventLoops() throws {
        let nThreads = 3
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: nThreads)
        defer {
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }

        let eventLoop0 = eventLoopGroup.next()
        let eventLoop1 = eventLoopGroup.next()
        let eventLoop2 = eventLoopGroup.next()

        XCTAssert(eventLoop0 !== eventLoop1)
        XCTAssert(eventLoop1 !== eventLoop2)
        XCTAssert(eventLoop0 !== eventLoop2)

        let f0: EventLoopFuture<[Int: Int]> = eventLoop0.submit { [:] }
        let f1s: [EventLoopFuture<Int>] = (1...4).map { id in eventLoop1.submit { id / 2 } }
        let f2s: [EventLoopFuture<Int>] = (5...8).map { id in eventLoop2.submit { id / 2 } }

        let fN = EventLoopFuture<[Int: Int]>.reduce(into: [:], f1s + f2s, on: eventLoop0) { (freqs, elem) in
            XCTAssert(eventLoop0.inEventLoop)
            if let value = freqs[elem] {
                freqs[elem] = value + 1
            } else {
                freqs[elem] = 1
            }
        }

        let allValues = try fN.wait()
        XCTAssert(fN.eventLoop === f0.eventLoop)
        XCTAssert(fN.isFulfilled)
        XCTAssertEqual(allValues, [0: 1, 1: 2, 2: 2, 3: 2, 4: 1])
    }

    func testThenThrowingWhichDoesNotThrow() {
        let eventLoop = EmbeddedEventLoop()
        var ran = false
        let p = eventLoop.makePromise(of: String.self)
        p.futureResult.map {
            $0.count
        }.flatMapThrowing {
            1 + $0
        }.assumeIsolated().whenSuccess {
            ran = true
            XCTAssertEqual($0, 6)
        }
        p.succeed("hello")
        XCTAssertTrue(ran)
    }

    func testThenThrowingWhichDoesThrow() {
        enum DummyError: Error, Equatable {
            case dummyError
        }
        let eventLoop = EmbeddedEventLoop()
        var ran = false
        let p = eventLoop.makePromise(of: String.self)
        p.futureResult.map {
            $0.count
        }.flatMapThrowing { (x: Int) throws -> Int in
            XCTAssertEqual(5, x)
            throw DummyError.dummyError
        }.map { (x: Int) -> Int in
            XCTFail("shouldn't have been called")
            return x
        }.assumeIsolated().whenFailure {
            ran = true
            XCTAssertEqual(.some(DummyError.dummyError), $0 as? DummyError)
        }
        p.succeed("hello")
        XCTAssertTrue(ran)
    }

    func testflatMapErrorThrowingWhichDoesNotThrow() {
        enum DummyError: Error, Equatable {
            case dummyError
        }
        let eventLoop = EmbeddedEventLoop()
        var ran = false
        let p = eventLoop.makePromise(of: String.self)
        p.futureResult.map {
            $0.count
        }.flatMapErrorThrowing {
            XCTAssertEqual(.some(DummyError.dummyError), $0 as? DummyError)
            return 5
        }.flatMapErrorThrowing { (_: Error) in
            XCTFail("shouldn't have been called")
            return 5
        }.assumeIsolated().whenSuccess {
            ran = true
            XCTAssertEqual($0, 5)
        }
        p.fail(DummyError.dummyError)
        XCTAssertTrue(ran)
    }

    func testflatMapErrorThrowingWhichDoesThrow() {
        enum DummyError: Error, Equatable {
            case dummyError1
            case dummyError2
        }
        let eventLoop = EmbeddedEventLoop()
        var ran = false
        let p = eventLoop.makePromise(of: String.self)
        p.futureResult.map {
            $0.count
        }.flatMapErrorThrowing { (x: Error) throws -> Int in
            XCTAssertEqual(.some(DummyError.dummyError1), x as? DummyError)
            throw DummyError.dummyError2
        }.map { (x: Int) -> Int in
            XCTFail("shouldn't have been called")
            return x
        }.assumeIsolated().whenFailure {
            ran = true
            XCTAssertEqual(.some(DummyError.dummyError2), $0 as? DummyError)
        }
        p.fail(DummyError.dummyError1)
        XCTAssertTrue(ran)
    }

    func testOrderOfFutureCompletion() throws {
        let eventLoop = EmbeddedEventLoop()
        var state = 0
        let p: EventLoopPromise<Void> = EventLoopPromise(eventLoop: eventLoop, file: #filePath, line: #line)
        p.futureResult.assumeIsolated().map {
            XCTAssertEqual(state, 0)
            state += 1
        }.map {
            XCTAssertEqual(state, 1)
            state += 1
        }.whenSuccess {
            XCTAssertEqual(state, 2)
            state += 1
        }
        p.succeed(())
        XCTAssertTrue(p.futureResult.isFulfilled)
        XCTAssertEqual(state, 3)
    }

    func testEventLoopHoppingInThen() throws {
        let n = 20
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: n)
        var prev: EventLoopFuture<Int> = elg.next().makeSucceededFuture(0)
        for i in (1..<20) {
            let p = elg.next().makePromise(of: Int.self)
            prev.flatMap { (i2: Int) -> EventLoopFuture<Int> in
                XCTAssertEqual(i - 1, i2)
                p.succeed(i)
                return p.futureResult
            }.whenSuccess { i2 in
                XCTAssertEqual(i, i2)
            }
            prev = p.futureResult
        }
        XCTAssertEqual(n - 1, try prev.wait())
        XCTAssertNoThrow(try elg.syncShutdownGracefully())
    }

    func testEventLoopHoppingInThenWithFailures() throws {
        enum DummyError: Error {
            case dummy
        }
        let n = 20
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: n)
        var prev: EventLoopFuture<Int> = elg.next().makeSucceededFuture(0)
        for i in (1..<n) {
            let p = elg.next().makePromise(of: Int.self)
            prev.flatMap { (i2: Int) -> EventLoopFuture<Int> in
                XCTAssertEqual(i - 1, i2)
                if i == n / 2 {
                    p.fail(DummyError.dummy)
                } else {
                    p.succeed(i)
                }
                return p.futureResult
            }.flatMapError { error in
                p.fail(error)
                return p.futureResult
            }.whenSuccess { i2 in
                XCTAssertEqual(i, i2)
            }
            prev = p.futureResult
        }
        XCTAssertThrowsError(try prev.wait()) { error in
            XCTAssertNotNil(error as? DummyError)
        }
        XCTAssertNoThrow(try elg.syncShutdownGracefully())
    }

    func testEventLoopHoppingAndAll() throws {
        let n = 20
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: n)
        let ps = (0..<n).map { (_: Int) -> EventLoopPromise<Void> in
            elg.next().makePromise()
        }
        let allOfEm = EventLoopFuture.andAllSucceed(ps.map { $0.futureResult }, on: elg.next())
        for promise in ps.reversed() {
            DispatchQueue.global().async {
                promise.succeed(())
            }
        }
        try allOfEm.wait()
        XCTAssertNoThrow(try elg.syncShutdownGracefully())
    }

    func testEventLoopHoppingAndAllWithFailures() throws {
        enum DummyError: Error { case dummy }
        let n = 20
        let fireBackEl = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: n)
        let ps = (0..<n).map { (_: Int) -> EventLoopPromise<Void> in
            elg.next().makePromise()
        }
        let allOfEm = EventLoopFuture.andAllSucceed(ps.map { $0.futureResult }, on: fireBackEl.next())
        for (index, promise) in ps.reversed().enumerated() {
            DispatchQueue.global().async {
                if index == n / 2 {
                    promise.fail(DummyError.dummy)
                } else {
                    promise.succeed(())
                }
            }
        }
        XCTAssertThrowsError(try allOfEm.wait()) { error in
            XCTAssertNotNil(error as? DummyError)
        }
        XCTAssertNoThrow(try elg.syncShutdownGracefully())
        XCTAssertNoThrow(try fireBackEl.syncShutdownGracefully())
    }

    func testFutureInVariousScenarios() throws {
        enum DummyError: Error {
            case dummy0
            case dummy1
        }
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let el1 = elg.next()
        let el2 = elg.next()
        precondition(el1 !== el2)
        let q1 = DispatchQueue(label: "q1")
        let q2 = DispatchQueue(label: "q2")

        // this determines which promise is fulfilled first (and (true, true) meaning they race)
        for whoGoesFirst in [(false, true), (true, false), (true, true)] {
            // this determines what EventLoops the Promises are created on
            for eventLoops in [(el1, el1), (el1, el2), (el2, el1), (el2, el2)] {
                // this determines if the promises fail or succeed
                for whoSucceeds in [(false, false), (false, true), (true, false), (true, true)] {
                    let p0 = eventLoops.0.makePromise(of: Int.self)
                    let p1 = eventLoops.1.makePromise(of: String.self)
                    let fAll = p0.futureResult.and(p1.futureResult)

                    // preheat both queues so we have a better chance of racing
                    let sem1 = DispatchSemaphore(value: 0)
                    let sem2 = DispatchSemaphore(value: 0)
                    let g = DispatchGroup()
                    q1.async(group: g) {
                        sem2.signal()
                        sem1.wait()
                    }
                    q2.async(group: g) {
                        sem1.signal()
                        sem2.wait()
                    }
                    g.wait()

                    if whoGoesFirst.0 {
                        q1.async {
                            if whoSucceeds.0 {
                                p0.succeed(7)
                            } else {
                                p0.fail(DummyError.dummy0)
                            }
                            if !whoGoesFirst.1 {
                                q2.asyncAfter(deadline: .now() + 0.1) {
                                    if whoSucceeds.1 {
                                        p1.succeed("hello")
                                    } else {
                                        p1.fail(DummyError.dummy1)
                                    }
                                }
                            }
                        }
                    }
                    if whoGoesFirst.1 {
                        q2.async {
                            if whoSucceeds.1 {
                                p1.succeed("hello")
                            } else {
                                p1.fail(DummyError.dummy1)
                            }
                            if !whoGoesFirst.0 {
                                q1.asyncAfter(deadline: .now() + 0.1) {
                                    if whoSucceeds.0 {
                                        p0.succeed(7)
                                    } else {
                                        p0.fail(DummyError.dummy0)
                                    }
                                }
                            }
                        }
                    }
                    do {
                        let result = try fAll.wait()
                        if !whoSucceeds.0 || !whoSucceeds.1 {
                            XCTFail("unexpected success")
                        } else {
                            XCTAssert((7, "hello") == result)
                        }
                    } catch let e as DummyError {
                        switch e {
                        case .dummy0:
                            XCTAssertFalse(whoSucceeds.0)
                        case .dummy1:
                            XCTAssertFalse(whoSucceeds.1)
                        }
                    } catch {
                        XCTFail("unexpected error: \(error)")
                    }
                }
            }
        }

        XCTAssertNoThrow(try elg.syncShutdownGracefully())
    }

    func testLoopHoppingHelperSuccess() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let loop1 = group.next()
        let loop2 = group.next()
        XCTAssertFalse(loop1 === loop2)

        let succeedingPromise = loop1.makePromise(of: Void.self)
        let succeedingFuture = succeedingPromise.futureResult.map {
            XCTAssertTrue(loop1.inEventLoop)
        }.hop(to: loop2).map {
            XCTAssertTrue(loop2.inEventLoop)
        }
        succeedingPromise.succeed(())
        XCTAssertNoThrow(try succeedingFuture.wait())
    }

    func testLoopHoppingHelperFailure() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let loop1 = group.next()
        let loop2 = group.next()
        XCTAssertFalse(loop1 === loop2)

        let failingPromise = loop2.makePromise(of: Void.self)
        let failingFuture = failingPromise.futureResult.flatMapErrorThrowing { error in
            XCTAssertEqual(error as? EventLoopFutureTestError, EventLoopFutureTestError.example)
            XCTAssertTrue(loop2.inEventLoop)
            throw error
        }.hop(to: loop1).recover { error in
            XCTAssertEqual(error as? EventLoopFutureTestError, EventLoopFutureTestError.example)
            XCTAssertTrue(loop1.inEventLoop)
        }

        failingPromise.fail(EventLoopFutureTestError.example)
        XCTAssertNoThrow(try failingFuture.wait())
    }

    func testLoopHoppingHelperNoHopping() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let loop1 = group.next()
        let loop2 = group.next()
        XCTAssertFalse(loop1 === loop2)

        let noHoppingPromise = loop1.makePromise(of: Void.self)
        let noHoppingFuture = noHoppingPromise.futureResult.hop(to: loop1)
        XCTAssertTrue(noHoppingFuture === noHoppingPromise.futureResult)
        noHoppingPromise.succeed(())
    }

    func testFlatMapResultHappyPath() {
        let el = EmbeddedEventLoop()
        defer {
            XCTAssertNoThrow(try el.syncShutdownGracefully())
        }

        let p = el.makePromise(of: Int.self)
        let f = p.futureResult.flatMapResult { (_: Int) in
            Result<String, Never>.success("hello world")
        }
        p.succeed(1)
        XCTAssertNoThrow(XCTAssertEqual("hello world", try f.wait()))
    }

    func testFlatMapResultFailurePath() {
        struct DummyError: Error {}
        let el = EmbeddedEventLoop()
        defer {
            XCTAssertNoThrow(try el.syncShutdownGracefully())
        }

        let p = el.makePromise(of: Int.self)
        let f = p.futureResult.flatMapResult { (_: Int) in
            Result<Int, Error>.failure(DummyError())
        }
        p.succeed(1)
        XCTAssertThrowsError(try f.wait()) { error in
            XCTAssert(type(of: error) == DummyError.self)
        }
    }

    func testWhenAllSucceedFailsImmediately() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        func doTest(promise: EventLoopPromise<[Int]>?) {
            let promises = [
                group.next().makePromise(of: Int.self),
                group.next().makePromise(of: Int.self),
            ]
            let futures = promises.map { $0.futureResult }
            let futureResult: EventLoopFuture<[Int]>

            if let promise = promise {
                futureResult = promise.futureResult
                EventLoopFuture.whenAllSucceed(futures, promise: promise)
            } else {
                futureResult = EventLoopFuture.whenAllSucceed(futures, on: group.next())
            }

            promises[0].fail(EventLoopFutureTestError.example)
            XCTAssertThrowsError(try futureResult.wait()) { error in
                XCTAssert(type(of: error) == EventLoopFutureTestError.self)
            }
        }

        doTest(promise: nil)
        doTest(promise: group.next().makePromise())
    }

    func testWhenAllSucceedResolvesAfterFutures() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 6)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        func doTest(promise: EventLoopPromise<[Int]>?) throws {
            let promises = (0..<5).map { _ in group.next().makePromise(of: Int.self) }
            let futures = promises.map { $0.futureResult }

            let succeeded = NIOLockedValueBox(false)
            let completedPromises = NIOLockedValueBox(false)

            let mainFuture: EventLoopFuture<[Int]>

            if let promise = promise {
                mainFuture = promise.futureResult
                EventLoopFuture.whenAllSucceed(futures, promise: promise)
            } else {
                mainFuture = EventLoopFuture.whenAllSucceed(futures, on: group.next())
            }

            mainFuture.whenSuccess { _ in
                XCTAssertTrue(completedPromises.withLockedValue { $0 })
                XCTAssertFalse(succeeded.withLockedValue { $0 })
                succeeded.withLockedValue { $0 = true }
            }

            // Should be false, as none of the promises have completed yet
            XCTAssertFalse(succeeded.withLockedValue { $0 })

            // complete the first four promises
            for (index, promise) in promises.dropLast().enumerated() {
                promise.succeed(index)
            }

            // Should still be false, as one promise hasn't completed yet
            XCTAssertFalse(succeeded.withLockedValue { $0 })

            // Complete the last promise
            completedPromises.withLockedValue { $0 = true }
            promises.last!.succeed(4)

            let results = try assertNoThrowWithValue(mainFuture.wait())
            XCTAssertEqual(results, [0, 1, 2, 3, 4])
        }

        XCTAssertNoThrow(try doTest(promise: nil))
        XCTAssertNoThrow(try doTest(promise: group.next().makePromise()))
    }

    func testWhenAllSucceedIsIndependentOfFulfillmentOrder() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 6)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        func doTest(promise: EventLoopPromise<[Int]>?) throws {
            let expected = Array(0..<1000)
            let promises = expected.map { _ in group.next().makePromise(of: Int.self) }
            let futures = promises.map { $0.futureResult }

            let succeeded = NIOLockedValueBox(false)
            let completedPromises = NIOLockedValueBox(false)

            let mainFuture: EventLoopFuture<[Int]>

            if let promise = promise {
                mainFuture = promise.futureResult
                EventLoopFuture.whenAllSucceed(futures, promise: promise)
            } else {
                mainFuture = EventLoopFuture.whenAllSucceed(futures, on: group.next())
            }

            mainFuture.whenSuccess { _ in
                XCTAssertTrue(completedPromises.withLockedValue { $0 })
                XCTAssertFalse(succeeded.withLockedValue { $0 })
                succeeded.withLockedValue { $0 = true }
            }

            for index in expected.reversed() {
                if index == 0 {
                    completedPromises.withLockedValue { $0 = true }
                }
                promises[index].succeed(index)
            }

            let results = try assertNoThrowWithValue(mainFuture.wait())
            XCTAssertEqual(results, expected)
        }

        XCTAssertNoThrow(try doTest(promise: nil))
        XCTAssertNoThrow(try doTest(promise: group.next().makePromise()))
    }

    func testWhenAllCompleteResultsWithFailuresStillSucceed() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        func doTest(promise: EventLoopPromise<[Result<Bool, Error>]>?) {
            let futures: [EventLoopFuture<Bool>] = [
                group.next().makeFailedFuture(EventLoopFutureTestError.example),
                group.next().makeSucceededFuture(true),
            ]
            let future: EventLoopFuture<[Result<Bool, Error>]>

            if let promise = promise {
                future = promise.futureResult
                EventLoopFuture.whenAllComplete(futures, promise: promise)
            } else {
                future = EventLoopFuture.whenAllComplete(futures, on: group.next())
            }

            XCTAssertNoThrow(try future.wait())
        }

        doTest(promise: nil)
        doTest(promise: group.next().makePromise())
    }

    func testWhenAllCompleteResults() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        func doTest(promise: EventLoopPromise<[Result<Int, Error>]>?) throws {
            let futures: [EventLoopFuture<Int>] = [
                group.next().makeSucceededFuture(3),
                group.next().makeFailedFuture(EventLoopFutureTestError.example),
                group.next().makeSucceededFuture(10),
                group.next().makeFailedFuture(EventLoopFutureTestError.example),
                group.next().makeSucceededFuture(5),
            ]
            let future: EventLoopFuture<[Result<Int, Error>]>

            if let promise = promise {
                future = promise.futureResult
                EventLoopFuture.whenAllComplete(futures, promise: promise)
            } else {
                future = EventLoopFuture.whenAllComplete(futures, on: group.next())
            }

            let results = try assertNoThrowWithValue(future.wait())

            XCTAssertEqual(try results[0].get(), 3)
            XCTAssertThrowsError(try results[1].get())
            XCTAssertEqual(try results[2].get(), 10)
            XCTAssertThrowsError(try results[3].get())
            XCTAssertEqual(try results[4].get(), 5)
        }

        XCTAssertNoThrow(try doTest(promise: nil))
        XCTAssertNoThrow(try doTest(promise: group.next().makePromise()))
    }

    func testWhenAllCompleteResolvesAfterFutures() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 6)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        func doTest(promise: EventLoopPromise<[Result<Int, Error>]>?) throws {
            let promises = (0..<5).map { _ in group.next().makePromise(of: Int.self) }
            let futures = promises.map { $0.futureResult }

            let succeeded = NIOLockedValueBox(false)
            let completedPromises = NIOLockedValueBox(false)

            let mainFuture: EventLoopFuture<[Result<Int, Error>]>

            if let promise = promise {
                mainFuture = promise.futureResult
                EventLoopFuture.whenAllComplete(futures, promise: promise)
            } else {
                mainFuture = EventLoopFuture.whenAllComplete(futures, on: group.next())
            }

            mainFuture.whenSuccess { _ in
                XCTAssertTrue(completedPromises.withLockedValue { $0 })
                XCTAssertFalse(succeeded.withLockedValue { $0 })
                succeeded.withLockedValue { $0 = true }
            }

            // Should be false, as none of the promises have completed yet
            XCTAssertFalse(succeeded.withLockedValue { $0 })

            // complete the first four promises
            for (index, promise) in promises.dropLast().enumerated() {
                promise.succeed(index)
            }

            // Should still be false, as one promise hasn't completed yet
            XCTAssertFalse(succeeded.withLockedValue { $0 })

            // Complete the last promise
            completedPromises.withLockedValue { $0 = true }
            promises.last!.succeed(4)

            let results = try assertNoThrowWithValue(mainFuture.wait().map { try $0.get() })
            XCTAssertEqual(results, [0, 1, 2, 3, 4])
        }

        XCTAssertNoThrow(try doTest(promise: nil))
        XCTAssertNoThrow(try doTest(promise: group.next().makePromise()))
    }

    struct DatabaseError: Error {}
    final class Database: Sendable {
        private let query: @Sendable () -> EventLoopFuture<[String]>
        private let _closed = NIOLockedValueBox(false)

        var closed: Bool {
            self._closed.withLockedValue { $0 }
        }

        init(query: @escaping @Sendable () -> EventLoopFuture<[String]>) {
            self.query = query
        }

        func runQuery() -> EventLoopFuture<[String]> {
            self.query()
        }

        func close() {
            self._closed.withLockedValue { $0 = true }
        }
    }

    func testAlways() throws {
        let group = EmbeddedEventLoop()
        let loop = group.next()
        let db = Database { loop.makeSucceededFuture(["Item 1", "Item 2", "Item 3"]) }

        XCTAssertFalse(db.closed)
        let _ = try assertNoThrowWithValue(
            db.runQuery().always { result in
                assertSuccess(result)
                db.close()
            }.map { $0.map { $0.uppercased() } }.wait()
        )
        XCTAssertTrue(db.closed)
    }

    func testAlwaysWithFailingPromise() throws {
        let group = EmbeddedEventLoop()
        let loop = group.next()
        let db = Database { loop.makeFailedFuture(DatabaseError()) }

        XCTAssertFalse(db.closed)
        let _ = try XCTAssertThrowsError(
            db.runQuery().always { result in
                assertFailure(result)
                db.close()
            }.map { $0.map { $0.uppercased() } }.wait()
        ) { XCTAssertTrue($0 is DatabaseError) }
        XCTAssertTrue(db.closed)
    }

    func testPromiseCompletedWithSuccessfulFuture() throws {
        let group = EmbeddedEventLoop()
        let loop = group.next()

        let future = loop.makeSucceededFuture("yay")
        let promise = loop.makePromise(of: String.self)

        promise.completeWith(future)
        XCTAssertEqual(try promise.futureResult.wait(), "yay")
    }

    func testFutureFulfilledIfHasNonSendableResult() throws {
        let eventLoop = EmbeddedEventLoop()
        let f = EventLoopFuture(eventLoop: eventLoop, isolatedValue: NonSendableObject(value: 5))
        XCTAssertTrue(f.isFulfilled)
    }

    func testSucceededIsolatedFutureIsCompleted() throws {
        let group = EmbeddedEventLoop()
        let loop = group.next()

        let value = NonSendableObject(value: 4)

        let future = loop.makeSucceededIsolatedFuture(value)

        future.whenComplete { result in
            switch result {
            case .success(let nonSendableStruct):
                XCTAssertEqual(nonSendableStruct, value)
            case .failure(let error):
                XCTFail("\(error)")
            }
        }
    }

    func testPromiseCompletedWithFailedFuture() throws {
        let group = EmbeddedEventLoop()
        let loop = group.next()

        let future: EventLoopFuture<EventLoopFutureTestError> = loop.makeFailedFuture(EventLoopFutureTestError.example)
        let promise = loop.makePromise(of: EventLoopFutureTestError.self)

        promise.completeWith(future)
        XCTAssertThrowsError(try promise.futureResult.wait()) { error in
            XCTAssert(type(of: error) == EventLoopFutureTestError.self)
        }
    }

    func testPromiseCompletedWithSuccessfulResult() throws {
        let group = EmbeddedEventLoop()
        let loop = group.next()

        let promise = loop.makePromise(of: Void.self)

        let result: Result<Void, Error> = .success(())
        promise.completeWith(result)
        XCTAssertNoThrow(try promise.futureResult.wait())
    }

    func testPromiseCompletedWithFailedResult() throws {
        let group = EmbeddedEventLoop()
        let loop = group.next()

        let promise = loop.makePromise(of: Void.self)

        let result: Result<Void, Error> = .failure(EventLoopFutureTestError.example)
        promise.completeWith(result)
        XCTAssertThrowsError(try promise.futureResult.wait()) { error in
            XCTAssert(type(of: error) == EventLoopFutureTestError.self)
        }
    }

    func testAndAllCompleteWithZeroFutures() {
        let eventLoop = EmbeddedEventLoop()
        let done = DispatchSemaphore(value: 0)
        EventLoopFuture<Void>.andAllComplete([], on: eventLoop).whenComplete { (result: Result<Void, Error>) in
            _ = result.mapError { error -> Error in
                XCTFail("unexpected error \(error)")
                return error
            }
            done.signal()
        }
        done.wait()
    }

    func testAndAllSucceedWithZeroFutures() {
        let eventLoop = EmbeddedEventLoop()
        let done = DispatchSemaphore(value: 0)
        EventLoopFuture<Void>.andAllSucceed([], on: eventLoop).whenComplete { result in
            _ = result.mapError { error -> Error in
                XCTFail("unexpected error \(error)")
                return error
            }
            done.signal()
        }
        done.wait()
    }

    func testAndAllCompleteWithPreSucceededFutures() {
        let eventLoop = EmbeddedEventLoop()
        let succeeded = eventLoop.makeSucceededFuture(())

        for i in 0..<10 {
            XCTAssertNoThrow(
                try EventLoopFuture<Void>.andAllComplete(
                    Array(repeating: succeeded, count: i),
                    on: eventLoop
                ).wait()
            )
        }
    }

    func testAndAllCompleteWithPreFailedFutures() {
        struct Dummy: Error {}
        let eventLoop = EmbeddedEventLoop()
        let failed: EventLoopFuture<Void> = eventLoop.makeFailedFuture(Dummy())

        for i in 0..<10 {
            XCTAssertNoThrow(
                try EventLoopFuture<Void>.andAllComplete(
                    Array(repeating: failed, count: i),
                    on: eventLoop
                ).wait()
            )
        }
    }

    func testAndAllCompleteWithMixOfPreSuccededAndNotYetCompletedFutures() {
        struct Dummy: Error {}
        let eventLoop = EmbeddedEventLoop()
        let succeeded = eventLoop.makeSucceededFuture(())
        let incompletes = [
            eventLoop.makePromise(of: Void.self), eventLoop.makePromise(of: Void.self),
            eventLoop.makePromise(of: Void.self), eventLoop.makePromise(of: Void.self),
            eventLoop.makePromise(of: Void.self),
        ]
        var futures: [EventLoopFuture<Void>] = []

        for i in 0..<10 {
            if i % 2 == 0 {
                futures.append(succeeded)
            } else {
                futures.append(incompletes[i / 2].futureResult)
            }
        }

        let overall = EventLoopFuture<Void>.andAllComplete(futures, on: eventLoop)
        XCTAssertFalse(overall.isFulfilled)
        for (idx, incomplete) in incompletes.enumerated() {
            XCTAssertFalse(overall.isFulfilled)
            if idx % 2 == 0 {
                incomplete.succeed(())
            } else {
                incomplete.fail(Dummy())
            }
        }
        XCTAssertNoThrow(try overall.wait())
    }

    func testWhenAllCompleteWithMixOfPreSuccededAndNotYetCompletedFutures() {
        struct Dummy: Error {}
        let eventLoop = EmbeddedEventLoop()
        let succeeded = eventLoop.makeSucceededFuture(())
        let incompletes = [
            eventLoop.makePromise(of: Void.self), eventLoop.makePromise(of: Void.self),
            eventLoop.makePromise(of: Void.self), eventLoop.makePromise(of: Void.self),
            eventLoop.makePromise(of: Void.self),
        ]
        var futures: [EventLoopFuture<Void>] = []

        for i in 0..<10 {
            if i % 2 == 0 {
                futures.append(succeeded)
            } else {
                futures.append(incompletes[i / 2].futureResult)
            }
        }

        let overall = EventLoopFuture<Void>.whenAllComplete(futures, on: eventLoop)
        XCTAssertFalse(overall.isFulfilled)
        for (idx, incomplete) in incompletes.enumerated() {
            XCTAssertFalse(overall.isFulfilled)
            if idx % 2 == 0 {
                incomplete.succeed(())
            } else {
                incomplete.fail(Dummy())
            }
        }
        let expected: [Result<Void, Error>] = [
            .success(()), .success(()),
            .success(()), .failure(Dummy()),
            .success(()), .success(()),
            .success(()), .failure(Dummy()),
            .success(()), .success(()),
        ]
        func assertIsEqual(_ expecteds: [Result<Void, Error>], _ actuals: [Result<Void, Error>]) {
            XCTAssertEqual(expecteds.count, actuals.count, "counts not equal")
            for i in expecteds.indices {
                let expected = expecteds[i]
                let actual = actuals[i]
                switch (expected, actual) {
                case (.success(()), .success(())):
                    ()
                case (.failure(let le), .failure(let re)):
                    XCTAssert(le is Dummy)
                    XCTAssert(re is Dummy)
                default:
                    XCTFail("\(expecteds) and \(actuals) not equal")
                }
            }
        }
        XCTAssertNoThrow(assertIsEqual(expected, try overall.wait()))
    }

    func testRepeatedTaskOffEventLoopGroupFuture() throws {
        let elg1: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try elg1.syncShutdownGracefully())
        }

        let elg2: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try elg2.syncShutdownGracefully())
        }

        let exitPromise: EventLoopPromise<Void> = elg1.next().makePromise()
        let callNumber = NIOLockedValueBox(0)
        _ = elg1.next().scheduleRepeatedAsyncTask(initialDelay: .nanoseconds(0), delay: .nanoseconds(0)) { task in
            struct Dummy: Error {}

            callNumber.withLockedValue { $0 += 1 }
            switch callNumber.withLockedValue({ $0 }) {
            case 1:
                return elg2.next().makeSucceededFuture(())
            case 2:
                task.cancel(promise: exitPromise)
                return elg2.next().makeFailedFuture(Dummy())
            default:
                XCTFail("shouldn't be called \(callNumber)")
                return elg2.next().makeFailedFuture(Dummy())
            }
        }

        try exitPromise.futureResult.wait()
    }

    func testEventLoopFutureOrErrorNoThrow() {
        let eventLoop = EmbeddedEventLoop()
        let promise = eventLoop.makePromise(of: Int?.self)
        let result: Result<Int?, Error> = .success(42)
        promise.completeWith(result)

        XCTAssertEqual(try promise.futureResult.unwrap(orError: EventLoopFutureTestError.example).wait(), 42)
    }

    func testEventLoopFutureOrThrows() {
        let eventLoop = EmbeddedEventLoop()
        let promise = eventLoop.makePromise(of: Int?.self)
        let result: Result<Int?, Error> = .success(nil)
        promise.completeWith(result)

        XCTAssertThrowsError(try promise.futureResult.unwrap(orError: EventLoopFutureTestError.example).wait()) {
            (error) -> Void in
            XCTAssertEqual(error as! EventLoopFutureTestError, EventLoopFutureTestError.example)
        }
    }

    func testEventLoopFutureOrNoReplacement() {
        let eventLoop = EmbeddedEventLoop()
        let promise = eventLoop.makePromise(of: Int?.self)
        let result: Result<Int?, Error> = .success(42)
        promise.completeWith(result)

        XCTAssertEqual(try! promise.futureResult.unwrap(orReplace: 41).wait(), 42)
    }

    func testEventLoopFutureOrReplacement() {
        let eventLoop = EmbeddedEventLoop()
        let promise = eventLoop.makePromise(of: Int?.self)
        let result: Result<Int?, Error> = .success(nil)
        promise.completeWith(result)

        XCTAssertEqual(try! promise.futureResult.unwrap(orReplace: 42).wait(), 42)
    }

    func testEventLoopFutureOrNoElse() {
        let eventLoop = EmbeddedEventLoop()
        let promise = eventLoop.makePromise(of: Int?.self)
        let result: Result<Int?, Error> = .success(42)
        promise.completeWith(result)

        XCTAssertEqual(try! promise.futureResult.unwrap(orElse: { 41 }).wait(), 42)
    }

    func testEventLoopFutureOrElse() {
        let eventLoop = EmbeddedEventLoop()
        let promise = eventLoop.makePromise(of: Int?.self)
        let result: Result<Int?, Error> = .success(4)
        promise.completeWith(result)

        let x = 2
        XCTAssertEqual(try! promise.futureResult.unwrap(orElse: { x * 2 }).wait(), 4)
    }

    func testFlatBlockingMapOnto() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let eventLoop = group.next()
        let p = eventLoop.makePromise(of: String.self)
        let sem = DispatchSemaphore(value: 0)
        let blockingRan = ManagedAtomic(false)
        let nonBlockingRan = ManagedAtomic(false)
        p.futureResult.map {
            $0.count
        }.flatMapBlocking(onto: DispatchQueue.global()) { value -> Int in
            sem.wait()  // Block in chained EventLoopFuture
            blockingRan.store(true, ordering: .sequentiallyConsistent)
            return 1 + value
        }.whenSuccess {
            XCTAssertEqual($0, 6)
            XCTAssertTrue(blockingRan.load(ordering: .sequentiallyConsistent))
            XCTAssertTrue(nonBlockingRan.load(ordering: .sequentiallyConsistent))
        }
        p.succeed("hello")

        let p2 = eventLoop.makePromise(of: Bool.self)
        p2.futureResult.whenSuccess { _ in
            nonBlockingRan.store(true, ordering: .sequentiallyConsistent)
        }
        p2.succeed(true)

        sem.signal()
    }

    func testWhenSuccessBlocking() {
        let eventLoop = EmbeddedEventLoop()
        let sem = DispatchSemaphore(value: 0)
        let nonBlockingRan = NIOLockedValueBox(false)
        let p = eventLoop.makePromise(of: String.self)
        p.futureResult.whenSuccessBlocking(onto: DispatchQueue.global()) {
            sem.wait()  // Block in callback
            XCTAssertEqual($0, "hello")
            nonBlockingRan.withLockedValue { XCTAssertTrue($0) }

        }
        p.succeed("hello")

        let p2 = eventLoop.makePromise(of: Bool.self)
        p2.futureResult.whenSuccess { _ in
            nonBlockingRan.withLockedValue { $0 = true }
        }
        p2.succeed(true)

        sem.signal()
    }

    func testWhenFailureBlocking() {
        let eventLoop = EmbeddedEventLoop()
        let sem = DispatchSemaphore(value: 0)
        let nonBlockingRan = NIOLockedValueBox(false)
        let p = eventLoop.makePromise(of: String.self)
        p.futureResult.whenFailureBlocking(onto: DispatchQueue.global()) { err in
            sem.wait()  // Block in callback
            XCTAssertEqual(err as! EventLoopFutureTestError, EventLoopFutureTestError.example)
            XCTAssertTrue(nonBlockingRan.withLockedValue { $0 })
        }
        p.fail(EventLoopFutureTestError.example)

        let p2 = eventLoop.makePromise(of: Bool.self)
        p2.futureResult.whenSuccess { _ in
            nonBlockingRan.withLockedValue { $0 = true }
        }
        p2.succeed(true)

        sem.signal()
    }

    func testWhenCompleteBlockingSuccess() {
        let eventLoop = EmbeddedEventLoop()
        let sem = DispatchSemaphore(value: 0)
        let nonBlockingRan = NIOLockedValueBox(false)
        let p = eventLoop.makePromise(of: String.self)
        p.futureResult.whenCompleteBlocking(onto: DispatchQueue.global()) { _ in
            sem.wait()  // Block in callback
            XCTAssertTrue(nonBlockingRan.withLockedValue { $0 })
        }
        p.succeed("hello")

        let p2 = eventLoop.makePromise(of: Bool.self)
        p2.futureResult.whenSuccess { _ in
            nonBlockingRan.withLockedValue { $0 = true }
        }
        p2.succeed(true)

        sem.signal()
    }

    func testWhenCompleteBlockingFailure() {
        let eventLoop = EmbeddedEventLoop()
        let sem = DispatchSemaphore(value: 0)
        let nonBlockingRan = NIOLockedValueBox(false)
        let p = eventLoop.makePromise(of: String.self)
        p.futureResult.whenCompleteBlocking(onto: DispatchQueue.global()) { _ in
            sem.wait()  // Block in callback
            XCTAssertTrue(nonBlockingRan.withLockedValue { $0 })
        }
        p.fail(EventLoopFutureTestError.example)

        let p2 = eventLoop.makePromise(of: Bool.self)
        p2.futureResult.whenSuccess { _ in
            nonBlockingRan.withLockedValue { $0 = true }
        }
        p2.succeed(true)

        sem.signal()
    }

    func testFlatMapWithEL() {
        let el = EmbeddedEventLoop()

        XCTAssertEqual(
            2,
            try el.makeSucceededFuture(1).flatMapWithEventLoop { one, el2 in
                XCTAssert(el === el2)
                return el2.makeSucceededFuture(one + 1)
            }.wait()
        )
    }

    func testFlatMapErrorWithEL() {
        let el = EmbeddedEventLoop()
        struct E: Error {}

        XCTAssertEqual(
            1,
            try el.makeFailedFuture(E()).flatMapErrorWithEventLoop { error, el2 in
                XCTAssert(error is E)
                return el2.makeSucceededFuture(1)
            }.wait()
        )
    }

    func testFoldWithEL() {
        let el = EmbeddedEventLoop()

        let futures = (1...10).map { el.makeSucceededFuture($0) }

        let calls = NIOLockedValueBox(0)
        let all = el.makeSucceededFuture(0).foldWithEventLoop(futures) { l, r, el2 in
            calls.withLockedValue { $0 += 1 }
            XCTAssert(el === el2)
            XCTAssertEqual(calls.withLockedValue { $0 }, r)
            return el2.makeSucceededFuture(l + r)
        }

        XCTAssertEqual((1...10).reduce(0, +), try all.wait())
    }

    func testAssertSuccess() {
        let eventLoop = EmbeddedEventLoop()

        let promise = eventLoop.makePromise(of: String.self)
        let assertedFuture = promise.futureResult.assertSuccess()
        promise.succeed("hello")

        XCTAssertNoThrow(try assertedFuture.wait())
    }

    func testAssertFailure() {
        let eventLoop = EmbeddedEventLoop()

        let promise = eventLoop.makePromise(of: String.self)
        let assertedFuture = promise.futureResult.assertFailure()
        promise.fail(EventLoopFutureTestError.example)

        XCTAssertThrowsError(try assertedFuture.wait()) { error in
            XCTAssertEqual(error as? EventLoopFutureTestError, EventLoopFutureTestError.example)
        }
    }

    func testPreconditionSuccess() {
        let eventLoop = EmbeddedEventLoop()

        let promise = eventLoop.makePromise(of: String.self)
        let preconditionedFuture = promise.futureResult.preconditionSuccess()
        promise.succeed("hello")

        XCTAssertNoThrow(try preconditionedFuture.wait())
    }

    func testPreconditionFailure() {
        let eventLoop = EmbeddedEventLoop()

        let promise = eventLoop.makePromise(of: String.self)
        let preconditionedFuture = promise.futureResult.preconditionFailure()
        promise.fail(EventLoopFutureTestError.example)

        XCTAssertThrowsError(try preconditionedFuture.wait()) { error in
            XCTAssertEqual(error as? EventLoopFutureTestError, EventLoopFutureTestError.example)
        }
    }

    func testSetOrCascadeReplacesNil() throws {
        let eventLoop = EmbeddedEventLoop()

        var promise: EventLoopPromise<Void>? = nil
        let other = eventLoop.makePromise(of: Void.self)
        promise.setOrCascade(to: other)
        XCTAssertNotNil(promise)
        promise?.succeed()
        try other.futureResult.wait()
    }

    func testSetOrCascadeCascadesToExisting() throws {
        let eventLoop = EmbeddedEventLoop()

        var promise: EventLoopPromise<Void>? = eventLoop.makePromise(of: Void.self)
        let other = eventLoop.makePromise(of: Void.self)
        promise.setOrCascade(to: other)
        promise?.succeed()
        try other.futureResult.wait()
    }

    func testSetOrCascadeNoOpOnNil() throws {
        let eventLoop = EmbeddedEventLoop()

        var promise: EventLoopPromise<Void>? = eventLoop.makePromise(of: Void.self)
        promise.setOrCascade(to: nil)
        XCTAssertNotNil(promise)
        promise?.succeed()
    }

    func testPromiseEquatable() {
        let eventLoop = EmbeddedEventLoop()

        let promise1 = eventLoop.makePromise(of: Void.self)
        let promise2 = eventLoop.makePromise(of: Void.self)
        let promise3 = promise1
        XCTAssertEqual(promise1, promise3)
        XCTAssertNotEqual(promise1, promise2)
        XCTAssertNotEqual(promise3, promise2)

        promise1.succeed()
        promise2.succeed()
    }

    func testPromiseEquatable_WhenSucceeded() {
        let eventLoop = EmbeddedEventLoop()

        let promise1 = eventLoop.makePromise(of: Void.self)
        let promise2 = eventLoop.makePromise(of: Void.self)
        let promise3 = promise1

        promise1.succeed()
        promise2.succeed()
        XCTAssertEqual(promise1, promise3)
        XCTAssertNotEqual(promise1, promise2)
        XCTAssertNotEqual(promise3, promise2)
    }

    func testPromiseEquatable_WhenFailed() {
        struct E: Error {}
        let eventLoop = EmbeddedEventLoop()

        let promise1 = eventLoop.makePromise(of: Void.self)
        let promise2 = eventLoop.makePromise(of: Void.self)
        let promise3 = promise1

        promise1.fail(E())
        promise2.fail(E())
        XCTAssertEqual(promise1, promise3)
        XCTAssertNotEqual(promise1, promise2)
        XCTAssertNotEqual(promise3, promise2)
    }
}

class NonSendableObject: Equatable {
    var value: Int
    init(value: Int) {
        self.value = value
    }

    static func == (lhs: NonSendableObject, rhs: NonSendableObject) -> Bool {
        lhs.value == rhs.value
    }
}
@available(*, unavailable)
extension NonSendableObject: Sendable {}
