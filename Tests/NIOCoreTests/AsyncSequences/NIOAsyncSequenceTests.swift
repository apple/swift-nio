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

import NIOCore
import XCTest

#if compiler(>=5.5.2) && canImport(_Concurrency)
final class MockNIOElementStreamBackPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategy, @unchecked Sendable {
    var didYieldCallCount = 0
    var didYieldHandler: ((Int) -> Bool)?
    func didYield(bufferDepth: Int) -> Bool {
        self.didYieldCallCount += 1
        if let didYieldHandler = self.didYieldHandler {
            return didYieldHandler(bufferDepth)
        }
        return false
    }

    var didNextCallCount = 0
    var didNextHandler: ((Int) -> Bool)?
    func didConsume(bufferDepth: Int) -> Bool {
        self.didNextCallCount += 1
        if let didNextHandler = self.didNextHandler {
            return didNextHandler(bufferDepth)
        }
        return false
    }
}

final class MockNIOBackPressuredStreamSourceDelegate: NIOAsyncSequenceProducerDelegate, @unchecked Sendable {
    var produceMoreCallCount = 0
    var produceMoreHandler: (() -> Void)?
    func produceMore() {
        self.produceMoreCallCount += 1
        if let produceMoreHandler = self.produceMoreHandler {
            return produceMoreHandler()
        }
    }

    var didTerminateCallCount = 0
    var didTerminateHandler: (() -> Void)?
    func didTerminate() {
        self.didTerminateCallCount += 1
        if let didTerminateHandler = self.didTerminateHandler {
            return didTerminateHandler()
        }
    }
}

final class NIOAsyncSequenceProducerTests: XCTestCase {
    private var backPressureStrategy: MockNIOElementStreamBackPressureStrategy!
    private var delegate: MockNIOBackPressuredStreamSourceDelegate!
    private var sequence: NIOAsyncSequenceProducer<
        Int,
        MockNIOElementStreamBackPressureStrategy,
        MockNIOBackPressuredStreamSourceDelegate
    >!
    private var source: NIOAsyncSequenceProducer<
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
            delegate: self.delegate
        )
        self.source = result.source
        self.sequence = result.sequence
    }

    override func tearDown() {
        self.backPressureStrategy = nil
        self.delegate = nil
        self.sequence = nil

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
        XCTAssertEqual(self.delegate.produceMoreCallCount, 0)
        XCTAssertEqualWithoutAutoclosure(await iterator.next(), 1)
        XCTAssertEqualWithoutAutoclosure(await iterator.next(), 2)
        XCTAssertEqualWithoutAutoclosure(await iterator.next(), 3)
        XCTAssertEqualWithoutAutoclosure(await iterator.next(), 4)
        XCTAssertEqual(self.delegate.produceMoreCallCount, 0)
        XCTAssertEqualWithoutAutoclosure(await iterator.next(), 5)
        XCTAssertEqual(self.delegate.produceMoreCallCount, 1)
        XCTAssertEqual(self.source.yield(contentsOf: [7, 8, 9, 10, 11]), .stopProducing)
    }

    // MARK: - Yield

    func testYield_whenInitial_andStopDemanding() async {
        self.backPressureStrategy.didYieldHandler = { _ in false }
        let result = self.source.yield(contentsOf: [1])

        XCTAssertEqual(self.backPressureStrategy.didYieldCallCount, 1)
        XCTAssertEqual(result, .stopProducing)
    }

    func testYield_whenInitial_andDemandMore() async {
        self.backPressureStrategy.didYieldHandler = { _ in true }
        let result = self.source.yield(contentsOf: [1])

        XCTAssertEqual(self.backPressureStrategy.didYieldCallCount, 1)
        XCTAssertEqual(result, .produceMore)
    }

    func testYield_whenStreaming_andSuspended_andStopDemanding() async throws {
        self.backPressureStrategy.didYieldHandler = { _ in false }

        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        async let element = sequence.first { _ in true }
        try await Task.sleep(nanoseconds: 1_000_000)
        XCTAssertEqual(self.backPressureStrategy.didNextCallCount, 1)

        let result = self.source.yield(contentsOf: [1])

        XCTAssertEqual(result, .stopProducing)
        XCTAssertEqualWithoutAutoclosure(await element, 1)
        XCTAssertEqual(self.backPressureStrategy.didYieldCallCount, 1)
    }

    func testYield_whenStreaming_andSuspended_andDemandMore() async throws {
        self.backPressureStrategy.didYieldHandler = { _ in true }

        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        async let element = sequence.first { _ in true }
        try await Task.sleep(nanoseconds: 1_000_000)
        XCTAssertEqual(self.backPressureStrategy.didNextCallCount, 1)

        let result = self.source.yield(contentsOf: [1])

        XCTAssertEqual(result, .produceMore)
        XCTAssertEqualWithoutAutoclosure(await element, 1)
        XCTAssertEqual(self.backPressureStrategy.didYieldCallCount, 1)
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
        try await Task.sleep(nanoseconds: 1_000_000)
        XCTAssertEqual(self.backPressureStrategy.didNextCallCount, 1)

        let result = self.source.yield(contentsOf: [])

        XCTAssertEqual(result, .stopProducing)
        XCTAssertEqual(self.backPressureStrategy.didYieldCallCount, 0)
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
        try await Task.sleep(nanoseconds: 1_000_000)
        XCTAssertEqual(self.backPressureStrategy.didNextCallCount, 1)

        let result = self.source.yield(contentsOf: [])

        XCTAssertEqual(result, .stopProducing)
        XCTAssertEqual(self.backPressureStrategy.didYieldCallCount, 0)
    }

    func testYield_whenStreaming_andNotSuspended_andStopDemanding() async throws {
        self.backPressureStrategy.didYieldHandler = { _ in false }
        // This transitions the sequence into streaming
        _ = self.source.yield(contentsOf: [])

        let result = self.source.yield(contentsOf: [1])

        XCTAssertEqual(result, .stopProducing)
        XCTAssertEqual(self.backPressureStrategy.didYieldCallCount, 2)
    }

    func testYield_whenStreaming_andNotSuspended_andDemandMore() async throws {
        self.backPressureStrategy.didYieldHandler = { _ in true }
        // This transitions the sequence into streaming
        _ = self.source.yield(contentsOf: [])

        let result = self.source.yield(contentsOf: [1])

        XCTAssertEqual(result, .produceMore)
        XCTAssertEqual(self.backPressureStrategy.didYieldCallCount, 2)
    }

    func testYield_whenSourceFinished() async throws {
        self.source.finish()

        let result = self.source.yield(contentsOf: [1])

        XCTAssertEqual(result, .dropped)
        XCTAssertEqual(self.backPressureStrategy.didYieldCallCount, 0)
    }

    // MARK: - Finish

    func testFinish_whenInitial() async {
        self.source.finish()

        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)
    }

    func testFinish_whenStreaming_andSuspended() async throws {
        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        async let element = sequence.first { _ in true }
        try await Task.sleep(nanoseconds: 1_000_000)

        self.source.finish()

        XCTAssertEqualWithoutAutoclosure(await element, nil)
        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    func testFinish_whenStreaming_andNotSuspended_andBufferEmpty() async throws {
        _ = self.source.yield(contentsOf: [])

        self.source.finish()

        let element = await self.sequence.first { _ in true }
        XCTAssertNil(element)
        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    func testFinish_whenStreaming_andNotSuspended_andBufferNotEmpty() async throws {
        _ = self.source.yield(contentsOf: [1])

        self.source.finish()

        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)

        let element = await self.sequence.first { _ in true }
        XCTAssertEqual(element, 1)

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    func testFinish_whenFinished() async throws {
        self.source.finish()

        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)

        _ = await self.sequence.first { _ in true }

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)

        self.source.finish()

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    // MARK: - Source Deinited

    func testSourceDeinited_whenInitial() async {
        self.source = nil

        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)
    }

    func testSourceDeinited_whenStreaming_andSuspended() async throws {
        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        let element: Int? = try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                let element = await sequence.first { _ in true }
                return element
            }

            try await Task.sleep(nanoseconds: 1_000_000)

            self.source = nil

            return try await group.next() ?? nil
        }

        XCTAssertEqual(element, nil)
        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    func testSourceDeinited_whenStreaming_andNotSuspended_andBufferEmpty() async throws {
        _ = self.source.yield(contentsOf: [])

        self.source = nil

        let sequence = try XCTUnwrap(self.sequence)
        let element: Int? = try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                return await sequence.first { _ in true }
            }

            return try await group.next() ?? nil
        }

        XCTAssertNil(element)
        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    func testSourceDeinited_whenStreaming_andNotSuspended_andBufferNotEmpty() async throws {
        _ = self.source.yield(contentsOf: [1])

        self.source = nil

        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)

        let sequence = try XCTUnwrap(self.sequence)
        let element: Int? = try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                return await sequence.first { _ in true }
            }

            return try await group.next() ?? nil
        }

        XCTAssertEqual(element, 1)

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    // MARK: - Task cancel

    func testTaskCancel_whenStreaming_andSuspended() async throws {
        // We are registering our demand and sleeping a bit to make
        // sure our task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        let task: Task<Int?, Never> = Task {
            let iterator = sequence.makeAsyncIterator()
            return await iterator.next()
        }
        try await Task.sleep(nanoseconds: 1_000_000)

        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)
        task.cancel()
        let value = await task.value
        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
        XCTAssertNil(value)
    }

    func testTaskCancel_whenStreaming_andNotSuspended() async throws {
        // We are registering our demand and sleeping a bit to make
        // sure our task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        let task: Task<Int?, Never> = Task {
            let iterator = sequence.makeAsyncIterator()
            return await iterator.next()
        }
        try await Task.sleep(nanoseconds: 1_000_000)

        _ = self.source.yield(contentsOf: [1])

        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)
        task.cancel()
        let value = await task.value
        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
        XCTAssertEqual(value, 1)
    }

    func testTaskCancel_whenSourceFinished() async throws {
        // We are registering our demand and sleeping a bit to make
        // sure our task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        let task: Task<Int?, Never> = Task {
            let iterator = sequence.makeAsyncIterator()
            return await iterator.next()
        }
        try await Task.sleep(nanoseconds: 1_000_000)

        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)
        self.source.finish()
        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
        task.cancel()
        let value = await task.value
        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
        XCTAssertNil(value)
    }

    func testTaskCancel_whenStreaming_andTaskIsAlreadyCancelled() async throws {
        let sequence = try XCTUnwrap(self.sequence)
        let task: Task<Int?, Never> = Task {
            // We are sleeping here to allow some time for us to cancel the task.
            // Once the Task is cancelled we will call `next()`
            try? await Task.sleep(nanoseconds: 1_000_000)
            let iterator = sequence.makeAsyncIterator()
            return await iterator.next()
        }

        task.cancel()

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
        try await Task.sleep(nanoseconds: 1_000_000)

        XCTAssertEqual(self.backPressureStrategy.didNextCallCount, 1)
        XCTAssertEqual(self.delegate.produceMoreCallCount, 1)
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
        try await Task.sleep(nanoseconds: 1_000_000)

        XCTAssertEqual(self.backPressureStrategy.didNextCallCount, 1)
        XCTAssertEqual(self.delegate.produceMoreCallCount, 0)
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
        try await Task.sleep(nanoseconds: 1_000_000)

        XCTAssertEqual(self.backPressureStrategy.didNextCallCount, 1)
        XCTAssertEqual(self.delegate.produceMoreCallCount, 1)
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
        try await Task.sleep(nanoseconds: 1_000_000)

        XCTAssertEqual(self.backPressureStrategy.didNextCallCount, 1)
        XCTAssertEqual(self.delegate.produceMoreCallCount, 0)
    }

    func testNext_whenStreaming_whenNotEmptyBuffer_whenNoDemand() async throws {
        self.backPressureStrategy.didNextHandler = { _ in false }
        _ = self.source.yield(contentsOf: [1])

        let element = await self.sequence.first { _ in true }

        XCTAssertEqual(element, 1)
        XCTAssertEqual(self.backPressureStrategy.didNextCallCount, 1)
        XCTAssertEqual(self.delegate.produceMoreCallCount, 0)
    }

    func testNext_whenStreaming_whenNotEmptyBuffer_whenNewDemand() async throws {
        self.backPressureStrategy.didNextHandler = { _ in true }
        _ = self.source.yield(contentsOf: [1])

        let element = await self.sequence.first { _ in true }

        XCTAssertEqual(element, 1)
        XCTAssertEqual(self.backPressureStrategy.didNextCallCount, 1)
        XCTAssertEqual(self.delegate.produceMoreCallCount, 1)
    }

    func testNext_whenStreaming_whenNotEmptyBuffer_whenNewAndOutstandingDemand() async throws {
        self.backPressureStrategy.didNextHandler = { _ in true }
        self.backPressureStrategy.didYieldHandler = { _ in true }

        _ = self.source.yield(contentsOf: [1])
        XCTAssertEqual(self.delegate.produceMoreCallCount, 0)

        let element = await self.sequence.first { _ in true }

        XCTAssertEqual(element, 1)
        XCTAssertEqual(self.backPressureStrategy.didNextCallCount, 1)
        XCTAssertEqual(self.delegate.produceMoreCallCount, 0)
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

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    func testSequenceDeinitialized_whenIteratorReferenced() async {
        var iterator = self.sequence?.makeAsyncIterator()

        self.sequence = nil
        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)

        XCTAssertNotNil(iterator)
        iterator = nil
        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    // MARK: - IteratorDeinitialized

    func testIteratorDeinitialized_whenSequenceReferenced() async {
        var iterator = self.sequence?.makeAsyncIterator()

        XCTAssertNotNil(iterator)
        iterator = nil
        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)

        self.sequence = nil
        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    func testIteratorDeinitialized_whenSequenceFinished() {
        self.source.finish()
        XCTAssertEqual(self.delegate.didTerminateCallCount, 0)

        var iterator = self.sequence?.makeAsyncIterator()

        XCTAssertNotNil(iterator)
        iterator = nil

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }

    func testIteratorDeinitialized_whenStreaming() {
        _ = self.source.yield(contentsOf: [1])
        var iterator = self.sequence?.makeAsyncIterator()

        XCTAssertNotNil(iterator)
        iterator = nil

        XCTAssertEqual(self.delegate.didTerminateCallCount, 1)
    }
}

// This is needed until async let is supported to be used in autoclosures
fileprivate func XCTAssertEqualWithoutAutoclosure<T>(
    _ expression1: T,
    _ expression2: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) where T: Equatable {
    let result = expression1 == expression2
    XCTAssertTrue(result, message(), file: file, line: line)
}

#endif
