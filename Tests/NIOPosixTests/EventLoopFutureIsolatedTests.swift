//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOPosix
import XCTest

final class SuperNotSendable {
    var x: Int = 5
}

@available(*, unavailable)
extension SuperNotSendable: Sendable {}

final class EventLoopFutureIsolatedTest: XCTestCase {
    func testCompletingPromiseWithNonSendableValue() throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let loop = group.next()

        try loop.flatSubmit {
            let promise = loop.makePromise(of: SuperNotSendable.self)
            let value = SuperNotSendable()
            promise.assumeIsolated().succeed(value)
            return promise.futureResult.assumeIsolated().map { val in
                XCTAssertIdentical(val, value)
            }.nonisolated()
        }.wait()
    }

    func testCompletingPromiseWithNonSendableResult() throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let loop = group.next()

        try loop.flatSubmit {
            let promise = loop.makePromise(of: SuperNotSendable.self)
            let value = SuperNotSendable()
            promise.assumeIsolated().completeWith(.success(value))
            return promise.futureResult.assumeIsolated().map { val in
                XCTAssertIdentical(val, value)
            }.nonisolated()
        }.wait()
    }

    func testCompletingPromiseWithNonSendableValueUnchecked() throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let loop = group.next()

        try loop.flatSubmit {
            let promise = loop.makePromise(of: SuperNotSendable.self)
            let value = SuperNotSendable()
            promise.assumeIsolatedUnsafeUnchecked().succeed(value)
            return promise.futureResult.assumeIsolatedUnsafeUnchecked().map { val in
                XCTAssertIdentical(val, value)
            }.nonisolated()
        }.wait()
    }

    func testCompletingPromiseWithNonSendableResultUnchecked() throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let loop = group.next()

        try loop.flatSubmit {
            let promise = loop.makePromise(of: SuperNotSendable.self)
            let value = SuperNotSendable()
            promise.assumeIsolatedUnsafeUnchecked().completeWith(.success(value))
            return promise.futureResult.assumeIsolatedUnsafeUnchecked().map { val in
                XCTAssertIdentical(val, value)
            }.nonisolated()
        }.wait()
    }

    func testBackAndForthUnwrapping() throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let loop = group.next()

        try loop.submit {
            let promise = loop.makePromise(of: SuperNotSendable.self)
            let future = promise.futureResult

            XCTAssertEqual(promise.assumeIsolated().nonisolated(), promise)
            XCTAssertEqual(future.assumeIsolated().nonisolated(), future)
            promise.assumeIsolated().succeed(SuperNotSendable())
        }.wait()
    }

    func testBackAndForthUnwrappingUnchecked() throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let loop = group.next()

        try loop.submit {
            let promise = loop.makePromise(of: SuperNotSendable.self)
            let future = promise.futureResult

            XCTAssertEqual(promise.assumeIsolatedUnsafeUnchecked().nonisolated(), promise)
            XCTAssertEqual(future.assumeIsolatedUnsafeUnchecked().nonisolated(), future)
            promise.assumeIsolated().succeed(SuperNotSendable())
        }.wait()
    }

    func testFutureChaining() throws {
        enum TestError: Error {
            case error
        }

        let group = MultiThreadedEventLoopGroup.singleton
        let loop = group.next()

        try loop.flatSubmit {
            let promise = loop.makePromise(of: SuperNotSendable.self)
            let future = promise.futureResult.assumeIsolated()
            let originalValue = SuperNotSendable()

            // Note that for this test it is _very important_ that all of these
            // close over `originalValue`. This proves the non-Sendability of
            // the closure.

            // This block is the main happy path.
            let newFuture = future.flatMap { result in
                XCTAssertIdentical(originalValue, result)
                let promise = loop.makePromise(of: Int.self)
                promise.succeed(4)
                return promise.futureResult
            }.map { (result: Int) in
                XCTAssertEqual(result, 4)
                return originalValue
            }.flatMapThrowing { (result: SuperNotSendable) in
                XCTAssertIdentical(originalValue, result)
                return SuperNotSendable()
            }.flatMapResult { (result: SuperNotSendable) -> Result<SuperNotSendable, any Error> in
                XCTAssertNotIdentical(originalValue, result)
                return .failure(TestError.error)
            }.recover { err in
                XCTAssertTrue(err is TestError)
                return originalValue
            }.always { val in
                XCTAssertNotNil(try? val.get())
            }

            newFuture.whenComplete { result in
                guard case .success(let r) = result else {
                    XCTFail("Unexpected error")
                    return
                }
                XCTAssertIdentical(r, originalValue)
            }
            newFuture.whenSuccess { result in
                XCTAssertIdentical(result, originalValue)
            }

            // This block covers the flatMapError and whenFailure tests
            let throwingFuture = newFuture.flatMapThrowing { (_: SuperNotSendable) throws -> SuperNotSendable in
                XCTAssertEqual(originalValue.x, 5)
                throw TestError.error
            }
            throwingFuture.whenFailure { error in
                // Supurious but forces the closure.
                XCTAssertEqual(originalValue.x, 5)
                guard let error = error as? TestError, error == .error else {
                    XCTFail("Invalid passed error: \(error)")
                    return
                }
            }
            throwingFuture.flatMapErrorThrowing { error in
                guard let error = error as? TestError, error == .error else {
                    XCTFail("Invalid passed error: \(error)")
                    throw error
                }
                return originalValue
            }.whenComplete { result in
                guard case .success(let r) = result else {
                    XCTFail("Unexpected error")
                    return
                }
                XCTAssertIdentical(r, originalValue)
            }
            throwingFuture.map { _ in 5 }.flatMapError { (error: any Error) -> EventLoopFuture<Int> in
                guard let error = error as? TestError, error == .error else {
                    XCTFail("Invalid passed error: \(error)")
                    return loop.makeSucceededFuture(originalValue.x)
                }
                return loop.makeSucceededFuture(originalValue.x - 1)
            }.whenComplete { (result: Result<Int, any Error>) in
                guard case .success(let r) = result else {
                    XCTFail("Unexpected error")
                    return
                }
                XCTAssertEqual(r, originalValue.x - 1)
            }

            // This block handles unwrap.
            newFuture.map { x -> SuperNotSendable? in
                XCTAssertEqual(originalValue.x, 5)
                return nil
            }.unwrap(orReplace: originalValue).unwrap(
                orReplace: SuperNotSendable()
            ).map { x -> SuperNotSendable? in
                XCTAssertIdentical(x, originalValue)
                return nil
            }.unwrap(orElse: {
                originalValue
            }).unwrap(orElse: {
                SuperNotSendable()
            }).whenSuccess { x in
                XCTAssertIdentical(x, originalValue)
            }

            promise.assumeIsolated().succeed(originalValue)
            return newFuture.map { _ in }.nonisolated()
        }.wait()
    }

    func testEventLoopIsolated() throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let loop = group.next()

        let result: Int = try loop.flatSubmit {
            let value = SuperNotSendable()

            // Again, all of these need to close over value. In addition,
            // many need to return it as well.
            let isolated = loop.assumeIsolated()
            XCTAssertIdentical(isolated.nonisolated(), loop)
            isolated.execute {
                XCTAssertEqual(value.x, 5)
            }
            let firstFuture = isolated.submit {
                let val = SuperNotSendable()
                val.x = value.x + 1
                return val
            }.map { $0.x }

            let secondFuture = isolated.scheduleTask(deadline: .now() + .milliseconds(50)) {
                let val = SuperNotSendable()
                val.x = value.x + 1
                return val
            }.futureResult.map { $0.x }

            let thirdFuture = isolated.scheduleTask(in: .milliseconds(50)) {
                let val = SuperNotSendable()
                val.x = value.x + 1
                return val
            }.futureResult.map { $0.x }

            let fourthFuture = isolated.flatScheduleTask(deadline: .now() + .milliseconds(50)) {
                let promise = loop.makePromise(of: Int.self)
                promise.succeed(value.x + 1)
                return promise.futureResult
            }.futureResult.map { $0 }

            return EventLoopFuture.reduce(
                into: 0,
                [firstFuture, secondFuture, thirdFuture, fourthFuture],
                on: loop
            ) { $0 += $1 }
        }.wait()

        XCTAssertEqual(result, 6 * 4)
    }

    func testEventLoopIsolatedUnchecked() throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let loop = group.next()

        let result: Int = try loop.flatSubmit {
            let value = SuperNotSendable()

            // Again, all of these need to close over value. In addition,
            // many need to return it as well.
            let isolated = loop.assumeIsolatedUnsafeUnchecked()
            XCTAssertIdentical(isolated.nonisolated(), loop)
            isolated.execute {
                XCTAssertEqual(value.x, 5)
            }
            let firstFuture = isolated.submit {
                let val = SuperNotSendable()
                val.x = value.x + 1
                return val
            }.map { $0.x }

            let secondFuture = isolated.scheduleTask(deadline: .now() + .milliseconds(50)) {
                let val = SuperNotSendable()
                val.x = value.x + 1
                return val
            }.futureResult.map { $0.x }

            let thirdFuture = isolated.scheduleTask(in: .milliseconds(50)) {
                let val = SuperNotSendable()
                val.x = value.x + 1
                return val
            }.futureResult.map { $0.x }

            let fourthFuture = isolated.flatScheduleTask(deadline: .now() + .milliseconds(50)) {
                let promise = loop.makePromise(of: Int.self)
                promise.succeed(value.x + 1)
                return promise.futureResult
            }.futureResult.map { $0 }

            return EventLoopFuture.reduce(
                into: 0,
                [firstFuture, secondFuture, thirdFuture, fourthFuture],
                on: loop
            ) { $0 += $1 }
        }.wait()

        XCTAssertEqual(result, 6 * 4)
    }
}
