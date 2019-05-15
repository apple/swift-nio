//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import Dispatch
@testable import NIO

enum EventLoopFutureTestError : Error {
    case example
}

class EventLoopFutureTest : XCTestCase {
    func testFutureFulfilledIfHasResult() throws {
        let eventLoop = EmbeddedEventLoop()
        let f = EventLoopFuture(eventLoop: eventLoop, value: 5, file: #file, line: #line)
        XCTAssertTrue(f.isFulfilled)
    }

    func testFutureFulfilledIfHasError() throws {
        let eventLoop = EmbeddedEventLoop()
        let f = EventLoopFuture<Void>(eventLoop: eventLoop, error: EventLoopFutureTestError.example, file: #file, line: #line)
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
        do {
            _ = try fN.wait()
            XCTFail("should've thrown an error")
        } catch _ as E {
            /* good */
        } catch let e {
            XCTFail("error of wrong type \(e)")
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
        do {
            _ = try fN.wait()
            XCTFail("should've thrown an error")
        } catch _ as E {
            /* good */
        } catch let e {
            XCTFail("error of wrong type \(e)")
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
        do {
            _ = try fN.wait()
            XCTFail("should've thrown an error")
        } catch _ as E {
            /* good */
        } catch let e {
            XCTFail("error of wrong type \(e)")
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
        do {
            _ = try fN.wait()
            XCTFail("should've thrown an error")
        } catch _ as E {
            /* good */
        } catch let e {
            XCTFail("error of wrong type \(e)")
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
        do {
            _ = try fN.wait()
            XCTFail("should've thrown an error")
        } catch _ as E {
            /* good */
        } catch let e {
            XCTFail("error of wrong type \(e)")
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
        do {
            () = try fN.wait()
            XCTFail("should've thrown an error")
        } catch _ as E {
            /* good */
        } catch let e {
            XCTFail("error of wrong type \(e)")
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
        do {
            () = try fN.wait()
            XCTFail("should've thrown an error")
        } catch _ as E {
            /* good */
        } catch let e {
            XCTFail("error of wrong type \(e)")
        }
    }

    func testReduceWithAllSuccesses() throws {
        let eventLoop = EmbeddedEventLoop()
        let promises: [EventLoopPromise<Int>] = (0..<5).map { (_: Int) in eventLoop.makePromise() }
        let futures = promises.map { $0.futureResult }

        let fN: EventLoopFuture<[Int]> = EventLoopFuture<[Int]>.reduce([], futures, on: eventLoop) {$0 + [$1]}
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

        let fN: EventLoopFuture<[Int]> = EventLoopFuture<[Int]>.reduce([], futures, on: eventLoop) {$0 + [$1]}

        let results = try fN.wait()
        XCTAssertEqual(results, [])
        XCTAssert(fN.eventLoop === eventLoop)
    }

    func testReduceWithAllFailures() throws {
        struct E: Error {}
        let eventLoop = EmbeddedEventLoop()
        let promises: [EventLoopPromise<Int>] = (0..<100).map { (_: Int) in eventLoop.makePromise() }
        let futures = promises.map { $0.futureResult }

        let fN: EventLoopFuture<Int> = EventLoopFuture<Int>.reduce(0, futures, on: eventLoop, +)
        _ = promises.map { $0.fail(E()) }
        XCTAssert(fN.eventLoop === eventLoop)
        do {
            _ = try fN.wait()
            XCTFail("should've thrown an error")
        } catch _ as E {
            /* good */
        } catch let e {
            XCTFail("error of wrong type \(e)")
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

        let fN: EventLoopFuture<Int> = EventLoopFuture<Int>.reduce(0, futures, on: eventLoop, +)
        XCTAssert(fN.eventLoop === eventLoop)
        do {
            _ = try fN.wait()
            XCTFail("should've thrown an error")
        } catch _ as E {
            /* good */
        } catch let e {
            XCTFail("error of wrong type \(e)")
        }
    }

    func testReduceWhichDoesFailFast() throws {
        struct E: Error {}
        let eventLoop = EmbeddedEventLoop()
        var promises: [EventLoopPromise<Int>] = (0..<100).map { (_: Int) in eventLoop.makePromise() }

        let failedPromise = eventLoop.makePromise(of: Int.self)
        promises.insert(failedPromise, at: promises.startIndex)

        let futures = promises.map { $0.futureResult }
        let fN: EventLoopFuture<Int> = EventLoopFuture<Int>.reduce(0, futures, on: eventLoop, +)

        failedPromise.fail(E())

        XCTAssertTrue(fN.isFulfilled)
        XCTAssert(fN.eventLoop === eventLoop)
        do {
            _ = try fN.wait()
            XCTFail("should've thrown an error")
        } catch _ as E {
            /* good */
        } catch let e {
            XCTFail("error of wrong type \(e)")
        }
    }

    func testReduceIntoWithAllSuccesses() throws {
        let eventLoop = EmbeddedEventLoop()
        let futures: [EventLoopFuture<Int>] = [1, 2, 2, 3, 3, 3].map { (id: Int) in eventLoop.makeSucceededFuture(id) }

        let fN: EventLoopFuture<[Int: Int]> = EventLoopFuture<[Int: Int]>.reduce(into: [:], futures, on: eventLoop) { (freqs, elem) in
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

        let fN: EventLoopFuture<[Int: Int]> = EventLoopFuture<[Int: Int]>.reduce(into: [:], futures, on: eventLoop) { (freqs, elem) in
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

        let fN: EventLoopFuture<[Int: Int]> = EventLoopFuture<[Int: Int]>.reduce(into: [:], futures, on: eventLoop) { (freqs, elem) in
            if let value = freqs[elem] {
                freqs[elem] = value + 1
            } else {
                freqs[elem] = 1
            }
        }

        XCTAssert(fN.isFulfilled)
        XCTAssert(fN.eventLoop === eventLoop)
        do {
            _ = try fN.wait()
            XCTFail("should've thrown an error")
        } catch _ as E {
            /* good */
        } catch let e {
            XCTFail("error of wrong type \(e)")
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

        let f0: EventLoopFuture<[Int:Int]> = eventLoop0.submit { [:] }
        let f1s: [EventLoopFuture<Int>] = (1...4).map { id in eventLoop1.submit { id / 2 } }
        let f2s: [EventLoopFuture<Int>] = (5...8).map { id in eventLoop2.submit { id / 2 } }

        let fN = EventLoopFuture<[Int:Int]>.reduce(into: [:], f1s + f2s, on: eventLoop0) { (freqs, elem) in
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
        }.whenSuccess {
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
        }.whenFailure {
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
        }.whenSuccess {
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
        }.whenFailure {
            ran = true
            XCTAssertEqual(.some(DummyError.dummyError2), $0 as? DummyError)
        }
        p.fail(DummyError.dummyError1)
        XCTAssertTrue(ran)
    }

    func testOrderOfFutureCompletion() throws {
        let eventLoop = EmbeddedEventLoop()
        var state = 0
        let p: EventLoopPromise<Void> = EventLoopPromise(eventLoop: eventLoop, file: #file, line: #line)
        p.futureResult.map {
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
        (1..<20).forEach { (i: Int) in
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
        XCTAssertEqual(n-1, try prev.wait())
        XCTAssertNoThrow(try elg.syncShutdownGracefully())
    }

    func testEventLoopHoppingInThenWithFailures() throws {
        enum DummyError: Error {
            case dummy
        }
        let n = 20
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: n)
        var prev: EventLoopFuture<Int> = elg.next().makeSucceededFuture(0)
        (1..<n).forEach { (i: Int) in
            let p = elg.next().makePromise(of: Int.self)
            prev.flatMap { (i2: Int) -> EventLoopFuture<Int> in
                XCTAssertEqual(i - 1, i2)
                if i == n/2 {
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
        do {
            _ = try prev.wait()
            XCTFail("should have failed")
        } catch _ as DummyError {
            // OK
        } catch {
            XCTFail("wrong error \(error)")
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
        ps.reversed().forEach { p in
            DispatchQueue.global().async {
                p.succeed(())
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
        ps.reversed().enumerated().forEach { idx, p in
            DispatchQueue.global().async {
                if idx == n / 2 {
                    p.fail(DummyError.dummy)
                } else {
                    p.succeed(())
                }
            }
        }
        do {
            try allOfEm.wait()
            XCTFail("unexpected failure")
        } catch _ as DummyError {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNoThrow(try elg.syncShutdownGracefully())
        XCTAssertNoThrow(try fireBackEl.syncShutdownGracefully())
    }

    func testFutureInVariousScenarios() throws {
        enum DummyError: Error { case dummy0; case dummy1 }
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
            return Result<String, Never>.success("hello world")
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
            return Result<Int, Error>.failure(DummyError())
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

        let promises = [group.next().makePromise(of: Int.self),
                        group.next().makePromise(of: Int.self)]
        let future = EventLoopFuture.whenAllSucceed(promises.map { $0.futureResult }, on: group.next())
        promises[0].fail(EventLoopFutureTestError.example)
        XCTAssertThrowsError(try future.wait()) { error in
            XCTAssert(type(of: error) == EventLoopFutureTestError.self)
        }
    }

    func testWhenAllSucceedResolvesAfterFutures() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 6)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let promises = (0..<5).map { _ in group.next().makePromise(of: Int.self) }
        let futures = promises.map { $0.futureResult }

        var succeeded = false
        var completedPromises = false

        let mainFuture = EventLoopFuture.whenAllSucceed(futures, on: group.next())
        mainFuture.whenSuccess { _ in
            XCTAssertTrue(completedPromises)
            XCTAssertFalse(succeeded)
            succeeded = true
        }

        // Should be false, as none of the promises have completed yet
        XCTAssertFalse(succeeded)

        // complete the first four promises
        for (index, promise) in promises.dropLast().enumerated() {
            promise.succeed(index)
        }

        // Should still be false, as one promise hasn't completed yet
        XCTAssertFalse(succeeded)

        // Complete the last promise
        completedPromises = true
        promises.last!.succeed(4)

        let results = try assertNoThrowWithValue(mainFuture.wait())
        XCTAssertEqual(results, [0, 1, 2, 3, 4])
    }

    func testWhenAllSucceedIsIndependentOfFulfillmentOrder() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 6)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let expected = Array(0..<1000)
        let promises = expected.map { _ in group.next().makePromise(of: Int.self) }
        let futures = promises.map { $0.futureResult }

        var succeeded = false
        var completedPromises = false

        let mainFuture = EventLoopFuture.whenAllSucceed(futures, on: group.next())
        mainFuture.whenSuccess { _ in
            XCTAssertTrue(completedPromises)
            XCTAssertFalse(succeeded)
            succeeded = true
        }

        for index in expected.reversed() {
            if index == 0 {
                completedPromises = true
            }
            promises[index].succeed(index)
        }

        let results = try assertNoThrowWithValue(mainFuture.wait())
        XCTAssertEqual(results, expected)
    }

    func testWhenAllCompleteResultsWithFailuresStillSucceed() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let future = EventLoopFuture.whenAllComplete([
            group.next().makeFailedFuture(EventLoopFutureTestError.example),
            group.next().makeSucceededFuture(true)
        ], on: group.next())
        XCTAssertNoThrow(try future.wait())
    }

    func testWhenAllCompleteResults() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let results = try EventLoopFuture.whenAllComplete([
            group.next().makeSucceededFuture(3),
            group.next().makeFailedFuture(EventLoopFutureTestError.example),
            group.next().makeSucceededFuture(10),
            group.next().makeFailedFuture(EventLoopFutureTestError.example),
            group.next().makeSucceededFuture(5)
        ], on: group.next()).wait()

        XCTAssertEqual(try results[0].get(), 3)
        XCTAssertThrowsError(try results[1].get())
        XCTAssertEqual(try results[2].get(), 10)
        XCTAssertThrowsError(try results[3].get())
        XCTAssertEqual(try results[4].get(), 5)
    }

    func testWhenAllCompleteResolvesAfterFutures() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 6)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let promises = (0..<5).map { _ in group.next().makePromise(of: Int.self) }
        let futures = promises.map { $0.futureResult }

        var succeeded = false
        var completedPromises = false

        let mainFuture = EventLoopFuture.whenAllComplete(futures, on: group.next())
        mainFuture.whenSuccess { _ in
            XCTAssertTrue(completedPromises)
            XCTAssertFalse(succeeded)
            succeeded = true
        }

        // Should be false, as none of the promises have completed yet
        XCTAssertFalse(succeeded)

        // complete the first four promises
        for (index, promise) in promises.dropLast().enumerated() {
            promise.succeed(index)
        }

        // Should still be false, as one promise hasn't completed yet
        XCTAssertFalse(succeeded)

        // Complete the last promise
        completedPromises = true
        promises.last!.succeed(4)

        let results = try assertNoThrowWithValue(mainFuture.wait().map { try $0.get() })
        XCTAssertEqual(results, [0, 1, 2, 3, 4])
    }
    
    struct DatabaseError: Error {}
    struct Database {
        let query: () -> EventLoopFuture<[String]>
        
        var closed = false
        
        init(query: @escaping () -> EventLoopFuture<[String]>) {
            self.query = query
        }
        
        func runQuery() -> EventLoopFuture<[String]> {
            return query()
        }
        
        mutating func close() {
            self.closed = true
        }
    }
    
    func testAlways() throws {
        let group = EmbeddedEventLoop()
        let loop = group.next()
        var db = Database { loop.makeSucceededFuture(["Item 1", "Item 2", "Item 3"]) }
        
        XCTAssertFalse(db.closed)
        let _ = try assertNoThrowWithValue(db.runQuery().always { result in
            assertSuccess(result)
            db.close()
        }.map { $0.map { $0.uppercased() }}.wait())
        XCTAssertTrue(db.closed)
    }
    
    func testAlwaysWithFailingPromise() throws {
        let group = EmbeddedEventLoop()
        let loop = group.next()
        var db = Database { loop.makeFailedFuture(DatabaseError()) }
        
        XCTAssertFalse(db.closed)
        let _ = try XCTAssertThrowsError(db.runQuery().always { result in
            assertFailure(result)
            db.close()
        }.map { $0.map { $0.uppercased() }}.wait()) { XCTAssertTrue($0 is DatabaseError) }
        XCTAssertTrue(db.closed)
    }
}
