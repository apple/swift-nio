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

enum FutureTestError : Error {
    case example
}

class FutureTest : XCTestCase {
    func testFutureFulfilledIfHasResult() throws {
        let eventLoop = EmbeddedEventLoop()
        let f = Future(eventLoop: eventLoop, checkForPossibleDeadlock: true, result: 5)
        XCTAssertTrue(f.fulfilled)
    }

    func testFutureFulfilledIfHasError() throws {
        let eventLoop = EmbeddedEventLoop()
        let f = Future<Void>(eventLoop: eventLoop, checkForPossibleDeadlock: true, error: FutureTestError.example)
        XCTAssertTrue(f.fulfilled)
    }

    func testAndAllWithAllSuccesses() throws {
        let eventLoop = EmbeddedEventLoop()
        let promises: [Promise<Void>] = (0..<100).map { _ in eventLoop.newPromise() }
        let futures = promises.map { $0.futureResult }

        let fN: Future<Void> = Future<Void>.andAll(futures, eventLoop: eventLoop)
        _ = promises.map { $0.succeed(result: ()) }
        () = try fN.wait()
    }

    func testAndAllWithAllFailures() throws {
        struct E: Error {}
        let eventLoop = EmbeddedEventLoop()
        let promises: [Promise<Void>] = (0..<100).map { _ in eventLoop.newPromise() }
        let futures = promises.map { $0.futureResult }

        let fN: Future<Void> = Future<Void>.andAll(futures, eventLoop: eventLoop)
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
        var promises: [Promise<Void>] = (0..<100).map { _ in eventLoop.newPromise() }
        _ = promises.map { $0.succeed(result: ()) }
        let failedPromise: Promise<()> = eventLoop.newPromise()
        failedPromise.fail(error: E())
        promises.append(failedPromise)

        let futures = promises.map { $0.futureResult }

        let fN: Future<Void> = Future<Void>.andAll(futures, eventLoop: eventLoop)
        do {
            () = try fN.wait()
            XCTFail("should've thrown an error")
        } catch _ as E {
            /* good */
        } catch let e {
            XCTFail("error of wrong type \(e)")
        }
    }
}
