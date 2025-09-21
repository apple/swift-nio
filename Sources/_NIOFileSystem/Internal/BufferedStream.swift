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

import DequeModule
import NIOConcurrencyHelpers

/// An asynchronous sequence generated from an error-throwing closure that
/// calls a continuation to produce new elements.
///
/// `BufferedStream` conforms to `AsyncSequence`, providing a convenient
/// way to create an asynchronous sequence without manually implementing an
/// asynchronous iterator. In particular, an asynchronous stream is well-suited
/// to adapt callback- or delegation-based APIs to participate with
/// `async`-`await`.
///
/// In contrast to `AsyncStream`, this type can throw an error from the awaited
/// `next()`, which terminates the stream with the thrown error.
///
/// You initialize an `BufferedStream` with a closure that receives an
/// `BufferedStream.Continuation`. Produce elements in this closure, then
/// provide them to the stream by calling the continuation's `yield(_:)` method.
/// When there are no further elements to produce, call the continuation's
/// `finish()` method. This causes the sequence iterator to produce a `nil`,
/// which terminates the sequence. If an error occurs, call the continuation's
/// `finish(throwing:)` method, which causes the iterator's `next()` method to
/// throw the error to the awaiting call point. The continuation is `Sendable`,
/// which permits calling it from concurrent contexts external to the iteration
/// of the `BufferedStream`.
///
/// An arbitrary source of elements can produce elements faster than they are
/// consumed by a caller iterating over them. Because of this, `BufferedStream`
/// defines a buffering behavior, allowing the stream to buffer a specific
/// number of oldest or newest elements. By default, the buffer limit is
/// `Int.max`, which means it's unbounded.
///
/// ### Adapting Existing Code to Use Streams
///
/// To adapt existing callback code to use `async`-`await`, use the callbacks
/// to provide values to the stream, by using the continuation's `yield(_:)`
/// method.
///
/// Consider a hypothetical `QuakeMonitor` type that provides callers with
/// `Quake` instances every time it detects an earthquake. To receive callbacks,
/// callers set a custom closure as the value of the monitor's
/// `quakeHandler` property, which the monitor calls back as necessary. Callers
/// can also set an `errorHandler` to receive asynchronous error notifications,
/// such as the monitor service suddenly becoming unavailable.
///
///     class QuakeMonitor {
///         var quakeHandler: ((Quake) -> Void)?
///         var errorHandler: ((Error) -> Void)?
///
///         func startMonitoring() {…}
///         func stopMonitoring() {…}
///     }
///
/// To adapt this to use `async`-`await`, extend the `QuakeMonitor` to add a
/// `quakes` property, of type `BufferedStream<Quake>`. In the getter for
/// this property, return an `BufferedStream`, whose `build` closure --
/// called at runtime to create the stream -- uses the continuation to
/// perform the following steps:
///
/// 1. Creates a `QuakeMonitor` instance.
/// 2. Sets the monitor's `quakeHandler` property to a closure that receives
/// each `Quake` instance and forwards it to the stream by calling the
/// continuation's `yield(_:)` method.
/// 3. Sets the monitor's `errorHandler` property to a closure that receives
/// any error from the monitor and forwards it to the stream by calling the
/// continuation's `finish(throwing:)` method. This causes the stream's
/// iterator to throw the error and terminate the stream.
/// 4. Sets the continuation's `onTermination` property to a closure that
/// calls `stopMonitoring()` on the monitor.
/// 5. Calls `startMonitoring` on the `QuakeMonitor`.
///
/// ```
/// extension QuakeMonitor {
///
///     static var throwingQuakes: BufferedStream<Quake, Error> {
///         BufferedStream { continuation in
///             let monitor = QuakeMonitor()
///             monitor.quakeHandler = { quake in
///                  continuation.yield(quake)
///             }
///             monitor.errorHandler = { error in
///                 continuation.finish(throwing: error)
///             }
///             continuation.onTermination = { @Sendable _ in
///                 monitor.stopMonitoring()
///             }
///             monitor.startMonitoring()
///         }
///     }
/// }
/// ```
///
///
/// Because the stream is an `AsyncSequence`, the call point uses the
/// `for`-`await`-`in` syntax to process each `Quake` instance as produced by the stream:
///
///     do {
///         for try await quake in quakeStream {
///             print("Quake: \(quake.date)")
///         }
///         print("Stream done.")
///     } catch {
///         print("Error: \(error)")
///     }
///
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
internal struct BufferedStream<Element: Sendable> {
    final class _Backing: Sendable {
        let storage: _BackPressuredStorage

        init(storage: _BackPressuredStorage) {
            self.storage = storage
        }

        deinit {
            self.storage.sequenceDeinitialized()
        }
    }

    enum _Implementation: Sendable {
        /// This is the implementation with backpressure based on the Source
        case backpressured(_Backing)
    }

    let implementation: _Implementation
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension BufferedStream: AsyncSequence {
    /// The asynchronous iterator for iterating an asynchronous stream.
    ///
    /// This type is not `Sendable`. Don't use it from multiple
    /// concurrent contexts. It is a programmer error to invoke `next()` from a
    /// concurrent context that contends with another such call, which
    /// results in a call to `fatalError()`.
    internal struct Iterator: AsyncIteratorProtocol {
        final class _Backing {
            let storage: _BackPressuredStorage

            init(storage: _BackPressuredStorage) {
                self.storage = storage
                self.storage.iteratorInitialized()
            }

            deinit {
                self.storage.iteratorDeinitialized()
            }
        }
        enum _Implementation {
            /// This is the implementation with backpressure based on the Source
            case backpressured(_Backing)
        }

        var implementation: _Implementation

        /// The next value from the asynchronous stream.
        ///
        /// When `next()` returns `nil`, this signifies the end of the
        /// `BufferedStream`.
        ///
        /// It is a programmer error to invoke `next()` from a concurrent context
        /// that contends with another such call, which results in a call to
        ///  `fatalError()`.
        ///
        /// If you cancel the task this iterator is running in while `next()` is
        /// awaiting a value, the `BufferedStream` terminates. In this case,
        /// `next()` may return `nil` immediately, or else return `nil` on
        /// subsequent calls.
        internal mutating func next() async throws -> Element? {
            switch self.implementation {
            case .backpressured(let backing):
                return try await backing.storage.next()
            }
        }
    }

    /// Creates the asynchronous iterator that produces elements of this
    /// asynchronous sequence.
    internal func makeAsyncIterator() -> Iterator {
        switch self.implementation {
        case .backpressured(let backing):
            return Iterator(implementation: .backpressured(.init(storage: backing.storage)))
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension BufferedStream: Sendable {}

internal struct _ManagedCriticalState<State>: @unchecked Sendable {
    let lock: NIOLockedValueBox<State>

    internal init(_ initial: State) {
        self.lock = .init(initial)
    }

    internal func withCriticalRegion<R>(
        _ critical: (inout State) throws -> R
    ) rethrows -> R {
        try self.lock.withLockedValue(critical)
    }
}

internal struct AlreadyFinishedError: Error {}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension BufferedStream {
    /// A mechanism to interface between producer code and an asynchronous stream.
    ///
    /// Use this source to provide elements to the stream by calling one of the `write` methods, then terminate the stream normally
    /// by calling the `finish()` method. You can also use the source's `finish(throwing:)` method to terminate the stream by
    /// throwing an error.
    internal struct Source: Sendable {
        /// A strategy that handles the backpressure of the asynchronous stream.
        internal struct BackPressureStrategy: Sendable {
            /// When the high watermark is reached producers will be suspended. All producers will be resumed again once
            /// the low watermark is reached.
            internal static func watermark(low: Int, high: Int) -> BackPressureStrategy {
                BackPressureStrategy(
                    internalBackPressureStrategy: .watermark(.init(low: low, high: high))
                )
            }

            private init(internalBackPressureStrategy: _InternalBackPressureStrategy) {
                self._internalBackPressureStrategy = internalBackPressureStrategy
            }

            fileprivate let _internalBackPressureStrategy: _InternalBackPressureStrategy
        }

        /// A type that indicates the result of writing elements to the source.
        internal enum WriteResult: Sendable {
            /// A token that is returned when the asynchronous stream's backpressure strategy indicated that production should
            /// be suspended. Use this token to enqueue a callback by  calling the ``enqueueCallback(_:)`` method.
            internal struct CallbackToken: Sendable {
                let id: UInt
            }

            /// Indicates that more elements should be produced and written to the source.
            case produceMore

            /// Indicates that a callback should be enqueued.
            ///
            /// The associated token should be passed to the ``enqueueCallback(_:)`` method.
            case enqueueCallback(CallbackToken)
        }

        /// Backing class for the source used to hook a deinit.
        final class _Backing: Sendable {
            let storage: _BackPressuredStorage

            init(storage: _BackPressuredStorage) {
                self.storage = storage
            }

            deinit {
                self.storage.sourceDeinitialized()
            }
        }

        /// A callback to invoke when the stream finished.
        ///
        /// The stream finishes and calls this closure in the following cases:
        /// - No iterator was created and the sequence was deinited
        /// - An iterator was created and deinited
        /// - After ``finish(throwing:)`` was called and all elements have been consumed
        /// - The consuming task got cancelled
        internal var onTermination: (@Sendable () -> Void)? {
            set {
                self._backing.storage.onTermination = newValue
            }
            get {
                self._backing.storage.onTermination
            }
        }

        private var _backing: _Backing

        internal init(storage: _BackPressuredStorage) {
            self._backing = .init(storage: storage)
        }

        /// Writes new elements to the asynchronous stream.
        ///
        /// If there is a task consuming the stream and awaiting the next element then the task will get resumed with the
        /// first element of the provided sequence. If the asynchronous stream already terminated then this method will throw an error
        /// indicating the failure.
        ///
        /// - Parameter sequence: The elements to write to the asynchronous stream.
        /// - Returns: The result that indicates if more elements should be produced at this time.
        internal func write<S>(contentsOf sequence: S) throws -> WriteResult
        where Element == S.Element, S: Sequence, Element: Sendable {
            try self._backing.storage.write(contentsOf: sequence)
        }

        /// Write the element to the asynchronous stream.
        ///
        /// If there is a task consuming the stream and awaiting the next element then the task will get resumed with the
        /// provided element. If the asynchronous stream already terminated then this method will throw an error
        /// indicating the failure.
        ///
        /// - Parameter element: The element to write to the asynchronous stream.
        /// - Returns: The result that indicates if more elements should be produced at this time.
        internal func write(_ element: Element) throws -> WriteResult {
            try self._backing.storage.write(contentsOf: CollectionOfOne(element))
        }

        /// Enqueues a callback that will be invoked once more elements should be produced.
        ///
        /// Call this method after ``write(contentsOf:)`` or ``write(:)`` returned ``WriteResult/enqueueCallback(_:)``.
        ///
        /// - Important: Enqueueing the same token multiple times is not allowed.
        ///
        /// - Parameters:
        ///   - callbackToken: The callback token.
        ///   - onProduceMore: The callback which gets invoked once more elements should be produced.
        internal func enqueueCallback(
            callbackToken: WriteResult.CallbackToken,
            onProduceMore: @escaping @Sendable (Result<Void, Error>) -> Void
        ) {
            self._backing.storage.enqueueProducer(
                callbackToken: callbackToken,
                onProduceMore: onProduceMore
            )
        }

        /// Cancel an enqueued callback.
        ///
        /// Call this method to cancel a callback enqueued by the ``enqueueCallback(callbackToken:onProduceMore:)`` method.
        ///
        /// - Note: This methods supports being called before ``enqueueCallback(callbackToken:onProduceMore:)`` is called and
        /// will mark the passed `callbackToken` as cancelled.
        ///
        /// - Parameter callbackToken: The callback token.
        internal func cancelCallback(callbackToken: WriteResult.CallbackToken) {
            self._backing.storage.cancelProducer(callbackToken: callbackToken)
        }

        /// Write new elements to the asynchronous stream and provide a callback which will be invoked once more elements should be produced.
        ///
        /// If there is a task consuming the stream and awaiting the next element then the task will get resumed with the
        /// first element of the provided sequence. If the asynchronous stream already terminated then `onProduceMore` will be invoked with
        /// a `Result.failure`.
        ///
        /// - Parameters:
        ///   - sequence: The elements to write to the asynchronous stream.
        ///   - onProduceMore: The callback which gets invoked once more elements should be produced. This callback might be
        ///   invoked during the call to ``write(contentsOf:onProduceMore:)``.
        internal func write<S>(
            contentsOf sequence: S,
            onProduceMore: @escaping @Sendable (Result<Void, Error>) -> Void
        ) where Element == S.Element, S: Sequence, Element: Sendable {
            do {
                let writeResult = try self.write(contentsOf: sequence)

                switch writeResult {
                case .produceMore:
                    onProduceMore(Result<Void, Error>.success(()))

                case .enqueueCallback(let callbackToken):
                    self.enqueueCallback(callbackToken: callbackToken, onProduceMore: onProduceMore)
                }
            } catch {
                onProduceMore(.failure(error))
            }
        }

        /// Writes the element to the asynchronous stream.
        ///
        /// If there is a task consuming the stream and awaiting the next element then the task will get resumed with the
        /// provided element. If the asynchronous stream already terminated then `onProduceMore` will be invoked with
        /// a `Result.failure`.
        ///
        /// - Parameters:
        ///   - sequence: The element to write to the asynchronous stream.
        ///   - onProduceMore: The callback which gets invoked once more elements should be produced. This callback might be
        ///   invoked during the call to ``write(_:onProduceMore:)``.
        internal func write(
            _ element: Element,
            onProduceMore: @escaping @Sendable (Result<Void, Error>) -> Void
        ) {
            self.write(contentsOf: CollectionOfOne(element), onProduceMore: onProduceMore)
        }

        /// Write new elements to the asynchronous stream.
        ///
        /// If there is a task consuming the stream and awaiting the next element then the task will get resumed with the
        /// first element of the provided sequence. If the asynchronous stream already terminated then this method will throw an error
        /// indicating the failure.
        ///
        /// This method returns once more elements should be produced.
        ///
        /// - Parameters:
        ///   - sequence: The elements to write to the asynchronous stream.
        internal func write<S>(contentsOf sequence: S) async throws
        where Element == S.Element, S: Sequence, Element: Sendable {
            let writeResult = try { try self.write(contentsOf: sequence) }()

            switch writeResult {
            case .produceMore:
                return

            case .enqueueCallback(let callbackToken):
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        self.enqueueCallback(
                            callbackToken: callbackToken,
                            onProduceMore: { result in
                                switch result {
                                case .success():
                                    continuation.resume(returning: ())
                                case .failure(let error):
                                    continuation.resume(throwing: error)
                                }
                            }
                        )
                    }
                } onCancel: {
                    self.cancelCallback(callbackToken: callbackToken)
                }
            }
        }

        /// Write new element to the asynchronous stream.
        ///
        /// If there is a task consuming the stream and awaiting the next element then the task will get resumed with the
        /// provided element. If the asynchronous stream already terminated then this method will throw an error
        /// indicating the failure.
        ///
        /// This method returns once more elements should be produced.
        ///
        /// - Parameters:
        ///   - sequence: The element to write to the asynchronous stream.
        internal func write(_ element: Element) async throws {
            try await self.write(contentsOf: CollectionOfOne(element))
        }

        /// Write the elements of the asynchronous sequence to the asynchronous stream.
        ///
        /// This method returns once the provided asynchronous sequence or the  the asynchronous stream finished.
        ///
        /// - Important: This method does not finish the source if consuming the upstream sequence terminated.
        ///
        /// - Parameters:
        ///   - sequence: The elements to write to the asynchronous stream.
        internal func write<S>(contentsOf sequence: S) async throws
        where Element == S.Element, S: AsyncSequence, Element: Sendable {
            for try await element in sequence {
                try await self.write(contentsOf: CollectionOfOne(element))
            }
        }

        /// Indicates that the production terminated.
        ///
        /// After all buffered elements are consumed the next iteration point will return `nil` or throw an error.
        ///
        /// Calling this function more than once has no effect. After calling finish, the stream enters a terminal state and doesn't accept
        /// new elements.
        ///
        /// - Parameters:
        ///   - error: The error to throw, or `nil`, to finish normally.
        internal func finish(throwing error: Error?) {
            self._backing.storage.finish(error)
        }
    }

    /// Initializes a new ``BufferedStream`` and an ``BufferedStream/Source``.
    ///
    /// - Parameters:
    ///   - elementType: The element type of the stream.
    ///   - failureType: The failure type of the stream.
    ///   - backPressureStrategy: The backpressure strategy that the stream should use.
    /// - Returns: A tuple containing the stream and its source. The source should be passed to the
    ///   producer while the stream should be passed to the consumer.
    internal static func makeStream(
        of elementType: Element.Type = Element.self,
        throwing failureType: Error.Type = Error.self,
        backPressureStrategy: Source.BackPressureStrategy
    ) -> (`Self`, Source) where Error == Error {
        let storage = _BackPressuredStorage(
            backPressureStrategy: backPressureStrategy._internalBackPressureStrategy
        )
        let source = Source(storage: storage)

        return (.init(storage: storage), source)
    }

    init(storage: _BackPressuredStorage) {
        self.implementation = .backpressured(.init(storage: storage))
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension BufferedStream {
    struct _WatermarkBackPressureStrategy {
        /// The low watermark where demand should start.
        private let _low: Int
        /// The high watermark where demand should be stopped.
        private let _high: Int

        /// Initializes a new ``_WatermarkBackPressureStrategy``.
        ///
        /// - Parameters:
        ///   - low: The low watermark where demand should start.
        ///   - high: The high watermark where demand should be stopped.
        init(low: Int, high: Int) {
            precondition(low <= high)
            self._low = low
            self._high = high
        }

        func didYield(bufferDepth: Int) -> Bool {
            // We are demanding more until we reach the high watermark
            bufferDepth < self._high
        }

        func didConsume(bufferDepth: Int) -> Bool {
            // We start demanding again once we are below the low watermark
            bufferDepth < self._low
        }
    }

    enum _InternalBackPressureStrategy {
        case watermark(_WatermarkBackPressureStrategy)

        mutating func didYield(bufferDepth: Int) -> Bool {
            switch self {
            case .watermark(let strategy):
                return strategy.didYield(bufferDepth: bufferDepth)
            }
        }

        mutating func didConsume(bufferDepth: Int) -> Bool {
            switch self {
            case .watermark(let strategy):
                return strategy.didConsume(bufferDepth: bufferDepth)
            }
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension BufferedStream {
    // We are unchecked Sendable since we are protecting our state with a lock.
    final class _BackPressuredStorage: Sendable {
        /// The state machine
        let _stateMachine: _ManagedCriticalState<_StateMachine>

        var onTermination: (@Sendable () -> Void)? {
            set {
                self._stateMachine.withCriticalRegion {
                    $0._onTermination = newValue
                }
            }
            get {
                self._stateMachine.withCriticalRegion {
                    $0._onTermination
                }
            }
        }

        init(
            backPressureStrategy: _InternalBackPressureStrategy
        ) {
            self._stateMachine = .init(.init(backPressureStrategy: backPressureStrategy))
        }

        func sequenceDeinitialized() {
            let action = self._stateMachine.withCriticalRegion {
                $0.sequenceDeinitialized()
            }

            switch action {
            case .callOnTermination(let onTermination):
                onTermination?()

            case .failProducersAndCallOnTermination(let producerContinuations, let onTermination):
                for producerContinuation in producerContinuations {
                    producerContinuation(.failure(AlreadyFinishedError()))
                }
                onTermination?()

            case .none:
                break
            }
        }

        func iteratorInitialized() {
            self._stateMachine.withCriticalRegion {
                $0.iteratorInitialized()
            }
        }

        func iteratorDeinitialized() {
            let action = self._stateMachine.withCriticalRegion {
                $0.iteratorDeinitialized()
            }

            switch action {
            case .callOnTermination(let onTermination):
                onTermination?()

            case .failProducersAndCallOnTermination(let producerContinuations, let onTermination):
                for producerContinuation in producerContinuations {
                    producerContinuation(.failure(AlreadyFinishedError()))
                }
                onTermination?()

            case .none:
                break
            }
        }

        func sourceDeinitialized() {
            let action = self._stateMachine.withCriticalRegion {
                $0.sourceDeinitialized()
            }

            switch action {
            case .callOnTermination(let onTermination):
                onTermination?()

            case .failProducersAndCallOnTermination(let producerContinuations, let onTermination):
                for producerContinuation in producerContinuations {
                    producerContinuation(.failure(AlreadyFinishedError()))
                }
                onTermination?()

            case .failProducers(let producerContinuations):
                for producerContinuation in producerContinuations {
                    producerContinuation(.failure(AlreadyFinishedError()))
                }

            case .none:
                break
            }
        }

        func write(
            contentsOf sequence: some Sequence<Element>
        ) throws -> Source.WriteResult {
            let action = self._stateMachine.withCriticalRegion {
                $0.write(sequence)
            }

            switch action {
            case .returnProduceMore:
                return .produceMore

            case .returnEnqueue(let callbackToken):
                return .enqueueCallback(callbackToken)

            case .resumeConsumerAndReturnProduceMore(let continuation, let element):
                continuation.resume(returning: element)
                return .produceMore

            case .resumeConsumerAndReturnEnqueue(let continuation, let element, let callbackToken):
                continuation.resume(returning: element)
                return .enqueueCallback(callbackToken)

            case .throwFinishedError:
                throw AlreadyFinishedError()
            }
        }

        func enqueueProducer(
            callbackToken: Source.WriteResult.CallbackToken,
            onProduceMore: @escaping @Sendable (Result<Void, Error>) -> Void
        ) {
            let action = self._stateMachine.withCriticalRegion {
                $0.enqueueProducer(callbackToken: callbackToken, onProduceMore: onProduceMore)
            }

            switch action {
            case .resumeProducer(let onProduceMore):
                onProduceMore(Result<Void, Error>.success(()))

            case .resumeProducerWithError(let onProduceMore, let error):
                onProduceMore(Result<Void, Error>.failure(error))

            case .none:
                break
            }
        }

        func cancelProducer(callbackToken: Source.WriteResult.CallbackToken) {
            let action = self._stateMachine.withCriticalRegion {
                $0.cancelProducer(callbackToken: callbackToken)
            }

            switch action {
            case .resumeProducerWithCancellationError(let onProduceMore):
                onProduceMore(Result<Void, Error>.failure(CancellationError()))

            case .none:
                break
            }
        }

        func finish(_ failure: Error?) {
            let action = self._stateMachine.withCriticalRegion {
                $0.finish(failure)
            }

            switch action {
            case .callOnTermination(let onTermination):
                onTermination?()

            case .resumeConsumerAndCallOnTermination(
                let consumerContinuation,
                let failure,
                let onTermination
            ):
                switch failure {
                case .some(let error):
                    consumerContinuation.resume(throwing: error)
                case .none:
                    consumerContinuation.resume(returning: nil)
                }

                onTermination?()

            case .resumeProducers(let producerContinuations):
                for producerContinuation in producerContinuations {
                    producerContinuation(.failure(AlreadyFinishedError()))
                }

            case .none:
                break
            }
        }

        func next() async throws -> Element? {
            let action = self._stateMachine.withCriticalRegion {
                $0.next()
            }

            switch action {
            case .returnElement(let element):
                return element

            case .returnElementAndResumeProducers(let element, let producerContinuations):
                for producerContinuation in producerContinuations {
                    producerContinuation(Result<Void, Error>.success(()))
                }

                return element

            case .returnErrorAndCallOnTermination(let failure, let onTermination):
                onTermination?()
                switch failure {
                case .some(let error):
                    throw error

                case .none:
                    return nil
                }

            case .returnNil:
                return nil

            case .suspendTask:
                return try await self.suspendNext()
            }
        }

        func suspendNext() async throws -> Element? {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let action = self._stateMachine.withCriticalRegion {
                        $0.suspendNext(continuation: continuation)
                    }

                    switch action {
                    case .resumeConsumerWithElement(let continuation, let element):
                        continuation.resume(returning: element)

                    case .resumeConsumerWithElementAndProducers(
                        let continuation,
                        let element,
                        let producerContinuations
                    ):
                        continuation.resume(returning: element)
                        for producerContinuation in producerContinuations {
                            producerContinuation(Result<Void, Error>.success(()))
                        }

                    case .resumeConsumerWithErrorAndCallOnTermination(
                        let continuation,
                        let failure,
                        let onTermination
                    ):
                        switch failure {
                        case .some(let error):
                            continuation.resume(throwing: error)

                        case .none:
                            continuation.resume(returning: nil)
                        }
                        onTermination?()

                    case .resumeConsumerWithNil(let continuation):
                        continuation.resume(returning: nil)

                    case .none:
                        break
                    }
                }
            } onCancel: {
                let action = self._stateMachine.withCriticalRegion {
                    $0.cancelNext()
                }

                switch action {
                case .resumeConsumerWithCancellationErrorAndCallOnTermination(
                    let continuation,
                    let onTermination
                ):
                    continuation.resume(throwing: CancellationError())
                    onTermination?()

                case .failProducersAndCallOnTermination(
                    let producerContinuations,
                    let onTermination
                ):
                    for producerContinuation in producerContinuations {
                        producerContinuation(.failure(AlreadyFinishedError()))
                    }
                    onTermination?()

                case .none:
                    break
                }
            }
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension BufferedStream {
    /// The state machine of the backpressured async stream.
    struct _StateMachine {
        enum _State {
            struct Initial {
                /// The backpressure strategy.
                var backPressureStrategy: _InternalBackPressureStrategy
                /// Indicates if the iterator was initialized.
                var iteratorInitialized: Bool
                /// The onTermination callback.
                var onTermination: (@Sendable () -> Void)?
            }

            struct Streaming {
                /// The backpressure strategy.
                var backPressureStrategy: _InternalBackPressureStrategy
                /// Indicates if the iterator was initialized.
                var iteratorInitialized: Bool
                /// The onTermination callback.
                var onTermination: (@Sendable () -> Void)?
                /// The buffer of elements.
                var buffer: Deque<Element>
                /// The optional consumer continuation.
                var consumerContinuation: CheckedContinuation<Element?, Error>?
                /// The producer continuations.
                var producerContinuations: Deque<(UInt, (Result<Void, Error>) -> Void)>
                /// The producers that have been cancelled.
                var cancelledAsyncProducers: Deque<UInt>
                /// Indicates if we currently have outstanding demand.
                var hasOutstandingDemand: Bool
            }

            struct SourceFinished {
                /// Indicates if the iterator was initialized.
                var iteratorInitialized: Bool
                /// The buffer of elements.
                var buffer: Deque<Element>
                /// The failure that should be thrown after the last element has been consumed.
                var failure: Error?
                /// The onTermination callback.
                var onTermination: (@Sendable () -> Void)?
            }

            case initial(Initial)
            /// The state once either any element was yielded or `next()` was called.
            case streaming(Streaming)
            /// The state once the source signalled that it is finished.
            case sourceFinished(SourceFinished)

            /// The state once there can be no outstanding demand. This can happen if:
            /// 1. The iterator was deinited
            /// 2. The source finished and all buffered elements have been consumed
            case finished(iteratorInitialized: Bool)

            /// An intermediate state to avoid CoWs.
            case modify
        }

        /// The state machine's current state.
        var _state: _State

        // The ID used for the next CallbackToken.
        var nextCallbackTokenID: UInt = 0

        var _onTermination: (@Sendable () -> Void)? {
            set {
                switch self._state {
                case .initial(var initial):
                    initial.onTermination = newValue
                    self._state = .initial(initial)

                case .streaming(var streaming):
                    streaming.onTermination = newValue
                    self._state = .streaming(streaming)

                case .sourceFinished(var sourceFinished):
                    sourceFinished.onTermination = newValue
                    self._state = .sourceFinished(sourceFinished)

                case .finished:
                    break

                case .modify:
                    fatalError("AsyncStream internal inconsistency")
                }
            }
            get {
                switch self._state {
                case .initial(let initial):
                    return initial.onTermination

                case .streaming(let streaming):
                    return streaming.onTermination

                case .sourceFinished(let sourceFinished):
                    return sourceFinished.onTermination

                case .finished:
                    return nil

                case .modify:
                    fatalError("AsyncStream internal inconsistency")
                }
            }
        }

        /// Initializes a new `StateMachine`.
        ///
        /// We are passing and holding the back-pressure strategy here because
        /// it is a customizable extension of the state machine.
        ///
        /// - Parameter backPressureStrategy: The back-pressure strategy.
        init(
            backPressureStrategy: _InternalBackPressureStrategy
        ) {
            self._state = .initial(
                .init(
                    backPressureStrategy: backPressureStrategy,
                    iteratorInitialized: false,
                    onTermination: nil
                )
            )
        }

        /// Generates the next callback token.
        mutating func nextCallbackToken() -> Source.WriteResult.CallbackToken {
            let id = self.nextCallbackTokenID
            self.nextCallbackTokenID += 1
            return .init(id: id)
        }

        /// Actions returned by `sequenceDeinitialized()`.
        enum SequenceDeinitializedAction {
            /// Indicates that `onTermination` should be called.
            case callOnTermination((@Sendable () -> Void)?)
            /// Indicates that  all producers should be failed and `onTermination` should be called.
            case failProducersAndCallOnTermination(
                [(Result<Void, Error>) -> Void],
                (@Sendable () -> Void)?
            )
        }

        mutating func sequenceDeinitialized() -> SequenceDeinitializedAction? {
            switch self._state {
            case .initial(let initial):
                if initial.iteratorInitialized {
                    // An iterator was created and we deinited the sequence.
                    // This is an expected pattern and we just continue on normal.
                    return .none
                } else {
                    // No iterator was created so we can transition to finished right away.
                    self._state = .finished(iteratorInitialized: false)

                    return .callOnTermination(initial.onTermination)
                }

            case .streaming(let streaming):
                if streaming.iteratorInitialized {
                    // An iterator was created and we deinited the sequence.
                    // This is an expected pattern and we just continue on normal.
                    return .none
                } else {
                    // No iterator was created so we can transition to finished right away.
                    self._state = .finished(iteratorInitialized: false)

                    return .failProducersAndCallOnTermination(
                        Array(streaming.producerContinuations.map { $0.1 }),
                        streaming.onTermination
                    )
                }

            case .sourceFinished(let sourceFinished):
                if sourceFinished.iteratorInitialized {
                    // An iterator was created and we deinited the sequence.
                    // This is an expected pattern and we just continue on normal.
                    return .none
                } else {
                    // No iterator was created so we can transition to finished right away.
                    self._state = .finished(iteratorInitialized: false)

                    return .callOnTermination(sourceFinished.onTermination)
                }

            case .finished:
                // We are already finished so there is nothing left to clean up.
                // This is just the references dropping afterwards.
                return .none

            case .modify:
                fatalError("AsyncStream internal inconsistency")
            }
        }

        mutating func iteratorInitialized() {
            switch self._state {
            case .initial(var initial):
                if initial.iteratorInitialized {
                    // Our sequence is a unicast sequence and does not support multiple AsyncIterator's
                    fatalError("Only a single AsyncIterator can be created")
                } else {
                    // The first and only iterator was initialized.
                    initial.iteratorInitialized = true
                    self._state = .initial(initial)
                }

            case .streaming(var streaming):
                if streaming.iteratorInitialized {
                    // Our sequence is a unicast sequence and does not support multiple AsyncIterator's
                    fatalError("Only a single AsyncIterator can be created")
                } else {
                    // The first and only iterator was initialized.
                    streaming.iteratorInitialized = true
                    self._state = .streaming(streaming)
                }

            case .sourceFinished(var sourceFinished):
                if sourceFinished.iteratorInitialized {
                    // Our sequence is a unicast sequence and does not support multiple AsyncIterator's
                    fatalError("Only a single AsyncIterator can be created")
                } else {
                    // The first and only iterator was initialized.
                    sourceFinished.iteratorInitialized = true
                    self._state = .sourceFinished(sourceFinished)
                }

            case .finished(iteratorInitialized: true):
                // Our sequence is a unicast sequence and does not support multiple AsyncIterator's
                fatalError("Only a single AsyncIterator can be created")

            case .finished(iteratorInitialized: false):
                // It is strange that an iterator is created after we are finished
                // but it can definitely happen, e.g.
                // Sequence.init -> source.finish -> sequence.makeAsyncIterator
                self._state = .finished(iteratorInitialized: true)

            case .modify:
                fatalError("AsyncStream internal inconsistency")
            }
        }

        /// Actions returned by `iteratorDeinitialized()`.
        enum IteratorDeinitializedAction {
            /// Indicates that `onTermination` should be called.
            case callOnTermination((@Sendable () -> Void)?)
            /// Indicates that  all producers should be failed and `onTermination` should be called.
            case failProducersAndCallOnTermination(
                [(Result<Void, Error>) -> Void],
                (@Sendable () -> Void)?
            )
        }

        mutating func iteratorDeinitialized() -> IteratorDeinitializedAction? {
            switch self._state {
            case .initial(let initial):
                if initial.iteratorInitialized {
                    // An iterator was created and deinited. Since we only support
                    // a single iterator we can now transition to finish.
                    self._state = .finished(iteratorInitialized: true)
                    return .callOnTermination(initial.onTermination)
                } else {
                    // An iterator needs to be initialized before it can be deinitialized.
                    fatalError("AsyncStream internal inconsistency")
                }

            case .streaming(let streaming):
                if streaming.iteratorInitialized {
                    // An iterator was created and deinited. Since we only support
                    // a single iterator we can now transition to finish.
                    self._state = .finished(iteratorInitialized: true)

                    return .failProducersAndCallOnTermination(
                        Array(streaming.producerContinuations.map { $0.1 }),
                        streaming.onTermination
                    )
                } else {
                    // An iterator needs to be initialized before it can be deinitialized.
                    fatalError("AsyncStream internal inconsistency")
                }

            case .sourceFinished(let sourceFinished):
                if sourceFinished.iteratorInitialized {
                    // An iterator was created and deinited. Since we only support
                    // a single iterator we can now transition to finish.
                    self._state = .finished(iteratorInitialized: true)
                    return .callOnTermination(sourceFinished.onTermination)
                } else {
                    // An iterator needs to be initialized before it can be deinitialized.
                    fatalError("AsyncStream internal inconsistency")
                }

            case .finished:
                // We are already finished so there is nothing left to clean up.
                // This is just the references dropping afterwards.
                return .none

            case .modify:
                fatalError("AsyncStream internal inconsistency")
            }
        }

        /// Actions returned by `sourceDeinitialized()`.
        enum SourceDeinitializedAction {
            /// Indicates that `onTermination` should be called.
            case callOnTermination((() -> Void)?)
            /// Indicates that  all producers should be failed and `onTermination` should be called.
            case failProducersAndCallOnTermination(
                [(Result<Void, Error>) -> Void],
                (@Sendable () -> Void)?
            )
            /// Indicates that all producers should be failed.
            case failProducers([(Result<Void, Error>) -> Void])
        }

        mutating func sourceDeinitialized() -> SourceDeinitializedAction? {
            switch self._state {
            case .initial(let initial):
                // The source got deinited before anything was written
                self._state = .finished(iteratorInitialized: initial.iteratorInitialized)
                return .callOnTermination(initial.onTermination)

            case .streaming(let streaming):
                if streaming.buffer.isEmpty {
                    // We can transition to finished right away since the buffer is empty now
                    self._state = .finished(iteratorInitialized: streaming.iteratorInitialized)

                    return .failProducersAndCallOnTermination(
                        Array(streaming.producerContinuations.map { $0.1 }),
                        streaming.onTermination
                    )
                } else {
                    // The continuation must be `nil` if the buffer has elements
                    precondition(streaming.consumerContinuation == nil)

                    self._state = .sourceFinished(
                        .init(
                            iteratorInitialized: streaming.iteratorInitialized,
                            buffer: streaming.buffer,
                            failure: nil,
                            onTermination: streaming.onTermination
                        )
                    )

                    return .failProducers(
                        Array(streaming.producerContinuations.map { $0.1 })
                    )
                }

            case .sourceFinished, .finished:
                // This is normal and we just have to tolerate it
                return .none

            case .modify:
                fatalError("AsyncStream internal inconsistency")
            }
        }

        /// Actions returned by `write()`.
        enum WriteAction {
            /// Indicates that the producer should be notified to produce more.
            case returnProduceMore
            /// Indicates that the producer should be suspended to stop producing.
            case returnEnqueue(
                callbackToken: Source.WriteResult.CallbackToken
            )
            /// Indicates that the consumer should be resumed and the producer should be notified to produce more.
            case resumeConsumerAndReturnProduceMore(
                continuation: CheckedContinuation<Element?, Error>,
                element: Element
            )
            /// Indicates that the consumer should be resumed and the producer should be suspended.
            case resumeConsumerAndReturnEnqueue(
                continuation: CheckedContinuation<Element?, Error>,
                element: Element,
                callbackToken: Source.WriteResult.CallbackToken
            )
            /// Indicates that the producer has been finished.
            case throwFinishedError

            init(
                callbackToken: Source.WriteResult.CallbackToken?,
                continuationAndElement: (CheckedContinuation<Element?, Error>, Element)? = nil
            ) {
                switch (callbackToken, continuationAndElement) {
                case (.none, .none):
                    self = .returnProduceMore

                case (.some(let callbackToken), .none):
                    self = .returnEnqueue(callbackToken: callbackToken)

                case (.none, .some((let continuation, let element))):
                    self = .resumeConsumerAndReturnProduceMore(
                        continuation: continuation,
                        element: element
                    )

                case (.some(let callbackToken), .some((let continuation, let element))):
                    self = .resumeConsumerAndReturnEnqueue(
                        continuation: continuation,
                        element: element,
                        callbackToken: callbackToken
                    )
                }
            }
        }

        mutating func write(_ sequence: some Sequence<Element>) -> WriteAction {
            switch self._state {
            case .initial(var initial):
                var buffer = Deque<Element>()
                buffer.append(contentsOf: sequence)

                let shouldProduceMore = initial.backPressureStrategy.didYield(
                    bufferDepth: buffer.count
                )
                let callbackToken = shouldProduceMore ? nil : self.nextCallbackToken()

                self._state = .streaming(
                    .init(
                        backPressureStrategy: initial.backPressureStrategy,
                        iteratorInitialized: initial.iteratorInitialized,
                        onTermination: initial.onTermination,
                        buffer: buffer,
                        consumerContinuation: nil,
                        producerContinuations: .init(),
                        cancelledAsyncProducers: .init(),
                        hasOutstandingDemand: shouldProduceMore
                    )
                )

                return .init(callbackToken: callbackToken)

            case .streaming(var streaming):
                self._state = .modify

                streaming.buffer.append(contentsOf: sequence)

                // We have an element and can resume the continuation
                let shouldProduceMore = streaming.backPressureStrategy.didYield(
                    bufferDepth: streaming.buffer.count
                )
                streaming.hasOutstandingDemand = shouldProduceMore
                let callbackToken = shouldProduceMore ? nil : self.nextCallbackToken()

                if let consumerContinuation = streaming.consumerContinuation {
                    guard let element = streaming.buffer.popFirst() else {
                        // We got a yield of an empty sequence. We just tolerate this.
                        self._state = .streaming(streaming)

                        return .init(callbackToken: callbackToken)
                    }

                    // We got a consumer continuation and an element. We can resume the consumer now
                    streaming.consumerContinuation = nil
                    self._state = .streaming(streaming)
                    return .init(
                        callbackToken: callbackToken,
                        continuationAndElement: (consumerContinuation, element)
                    )
                } else {
                    // We don't have a suspended consumer so we just buffer the elements
                    self._state = .streaming(streaming)
                    return .init(
                        callbackToken: callbackToken
                    )
                }

            case .sourceFinished, .finished:
                // If the source has finished we are dropping the elements.
                return .throwFinishedError

            case .modify:
                fatalError("AsyncStream internal inconsistency")
            }
        }

        /// Actions returned by `enqueueProducer()`.
        enum EnqueueProducerAction {
            /// Indicates that the producer should be notified to produce more.
            case resumeProducer((Result<Void, Error>) -> Void)
            /// Indicates that the producer should be notified about an error.
            case resumeProducerWithError((Result<Void, Error>) -> Void, Error)
        }

        mutating func enqueueProducer(
            callbackToken: Source.WriteResult.CallbackToken,
            onProduceMore: @Sendable @escaping (Result<Void, Error>) -> Void
        ) -> EnqueueProducerAction? {
            switch self._state {
            case .initial:
                // We need to transition to streaming before we can suspend
                // This is enforced because the CallbackToken has no internal init so
                // one must create it by calling `write` first.
                fatalError("AsyncStream internal inconsistency")

            case .streaming(var streaming):
                if let index = streaming.cancelledAsyncProducers.firstIndex(of: callbackToken.id) {
                    // Our producer got marked as cancelled.
                    self._state = .modify
                    streaming.cancelledAsyncProducers.remove(at: index)
                    self._state = .streaming(streaming)

                    return .resumeProducerWithError(onProduceMore, CancellationError())
                } else if streaming.hasOutstandingDemand {
                    // We hit an edge case here where we wrote but the consuming thread got interleaved
                    return .resumeProducer(onProduceMore)
                } else {
                    self._state = .modify
                    streaming.producerContinuations.append((callbackToken.id, onProduceMore))

                    self._state = .streaming(streaming)
                    return .none
                }

            case .sourceFinished, .finished:
                // Since we are unlocking between yielding and suspending the yield
                // It can happen that the source got finished or the consumption fully finishes.
                return .resumeProducerWithError(onProduceMore, AlreadyFinishedError())

            case .modify:
                fatalError("AsyncStream internal inconsistency")
            }
        }

        /// Actions returned by `cancelProducer()`.
        enum CancelProducerAction {
            /// Indicates that the producer should be notified about cancellation.
            case resumeProducerWithCancellationError((Result<Void, Error>) -> Void)
        }

        mutating func cancelProducer(
            callbackToken: Source.WriteResult.CallbackToken
        ) -> CancelProducerAction? {
            switch self._state {
            case .initial:
                // We need to transition to streaming before we can suspend
                fatalError("AsyncStream internal inconsistency")

            case .streaming(var streaming):
                if let index = streaming.producerContinuations.firstIndex(where: {
                    $0.0 == callbackToken.id
                }) {
                    // We have an enqueued producer that we need to resume now
                    self._state = .modify
                    let continuation = streaming.producerContinuations.remove(at: index).1
                    self._state = .streaming(streaming)

                    return .resumeProducerWithCancellationError(continuation)
                } else {
                    // The task that yields was cancelled before yielding so the cancellation handler
                    // got invoked right away
                    self._state = .modify
                    streaming.cancelledAsyncProducers.append(callbackToken.id)
                    self._state = .streaming(streaming)

                    return .none
                }

            case .sourceFinished, .finished:
                // Since we are unlocking between yielding and suspending the yield
                // It can happen that the source got finished or the consumption fully finishes.
                return .none

            case .modify:
                fatalError("AsyncStream internal inconsistency")
            }
        }

        /// Actions returned by `finish()`.
        enum FinishAction {
            /// Indicates that `onTermination` should be called.
            case callOnTermination((() -> Void)?)
            /// Indicates that the consumer  should be resumed with the failure, the producers
            /// should be resumed with an error and `onTermination` should be called.
            case resumeConsumerAndCallOnTermination(
                consumerContinuation: CheckedContinuation<Element?, Error>,
                failure: Error?,
                onTermination: (() -> Void)?
            )
            /// Indicates that the producers should be resumed with an error.
            case resumeProducers(
                producerContinuations: [(Result<Void, Error>) -> Void]
            )
        }

        @inlinable
        mutating func finish(_ failure: Error?) -> FinishAction? {
            switch self._state {
            case .initial(let initial):
                // Nothing was yielded nor did anybody call next
                // This means we can transition to sourceFinished and store the failure
                self._state = .sourceFinished(
                    .init(
                        iteratorInitialized: initial.iteratorInitialized,
                        buffer: .init(),
                        failure: failure,
                        onTermination: initial.onTermination
                    )
                )

                return .callOnTermination(initial.onTermination)

            case .streaming(let streaming):
                if let consumerContinuation = streaming.consumerContinuation {
                    // We have a continuation, this means our buffer must be empty
                    // Furthermore, we can now transition to finished
                    // and resume the continuation with the failure
                    precondition(streaming.buffer.isEmpty, "Expected an empty buffer")
                    precondition(
                        streaming.producerContinuations.isEmpty,
                        "Expected no suspended producers"
                    )

                    self._state = .finished(iteratorInitialized: streaming.iteratorInitialized)

                    return .resumeConsumerAndCallOnTermination(
                        consumerContinuation: consumerContinuation,
                        failure: failure,
                        onTermination: streaming.onTermination
                    )
                } else {
                    self._state = .sourceFinished(
                        .init(
                            iteratorInitialized: streaming.iteratorInitialized,
                            buffer: streaming.buffer,
                            failure: failure,
                            onTermination: streaming.onTermination
                        )
                    )

                    return .resumeProducers(
                        producerContinuations: Array(streaming.producerContinuations.map { $0.1 })
                    )
                }

            case .sourceFinished, .finished:
                // If the source has finished, finishing again has no effect.
                return .none

            case .modify:
                fatalError("AsyncStream internal inconsistency")
            }
        }

        /// Actions returned by `next()`.
        enum NextAction {
            /// Indicates that the element should be returned to the caller.
            case returnElement(Element)
            /// Indicates that the element should be returned to the caller and that all producers should be called.
            case returnElementAndResumeProducers(Element, [(Result<Void, Error>) -> Void])
            /// Indicates that the `Error` should be returned to the caller and that `onTermination` should be called.
            case returnErrorAndCallOnTermination(Error?, (() -> Void)?)
            /// Indicates that the `nil` should be returned to the caller.
            case returnNil
            /// Indicates that the `Task` of the caller should be suspended.
            case suspendTask
        }

        mutating func next() -> NextAction {
            switch self._state {
            case .initial(let initial):
                // We are not interacting with the back-pressure strategy here because
                // we are doing this inside `next(:)`
                self._state = .streaming(
                    .init(
                        backPressureStrategy: initial.backPressureStrategy,
                        iteratorInitialized: initial.iteratorInitialized,
                        onTermination: initial.onTermination,
                        buffer: Deque<Element>(),
                        consumerContinuation: nil,
                        producerContinuations: .init(),
                        cancelledAsyncProducers: .init(),
                        hasOutstandingDemand: false
                    )
                )

                return .suspendTask
            case .streaming(var streaming):
                guard streaming.consumerContinuation == nil else {
                    // We have multiple AsyncIterators iterating the sequence
                    fatalError("AsyncStream internal inconsistency")
                }

                self._state = .modify

                if let element = streaming.buffer.popFirst() {
                    // We have an element to fulfil the demand right away.
                    let shouldProduceMore = streaming.backPressureStrategy.didConsume(
                        bufferDepth: streaming.buffer.count
                    )
                    streaming.hasOutstandingDemand = shouldProduceMore

                    if shouldProduceMore {
                        // There is demand and we have to resume our producers
                        let producers = Array(streaming.producerContinuations.map { $0.1 })
                        streaming.producerContinuations.removeAll()
                        self._state = .streaming(streaming)
                        return .returnElementAndResumeProducers(element, producers)
                    } else {
                        // We don't have any new demand, so we can just return the element.
                        self._state = .streaming(streaming)
                        return .returnElement(element)
                    }
                } else {
                    // There is nothing in the buffer to fulfil the demand so we need to suspend.
                    // We are not interacting with the back-pressure strategy here because
                    // we are doing this inside `suspendNext`
                    self._state = .streaming(streaming)

                    return .suspendTask
                }

            case .sourceFinished(var sourceFinished):
                // Check if we have an element left in the buffer and return it
                self._state = .modify

                if let element = sourceFinished.buffer.popFirst() {
                    self._state = .sourceFinished(sourceFinished)

                    return .returnElement(element)
                } else {
                    // We are returning the queued failure now and can transition to finished
                    self._state = .finished(iteratorInitialized: sourceFinished.iteratorInitialized)

                    return .returnErrorAndCallOnTermination(
                        sourceFinished.failure,
                        sourceFinished.onTermination
                    )
                }

            case .finished:
                return .returnNil

            case .modify:
                fatalError("AsyncStream internal inconsistency")
            }
        }

        /// Actions returned by `suspendNext()`.
        enum SuspendNextAction {
            /// Indicates that the consumer should be resumed.
            case resumeConsumerWithElement(CheckedContinuation<Element?, Error>, Element)
            /// Indicates that the consumer and all producers should be resumed.
            case resumeConsumerWithElementAndProducers(
                CheckedContinuation<Element?, Error>,
                Element,
                [(Result<Void, Error>) -> Void]
            )
            /// Indicates that the consumer should be resumed with the failure and that `onTermination` should be called.
            case resumeConsumerWithErrorAndCallOnTermination(
                CheckedContinuation<Element?, Error>,
                Error?,
                (() -> Void)?
            )
            /// Indicates that the consumer should be resumed with `nil`.
            case resumeConsumerWithNil(CheckedContinuation<Element?, Error>)
        }

        mutating func suspendNext(
            continuation: CheckedContinuation<Element?, Error>
        ) -> SuspendNextAction? {
            switch self._state {
            case .initial:
                // We need to transition to streaming before we can suspend
                preconditionFailure("AsyncStream internal inconsistency")

            case .streaming(var streaming):
                guard streaming.consumerContinuation == nil else {
                    // We have multiple AsyncIterators iterating the sequence
                    fatalError(
                        "This should never happen since we only allow a single Iterator to be created"
                    )
                }

                self._state = .modify

                // We have to check here again since we might have a producer interleave next and suspendNext
                if let element = streaming.buffer.popFirst() {
                    // We have an element to fulfil the demand right away.

                    let shouldProduceMore = streaming.backPressureStrategy.didConsume(
                        bufferDepth: streaming.buffer.count
                    )
                    streaming.hasOutstandingDemand = shouldProduceMore

                    if shouldProduceMore {
                        // There is demand and we have to resume our producers
                        let producers = Array(streaming.producerContinuations.map { $0.1 })
                        streaming.producerContinuations.removeAll()
                        self._state = .streaming(streaming)
                        return .resumeConsumerWithElementAndProducers(
                            continuation,
                            element,
                            producers
                        )
                    } else {
                        // We don't have any new demand, so we can just return the element.
                        self._state = .streaming(streaming)
                        return .resumeConsumerWithElement(continuation, element)
                    }
                } else {
                    // There is nothing in the buffer to fulfil the demand so we to store the continuation.
                    streaming.consumerContinuation = continuation
                    self._state = .streaming(streaming)

                    return .none
                }

            case .sourceFinished(var sourceFinished):
                // Check if we have an element left in the buffer and return it
                self._state = .modify

                if let element = sourceFinished.buffer.popFirst() {
                    self._state = .sourceFinished(sourceFinished)

                    return .resumeConsumerWithElement(continuation, element)
                } else {
                    // We are returning the queued failure now and can transition to finished
                    self._state = .finished(iteratorInitialized: sourceFinished.iteratorInitialized)

                    return .resumeConsumerWithErrorAndCallOnTermination(
                        continuation,
                        sourceFinished.failure,
                        sourceFinished.onTermination
                    )
                }

            case .finished:
                return .resumeConsumerWithNil(continuation)

            case .modify:
                fatalError("AsyncStream internal inconsistency")
            }
        }

        /// Actions returned by `cancelNext()`.
        enum CancelNextAction {
            /// Indicates that the continuation should be resumed with a cancellation error, the producers should be finished and call onTermination.
            case resumeConsumerWithCancellationErrorAndCallOnTermination(
                CheckedContinuation<Element?, Error>,
                (() -> Void)?
            )
            /// Indicates that the producers should be finished and call onTermination.
            case failProducersAndCallOnTermination([(Result<Void, Error>) -> Void], (() -> Void)?)
        }

        mutating func cancelNext() -> CancelNextAction? {
            switch self._state {
            case .initial:
                // We need to transition to streaming before we can suspend
                fatalError("AsyncStream internal inconsistency")

            case .streaming(let streaming):
                self._state = .finished(iteratorInitialized: streaming.iteratorInitialized)

                if let consumerContinuation = streaming.consumerContinuation {
                    precondition(
                        streaming.producerContinuations.isEmpty,
                        "Internal inconsistency. Unexpected producer continuations."
                    )
                    return .resumeConsumerWithCancellationErrorAndCallOnTermination(
                        consumerContinuation,
                        streaming.onTermination
                    )
                } else {
                    return .failProducersAndCallOnTermination(
                        Array(streaming.producerContinuations.map { $0.1 }),
                        streaming.onTermination
                    )
                }

            case .sourceFinished, .finished:
                return .none

            case .modify:
                fatalError("AsyncStream internal inconsistency")
            }
        }
    }
}
