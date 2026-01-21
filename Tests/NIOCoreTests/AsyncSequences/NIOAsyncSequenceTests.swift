//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest

@testable import NIOCore

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class MockNIOElementStreamBackPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategy, @unchecked Sendable
{
    enum Event {
        case didYield
        case didNext
    }
    let events: AsyncStream<Event>
    private let eventsContinuation: AsyncStream<Event>.Continuation

    init() {
        var eventsContinuation: AsyncStream<Event>.Continuation!
        self.events = .init { eventsContinuation = $0 }
        self.eventsContinuation = eventsContinuation!
    }

    var didYieldHandler: ((Int) -> Bool)?
    func didYield(bufferDepth: Int) -> Bool {
        self.eventsContinuation.yield(.didYield)
        if let didYieldHandler = self.didYieldHandler {
            return didYieldHandler(bufferDepth)
        }
        return false
    }

    var didNextHandler: ((Int) -> Bool)?
    func didConsume(bufferDepth: Int) -> Bool {
        self.eventsContinuation.yield(.didNext)
        if let didNextHandler = self.didNextHandler {
            return didNextHandler(bufferDepth)
        }
        return false
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class MockNIOBackPressuredStreamSourceDelegate: NIOAsyncSequenceProducerDelegate, @unchecked Sendable {
    enum Event {
        case produceMore
        case didTerminate
    }
    let events: AsyncStream<Event>
    private let eventsContinuation: AsyncStream<Event>.Continuation

    init() {
        var eventsContinuation: AsyncStream<Event>.Continuation!
        self.events = .init { eventsContinuation = $0 }
        self.eventsContinuation = eventsContinuation!
    }

    var produceMoreHandler: (() -> Void)?
    func produceMore() {
        self.eventsContinuation.yield(.produceMore)
        if let produceMoreHandler = self.produceMoreHandler {
            return produceMoreHandler()
        }
    }

    var didTerminateHandler: (() -> Void)?
    func didTerminate() {
        self.eventsContinuation.yield(.didTerminate)
        if let didTerminateHandler = self.didTerminateHandler {
            return didTerminateHandler()
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class NIOAsyncSequenceProducerTests: XCTestCase {
    private var backPressureStrategy: MockNIOElementStreamBackPressureStrategy!
    private var delegate: MockNIOBackPressuredStreamSourceDelegate!
    private var sequence:
        NIOAsyncSequenceProducer<
            Int,
            MockNIOElementStreamBackPressureStrategy,
            MockNIOBackPressuredStreamSourceDelegate
        >!
    private var source:
        NIOAsyncSequenceProducer<
            Int,
            MockNIOElementStreamBackPressureStrategy,
            MockNIOBackPressuredStreamSourceDelegate
        >.Source!

    override func setUp() {
        super.setUp()

        self.backPressureStrategy = .init()
        self.delegate = .init()
        let result = NIOAsyncSequenceProducer.makeSequence(
            elementType: Int.self,
            backPressureStrategy: self.backPressureStrategy,
            finishOnDeinit: false,
            delegate: self.delegate
        )
        self.source = result.source
        self.sequence = result.sequence
    }

    override func tearDown() {
        self.backPressureStrategy = nil
        self.delegate = nil
        self.sequence = nil
        self.source.finish()
        self.source = nil

        super.tearDown()
    }

    // MARK: - End to end tests

    func testBackPressure() async {
        let lowWatermark = 2
        let higherWatermark = 5
        self.backPressureStrategy.didYieldHandler = { bufferDepth in
            bufferDepth < higherWatermark
        }
        self.backPressureStrategy.didNextHandler = { bufferDepth in
            bufferDepth < lowWatermark
        }
        let iterator = self.sequence.makeAsyncIterator()

        XCTAssertEqual(self.source.yield(contentsOf: [1, 2, 3]), .produceMore)
        XCTAssertEqual(self.source.yield(contentsOf: [4, 5, 6]), .stopProducing)
        XCTAssertEqualWithoutAutoclosure(await iterator.next(), 1)
        XCTAssertEqualWithoutAutoclosure(await iterator.next(), 2)
        XCTAssertEqualWithoutAutoclosure(await iterator.next(), 3)
        XCTAssertEqualWithoutAutoclosure(await iterator.next(), 4)
        XCTAssertEqualWithoutAutoclosure(await iterator.next(), 5)
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.produceMore])
        XCTAssertEqual(self.source.yield(contentsOf: [7, 8, 9, 10, 11]), .stopProducing)
    }

    func testWatermarkBackpressure_whenBelowLowwatermark_andOutstandingDemand() async {
        let newSequence = NIOAsyncSequenceProducer.makeSequence(
            elementType: Int.self,
            backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark(
                lowWatermark: 2,
                highWatermark: 5
            ),
            finishOnDeinit: false,
            delegate: self.delegate
        )
        let iterator = newSequence.sequence.makeAsyncIterator()
        var eventsIterator = self.delegate.events.makeAsyncIterator()
        let source = newSequence.source

        XCTAssertEqual(source.yield(1), .produceMore)
        XCTAssertEqual(source.yield(2), .produceMore)
        XCTAssertEqual(source.yield(3), .produceMore)
        XCTAssertEqual(source.yield(4), .produceMore)
        XCTAssertEqual(source.yield(5), .stopProducing)
        XCTAssertEqualWithoutAutoclosure(await iterator.next(), 1)
        XCTAssertEqualWithoutAutoclosure(await iterator.next(), 2)
        XCTAssertEqualWithoutAutoclosure(await iterator.next(), 3)
        XCTAssertEqualWithoutAutoclosure(await iterator.next(), 4)
        XCTAssertEqualWithoutAutoclosure(await iterator.next(), 5)
        XCTAssertEqualWithoutAutoclosure(await eventsIterator.next(), .produceMore)
        XCTAssertEqual(source.yield(6), .produceMore)
        XCTAssertEqual(source.yield(7), .produceMore)
        XCTAssertEqual(source.yield(8), .produceMore)
        XCTAssertEqualWithoutAutoclosure(await iterator.next(), 6)
        XCTAssertEqualWithoutAutoclosure(await iterator.next(), 7)
        XCTAssertEqualWithoutAutoclosure(await iterator.next(), 8)
        source.finish()
        XCTAssertEqualWithoutAutoclosure(await iterator.next(), nil)
        XCTAssertEqualWithoutAutoclosure(await eventsIterator.next(), .didTerminate)
    }

    // MARK: - Yield

    func testYield_whenInitial_andStopDemanding() async {
        self.backPressureStrategy.didYieldHandler = { _ in false }
        let result = self.source.yield(contentsOf: [1])

        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didYield])
        XCTAssertEqual(result, .stopProducing)
    }

    func testYield_whenInitial_andDemandMore() async {
        self.backPressureStrategy.didYieldHandler = { _ in true }
        let result = self.source.yield(contentsOf: [1])

        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didYield])
        XCTAssertEqual(result, .produceMore)
    }

    func testYield_whenStreaming_andSuspended_andStopDemanding() async throws {
        self.backPressureStrategy.didYieldHandler = { _ in false }

        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        async let element = sequence.first { _ in true }
        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didNext])

        let result = self.source.yield(contentsOf: [1])

        XCTAssertEqual(result, .stopProducing)
        XCTAssertEqualWithoutAutoclosure(await element, 1)
        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didYield])
    }

    func testYield_whenStreaming_andSuspended_andDemandMore() async throws {
        self.backPressureStrategy.didYieldHandler = { _ in true }

        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        async let element = sequence.first { _ in true }
        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didNext])

        let result = self.source.yield(contentsOf: [1])

        XCTAssertEqual(result, .produceMore)
        XCTAssertEqualWithoutAutoclosure(await element, 1)
        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didYield])
    }

    func testYieldEmptySequence_whenStreaming_andSuspended_andStopDemanding() async throws {
        self.backPressureStrategy.didYieldHandler = { _ in false }

        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        Task {
            // Would prefer to use async let _ here but that is not allowed yet
            _ = await sequence.first { _ in true }
        }
        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didNext])

        let result = self.source.yield(contentsOf: [])

        XCTAssertEqual(result, .stopProducing)
    }

    func testYieldEmptySequence_whenStreaming_andSuspended_andDemandMore() async throws {
        self.backPressureStrategy.didYieldHandler = { _ in true }

        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        Task {
            // Would prefer to use async let _ here but that is not allowed yet
            _ = await sequence.first { _ in true }
        }
        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didNext])

        let result = self.source.yield(contentsOf: [])

        XCTAssertEqual(result, .stopProducing)
    }

    func testYield_whenStreaming_andNotSuspended_andStopDemanding() async throws {
        self.backPressureStrategy.didYieldHandler = { _ in false }
        // This transitions the sequence into streaming
        _ = self.source.yield(contentsOf: [])

        let result = self.source.yield(contentsOf: [1])

        XCTAssertEqual(result, .stopProducing)
        XCTAssertEqualWithoutAutoclosure(
            await self.backPressureStrategy.events.prefix(2).collect(),
            [.didYield, .didYield]
        )
    }

    func testYield_whenStreaming_andNotSuspended_andDemandMore() async throws {
        self.backPressureStrategy.didYieldHandler = { _ in true }
        // This transitions the sequence into streaming
        _ = self.source.yield(contentsOf: [])

        let result = self.source.yield(contentsOf: [1])

        XCTAssertEqual(result, .produceMore)
        XCTAssertEqualWithoutAutoclosure(
            await self.backPressureStrategy.events.prefix(2).collect(),
            [.didYield, .didYield]
        )
    }

    func testYield_whenSourceFinished() async throws {
        self.source.finish()

        let result = self.source.yield(contentsOf: [1])

        XCTAssertEqual(result, .dropped)
    }

    // MARK: - Finish

    func testFinish_whenInitial() async {
        self.source.finish()
    }

    func testFinish_whenStreaming_andSuspended() async throws {
        let sequence = try XCTUnwrap(self.sequence)

        let suspended = expectation(description: "task suspended")
        sequence._throwingSequence._storage._setDidSuspend { suspended.fulfill() }

        async let element = sequence.first { _ in true }

        await fulfillment(of: [suspended], timeout: 1)

        self.source.finish()

        XCTAssertEqualWithoutAutoclosure(await element, nil)
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }

    func testFinish_whenStreaming_andNotSuspended_andBufferEmpty() async throws {
        _ = self.source.yield(contentsOf: [])

        self.source.finish()

        let element = await self.sequence.first { _ in true }
        XCTAssertNil(element)
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }

    func testFinish_whenStreaming_andNotSuspended_andBufferNotEmpty() async throws {
        _ = self.source.yield(contentsOf: [1])

        self.source.finish()

        let element = await self.sequence.first { _ in true }
        XCTAssertEqual(element, 1)

        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }

    func testFinish_whenFinished() async throws {
        self.source.finish()

        _ = await self.sequence.first { _ in true }

        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])

        self.source.finish()
    }

    // MARK: - Source Deinited

    func testSourceDeinited_whenInitial() async {
        var newSequence:
            NIOAsyncSequenceProducer<
                Int,
                MockNIOElementStreamBackPressureStrategy,
                MockNIOBackPressuredStreamSourceDelegate
            >.NewSequence? = NIOAsyncSequenceProducer.makeSequence(
                elementType: Int.self,
                backPressureStrategy: self.backPressureStrategy,
                finishOnDeinit: true,
                delegate: self.delegate
            )
        let sequence = newSequence?.sequence
        var source = newSequence?.source
        newSequence = nil

        source = nil
        XCTAssertNil(source)
        XCTAssertNotNil(sequence)
    }

    func testSourceDeinited_whenStreaming_andSuspended() async throws {
        var newSequence:
            NIOAsyncSequenceProducer<
                Int,
                MockNIOElementStreamBackPressureStrategy,
                MockNIOBackPressuredStreamSourceDelegate
            >.NewSequence? = NIOAsyncSequenceProducer.makeSequence(
                elementType: Int.self,
                backPressureStrategy: self.backPressureStrategy,
                finishOnDeinit: true,
                delegate: self.delegate
            )
        let sequence = newSequence?.sequence
        var source = newSequence?.source
        newSequence = nil

        let element: Int? = try await withThrowingTaskGroup(of: Int?.self) { group in
            let suspended = expectation(description: "task suspended")
            sequence!._throwingSequence._storage._setDidSuspend { suspended.fulfill() }

            group.addTask {
                let element = await sequence!.first { _ in true }
                return element
            }

            await fulfillment(of: [suspended], timeout: 1)

            source = nil

            return try await group.next() ?? nil
        }

        XCTAssertEqual(element, nil)
        XCTAssertNil(source)
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }

    func testSourceDeinited_whenStreaming_andNotSuspended_andBufferEmpty() async throws {
        var newSequence:
            NIOAsyncSequenceProducer<
                Int,
                MockNIOElementStreamBackPressureStrategy,
                MockNIOBackPressuredStreamSourceDelegate
            >.NewSequence? = NIOAsyncSequenceProducer.makeSequence(
                elementType: Int.self,
                backPressureStrategy: self.backPressureStrategy,
                finishOnDeinit: true,
                delegate: self.delegate
            )
        let sequence = newSequence?.sequence
        var source = newSequence?.source
        newSequence = nil

        _ = source!.yield(contentsOf: [])

        source = nil

        let element: Int? = try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                await sequence!.first { _ in true }
            }

            return try await group.next() ?? nil
        }

        XCTAssertNil(element)
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }

    func testSourceDeinited_whenStreaming_andNotSuspended_andBufferNotEmpty() async throws {
        var newSequence:
            NIOAsyncSequenceProducer<
                Int,
                MockNIOElementStreamBackPressureStrategy,
                MockNIOBackPressuredStreamSourceDelegate
            >.NewSequence? = NIOAsyncSequenceProducer.makeSequence(
                elementType: Int.self,
                backPressureStrategy: self.backPressureStrategy,
                finishOnDeinit: true,
                delegate: self.delegate
            )
        let sequence = newSequence?.sequence
        var source = newSequence?.source
        newSequence = nil

        _ = source!.yield(contentsOf: [1])

        source = nil

        let element: Int? = try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                await sequence!.first { _ in true }
            }

            return try await group.next() ?? nil
        }

        XCTAssertEqual(element, 1)

        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }

    // MARK: - Task cancel

    func testTaskCancel_whenStreaming_andSuspended() async throws {
        let sequence = try XCTUnwrap(self.sequence)

        let suspended = expectation(description: "task suspended")
        sequence._throwingSequence._storage._setDidSuspend { suspended.fulfill() }

        let task: Task<Int?, Never> = Task {
            let iterator = sequence.makeAsyncIterator()
            return await iterator.next()
        }

        await fulfillment(of: [suspended], timeout: 1)

        task.cancel()
        let value = await task.value
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
        XCTAssertNil(value)
    }

    func testTaskCancel_whenStreaming_andNotSuspended() async throws {
        let sequence = try XCTUnwrap(self.sequence)

        let suspended = expectation(description: "task suspended")
        let resumed = expectation(description: "task resumed")
        let cancelled = expectation(description: "task cancelled")

        sequence._throwingSequence._storage._setDidSuspend { suspended.fulfill() }

        let task: Task<Int?, Never> = Task {
            let iterator = sequence.makeAsyncIterator()

            let value = await iterator.next()
            resumed.fulfill()

            await XCTWaiter().fulfillment(of: [cancelled], timeout: 1)
            return value
        }

        await fulfillment(of: [suspended], timeout: 1)
        _ = self.source.yield(contentsOf: [1])

        await fulfillment(of: [resumed], timeout: 1)
        task.cancel()
        cancelled.fulfill()

        let value = await task.value
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
        XCTAssertEqual(value, 1)
    }

    func testTaskCancel_whenSourceFinished() async throws {
        let sequence = try XCTUnwrap(self.sequence)

        let suspended = expectation(description: "task suspended")
        sequence._throwingSequence._storage._setDidSuspend { suspended.fulfill() }

        let task: Task<Int?, Never> = Task {
            let iterator = sequence.makeAsyncIterator()
            return await iterator.next()
        }

        await fulfillment(of: [suspended], timeout: 1)

        self.source.finish()

        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
        task.cancel()
        let value = await task.value
        XCTAssertNil(value)
    }

    func testTaskCancel_whenStreaming_andTaskIsAlreadyCancelled() async throws {
        let sequence = try XCTUnwrap(self.sequence)

        let cancelled = expectation(description: "task cancelled")

        let task: Task<Int?, Never> = Task {
            await XCTWaiter().fulfillment(of: [cancelled], timeout: 1)
            let iterator = sequence.makeAsyncIterator()
            return await iterator.next()
        }

        task.cancel()
        cancelled.fulfill()

        let value = await task.value

        XCTAssertNil(value)
    }

    // MARK: - Next

    func testNext_whenInitial_whenDemand() async throws {
        self.backPressureStrategy.didNextHandler = { _ in true }
        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        Task {
            // Would prefer to use async let _ here but that is not allowed yet
            _ = await sequence.first { _ in true }
        }

        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didNext])
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.produceMore])
    }

    func testNext_whenInitial_whenNoDemand() async throws {
        self.backPressureStrategy.didNextHandler = { _ in false }
        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        Task {
            // Would prefer to use async let _ here but that is not allowed yet
            _ = await sequence.first { _ in true }
        }

        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didNext])
    }

    func testNext_whenStreaming_whenEmptyBuffer_whenDemand() async throws {
        self.backPressureStrategy.didNextHandler = { _ in true }
        _ = self.source.yield(contentsOf: [])

        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        Task {
            // Would prefer to use async let _ here but that is not allowed yet
            _ = await sequence.first { _ in true }
        }

        XCTAssertEqualWithoutAutoclosure(
            await self.backPressureStrategy.events.prefix(2).collect(),
            [.didYield, .didNext]
        )
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.produceMore])
    }

    func testNext_whenStreaming_whenEmptyBuffer_whenNoDemand() async throws {
        self.backPressureStrategy.didNextHandler = { _ in false }
        _ = self.source.yield(contentsOf: [])

        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        Task {
            // Would prefer to use async let _ here but that is not allowed yet
            _ = await sequence.first { _ in true }
        }

        XCTAssertEqualWithoutAutoclosure(
            await self.backPressureStrategy.events.prefix(2).collect(),
            [.didYield, .didNext]
        )
    }

    func testNext_whenStreaming_whenNotEmptyBuffer_whenNoDemand() async throws {
        self.backPressureStrategy.didNextHandler = { _ in false }
        _ = self.source.yield(contentsOf: [1])

        let element = await self.sequence.first { _ in true }

        XCTAssertEqual(element, 1)
        XCTAssertEqualWithoutAutoclosure(
            await self.backPressureStrategy.events.prefix(2).collect(),
            [.didYield, .didNext]
        )
    }

    func testNext_whenStreaming_whenNotEmptyBuffer_whenNewDemand() async throws {
        self.backPressureStrategy.didNextHandler = { _ in true }
        _ = self.source.yield(contentsOf: [1])

        let element = await self.sequence.first { _ in true }

        XCTAssertEqual(element, 1)
        XCTAssertEqualWithoutAutoclosure(
            await self.backPressureStrategy.events.prefix(2).collect(),
            [.didYield, .didNext]
        )
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.produceMore])
    }

    func testNext_whenStreaming_whenNotEmptyBuffer_whenNewAndOutstandingDemand() async throws {
        self.backPressureStrategy.didNextHandler = { _ in true }
        self.backPressureStrategy.didYieldHandler = { _ in true }

        _ = self.source.yield(contentsOf: [1])

        let element = await self.sequence.first { _ in true }

        XCTAssertEqual(element, 1)
        XCTAssertEqualWithoutAutoclosure(
            await self.backPressureStrategy.events.prefix(2).collect(),
            [.didYield, .didNext]
        )
    }

    func testNext_whenSourceFinished() async throws {
        _ = self.source.yield(contentsOf: [1, 2])
        self.source.finish()

        var elements = [Int]()

        for await element in self.sequence {
            elements.append(element)
        }

        XCTAssertEqual(elements, [1, 2])
    }

    // MARK: - SequenceDeinitialized

    func testSequenceDeinitialized() async {
        self.sequence = nil

        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }

    func testSequenceDeinitialized_whenIteratorReferenced() async {
        var iterator = self.sequence?.makeAsyncIterator()

        self.sequence = nil

        XCTAssertNotNil(iterator)
        iterator = nil
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }

    // MARK: - IteratorDeinitialized

    func testIteratorDeinitialized_whenSequenceReferenced() async {
        var iterator = self.sequence?.makeAsyncIterator()

        XCTAssertNotNil(iterator)
        iterator = nil
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])

        self.sequence = nil
    }

    func testIteratorDeinitialized_whenSequenceFinished() async {
        self.source.finish()

        var iterator = self.sequence?.makeAsyncIterator()

        XCTAssertNotNil(iterator)
        iterator = nil

        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }

    func testIteratorDeinitialized_whenStreaming() async {
        _ = self.source.yield(contentsOf: [1])
        var iterator = self.sequence?.makeAsyncIterator()

        XCTAssertNotNil(iterator)
        iterator = nil

        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }
}

// This is needed until async let is supported to be used in autoclosures
private func XCTAssertEqualWithoutAutoclosure<T>(
    _ expression1: T,
    _ expression2: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) where T: Equatable {
    XCTAssertEqual(expression1, expression2, message(), file: file, line: line)
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension AsyncSequence {
    /// Collect all elements in the sequence into an array.
    fileprivate func collect() async rethrows -> [Element] {
        try await self.reduce(into: []) { accumulated, next in
            accumulated.append(next)
        }
    }
}
