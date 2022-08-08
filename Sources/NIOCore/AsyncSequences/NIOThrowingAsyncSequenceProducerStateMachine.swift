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

#if compiler(>=5.5.2) && canImport(_Concurrency)

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@usableFromInline
/* private */ internal struct NIOAsyncSequenceProducerStateMachine<
    Element: Sendable,
    Failure: Error,
    Strategy: NIOAsyncSequenceProducerBackPressureStrategy
> {
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

        /// The state once there can be no outstanding demand. This can happen if:
        /// 1. The ``NIOThrowingAsyncSequenceProducer/AsyncIterator`` was deinited
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
             .sourceFinished(_, iteratorInitialized: false, _):
            // No iterator was created so we can transition to finished right away.
            self.state = .finished

            return .callDidTerminate

        case .initial(_, iteratorInitialized: true),
             .streaming(_, _, _, _, iteratorInitialized: true),
             .sourceFinished(_, iteratorInitialized: true, _):
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
             .sourceFinished(_, iteratorInitialized: true, _):
            // Our sequence is a unicast sequence and does not support multiple AsyncIterator's
            fatalError("NIOThrowingAsyncSequenceProducer allows only a single AsyncIterator to be created")

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

        case .sourceFinished(let buffer, false, let failure):
            // The first and only iterator was initialized.
            self.state = .sourceFinished(
                buffer: buffer,
                iteratorInitialized: true,
                failure: failure
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
             .sourceFinished(_, iteratorInitialized: false, _):
            // An iterator needs to be initialized before it can be deinitialized.
            preconditionFailure("Internal inconsistency")

        case .initial(_, iteratorInitialized: true),
             .streaming(_, _, _, _, iteratorInitialized: true),
             .sourceFinished(_, iteratorInitialized: true, _):
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
        /// Indicates that the continuation should be resumed with `nil` and
        /// that ``NIOAsyncSequenceProducerDelegate/didTerminate()`` should be called.
        case resumeContinuationWithFailureAndCallDidTerminate(CheckedContinuation<Element?, Error>, Failure?)
        /// Indicates that nothing should be done.
        case none
    }

    @inlinable
    mutating func finish(_ failure: Failure?) -> FinishAction {
        switch self.state {
        case .initial(_, let iteratorInitialized):
            // Nothing was yielded nor did anybody call next
            // This means we can transition to sourceFinished and store the failure
            self.state = .sourceFinished(
                buffer: .init(),
                iteratorInitialized: iteratorInitialized,
                failure: failure
            )

            return .none

        case .streaming(_, let buffer, .some(let continuation), _, _):
            // We have a continuation, this means our buffer must be empty
            // Furthermore, we can now transition to finished
            // and resume the continuation with the failure
            precondition(buffer.isEmpty, "Expected an empty buffer")

            self.state = .finished

            return .resumeContinuationWithFailureAndCallDidTerminate(continuation, failure)

        case .streaming(_, let buffer, continuation: .none, _, let iteratorInitialized):
            self.state = .sourceFinished(
                buffer: buffer,
                iteratorInitialized: iteratorInitialized,
                failure: failure
            )

            return .none

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
        case resumeContinuationWithNilAndCallDidTerminate(CheckedContinuation<Element?, Error>)
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
        /// Indicates that the `Failure` should be returned to the caller and
        /// that ``NIOAsyncSequenceProducerDelegate/didTerminate()`` should be called.
        case returnFailureAndCallDidTerminate(Failure?)
        /// Indicates that the `nil` should be returned to the caller.
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

        case .sourceFinished(var buffer, let iteratorInitialized, let failure):
            self.state = .modifying

            // Check if we have an element left in the buffer and return it
            if let element = buffer.popFirst() {
                self.state = .sourceFinished(
                    buffer: buffer,
                    iteratorInitialized: iteratorInitialized,
                    failure: failure
                )

                return .returnElement(element)
            } else {
                // We are returning the queued failure now and can transition to finished
                self.state = .finished

                return .returnFailureAndCallDidTerminate(failure)
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
    mutating func next(for continuation: CheckedContinuation<Element?, Error>) -> NextForContinuationAction {
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

#endif
