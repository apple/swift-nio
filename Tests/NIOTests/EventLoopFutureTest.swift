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
@testable import NIO

enum EventLoopFutureTestError : Error {
    case example
}

class EventLoopFutureTest : XCTestCase {
    func testFutureFulfilledIfHasResult() throws {
        let eventLoop = EmbeddedEventLoop()
        let f = EventLoopFuture(eventLoop: eventLoop, result: 5, file: #file, line: #line)
        XCTAssertTrue(f.fulfilled)
    }

    func testFutureFulfilledIfHasError() throws {
        let eventLoop = EmbeddedEventLoop()
        let f = EventLoopFuture<Void>(eventLoop: eventLoop, error: EventLoopFutureTestError.example, file: #file, line: #line)
        XCTAssertTrue(f.fulfilled)
    }

    func testAndAllWithAllSuccesses() throws {
        let eventLoop = EmbeddedEventLoop()
        let promises: [EventLoopPromise<Void>] = (0..<100).map { _ in eventLoop.newPromise() }
        let futures = promises.map { $0.futureResult }

        let fN: EventLoopFuture<Void> = EventLoopFuture<Void>.andAll(futures, eventLoop: eventLoop)
        _ = promises.map { $0.succeed(result: ()) }
        () = try fN.wait()
    }

    func testAndAllWithAllFailures() throws {
        struct E: Error {}
        let eventLoop = EmbeddedEventLoop()
        let promises: [EventLoopPromise<Void>] = (0..<100).map { _ in eventLoop.newPromise() }
        let futures = promises.map { $0.futureResult }

        let fN: EventLoopFuture<Void> = EventLoopFuture<Void>.andAll(futures, eventLoop: eventLoop)
        _ = promises.map { $0.fail(error: E()) }
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
        var promises: [EventLoopPromise<Void>] = (0..<100).map { _ in eventLoop.newPromise() }
        _ = promises.map { $0.succeed(result: ()) }
        let failedPromise: EventLoopPromise<()> = eventLoop.newPromise()
        failedPromise.fail(error: E())
        promises.append(failedPromise)

        let futures = promises.map { $0.futureResult }

        let fN: EventLoopFuture<Void> = EventLoopFuture<Void>.andAll(futures, eventLoop: eventLoop)
        do {
            () = try fN.wait()
            XCTFail("should've thrown an error")
        } catch _ as E {
            /* good */
        } catch let e {
            XCTFail("error of wrong type \(e)")
        }
    }

    func testThenThrowingWhichDoesNotThrow() {
        let eventLoop = EmbeddedEventLoop()
        var ran = false
        let p: EventLoopPromise<String> = eventLoop.newPromise()
        p.futureResult.map {
            $0.count
        }.thenThrowing {
            1 + $0
        }.whenSuccess {
            ran = true
            XCTAssertEqual($0, 6)
        }
        p.succeed(result: "hello")
        XCTAssertTrue(ran)
    }

    func testThenThrowingWhichDoesThrow() {
        enum DummyError: Error, Equatable {
            case dummyError
        }
        let eventLoop = EmbeddedEventLoop()
        var ran = false
        let p: EventLoopPromise<String> = eventLoop.newPromise()
        p.futureResult.map {
            $0.count
        }.thenThrowing { (x: Int) throws -> Int in
            XCTAssertEqual(5, x)
            throw DummyError.dummyError
        }.map { (x: Int) -> Int in
            XCTFail("shouldn't have been called")
            return x
        }.whenFailure {
            ran = true
            XCTAssertEqual(.some(DummyError.dummyError), $0 as? DummyError)
        }
        p.succeed(result: "hello")
        XCTAssertTrue(ran)
    }

    func testThenIfErrorThrowingWhichDoesNotThrow() {
        enum DummyError: Error, Equatable {
            case dummyError
        }
        let eventLoop = EmbeddedEventLoop()
        var ran = false
        let p: EventLoopPromise<String> = eventLoop.newPromise()
        p.futureResult.map {
            $0.count
        }.thenIfErrorThrowing {
            XCTAssertEqual(.some(DummyError.dummyError), $0 as? DummyError)
            return 5
        }.thenIfErrorThrowing { _ in
            XCTFail("shouldn't have been called")
            return 5
        }.whenSuccess {
            ran = true
            XCTAssertEqual($0, 5)
        }
        p.fail(error: DummyError.dummyError)
        XCTAssertTrue(ran)
    }

    func testThenIfErrorThrowingWhichDoesThrow() {
        enum DummyError: Error, Equatable {
            case dummyError1
            case dummyError2
        }
        let eventLoop = EmbeddedEventLoop()
        var ran = false
        let p: EventLoopPromise<String> = eventLoop.newPromise()
        p.futureResult.map {
            $0.count
        }.thenIfErrorThrowing { (x: Error) throws -> Int in
            XCTAssertEqual(.some(DummyError.dummyError1), x as? DummyError)
            throw DummyError.dummyError2
        }.map { (x: Int) -> Int in
            XCTFail("shouldn't have been called")
            return x
        }.whenFailure {
            ran = true
            XCTAssertEqual(.some(DummyError.dummyError2), $0 as? DummyError)
        }
        p.fail(error: DummyError.dummyError1)
        XCTAssertTrue(ran)
    }

    func testOrderOfFutureCompletion() throws {
        let eventLoop = EmbeddedEventLoop()
        var state = 0
        let p: EventLoopPromise<()> = EventLoopPromise(eventLoop: eventLoop, file: #file, line: #line)
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
        p.succeed(result: ())
        XCTAssertTrue(p.futureResult.fulfilled)
        XCTAssertEqual(state, 3)
    }
}
