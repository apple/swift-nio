//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
#if canImport(Combine)
import Combine
#endif

import XCTest
import NIO


#if canImport(combine)
@available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
/// A really stupid ArraySink.
///
/// This class violates best practices for building subscribers in a number of ways: it's not
/// thread-safe, which only works because we're using EmbeddedChannel here, and it kicks off the
/// subscribing in init() instead of having a run function. Please don't consider this an example
/// of best-practices in writing Subscribers.
final class ArraySink<P: Publisher> {
    private var sink: Subscribers.Sink<P>?

    var outputs: [P.Output] = []
    var result: Subscribers.Completion<P.Failure>?

    init(_ publisher: P) {
        self.sink = Subscribers.Sink(receiveCompletion: { result in self.result = result },
                                     receiveValue: { value in self.outputs.append(value) })
        publisher.subscribe(self.sink!)
    }

    var isFinished: Bool {
        if case .some(.finished) = self.result {
            return true
        } else {
            return false
        }
    }

    var error: Error? {
        if case .some(.failure(let error)) = self.result {
            return error
        } else {
            return nil
        }
    }

    func cancel() {
        self.sink?.cancel()
    }
}
#endif


final class EventLoopFutureCombineTests: XCTestCase {
    var loop: EmbeddedEventLoop!

    override func setUp() {
        self.loop = EmbeddedEventLoop()
    }

    func testBasicConsumption() throws {
        #if canImport(Combine)
        if #available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let promise = loop.makePromise(of: Bool.self)
            let resultSink = ArraySink(promise.futureResult.publisher)
            XCTAssertEqual(resultSink.outputs, [])
            XCTAssertNil(resultSink.result)

            promise.succeed(true)
            XCTAssertEqual(resultSink.outputs, [true])
            XCTAssertTrue(resultSink.isFinished)
        }
        #endif
    }

    func testFailure() throws {
        #if canImport(Combine)
        if #available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let promise = loop.makePromise(of: Bool.self)
            let resultSink = ArraySink(promise.futureResult.publisher)
            XCTAssertEqual(resultSink.outputs, [])
            XCTAssertNil(resultSink.result)

            promise.fail(ChannelError.badInterfaceAddressFamily)
            XCTAssertEqual(resultSink.outputs, [])
            XCTAssertEqual(resultSink.error as? ChannelError, .badInterfaceAddressFamily)
        }
        #endif
    }

    func testCancellation() throws {
        #if canImport(Combine)
        if #available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let promise = loop.makePromise(of: Bool.self)
            let resultSink = ArraySink(promise.futureResult.publisher)
            XCTAssertEqual(resultSink.outputs, [])
            XCTAssertNil(resultSink.result)

            resultSink.cancel()
            self.loop.run()
            promise.succeed(true)

            XCTAssertEqual(resultSink.outputs, [])
            XCTAssertNil(resultSink.result)
        }
        #endif
    }

    func testCancellationWhenItLosesRace() throws {
        #if canImport(Combine)
        if #available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let promise = loop.makePromise(of: Bool.self)
            let resultSink = ArraySink(promise.futureResult.publisher)
            XCTAssertEqual(resultSink.outputs, [])
            XCTAssertNil(resultSink.result)

            resultSink.cancel()
            promise.succeed(true)
            self.loop.run()

            XCTAssertEqual(resultSink.outputs, [true])
            XCTAssertTrue(resultSink.isFinished)
        }
        #endif
    }

    func testCancellationOnError() throws {
        #if canImport(Combine)
        if #available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let promise = loop.makePromise(of: Bool.self)
            let resultSink = ArraySink(promise.futureResult.publisher)
            XCTAssertEqual(resultSink.outputs, [])
            XCTAssertNil(resultSink.result)

            resultSink.cancel()
            self.loop.run()
            promise.fail(ChannelError.badInterfaceAddressFamily)

            XCTAssertEqual(resultSink.outputs, [])
            XCTAssertNil(resultSink.result)
        }
        #endif
    }

    func testCancellationOnErrorWhenItLosesRace() throws {
        #if canImport(Combine)
        if #available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let promise = loop.makePromise(of: Bool.self)
            let resultSink = ArraySink(promise.futureResult.publisher)
            XCTAssertEqual(resultSink.outputs, [])
            XCTAssertNil(resultSink.result)

            resultSink.cancel()
            promise.fail(ChannelError.badInterfaceAddressFamily)
            self.loop.run()

            XCTAssertEqual(resultSink.outputs, [])
            XCTAssertEqual(resultSink.error as? ChannelError, .badInterfaceAddressFamily)
        }
        #endif
    }

    func testMultipleSubscribers() throws {
        #if canImport(Combine)
        if #available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let promise = loop.makePromise(of: Bool.self)

            let sinks = (0..<5).map { _ in ArraySink(promise.futureResult.publisher) }
            XCTAssertEqual(sinks.map { $0.outputs }, Array(repeatElement([], count: 5)))
            XCTAssertEqual(sinks.map { $0.result == nil }, Array(repeatElement(true, count: 5)))

            promise.succeed(true)
            XCTAssertEqual(sinks.map { $0.outputs }, Array(repeatElement([true], count: 5)))
            XCTAssertEqual(sinks.map { $0.isFinished }, Array(repeatElement(true, count: 5)))
        }
        #endif
    }

    func testPublisherOfSucceededPromise() throws {
        #if canImport(Combine)
        if #available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let promise = loop.makePromise(of: Bool.self)
            promise.succeed(true)

            let resultSink = ArraySink(promise.futureResult.publisher)
            XCTAssertEqual(resultSink.outputs, [true])
            XCTAssertTrue(resultSink.isFinished)
        }
        #endif
    }

    func testPublisherOfFailedPromise() throws {
        #if canImport(Combine)
        if #available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            let promise = loop.makePromise(of: Bool.self)
            promise.fail(ChannelError.badInterfaceAddressFamily)

            let resultSink = ArraySink(promise.futureResult.publisher)
            XCTAssertEqual(resultSink.outputs, [])
            XCTAssertEqual(resultSink.error as? ChannelError, .badInterfaceAddressFamily)
        }
        #endif
    }
}
