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

import NIOConcurrencyHelpers

#if compiler(>=5.5.2) && canImport(_Concurrency)
/// A protocol for the back-pressure strategy of the ``NIOBackPressuredAsyncSequence``.
///
/// A back-pressure strategy is invoked when new elements are yielded to the sequence or
/// when a ``NIOBackPressuredAsyncSequence/AsyncIterator`` requested the next value. The responsibility of the strategy is
/// to determine whether more elements need to be demanded .
///
/// If more elements need to be requested, either the ``NIOBackPressuredAsyncSequenceSourceDelegate/demand()``
/// method will be called or a ``NIOBackPressuredAsyncSequence/Source/YieldResult`` will be returned that indicates
/// more demand.
///
/// - Important: The methods of this protocol are guaranteed to be called serially. Furthermore, the implementation of these
/// methods **MUST NOT** do any locking or call out to any other Task/Thread.
public protocol NIOBackPressuredAsyncSequenceStrategy {
    /// This method is called after new elements were yielded by the producer to the source.
    ///
    /// - Parameter bufferDepth: The current depth of the internal buffer.
    /// - Returns: Returns whether more elements should be demanded.
    mutating func didYield(bufferDepth: Int) -> Bool

    /// This method is called after the `Subscriber` consumed an element.
    /// More specifically this method is called after `next` was called on an iterator of the ``NIOBackPressuredAsyncSequence``.
    ///
    /// - Parameter bufferDepth: The current depth of the internal buffer.
    /// - Returns: Returns whether new elements should be demanded.
    mutating func didConsume(bufferDepth: Int) -> Bool
}

/// The delegate of ``NIOBackPressuredAsyncSequence``.
public protocol NIOBackPressuredAsyncSequenceDelegate {
    /// This method is called once the back-pressure strategy of the ``NIOBackPressuredAsyncSequence`` determined
    /// that elements from the source need to be demanded and there is no outstanding demand.
    ///
    /// - Important: This is only called as a result of a `Subscriber` is calling ``NIOBackPressuredAsyncSequence/AsyncIterator/next()``.
    /// It is never called as a result of a producer calling ``NIOBackPressuredAsyncSequence/Source/yield(_:)``.
    func demand()

    /// This method is called once the ``NIOBackPressuredAsyncSequence`` is terminated.
    ///
    /// Termination happens if:
    /// - The ``NIOBackPressuredAsyncSequence/AsyncIterator`` is deinited.
    /// - The ``NIOBackPressuredAsyncSequence`` deinited and no iterator is alive.
    /// - The `Subscriber`'s `Task` is cancelled.
    /// - The source finished and all remaining buffered elements have been consumed.
    func didTerminate()
}

/// This is an ``AsyncSequence`` that supports a unicast ``AsyncIterator``.
///
/// The goal of this sequence is to bridge a stream of elements from the _synchronous_ world
/// (e.g. elements from a ``Channel`` pipeline) into the _asynchronous_ world.
/// Furthermore, it provides facilities to implement a back-pressure strategy which
/// observes the number of elements that are yielded and demanded. This allows to signal the source to request more data.
///
/// - Important: This sequence is a unicast sequence that only supports a single ``NIOBackPressuredAsyncSequence/AsyncIterator``.
/// If you try to create more than one iterator it will result in a `fatalError`.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct NIOBackPressuredAsyncSequence<
    Element,
    Strategy: NIOBackPressuredAsyncSequenceStrategy,
    Delegate: NIOBackPressuredAsyncSequenceDelegate
> {
    /// Simple struct for the return type of ``NIOBackPressuredAsyncSequence/makeSourceAndSequence(backPressureStrategy:delegate:)``.
    public struct NewSequence {
        /// The source of the ``NIOBackPressuredAsyncSequence`` used to yield and finish.
        public let source: Source
        /// The actual sequence which should be passed to the consumer.
        public let sequence: NIOBackPressuredAsyncSequence

        @usableFromInline
        /* fileprivate */ internal init(
            source: Source,
            sequence: NIOBackPressuredAsyncSequence
        ) {
            self.source = source
            self.sequence = sequence
        }
    }

    /// This class is needed to hook the deinit to observe once all references to the ``NIOBackPressuredAsyncSequence`` are dropped.
    ///
    /// If we get move-only types we should be able to drop this class and use the `deinit` of the ``AsyncIterator`` struct itself.
    @usableFromInline
    /* fileprivate */ internal final class InternalClass {
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

    /// Initializes a new ``NIOBackPressuredAsyncSequence`` and a ``NIOBackPressuredAsyncSequence/Source``.
    ///
    /// - Important: This method returns a tuple containing a ``NIOBackPressuredAsyncSequence/Source`` and
    /// a ``NIOBackPressuredAsyncSequence``. The source MUST be held by the caller and
    /// used to signal new elements or finish. The sequence MUST be passed to the actual subscriber and MUST NOT be held by the
    /// caller. This is due to the fact that deiniting the sequence is used as part of a trigger to terminate the underlying source.
    ///
    /// - Parameters:
    ///   - backPressureStrategy: The back-pressure strategy of the sequence.
    ///   - delegate: The delegate of the sequence
    /// - Returns: A ``NIOBackPressuredAsyncSequence/Source`` and a ``NIOBackPressuredAsyncSequence``.
    @inlinable
    public static func makeSourceAndSequence(
        backPressureStrategy: Strategy,
        delegate: Delegate
    ) -> NewSequence {
        let sequence = Self(
            backPressureStrategy: backPressureStrategy,
            delegate: delegate
        )
        let source = Source(storage: sequence.internalClass.storage)

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
extension NIOBackPressuredAsyncSequence: AsyncSequence {
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(storage: self.internalClass.storage)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOBackPressuredAsyncSequence {
    public struct AsyncIterator: AsyncIteratorProtocol {
        /// This class is needed to hook the deinit to observe once all references to an instance of the ``AsyncIterator`` are dropped.
        ///
        /// If we get move-only types we should be able to drop this class and use the `deinit` of the ``AsyncIterator`` struct itself.
        @usableFromInline
        /* private */ internal final class InternalClass {
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
extension NIOBackPressuredAsyncSequence {
    /// A struct to interface between the synchronous code of the producer and the asynchronous `Subscriber`.
    /// This type allows the producer to synchronously `yield` new elements to the ``NIOBackPressuredAsyncSequence``
    /// and to `finish` the sequence.
    public struct Source {
        @usableFromInline
        /* fileprivate */ internal let storage: Storage

        @usableFromInline
        /* fileprivate */ internal init(storage: Storage) {
            self.storage = storage
        }

        /// The result of a call to ``NIOBackPressuredAsyncSequence/Source/yield(_:)``.
        public enum YieldResult: Hashable {
            /// Indicates that the caller should produce more elements.
            case produceMore
            /// Indicates that the caller should stop producing elements.
            case stopProducing
            /// Indicates that the yielded elements have been dropped because the sequence already terminated.
            case dropped
        }

        /// Yields a sequence of new elements to the ``NIOBackPressuredAsyncSequence``.
        ///
        /// If there is an ``NIOBackPressuredAsyncSequence/AsyncIterator`` awaiting the next element, it will get resumed right away.
        /// Otherwise, the element will get buffered.
        ///
        /// If the ``NIOBackPressuredAsyncSequence`` is terminated this will drop the elements
        /// and return ``YieldResult/dropped``.
        ///
        /// This can be called more than once and returns to the caller immediately
        /// without blocking for any awaiting consumption from the iteration.
        ///
        /// - Parameter sequence: The sequence to yield.
        /// - Returns: A ``NIOBackPressuredAsyncSequence/Source/YieldResult`` that indicates if the yield was successfull
        /// and if more elements should be demanded.
        @inlinable
        public func yield<S: Sequence>(_ sequence: S) -> YieldResult where S.Element == Element {
            self.storage.yield(sequence)
        }

        /// Yields a new elements to the ``NIOBackPressuredAsyncSequence``.
        ///
        /// If there is an ``NIOBackPressuredAsyncSequence/AsyncIterator`` awaiting the next element, it will get resumed right away.
        /// Otherwise, the element will get buffered.
        ///
        /// If the ``NIOBackPressuredAsyncSequence`` is terminated this will drop the elements
        /// and return ``YieldResult/dropped``.
        ///
        /// This can be called more than once and returns to the caller immediately
        /// without blocking for any awaiting consumption from the iteration.
        ///
        /// - Parameter element: The element to yield.
        /// - Returns: A ``NIOBackPressuredAsyncSequence/Source/YieldResult`` that indicates if the yield was successfull
        /// and if more elements should be demanded.
        @inlinable
        public func yield(_ element: Element) -> YieldResult {
            self.yield(CollectionOfOne(element))
        }

        /// Finishes the sequence.
        ///
        /// Calling this function signals the sequence that there won't be any subsequent elements yielded.
        ///
        /// If there are still buffered elements and there is an ``NIOBackPressuredAsyncSequence/AsyncIterator`` consuming the sequence,
        /// then termination of the sequence only happens once all elements have been consumed by the ``NIOBackPressuredAsyncSequence/AsyncIterator``.
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
extension NIOBackPressuredAsyncSequence {
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
                let action = self.stateMachine.iteratorInitialized()

                switch action {
                case .none:
                    return
                }
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
                case .returnDemandMore:
                    return .produceMore

                case .returnStopDemanding:
                    return .stopProducing

                case .returnDropped:
                    return .dropped

                case .resumeContinuationAndReturnDemandMore(let continuation, let element):
                    // It is safe to resume the continuation while holding the lock
                    // since the task will get enqueued on its executor and the resume method
                    // is returning immediately
                    continuation.resume(returning: element)

                    return .produceMore

                case .resumeContinuationAndReturnStopDemanding(let continuation, let element):
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
            // We are locking manually here since we want to hold the lock
            // across the suspension point.
            await withTaskCancellationHandler {
                self.lock.lock()

                let action = self.stateMachine.next()

                switch action {
                case .returnElement(let element):
                    self.lock.unlock()
                    return element

                case .returnElementAndCallDemand(let element):
                    let delegate = self.delegate
                    self.lock.unlock()

                    delegate?.demand()

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
                        case .callDemand:
                            let delegate = delegate
                            self.lock.unlock()

                            delegate?.demand()

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
extension NIOBackPressuredAsyncSequence {
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
                buffer: CircularBuffer<Element>,
                continuation: CheckedContinuation<Element?, Never>?,
                hasOutstandingDemand: Bool,
                iteratorInitialized: Bool
            )

            /// The sate once the underlying source signalled that it is finished.
            case sourceFinished(
                buffer: CircularBuffer<Element>,
                iteratorInitialized: Bool
            )

            /// The state once there can be no outstanding demand. This can happen if:
            /// 1. The ``NIOBackPressuredAsyncSequence/AsyncIterator`` was deinited
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
            /// Indicates that ``NIOBackPressuredAsyncSequenceDelegate/didTerminate()`` should be called.
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

        /// Actions returned by `iteratorInitialized()`.
        @usableFromInline
        enum IteratorInitializedAction {
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        mutating func iteratorInitialized() -> IteratorInitializedAction {
            switch self.state {
            case .initial(_, iteratorInitialized: true),
                 .streaming(_, _, _, _, iteratorInitialized: true),
                 .sourceFinished(_, iteratorInitialized: true):
                // Our sequence is a unicast sequence and does not support multiple AsyncIterator's
                fatalError("NIOBackPressuredAsyncSequence allows only a single AsyncIterator to be created")

            case .initial(let backPressureStrategy, iteratorInitialized: false):
                // The first and only iterator was initialized.
                self.state = .initial(
                    backPressureStrategy: backPressureStrategy,
                    iteratorInitialized: true
                )

                return .none

            case .streaming(let backPressureStrategy, let buffer, let continuation, let hasOutstandingDemand, false):
                // The first and only iterator was initialized.
                self.state = .streaming(
                    backPressureStrategy: backPressureStrategy,
                    buffer: buffer,
                    continuation: continuation,
                    hasOutstandingDemand: hasOutstandingDemand,
                    iteratorInitialized: true
                )

                return .none

            case .sourceFinished(let buffer, false):
                // The first and only iterator was initialized.
                self.state = .sourceFinished(
                    buffer: buffer,
                    iteratorInitialized: true
                )

                return .none

            case .finished:
                // It is strange that an iterator is created after we are finished
                // but it can definitely happen, e.g.
                // Sequence.init -> source.finish -> sequence.makeAsyncIterator
                return .none

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        /// Actions returned by `iteratorDeinitialized()`.
        @usableFromInline
        enum IteratorDeinitializedAction {
            /// Indicates that ``NIOBackPressuredAsyncSequenceDelegate/didTerminate()`` should be called.
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
            /// Indicates that ``NIOBackPressuredAsyncSequence/Source/YieldResult/demandMore`` should be returned.
            case returnDemandMore
            /// Indicates that ``NIOBackPressuredAsyncSequence/Source/YieldResult/stopDemanding`` should be returned.
            case returnStopDemanding
            /// Indicates that the continuation should be resumed and
            /// ``NIOBackPressuredAsyncSequence/Source/YieldResult/demandMore`` should be returned.
            case resumeContinuationAndReturnDemandMore(
                continuation: CheckedContinuation<Element?, Never>,
                element: Element
            )
            /// Indicates that the continuation should be resumed and
            /// ``NIOBackPressuredAsyncSequence/Source/YieldResult/stopDemanding`` should be returned.
            case resumeContinuationAndReturnStopDemanding(
                continuation: CheckedContinuation<Element?, Never>,
                element: Element
            )
            /// Indicates that the yielded elements have been dropped.
            case returnDropped

            @usableFromInline
            init(shouldDemandMore: Bool, continuationAndElement: (CheckedContinuation<Element?, Never>, Element)? = nil) {
                switch (shouldDemandMore, continuationAndElement) {
                case (true, .none):
                    self = .returnDemandMore

                case (false, .none):
                    self = .returnStopDemanding

                case (true, .some((let continuation, let element))):
                    self = .resumeContinuationAndReturnDemandMore(
                        continuation: continuation,
                        element: element
                    )

                case (false, .some((let continuation, let element))):
                    self = .resumeContinuationAndReturnStopDemanding(
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
                let buffer = CircularBuffer<Element>(sequence)
                let shouldDemandMore = backPressureStrategy.didYield(bufferDepth: buffer.count)

                self.state = .streaming(
                    backPressureStrategy: backPressureStrategy,
                    buffer: buffer,
                    continuation: nil,
                    hasOutstandingDemand: shouldDemandMore,
                    iteratorInitialized: iteratorInitialized
                )

                return .init(shouldDemandMore: shouldDemandMore)

            case .streaming(var backPressureStrategy, var buffer, .some(let continuation), _, let iteratorInitialized):
                // The buffer should always be empty if we hold a continuation
                precondition(buffer.isEmpty)

                self.state = .modifying

                buffer.append(contentsOf: sequence)
                let element = buffer.popFirst()
                let shouldDemandMore = backPressureStrategy.didYield(bufferDepth: buffer.count)

                if let element = element {
                    // We have an element and can resume the continuation
                    self.state = .streaming(
                        backPressureStrategy: backPressureStrategy,
                        buffer: buffer,
                        continuation: nil, // Setting this to nil since we are resuming the continuation
                        hasOutstandingDemand: shouldDemandMore,
                        iteratorInitialized: iteratorInitialized
                    )

                    return .init(shouldDemandMore: shouldDemandMore, continuationAndElement: (continuation, element))
                } else {
                    self.state = .streaming(
                        backPressureStrategy: backPressureStrategy,
                        buffer: buffer,
                        continuation: continuation,
                        hasOutstandingDemand: shouldDemandMore,
                        iteratorInitialized: iteratorInitialized
                    )

                    // This is weird somebody yielded an empty sequence but we can handle it
                    return .init(shouldDemandMore: shouldDemandMore)
                }

            case .streaming(var backPressureStrategy, var buffer, continuation: .none, _, let iteratorInitialized):
                self.state = .modifying

                buffer.append(contentsOf: sequence)
                let shouldDemandMore = backPressureStrategy.didYield(bufferDepth: buffer.count)

                self.state = .streaming(
                    backPressureStrategy: backPressureStrategy,
                    buffer: buffer,
                    continuation: nil,
                    hasOutstandingDemand: shouldDemandMore,
                    iteratorInitialized: iteratorInitialized
                )

                return .init(shouldDemandMore: shouldDemandMore)

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
            /// Indicates that ``NIOBackPressuredAsyncSequenceDelegate/didTerminate()`` should be called.
            case callDidTerminate
            /// Indicates that the continuation should be resumed with `nil` and
            /// that ``NIOBackPressuredAsyncSequenceDelegate/didTerminate()`` should be called.
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
                precondition(buffer.isEmpty)

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
            /// Indicates that ``NIOBackPressuredAsyncSequenceDelegate/didTerminate()`` should be called.
            case callDidTerminate
            /// Indicates that the continuation should be resumed with `nil` and
            /// that ``NIOBackPressuredAsyncSequenceDelegate/didTerminate()`` should be called.
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
            /// that ``NIOBackPressuredAsyncSequenceDelegate/demand()`` should be called.
            case returnElementAndCallDemand(Element)
            /// Indicates that the element should be returned to the caller and
            /// that ``NIOBackPressuredAsyncSequenceDelegate/didTerminate()`` should be called.
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
                    buffer: CircularBuffer<Element>(),
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

                    let shouldDemand = backPressureStrategy.didConsume(bufferDepth: buffer.count)

                    self.state = .streaming(
                        backPressureStrategy: backPressureStrategy,
                        buffer: buffer,
                        continuation: nil,
                        hasOutstandingDemand: shouldDemand,
                        iteratorInitialized: iteratorInitialized
                    )

                    if shouldDemand && !hasOutstandingDemand {
                        // We didn't have any demand but now we do, so we need to inform the delegate.
                        return .returnElementAndCallDemand(element)
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
            /// Indicates that ``NIOBackPressuredAsyncSequenceDelegate/demand()`` should be called.
            case callDemand
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
                precondition(buffer.isEmpty)

                self.state = .modifying
                let shouldDemand = backPressureStrategy.didConsume(bufferDepth: buffer.count)

                self.state = .streaming(
                    backPressureStrategy: backPressureStrategy,
                    buffer: buffer,
                    continuation: continuation,
                    hasOutstandingDemand: shouldDemand,
                    iteratorInitialized: iteratorInitialized
                )

                if shouldDemand && !hasOutstandingDemand {
                    return .callDemand
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
#endif
