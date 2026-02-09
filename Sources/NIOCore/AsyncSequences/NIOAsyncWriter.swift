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

import Atomics
import DequeModule
import NIOConcurrencyHelpers
import _NIODataStructures

@usableFromInline
let _asyncWriterYieldIDCounter = ManagedAtomic<UInt64>(0)

/// The delegate of the ``NIOAsyncWriter``. It is the consumer of the yielded writes to the ``NIOAsyncWriter``.
/// Furthermore, the delegate gets informed when the ``NIOAsyncWriter`` terminated.
///
/// - Important: The methods on the delegate might be called on arbitrary threads and the implementation must ensure
/// that proper synchronization is in place.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol NIOAsyncWriterSinkDelegate: Sendable {
    /// The `Element` type of the delegate and the writer.
    associatedtype Element: Sendable

    /// This method is called once a sequence was yielded to the ``NIOAsyncWriter``.
    ///
    /// If the ``NIOAsyncWriter`` was writable when the sequence was yielded, the sequence will be forwarded
    /// right away to the delegate. If the ``NIOAsyncWriter`` was _NOT_ writable then the sequence will be buffered
    /// until the ``NIOAsyncWriter`` becomes writable again.
    ///
    /// The delegate might reentrantly call ``NIOAsyncWriter/Sink/setWritability(to:)`` while still processing writes.
    func didYield(contentsOf sequence: Deque<Element>)

    /// This method is called once a single element was yielded to the ``NIOAsyncWriter``.
    ///
    /// If the ``NIOAsyncWriter`` was writable when the sequence was yielded, the sequence will be forwarded
    /// right away to the delegate. If the ``NIOAsyncWriter`` was _NOT_ writable then the sequence will be buffered
    /// until the ``NIOAsyncWriter`` becomes writable again.
    ///
    /// - Note: This a fast path that you can optionally implement. By default this will just call ``NIOAsyncWriterSinkDelegate/didYield(contentsOf:)``.
    ///
    /// The delegate might reentrantly call ``NIOAsyncWriter/Sink/setWritability(to:)`` while still processing writes.
    func didYield(_ element: Element)

    /// This method is called once the ``NIOAsyncWriter`` is terminated.
    ///
    /// Termination happens if:
    /// - The ``NIOAsyncWriter`` is deinited and all yielded elements have been delivered to the delegate.
    /// - ``NIOAsyncWriter/finish()`` is called and all yielded elements have been delivered to the delegate.
    /// - ``NIOAsyncWriter/finish(error:)`` is called and all yielded elements have been delivered to the delegate.
    ///
    /// - Note: This is guaranteed to be called _at most_ once.
    ///
    /// - Parameter error: The error that terminated the ``NIOAsyncWriter``. If the writer was terminated without an
    /// error this value is `nil`. This can be either the error passed to ``NIOAsyncWriter/finish(error:)``.
    func didTerminate(error: Error?)
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncWriterSinkDelegate {
    @inlinable
    public func didYield(_ element: Element) {
        self.didYield(contentsOf: .init(CollectionOfOne(element)))
    }
}

/// Errors thrown by the ``NIOAsyncWriter``.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct NIOAsyncWriterError: Error, Hashable, CustomStringConvertible {
    @usableFromInline
    internal enum _Code: String, Hashable, Sendable {
        case alreadyFinished
    }

    @usableFromInline
    let _code: _Code

    public var file: String

    public var line: Int

    @inlinable
    init(_code: _Code, file: String, line: Int) {
        self._code = _code
        self.file = file
        self.line = line
    }

    @inlinable
    public static func == (lhs: NIOAsyncWriterError, rhs: NIOAsyncWriterError) -> Bool {
        lhs._code == rhs._code
    }

    @inlinable
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self._code)
    }

    /// Indicates that the ``NIOAsyncWriter`` has already finished and is not accepting any more writes.
    @inlinable
    public static func alreadyFinished(file: String = #fileID, line: Int = #line) -> Self {
        .init(_code: .alreadyFinished, file: file, line: line)
    }

    @inlinable
    public var description: String {
        "NIOAsyncWriterError.\(self._code.rawValue): \(self.file):\(self.line)"
    }
}

/// A ``NIOAsyncWriter`` is a type used to bridge elements from the Swift Concurrency domain into
/// a synchronous world. The `Task`s that are yielding to the ``NIOAsyncWriter`` are the producers.
/// Whereas the ``NIOAsyncWriterSinkDelegate`` is the consumer.
///
/// Additionally, the ``NIOAsyncWriter`` allows the consumer to set the writability by calling ``NIOAsyncWriter/Sink/setWritability(to:)``.
/// This allows the implementation of flow control on the consumer side. Any call to ``NIOAsyncWriter/yield(contentsOf:)`` or ``NIOAsyncWriter/yield(_:)``
/// will suspend if the ``NIOAsyncWriter`` is not writable and will be resumed after the ``NIOAsyncWriter`` becomes writable again
/// or if the ``NIOAsyncWriter`` has finished.
///
/// - Note: It is recommended to never directly expose this type from APIs, but rather wrap it. This is due to the fact that
/// this type has two generic parameters where at least the `Delegate` should be known statically and it is really awkward to spell out this type.
/// Moreover, having a wrapping type allows to optimize this to specialized calls if all generic types are known.
///
/// - Note: This struct has reference semantics. Once all copies of a writer have been dropped ``NIOAsyncWriterSinkDelegate/didTerminate(error:)`` will be called.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct NIOAsyncWriter<
    Element,
    Delegate: NIOAsyncWriterSinkDelegate
>: Sendable where Delegate.Element == Element {
    /// Simple struct for the return type of ``NIOAsyncWriter/makeWriter(elementType:isWritable:delegate:)``.
    ///
    /// This struct contains two properties:
    /// 1. The ``sink`` which should be retained by the consumer and is used to set the writability.
    /// 2. The ``writer`` which is the actual ``NIOAsyncWriter`` and should be passed to the producer.
    public struct NewWriter: Sendable {
        /// The ``sink`` which **MUST** be retained by the consumer and is used to set the writability.
        public let sink: Sink
        /// The ``writer`` which is the actual ``NIOAsyncWriter`` and should be passed to the producer.
        public let writer: NIOAsyncWriter

        @inlinable
        internal init(
            sink: Sink,
            writer: NIOAsyncWriter
        ) {
            self.sink = sink
            self.writer = writer
        }
    }

    /// This class is needed to hook the deinit to observe once all references to the ``NIOAsyncWriter`` are dropped.
    @usableFromInline
    internal final class InternalClass: Sendable {
        @usableFromInline
        internal let _storage: Storage

        @usableFromInline
        internal let _finishOnDeinit: Bool

        @inlinable
        init(storage: Storage, finishOnDeinit: Bool) {
            self._storage = storage
            self._finishOnDeinit = finishOnDeinit
        }

        @inlinable
        deinit {
            if !self._finishOnDeinit && !self._storage.isWriterFinished {
                preconditionFailure("Deinited NIOAsyncWriter without calling finish()")
            } else {
                // We need to call finish here to resume any suspended continuation.
                self._storage.writerFinish(error: nil)
            }
        }
    }

    @usableFromInline
    internal let _internalClass: InternalClass

    @inlinable
    internal var _storage: Storage {
        self._internalClass._storage
    }

    /// Initializes a new ``NIOAsyncWriter`` and a ``NIOAsyncWriter/Sink``.
    ///
    /// - Important: This method returns a struct containing a ``NIOAsyncWriter/Sink`` and
    /// a ``NIOAsyncWriter``. The sink MUST be held by the caller and is used to set the writability.
    /// The writer MUST be passed to the actual producer and MUST NOT be held by the
    /// caller. This is due to the fact that deiniting the sequence is used as part of a trigger to terminate the underlying sink.
    ///
    /// - Parameters:
    ///   - elementType: The element type of the sequence.
    ///   - isWritable: The initial writability state of the writer.
    ///   - delegate: The delegate of the writer.
    /// - Returns: A ``NIOAsyncWriter/NewWriter``.
    @inlinable
    @available(
        *,
        deprecated,
        renamed: "makeWriter(elementType:isWritable:finishOnDeinit:delegate:)",
        message: "This method has been deprecated since it defaults to deinit based resource teardown"
    )
    public static func makeWriter(
        elementType: Element.Type = Element.self,
        isWritable: Bool,
        delegate: Delegate
    ) -> NewWriter {
        let writer = Self(
            isWritable: isWritable,
            finishOnDeinit: true,
            delegate: delegate
        )
        let sink = Sink(storage: writer._storage, finishOnDeinit: true)

        return .init(sink: sink, writer: writer)
    }

    /// Initializes a new ``NIOAsyncWriter`` and a ``NIOAsyncWriter/Sink``.
    ///
    /// - Important: This method returns a struct containing a ``NIOAsyncWriter/Sink`` and
    /// a ``NIOAsyncWriter``. The sink MUST be held by the caller and is used to set the writability.
    /// The writer MUST be passed to the actual producer and MUST NOT be held by the
    /// caller. This is due to the fact that deiniting the sequence is used as part of a trigger to terminate the underlying sink.
    ///
    /// - Parameters:
    ///   - elementType: The element type of the sequence.
    ///   - isWritable: The initial writability state of the writer.
    ///   - finishOnDeinit: Indicates if ``NIOAsyncWriter/finish()`` should be called on deinit. We do not recommend to rely on
    ///   deinit based resource tear down.
    ///   - delegate: The delegate of the writer.
    /// - Returns: A ``NIOAsyncWriter/NewWriter``.
    @inlinable
    public static func makeWriter(
        elementType: Element.Type = Element.self,
        isWritable: Bool,
        finishOnDeinit: Bool,
        delegate: Delegate
    ) -> NewWriter {
        let writer = Self(
            isWritable: isWritable,
            finishOnDeinit: finishOnDeinit,
            delegate: delegate
        )
        let sink = Sink(storage: writer._storage, finishOnDeinit: finishOnDeinit)

        return .init(sink: sink, writer: writer)
    }

    @inlinable
    internal init(
        isWritable: Bool,
        finishOnDeinit: Bool,
        delegate: Delegate
    ) {
        let storage = Storage(
            isWritable: isWritable,
            delegate: delegate
        )
        self._internalClass = .init(storage: storage, finishOnDeinit: finishOnDeinit)
    }

    /// Yields a sequence of new elements to the ``NIOAsyncWriter``.
    ///
    /// If the ``NIOAsyncWriter`` is writable the sequence will get forwarded to the ``NIOAsyncWriterSinkDelegate`` immediately.
    /// Otherwise, the sequence will be buffered and the call to ``NIOAsyncWriter/yield(contentsOf:)`` will get suspended until the ``NIOAsyncWriter``
    /// becomes writable again.
    ///
    /// If the calling `Task` gets cancelled at any point the call to ``NIOAsyncWriter/yield(contentsOf:)``
    /// will be resumed. Consequently, the provided elements will not be yielded.
    ///
    /// This can be called more than once and from multiple `Task`s at the same time.
    ///
    /// - Parameter sequence: The sequence to yield.
    @inlinable
    public func yield<S: Sequence>(contentsOf sequence: S) async throws where S.Element == Element {
        try await self._storage.yield(contentsOf: sequence)
    }

    /// Yields an element to the ``NIOAsyncWriter``.
    ///
    /// If the ``NIOAsyncWriter`` is writable the element will get forwarded to the ``NIOAsyncWriterSinkDelegate`` immediately.
    /// Otherwise, the element will be buffered and the call to ``NIOAsyncWriter/yield(_:)`` will get suspended until the ``NIOAsyncWriter``
    /// becomes writable again.
    ///
    /// If the calling `Task` gets cancelled at any point the call to ``NIOAsyncWriter/yield(_:)``
    /// will be resumed. Consequently, the provided element will not be yielded.
    ///
    /// This can be called more than once and from multiple `Task`s at the same time.
    ///
    /// - Parameter element: The element to yield.
    @inlinable
    public func yield(_ element: Element) async throws {
        try await self._storage.yield(element: element)
    }

    /// Finishes the writer.
    ///
    /// Calling this function signals the writer that any suspended calls to ``NIOAsyncWriter/yield(contentsOf:)``
    /// or ``NIOAsyncWriter/yield(_:)`` will be resumed. Any subsequent calls to ``NIOAsyncWriter/yield(contentsOf:)``
    /// or ``NIOAsyncWriter/yield(_:)`` will throw.
    ///
    /// Any element that have been yielded before the writer has been finished which have not been delivered yet are continued
    /// to be buffered and will be delivered once the writer becomes writable again.
    ///
    /// - Note: Calling this function more than once has no effect.
    @inlinable
    public func finish() {
        self._storage.writerFinish(error: nil)
    }

    /// Finishes the writer.
    ///
    /// Calling this function signals the writer that any suspended calls to ``NIOAsyncWriter/yield(contentsOf:)``
    /// or ``NIOAsyncWriter/yield(_:)`` will be resumed. Any subsequent calls to ``NIOAsyncWriter/yield(contentsOf:)``
    /// or ``NIOAsyncWriter/yield(_:)`` will throw.
    ///
    /// Any element that have been yielded before the writer has been finished which have not been delivered yet are continued
    /// to be buffered and will be delivered once the writer becomes writable again.
    ///
    /// - Note: Calling this function more than once has no effect.
    /// - Parameter error: The error indicating why the writer finished.
    @inlinable
    public func finish(error: Error) {
        self._storage.writerFinish(error: error)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncWriter {
    /// The underlying sink of the ``NIOAsyncWriter``. This type allows to set the writability of the ``NIOAsyncWriter``.
    ///
    /// - Important: Once all copies to the ``NIOAsyncWriter/Sink`` are destroyed the ``NIOAsyncWriter`` will get finished.
    public struct Sink: Sendable {
        /// This class is needed to hook the deinit to observe once all references to the ``NIOAsyncWriter/Sink`` are dropped.
        @usableFromInline
        internal final class InternalClass: Sendable {
            @usableFromInline
            internal let _storage: Storage

            @usableFromInline
            internal let _finishOnDeinit: Bool

            @inlinable
            init(storage: Storage, finishOnDeinit: Bool) {
                self._storage = storage
                self._finishOnDeinit = finishOnDeinit
            }

            @inlinable
            deinit {
                if !self._finishOnDeinit && !self._storage.isSinkFinished {
                    preconditionFailure("Deinited NIOAsyncWriter.Sink without calling sink.finish()")
                } else {
                    // We need to call finish here to resume any suspended continuation.
                    self._storage.sinkFinish(error: nil)
                }
            }
        }

        @usableFromInline
        internal let _internalClass: InternalClass

        @inlinable
        internal var _storage: Storage {
            self._internalClass._storage
        }

        @inlinable
        init(storage: Storage, finishOnDeinit: Bool) {
            self._internalClass = .init(storage: storage, finishOnDeinit: finishOnDeinit)
        }

        /// Sets the writability of the ``NIOAsyncWriter``.
        ///
        /// If the writer becomes writable again all suspended yields will be resumed and the produced elements will be forwarded via
        /// the ``NIOAsyncWriterSinkDelegate/didYield(contentsOf:)`` method. If the writer becomes unwritable all
        /// subsequent calls to ``NIOAsyncWriterSinkDelegate/didYield(contentsOf:)`` will suspend.
        ///
        /// - Parameter writability: The new writability of the ``NIOAsyncWriter``.
        @inlinable
        public func setWritability(to writability: Bool) {
            self._storage.setWritability(to: writability)
        }

        /// Finishes the sink which will result in the ``NIOAsyncWriter`` being finished.
        ///
        /// Calling this function signals the writer that any suspended or subsequent calls to ``NIOAsyncWriter/yield(contentsOf:)``
        /// or ``NIOAsyncWriter/yield(_:)`` will return a ``NIOAsyncWriterError/alreadyFinished(file:line:)`` error.
        ///
        /// - Note: Calling this function more than once has no effect.
        @inlinable
        public func finish() {
            self._storage.sinkFinish(error: nil)
        }

        /// Finishes the sink which will result in the ``NIOAsyncWriter`` being finished.
        ///
        /// Calling this function signals the writer that any suspended or subsequent calls to ``NIOAsyncWriter/yield(contentsOf:)``
        /// or ``NIOAsyncWriter/yield(_:)`` will return the passed error parameter.
        ///
        /// - Note: Calling this function more than once has no effect.
        @inlinable
        public func finish(error: Error) {
            self._storage.sinkFinish(error: error)
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncWriter {
    /// This is the underlying storage of the writer. The goal of this is to synchronize the access to all state.
    @usableFromInline
    internal struct Storage: Sendable {
        /// Internal type to generate unique yield IDs.
        ///
        /// This type has reference semantics.
        @usableFromInline
        struct YieldIDGenerator: Sendable {
            /// A struct representing a unique yield ID.
            @usableFromInline
            struct YieldID: Equatable, Sendable {
                @usableFromInline
                internal var value: UInt64

                @inlinable
                init(value: UInt64) {
                    self.value = value
                }

                @inlinable
                static func == (lhs: Self, rhs: Self) -> Bool {
                    lhs.value == rhs.value
                }
            }

            @inlinable
            func generateUniqueYieldID() -> YieldID {
                // Using relaxed is fine here since we do not need any strict ordering just a
                // unique ID for every yield.
                .init(value: _asyncWriterYieldIDCounter.loadThenWrappingIncrement(ordering: .relaxed))
            }
        }

        /// The counter used to assign an ID to all our yields.
        @usableFromInline
        internal let _yieldIDGenerator = YieldIDGenerator()
        /// The state machine.
        @usableFromInline
        internal let _state: NIOLockedValueBox<State>

        @usableFromInline
        struct State: Sendable {
            @usableFromInline
            var stateMachine: StateMachine
            @usableFromInline
            var didSuspend: (@Sendable () -> Void)?

            @inlinable
            init(stateMachine: StateMachine) {
                self.stateMachine = stateMachine
                self.didSuspend = nil
            }
        }

        /// Hook used in testing.
        @usableFromInline
        internal func _setDidSuspend(_ didSuspend: (@Sendable () -> Void)?) {
            self._state.withLockedValue {
                $0.didSuspend = didSuspend
            }
        }

        @inlinable
        internal var isWriterFinished: Bool {
            self._state.withLockedValue { $0.stateMachine.isWriterFinished }
        }

        @inlinable
        internal var isSinkFinished: Bool {
            self._state.withLockedValue { $0.stateMachine.isSinkFinished }
        }

        @inlinable
        internal init(
            isWritable: Bool,
            delegate: Delegate
        ) {
            let state = State(stateMachine: StateMachine(isWritable: isWritable, delegate: delegate))
            self._state = NIOLockedValueBox(state)
        }

        @inlinable
        internal func setWritability(to writability: Bool) {
            // We must not resume the continuation while holding the lock
            // because it can deadlock in combination with the underlying ulock
            // in cases where we race with a cancellation handler
            let action = self._state.withLockedValue {
                $0.stateMachine.setWritability(to: writability)
            }

            switch action {
            case .resumeContinuations(let suspendedYields):
                for yield in suspendedYields {
                    yield.continuation.resume(returning: .retry)
                }

            case .none:
                return
            }
        }

        @inlinable
        internal func yield<S: Sequence>(contentsOf sequence: S) async throws
        where S.Element == Element {
            let yieldID = self._yieldIDGenerator.generateUniqueYieldID()
            while true {
                switch try await self._yield(contentsOf: sequence, yieldID: yieldID) {
                case .retry:
                    continue
                case .yielded:
                    return
                }
            }
        }

        @inlinable
        internal func _yield<S: Sequence>(
            contentsOf sequence: S,
            yieldID: StateMachine.YieldID?
        ) async throws -> StateMachine.YieldResult where S.Element == Element {
            let yieldID = yieldID ?? self._yieldIDGenerator.generateUniqueYieldID()

            return try await withTaskCancellationHandler {
                let action = self._state.withLockedValue {
                    $0.stateMachine.yield(yieldID: yieldID)
                }

                switch action {
                case .callDidYield(let delegate):
                    // We are allocating a new Deque for every write here
                    delegate.didYield(contentsOf: Deque(sequence))
                    self.unbufferQueuedEvents()
                    return .yielded

                case .throwError(let error):
                    throw error

                case .suspendTask:
                    // Holding the lock here *should* be safe but because of a bug in the runtime
                    // it isn't, so drop the lock, create the continuation and then try again.
                    //
                    // See https://github.com/swiftlang/swift/issues/85668
                    //
                    // Dropping and reacquiring the lock may result in yields being reordered but
                    // only from the perspective of when this function was entered. For example:
                    //
                    // - T1 calls _yield
                    // - T2 calls _yield
                    // - T2 returns from _yield
                    // - T1 returns from _yield
                    //
                    // This is fine: the async writer doesn't offer any ordering guarantees for
                    // calls made from different threads.
                    //
                    // Within a thread there is no possibility of re-ordering as the call only
                    // returns once the write has been yielded.
                    return try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<StateMachine.YieldResult, Error>) in
                        let (action, didSuspend) = self._state.withLockedValue {
                            state -> (NIOAsyncWriter.StateMachine.YieldAction, (@Sendable () -> Void)?) in
                            let yieldAction = state.stateMachine.yield(yieldID: yieldID)
                            switch yieldAction {
                            case .callDidYield, .throwError:
                                return (yieldAction, nil)
                            case .suspendTask:
                                switch state.stateMachine.yield(
                                    continuation: continuation,
                                    yieldID: yieldID
                                ) {
                                case .cancelled:
                                    return (.throwError(CancellationError()), nil)
                                case .suspended:
                                    return (yieldAction, state.didSuspend)
                                }
                            }
                        }

                        switch action {
                        case .callDidYield(let delegate):
                            delegate.didYield(contentsOf: Deque(sequence))
                            self.unbufferQueuedEvents()
                            continuation.resume(returning: .yielded)

                        case .throwError(let error):
                            continuation.resume(throwing: error)

                        case .suspendTask:
                            didSuspend?()
                        }
                    }
                }
            } onCancel: {
                // We must not resume the continuation while holding the lock
                // because it can deadlock in combination with the underlying ulock
                // in cases where we race with a cancellation handler
                let action = self._state.withLockedValue {
                    $0.stateMachine.cancel(yieldID: yieldID)
                }

                switch action {
                case .resumeContinuationWithCancellationError(let continuation):
                    continuation.resume(throwing: CancellationError())

                case .none:
                    break
                }
            }
        }

        @inlinable
        internal func yield(element: Element) async throws {
            let yieldID = self._yieldIDGenerator.generateUniqueYieldID()
            while true {
                switch try await self._yield(element: element, yieldID: yieldID) {
                case .retry:
                    continue
                case .yielded:
                    return
                }
            }
        }

        @inlinable
        internal func _yield(
            element: Element,
            yieldID: StateMachine.YieldID?
        ) async throws -> StateMachine.YieldResult {
            let yieldID = yieldID ?? self._yieldIDGenerator.generateUniqueYieldID()

            return try await withTaskCancellationHandler {
                let action = self._state.withLockedValue {
                    $0.stateMachine.yield(yieldID: yieldID)
                }

                switch action {
                case .callDidYield(let delegate):
                    delegate.didYield(element)
                    self.unbufferQueuedEvents()
                    return .yielded

                case .throwError(let error):
                    throw error

                case .suspendTask:
                    // Holding the lock here *should* be safe but because of a bug in the runtime
                    // it isn't, so drop the lock, create the continuation and then try again.
                    //
                    // See https://github.com/swiftlang/swift/issues/85668
                    //
                    // Dropping and reacquiring the lock may result in yields being reordered but
                    // only from the perspective of when this function was entered. For example:
                    //
                    // - T1 calls _yield
                    // - T2 calls _yield
                    // - T2 returns from _yield
                    // - T1 returns from _yield
                    //
                    // This is fine: the async writer doesn't offer any ordering guarantees for
                    // calls made from different threads.
                    //
                    // Within a thread there is no possibility of re-ordering as the call only
                    // returns once the write has been yielded.
                    return try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<StateMachine.YieldResult, Error>) in
                        let (action, didSuspend) = self._state.withLockedValue {
                            state -> (NIOAsyncWriter.StateMachine.YieldAction, (@Sendable () -> Void)?) in
                            let yieldAction = state.stateMachine.yield(yieldID: yieldID)
                            switch yieldAction {
                            case .callDidYield, .throwError:
                                return (yieldAction, nil)
                            case .suspendTask:
                                switch state.stateMachine.yield(
                                    continuation: continuation,
                                    yieldID: yieldID
                                ) {
                                case .cancelled:
                                    return (.throwError(CancellationError()), nil)
                                case .suspended:
                                    return (yieldAction, state.didSuspend)
                                }
                            }
                        }

                        switch action {
                        case .callDidYield(let delegate):
                            delegate.didYield(element)
                            self.unbufferQueuedEvents()
                            continuation.resume(returning: .yielded)

                        case .throwError(let error):
                            continuation.resume(throwing: error)

                        case .suspendTask:
                            didSuspend?()
                        }
                    }
                }
            } onCancel: {
                // We must not resume the continuation while holding the lock
                // because it can deadlock in combination with the underlying lock
                // in cases where we race with a cancellation handler
                let action = self._state.withLockedValue {
                    $0.stateMachine.cancel(yieldID: yieldID)
                }

                switch action {
                case .resumeContinuationWithCancellationError(let continuation):
                    continuation.resume(throwing: CancellationError())

                case .none:
                    break
                }
            }
        }

        @inlinable
        internal func writerFinish(error: Error?) {
            // We must not resume the continuation while holding the lock
            // because it can deadlock in combination with the underlying ulock
            // in cases where we race with a cancellation handler
            let action = self._state.withLockedValue {
                $0.stateMachine.writerFinish(error: error)
            }

            switch action {
            case .callDidTerminate(let delegate):
                delegate.didTerminate(error: error)

            case .resumeContinuations(let suspendedYields):
                for yield in suspendedYields {
                    yield.continuation.resume(returning: .retry)
                }

            case .none:
                break
            }
        }

        @inlinable
        internal func sinkFinish(error: Error?) {
            // We must not resume the continuation while holding the lock
            // because it can deadlock in combination with the underlying ulock
            // in cases where we race with a cancellation handler
            let action = self._state.withLockedValue {
                $0.stateMachine.sinkFinish(error: error)
            }

            switch action {
            case .resumeContinuationsWithError(let suspendedYields, let error):
                for yield in suspendedYields {
                    yield.continuation.resume(throwing: error)
                }

            case .none:
                break
            }
        }

        @inlinable
        internal func unbufferQueuedEvents() {
            while let action = self._state.withLockedValue({ $0.stateMachine.unbufferQueuedEvents() }) {
                switch action {
                case .callDidTerminate(let delegate, let error):
                    delegate.didTerminate(error: error)

                case .resumeContinuations(let suspendedYields):
                    for yield in suspendedYields {
                        yield.continuation.resume(returning: .retry)
                    }
                    return
                }
            }
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncWriter {
    @usableFromInline
    internal struct StateMachine: Sendable {
        @usableFromInline
        typealias YieldID = Storage.YieldIDGenerator.YieldID
        /// This is a small helper struct to encapsulate the two different values for a suspended yield.
        @usableFromInline
        internal struct SuspendedYield: Sendable {
            /// The yield's ID.
            @usableFromInline
            var yieldID: YieldID
            /// The yield's produced sequence of elements.
            /// The yield's continuation.
            @usableFromInline
            var continuation: CheckedContinuation<YieldResult, Error>

            @inlinable
            init(yieldID: YieldID, continuation: CheckedContinuation<YieldResult, Error>) {
                self.yieldID = yieldID
                self.continuation = continuation
            }
        }
        /// The internal result of a yield.
        @usableFromInline
        internal enum YieldResult: Sendable {
            /// Indicates that the elements got yielded to the sink.
            case yielded
            /// Indicates that the yield should be retried.
            case retry
        }

        /// The current state of our ``NIOAsyncWriter``.
        @usableFromInline
        internal enum State: Sendable, CustomStringConvertible {
            /// The initial state before either a call to ``NIOAsyncWriter/yield(contentsOf:)`` or
            /// ``NIOAsyncWriter/finish(completion:)`` happened.
            case initial(
                isWritable: Bool,
                delegate: Delegate
            )

            /// The state after a call to ``NIOAsyncWriter/yield(contentsOf:)``.
            case streaming(
                isWritable: Bool,
                inDelegateOutcall: Bool,
                cancelledYields: [YieldID],
                suspendedYields: _TinyArray<SuspendedYield>,
                delegate: Delegate
            )

            /// The state once the writer finished and there are still tasks that need to write. This can happen if:
            /// 1. The ``NIOAsyncWriter`` was deinited
            /// 2. ``NIOAsyncWriter/finish(completion:)`` was called.
            case writerFinished(
                isWritable: Bool,
                inDelegateOutcall: Bool,
                suspendedYields: _TinyArray<SuspendedYield>,
                cancelledYields: [YieldID],
                // These are the yields that have been enqueued before the writer got finished.
                bufferedYieldIDs: _TinyArray<YieldID>,
                delegate: Delegate,
                error: Error?
            )

            /// The state once the sink has been finished or the writer has been finished and all elements
            /// have been delivered to the delegate.
            case finished(sinkError: Error?)

            /// Internal state to avoid CoW.
            case modifying

            @usableFromInline
            var description: String {
                switch self {
                case .initial(let isWritable, _):
                    return "initial(isWritable: \(isWritable))"
                case .streaming(let isWritable, let inDelegateOutcall, let cancelledYields, let suspendedYields, _):
                    return
                        "streaming(isWritable: \(isWritable), inDelegateOutcall: \(inDelegateOutcall), cancelledYields: \(cancelledYields.count), suspendedYields: \(suspendedYields.count))"
                case .writerFinished(
                    let isWritable,
                    let inDelegateOutcall,
                    let suspendedYields,
                    let cancelledYields,
                    let bufferedYieldIDs,
                    _,
                    _
                ):
                    return
                        "writerFinished(isWritable: \(isWritable), inDelegateOutcall: \(inDelegateOutcall), suspendedYields: \(suspendedYields.count), cancelledYields: \(cancelledYields.count), bufferedYieldIDs: \(bufferedYieldIDs.count)"
                case .finished:
                    return "finished"
                case .modifying:
                    return "modifying"
                }
            }
        }

        /// The state machine's current state.
        @usableFromInline
        internal var _state: State

        @inlinable
        internal var isWriterFinished: Bool {
            switch self._state {
            case .initial, .streaming:
                return false
            case .writerFinished, .finished:
                return true
            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        @inlinable
        internal var isSinkFinished: Bool {
            switch self._state {
            case .initial, .streaming, .writerFinished:
                return false
            case .finished:
                return true
            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        @inlinable
        init(
            isWritable: Bool,
            delegate: Delegate
        ) {
            self._state = .initial(isWritable: isWritable, delegate: delegate)
        }

        /// Actions returned by `setWritability()`.
        @usableFromInline
        enum SetWritabilityAction: Sendable {
            /// Indicates that all writer continuations should be resumed.
            case resumeContinuations(_TinyArray<SuspendedYield>)
        }

        @inlinable
        internal mutating func setWritability(to newWritability: Bool) -> SetWritabilityAction? {
            switch self._state {
            case .initial(_, let delegate):
                // We just need to store the new writability state
                self._state = .initial(isWritable: newWritability, delegate: delegate)

                return .none

            case .streaming(
                let isWritable,
                let inDelegateOutcall,
                let cancelledYields,
                let suspendedYields,
                let delegate
            ):
                if isWritable == newWritability {
                    // The writability didn't change so we can just early exit here
                    return .none
                }

                if newWritability && !inDelegateOutcall {
                    // We became writable again. This means we have to resume all the continuations.
                    self._state = .streaming(
                        isWritable: newWritability,
                        inDelegateOutcall: inDelegateOutcall,
                        cancelledYields: cancelledYields,
                        suspendedYields: .init(),
                        delegate: delegate
                    )

                    return .resumeContinuations(suspendedYields)
                } else if newWritability && inDelegateOutcall {
                    // We became writable but are in a delegate outcall.
                    // We just have to store the new writability here.
                    self._state = .streaming(
                        isWritable: newWritability,
                        inDelegateOutcall: inDelegateOutcall,
                        cancelledYields: cancelledYields,
                        suspendedYields: suspendedYields,
                        delegate: delegate
                    )
                    return .none
                } else {
                    // We became unwritable nothing really to do here
                    self._state = .streaming(
                        isWritable: newWritability,
                        inDelegateOutcall: inDelegateOutcall,
                        cancelledYields: cancelledYields,
                        suspendedYields: suspendedYields,
                        delegate: delegate
                    )
                    return .none
                }

            case .writerFinished(
                _,
                let inDelegateOutcall,
                let suspendedYields,
                let cancelledYields,
                let bufferedYieldIDs,
                let delegate,
                let error
            ):
                if !newWritability {
                    // We are not writable so we can't deliver the outstanding elements
                    return .none
                }

                if newWritability && !inDelegateOutcall {
                    // We became writable again. This means we have to resume all the continuations.
                    self._state = .writerFinished(
                        isWritable: newWritability,
                        inDelegateOutcall: inDelegateOutcall,
                        suspendedYields: .init(),
                        cancelledYields: cancelledYields,
                        bufferedYieldIDs: bufferedYieldIDs,
                        delegate: delegate,
                        error: error
                    )

                    return .resumeContinuations(suspendedYields)
                } else if newWritability && inDelegateOutcall {
                    // We became writable but are in a delegate outcall.
                    // We just have to store the new writability here.
                    self._state = .writerFinished(
                        isWritable: newWritability,
                        inDelegateOutcall: inDelegateOutcall,
                        suspendedYields: suspendedYields,
                        cancelledYields: cancelledYields,
                        bufferedYieldIDs: bufferedYieldIDs,
                        delegate: delegate,
                        error: error
                    )
                    return .none
                } else {
                    // We became unwritable nothing really to do here
                    self._state = .writerFinished(
                        isWritable: newWritability,
                        inDelegateOutcall: inDelegateOutcall,
                        suspendedYields: suspendedYields,
                        cancelledYields: cancelledYields,
                        bufferedYieldIDs: bufferedYieldIDs,
                        delegate: delegate,
                        error: error
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
        enum YieldAction: Sendable {
            /// Indicates that ``NIOAsyncWriterSinkDelegate/didYield(contentsOf:)`` should be called.
            case callDidYield(Delegate)
            /// Indicates that the calling `Task` should get suspended.
            case suspendTask
            /// Indicates the given error should be thrown.
            case throwError(Error)

            @inlinable
            init(isWritable: Bool, delegate: Delegate) {
                if isWritable {
                    self = .callDidYield(delegate)
                } else {
                    self = .suspendTask
                }
            }
        }

        @inlinable
        internal mutating func yield(
            yieldID: YieldID
        ) -> YieldAction {
            switch self._state {
            case .initial(let isWritable, let delegate):
                // We can transition to streaming now

                self._state = .streaming(
                    isWritable: isWritable,
                    inDelegateOutcall: isWritable,  // If we are writable we are going to make an outcall
                    cancelledYields: [],
                    suspendedYields: .init(),
                    delegate: delegate
                )

                return .init(isWritable: isWritable, delegate: delegate)

            case .streaming(
                let isWritable,
                let inDelegateOutcall,
                var cancelledYields,
                let suspendedYields,
                let delegate
            ):
                self._state = .modifying

                if let index = cancelledYields.firstIndex(of: yieldID) {
                    // We already marked the yield as cancelled. We have to remove it and
                    // throw a CancellationError.
                    cancelledYields.remove(at: index)

                    self._state = .streaming(
                        isWritable: isWritable,
                        inDelegateOutcall: inDelegateOutcall,
                        cancelledYields: cancelledYields,
                        suspendedYields: suspendedYields,
                        delegate: delegate
                    )

                    return .throwError(CancellationError())
                } else {
                    // Yield hasn't been marked as cancelled.

                    switch (isWritable, inDelegateOutcall) {
                    case (true, false):
                        self._state = .streaming(
                            isWritable: isWritable,
                            inDelegateOutcall: true,  // We are now making a call to the delegate
                            cancelledYields: cancelledYields,
                            suspendedYields: suspendedYields,
                            delegate: delegate
                        )
                        return .callDidYield(delegate)

                    case (true, true), (false, _):
                        self._state = .streaming(
                            isWritable: isWritable,
                            inDelegateOutcall: inDelegateOutcall,
                            cancelledYields: cancelledYields,
                            suspendedYields: suspendedYields,
                            delegate: delegate
                        )
                        return .suspendTask
                    }
                }

            case .writerFinished(
                let isWritable,
                let inDelegateOutcall,
                let suspendedYields,
                var cancelledYields,
                let bufferedYieldIDs,
                let delegate,
                let error
            ):
                if bufferedYieldIDs.contains(yieldID) {
                    // This yield was buffered before we became finished so we still have to deliver it
                    self._state = .modifying

                    if let index = cancelledYields.firstIndex(of: yieldID) {
                        // We already marked the yield as cancelled. We have to remove it and
                        // throw a CancellationError.
                        cancelledYields.remove(at: index)

                        self._state = .writerFinished(
                            isWritable: isWritable,
                            inDelegateOutcall: inDelegateOutcall,
                            suspendedYields: suspendedYields,
                            cancelledYields: cancelledYields,
                            bufferedYieldIDs: bufferedYieldIDs,
                            delegate: delegate,
                            error: error
                        )

                        return .throwError(CancellationError())
                    } else {
                        // Yield hasn't been marked as cancelled.

                        switch (isWritable, inDelegateOutcall) {
                        case (true, false):
                            self._state = .writerFinished(
                                isWritable: isWritable,
                                inDelegateOutcall: true,  // We are now making a call to the delegate
                                suspendedYields: suspendedYields,
                                cancelledYields: cancelledYields,
                                bufferedYieldIDs: bufferedYieldIDs,
                                delegate: delegate,
                                error: error
                            )

                            return .callDidYield(delegate)
                        case (true, true), (false, _):
                            self._state = .writerFinished(
                                isWritable: isWritable,
                                inDelegateOutcall: inDelegateOutcall,
                                suspendedYields: suspendedYields,
                                cancelledYields: cancelledYields,
                                bufferedYieldIDs: bufferedYieldIDs,
                                delegate: delegate,
                                error: error
                            )
                            return .suspendTask
                        }
                    }
                } else {
                    // We are already finished and still tried to write something
                    return .throwError(NIOAsyncWriterError.alreadyFinished())
                }

            case .finished(let sinkError):
                // We are already finished and still tried to write something
                return .throwError(sinkError ?? NIOAsyncWriterError.alreadyFinished())

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        @usableFromInline
        enum YieldWithContinuationAction {
            // The yield was cancelled; fail the continuation.
            case cancelled
            // The yield was suspended.
            case suspended
        }

        /// This method is called as a result of the above `yield` method if it decided that the task needs to get suspended.
        @inlinable
        internal mutating func yield(
            continuation: CheckedContinuation<YieldResult, Error>,
            yieldID: YieldID
        ) -> YieldWithContinuationAction {
            switch self._state {
            case .streaming(
                let isWritable,
                let inDelegateOutcall,
                var cancelledYields,
                var suspendedYields,
                let delegate
            ):
                self._state = .modifying

                if let index = cancelledYields.firstIndex(of: yieldID) {
                    cancelledYields.remove(at: index)
                    self._state = .streaming(
                        isWritable: isWritable,
                        inDelegateOutcall: inDelegateOutcall,
                        cancelledYields: cancelledYields,
                        suspendedYields: suspendedYields,
                        delegate: delegate
                    )
                    return .cancelled
                } else {
                    // We have a suspended yield at this point that hasn't been cancelled yet.
                    // We need to store the yield now.

                    let suspendedYield = SuspendedYield(
                        yieldID: yieldID,
                        continuation: continuation
                    )
                    suspendedYields.append(suspendedYield)

                    self._state = .streaming(
                        isWritable: isWritable,
                        inDelegateOutcall: inDelegateOutcall,
                        cancelledYields: cancelledYields,
                        suspendedYields: suspendedYields,
                        delegate: delegate
                    )

                    return .suspended
                }

            case .writerFinished(
                let isWritable,
                let inDelegateOutcall,
                var suspendedYields,
                var cancelledYields,
                let bufferedYieldIDs,
                let delegate,
                let error
            ):
                self._state = .modifying

                if let index = cancelledYields.firstIndex(of: yieldID) {
                    cancelledYields.remove(at: index)
                    self._state = .writerFinished(
                        isWritable: isWritable,
                        inDelegateOutcall: inDelegateOutcall,
                        suspendedYields: suspendedYields,
                        cancelledYields: cancelledYields,
                        bufferedYieldIDs: bufferedYieldIDs,
                        delegate: delegate,
                        error: error
                    )
                    return .cancelled
                } else {
                    // We have a suspended yield at this point that hasn't been cancelled yet.
                    // It was buffered before we became finished, so we still have to deliver it.
                    // We need to store the yield now.
                    let suspendedYield = SuspendedYield(
                        yieldID: yieldID,
                        continuation: continuation
                    )
                    suspendedYields.append(suspendedYield)

                    self._state = .writerFinished(
                        isWritable: isWritable,
                        inDelegateOutcall: inDelegateOutcall,
                        suspendedYields: suspendedYields,
                        cancelledYields: cancelledYields,
                        bufferedYieldIDs: bufferedYieldIDs,
                        delegate: delegate,
                        error: error
                    )

                    return .suspended
                }

            case .initial, .finished:
                preconditionFailure("This should have already been handled by `yield()`")

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        /// Actions returned by `cancel()`.
        @usableFromInline
        enum CancelAction: Sendable {
            /// Indicates that the continuation should be resumed with a `CancellationError`.
            case resumeContinuationWithCancellationError(CheckedContinuation<YieldResult, Error>)
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        internal mutating func cancel(
            yieldID: YieldID
        ) -> CancelAction {
            switch self._state {
            case .initial(let isWritable, let delegate):
                // We got a cancel before the yield happened. This means we
                // need to transition to streaming and store our cancelled state.

                self._state = .streaming(
                    isWritable: isWritable,
                    inDelegateOutcall: false,
                    cancelledYields: [yieldID],
                    suspendedYields: .init(),
                    delegate: delegate
                )

                return .none

            case .streaming(
                let isWritable,
                let inDelegateOutcall,
                var cancelledYields,
                var suspendedYields,
                let delegate
            ):
                if let index = suspendedYields.firstIndex(where: { $0.yieldID == yieldID }) {
                    self._state = .modifying
                    // We have a suspended yield for the id. We need to resume the continuation now.

                    // Removing can be quite expensive if it produces a gap in the array.
                    // Since we are not expecting a lot of elements in this array it should be fine
                    // to just remove. If this turns out to be a performance pitfall, we can
                    // swap the elements before removing. So that we always remove the last element.
                    let suspendedYield = suspendedYields.remove(at: index)

                    // We are keeping the elements that the yield produced.
                    self._state = .streaming(
                        isWritable: isWritable,
                        inDelegateOutcall: inDelegateOutcall,
                        cancelledYields: cancelledYields,
                        suspendedYields: suspendedYields,
                        delegate: delegate
                    )

                    return .resumeContinuationWithCancellationError(suspendedYield.continuation)

                } else {
                    self._state = .modifying
                    // There is no suspended yield. This can mean that we either already yielded
                    // or that the call to `yield` is coming afterwards. We need to store
                    // the ID here. However, if the yield already happened we will never remove the
                    // stored ID. The only way to avoid doing this would be storing every ID
                    cancelledYields.append(yieldID)
                    self._state = .streaming(
                        isWritable: isWritable,
                        inDelegateOutcall: inDelegateOutcall,
                        cancelledYields: cancelledYields,
                        suspendedYields: suspendedYields,
                        delegate: delegate
                    )

                    return .none
                }

            case .writerFinished(
                let isWritable,
                let inDelegateOutcall,
                var suspendedYields,
                var cancelledYields,
                let bufferedYieldIDs,
                let delegate,
                let error
            ):
                guard bufferedYieldIDs.contains(yieldID) else {
                    return .none
                }
                if let index = suspendedYields.firstIndex(where: { $0.yieldID == yieldID }) {
                    self._state = .modifying
                    // We have a suspended yield for the id. We need to resume the continuation now.

                    // Removing can be quite expensive if it produces a gap in the array.
                    // Since we are not expecting a lot of elements in this array it should be fine
                    // to just remove. If this turns out to be a performance pitfall, we can
                    // swap the elements before removing. So that we always remove the last element.
                    let suspendedYield = suspendedYields.remove(at: index)

                    // We are keeping the elements that the yield produced.
                    self._state = .writerFinished(
                        isWritable: isWritable,
                        inDelegateOutcall: inDelegateOutcall,
                        suspendedYields: suspendedYields,
                        cancelledYields: cancelledYields,
                        bufferedYieldIDs: bufferedYieldIDs,
                        delegate: delegate,
                        error: error
                    )

                    return .resumeContinuationWithCancellationError(suspendedYield.continuation)

                } else {
                    self._state = .modifying
                    // There is no suspended yield. This can mean that we either already yielded
                    // or that the call to `yield` is coming afterwards. We need to store
                    // the ID here. However, if the yield already happened we will never remove the
                    // stored ID. The only way to avoid doing this would be storing every ID
                    cancelledYields.append(yieldID)
                    self._state = .writerFinished(
                        isWritable: isWritable,
                        inDelegateOutcall: inDelegateOutcall,
                        suspendedYields: suspendedYields,
                        cancelledYields: cancelledYields,
                        bufferedYieldIDs: bufferedYieldIDs,
                        delegate: delegate,
                        error: error
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

        /// Actions returned by `writerFinish()`.
        @usableFromInline
        enum WriterFinishAction: Sendable {
            /// Indicates that ``NIOAsyncWriterSinkDelegate/didTerminate(completion:)`` should be called.
            case callDidTerminate(Delegate)
            /// Indicates that all continuations should be resumed.
            case resumeContinuations(_TinyArray<SuspendedYield>)
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        internal mutating func writerFinish(error: Error?) -> WriterFinishAction {
            switch self._state {
            case .initial(_, let delegate):
                // Nothing was ever written so we can transition to finished
                self._state = .finished(sinkError: nil)

                return .callDidTerminate(delegate)

            case .streaming(
                let isWritable,
                let inDelegateOutcall,
                let cancelledYields,
                let suspendedYields,
                let delegate
            ):
                // We are currently streaming and the writer got finished.
                if suspendedYields.isEmpty {
                    if inDelegateOutcall {
                        // We are in an outcall already and have to buffer
                        // the didTerminate call.
                        self._state = .writerFinished(
                            isWritable: isWritable,
                            inDelegateOutcall: inDelegateOutcall,
                            suspendedYields: .init(),
                            cancelledYields: cancelledYields,
                            bufferedYieldIDs: .init(),
                            delegate: delegate,
                            error: error
                        )
                        return .none
                    } else {
                        // We have no elements left and are not in an outcall so we
                        // can transition to finished directly
                        self._state = .finished(sinkError: nil)
                        return .callDidTerminate(delegate)
                    }
                } else {
                    // There are still suspended writer tasks which we need to deliver once we become writable again
                    self._state = .writerFinished(
                        isWritable: isWritable,
                        inDelegateOutcall: inDelegateOutcall,
                        suspendedYields: suspendedYields,
                        cancelledYields: cancelledYields,
                        bufferedYieldIDs: _TinyArray(suspendedYields.map { $0.yieldID }),
                        delegate: delegate,
                        error: error
                    )

                    return .none
                }

            case .writerFinished, .finished:
                // We are already finished and there is nothing to do
                return .none

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        /// Actions returned by `sinkFinish()`.
        @usableFromInline
        enum SinkFinishAction: Sendable {
            /// Indicates that all continuations should be resumed with the given error.
            case resumeContinuationsWithError(_TinyArray<SuspendedYield>, Error)
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        internal mutating func sinkFinish(error: Error?) -> SinkFinishAction {
            switch self._state {
            case .initial(_, _):
                // Nothing was ever written so we can transition to finished
                self._state = .finished(sinkError: error)

                return .none

            case .streaming(_, _, _, let suspendedYields, _):
                // We are currently streaming and the sink got finished.
                // We can transition to finished and need to resume all continuations.
                self._state = .finished(sinkError: error)
                return .resumeContinuationsWithError(
                    suspendedYields,
                    error ?? NIOAsyncWriterError.alreadyFinished()
                )

            case .writerFinished(_, _, let suspendedYields, _, _, _, _):
                // The writer already got finished and the sink got finished too now.
                // We can transition to finished and need to resume all continuations.
                self._state = .finished(sinkError: error)
                return .resumeContinuationsWithError(
                    suspendedYields,
                    error ?? NIOAsyncWriterError.alreadyFinished()
                )

            case .finished:
                // We are already finished and there is nothing to do
                return .none

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        /// Actions returned by `sinkFinish()`.
        @usableFromInline
        enum UnbufferQueuedEventsAction: Sendable {
            case resumeContinuations(_TinyArray<SuspendedYield>)
            case callDidTerminate(Delegate, Error?)
        }

        @inlinable
        internal mutating func unbufferQueuedEvents() -> UnbufferQueuedEventsAction? {
            switch self._state {
            case .initial:
                preconditionFailure("Invalid state")

            case .streaming(
                let isWritable,
                let inDelegateOutcall,
                let cancelledYields,
                let suspendedYields,
                let delegate
            ):
                precondition(inDelegateOutcall, "We must be in a delegate outcall when we unbuffer events")
                // We have to resume the other suspended yields now.

                if suspendedYields.isEmpty {
                    // There are no other writer suspended writer tasks so we can just return
                    self._state = .streaming(
                        isWritable: isWritable,
                        inDelegateOutcall: false,
                        cancelledYields: cancelledYields,
                        suspendedYields: suspendedYields,
                        delegate: delegate
                    )
                    return .none
                } else {
                    // We have to resume the other suspended yields now.
                    self._state = .streaming(
                        isWritable: isWritable,
                        inDelegateOutcall: false,
                        cancelledYields: cancelledYields,
                        suspendedYields: .init(),
                        delegate: delegate
                    )
                    return .resumeContinuations(suspendedYields)
                }

            case .writerFinished(
                let isWritable,
                let inDelegateOutcall,
                let suspendedYields,
                let cancelledYields,
                let bufferedYieldIDs,
                let delegate,
                let error
            ):
                precondition(inDelegateOutcall, "We must be in a delegate outcall when we unbuffer events")
                if suspendedYields.isEmpty {
                    // We were the last writer task and can now call didTerminate
                    self._state = .finished(sinkError: nil)
                    return .callDidTerminate(delegate, error)
                } else {
                    // There are still other writer tasks that need to be resumed
                    self._state = .modifying

                    self._state = .writerFinished(
                        isWritable: isWritable,
                        inDelegateOutcall: false,
                        suspendedYields: .init(),
                        cancelledYields: cancelledYields,
                        bufferedYieldIDs: bufferedYieldIDs,
                        delegate: delegate,
                        error: error
                    )

                    return .resumeContinuations(suspendedYields)
                }

            case .finished:
                return .none

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }
    }
}
