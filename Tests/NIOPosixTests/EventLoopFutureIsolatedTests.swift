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

import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest

final class SuperNotSendable {
    var x: Int = 5
}

@available(*, unavailable)
extension SuperNotSendable: Sendable {}

// A very stupid event loop that implements as little of the protocol as possible.
//
// We use this to confirm that the fallback path for the isolated views works, by not implementing
// their fast-paths. Instead, we forward to the underlying implementation. We use `AsyncTestingEventLoop`
// to provide the backing implementation.
private final class FallbackEventLoop: RunnableEventLoop {
    private let base: NIOAsyncTestingEventLoop

    init() {
        self.base = .init()
    }

    var now: NIODeadline {
        self.base.now
    }

    var inEventLoop: Bool {
        self.base.inEventLoop
    }

    func execute(_ task: @escaping @Sendable () -> Void) {
        self.base.execute(task)
    }

    func scheduleTask<T>(
        deadline: NIOCore.NIODeadline,
        _ task: @escaping @Sendable () throws -> T
    ) -> NIOCore.Scheduled<T> {
        self.base.scheduleTask(deadline: deadline, task)
    }

    func scheduleTask<T>(
        in delay: NIOCore.TimeAmount,
        _ task: @escaping @Sendable () throws -> T
    ) -> NIOCore.Scheduled<T> {
        self.base.scheduleTask(in: delay, task)
    }

    func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping @Sendable ((any Error)?) -> Void) {
        self.base.shutdownGracefully(queue: queue, callback)
    }

    func runForTests() {
        self.base.runForTests()
    }

    func advanceTimeForTests(by amount: TimeAmount) {
        self.base.advanceTimeForTests(by: amount)
    }
}

private protocol RunnableEventLoop: EventLoop {
    func runForTests()
    func advanceTimeForTests(by: TimeAmount)
}

extension EmbeddedEventLoop: RunnableEventLoop {
    fileprivate func runForTests() {
        self.run()
    }

    fileprivate func advanceTimeForTests(by amount: TimeAmount) {
        self.advanceTime(by: amount)
    }
}

extension NIOAsyncTestingEventLoop: RunnableEventLoop {
    fileprivate func runForTests() {
        // This is horrible, but it's the only general-purpose implementation.
        let promise = self.makePromise(of: Void.self)
        promise.completeWithTask {
            await self.run()
        }
        try! promise.futureResult.wait()
    }

    fileprivate func advanceTimeForTests(by amount: TimeAmount) {
        // This is horrible, but it's the only general-purpose implementation.
        let promise = self.makePromise(of: Void.self)
        promise.completeWithTask {
            await self.advanceTime(by: amount)
        }
        try! promise.futureResult.wait()
    }
}

final class EventLoopFutureIsolatedTest: XCTestCase {
    func _completingPromiseWithNonSendableValue(loop: any EventLoop) throws {
        let f = loop.flatSubmit {
            let promise = loop.makePromise(of: SuperNotSendable.self)
            let value = SuperNotSendable()
            promise.assumeIsolated().succeed(value)
            return promise.futureResult.assumeIsolated().map { val in
                XCTAssertIdentical(val, value)
            }.nonisolated()
        }
        if let runnable = loop as? RunnableEventLoop {
            runnable.runForTests()
        }
        try f.wait()
    }

    func _completingPromiseWithNonSendableResult(loop: any EventLoop) throws {
        let f = loop.flatSubmit {
            let promise = loop.makePromise(of: SuperNotSendable.self)
            let value = SuperNotSendable()
            promise.assumeIsolated().completeWith(.success(value))
            return promise.futureResult.assumeIsolated().map { val in
                XCTAssertIdentical(val, value)
            }.nonisolated()
        }
        if let runnable = loop as? RunnableEventLoop {
            runnable.runForTests()
        }
        try f.wait()
    }

    func _completingPromiseWithNonSendableValueUnchecked(loop: any EventLoop) throws {
        let f = loop.flatSubmit {
            let promise = loop.makePromise(of: SuperNotSendable.self)
            let value = SuperNotSendable()
            promise.assumeIsolatedUnsafeUnchecked().succeed(value)
            return promise.futureResult.assumeIsolatedUnsafeUnchecked().map { val in
                XCTAssertIdentical(val, value)
            }.nonisolated()
        }
        if let runnable = loop as? RunnableEventLoop {
            runnable.runForTests()
        }
        try f.wait()
    }

    func _completingPromiseWithNonSendableResultUnchecked(loop: any EventLoop) throws {
        let f = loop.flatSubmit {
            let promise = loop.makePromise(of: SuperNotSendable.self)
            let value = SuperNotSendable()
            promise.assumeIsolatedUnsafeUnchecked().completeWith(.success(value))
            return promise.futureResult.assumeIsolatedUnsafeUnchecked().map { val in
                XCTAssertIdentical(val, value)
            }.nonisolated()
        }
        if let runnable = loop as? RunnableEventLoop {
            runnable.runForTests()
        }
        try f.wait()
    }

    func _backAndForthUnwrapping(loop: any EventLoop) throws {
        let f = loop.submit {
            let promise = loop.makePromise(of: SuperNotSendable.self)
            let future = promise.futureResult

            XCTAssertEqual(promise.assumeIsolated().nonisolated(), promise)
            XCTAssertEqual(future.assumeIsolated().nonisolated(), future)
            promise.assumeIsolated().succeed(SuperNotSendable())
        }
        if let runnable = loop as? RunnableEventLoop {
            runnable.runForTests()
        }
        try f.wait()
    }

    func _backAndForthUnwrappingUnchecked(loop: any EventLoop) throws {
        let f = loop.submit {
            let promise = loop.makePromise(of: SuperNotSendable.self)
            let future = promise.futureResult

            XCTAssertEqual(promise.assumeIsolatedUnsafeUnchecked().nonisolated(), promise)
            XCTAssertEqual(future.assumeIsolatedUnsafeUnchecked().nonisolated(), future)
            promise.assumeIsolated().succeed(SuperNotSendable())
        }
        if let runnable = loop as? RunnableEventLoop {
            runnable.runForTests()
        }
        try f.wait()
    }

    func _futureChaining(loop: any EventLoop) throws {
        enum TestError: Error {
            case error
        }

        let f = loop.flatSubmit {
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
            throwingFuture.map { _ in 5 }.flatMapError { (error: any Error) -> EventLoopFuture<Int>.Isolated in
                guard let error = error as? TestError, error == .error else {
                    XCTFail("Invalid passed error: \(error)")
                    return loop.makeSucceededIsolatedFuture(originalValue.x)
                }
                return loop.makeSucceededIsolatedFuture(originalValue.x - 2)
            }.whenComplete { (result: Result<Int, any Error>) in
                guard case .success(let r) = result else {
                    XCTFail("Unexpected error")
                    return
                }
                XCTAssertEqual(r, originalValue.x - 2)
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
        }
        if let runnable = loop as? RunnableEventLoop {
            runnable.runForTests()
        }
        try f.wait()
    }

    func _eventLoopIsolated(loop: any EventLoop) throws {
        let f = loop.flatSubmit {
            let value = SuperNotSendable()
            value.x = 4

            // Again, all of these need to close over value. In addition,
            // many need to return it as well.
            let isolated = loop.assumeIsolated()
            XCTAssertIdentical(isolated.nonisolated(), loop)
            isolated.execute {
                XCTAssertEqual(value.x, 4)
                value.x = 5
            }
            let firstFuture = isolated.submit {
                let val = SuperNotSendable()
                val.x = value.x + 1
                return val
            }.map { $0.x }

            let secondFuture = isolated.scheduleTask(deadline: loop.now + .milliseconds(50)) {
                let val = SuperNotSendable()
                val.x = value.x + 1
                return val
            }.futureResult.map { $0.x }

            let thirdFuture = isolated.scheduleTask(in: .milliseconds(50)) {
                let val = SuperNotSendable()
                val.x = value.x + 1
                return val
            }.futureResult.map { $0.x }

            let fourthFuture = isolated.flatScheduleTask(deadline: loop.now + .milliseconds(50)) {
                let promise = loop.makePromise(of: Int.self)
                promise.succeed(value.x + 1)
                return promise.futureResult
            }.futureResult.map { $0 }

            return EventLoopFuture.reduce(
                into: 0,
                [firstFuture, secondFuture, thirdFuture, fourthFuture],
                on: loop
            ) { $0 += $1 }
        }
        if let runnable = loop as? RunnableEventLoop {
            runnable.advanceTimeForTests(by: .milliseconds(51))
        }
        let result = try f.wait()

        XCTAssertEqual(result, 6 * 4)
    }

    func _eventLoopIsolatedUnchecked(loop: any EventLoop) throws {
        let f = loop.flatSubmit {
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

            let secondFuture = isolated.scheduleTask(deadline: loop.now + .milliseconds(50)) {
                let val = SuperNotSendable()
                val.x = value.x + 1
                return val
            }.futureResult.map { $0.x }

            let thirdFuture = isolated.scheduleTask(in: .milliseconds(50)) {
                let val = SuperNotSendable()
                val.x = value.x + 1
                return val
            }.futureResult.map { $0.x }

            let fourthFuture = isolated.flatScheduleTask(deadline: loop.now + .milliseconds(50)) {
                let promise = loop.makePromise(of: Int.self)
                promise.succeed(value.x + 1)
                return promise.futureResult
            }.futureResult.map { $0 }

            return EventLoopFuture.reduce(
                into: 0,
                [firstFuture, secondFuture, thirdFuture, fourthFuture],
                on: loop
            ) { $0 += $1 }
        }
        if let runnable = loop as? RunnableEventLoop {
            runnable.advanceTimeForTests(by: .milliseconds(50))
        }
        let result = try f.wait()

        XCTAssertEqual(result, 6 * 4)
    }

    // MARK: SelectableEL
    func testCompletingPromiseWithNonSendableValue_SelectableEL() throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        try self._completingPromiseWithNonSendableValue(loop: loop)
    }

    func testCompletingPromiseWithNonSendableResult_SelectableEL() throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        try self._completingPromiseWithNonSendableResult(loop: loop)
    }

    func testCompletingPromiseWithNonSendableValueUnchecked_SelectableEL() throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        try self._completingPromiseWithNonSendableValueUnchecked(loop: loop)
    }

    func testCompletingPromiseWithNonSendableResultUnchecked_SelectableEL() throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        try self._completingPromiseWithNonSendableResultUnchecked(loop: loop)
    }

    func testBackAndForthUnwrapping_SelectableEL() throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        try self._backAndForthUnwrapping(loop: loop)
    }

    func testBackAndForthUnwrappingUnchecked_SelectableEL() throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        try self._backAndForthUnwrappingUnchecked(loop: loop)
    }

    func testFutureChaining_SelectableEL() throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        try self._futureChaining(loop: loop)
    }

    func testEventLoopIsolated_SelectableEL() throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        try self._eventLoopIsolated(loop: loop)
    }

    func testEventLoopIsolatedUnchecked_SelectableEL() throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        try self._eventLoopIsolatedUnchecked(loop: loop)
    }

    // MARK: EmbeddedEL
    func testCompletingPromiseWithNonSendableValue_EmbeddedEL() throws {
        let loop = EmbeddedEventLoop()
        try self._completingPromiseWithNonSendableValue(loop: loop)
    }

    func testCompletingPromiseWithNonSendableResult_EmbeddedEL() throws {
        let loop = EmbeddedEventLoop()
        try self._completingPromiseWithNonSendableResult(loop: loop)
    }

    func testCompletingPromiseWithNonSendableValueUnchecked_EmbeddedEL() throws {
        let loop = EmbeddedEventLoop()
        try self._completingPromiseWithNonSendableValueUnchecked(loop: loop)
    }

    func testCompletingPromiseWithNonSendableResultUnchecked_EmbeddedEL() throws {
        let loop = EmbeddedEventLoop()
        try self._completingPromiseWithNonSendableResultUnchecked(loop: loop)
    }

    func testBackAndForthUnwrapping_EmbeddedEL() throws {
        let loop = EmbeddedEventLoop()
        try self._backAndForthUnwrapping(loop: loop)
    }

    func testBackAndForthUnwrappingUnchecked_EmbeddedEL() throws {
        let loop = EmbeddedEventLoop()
        try self._backAndForthUnwrappingUnchecked(loop: loop)
    }

    func testFutureChaining_EmbeddedEL() throws {
        let loop = EmbeddedEventLoop()
        try self._futureChaining(loop: loop)
    }

    func testEventLoopIsolated_EmbeddedEL() throws {
        let loop = EmbeddedEventLoop()
        try self._eventLoopIsolated(loop: loop)
    }

    func testEventLoopIsolatedUnchecked_EmbeddedEL() throws {
        let loop = EmbeddedEventLoop()
        try self._eventLoopIsolatedUnchecked(loop: loop)
    }

    // MARK: AsyncTestingEL
    func testCompletingPromiseWithNonSendableValue_AsyncTestingEL() throws {
        let loop = NIOAsyncTestingEventLoop()
        try self._completingPromiseWithNonSendableValue(loop: loop)
    }

    func testCompletingPromiseWithNonSendableResult_AsyncTestingEL() throws {
        let loop = NIOAsyncTestingEventLoop()
        try self._completingPromiseWithNonSendableResult(loop: loop)
    }

    func testCompletingPromiseWithNonSendableValueUnchecked_AsyncTestingEL() throws {
        let loop = NIOAsyncTestingEventLoop()
        try self._completingPromiseWithNonSendableValueUnchecked(loop: loop)
    }

    func testCompletingPromiseWithNonSendableResultUnchecked_AsyncTestingEL() throws {
        let loop = NIOAsyncTestingEventLoop()
        try self._completingPromiseWithNonSendableResultUnchecked(loop: loop)
    }

    func testBackAndForthUnwrapping_AsyncTestingEL() throws {
        let loop = NIOAsyncTestingEventLoop()
        try self._backAndForthUnwrapping(loop: loop)
    }

    func testBackAndForthUnwrappingUnchecked_AsyncTestingEL() throws {
        let loop = NIOAsyncTestingEventLoop()
        try self._backAndForthUnwrappingUnchecked(loop: loop)
    }

    func testFutureChaining_AsyncTestingEL() throws {
        let loop = NIOAsyncTestingEventLoop()
        try self._futureChaining(loop: loop)
    }

    func testEventLoopIsolated_AsyncTestingEL() throws {
        let loop = NIOAsyncTestingEventLoop()
        try self._eventLoopIsolated(loop: loop)
    }

    func testEventLoopIsolatedUnchecked_AsyncTestingEL() throws {
        let loop = NIOAsyncTestingEventLoop()
        try self._eventLoopIsolatedUnchecked(loop: loop)
    }

    // MARK: Fallback
    func testCompletingPromiseWithNonSendableValue_Fallback() throws {
        let loop = FallbackEventLoop()
        try self._completingPromiseWithNonSendableValue(loop: loop)
    }

    func testCompletingPromiseWithNonSendableResult_() throws {
        let loop = FallbackEventLoop()
        try self._completingPromiseWithNonSendableResult(loop: loop)
    }

    func testCompletingPromiseWithNonSendableValueUnchecked_Fallback() throws {
        let loop = FallbackEventLoop()
        try self._completingPromiseWithNonSendableValueUnchecked(loop: loop)
    }

    func testCompletingPromiseWithNonSendableResultUnchecked_Fallback() throws {
        let loop = FallbackEventLoop()
        try self._completingPromiseWithNonSendableResultUnchecked(loop: loop)
    }

    func testBackAndForthUnwrapping_Fallback() throws {
        let loop = FallbackEventLoop()
        try self._backAndForthUnwrapping(loop: loop)
    }

    func testBackAndForthUnwrappingUnchecked_Fallback() throws {
        let loop = FallbackEventLoop()
        try self._backAndForthUnwrappingUnchecked(loop: loop)
    }

    func testFutureChaining_Fallback() throws {
        let loop = FallbackEventLoop()
        try self._futureChaining(loop: loop)
    }

    func testEventLoopIsolated_Fallback() throws {
        let loop = FallbackEventLoop()
        try self._eventLoopIsolated(loop: loop)
    }

    func testEventLoopIsolatedUnchecked_Fallback() throws {
        let loop = FallbackEventLoop()
        try self._eventLoopIsolatedUnchecked(loop: loop)
    }
}
