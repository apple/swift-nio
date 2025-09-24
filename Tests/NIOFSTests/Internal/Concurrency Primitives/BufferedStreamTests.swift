//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest

@testable import NIOFS

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class BufferedStreamTests: XCTestCase {
    // MARK: - sequenceDeinitialized

    func testSequenceDeinitialized_whenNoIterator() async throws {
        var (stream, source): (BufferedStream?, BufferedStream.Source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 5, high: 10)
        )

        let (onTerminationStream, onTerminationContinuation) = AsyncStream<Void>.makeStream()
        source.onTermination = {
            onTerminationContinuation.finish()
        }

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    onTerminationContinuation.yield()
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }

            var onTerminationIterator = onTerminationStream.makeAsyncIterator()
            _ = await onTerminationIterator.next()

            withExtendedLifetime(stream) {}
            stream = nil

            let terminationResult: Void? = await onTerminationIterator.next()
            XCTAssertNil(terminationResult)

            do {
                _ = try { try source.write(2) }()
                XCTFail("Expected an error to be thrown")
            } catch {
                XCTAssertTrue(error is AlreadyFinishedError)
            }

            group.cancelAll()
        }
    }

    func testSequenceDeinitialized_whenIterator() async throws {
        var (stream, source): (BufferedStream?, BufferedStream.Source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 5, high: 10)
        )

        var iterator = stream?.makeAsyncIterator()

        let (onTerminationStream, onTerminationContinuation) = AsyncStream<Void>.makeStream()
        source.onTermination = {
            onTerminationContinuation.finish()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    onTerminationContinuation.yield()
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }

            var onTerminationIterator = onTerminationStream.makeAsyncIterator()
            _ = await onTerminationIterator.next()

            try withExtendedLifetime(stream) {
                let writeResult = try source.write(1)
                writeResult.assertIsProducerMore()
            }

            stream = nil

            do {
                let writeResult = try { try source.write(2) }()
                writeResult.assertIsProducerMore()
            } catch {
                XCTFail("Expected no error to be thrown")
            }

            let element1 = try await iterator?.next()
            XCTAssertEqual(element1, 1)
            let element2 = try await iterator?.next()
            XCTAssertEqual(element2, 2)

            group.cancelAll()
        }
    }

    func testSequenceDeinitialized_whenFinished() async throws {
        var (stream, source): (BufferedStream?, BufferedStream.Source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 5, high: 10)
        )

        let (onTerminationStream, onTerminationContinuation) = AsyncStream<Void>.makeStream()
        source.onTermination = {
            onTerminationContinuation.finish()
        }

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    onTerminationContinuation.yield()
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }

            var onTerminationIterator = onTerminationStream.makeAsyncIterator()
            _ = await onTerminationIterator.next()

            withExtendedLifetime(stream) {
                source.finish(throwing: nil)
            }

            stream = nil

            let terminationResult: Void? = await onTerminationIterator.next()
            XCTAssertNil(terminationResult)

            do {
                _ = try { try source.write(1) }()
                XCTFail("Expected an error to be thrown")
            } catch {
                XCTAssertTrue(error is AlreadyFinishedError)
            }

            group.cancelAll()
        }
    }

    func testSequenceDeinitialized_whenStreaming_andSuspendedProducer() async throws {
        var (stream, source): (BufferedStream?, BufferedStream.Source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 1, high: 2)
        )

        _ = try { try source.write(1) }()

        do {
            try await withCheckedThrowingContinuation { continuation in
                source.write(1) { result in
                    continuation.resume(with: result)
                }

                stream = nil
                _ = stream?.makeAsyncIterator()
            }
        } catch {
            XCTAssertTrue(error is AlreadyFinishedError)
        }
    }

    // MARK: - iteratorInitialized

    func testIteratorInitialized_whenInitial() async throws {
        let (stream, _) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 5, high: 10)
        )

        _ = stream.makeAsyncIterator()
    }

    func testIteratorInitialized_whenStreaming() async throws {
        let (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 5, high: 10)
        )

        try await source.write(1)

        var iterator = stream.makeAsyncIterator()
        let element = try await iterator.next()
        XCTAssertEqual(element, 1)
    }

    func testIteratorInitialized_whenSourceFinished() async throws {
        let (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 5, high: 10)
        )

        try await source.write(1)
        source.finish(throwing: nil)

        var iterator = stream.makeAsyncIterator()
        let element1 = try await iterator.next()
        XCTAssertEqual(element1, 1)
        let element2 = try await iterator.next()
        XCTAssertNil(element2)
    }

    func testIteratorInitialized_whenFinished() async throws {
        let (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 5, high: 10)
        )

        source.finish(throwing: nil)

        var iterator = stream.makeAsyncIterator()
        let element = try await iterator.next()
        XCTAssertNil(element)
    }

    // MARK: - iteratorDeinitialized

    func testIteratorDeinitialized_whenInitial() async throws {
        var (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 5, high: 10)
        )

        let (onTerminationStream, onTerminationContinuation) = AsyncStream<Void>.makeStream()
        source.onTermination = {
            onTerminationContinuation.finish()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    onTerminationContinuation.yield()
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }

            var onTerminationIterator = onTerminationStream.makeAsyncIterator()
            _ = await onTerminationIterator.next()

            var iterator: BufferedStream<Int>.AsyncIterator? = stream.makeAsyncIterator()
            iterator = nil
            _ = try await iterator?.next()

            let terminationResult: Void? = await onTerminationIterator.next()
            XCTAssertNil(terminationResult)

            group.cancelAll()
        }
    }

    func testIteratorDeinitialized_whenStreaming() async throws {
        var (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 5, high: 10)
        )

        let (onTerminationStream, onTerminationContinuation) = AsyncStream<Void>.makeStream()
        source.onTermination = {
            onTerminationContinuation.finish()
        }

        try await source.write(1)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    onTerminationContinuation.yield()
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }

            var onTerminationIterator = onTerminationStream.makeAsyncIterator()
            _ = await onTerminationIterator.next()

            var iterator: BufferedStream<Int>.AsyncIterator? = stream.makeAsyncIterator()
            iterator = nil
            _ = try await iterator?.next()

            let terminationResult: Void? = await onTerminationIterator.next()
            XCTAssertNil(terminationResult)

            group.cancelAll()
        }
    }

    func testIteratorDeinitialized_whenSourceFinished() async throws {
        var (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 5, high: 10)
        )

        let (onTerminationStream, onTerminationContinuation) = AsyncStream<Void>.makeStream()
        source.onTermination = {
            onTerminationContinuation.finish()
        }

        try await source.write(1)
        source.finish(throwing: nil)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    onTerminationContinuation.yield()
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }

            var onTerminationIterator = onTerminationStream.makeAsyncIterator()
            _ = await onTerminationIterator.next()

            var iterator: BufferedStream<Int>.AsyncIterator? = stream.makeAsyncIterator()
            iterator = nil
            _ = try await iterator?.next()

            let terminationResult: Void? = await onTerminationIterator.next()
            XCTAssertNil(terminationResult)

            group.cancelAll()
        }
    }

    func testIteratorDeinitialized_whenFinished() async throws {
        var (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 5, high: 10)
        )

        let (onTerminationStream, onTerminationContinuation) = AsyncStream<Void>.makeStream()
        source.onTermination = {
            onTerminationContinuation.finish()
        }

        source.finish(throwing: nil)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    onTerminationContinuation.yield()
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }

            var onTerminationIterator = onTerminationStream.makeAsyncIterator()
            _ = await onTerminationIterator.next()

            var iterator: BufferedStream<Int>.AsyncIterator? = stream.makeAsyncIterator()
            iterator = nil
            _ = try await iterator?.next()

            let terminationResult: Void? = await onTerminationIterator.next()
            XCTAssertNil(terminationResult)

            group.cancelAll()
        }
    }

    func testIteratorDeinitialized_whenStreaming_andSuspendedProducer() async throws {
        var (stream, source): (BufferedStream?, BufferedStream.Source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 1, high: 2)
        )

        var iterator: BufferedStream<Int>.AsyncIterator? = stream?.makeAsyncIterator()
        stream = nil

        _ = try { try source.write(1) }()

        do {
            try await withCheckedThrowingContinuation { continuation in
                source.write(1) { result in
                    continuation.resume(with: result)
                }

                iterator = nil
            }
        } catch {
            XCTAssertTrue(error is AlreadyFinishedError)
        }

        _ = try await iterator?.next()
    }

    // MARK: - sourceDeinitialized

    func testSourceDeinitialized_whenInitial() async throws {
        var (stream, source): (BufferedStream, BufferedStream.Source?) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 5, high: 10)
        )

        let (onTerminationStream, onTerminationContinuation) = AsyncStream<Void>.makeStream()
        source?.onTermination = {
            onTerminationContinuation.finish()
        }

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    onTerminationContinuation.yield()
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }

            var onTerminationIterator = onTerminationStream.makeAsyncIterator()
            _ = await onTerminationIterator.next()

            source = nil

            let terminationResult: Void? = await onTerminationIterator.next()
            XCTAssertNil(terminationResult)

            group.cancelAll()
        }

        withExtendedLifetime(stream) {}
    }

    func testSourceDeinitialized_whenStreaming_andEmptyBuffer() async throws {
        var (stream, source): (BufferedStream, BufferedStream.Source?) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 5, high: 10)
        )

        let (onTerminationStream, onTerminationContinuation) = AsyncStream<Void>.makeStream()
        source?.onTermination = {
            onTerminationContinuation.finish()
        }

        try await source?.write(1)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    onTerminationContinuation.yield()
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }

            var onTerminationIterator = onTerminationStream.makeAsyncIterator()
            _ = await onTerminationIterator.next()

            var iterator: BufferedStream<Int>.AsyncIterator? = stream.makeAsyncIterator()
            _ = try await iterator?.next()

            source = nil

            let terminationResult: Void? = await onTerminationIterator.next()
            XCTAssertNil(terminationResult)

            group.cancelAll()
        }
    }

    func testSourceDeinitialized_whenStreaming_andNotEmptyBuffer() async throws {
        var (stream, source): (BufferedStream, BufferedStream.Source?) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 5, high: 10)
        )

        let (onTerminationStream, onTerminationContinuation) = AsyncStream<Void>.makeStream()
        source?.onTermination = {
            onTerminationContinuation.finish()
        }

        try await source?.write(1)
        try await source?.write(2)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    onTerminationContinuation.yield()
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }

            var onTerminationIterator = onTerminationStream.makeAsyncIterator()
            _ = await onTerminationIterator.next()

            var iterator: BufferedStream<Int>.AsyncIterator? = stream.makeAsyncIterator()
            _ = try await iterator?.next()

            source = nil

            _ = await onTerminationIterator.next()

            _ = try await iterator?.next()
            _ = try await iterator?.next()

            let terminationResult: Void? = await onTerminationIterator.next()
            XCTAssertNil(terminationResult)

            group.cancelAll()
        }
    }

    func testSourceDeinitialized_whenSourceFinished() async throws {
        var (stream, source): (BufferedStream, BufferedStream.Source?) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 5, high: 10)
        )

        let (onTerminationStream, onTerminationContinuation) = AsyncStream<Void>.makeStream()
        source?.onTermination = {
            onTerminationContinuation.finish()
        }

        try await source?.write(1)
        try await source?.write(2)
        source?.finish(throwing: nil)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    onTerminationContinuation.yield()
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }

            var onTerminationIterator = onTerminationStream.makeAsyncIterator()
            _ = await onTerminationIterator.next()

            var iterator: BufferedStream<Int>.AsyncIterator? = stream.makeAsyncIterator()
            _ = try await iterator?.next()

            source = nil

            _ = await onTerminationIterator.next()

            _ = try await iterator?.next()
            _ = try await iterator?.next()

            let terminationResult: Void? = await onTerminationIterator.next()
            XCTAssertNil(terminationResult)

            group.cancelAll()
        }
    }

    func testSourceDeinitialized_whenFinished() async throws {
        var (stream, source): (BufferedStream, BufferedStream.Source?) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 5, high: 10)
        )

        let (onTerminationStream, onTerminationContinuation) = AsyncStream<Void>.makeStream()
        source?.onTermination = {
            onTerminationContinuation.finish()
        }

        source?.finish(throwing: nil)

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    onTerminationContinuation.yield()
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }

            var onTerminationIterator = onTerminationStream.makeAsyncIterator()
            _ = await onTerminationIterator.next()

            _ = stream.makeAsyncIterator()

            source = nil

            _ = await onTerminationIterator.next()

            let terminationResult: Void? = await onTerminationIterator.next()
            XCTAssertNil(terminationResult)

            group.cancelAll()
        }
    }

    func testSourceDeinitialized_whenStreaming_andSuspendedProducer() async throws {
        var (stream, source): (BufferedStream, BufferedStream.Source?) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 0, high: 0)
        )
        let (producerStream, producerContinuation) = AsyncThrowingStream<Void, Error>.makeStream()
        var iterator = stream.makeAsyncIterator()

        source?.write(1) {
            producerContinuation.yield(with: $0)
        }

        _ = try await iterator.next()
        source = nil

        do {
            try await producerStream.first { _ in true }
            XCTFail("We expected to throw here")
        } catch {
            XCTAssertTrue(error is AlreadyFinishedError)
        }
    }

    // MARK: - write

    func testWrite_whenInitial() async throws {
        let (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 2, high: 5)
        )

        try await source.write(1)

        var iterator = stream.makeAsyncIterator()
        let element = try await iterator.next()
        XCTAssertEqual(element, 1)
    }

    func testWrite_whenStreaming_andNoConsumer() async throws {
        let (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 2, high: 5)
        )

        try await source.write(1)
        try await source.write(2)

        var iterator = stream.makeAsyncIterator()
        let element1 = try await iterator.next()
        XCTAssertEqual(element1, 1)
        let element2 = try await iterator.next()
        XCTAssertEqual(element2, 2)
    }

    func testWrite_whenStreaming_andSuspendedConsumer() async throws {
        let (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 2, high: 5)
        )

        try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                try await stream.first { _ in true }
            }

            // This is always going to be a bit racy since we need the call to next() suspend
            try await Task.sleep(nanoseconds: 500_000_000)

            try await source.write(1)
            let element = try await group.next()
            XCTAssertEqual(element, 1)
        }
    }

    func testWrite_whenStreaming_andSuspendedConsumer_andEmptySequence() async throws {
        let (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 2, high: 5)
        )

        try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                try await stream.first { _ in true }
            }

            // This is always going to be a bit racy since we need the call to next() suspend
            try await Task.sleep(nanoseconds: 500_000_000)

            try await source.write(contentsOf: [])
            try await source.write(contentsOf: [1])
            let element = try await group.next()
            XCTAssertEqual(element, 1)
        }
    }

    // MARK: - enqueueProducer

    func testEnqueueProducer_whenStreaming_andAndCancelled() async throws {
        let (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 1, high: 2)
        )

        let (producerStream, producerSource) = AsyncThrowingStream<Void, Error>.makeStream()

        try await source.write(1)

        let writeResult = try { try source.write(2) }()

        switch writeResult {
        case .produceMore:
            preconditionFailure()
        case .enqueueCallback(let callbackToken):
            source.cancelCallback(callbackToken: callbackToken)

            source.enqueueCallback(callbackToken: callbackToken) { result in
                producerSource.yield(with: result)
            }
        }

        do {
            _ = try await producerStream.first { _ in true }
            XCTFail("Expected an error to be thrown")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let element = try await stream.first { _ in true }
        XCTAssertEqual(element, 1)
    }

    func testEnqueueProducer_whenStreaming_andAndCancelled_andAsync() async throws {
        let (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 1, high: 2)
        )

        try await source.write(1)

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await source.write(2)
            }

            group.cancelAll()
            do {
                try await group.next()
                XCTFail("Expected an error to be thrown")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }

        let element = try await stream.first { _ in true }
        XCTAssertEqual(element, 1)
    }

    func testEnqueueProducer_whenStreaming_andInterleaving() async throws {
        let (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 1, high: 1)
        )
        var iterator = stream.makeAsyncIterator()

        let (producerStream, producerSource) = AsyncThrowingStream<Void, Error>.makeStream()

        let writeResult = try { try source.write(1) }()

        switch writeResult {
        case .produceMore:
            preconditionFailure()
        case .enqueueCallback(let callbackToken):
            let element = try await iterator.next()
            XCTAssertEqual(element, 1)

            source.enqueueCallback(callbackToken: callbackToken) { result in
                producerSource.yield(with: result)
            }
        }

        do {
            _ = try await producerStream.first { _ in true }
        } catch {
            XCTFail("Expected no error to be thrown")
        }
    }

    func testEnqueueProducer_whenStreaming_andSuspending() async throws {
        let (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 1, high: 1)
        )
        var iterator = stream.makeAsyncIterator()

        let (producerStream, producerSource) = AsyncThrowingStream<Void, Error>.makeStream()

        let writeResult = try { try source.write(1) }()

        switch writeResult {
        case .produceMore:
            preconditionFailure()
        case .enqueueCallback(let callbackToken):
            source.enqueueCallback(callbackToken: callbackToken) { result in
                producerSource.yield(with: result)
            }
        }

        let element = try await iterator.next()
        XCTAssertEqual(element, 1)

        do {
            _ = try await producerStream.first { _ in true }
        } catch {
            XCTFail("Expected no error to be thrown")
        }
    }

    func testEnqueueProducer_whenFinished() async throws {
        let (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 1, high: 1)
        )
        var iterator = stream.makeAsyncIterator()

        let (producerStream, producerSource) = AsyncThrowingStream<Void, Error>.makeStream()

        let writeResult = try { try source.write(1) }()

        switch writeResult {
        case .produceMore:
            preconditionFailure()
        case .enqueueCallback(let callbackToken):
            source.finish(throwing: nil)

            source.enqueueCallback(callbackToken: callbackToken) { result in
                producerSource.yield(with: result)
            }
        }

        let element = try await iterator.next()
        XCTAssertEqual(element, 1)

        do {
            _ = try await producerStream.first { _ in true }
            XCTFail("Expected an error to be thrown")
        } catch {
            XCTAssertTrue(error is AlreadyFinishedError)
        }
    }

    // MARK: - cancelProducer

    func testCancelProducer_whenStreaming() async throws {
        let (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 1, high: 2)
        )

        let (producerStream, producerSource) = AsyncThrowingStream<Void, Error>.makeStream()

        try await source.write(1)

        let writeResult = try { try source.write(2) }()

        switch writeResult {
        case .produceMore:
            preconditionFailure()
        case .enqueueCallback(let callbackToken):
            source.enqueueCallback(callbackToken: callbackToken) { result in
                producerSource.yield(with: result)
            }

            source.cancelCallback(callbackToken: callbackToken)
        }

        do {
            _ = try await producerStream.first { _ in true }
            XCTFail("Expected an error to be thrown")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let element = try await stream.first { _ in true }
        XCTAssertEqual(element, 1)
    }

    func testCancelProducer_whenSourceFinished() async throws {
        let (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 1, high: 2)
        )

        let (producerStream, producerSource) = AsyncThrowingStream<Void, Error>.makeStream()

        try await source.write(1)

        let writeResult = try { try source.write(2) }()

        switch writeResult {
        case .produceMore:
            preconditionFailure()
        case .enqueueCallback(let callbackToken):
            source.enqueueCallback(callbackToken: callbackToken) { result in
                producerSource.yield(with: result)
            }

            source.finish(throwing: nil)

            source.cancelCallback(callbackToken: callbackToken)
        }

        do {
            _ = try await producerStream.first { _ in true }
            XCTFail("Expected an error to be thrown")
        } catch {
            XCTAssertTrue(error is AlreadyFinishedError)
        }

        let element = try await stream.first { _ in true }
        XCTAssertEqual(element, 1)
    }

    // MARK: - finish

    func testFinish_whenStreaming_andConsumerSuspended() async throws {
        let (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 1, high: 1)
        )

        try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                try await stream.first { $0 == 2 }
            }

            // This is always going to be a bit racy since we need the call to next() suspend
            try await Task.sleep(nanoseconds: 500_000_000)

            source.finish(throwing: nil)
            let element = try await group.next()
            XCTAssertEqual(element, .some(nil))
        }
    }

    func testFinish_whenInitial() async throws {
        let (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 1, high: 1)
        )

        source.finish(throwing: CancellationError())

        do {
            for try await _ in stream {}
            XCTFail("Expected an error to be thrown")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

    }

    // MARK: - Backpressure

    func testBackPressure() async throws {
        let (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 2, high: 4)
        )

        let (backPressureEventStream, backPressureEventContinuation) = AsyncStream.makeStream(
            of: Void.self
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while true {
                    backPressureEventContinuation.yield(())
                    try await source.write(contentsOf: [1])
                }
            }

            var backPressureEventIterator = backPressureEventStream.makeAsyncIterator()
            var iterator = stream.makeAsyncIterator()

            await backPressureEventIterator.next()
            await backPressureEventIterator.next()
            await backPressureEventIterator.next()
            await backPressureEventIterator.next()

            _ = try await iterator.next()
            _ = try await iterator.next()
            _ = try await iterator.next()

            await backPressureEventIterator.next()
            await backPressureEventIterator.next()
            await backPressureEventIterator.next()

            group.cancelAll()
        }
    }

    func testBackPressureSync() async throws {
        let (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 2, high: 4)
        )

        let (backPressureEventStream, backPressureEventContinuation) = AsyncStream.makeStream(
            of: Void.self
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                @Sendable func yield() {
                    backPressureEventContinuation.yield(())
                    source.write(contentsOf: [1]) { result in
                        switch result {
                        case .success:
                            yield()

                        case .failure:
                            break
                        }
                    }
                }

                yield()
            }

            var backPressureEventIterator = backPressureEventStream.makeAsyncIterator()
            var iterator = stream.makeAsyncIterator()

            await backPressureEventIterator.next()
            await backPressureEventIterator.next()
            await backPressureEventIterator.next()
            await backPressureEventIterator.next()

            _ = try await iterator.next()
            _ = try await iterator.next()
            _ = try await iterator.next()

            await backPressureEventIterator.next()
            await backPressureEventIterator.next()
            await backPressureEventIterator.next()

            group.cancelAll()
        }
    }

    func testThrowsError() async throws {
        let (stream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 2, high: 4)
        )

        try await source.write(1)
        try await source.write(2)
        source.finish(throwing: CancellationError())

        var elements = [Int]()
        var iterator = stream.makeAsyncIterator()

        do {
            while let element = try await iterator.next() {
                elements.append(element)
            }
            XCTFail("Expected an error to be thrown")
        } catch {
            XCTAssertTrue(error is CancellationError)
            XCTAssertEqual(elements, [1, 2])
        }

        let element = try await iterator.next()
        XCTAssertNil(element)
    }

    func testAsyncSequenceWrite() async throws {
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let (backpressuredStream, source) = BufferedStream.makeStream(
            of: Int.self,
            backPressureStrategy: .watermark(low: 2, high: 4)
        )

        continuation.yield(1)
        continuation.yield(2)
        continuation.finish()

        try await source.write(contentsOf: stream)
        source.finish(throwing: nil)

        let elements = try await backpressuredStream.collect()
        XCTAssertEqual(elements, [1, 2])
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AsyncSequence {
    /// Collect all elements in the sequence into an array.
    fileprivate func collect() async rethrows -> [Element] {
        try await self.reduce(into: []) { accumulated, next in
            accumulated.append(next)
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension BufferedStream.Source.WriteResult {
    func assertIsProducerMore() {
        switch self {
        case .produceMore:
            return

        case .enqueueCallback:
            XCTFail("Expected produceMore")
        }
    }

    func assertIsEnqueueCallback() {
        switch self {
        case .produceMore:
            XCTFail("Expected enqueueCallback")

        case .enqueueCallback:
            return
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AsyncStream {
    static func makeStream(
        of elementType: Element.Type = Element.self,
        bufferingPolicy limit: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded
    ) -> (stream: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation) {
        var continuation: AsyncStream<Element>.Continuation!
        let stream = AsyncStream(bufferingPolicy: limit) { continuation = $0 }
        return (stream, continuation!)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AsyncThrowingStream {
    static func makeStream(
        of elementType: Element.Type = Element.self,
        throwing failureType: Failure.Type = Failure.self,
        bufferingPolicy limit: AsyncThrowingStream<Element, Failure>.Continuation.BufferingPolicy =
            .unbounded
    ) -> (
        stream: AsyncThrowingStream<Element, Failure>,
        continuation: AsyncThrowingStream<Element, Failure>.Continuation
    ) where Failure == Error {
        var continuation: AsyncThrowingStream<Element, Failure>.Continuation!
        let stream = AsyncThrowingStream(bufferingPolicy: limit) { continuation = $0 }
        return (stream, continuation!)
    }
}
