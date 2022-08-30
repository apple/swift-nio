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

#if compiler(>=5.5.2) && canImport(_Concurrency)
import Atomics
import NIOConcurrencyHelpers

/// The delegate of the ``NIOAsyncWriter``.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol NIOAsyncWriterDelegate: Sendable {
    /// The `Element` type of the delegate and the writer.
    associatedtype Element: Sendable
    /// The `Failure` type of the delegate and the writer.
    associatedtype Failure: Error = Never

    /// This method is called once a sequence was yielded to the ``NIOAsyncWriter``.
    ///
    /// If the ``NIOAsyncWriter`` was writable when the sequence was yielded, the sequence will be forwarded
    /// right away to the delegate. If the ``NIOAsyncWriter`` was _NOT_ writable then the sequence will be buffered
    /// until the ``NIOAsyncWriter`` becomes writable again.
    func didYield<S: Sequence>(contentsOf sequence: S) where S.Element == Element

    /// This method is called once the ``NIOAsyncWriter`` is terminated.
    ///
    /// Termination happens if:
    /// - The ``NIOAsyncWriter`` is deinited.
    /// - ``NIOAsyncWriter/finish()`` is called.
    /// - ``NIOAsyncWriter/finish(with:)`` is called.
    ///
    /// - Note: This is guaranteed to be called _exactly_ once.
    ///
    /// - Parameter failure: The failure that terminated the ``NIOAsyncWriter``. If the writer was terminated without an
    /// error this value is `nil`.
    func didTerminate(failure: Failure?)
}

/// Errors thrown by the ``NIOAsyncWriter``.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct NIOAsyncWriterError: Error, Hashable {
    @usableFromInline
    internal enum _Code: Hashable, Sendable {
        case alreadyFinished
    }

    @usableFromInline
    let _code: _Code

    @usableFromInline
    var file: String

    @usableFromInline
    var line: Int

    @inlinable
    init(_code: _Code, file: String = #fileID, line: Int = #line) {
        self._code = _code
        self.file = file
        self.line = line
    }

    public static func == (lhs: NIOAsyncWriterError, rhs: NIOAsyncWriterError) -> Bool {
        return lhs._code == rhs._code
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self._code)
    }

    /// Indicates that the ``NIOAsyncWriter`` has already finished and is not accepting any more writes.
    public static let alreadyFinished: Self = .init(_code: .alreadyFinished)
}

/// A ``NIOAsyncWriter`` is a type used to bridge elements from the Swift Concurrency domain into
/// a synchronous world. The `Task`s that are yielding to the ``NIOAsyncWriter`` are the producers.
/// Whereas the ``NIOAsyncWriterDelegate`` is the consumer.
///
/// Additionally, the ``NIOAsyncWriter`` allows the consumer to toggle the writability by calling ``NIOAsyncWriter/Sink/toggleWritability()``.
/// This allows the implementation of flow control on the consumer side. Any call to ``NIOAsyncWriter/yield(contentsOf:)`` or ``NIOAsyncWriter/yield(_:)``
/// will suspend if the ``NIOAsyncWriter`` is not writable and only be resumed after the ``NIOAsyncWriter`` becomes writable again.
///
/// - Note: It is recommended to never directly expose this type from APIs, but rather wrap it. This is due to the fact that
/// this type has three generic parameters where at least two should be known statically and it is really awkward to spell out this type.
/// Moreover, having a wrapping type allows to optimize this to specialized calls if all generic types are known.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct NIOAsyncWriter<
    Element,
    Failure,
    Delegate: NIOAsyncWriterDelegate
>: Sendable where Delegate.Element == Element, Delegate.Failure == Failure {
    /// Simple struct for the return type of ``NIOAsyncWriter/makeWriter(elementType:failureType:isWritable:delegate:)``.
    ///
    /// This struct contains two properties:
    /// 1. The ``sink`` which should be retained by the consumer and is used to toggle the writability.
    /// 2. The ``writer`` which is the actual ``NIOAsyncWriter`` and should be passed to the producer.
    public struct NewWriter {
        /// The ``sink`` which should be retained by the consumer and is used to toggle the writability.
        public let sink: Sink
        /// The ``writer`` which is the actual ``NIOAsyncWriter`` and should be passed to the producer.
        public let writer: NIOAsyncWriter

        @usableFromInline
        /* fileprivate */ internal init(
            sink: Sink,
            writer: NIOAsyncWriter
        ) {
            self.sink = sink
            self.writer = writer
        }
    }

    /// This class is needed to hook the deinit to observe once all references to the ``NIOAsyncWriter`` are dropped.
    ///
    /// If we get move-only types we should be able to drop this class and use the `deinit` of the ``NIOAsyncWriter`` struct itself.
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
            _storage.writerDeinitialized()
        }
    }

    @usableFromInline
    /* private */ internal let _internalClass: InternalClass

    @usableFromInline
    /* private */ internal var _storage: Storage {
        self._internalClass._storage
    }

    /// Initializes a new ``NIOAsyncWriter`` and a ``NIOAsyncWriter/Sink``.
    ///
    /// - Important: This method returns a struct containing a ``NIOAsyncWriter/Sink`` and
    /// a ``NIOAsyncWriter``. The sink MUST be held by the caller and is used to toggle the writability.
    /// The writer MUST be passed to the actual producer and MUST NOT be held by the
    /// caller. This is due to the fact that deiniting the sequence is used as part of a trigger to terminate the underlying sink.
    ///
    /// - Parameters:
    ///   - elementType: The element type of the sequence.
    ///   - failureType: The failure type of the sequence.
    ///   - isWritable: The initial writability state of the writer.
    ///   - delegate: The delegate of the writer.
    /// - Returns: A ``NIOAsyncWriter/NewWriter``.
    public static func makeWriter(
        elementType: Element.Type = Element.self,
        failureType: Failure.Type = Failure.self,
        isWritable: Bool,
        delegate: Delegate
    ) -> NewWriter {
        let writer = Self(
            isWritable: isWritable,
            delegate: delegate
        )
        let sink = Sink(storage: writer._storage)

        return .init(sink: sink, writer: writer)
    }

    private init(
        isWritable: Bool,
        delegate: Delegate
    ) {
        let storage = Storage(
            isWritable: isWritable,
            delegate: delegate
        )
        self._internalClass = .init(storage: storage)
    }

    /// Yields a sequence of new elements to the ``NIOAsyncWriter``.
    ///
    /// If the ``NIOAsyncWriter`` is writable the sequence will get forwarded to the ``NIOAsyncWriterDelegate`` immediately.
    /// Otherwise, the call to ``NIOAsyncWriter/yield(contentsOf:)`` will get suspended until the ``NIOAsyncWriter``
    /// becomes writable again.
    ///
    /// If the ``NIOAsyncWriter`` is finished while a call to ``NIOAsyncWriter/yield(contentsOf:)`` is suspended the
    /// call will throw a ``NIOAsyncWriterError/alreadyFinished`` error.
    ///
    /// This can be called more than once and from multiple `Task`s at the same time.
    ///
    /// - Parameter contentsOf: The sequence to yield.
    @inlinable
    public func yield<S: Sequence>(contentsOf sequence: S) async throws where S.Element == Element {
        try await self._storage.yield(contentsOf: sequence)
    }

    /// Yields an element to the ``NIOAsyncWriter``.
    ///
    /// If the ``NIOAsyncWriter`` is writable the element will get forwarded to the ``NIOAsyncWriterDelegate`` immediately.
    /// Otherwise, the call to ``NIOAsyncWriter/yield(contentsOf:)`` will get suspended until the ``NIOAsyncWriter``
    /// becomes writable again.
    ///
    /// If the ``NIOAsyncWriter`` is finished while a call to ``NIOAsyncWriter/yield(contentsOf:)`` is suspended the
    /// call will throw a ``NIOAsyncWriterError/alreadyFinished`` error.
    ///
    /// This can be called more than once and from multiple `Task`s at the same time.
    ///
    /// - Parameter element: The element to yield.
    @inlinable
    public func yield(_ element: Element) async throws {
        try await self.yield(contentsOf: CollectionOfOne(element))
    }

    /// Finishes the writer.
    ///
    /// Calling this function signals the writer that any suspended or subsequent calls to ``NIOAsyncWriter/yield(contentsOf:)``
    /// or ``NIOAsyncWriter/yield(_:)`` will return a ``NIOAsyncWriterError/alreadyFinished`` error.
    ///
    /// - Note: Calling this function more than once has no effect.
    @inlinable
    public func finish() {
        self._storage.finish(with: nil)
    }

    /// Finishes the writer.
    ///
    /// Calling this function signals the writer that any suspended or subsequent calls to ``NIOAsyncWriter/yield(contentsOf:)``
    /// or ``NIOAsyncWriter/yield(_:)`` will return a ``NIOAsyncWriterError/alreadyFinished`` error.
    ///
    /// - Note: Calling this function more than once has no effect.
    /// - Parameter failure: The failure indicating why the writer finished.
    @inlinable
    public func finish(with failure: Failure) {
        self._storage.finish(with: failure)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncWriter {
    /// The underlying sink of the ``NIOAsyncWriter``. This type allows to toggle the writability of the ``NIOAsyncWriter``.
    public struct Sink {
        @usableFromInline
        /* private */ internal let _storage: Storage

        @inlinable
        init(storage: Storage) {
            self._storage = storage
        }

        /// Sets the writability of the ``NIOAsyncWriter``.
        ///
        /// If the writer becomes writable again all suspended yields will be resumed and the produced elements will be forwarded via
        /// the ``NIOAsyncWriterDelegate/didYield(contentsOf:)`` method. If the writer becomes unwritable all
        /// subsequent calls to ``NIOAsyncWriterDelegate/didYield(contentsOf:)`` will suspend.
        ///
        /// - Parameter writability: The new writability of the ``NIOAsyncWriter``.
        public func setWritability(to writability: Bool) {
            self._storage.setWritability(to: writability)
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncWriter {
    /// This is the underlying storage of the writer. The goal of this is to synchronize the access to all state.
    @usableFromInline
    /* fileprivate */ internal final class Storage: @unchecked Sendable {
        /// The lock that protects our state.
        @usableFromInline
        /* private */ internal let _lock = Lock()
        /// The counter used to assign an ID to all our yields.
        @usableFromInline
        /* private */ internal let _yieldIDCounter = ManagedAtomic<UInt64>(0)
        /// The state machine.
        @usableFromInline
        /* private */ internal var _stateMachine: StateMachine
        /// The delegate.
        @usableFromInline
        /* private */ internal var _delegate: Delegate?

        @usableFromInline
        /* fileprivate */ internal init(
            isWritable: Bool,
            delegate: Delegate
        ) {
            self._stateMachine = .init(isWritable: isWritable)
            self._delegate = delegate
        }

        @inlinable
        /* fileprivate */ internal func writerDeinitialized() {
            let delegate: Delegate? = self._lock.withLock {
                let action = self._stateMachine.writerDeinitialized()

                switch action {
                case .callDidTerminate:
                    let delegate = self._delegate
                    self._delegate = nil

                    return delegate

                case .none:
                    return nil
                }
            }

            delegate?.didTerminate(failure: nil)
        }

        @inlinable
        /* fileprivate */ internal func setWritability(to writability: Bool) {
            // We are manually locking here since we need to use both the delegate and the
            // suspendedYields. Doing this with a withLock becomes very unhandy.
            self._lock.lock()
            let action = self._stateMachine.setWritability(to: writability)

            switch action {
            case .callDidYieldAndResumeContinuations(let suspendedYields):
                let delegate = self._delegate
                self._lock.unlock()

                delegate?.didYield(contentsOf: suspendedYields.lazy.map { $0.elements }.flatMap { $0 })
                suspendedYields.forEach { $0.continuation.resume() }

            case .none:
                self._lock.unlock()
                return
            }
        }

        @inlinable
        /* fileprivate */ internal func yield<S: Sequence>(contentsOf sequence: S) async throws where S.Element == Element {
            // Using relaxed is fine here since we do not need any strict ordering just a
            // unique ID for every yield.
            let yieldID = self._yieldIDCounter.loadThenWrappingIncrement(ordering: .relaxed)

            try await withTaskCancellationHandler {
                // We are manually locking here to hold the lock across the withCheckedContinuation call
                self._lock.lock()

                let action = self._stateMachine.yield(yieldID: yieldID)

                switch action {
                case .callDidYield:
                    let delegate = self._delegate
                    self._lock.unlock()
                    delegate?.didYield(contentsOf: sequence)

                case .throwError(let error):
                    self._lock.unlock()
                    throw error

                case .suspendTask:
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        self._stateMachine.yield(
                            contentsOf: sequence,
                            continuation: continuation,
                            yieldID: yieldID
                        )

                        self._lock.unlock()
                    }
                }
            } onCancel: {
                let action = self._lock.withLock { self._stateMachine.cancel(yieldID: yieldID) }

                switch action {
                case .resumeContinuationWithError(let continuation, let error):
                    continuation.resume(throwing: error)

                case .none:
                    break
                }
            }
        }

        @inlinable
        /* fileprivate */ internal func finish(with failure: Failure?) {
            let delegate: Delegate? = self._lock.withLock {
                let action = self._stateMachine.finish()

                switch action {
                case .callDidTerminate:
                    let delegate = self._delegate
                    self._delegate = nil

                    return delegate

                case .resumeContinuationsWithErrorAndCallDidTerminate(let suspendedYields, let error):
                    let delegate = self._delegate
                    self._delegate = nil
                    // It is safe to resume the continuation while holding the lock
                    // since the task will get enqueued on its executor and the resume method
                    // is returning immediately
                    suspendedYields.forEach { $0.continuation.resume(throwing: error) }

                    return delegate

                case .none:
                    return nil
                }
            }

            delegate?.didTerminate(failure: failure)
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncWriter {
    @usableFromInline
    /* private */ internal struct StateMachine {
        /// This is a small helper struct to encapsulate the three different values for a suspended yield.
        @usableFromInline
        /* private */ internal struct SuspendedYield {
            /// The yield's ID.
            @usableFromInline
            var yieldID: UInt64
            /// The yield's produced sequence of elements.
            @usableFromInline
            var elements: AnySequence<Element>
            /// The yield's continuation.
            @usableFromInline
            var continuation: CheckedContinuation<Void, Error>

            @usableFromInline
            init(yieldID: UInt64, elements: AnySequence<Element>, continuation: CheckedContinuation<Void, Error>) {
                self.yieldID = yieldID
                self.elements = elements
                self.continuation = continuation
            }
        }

        /// The current state of our ``NIOAsyncWriter``.
        @usableFromInline
        /* private */ internal enum State {
            /// The initial state before either a call to ``NIOAsyncWriter/yield(contentsOf:)`` or
            /// ``NIOAsyncWriter/finish(completion:)`` happened.
            case initial(isWritable: Bool)

            /// The state after a call to ``NIOAsyncWriter/yield(contentsOf:)``.
            case streaming(
                isWritable: Bool,
                cancelledYields: [UInt64],
                suspendedYields: [SuspendedYield]
            )

            /// The state once the writer finished. This can happen if:
            /// 1. The ``NIOAsyncWriter`` was deinited
            /// 2. ``NIOAsyncWriter/finish(completion:)`` was called.
            case finished

            /// Internal state to avoid CoW.
            case modifying
        }

        /// The state machine's current state.
        @usableFromInline
        /* private */ internal var _state: State

        init(isWritable: Bool) {
            self._state = .initial(isWritable: isWritable)
        }

        /// Actions returned by `writerDeinitialized()`.
        @usableFromInline
        enum WriterDeinitializedAction {
            /// Indicates that ``NIOAsyncWriterDelegate/didTerminate(completion:)`` should be called.
            case callDidTerminate
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        /* fileprivate */ internal mutating func writerDeinitialized() -> WriterDeinitializedAction {
            switch self._state {
            case .initial:
                // The writer deinited before writing anything.
                // We can transition to finished and inform our delegate
                self._state = .finished

                return .callDidTerminate

            case .streaming(_, _, let suspendedYields):
                // The writer got deinited after we started streaming.
                // This is normal and we need to transition to finished
                // and call the delegate. However, we should not have
                // any suspended yields because they MUST strongly retain
                // the writer.
                precondition(suspendedYields.isEmpty, "We have outstanding suspended yields")

                self._state = .finished

                return .callDidTerminate

            case .finished:
                // We are already finished nothing to do here
                return .none

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        /// Actions returned by `toggleWritability()`.
        @usableFromInline
        enum ToggleWritabilityAction {
            /// Indicates that ``NIOAsyncWriterDelegate/didYield(contentsOf:)`` should be called
            /// and all continuations should be resumed.
            case callDidYieldAndResumeContinuations([SuspendedYield])
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        /* fileprivate */ internal mutating func setWritability(to newWritability: Bool) -> ToggleWritabilityAction {
            switch self._state {
            case .initial:
                // We just need to store the new writability state
                self._state = .initial(isWritable: newWritability)

                return .none

            case .streaming(let isWritable, let cancelledYields, let suspendedYields):
                if isWritable == newWritability {
                    // The writability didn't change so we can just early exit here
                    return .none
                }

                if newWritability {
                    // We became writable again. This means we have to resume all the continuations
                    // and yield the values.

                    // We are taking the whole array of suspended yields and allocate a new empty one.
                    // As a performance optimization we could always keep two arrays and switch between
                    // them but I don't think this is the performance critical part.
                    let yields = suspendedYields

                    self._state = .streaming(
                        isWritable: newWritability,
                        cancelledYields: cancelledYields,
                        suspendedYields: []
                    )
                    return .callDidYieldAndResumeContinuations(yields)
                } else {
                    // We became unwritable nothing really to do here
                    precondition(suspendedYields.isEmpty, "No yield should be suspended at this point")

                    self._state = .streaming(
                        isWritable: newWritability,
                        cancelledYields: cancelledYields,
                        suspendedYields: suspendedYields
                    )
                    return .none
                }

            case .finished:
                // We are already finished nothing to do here
                return .none

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        /// Actions returned by `yield()`.
        @usableFromInline
        enum YieldAction {
            /// Indicates that ``NIOAsyncWriterDelegate/didYield(contentsOf:)`` should be called.
            case callDidYield
            /// Indicates that the calling `Task` should get suspended.
            case suspendTask
            /// Indicates the given error should be thrown.
            case throwError(Error)

            @usableFromInline
            init(isWritable: Bool) {
                if isWritable {
                    self = .callDidYield
                } else {
                    self = .suspendTask
                }
            }
        }

        @inlinable
        /* fileprivate */ internal mutating func yield(
            yieldID: UInt64
        ) -> YieldAction {
            switch self._state {
            case .initial(let isWritable):
                // We can transition to streaming now

                self._state = .streaming(
                    isWritable: isWritable,
                    cancelledYields: [],
                    suspendedYields: []
                )

                return .init(isWritable: isWritable)

            case .streaming(let isWritable, var cancelledYields, let suspendedYields):
                if let index = cancelledYields.firstIndex(of: yieldID) {
                    // We already marked the yield as cancelled. We have to remove it and
                    // throw an error.
                    self._state = .modifying

                    cancelledYields.remove(at: index)

                    self._state = .streaming(
                        isWritable: isWritable,
                        cancelledYields: cancelledYields,
                        suspendedYields: suspendedYields
                    )
                    return .throwError(CancellationError())

                } else {
                    // Yield hasn't been marked as cancelled.
                    // This means we can either call the delegate or suspend
                    return .init(isWritable: isWritable)
                }

            case .finished:
                // We are already finished and still tried to write something
                return .throwError(NIOAsyncWriterError(_code: .alreadyFinished))

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        @inlinable
        /* fileprivate */ internal mutating func yield<S: Sequence>(
            contentsOf sequence: S,
            continuation: CheckedContinuation<Void, Error>,
            yieldID: UInt64
        ) where S.Element == Element {
            switch self._state {
            case .streaming(let isWritable, let cancelledYields, var suspendedYields):
                // We have a suspended yield at this point that hasn't been cancelled yet.
                // We need to store the yield now.

                self._state = .modifying

                let suspendedYield = SuspendedYield(
                    yieldID: yieldID,
                    elements: AnySequence(sequence),
                    continuation: continuation
                )
                suspendedYields.append(suspendedYield)

                self._state = .streaming(
                    isWritable: isWritable,
                    cancelledYields: cancelledYields,
                    suspendedYields: suspendedYields
                )

            case .initial, .finished:
                preconditionFailure("This should have already been handled by `yield()`")

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        /// Actions returned by `cancel()`.
        @usableFromInline
        enum CancelAction {
            case resumeContinuationWithError(CheckedContinuation<Void, Error>, Error)
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        /* fileprivate */ internal mutating func cancel(
            yieldID: UInt64
        ) -> CancelAction {
            switch self._state {
            case .initial(let isWritable):
                // We got a cancel before the yield happened. This means we
                // need to transition to streaming and store our cancelled state.

                self._state = .streaming(
                    isWritable: isWritable,
                    cancelledYields: [yieldID],
                    suspendedYields: []
                )

                return .none

            case .streaming(let isWritable, var cancelledYields, var suspendedYields):
                if let index = suspendedYields.firstIndex(where: { $0.yieldID == yieldID }) {
                    self._state = .modifying
                    // We have a suspended yield for the id. We need to resume the continuation with
                    // an error now.

                    // Removing can be quite expensive if it produces a gap in the array.
                    // Since we are not expected a lot of elements in this array it should be fine
                    // to just remove. If this turns out to be a performance pitfall, we can
                    // swap the elements before removing. So that we always remove the last element.
                    let suspendedYield = suspendedYields.remove(at: index)
                    self._state = .streaming(
                        isWritable: isWritable,
                        cancelledYields: cancelledYields,
                        suspendedYields: suspendedYields
                    )

                    return .resumeContinuationWithError(
                        suspendedYield.continuation,
                        CancellationError()
                    )

                } else {
                    self._state = .modifying
                    // There is no suspended yield. This can mean that we either already yielded
                    // or that the call to `yield` is coming afterwards. We need to store
                    // the ID here. However, if the yield already happened we will never remove the
                    // stored ID. The only way to avoid doing this would be storing every ID
                    cancelledYields.append(yieldID)
                    self._state = .streaming(
                        isWritable: isWritable,
                        cancelledYields: cancelledYields,
                        suspendedYields: suspendedYields
                    )

                    return .none
                }

            case .finished:
                // We are already finished and there is nothing to do
                return .none

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        /// Actions returned by `finish()`.
        @usableFromInline
        enum FinishAction {
            /// Indicates that ``NIOAsyncWriterDelegate/didTerminate(completion:)`` should be called.
            case callDidTerminate
            /// Indicates that ``NIOAsyncWriterDelegate/didTerminate(completion:)`` should be called and all
            /// continuations should be resumed with the given error.
            case resumeContinuationsWithErrorAndCallDidTerminate([SuspendedYield], Error)
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        /* fileprivate */ internal mutating func finish() -> FinishAction {
            switch self._state {
            case .initial:
                // Nothing was ever written so we can transition to finished
                self._state = .finished

                return .callDidTerminate

            case .streaming(_, _, let suspendedYields):
                // We are currently streaming and the writer got finished.
                // We can transition to finished and need to resume all continuations.
                self._state = .finished

                return .resumeContinuationsWithErrorAndCallDidTerminate(
                    suspendedYields,
                    CancellationError()
                )

            case .finished:
                // We are already finished and there is nothing to do
                return .none

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }
    }
}
#endif
