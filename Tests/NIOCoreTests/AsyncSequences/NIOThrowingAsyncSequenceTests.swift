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

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class NIOThrowingAsyncSequenceProducerTests: XCTestCase {
    private var backPressureStrategy: MockNIOElementStreamBackPressureStrategy!
    private var delegate: MockNIOBackPressuredStreamSourceDelegate!
    private var sequence: NIOThrowingAsyncSequenceProducer<
        Int,
        Error,
        MockNIOElementStreamBackPressureStrategy,
        MockNIOBackPressuredStreamSourceDelegate
    >!
    private var source: NIOThrowingAsyncSequenceProducer<
        Int,
        Error,
        MockNIOElementStreamBackPressureStrategy,
        MockNIOBackPressuredStreamSourceDelegate
    >.Source!

    override func setUp() {
        super.setUp()

        self.backPressureStrategy = .init()
        self.delegate = .init()
        let result = NIOThrowingAsyncSequenceProducer.makeSequence(
            elementType: Int.self,
            failureType: Error.self,
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

    func testBackPressure() async throws {
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
        XCTAssertEqualWithoutAutoclosure(try await iterator.next(), 1)
        XCTAssertEqualWithoutAutoclosure(try await iterator.next(), 2)
        XCTAssertEqualWithoutAutoclosure(try await iterator.next(), 3)
        XCTAssertEqualWithoutAutoclosure(try await iterator.next(), 4)
        XCTAssertEqualWithoutAutoclosure(try await iterator.next(), 5)
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.produceMore])
        XCTAssertEqual(self.source.yield(contentsOf: [7, 8, 9, 10, 11]), .stopProducing)
    }

    // MARK: - Yield

    func testYield_whenInitial_andStopProducing() async {
        self.backPressureStrategy.didYieldHandler = { _ in false }
        let result = self.source.yield(contentsOf: [1])

        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didYield])
        XCTAssertEqual(result, .stopProducing)
    }

    func testYield_whenInitial_andProduceMore() async {
        self.backPressureStrategy.didYieldHandler = { _ in true }
        let result = self.source.yield(contentsOf: [1])

        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didYield])
        XCTAssertEqual(result, .produceMore)
    }

    func testYield_whenStreaming_andSuspended_andStopProducing() async throws {
        self.backPressureStrategy.didYieldHandler = { _ in false }

        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        let element: Int? = try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                try await sequence.first { _ in true }
            }

            try await Task.sleep(nanoseconds: 1_000_000)
            XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didNext])

            let result = self.source.yield(contentsOf: [1])

            XCTAssertEqual(result, .stopProducing)

            return try await group.next() ?? nil
        }

        XCTAssertEqual(element, 1)
        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didYield])
    }

    func testYield_whenStreaming_andSuspended_andProduceMore() async throws {
        self.backPressureStrategy.didYieldHandler = { _ in true }

        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        let element: Int? = try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                try await sequence.first { _ in true }
            }

            try await Task.sleep(nanoseconds: 1_000_000)
            XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didNext])

            let result = self.source.yield(contentsOf: [1])

            XCTAssertEqual(result, .produceMore)

            return try await group.next() ?? nil
        }

        XCTAssertEqual(element, 1)
        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didYield])
    }

    func testYieldEmptySequence_whenStreaming_andSuspended_andStopProducing() async throws {
        self.backPressureStrategy.didYieldHandler = { _ in false }

        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await sequence.first { _ in true }
            }

            try await Task.sleep(nanoseconds: 1_000_000)
            XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didNext])

            let result = self.source.yield(contentsOf: [])

            XCTAssertEqual(result, .stopProducing)

            group.cancelAll()
        }
    }

    func testYieldEmptySequence_whenStreaming_andSuspended_andProduceMore() async throws {
        self.backPressureStrategy.didYieldHandler = { _ in true }

        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await sequence.first { _ in true }
            }

            try await Task.sleep(nanoseconds: 1_000_000)
            XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didNext])

            let result = self.source.yield(contentsOf: [])

            XCTAssertEqual(result, .stopProducing)

            group.cancelAll()
        }
    }

    func testYield_whenStreaming_andNotSuspended_andStopProducing() async throws {
        self.backPressureStrategy.didYieldHandler = { _ in false }
        // This transitions the sequence into streaming
        _ = self.source.yield(contentsOf: [])

        let result = self.source.yield(contentsOf: [1])

        XCTAssertEqual(result, .stopProducing)
        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(2).collect(), [.didYield, .didYield])
    }

    func testYield_whenStreaming_andNotSuspended_andProduceMore() async throws {
        self.backPressureStrategy.didYieldHandler = { _ in true }
        // This transitions the sequence into streaming
        _ = self.source.yield(contentsOf: [])

        let result = self.source.yield(contentsOf: [1])

        XCTAssertEqual(result, .produceMore)
        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(2).collect(), [.didYield, .didYield])
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
        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        let element: Int? = try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                let element = try await sequence.first { _ in true }
                return element
            }

            try await Task.sleep(nanoseconds: 1_000_000)

            self.source.finish()

            return try await group.next() ?? nil
        }

        XCTAssertEqual(element, nil)
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }

    func testFinish_whenStreaming_andNotSuspended_andBufferEmpty() async throws {
        _ = self.source.yield(contentsOf: [])

        self.source.finish()

        let sequence = try XCTUnwrap(self.sequence)
        let element: Int? = try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                return try await sequence.first { _ in true }
            }

            return try await group.next() ?? nil
        }

        XCTAssertNil(element)
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }

    func testFinish_whenStreaming_andNotSuspended_andBufferNotEmpty() async throws {
        _ = self.source.yield(contentsOf: [1])

        self.source.finish()

        let sequence = try XCTUnwrap(self.sequence)
        let element: Int? = try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                return try await sequence.first { _ in true }
            }

            return try await group.next() ?? nil
        }

        XCTAssertEqual(element, 1)

        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }

    func testFinish_whenFinished() async throws {
        self.source.finish()


        _ = try await self.sequence.first { _ in true }

        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])

        self.source.finish()
    }

    // MARK: - Finish with Error

    func testFinishError_whenInitial() async {
        self.source.finish(ChannelError.alreadyClosed)

        await XCTAssertThrowsError(try await self.sequence.first { _ in true }) { error in
            XCTAssertEqual(error as? ChannelError, .alreadyClosed)
        }

        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }

    func testFinishError_whenStreaming_andSuspended() async throws {
        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        await XCTAssertThrowsError(try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await sequence.first { _ in true }
            }

            try await Task.sleep(nanoseconds: 1_000_000)

            self.source.finish(ChannelError.alreadyClosed)

            try await group.next()
        }) { error in
            XCTAssertEqual(error as? ChannelError, .alreadyClosed)
        }

        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }

    func testFinishError_whenStreaming_andNotSuspended_andBufferEmpty() async throws {
        _ = self.source.yield(contentsOf: [])

        self.source.finish(ChannelError.alreadyClosed)

        let sequence = try XCTUnwrap(self.sequence)
        await XCTAssertThrowsError(try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await sequence.first { _ in true }
            }

            try await group.next()
        }) { error in
            XCTAssertEqual(error as? ChannelError, .alreadyClosed)
        }

        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }

    func testFinishError_whenStreaming_andNotSuspended_andBufferNotEmpty() async throws {
        _ = self.source.yield(contentsOf: [1])

        self.source.finish(ChannelError.alreadyClosed)

        var elements = [Int]()

        await XCTAssertThrowsError(try await {
            for try await element in self.sequence {
                elements.append(element)
            }
        }()) { error in
            XCTAssertEqual(error as? ChannelError, .alreadyClosed)
        }

        XCTAssertEqual(elements, [1])
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }

    func testFinishError_whenFinished() async throws {
        self.source.finish()
        let iterator = self.sequence.makeAsyncIterator()

        _ = try await iterator.next()
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])

        self.source.finish(ChannelError.alreadyClosed)

        // This call should just return nil
        _ = try await iterator.next()
    }

    // MARK: - Source Deinited

    func testSourceDeinited_whenInitial() async {
        self.source = nil
    }

    func testSourceDeinited_whenStreaming_andSuspended() async throws {
        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        let element: Int? = try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                let element = try await sequence.first { _ in true }
                return element
            }

            try await Task.sleep(nanoseconds: 1_000_000)

            self.source = nil

            return try await group.next() ?? nil
        }

        XCTAssertEqual(element, nil)
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }

    func testSourceDeinited_whenStreaming_andNotSuspended_andBufferEmpty() async throws {
        _ = self.source.yield(contentsOf: [])

        self.source = nil

        let sequence = try XCTUnwrap(self.sequence)
        let element: Int? = try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                return try await sequence.first { _ in true }
            }

            return try await group.next() ?? nil
        }

        XCTAssertNil(element)
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }

    func testSourceDeinited_whenStreaming_andNotSuspended_andBufferNotEmpty() async throws {
        _ = self.source.yield(contentsOf: [1])

        self.source = nil

        let sequence = try XCTUnwrap(self.sequence)
        let element: Int? = try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                return try await sequence.first { _ in true }
            }

            return try await group.next() ?? nil
        }

        XCTAssertEqual(element, 1)

        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
    }

    // MARK: - Task cancel

    func testTaskCancel_whenStreaming_andSuspended() async throws {
        // We are registering our demand and sleeping a bit to make
        // sure our task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        let task: Task<Int?, Error> = Task {
            let iterator = sequence.makeAsyncIterator()
            return try await iterator.next()
        }
        try await Task.sleep(nanoseconds: 1_000_000)

        task.cancel()
        let result = await task.result
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
        await XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }
    
    @available(*, deprecated, message: "tests the deprecated custom generic failure type")
    func testTaskCancel_whenStreaming_andSuspended_withCustomErrorType() async throws {
        struct CustomError: Error {}
        // We are registering our demand and sleeping a bit to make
        // sure our task runs when the demand is registered
        let backPressureStrategy = MockNIOElementStreamBackPressureStrategy()
        let delegate = MockNIOBackPressuredStreamSourceDelegate()
        let new = NIOThrowingAsyncSequenceProducer.makeSequence(
            elementType: Int.self,
            failureType: CustomError.self,
            backPressureStrategy: backPressureStrategy,
            delegate: delegate
        )
        let sequence = new.sequence
        let task: Task<Int?, Error> = Task {
            let iterator = sequence.makeAsyncIterator()
            return try await iterator.next()
        }
        try await Task.sleep(nanoseconds: 1_000_000)

        task.cancel()
        let result = await task.result
        XCTAssertEqualWithoutAutoclosure(await delegate.events.prefix(1).collect(), [.didTerminate])
        
        try withExtendedLifetime(new.source) {
            XCTAssertNil(try result.get())
        }
    }

    func testTaskCancel_whenStreaming_andNotSuspended() async throws {
        // We are registering our demand and sleeping a bit to make
        // sure our task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        let task: Task<Int?, Error> = Task {
            let iterator = sequence.makeAsyncIterator()
            let element = try await iterator.next()
            
            // Sleeping here to give the other Task a chance to cancel this one.
            try? await Task.sleep(nanoseconds: 1_000_000)
            return element
        }
        try await Task.sleep(nanoseconds: 1_000_000)

        _ = self.source.yield(contentsOf: [1])

        task.cancel()
        let value = try await task.value
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
        XCTAssertEqual(value, 1)
    }

    func testTaskCancel_whenSourceFinished() async throws {
        // We are registering our demand and sleeping a bit to make
        // sure our task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        let task: Task<Int?, Error> = Task {
            let iterator = sequence.makeAsyncIterator()
            return try await iterator.next()
        }
        try await Task.sleep(nanoseconds: 1_000_000)

        self.source.finish()
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
        task.cancel()
        let value = try await task.value
        XCTAssertNil(value)
    }

    func testTaskCancel_whenStreaming_andTaskIsAlreadyCancelled() async throws {
        let sequence = try XCTUnwrap(self.sequence)
        let task: Task<Int?, Error> = Task {
            // We are sleeping here to allow some time for us to cancel the task.
            // Once the Task is cancelled we will call `next()`
            try? await Task.sleep(nanoseconds: 1_000_000)
            let iterator = sequence.makeAsyncIterator()
            return try await iterator.next()
        }

        task.cancel()

        let result = await task.result

        await XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError, "unexpected error \(error)")
        }
    }
    
    @available(*, deprecated, message: "tests the deprecated custom generic failure type")
    func testTaskCancel_whenStreaming_andTaskIsAlreadyCancelled_withCustomErrorType() async throws {
        struct CustomError: Error {}
        let backPressureStrategy = MockNIOElementStreamBackPressureStrategy()
        let delegate = MockNIOBackPressuredStreamSourceDelegate()
        let new = NIOThrowingAsyncSequenceProducer.makeSequence(
            elementType: Int.self,
            failureType: CustomError.self,
            backPressureStrategy: backPressureStrategy,
            delegate: delegate
        )
        let sequence = new.sequence
        let task: Task<Int?, Error> = Task {
            // We are sleeping here to allow some time for us to cancel the task.
            // Once the Task is cancelled we will call `next()`
            try? await Task.sleep(nanoseconds: 1_000_000)
            let iterator = sequence.makeAsyncIterator()
            return try await iterator.next()
        }

        task.cancel()
        
        let result = await task.result
        try withExtendedLifetime(new.source) {
            XCTAssertNil(try result.get())
        }
    }

    // MARK: - Next

    func testNext_whenInitial_whenDemand() async throws {
        self.backPressureStrategy.didNextHandler = { _ in true }
        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        Task {
            // Would prefer to use async let _ here but that is not allowed yet
            _ = try await sequence.first { _ in true }
        }
        try await Task.sleep(nanoseconds: 1_000_000)

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
            _ = try await sequence.first { _ in true }
        }
        try await Task.sleep(nanoseconds: 1_000_000)

        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didNext])
    }

    func testNext_whenStreaming_whenEmptyBuffer_whenDemand() async throws {
        self.backPressureStrategy.didNextHandler = { _ in true }
        _ = self.source.yield(contentsOf: [])
        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didYield])

        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        Task {
            // Would prefer to use async let _ here but that is not allowed yet
            _ = try await sequence.first { _ in true }
        }
        try await Task.sleep(nanoseconds: 1_000_000)

        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didNext])
    }

    func testNext_whenStreaming_whenEmptyBuffer_whenNoDemand() async throws {
        self.backPressureStrategy.didNextHandler = { _ in false }
        _ = self.source.yield(contentsOf: [])
        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didYield])

        // We are registering our demand and sleeping a bit to make
        // sure the other child task runs when the demand is registered
        let sequence = try XCTUnwrap(self.sequence)
        Task {
            // Would prefer to use async let _ here but that is not allowed yet
            _ = try await sequence.first { _ in true }
        }
        try await Task.sleep(nanoseconds: 1_000_000)

        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didNext])
    }

    func testNext_whenStreaming_whenNotEmptyBuffer_whenNoDemand() async throws {
        self.backPressureStrategy.didNextHandler = { _ in false }
        _ = self.source.yield(contentsOf: [1])
        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didYield])

        let element = try await self.sequence.first { _ in true }

        XCTAssertEqual(element, 1)
        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didNext])
    }

    func testNext_whenStreaming_whenNotEmptyBuffer_whenNewDemand() async throws {
        self.backPressureStrategy.didNextHandler = { _ in true }
        _ = self.source.yield(contentsOf: [1])
        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didYield])

        let element = try await self.sequence.first { _ in true }

        XCTAssertEqual(element, 1)
        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didNext])
        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.produceMore])
    }

    func testNext_whenStreaming_whenNotEmptyBuffer_whenNewAndOutstandingDemand() async throws {
        self.backPressureStrategy.didNextHandler = { _ in true }
        self.backPressureStrategy.didYieldHandler = { _ in true }

        _ = self.source.yield(contentsOf: [1])
        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didYield])

        let element = try await self.sequence.first { _ in true }

        XCTAssertEqual(element, 1)
        XCTAssertEqualWithoutAutoclosure(await self.backPressureStrategy.events.prefix(1).collect(), [.didNext])
    }

    func testNext_whenSourceFinished() async throws {
        _ = self.source.yield(contentsOf: [1, 2])
        self.source.finish()

        var elements = [Int]()

        for try await element in self.sequence {
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

    func testIteratorThrows_whenCancelled() async {
        _ = self.source.yield(contentsOf: Array(0..<100))
        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var counter = 0
                guard let sequence = self.sequence else {
                    return XCTFail("Expected to have an AsyncSequence")
                }

                do {
                    for try await next in sequence {
                        XCTAssertEqual(next, counter)
                        counter += 1
                    }
                    XCTFail("Expected that this throws")
                } catch is CancellationError {
                    // expected
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }

                XCTAssertLessThan(counter, 100)
            }

            group.cancelAll()
        }

        XCTAssertEqualWithoutAutoclosure(await self.delegate.events.prefix(1).collect(), [.didTerminate])
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
    XCTAssertEqual(expression1, expression2, message(), file: file, line: line)
}

extension AsyncSequence {
    /// Collect all elements in the sequence into an array.
    fileprivate func collect() async rethrows -> [Element] {
        try await self.reduce(into: []) { accumulated, next in
            accumulated.append(next)
        }
    }
}
