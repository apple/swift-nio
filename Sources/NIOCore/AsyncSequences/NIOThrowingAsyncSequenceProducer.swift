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

import DequeModule
import NIOConcurrencyHelpers

/// This is an `AsyncSequence` that supports a unicast `AsyncIterator`.
///
/// The goal of this sequence is to produce a stream of elements from the _synchronous_ world
/// (e.g. elements from a ``Channel`` pipeline) and vend it to the _asynchronous_ world for consumption.
/// Furthermore, it provides facilities to implement a back-pressure strategy which
/// observes the number of elements that are yielded and consumed. This allows to signal the source to request more data.
///
/// - Note: It is recommended to never directly expose this type from APIs, but rather wrap it. This is due to the fact that
/// this type has three generic parameters where at least two should be known statically and it is really awkward to spell out this type.
/// Moreover, having a wrapping type allows to optimize this to specialized calls if all generic types are known.
///
/// - Important: This sequence is a unicast sequence that only supports a single ``NIOThrowingAsyncSequenceProducer/AsyncIterator``.
/// If you try to create more than one iterator it will result in a `fatalError`.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct NIOThrowingAsyncSequenceProducer<
    Element: Sendable,
    Failure: Error,
    Strategy: NIOAsyncSequenceProducerBackPressureStrategy,
    Delegate: NIOAsyncSequenceProducerDelegate
>: Sendable {
    /// Simple struct for the return type of ``NIOThrowingAsyncSequenceProducer/makeSequence(elementType:failureType:backPressureStrategy:delegate:)-8qauq``.
    ///
    /// This struct contains two properties:
    /// 1. The ``source`` which should be retained by the producer and is used
    /// to yield new elements to the sequence.
    /// 2. The ``sequence`` which is the actual `AsyncSequence` and
    /// should be passed to the consumer.
    public struct NewSequence {
        /// The source of the ``NIOThrowingAsyncSequenceProducer`` used to yield and finish.
        public let source: Source
        /// The actual sequence which should be passed to the consumer.
        public let sequence: NIOThrowingAsyncSequenceProducer

        @usableFromInline
        /* fileprivate */ internal init(
            source: Source,
            sequence: NIOThrowingAsyncSequenceProducer
        ) {
            self.source = source
            self.sequence = sequence
        }
    }

    /// This class is needed to hook the deinit to observe once all references to the ``NIOThrowingAsyncSequenceProducer`` are dropped.
    ///
    /// If we get move-only types we should be able to drop this class and use the `deinit` of the ``AsyncIterator`` struct itself.
    @usableFromInline
    /* fileprivate */ internal final class InternalClass: Sendable {
        @usableFromInline
        internal let _storage: Storage

        @inlinable
        init(storage: Storage) {
            self._storage = storage
        }

        @inlinable
        deinit {
            _storage.sequenceDeinitialized()
        }
    }

    @usableFromInline
    /* private */ internal let _internalClass: InternalClass

    @usableFromInline
    /* private */ internal var _storage: Storage {
        self._internalClass._storage
    }

    /// Initializes a new ``NIOThrowingAsyncSequenceProducer`` and a ``NIOThrowingAsyncSequenceProducer/Source``.
    ///
    /// - Important: This method returns a struct containing a ``NIOThrowingAsyncSequenceProducer/Source`` and
    /// a ``NIOThrowingAsyncSequenceProducer``. The source MUST be held by the caller and
    /// used to signal new elements or finish. The sequence MUST be passed to the actual consumer and MUST NOT be held by the
    /// caller. This is due to the fact that deiniting the sequence is used as part of a trigger to terminate the underlying source.
    ///
    /// - Parameters:
    ///   - elementType: The element type of the sequence.
    ///   - failureType: The failure type of the sequence.
    ///   - backPressureStrategy: The back-pressure strategy of the sequence.
    ///   - delegate: The delegate of the sequence
    /// - Returns: A ``NIOThrowingAsyncSequenceProducer/Source`` and a ``NIOThrowingAsyncSequenceProducer``.
    @available(*, deprecated, message: "Support for a generic Failure type is deprecated. Failure type must be `any Swift.Error`.")
    @inlinable
    public static func makeSequence(
        elementType: Element.Type = Element.self,
        failureType: Failure.Type = Failure.self,
        backPressureStrategy: Strategy,
        delegate: Delegate
    ) -> NewSequence {
        let sequence = Self(
            backPressureStrategy: backPressureStrategy,
            delegate: delegate
        )
        let source = Source(storage: sequence._storage)

        return .init(source: source, sequence: sequence)
    }
    
    /// Initializes a new ``NIOThrowingAsyncSequenceProducer`` and a ``NIOThrowingAsyncSequenceProducer/Source``.
    ///
    /// - Important: This method returns a struct containing a ``NIOThrowingAsyncSequenceProducer/Source`` and
    /// a ``NIOThrowingAsyncSequenceProducer``. The source MUST be held by the caller and
    /// used to signal new elements or finish. The sequence MUST be passed to the actual consumer and MUST NOT be held by the
    /// caller. This is due to the fact that deiniting the sequence is used as part of a trigger to terminate the underlying source.
    ///
    /// - Parameters:
    ///   - elementType: The element type of the sequence.
    ///   - failureType: The failure type of the sequence. Must be `Swift.Error`
    ///   - backPressureStrategy: The back-pressure strategy of the sequence.
    ///   - delegate: The delegate of the sequence
    /// - Returns: A ``NIOThrowingAsyncSequenceProducer/Source`` and a ``NIOThrowingAsyncSequenceProducer``.
    @inlinable
    public static func makeSequence(
        elementType: Element.Type = Element.self,
        failureType: Failure.Type = Error.self,
        backPressureStrategy: Strategy,
        delegate: Delegate
    ) -> NewSequence where Failure == Error {
        let sequence = Self(
            backPressureStrategy: backPressureStrategy,
            delegate: delegate
        )
        let source = Source(storage: sequence._storage)

        return .init(source: source, sequence: sequence)
    }

    /// only used internally by``NIOAsyncSequenceProducer`` to reuse most of the code
    @inlinable
    internal static func makeNonThrowingSequence(
        elementType: Element.Type = Element.self,
        backPressureStrategy: Strategy,
        delegate: Delegate
    ) -> NewSequence where Failure == Never {
        let sequence = Self(
            backPressureStrategy: backPressureStrategy,
            delegate: delegate
        )
        let source = Source(storage: sequence._storage)

        return .init(source: source, sequence: sequence)
    }

    @inlinable
    /* private */ internal init(
        backPressureStrategy: Strategy,
        delegate: Delegate
    ) {
        let storage = Storage(
            backPressureStrategy: backPressureStrategy,
            delegate: delegate
        )
        self._internalClass = .init(storage: storage)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOThrowingAsyncSequenceProducer: AsyncSequence {
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(storage: self._internalClass._storage)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOThrowingAsyncSequenceProducer {
    public struct AsyncIterator: AsyncIteratorProtocol {
        /// This class is needed to hook the deinit to observe once all references to an instance of the ``AsyncIterator`` are dropped.
        ///
        /// If we get move-only types we should be able to drop this class and use the `deinit` of the ``AsyncIterator`` struct itself.
        @usableFromInline
        /* private */ internal final class InternalClass: Sendable {
            @usableFromInline
            /* private */ internal let _storage: Storage

            fileprivate init(storage: Storage) {
                self._storage = storage
                self._storage.iteratorInitialized()
            }

            @inlinable
            deinit {
                self._storage.iteratorDeinitialized()
            }

            @inlinable
            /* fileprivate */ internal func next() async throws -> Element? {
                try await self._storage.next()
            }
        }

        @usableFromInline
        /* private */ internal let _internalClass: InternalClass

        fileprivate init(storage: Storage) {
            self._internalClass = InternalClass(storage: storage)
        }

        @inlinable
        public func next() async throws -> Element? {
            try await self._internalClass.next()
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOThrowingAsyncSequenceProducer {
    /// A struct to interface between the synchronous code of the producer and the asynchronous consumer.
    /// This type allows the producer to synchronously `yield` new elements to the ``NIOThrowingAsyncSequenceProducer``
    /// and to `finish` the sequence.
    ///
    /// - Note: This struct has reference semantics. Once all copies of a source have been dropped ``NIOThrowingAsyncSequenceProducer/Source/finish()``.
    /// This will resume any suspended continuation.
    public struct Source: Sendable {
        /// This class is needed to hook the deinit to observe once all references to the ``NIOThrowingAsyncSequenceProducer/Source`` are dropped.
        ///
        /// - Important: This is safe to be unchecked ``Sendable`` since the `storage` is ``Sendable`` and `immutable`.
        @usableFromInline
        /* fileprivate */ internal final class InternalClass: Sendable {
            @usableFromInline
            internal let _storage: Storage

            @inlinable
            init(storage: Storage) {
                self._storage = storage
            }

            @inlinable
            deinit {
                // We need to call finish here to resume any suspended continuation.
                self._storage.finish(nil)
            }
        }

        @usableFromInline
        /* private */ internal let _internalClass: InternalClass

        @usableFromInline
        /* private */ internal var _storage: Storage {
            self._internalClass._storage
        }

        @usableFromInline
        /* fileprivate */ internal init(storage: Storage) {
            self._internalClass = .init(storage: storage)
        }

        /// The result of a call to ``NIOThrowingAsyncSequenceProducer/Source/yield(_:)``.
        public enum YieldResult: Hashable {
            /// Indicates that the caller should produce more elements.
            case produceMore
            /// Indicates that the caller should stop producing elements.
            case stopProducing
            /// Indicates that the yielded elements have been dropped because the sequence already terminated.
            case dropped
        }

        /// Yields a sequence of new elements to the ``NIOThrowingAsyncSequenceProducer``.
        ///
        /// If there is an ``NIOThrowingAsyncSequenceProducer/AsyncIterator`` awaiting the next element, it will get resumed right away.
        /// Otherwise, the element will get buffered.
        ///
        /// If the ``NIOThrowingAsyncSequenceProducer`` is terminated this will drop the elements
        /// and return ``YieldResult/dropped``.
        ///
        /// This can be called more than once and returns to the caller immediately
        /// without blocking for any awaiting consumption from the iteration.
        ///
        /// - Parameter contentsOf: The sequence to yield.
        /// - Returns: A ``NIOThrowingAsyncSequenceProducer/Source/YieldResult`` that indicates if the yield was successful
        /// and if more elements should be produced.
        @inlinable
        public func yield<S: Sequence>(contentsOf sequence: S) -> YieldResult where S.Element == Element {
            self._storage.yield(sequence)
        }

        /// Yields a new elements to the ``NIOThrowingAsyncSequenceProducer``.
        ///
        /// If there is an ``NIOThrowingAsyncSequenceProducer/AsyncIterator`` awaiting the next element, it will get resumed right away.
        /// Otherwise, the element will get buffered.
        ///
        /// If the ``NIOThrowingAsyncSequenceProducer`` is terminated this will drop the elements
        /// and return ``YieldResult/dropped``.
        ///
        /// This can be called more than once and returns to the caller immediately
        /// without blocking for any awaiting consumption from the iteration.
        ///
        /// - Parameter element: The element to yield.
        /// - Returns: A ``NIOThrowingAsyncSequenceProducer/Source/YieldResult`` that indicates if the yield was successful
        /// and if more elements should be produced.
        @inlinable
        public func yield(_ element: Element) -> YieldResult {
            self.yield(contentsOf: CollectionOfOne(element))
        }

        /// Finishes the sequence.
        ///
        /// Calling this function signals the sequence that there won't be any subsequent elements yielded.
        ///
        /// If there are still buffered elements and there is an ``NIOThrowingAsyncSequenceProducer/AsyncIterator`` consuming the sequence,
        /// then termination of the sequence only happens once all elements have been consumed by the ``NIOThrowingAsyncSequenceProducer/AsyncIterator``.
        /// Otherwise, the buffered elements will be dropped.
        ///
        /// - Note: Calling this function more than once has no effect.
        @inlinable
        public func finish() {
            self._storage.finish(nil)
        }

        /// Finishes the sequence with the given `Failure`.
        ///
        /// Calling this function signals the sequence that there won't be any subsequent elements yielded.
        ///
        /// If there are still buffered elements and there is an ``NIOThrowingAsyncSequenceProducer/AsyncIterator`` consuming the sequence,
        /// then termination of the sequence only happens once all elements have been consumed by the ``NIOThrowingAsyncSequenceProducer/AsyncIterator``.
        /// Otherwise, the buffered elements will be dropped.
        ///
        /// - Note: Calling this function more than once has no effect.
        /// - Parameter failure: The failure why the sequence finished.
        @inlinable
        public func finish(_ failure: Failure) {
            self._storage.finish(failure)
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOThrowingAsyncSequenceProducer {
    /// This is the underlying storage of the sequence. The goal of this is to synchronize the access to all state.
    @usableFromInline
    /* fileprivate */ internal final class Storage: @unchecked Sendable {
        /// The lock that protects our state.
        @usableFromInline
        /* private */ internal let _lock = NIOLock()
        /// The state machine.
        @usableFromInline
        /* private */ internal var _stateMachine: StateMachine
        /// The delegate.
        @usableFromInline
        /* private */ internal var _delegate: Delegate?

        @usableFromInline
        /* fileprivate */ internal init(
            backPressureStrategy: Strategy,
            delegate: Delegate
        ) {
            self._stateMachine = .init(backPressureStrategy: backPressureStrategy)
            self._delegate = delegate
        }

        @inlinable
        /* fileprivate */ internal func sequenceDeinitialized() {
            let delegate: Delegate? = self._lock.withLock {
                let action = self._stateMachine.sequenceDeinitialized()

                switch action {
                case .callDidTerminate:
                    let delegate = self._delegate
                    self._delegate = nil
                    return delegate

                case .none:
                    return nil
                }
            }

            delegate?.didTerminate()
        }

        @inlinable
        /* fileprivate */ internal func iteratorInitialized() {
            self._lock.withLock {
                self._stateMachine.iteratorInitialized()
            }
        }

        @inlinable
        /* fileprivate */ internal func iteratorDeinitialized() {
            let delegate: Delegate? = self._lock.withLock {
                let action = self._stateMachine.iteratorDeinitialized()

                switch action {
                case .callDidTerminate:
                    let delegate = self._delegate
                    self._delegate = nil

                    return delegate

                case .none:
                    return nil
                }
            }

            delegate?.didTerminate()
        }

        @inlinable
        /* fileprivate */ internal func yield<S: Sequence>(_ sequence: S) -> Source.YieldResult where S.Element == Element {
            self._lock.withLock {
                let action = self._stateMachine.yield(sequence)

                switch action {
                case .returnProduceMore:
                    return .produceMore

                case .returnStopProducing:
                    return .stopProducing

                case .returnDropped:
                    return .dropped

                case .resumeContinuationAndReturnProduceMore(let continuation, let element):
                    // It is safe to resume the continuation while holding the lock
                    // since the task will get enqueued on its executor and the resume method
                    // is returning immediately
                    continuation.resume(returning: element)

                    return .produceMore

                case .resumeContinuationAndReturnStopProducing(let continuation, let element):
                    // It is safe to resume the continuation while holding the lock
                    // since the task will get enqueued on its executor and the resume method
                    // is returning immediately
                    continuation.resume(returning: element)

                    return .stopProducing
                }
            }
        }

        @inlinable
        /* fileprivate */ internal func finish(_ failure: Failure?) {
            let delegate: Delegate? = self._lock.withLock {
                let action = self._stateMachine.finish(failure)

                switch action {
                case .resumeContinuationWithFailureAndCallDidTerminate(let continuation, let failure):
                    let delegate = self._delegate
                    self._delegate = nil

                    // It is safe to resume the continuation while holding the lock
                    // since the task will get enqueued on its executor and the resume method
                    // is returning immediately
                    switch failure {
                    case .some(let error):
                        continuation.resume(throwing: error)
                    case .none:
                        continuation.resume(returning: nil)
                    }

                    return delegate

                case .none:
                    return nil
                }
            }

            delegate?.didTerminate()
        }

        @inlinable
        /* fileprivate */ internal func next() async throws -> Element? {
            try await withTaskCancellationHandler {
                self._lock.lock()

                let action = self._stateMachine.next()

                switch action {
                case .returnElement(let element):
                    self._lock.unlock()
                    return element

                case .returnElementAndCallProduceMore(let element):
                    let delegate = self._delegate
                    self._lock.unlock()

                    delegate?.produceMore()

                    return element

                case .returnFailureAndCallDidTerminate(let failure):
                    let delegate = self._delegate
                    self._delegate = nil
                    self._lock.unlock()

                    delegate?.didTerminate()

                    switch failure {
                    case .some(let error):
                        throw error

                    case .none:
                        return nil
                    }

                case .returnCancellationError:
                    self._lock.unlock()
                    // We have deprecated the generic Failure type in the public API and Failure should
                    // now be `Swift.Error`. However, if users have not migrated to the new API they could
                    // still use a custom generic Error type and this cast might fail.
                    // In addition, we use `NIOThrowingAsyncSequenceProducer` in the implementation of the
                    // non-throwing variant `NIOAsyncSequenceProducer` where `Failure` will be `Never` and
                    // this cast will fail as well.
                    // Everything is marked @inlinable and the Failure type is known at compile time,
                    // therefore this cast should be optimised away in release build.
                    if let error = CancellationError() as? Failure {
                        throw error
                    }
                    return nil

                case .returnNil:
                    self._lock.unlock()
                    return nil

                case .suspendTask:
                    // It is safe to hold the lock across this method
                    // since the closure is guaranteed to be run straight away
                    return try await withCheckedThrowingContinuation { continuation in
                        let action = self._stateMachine.next(for: continuation)

                        switch action {
                        case .callProduceMore:
                            let delegate = _delegate
                            self._lock.unlock()

                            delegate?.produceMore()

                        case .none:
                            self._lock.unlock()
                        }
                    }
                }
            } onCancel: {
                let delegate: Delegate? = self._lock.withLock {
                    let action = self._stateMachine.cancelled()

                    switch action {
                    case .callDidTerminate:
                        let delegate = self._delegate
                        self._delegate = nil

                        return delegate

                    case .resumeContinuationWithCancellationErrorAndCallDidTerminate(let continuation):
                        // We have deprecated the generic Failure type in the public API and Failure should
                        // now be `Swift.Error`. However, if users have not migrated to the new API they could
                        // still use a custom generic Error type and this cast might fail.
                        // In addition, we use `NIOThrowingAsyncSequenceProducer` in the implementation of the
                        // non-throwing variant `NIOAsyncSequenceProducer` where `Failure` will be `Never` and
                        // this cast will fail as well.
                        // Everything is marked @inlinable and the Failure type is known at compile time,
                        // therefore this cast should be optimised away in release build.
                        if let failure = CancellationError() as? Failure {
                            continuation.resume(throwing: failure)
                        } else {
                            continuation.resume(returning: nil)
                        }
                        
                        let delegate = self._delegate
                        self._delegate = nil

                        return delegate

                    case .none:
                        return nil
                    }
                }

                delegate?.didTerminate()
            }
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOThrowingAsyncSequenceProducer {
    @usableFromInline
    /* private */ internal struct StateMachine {
        @usableFromInline
        /* private */ internal enum State {
            /// The initial state before either a call to `yield()` or a call to `next()` happened
            case initial(
                backPressureStrategy: Strategy,
                iteratorInitialized: Bool
            )

            /// The state once either any element was yielded or `next()` was called.
            case streaming(
                backPressureStrategy: Strategy,
                buffer: Deque<Element>,
                continuation: CheckedContinuation<Element?, Error>?,
                hasOutstandingDemand: Bool,
                iteratorInitialized: Bool
            )

            /// The state once the underlying source signalled that it is finished.
            case sourceFinished(
                buffer: Deque<Element>,
                iteratorInitialized: Bool,
                failure: Failure?
            )

            /// The state once a call to next has been cancelled. Cancel the source when entering this state.
            case cancelled(iteratorInitialized: Bool)

            /// The state once there can be no outstanding demand. This can happen if:
            /// 1. The ``NIOThrowingAsyncSequenceProducer/AsyncIterator`` was deinited
            /// 2. The underlying source finished and all buffered elements have been consumed
            case finished(iteratorInitialized: Bool)

            /// Internal state to avoid CoW.
            case modifying
        }

        /// The state machine's current state.
        @usableFromInline
        /* private */ internal var _state: State

        /// Initializes a new `StateMachine`.
        ///
        /// We are passing and holding the back-pressure strategy here because
        /// it is a customizable extension of the state machine.
        ///
        /// - Parameter backPressureStrategy: The back-pressure strategy.
        @inlinable
        init(backPressureStrategy: Strategy) {
            self._state = .initial(
                backPressureStrategy: backPressureStrategy,
                iteratorInitialized: false
            )
        }

        /// Actions returned by `sequenceDeinitialized()`.
        @usableFromInline
        enum SequenceDeinitializedAction {
            /// Indicates that ``NIOAsyncSequenceProducerDelegate/didTerminate()`` should be called.
            case callDidTerminate
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        mutating func sequenceDeinitialized() -> SequenceDeinitializedAction {
            switch self._state {
            case .initial(_, iteratorInitialized: false),
                 .streaming(_, _, _, _, iteratorInitialized: false),
                 .sourceFinished(_, iteratorInitialized: false, _),
                 .cancelled(iteratorInitialized: false):
                // No iterator was created so we can transition to finished right away.
                self._state = .finished(iteratorInitialized: false)

                return .callDidTerminate

            case .initial(_, iteratorInitialized: true),
                 .streaming(_, _, _, _, iteratorInitialized: true),
                 .sourceFinished(_, iteratorInitialized: true, _),
                 .cancelled(iteratorInitialized: true):
                // An iterator was created and we deinited the sequence.
                // This is an expected pattern and we just continue on normal.
                return .none

            case .finished:
                // We are already finished so there is nothing left to clean up.
                // This is just the references dropping afterwards.
                return .none

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        @inlinable
        mutating func iteratorInitialized() {
            switch self._state {
            case .initial(_, iteratorInitialized: true),
                 .streaming(_, _, _, _, iteratorInitialized: true),
                 .sourceFinished(_, iteratorInitialized: true, _),
                 .cancelled(iteratorInitialized: true),
                 .finished(iteratorInitialized: true):
                // Our sequence is a unicast sequence and does not support multiple AsyncIterator's
                fatalError("NIOThrowingAsyncSequenceProducer allows only a single AsyncIterator to be created")

            case .initial(let backPressureStrategy, iteratorInitialized: false):
                // The first and only iterator was initialized.
                self._state = .initial(
                    backPressureStrategy: backPressureStrategy,
                    iteratorInitialized: true
                )

            case .streaming(let backPressureStrategy, let buffer, let continuation, let hasOutstandingDemand, false):
                // The first and only iterator was initialized.
                self._state = .streaming(
                    backPressureStrategy: backPressureStrategy,
                    buffer: buffer,
                    continuation: continuation,
                    hasOutstandingDemand: hasOutstandingDemand,
                    iteratorInitialized: true
                )

            case .cancelled(iteratorInitialized: false):
                // An iterator needs to be initialized before we can be cancelled.
                preconditionFailure("Internal inconsistency")

            case .sourceFinished(let buffer, false, let failure):
                // The first and only iterator was initialized.
                self._state = .sourceFinished(
                    buffer: buffer,
                    iteratorInitialized: true,
                    failure: failure
                )

            case .finished(iteratorInitialized: false):
                // It is strange that an iterator is created after we are finished
                // but it can definitely happen, e.g.
                // Sequence.init -> source.finish -> sequence.makeAsyncIterator
                self._state = .finished(iteratorInitialized: true)

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        /// Actions returned by `iteratorDeinitialized()`.
        @usableFromInline
        enum IteratorDeinitializedAction {
            /// Indicates that ``NIOAsyncSequenceProducerDelegate/didTerminate()`` should be called.
            case callDidTerminate
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        mutating func iteratorDeinitialized() -> IteratorDeinitializedAction {
            switch self._state {
            case .initial(_, iteratorInitialized: false),
                 .streaming(_, _, _, _, iteratorInitialized: false),
                 .sourceFinished(_, iteratorInitialized: false, _),
                 .cancelled(iteratorInitialized: false):
                // An iterator needs to be initialized before it can be deinitialized.
                preconditionFailure("Internal inconsistency")

            case .initial(_, iteratorInitialized: true),
                 .streaming(_, _, _, _, iteratorInitialized: true),
                 .sourceFinished(_, iteratorInitialized: true, _),
                 .cancelled(iteratorInitialized: true):
                // An iterator was created and deinited. Since we only support
                // a single iterator we can now transition to finish and inform the delegate.
                self._state = .finished(iteratorInitialized: true)

                return .callDidTerminate

            case .finished:
                // We are already finished so there is nothing left to clean up.
                // This is just the references dropping afterwards.
                return .none

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        /// Actions returned by `yield()`.
        @usableFromInline
        enum YieldAction {
            /// Indicates that ``NIOThrowingAsyncSequenceProducer/Source/YieldResult/produceMore`` should be returned.
            case returnProduceMore
            /// Indicates that ``NIOThrowingAsyncSequenceProducer/Source/YieldResult/stopProducing`` should be returned.
            case returnStopProducing
            /// Indicates that the continuation should be resumed and
            /// ``NIOThrowingAsyncSequenceProducer/Source/YieldResult/produceMore`` should be returned.
            case resumeContinuationAndReturnProduceMore(
                continuation: CheckedContinuation<Element?, Error>,
                element: Element
            )
            /// Indicates that the continuation should be resumed and
            /// ``NIOThrowingAsyncSequenceProducer/Source/YieldResult/stopProducing`` should be returned.
            case resumeContinuationAndReturnStopProducing(
                continuation: CheckedContinuation<Element?, Error>,
                element: Element
            )
            /// Indicates that the yielded elements have been dropped.
            case returnDropped

            @usableFromInline
            init(shouldProduceMore: Bool, continuationAndElement: (CheckedContinuation<Element?, Error>, Element)? = nil) {
                switch (shouldProduceMore, continuationAndElement) {
                case (true, .none):
                    self = .returnProduceMore

                case (false, .none):
                    self = .returnStopProducing

                case (true, .some((let continuation, let element))):
                    self = .resumeContinuationAndReturnProduceMore(
                        continuation: continuation,
                        element: element
                    )

                case (false, .some((let continuation, let element))):
                    self = .resumeContinuationAndReturnStopProducing(
                        continuation: continuation,
                        element: element
                    )
                }
            }
        }

        @inlinable
        mutating func yield<S: Sequence>(_ sequence: S) -> YieldAction where S.Element == Element {
            switch self._state {
            case .initial(var backPressureStrategy, let iteratorInitialized):
                let buffer = Deque<Element>(sequence)
                let shouldProduceMore = backPressureStrategy.didYield(bufferDepth: buffer.count)

                self._state = .streaming(
                    backPressureStrategy: backPressureStrategy,
                    buffer: buffer,
                    continuation: nil,
                    hasOutstandingDemand: shouldProduceMore,
                    iteratorInitialized: iteratorInitialized
                )

                return .init(shouldProduceMore: shouldProduceMore)

            case .streaming(var backPressureStrategy, var buffer, .some(let continuation), let hasOutstandingDemand, let iteratorInitialized):
                // The buffer should always be empty if we hold a continuation
                precondition(buffer.isEmpty, "Expected an empty buffer")

                self._state = .modifying

                buffer.append(contentsOf: sequence)

                guard let element = buffer.popFirst() else {
                    self._state = .streaming(
                        backPressureStrategy: backPressureStrategy,
                        buffer: buffer,
                        continuation: continuation,
                        hasOutstandingDemand: hasOutstandingDemand,
                        iteratorInitialized: iteratorInitialized
                    )
                    return .init(shouldProduceMore: hasOutstandingDemand)
                }

                // We have an element and can resume the continuation

                let shouldProduceMore = backPressureStrategy.didYield(bufferDepth: buffer.count)
                self._state = .streaming(
                    backPressureStrategy: backPressureStrategy,
                    buffer: buffer,
                    continuation: nil, // Setting this to nil since we are resuming the continuation
                    hasOutstandingDemand: shouldProduceMore,
                    iteratorInitialized: iteratorInitialized
                )

                return .init(shouldProduceMore: shouldProduceMore, continuationAndElement: (continuation, element))

            case .streaming(var backPressureStrategy, var buffer, continuation: .none, _, let iteratorInitialized):
                self._state = .modifying

                buffer.append(contentsOf: sequence)
                let shouldProduceMore = backPressureStrategy.didYield(bufferDepth: buffer.count)

                self._state = .streaming(
                    backPressureStrategy: backPressureStrategy,
                    buffer: buffer,
                    continuation: nil,
                    hasOutstandingDemand: shouldProduceMore,
                    iteratorInitialized: iteratorInitialized
                )

                return .init(shouldProduceMore: shouldProduceMore)

            case .cancelled, .sourceFinished, .finished:
                // If the source has finished we are dropping the elements.
                return .returnDropped

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        /// Actions returned by `finish()`.
        @usableFromInline
        enum FinishAction {
            /// Indicates that the continuation should be resumed with `nil` and
            /// that ``NIOAsyncSequenceProducerDelegate/didTerminate()`` should be called.
            case resumeContinuationWithFailureAndCallDidTerminate(CheckedContinuation<Element?, Error>, Failure?)
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        mutating func finish(_ failure: Failure?) -> FinishAction {
            switch self._state {
            case .initial(_, let iteratorInitialized):
                // Nothing was yielded nor did anybody call next
                // This means we can transition to sourceFinished and store the failure
                self._state = .sourceFinished(
                    buffer: .init(),
                    iteratorInitialized: iteratorInitialized,
                    failure: failure
                )

                return .none

            case .streaming(_, let buffer, .some(let continuation), _, let iteratorInitialized):
                // We have a continuation, this means our buffer must be empty
                // Furthermore, we can now transition to finished
                // and resume the continuation with the failure
                precondition(buffer.isEmpty, "Expected an empty buffer")

                self._state = .finished(iteratorInitialized: iteratorInitialized)

                return .resumeContinuationWithFailureAndCallDidTerminate(continuation, failure)

            case .streaming(_, let buffer, continuation: .none, _, let iteratorInitialized):
                self._state = .sourceFinished(
                    buffer: buffer,
                    iteratorInitialized: iteratorInitialized,
                    failure: failure
                )

                return .none

            case .cancelled, .sourceFinished, .finished:
                // If the source has finished, finishing again has no effect.
                return .none

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        /// Actions returned by `cancelled()`.
        @usableFromInline
        enum CancelledAction {
            /// Indicates that ``NIOAsyncSequenceProducerDelegate/didTerminate()`` should be called.
            case callDidTerminate
            /// Indicates that the continuation should be resumed with a `CancellationError` and
            /// that ``NIOAsyncSequenceProducerDelegate/didTerminate()`` should be called.
            case resumeContinuationWithCancellationErrorAndCallDidTerminate(CheckedContinuation<Element?, Error>)
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        mutating func cancelled() -> CancelledAction {
            switch self._state {
            case .initial(_, let iteratorInitialized):
                // This can happen if the `Task` that calls `next()` is already cancelled.
                
                // We have deprecated the generic Failure type in the public API and Failure should
                // now be `Swift.Error`. However, if users have not migrated to the new API they could
                // still use a custom generic Error type and this cast might fail.
                // In addition, we use `NIOThrowingAsyncSequenceProducer` in the implementation of the
                // non-throwing variant `NIOAsyncSequenceProducer` where `Failure` will be `Never` and
                // this cast will fail as well.
                // Everything is marked @inlinable and the Failure type is known at compile time,
                // therefore this cast should be optimised away in release build.
                if let failure = CancellationError() as? Failure {
                    self._state = .sourceFinished(
                        buffer: .init(),
                        iteratorInitialized: iteratorInitialized,
                        failure: failure
                    )
                } else {
                    self._state = .finished(iteratorInitialized: iteratorInitialized)
                }
                
                return .none

            case .streaming(_, _, .some(let continuation), _, let iteratorInitialized):
                // We have an outstanding continuation that needs to resumed
                // and we can transition to finished here and inform the delegate
                self._state = .finished(iteratorInitialized: iteratorInitialized)

                return .resumeContinuationWithCancellationErrorAndCallDidTerminate(continuation)

            case .streaming(_, _, continuation: .none, _, let iteratorInitialized):
                // We may have elements in the buffer, which is why we have no continuation
                // waiting. We must store the cancellation error to hand it out on the next
                // next() call.
                self._state = .cancelled(iteratorInitialized: iteratorInitialized)

                return .callDidTerminate

            case .cancelled, .sourceFinished, .finished:
                // If the source has finished, finishing again has no effect.
                return .none

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        /// Actions returned by `next()`.
        @usableFromInline
        enum NextAction {
            /// Indicates that the element should be returned to the caller.
            case returnElement(Element)
            /// Indicates that the element should be returned to the caller and
            /// that ``NIOAsyncSequenceProducerDelegate/produceMore()`` should be called.
            case returnElementAndCallProduceMore(Element)
            /// Indicates that the `Failure` should be returned to the caller and
            /// that ``NIOAsyncSequenceProducerDelegate/didTerminate()`` should be called.
            case returnFailureAndCallDidTerminate(Failure?)
            /// Indicates that the next call to AsyncSequence got cancelled
            case returnCancellationError
            /// Indicates that the `nil` should be returned to the caller.
            case returnNil
            /// Indicates that the `Task` of the caller should be suspended.
            case suspendTask
        }

        @inlinable
        mutating func next() -> NextAction {
            switch self._state {
            case .initial(let backPressureStrategy, let iteratorInitialized):
                // We are not interacting with the back-pressure strategy here because
                // we are doing this inside `next(:)`
                self._state = .streaming(
                    backPressureStrategy: backPressureStrategy,
                    buffer: Deque<Element>(),
                    continuation: nil,
                    hasOutstandingDemand: false,
                    iteratorInitialized: iteratorInitialized
                )

                return .suspendTask

            case .streaming(_, _, .some, _, _):
                // We have multiple AsyncIterators iterating the sequence
                preconditionFailure("This should never happen since we only allow a single Iterator to be created")

            case .streaming(var backPressureStrategy, var buffer, .none, let hasOutstandingDemand, let iteratorInitialized):
                self._state = .modifying

                if let element = buffer.popFirst() {
                    // We have an element to fulfil the demand right away.

                    let shouldProduceMore = backPressureStrategy.didConsume(bufferDepth: buffer.count)

                    self._state = .streaming(
                        backPressureStrategy: backPressureStrategy,
                        buffer: buffer,
                        continuation: nil,
                        hasOutstandingDemand: shouldProduceMore,
                        iteratorInitialized: iteratorInitialized
                    )

                    if shouldProduceMore && !hasOutstandingDemand {
                        // We didn't have any demand but now we do, so we need to inform the delegate.
                        return .returnElementAndCallProduceMore(element)
                    } else {
                        // We don't have any new demand, so we can just return the element.
                        return .returnElement(element)
                    }
                } else {
                    // There is nothing in the buffer to fulfil the demand so we need to suspend.
                    // We are not interacting with the back-pressure strategy here because
                    // we are doing this inside `next(:)`
                    self._state = .streaming(
                        backPressureStrategy: backPressureStrategy,
                        buffer: buffer,
                        continuation: nil,
                        hasOutstandingDemand: hasOutstandingDemand,
                        iteratorInitialized: iteratorInitialized
                    )

                    return .suspendTask
                }

            case .sourceFinished(var buffer, let iteratorInitialized, let failure):
                self._state = .modifying

                // Check if we have an element left in the buffer and return it
                if let element = buffer.popFirst() {
                    self._state = .sourceFinished(
                        buffer: buffer,
                        iteratorInitialized: iteratorInitialized,
                        failure: failure
                    )

                    return .returnElement(element)
                } else {
                    // We are returning the queued failure now and can transition to finished
                    self._state = .finished(iteratorInitialized: iteratorInitialized)

                    return .returnFailureAndCallDidTerminate(failure)
                }

            case .cancelled(let iteratorInitialized):
                self._state = .finished(iteratorInitialized: iteratorInitialized)
                return .returnCancellationError

            case .finished:
                return .returnNil

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        /// Actions returned by `next(for:)`.
        @usableFromInline
        enum NextForContinuationAction {
            /// Indicates that ``NIOAsyncSequenceProducerDelegate/produceMore()`` should be called.
            case callProduceMore
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        mutating func next(for continuation: CheckedContinuation<Element?, Error>) -> NextForContinuationAction {
            switch self._state {
            case .initial:
                // We are transitioning away from the initial state in `next()`
                preconditionFailure("Invalid state")

            case .streaming(var backPressureStrategy, let buffer, .none, let hasOutstandingDemand, let iteratorInitialized):
                precondition(buffer.isEmpty, "Expected an empty buffer")

                self._state = .modifying
                let shouldProduceMore = backPressureStrategy.didConsume(bufferDepth: buffer.count)

                self._state = .streaming(
                    backPressureStrategy: backPressureStrategy,
                    buffer: buffer,
                    continuation: continuation,
                    hasOutstandingDemand: shouldProduceMore,
                    iteratorInitialized: iteratorInitialized
                )

                if shouldProduceMore && !hasOutstandingDemand {
                    return .callProduceMore
                } else {
                    return .none
                }

            case .streaming(_, _, .some(_), _, _), .sourceFinished, .finished, .cancelled:
                preconditionFailure("This should have already been handled by `next()`")

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }
    }
}

/// The ``NIOThrowingAsyncSequenceProducer/AsyncIterator`` MUST NOT be shared across `Task`s. With marking this as
/// unavailable we are explicitly declaring this.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@available(*, unavailable)
extension NIOThrowingAsyncSequenceProducer.AsyncIterator: Sendable {}
