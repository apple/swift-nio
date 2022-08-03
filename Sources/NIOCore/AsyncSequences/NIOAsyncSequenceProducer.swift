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

#if compiler(>=5.5.2) && canImport(_Concurrency)
/// A protocol for the back-pressure strategy of the ``NIOAsyncSequenceProducer``.
///
/// A back-pressure strategy is invoked when new elements are yielded to the sequence or
/// when a ``NIOAsyncSequenceProducer/AsyncIterator`` requested the next value. The responsibility of the strategy is
/// to determine whether more elements need to be produced .
///
/// If more elements need to be produced, either the ``NIOAsyncSequenceProducerDelegate/produceMore()``
/// method will be called or a ``NIOAsyncSequenceProducer/Source/YieldResult`` will be returned that indicates
/// to produce more.
///
/// - Important: The methods of this protocol are guaranteed to be called serially. Furthermore, the implementation of these
/// methods **MUST NOT** do any locking or call out to any other Task/Thread.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol NIOAsyncSequenceProducerBackPressureStrategy: Sendable {
    /// This method is called after new elements were yielded by the producer to the source.
    ///
    /// - Parameter bufferDepth: The current depth of the internal buffer of the sequence. The buffer contains all
    /// the yielded but not yet consumed elements.
    /// - Returns: Returns whether more elements should be produced.
    mutating func didYield(bufferDepth: Int) -> Bool

    /// This method is called after the consumer consumed an element.
    /// More specifically this method is called after `next` was called on an iterator of the ``NIOAsyncSequenceProducer``.
    ///
    /// - Parameter bufferDepth: The current depth of the internal buffer of the sequence. The buffer contains all
    /// the yielded but not yet consumed elements.
    /// - Returns: Returns whether the producer should produce more elements.
    mutating func didConsume(bufferDepth: Int) -> Bool
}

/// The delegate of ``NIOAsyncSequenceProducer``.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol NIOAsyncSequenceProducerDelegate: Sendable {
    /// This method is called once the back-pressure strategy of the ``NIOAsyncSequenceProducer`` determined
    /// that the producer needs to produce more elements.
    ///
    /// - Note: ``NIOAsyncSequenceProducerDelegate/produceMore()`` will never be called after
    /// ``NIOAsyncSequenceProducerDelegate/didTerminate()`` was called.
    ///
    /// - Important: This is only called as a result of the consumer calling ``NIOAsyncSequenceProducer/AsyncIterator/next()``.
    /// It is never called as a result of a producer calling ``NIOAsyncSequenceProducer/Source/yield(_:)``.
    func produceMore()

    /// This method is called once the ``NIOAsyncSequenceProducer`` is terminated.
    ///
    /// Termination happens if:
    /// - The ``NIOAsyncSequenceProducer/AsyncIterator`` is deinited.
    /// - The ``NIOAsyncSequenceProducer`` deinited and no iterator is alive.
    /// - The consuming `Task` is cancelled (e.g. `for await let element in`).
    /// - The source finished and all remaining buffered elements have been consumed.
    func didTerminate()
}

/// This is an ``Swift/AsyncSequence`` that supports a unicast ``Swift/AsyncIterator``.
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
/// - Important: This sequence is a unicast sequence that only supports a single ``NIOAsyncSequenceProducer/AsyncIterator``.
/// If you try to create more than one iterator it will result in a `fatalError`.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct NIOAsyncSequenceProducer<
    Element: Sendable,
    Strategy: NIOAsyncSequenceProducerBackPressureStrategy,
    Delegate: NIOAsyncSequenceProducerDelegate
>: Sendable {
    /// Simple struct for the return type of ``NIOAsyncSequenceProducer/makeSequence(of:backPressureStrategy:delegate:)``.
    ///
    /// This struct contains two properties:
    /// 1. The ``NIOAsyncSequenceProducer/NewSequence/source`` which should be retained by the producer and is used
    /// to yield new elements to the sequence.
    /// 2. The ``NIOAsyncSequenceProducer/NewSequence/sequence`` which is the actual ``Swift/AsyncSequence`` and
    /// should be passed to the consumer.
    public struct NewSequence {
        /// The source of the ``NIOAsyncSequenceProducer`` used to yield and finish.
        public let source: Source
        /// The actual sequence which should be passed to the consumer.
        public let sequence: NIOAsyncSequenceProducer

        @usableFromInline
        /* fileprivate */ internal init(
            source: Source,
            sequence: NIOAsyncSequenceProducer
        ) {
            self.source = source
            self.sequence = sequence
        }
    }

    /// This class is needed to hook the deinit to observe once all references to the ``NIOAsyncSequenceProducer`` are dropped.
    ///
    /// If we get move-only types we should be able to drop this class and use the `deinit` of the ``AsyncIterator`` struct itself.
    ///
    /// - Important: This is safe to be unchecked ``Sendable`` since the `storage` is ``Sendable`` and `immutable`.
    @usableFromInline
    /* fileprivate */ internal final class InternalClass: @unchecked Sendable {
        @usableFromInline
        internal let storage: Storage

        @inlinable
        init(storage: Storage) {
            self.storage = storage
        }

        @inlinable
        deinit {
            storage.sequenceDeinitialized()
        }
    }

    @usableFromInline
    /* private */ internal let internalClass: InternalClass

    @usableFromInline
    /* private */ internal var storage: Storage {
        self.internalClass.storage
    }

    /// Initializes a new ``NIOAsyncSequenceProducer`` and a ``NIOAsyncSequenceProducer/Source``.
    ///
    /// - Important: This method returns a struct containing a ``NIOAsyncSequenceProducer/Source`` and
    /// a ``NIOAsyncSequenceProducer``. The source MUST be held by the caller and
    /// used to signal new elements or finish. The sequence MUST be passed to the actual consumer and MUST NOT be held by the
    /// caller. This is due to the fact that deiniting the sequence is used as part of a trigger to terminate the underlying source.
    ///
    /// - Parameters:
    ///   - element: The element type of the sequence.
    ///   - backPressureStrategy: The back-pressure strategy of the sequence.
    ///   - delegate: The delegate of the sequence
    /// - Returns: A ``NIOAsyncSequenceProducer/Source`` and a ``NIOAsyncSequenceProducer``.
    @inlinable
    public static func makeSequence(
        of elementType: Element.Type = Element.self,
        backPressureStrategy: Strategy,
        delegate: Delegate
    ) -> NewSequence {
        let sequence = Self(
            backPressureStrategy: backPressureStrategy,
            delegate: delegate
        )
        let source = Source(storage: sequence.storage)

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
        self.internalClass = .init(storage: storage)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncSequenceProducer: AsyncSequence {
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(storage: self.internalClass.storage)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncSequenceProducer {
    public struct AsyncIterator: AsyncIteratorProtocol {
        /// This class is needed to hook the deinit to observe once all references to an instance of the ``AsyncIterator`` are dropped.
        ///
        /// If we get move-only types we should be able to drop this class and use the `deinit` of the ``AsyncIterator`` struct itself.
        ///
        /// - Important: This is safe to be unchecked ``Sendable`` since the `storage` is ``Sendable`` and `immutable`.
        @usableFromInline
        /* private */ internal final class InternalClass: @unchecked Sendable {
            @usableFromInline
            /* private */ internal let storage: Storage

            fileprivate init(storage: Storage) {
                self.storage = storage
                self.storage.iteratorInitialized()
            }

            @inlinable
            deinit {
                self.storage.iteratorDeinitialized()
            }

            @inlinable
            /* fileprivate */ internal func next() async -> Element? {
                await self.storage.next()
            }
        }

        @usableFromInline
        /* private */ internal let internalClass: InternalClass

        fileprivate init(storage: Storage) {
            self.internalClass = InternalClass(storage: storage)
        }

        @inlinable
        public func next() async -> Element? {
            await self.internalClass.next()
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncSequenceProducer {
    /// A struct to interface between the synchronous code of the producer and the asynchronous consumer.
    /// This type allows the producer to synchronously `yield` new elements to the ``NIOAsyncSequenceProducer``
    /// and to `finish` the sequence.
    public struct Source {
        @usableFromInline
        /* fileprivate */ internal let storage: Storage

        @usableFromInline
        /* fileprivate */ internal init(storage: Storage) {
            self.storage = storage
        }

        /// The result of a call to ``NIOAsyncSequenceProducer/Source/yield(_:)``.
        public enum YieldResult: Hashable {
            /// Indicates that the caller should produce more elements.
            case produceMore
            /// Indicates that the caller should stop producing elements.
            case stopProducing
            /// Indicates that the yielded elements have been dropped because the sequence already terminated.
            case dropped
        }

        /// Yields a sequence of new elements to the ``NIOAsyncSequenceProducer``.
        ///
        /// If there is an ``NIOAsyncSequenceProducer/AsyncIterator`` awaiting the next element, it will get resumed right away.
        /// Otherwise, the element will get buffered.
        ///
        /// If the ``NIOAsyncSequenceProducer`` is terminated this will drop the elements
        /// and return ``YieldResult/dropped``.
        ///
        /// This can be called more than once and returns to the caller immediately
        /// without blocking for any awaiting consumption from the iteration.
        ///
        /// - Parameter contentsOf: The sequence to yield.
        /// - Returns: A ``NIOAsyncSequenceProducer/Source/YieldResult`` that indicates if the yield was successful
        /// and if more elements should be produced.
        @inlinable
        public func yield<S: Sequence>(contentsOf sequence: S) -> YieldResult where S.Element == Element {
            self.storage.yield(sequence)
        }

        /// Yields a new elements to the ``NIOAsyncSequenceProducer``.
        ///
        /// If there is an ``NIOAsyncSequenceProducer/AsyncIterator`` awaiting the next element, it will get resumed right away.
        /// Otherwise, the element will get buffered.
        ///
        /// If the ``NIOAsyncSequenceProducer`` is terminated this will drop the elements
        /// and return ``YieldResult/dropped``.
        ///
        /// This can be called more than once and returns to the caller immediately
        /// without blocking for any awaiting consumption from the iteration.
        ///
        /// - Parameter element: The element to yield.
        /// - Returns: A ``NIOAsyncSequenceProducer/Source/YieldResult`` that indicates if the yield was successful
        /// and if more elements should be produced.
        @inlinable
        public func yield(_ element: Element) -> YieldResult {
            self.yield(contentsOf: CollectionOfOne(element))
        }

        /// Finishes the sequence.
        ///
        /// Calling this function signals the sequence that there won't be any subsequent elements yielded.
        ///
        /// If there are still buffered elements and there is an ``NIOAsyncSequenceProducer/AsyncIterator`` consuming the sequence,
        /// then termination of the sequence only happens once all elements have been consumed by the ``NIOAsyncSequenceProducer/AsyncIterator``.
        /// Otherwise, the buffered elements will be dropped.
        ///
        /// - Note: Calling this function more than once has no effect.
        @inlinable
        public func finish() {
            self.storage.finish()
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncSequenceProducer {
    /// This is the underlying storage of the sequence. The goal of this is to synchronize the access to all state.
    @usableFromInline
    /* fileprivate */ internal final class Storage: @unchecked Sendable {
        /// The lock that protects our state.
        @usableFromInline
        /* private */ internal let lock = Lock()
        /// The state machine.
        @usableFromInline
        /* private */ internal var stateMachine: StateMachine
        /// The delegate.
        @usableFromInline
        /* private */ internal var delegate: Delegate?

        @usableFromInline
        /* fileprivate */ internal init(
            backPressureStrategy: Strategy,
            delegate: Delegate
        ) {
            self.stateMachine = .init(backPressureStrategy: backPressureStrategy)
            self.delegate = delegate
        }

        @inlinable
        /* fileprivate */ internal func sequenceDeinitialized() {
            let delegate: Delegate? = self.lock.withLock {
                let action = self.stateMachine.sequenceDeinitialized()

                switch action {
                case .callDidTerminate:
                    let delegate = self.delegate
                    self.delegate = nil
                    return delegate

                case .none:
                    return nil
                }
            }

            delegate?.didTerminate()
        }

        @inlinable
        /* fileprivate */ internal func iteratorInitialized() {
            self.lock.withLock {
                self.stateMachine.iteratorInitialized()
            }
        }

        @inlinable
        /* fileprivate */ internal func iteratorDeinitialized() {
            let delegate: Delegate? = self.lock.withLock {
                let action = self.stateMachine.iteratorDeinitialized()

                switch action {
                case .callDidTerminate:
                    let delegate = self.delegate
                    self.delegate = nil

                    return delegate

                case .none:
                    return nil
                }
            }

            delegate?.didTerminate()
        }

        @inlinable
        /* fileprivate */ internal func yield<S: Sequence>(_ sequence: S) -> Source.YieldResult where S.Element == Element {
            self.lock.withLock {
                let action = self.stateMachine.yield(sequence)

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
        /* fileprivate */ internal func finish() {
            let delegate: Delegate? = self.lock.withLock {
                let action = self.stateMachine.finish()

                switch action {
                case .callDidTerminate:
                    let delegate = self.delegate
                    self.delegate = nil

                    return delegate

                case .resumeContinuationWithNilAndCallDidTerminate(let continuation):
                    let delegate = self.delegate
                    self.delegate = nil

                    // It is safe to resume the continuation while holding the lock
                    // since the task will get enqueued on its executor and the resume method
                    // is returning immediately
                    continuation.resume(returning: nil)

                    return delegate

                case .none:
                    return nil
                }
            }

            delegate?.didTerminate()
        }

        @inlinable
        /* fileprivate */ internal func next() async -> Element? {
            await withTaskCancellationHandler {
                self.lock.lock()

                let action = self.stateMachine.next()

                switch action {
                case .returnElement(let element):
                    self.lock.unlock()
                    return element

                case .returnElementAndCallProduceMore(let element):
                    let delegate = self.delegate
                    self.lock.unlock()

                    delegate?.produceMore()

                    return element

                case .returnElementAndCallDidTerminate(let element):
                    let delegate = self.delegate
                    self.delegate = nil
                    self.lock.unlock()

                    delegate?.didTerminate()
                    return element

                case .returnNil:
                    self.lock.unlock()
                    return nil

                case .suspendTask:
                    // It is safe to hold the lock across this method
                    // since the closure is guaranteed to be run straight away
                    return await withCheckedContinuation { continuation in
                        let action = self.stateMachine.next(for: continuation)

                        switch action {
                        case .callProduceMore:
                            let delegate = delegate
                            self.lock.unlock()

                            delegate?.produceMore()

                        case .none:
                            self.lock.unlock()
                        }
                    }
                }
            } onCancel: {
                let delegate: Delegate? = self.lock.withLock {
                    let action = self.stateMachine.cancelled()

                    switch action {
                    case .callDidTerminate:
                        let delegate = self.delegate
                        self.delegate = nil

                        return delegate

                    case .resumeContinuationWithNilAndCallDidTerminate(let continuation):
                        continuation.resume(returning: nil)
                        let delegate = self.delegate
                        self.delegate = nil

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
extension NIOAsyncSequenceProducer {
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
                continuation: CheckedContinuation<Element?, Never>?,
                hasOutstandingDemand: Bool,
                iteratorInitialized: Bool
            )

            /// The state once the underlying source signalled that it is finished.
            case sourceFinished(
                buffer: Deque<Element>,
                iteratorInitialized: Bool
            )

            /// The state once there can be no outstanding demand. This can happen if:
            /// 1. The ``NIOAsyncSequenceProducer/AsyncIterator`` was deinited
            /// 2. The underlying source finished and all buffered elements have been consumed
            case finished

            /// Internal state to avoid CoW.
            case modifying
        }

        /// The state machine's current state.
        @usableFromInline
        /* private */ internal var state: State

        /// Initializes a new `StateMachine`.
        ///
        /// We are passing and holding the back-pressure strategy here because
        /// it is a customizable extension of the state machine.
        ///
        /// - Parameter backPressureStrategy: The back-pressure strategy.
        @inlinable
        init(backPressureStrategy: Strategy) {
            self.state = .initial(
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
            switch self.state {
            case .initial(_, iteratorInitialized: false),
                 .streaming(_, _, _, _, iteratorInitialized: false),
                 .sourceFinished(_, iteratorInitialized: false):
                // No iterator was created so we can transition to finished right away.
                self.state = .finished

                return .callDidTerminate

            case .initial(_, iteratorInitialized: true),
                 .streaming(_, _, _, _, iteratorInitialized: true),
                 .sourceFinished(_, iteratorInitialized: true):
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
            switch self.state {
            case .initial(_, iteratorInitialized: true),
                 .streaming(_, _, _, _, iteratorInitialized: true),
                 .sourceFinished(_, iteratorInitialized: true):
                // Our sequence is a unicast sequence and does not support multiple AsyncIterator's
                fatalError("NIOAsyncSequenceProducer allows only a single AsyncIterator to be created")

            case .initial(let backPressureStrategy, iteratorInitialized: false):
                // The first and only iterator was initialized.
                self.state = .initial(
                    backPressureStrategy: backPressureStrategy,
                    iteratorInitialized: true
                )

            case .streaming(let backPressureStrategy, let buffer, let continuation, let hasOutstandingDemand, false):
                // The first and only iterator was initialized.
                self.state = .streaming(
                    backPressureStrategy: backPressureStrategy,
                    buffer: buffer,
                    continuation: continuation,
                    hasOutstandingDemand: hasOutstandingDemand,
                    iteratorInitialized: true
                )

            case .sourceFinished(let buffer, false):
                // The first and only iterator was initialized.
                self.state = .sourceFinished(
                    buffer: buffer,
                    iteratorInitialized: true
                )

            case .finished:
                // It is strange that an iterator is created after we are finished
                // but it can definitely happen, e.g.
                // Sequence.init -> source.finish -> sequence.makeAsyncIterator
                break

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
            switch self.state {
            case .initial(_, iteratorInitialized: false),
                 .streaming(_, _, _, _, iteratorInitialized: false),
                 .sourceFinished(_, iteratorInitialized: false):
                // An iterator needs to be initialized before it can be deinitialized.
                preconditionFailure("Internal inconsistency")

            case .initial(_, iteratorInitialized: true),
                 .streaming(_, _, _, _, iteratorInitialized: true),
                 .sourceFinished(_, iteratorInitialized: true):
                // An iterator was created and deinited. Since we only support
                // a single iterator we can now transition to finish and inform the delegate.
                self.state = .finished

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
            /// Indicates that ``NIOAsyncSequenceProducer/Source/YieldResult/produceMore`` should be returned.
            case returnProduceMore
            /// Indicates that ``NIOAsyncSequenceProducer/Source/YieldResult/stopProducing`` should be returned.
            case returnStopProducing
            /// Indicates that the continuation should be resumed and
            /// ``NIOAsyncSequenceProducer/Source/YieldResult/produceMore`` should be returned.
            case resumeContinuationAndReturnProduceMore(
                continuation: CheckedContinuation<Element?, Never>,
                element: Element
            )
            /// Indicates that the continuation should be resumed and
            /// ``NIOAsyncSequenceProducer/Source/YieldResult/stopProducing`` should be returned.
            case resumeContinuationAndReturnStopProducing(
                continuation: CheckedContinuation<Element?, Never>,
                element: Element
            )
            /// Indicates that the yielded elements have been dropped.
            case returnDropped

            @usableFromInline
            init(shouldProduceMore: Bool, continuationAndElement: (CheckedContinuation<Element?, Never>, Element)? = nil) {
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
            switch self.state {
            case .initial(var backPressureStrategy, let iteratorInitialized):
                let buffer = Deque<Element>(sequence)
                let shouldProduceMore = backPressureStrategy.didYield(bufferDepth: buffer.count)

                self.state = .streaming(
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

                self.state = .modifying

                buffer.append(contentsOf: sequence)

                guard let element = buffer.popFirst() else {
                    self.state = .streaming(
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
                self.state = .streaming(
                    backPressureStrategy: backPressureStrategy,
                    buffer: buffer,
                    continuation: nil, // Setting this to nil since we are resuming the continuation
                    hasOutstandingDemand: shouldProduceMore,
                    iteratorInitialized: iteratorInitialized
                )

                return .init(shouldProduceMore: shouldProduceMore, continuationAndElement: (continuation, element))

            case .streaming(var backPressureStrategy, var buffer, continuation: .none, _, let iteratorInitialized):
                self.state = .modifying

                buffer.append(contentsOf: sequence)
                let shouldProduceMore = backPressureStrategy.didYield(bufferDepth: buffer.count)

                self.state = .streaming(
                    backPressureStrategy: backPressureStrategy,
                    buffer: buffer,
                    continuation: nil,
                    hasOutstandingDemand: shouldProduceMore,
                    iteratorInitialized: iteratorInitialized
                )

                return .init(shouldProduceMore: shouldProduceMore)

            case .sourceFinished, .finished:
                // If the source has finished we are dropping the elements.
                return .returnDropped

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        /// Actions returned by `finish()`.
        @usableFromInline
        enum FinishAction {
            /// Indicates that ``NIOAsyncSequenceProducerDelegate/didTerminate()`` should be called.
            case callDidTerminate
            /// Indicates that the continuation should be resumed with `nil` and
            /// that ``NIOAsyncSequenceProducerDelegate/didTerminate()`` should be called.
            case resumeContinuationWithNilAndCallDidTerminate(CheckedContinuation<Element?, Never>)
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        mutating func finish() -> FinishAction {
            switch self.state {
            case .initial:
                // Nothing was yielded nor did anybody call next
                // This means we can just transition to finished
                self.state = .finished

                return .callDidTerminate

            case .streaming(_, let buffer, .some(let continuation), _, _):
                // We have a continuation, this means our buffer must be empty
                // Furthermore, we can now transition to finished
                // and resume the continuation with `nil`
                precondition(buffer.isEmpty, "Expected an empty buffer")

                self.state = .finished

                return .resumeContinuationWithNilAndCallDidTerminate(continuation)

            case .streaming(_, let buffer, continuation: .none, _, let iteratorInitialized):
                if buffer.isEmpty {
                    // There is nothing left in the buffer and we can transition to finished
                    self.state = .finished

                    return .callDidTerminate
                } else {
                    // There is some stuff left in the buffer and we have to continue to unbuffer
                    self.state = .sourceFinished(
                        buffer: buffer,
                        iteratorInitialized: iteratorInitialized
                    )

                    return .none
                }

            case .sourceFinished, .finished:
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
            /// Indicates that the continuation should be resumed with `nil` and
            /// that ``NIOAsyncSequenceProducerDelegate/didTerminate()`` should be called.
            case resumeContinuationWithNilAndCallDidTerminate(CheckedContinuation<Element?, Never>)
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        mutating func cancelled() -> CancelledAction {
            switch self.state {
            case .initial:
                // This can happen if the `Task` that calls `next()` is already cancelled.
                self.state = .finished

                return .callDidTerminate

            case .streaming(_, _, .some(let continuation), _, _):
                // We have an outstanding continuation that needs to resumed
                // and we can transition to finished here and inform the delegate
                self.state = .finished

                return .resumeContinuationWithNilAndCallDidTerminate(continuation)

            case .streaming(_, _, continuation: .none, _, _):
                self.state = .finished

                return .callDidTerminate

            case .sourceFinished, .finished:
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
            /// Indicates that the element should be returned to the caller and
            /// that ``NIOAsyncSequenceProducerDelegate/didTerminate()`` should be called.
            case returnElementAndCallDidTerminate(Element)
            /// Indicates that `nil` should be returned to the caller.
            case returnNil
            /// Indicates that the `Task` of the caller should be suspended.
            case suspendTask
        }

        @inlinable
        mutating func next() -> NextAction {
            switch self.state {
            case .initial(let backPressureStrategy, let iteratorInitialized):
                // We are not interacting with the back-pressure strategy here because
                // we are doing this inside `next(:)`
                self.state = .streaming(
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
                self.state = .modifying

                if let element = buffer.popFirst() {
                    // We have an element to fulfil the demand right away.

                    let shouldProduceMore = backPressureStrategy.didConsume(bufferDepth: buffer.count)

                    self.state = .streaming(
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
                    self.state = .streaming(
                        backPressureStrategy: backPressureStrategy,
                        buffer: buffer,
                        continuation: nil,
                        hasOutstandingDemand: hasOutstandingDemand,
                        iteratorInitialized: iteratorInitialized
                    )

                    return .suspendTask
                }

            case .sourceFinished(var buffer, let iteratorInitialized):
                self.state = .modifying

                // Check if we have an element left in the buffer and return it
                if let element = buffer.popFirst() {
                    if buffer.isEmpty {
                        // The buffer is empty now and we can transition to finished
                        self.state = .finished

                        return .returnElementAndCallDidTerminate(element)
                    } else {
                        // There are still elements left and we need to continue to unbuffer
                        self.state = .sourceFinished(
                            buffer: buffer,
                            iteratorInitialized: iteratorInitialized
                        )

                        return .returnElement(element)
                    }
                } else {
                    // We should never be in sourceFinished and have an empty buffer
                    preconditionFailure("Unexpected state")
                }

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
        mutating func next(for continuation: CheckedContinuation<Element?, Never>) -> NextForContinuationAction {
            switch self.state {
            case .initial:
                // We are transitioning away from the initial state in `next()`
                preconditionFailure("Invalid state")

            case .streaming(var backPressureStrategy, let buffer, .none, let hasOutstandingDemand, let iteratorInitialized):
                precondition(buffer.isEmpty, "Expected an empty buffer")

                self.state = .modifying
                let shouldProduceMore = backPressureStrategy.didConsume(bufferDepth: buffer.count)

                self.state = .streaming(
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

            case .streaming(_, _, .some(_), _, _), .sourceFinished, .finished:
                preconditionFailure("This should have already been handled by `next()`")

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }
    }
}

/// The ``NIOAsyncSequenceProducer/AsyncIterator`` MUST NOT be shared across `Task`s. With marking this as
/// unavailable we are explicitly declaring this.
@available(*, unavailable)
extension NIOAsyncSequenceProducer.AsyncIterator: Sendable {}
#endif
