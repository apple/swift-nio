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

/// The delegate of the ``NIOAsyncWriter``. It is the consumer of the yielded writes to the ``NIOAsyncWriter``.
/// Furthermore, the delegate gets informed when the ``NIOAsyncWriter`` terminated.
///
/// - Important: The methods on the delegate are called while a lock inside of the ``NIOAsyncWriter`` is held. This is done to
/// guarantee the ordering of the writes. However, this means you **MUST NOT** call ``NIOAsyncWriter/Sink/setWritability(to:)``
/// from within ``NIOAsyncWriterSinkDelegate/didYield(contentsOf:)`` or ``NIOAsyncWriterSinkDelegate/didTerminate(error:)``.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol NIOAsyncWriterSinkDelegate: Sendable {
    /// The `Element` type of the delegate and the writer.
    associatedtype Element: Sendable

    /// This method is called once a sequence was yielded to the ``NIOAsyncWriter``.
    ///
    /// If the ``NIOAsyncWriter`` was writable when the sequence was yielded, the sequence will be forwarded
    /// right away to the delegate. If the ``NIOAsyncWriter`` was _NOT_ writable then the sequence will be buffered
    /// until the ``NIOAsyncWriter`` becomes writable again. All buffered writes, while the ``NIOAsyncWriter`` is not writable,
    /// will be coalesced into a single sequence.
    ///
    /// - Important: You **MUST NOT** call ``NIOAsyncWriter/Sink/setWritability(to:)`` from within this method.
    func didYield(contentsOf sequence: Deque<Element>)

    /// This method is called once a single element was yielded to the ``NIOAsyncWriter``.
    ///
    /// If the ``NIOAsyncWriter`` was writable when the sequence was yielded, the sequence will be forwarded
    /// right away to the delegate. If the ``NIOAsyncWriter`` was _NOT_ writable then the sequence will be buffered
    /// until the ``NIOAsyncWriter`` becomes writable again. All buffered writes, while the ``NIOAsyncWriter`` is not writable,
    /// will be coalesced into a single sequence.
    ///
    /// - Note: This a fast path that you can optionally implement. By default this will just call ``NIOAsyncWriterSinkDelegate/didYield(contentsOf:)``.
    ///
    /// - Important: You **MUST NOT** call ``NIOAsyncWriter/Sink/setWritability(to:)`` from within this method.
    func didYield(_ element: Element)

    /// This method is called once the ``NIOAsyncWriter`` is terminated.
    ///
    /// Termination happens if:
    /// - The ``NIOAsyncWriter`` is deinited and all yielded elements have been delivered to the delegate.
    /// - ``NIOAsyncWriter/finish()`` is called and all yielded elements have been delivered to the delegate.
    /// - ``NIOAsyncWriter/finish(error:)`` is called and all yielded elements have been delivered to the delegate.
    /// - ``NIOAsyncWriter/Sink/finish()`` or ``NIOAsyncWriter/Sink/finish(error:)`` is called.
    ///
    /// - Note: This is guaranteed to be called _exactly_ once.
    ///
    /// - Parameter error: The error that terminated the ``NIOAsyncWriter``. If the writer was terminated without an
    /// error this value is `nil`. This can be either the error passed to ``NIOAsyncWriter/finish(error:)`` or
    /// to ``NIOAsyncWriter/Sink/finish(error:)``.
    ///
    /// - Important: You **MUST NOT** call ``NIOAsyncWriter/Sink/setWritability(to:)`` from within this method.
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

    @usableFromInline
    var file: String

    @usableFromInline
    var line: Int

    @inlinable
    init(_code: _Code, file: String, line: Int) {
        self._code = _code
        self.file = file
        self.line = line
    }

    @inlinable
    public static func == (lhs: NIOAsyncWriterError, rhs: NIOAsyncWriterError) -> Bool {
        return lhs._code == rhs._code
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
        "NIOAsyncWriterError.\(self._code.rawValue)"
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
    public struct NewWriter {
        /// The ``sink`` which **MUST** be retained by the consumer and is used to set the writability.
        public let sink: Sink
        /// The ``writer`` which is the actual ``NIOAsyncWriter`` and should be passed to the producer.
        public let writer: NIOAsyncWriter

        @inlinable
        /* fileprivate */ internal init(
            sink: Sink,
            writer: NIOAsyncWriter
        ) {
            self.sink = sink
            self.writer = writer
        }
    }

    /// This class is needed to hook the deinit to observe once all references to the ``NIOAsyncWriter`` are dropped.
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

    @inlinable
    /* private */ internal var _storage: Storage {
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
    public static func makeWriter(
        elementType: Element.Type = Element.self,
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

    @inlinable
    /* private */ internal init(
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
    /// If the ``NIOAsyncWriter`` is writable the sequence will get forwarded to the ``NIOAsyncWriterSinkDelegate`` immediately.
    /// Otherwise, the sequence will be buffered and the call to ``NIOAsyncWriter/yield(contentsOf:)`` will get suspended until the ``NIOAsyncWriter``
    /// becomes writable again. If the calling `Task` gets cancelled at any point the call to ``NIOAsyncWriter/yield(contentsOf:)``
    /// will be resumed.
    ///
    /// If the ``NIOAsyncWriter/finish()`` or ``NIOAsyncWriter/finish(error:)`` method is called while a call to
    /// ``NIOAsyncWriter/yield(contentsOf:)`` is suspended then the call will be resumed and the yielded sequence will be kept buffered.
    ///
    /// If the ``NIOAsyncWriter/Sink/finish()`` or ``NIOAsyncWriter/Sink/finish(error:)`` method is called while
    /// a call to ``NIOAsyncWriter/yield(contentsOf:)`` is suspended then the call will be resumed with an error and the
    /// yielded sequence is dropped.
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
    /// If the ``NIOAsyncWriter`` is writable the element will get forwarded to the ``NIOAsyncWriterSinkDelegate`` immediately.
    /// Otherwise, the element will be buffered and the call to ``NIOAsyncWriter/yield(_:)`` will get suspended until the ``NIOAsyncWriter``
    /// becomes writable again. If the calling `Task` gets cancelled at any point the call to ``NIOAsyncWriter/yield(_:)``
    /// will be resumed.
    ///
    /// If the ``NIOAsyncWriter/finish()`` or ``NIOAsyncWriter/finish(error:)`` method is called while a call to
    /// ``NIOAsyncWriter/yield(_:)`` is suspended then the call will be resumed and the yielded sequence will be kept buffered.
    ///
    /// If the ``NIOAsyncWriter/Sink/finish()`` or ``NIOAsyncWriter/Sink/finish(error:)`` method is called while
    /// a call to ``NIOAsyncWriter/yield(_:)`` is suspended then the call will be resumed with an error and the
    /// yielded sequence is dropped.
    ///
    /// This can be called more than once and from multiple `Task`s at the same time.
    ///
    /// - Parameter element: The element to yield.
    @inlinable
    public func yield(_ element: Element) async throws {
        try await self._storage.yield(element)
    }

    /// Finishes the writer.
    ///
    /// Calling this function signals the writer that any suspended calls to ``NIOAsyncWriter/yield(contentsOf:)``
    /// or ``NIOAsyncWriter/yield(_:)`` will be resumed. Any subsequent calls to ``NIOAsyncWriter/yield(contentsOf:)``
    /// or ``NIOAsyncWriter/yield(_:)`` will throw.
    ///
    /// Any element that have been yielded elements before the writer has been finished which have not been delivered yet are continued
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
    /// Any element that have been yielded elements before the writer has been finished which have not been delivered yet are continued
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
    public struct Sink {
        /// This class is needed to hook the deinit to observe once all references to the ``NIOAsyncWriter/Sink`` are dropped.
        @usableFromInline
        /* fileprivate */ internal final class InternalClass: Sendable {
            @usableFromInline
            /* fileprivate */ internal let _storage: Storage

            @inlinable
            init(storage: Storage) {
                self._storage = storage
            }

            @inlinable
            deinit {
                // We need to call finish here to resume any suspended continuation.
                self._storage.sinkFinish(error: nil)
            }
        }

        @usableFromInline
        /* private */ internal let _internalClass: InternalClass

        @inlinable
        /* private */ internal var _storage: Storage {
            self._internalClass._storage
        }

        @inlinable
        init(storage: Storage) {
            self._internalClass = .init(storage: storage)
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
    /* fileprivate */ internal final class Storage: @unchecked Sendable {
        /// Internal type to generate unique yield IDs.
        ///
        /// This type has reference semantics.
        @usableFromInline
        struct YieldIDGenerator {
            /// A struct representing a unique yield ID.
            @usableFromInline
            struct YieldID: Equatable, Sendable {
                @usableFromInline
                /* private */ internal var value: UInt64

                @inlinable
                init(value: UInt64) {
                    self.value = value
                }

                @inlinable
                static func == (lhs: Self, rhs: Self) -> Bool {
                    lhs.value == rhs.value
                }
            }

            @usableFromInline
            /* private */ internal let _yieldIDCounter = ManagedAtomic<UInt64>(0)

            @inlinable
            func generateUniqueYieldID() -> YieldID {
                // Using relaxed is fine here since we do not need any strict ordering just a
                // unique ID for every yield.
                .init(value: self._yieldIDCounter.loadThenWrappingIncrement(ordering: .relaxed))
            }
        }

        /// The lock that protects our state.
        @usableFromInline
        /* private */ internal let _lock = NIOLock()
        /// The counter used to assign an ID to all our yields.
        @usableFromInline
        /* private */ internal let _yieldIDGenerator = YieldIDGenerator()
        /// The state machine.
        @usableFromInline
        /* private */ internal var _stateMachine: StateMachine

        @inlinable
        /* fileprivate */ internal init(
            isWritable: Bool,
            delegate: Delegate
        ) {
            self._stateMachine = .init(isWritable: isWritable, delegate: delegate)
        }

        @inlinable
        /* fileprivate */ internal func writerDeinitialized() {
            self._lock.withLock {
                let action = self._stateMachine.writerDeinitialized()

                switch action {
                case .callDidTerminate(let delegate):
                    // We are calling the delegate while holding lock. This can lead to potential crashes
                    // if the delegate calls `setWritability` reentrantly. However, we call this
                    // out in the docs of the delegate
                    delegate.didTerminate(error: nil)

                case .none:
                    break
                }
            }
        }

        @inlinable
        /* fileprivate */ internal func setWritability(to writability: Bool) {
            self._lock.withLock {
                let action = self._stateMachine.setWritability(to: writability)

                switch action {
                case .callDidYieldAndResumeContinuations(let delegate, let elements, let suspendedYields):
                    // We are calling the delegate while holding lock. This can lead to potential crashes
                    // if the delegate calls `setWritability` reentrantly. However, we call this
                    // out in the docs of the delegate
                    delegate.didYield(contentsOf: elements)

                    // It is safe to resume the continuations while holding the lock since resume
                    // is immediately returning and just enqueues the Job on the executor
                    suspendedYields.forEach { $0.continuation.resume() }

                case .callDidYieldAndDidTerminate(let delegate, let elements):
                    // We are calling the delegate while holding lock. This can lead to potential crashes
                    // if the delegate calls `setWritability` reentrantly. However, we call this
                    // out in the docs of the delegate
                    delegate.didYield(contentsOf: elements)
                    delegate.didTerminate(error: nil)

                case .none:
                    return
                }
            }
        }

        @inlinable
        /* fileprivate */ internal func yield<S: Sequence>(contentsOf sequence: S) async throws where S.Element == Element {
            let yieldID = self._yieldIDGenerator.generateUniqueYieldID()

            try await withTaskCancellationHandler {
                // We are manually locking here to hold the lock across the withCheckedContinuation call
                self._lock.lock()

                let action = self._stateMachine.yield(contentsOf: sequence, yieldID: yieldID)

                switch action {
                case .callDidYield(let delegate):
                    // We are calling the delegate while holding lock. This can lead to potential crashes
                    // if the delegate calls `setWritability` reentrantly. However, we call this
                    // out in the docs of the delegate

                    // We are allocating a new Deque for every write here
                    delegate.didYield(contentsOf: Deque(sequence))
                    self._lock.unlock()

                case .returnNormally:
                    self._lock.unlock()
                    return

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
                self._lock.withLock {
                    let action = self._stateMachine.cancel(yieldID: yieldID)

                    switch action {
                    case .resumeContinuation(let continuation):
                        // It is safe to resume the continuations while holding the lock since resume
                        // is immediately returning and just enqueues the Job on the executor
                        continuation.resume()

                    case .none:
                        break
                    }
                }
            }
        }

        @inlinable
        /* fileprivate */ internal func yield(_ element: Element) async throws {
            let yieldID = self._yieldIDGenerator.generateUniqueYieldID()

            try await withTaskCancellationHandler {
                // We are manually locking here to hold the lock across the withCheckedContinuation call
                self._lock.lock()

                let action = self._stateMachine.yield(contentsOf: CollectionOfOne(element), yieldID: yieldID)

                switch action {
                case .callDidYield(let delegate):
                    // We are calling the delegate while holding lock. This can lead to potential crashes
                    // if the delegate calls `setWritability` reentrantly. However, we call this
                    // out in the docs of the delegate

                    delegate.didYield(element)
                    self._lock.unlock()

                case .returnNormally:
                    self._lock.unlock()
                    return

                case .throwError(let error):
                    self._lock.unlock()
                    throw error

                case .suspendTask:
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        self._stateMachine.yield(
                            contentsOf: CollectionOfOne(element),
                            continuation: continuation,
                            yieldID: yieldID
                        )

                        self._lock.unlock()
                    }
                }
            } onCancel: {
                self._lock.withLock {
                    let action = self._stateMachine.cancel(yieldID: yieldID)

                    switch action {
                    case .resumeContinuation(let continuation):
                        // It is safe to resume the continuations while holding the lock since resume
                        // is immediately returning and just enqueues the Job on the executor
                        continuation.resume()

                    case .none:
                        break
                    }
                }
            }
        }

        @inlinable
        /* fileprivate */ internal func writerFinish(error: Error?) {
            self._lock.withLock {
                let action = self._stateMachine.writerFinish()

                switch action {
                case .callDidTerminate(let delegate):
                    // We are calling the delegate while holding lock. This can lead to potential crashes
                    // if the delegate calls `setWritability` reentrantly. However, we call this
                    // out in the docs of the delegate
                    delegate.didTerminate(error: error)

                case .resumeContinuations(let suspendedYields):
                    // It is safe to resume the continuations while holding the lock since resume
                    // is immediately returning and just enqueues the Job on the executor
                    suspendedYields.forEach { $0.continuation.resume() }

                case .none:
                    break
                }
            }
        }

        @inlinable
        /* fileprivate */ internal func sinkFinish(error: Error?) {
            self._lock.withLock {
                let action = self._stateMachine.sinkFinish(error: error)

                switch action {
                case .callDidTerminate(let delegate, let error):
                    // We are calling the delegate while holding lock. This can lead to potential crashes
                    // if the delegate calls `setWritability` reentrantly. However, we call this
                    // out in the docs of the delegate
                    delegate.didTerminate(error: error)

                case .resumeContinuationsWithErrorAndCallDidTerminate(let delegate, let suspendedYields, let error):
                    // We are calling the delegate while holding lock. This can lead to potential crashes
                    // if the delegate calls `setWritability` reentrantly. However, we call this
                    // out in the docs of the delegate
                    delegate.didTerminate(error: error)

                    // It is safe to resume the continuations while holding the lock since resume
                    // is immediately returning and just enqueues the Job on the executor
                    suspendedYields.forEach { $0.continuation.resume(throwing: error) }

                case .none:
                    break
                }
            }
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncWriter {
    @usableFromInline
    /* private */ internal struct StateMachine {
        @usableFromInline
        typealias YieldID = Storage.YieldIDGenerator.YieldID
        /// This is a small helper struct to encapsulate the two different values for a suspended yield.
        @usableFromInline
        /* private */ internal struct SuspendedYield {
            /// The yield's ID.
            @usableFromInline
            var yieldID: YieldID
            /// The yield's produced sequence of elements.
            /// The yield's continuation.
            @usableFromInline
            var continuation: CheckedContinuation<Void, Error>

            @inlinable
            init(yieldID: YieldID, continuation: CheckedContinuation<Void, Error>) {
                self.yieldID = yieldID
                self.continuation = continuation
            }
        }

        /// The current state of our ``NIOAsyncWriter``.
        @usableFromInline
        /* private */ internal enum State {
            /// The initial state before either a call to ``NIOAsyncWriter/yield(contentsOf:)`` or
            /// ``NIOAsyncWriter/finish(completion:)`` happened.
            case initial(
                isWritable: Bool,
                delegate: Delegate
            )

            /// The state after a call to ``NIOAsyncWriter/yield(contentsOf:)``.
            case streaming(
                isWritable: Bool,
                cancelledYields: [YieldID],
                suspendedYields: [SuspendedYield],
                elements: Deque<Element>,
                delegate: Delegate
            )

            /// The state once the writer finished and there are still elements that need to be delivered. This can happen if:
            /// 1. The ``NIOAsyncWriter`` was deinited
            /// 2. ``NIOAsyncWriter/finish(completion:)`` was called.
            case writerFinished(
                elements: Deque<Element>,
                delegate: Delegate
            )

            /// The state once the sink has been finished or the writer has been finished and all elements
            /// have been delivered to the delegate.
            case finished(sinkError: Error?)

            /// Internal state to avoid CoW.
            case modifying
        }

        /// The state machine's current state.
        @usableFromInline
        /* private */ internal var _state: State

        @inlinable
        init(
            isWritable: Bool,
            delegate: Delegate
        ) {
            self._state = .initial(isWritable: isWritable, delegate: delegate)
        }

        /// Actions returned by `writerDeinitialized()`.
        @usableFromInline
        enum WriterDeinitializedAction {
            /// Indicates that ``NIOAsyncWriterSinkDelegate/didTerminate(completion:)`` should be called.
            case callDidTerminate(Delegate)
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        /* fileprivate */ internal mutating func writerDeinitialized() -> WriterDeinitializedAction {
            switch self._state {
            case .initial(_, let delegate):
                // The writer deinited before writing anything.
                // We can transition to finished and inform our delegate
                self._state = .finished(sinkError: nil)

                return .callDidTerminate(delegate)

            case .streaming(_, _, let suspendedYields, let elements, let delegate):
                // The writer got deinited after we started streaming.
                // This is normal and we need to transition to finished
                // and call the delegate. However, we should not have
                // any suspended yields because they MUST strongly retain
                // the writer.
                precondition(suspendedYields.isEmpty, "We have outstanding suspended yields")
                precondition(elements.isEmpty, "We have buffered elements")

                // We have no elements left and can transition to finished directly
                self._state = .finished(sinkError: nil)

                return .callDidTerminate(delegate)

            case .finished, .writerFinished:
                // We are already finished nothing to do here
                return .none

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        /// Actions returned by `setWritability()`.
        @usableFromInline
        enum SetWritabilityAction {
            /// Indicates that ``NIOAsyncWriterSinkDelegate/didYield(contentsOf:)`` should be called
            /// and all continuations should be resumed.
            case callDidYieldAndResumeContinuations(Delegate, Deque<Element>, [SuspendedYield])
            /// Indicates that ``NIOAsyncWriterSinkDelegate/didYield(contentsOf:)`` and
            /// ``NIOAsyncWriterSinkDelegate/didTerminate(error:)``should be called.
            case callDidYieldAndDidTerminate(Delegate, Deque<Element>)
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        /* fileprivate */ internal mutating func setWritability(to newWritability: Bool) -> SetWritabilityAction {
            switch self._state {
            case .initial(_, let delegate):
                // We just need to store the new writability state
                self._state = .initial(isWritable: newWritability, delegate: delegate)

                return .none

            case .streaming(let isWritable, let cancelledYields, let suspendedYields, let elements, let delegate):
                if isWritable == newWritability {
                    // The writability didn't change so we can just early exit here
                    return .none
                }

                if newWritability {
                    // We became writable again. This means we have to resume all the continuations
                    // and yield the values.

                    self._state = .streaming(
                        isWritable: newWritability,
                        cancelledYields: cancelledYields,
                        suspendedYields: [],
                        elements: .init(),
                        delegate: delegate
                    )

                    // We are taking the whole array of suspended yields and the deque of elements
                    // and allocate a new empty one.
                    // As a performance optimization we could always keep multiple arrays/deques and
                    // switch between them but I don't think this is the performance critical part.
                    return .callDidYieldAndResumeContinuations(delegate, elements, suspendedYields)
                } else {
                    // We became unwritable nothing really to do here
                    precondition(suspendedYields.isEmpty, "No yield should be suspended at this point")
                    precondition(elements.isEmpty, "No element should be buffered at this point")

                    self._state = .streaming(
                        isWritable: newWritability,
                        cancelledYields: cancelledYields,
                        suspendedYields: suspendedYields,
                        elements: elements,
                        delegate: delegate
                    )
                    return .none
                }

            case .writerFinished(let elements, let delegate):
                if !newWritability {
                    // We are not writable so we can't deliver the outstanding elements
                    return .none
                }

                self._state = .finished(sinkError: nil)

                return .callDidYieldAndDidTerminate(delegate, elements)

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
            /// Indicates that ``NIOAsyncWriterSinkDelegate/didYield(contentsOf:)`` should be called.
            case callDidYield(Delegate)
            /// Indicates that the calling `Task` should get suspended.
            case suspendTask
            /// Indicates that the method should just return.
            case returnNormally
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
        /* fileprivate */ internal mutating func yield<S: Sequence>(
            contentsOf sequence: S,
            yieldID: YieldID
        ) -> YieldAction where S.Element == Element {
            switch self._state {
            case .initial(let isWritable, let delegate):
                // We can transition to streaming now

                self._state = .streaming(
                    isWritable: isWritable,
                    cancelledYields: [],
                    suspendedYields: [],
                    elements: .init(),
                    delegate: delegate
                )

                return .init(isWritable: isWritable, delegate: delegate)

            case .streaming(let isWritable, var cancelledYields, let suspendedYields, var elements, let delegate):
                if let index = cancelledYields.firstIndex(of: yieldID) {
                    // We already marked the yield as cancelled. We have to remove it and
                    // throw an error.
                    self._state = .modifying

                    cancelledYields.remove(at: index)

                    if isWritable {
                        // We are writable so we can yield the elements right away and then
                        // return normally.
                        self._state = .streaming(
                            isWritable: isWritable,
                            cancelledYields: cancelledYields,
                            suspendedYields: suspendedYields,
                            elements: elements,
                            delegate: delegate
                        )
                        return .callDidYield(delegate)
                    } else {
                        // We are not writable so we are just going to enqueue the writes
                        // and return normally. We are not suspending the yield since the Task
                        // is marked as cancelled.
                        elements.append(contentsOf: sequence)

                        self._state = .streaming(
                            isWritable: isWritable,
                            cancelledYields: cancelledYields,
                            suspendedYields: suspendedYields,
                            elements: elements,
                            delegate: delegate
                        )

                        return .returnNormally
                    }
                } else {
                    // Yield hasn't been marked as cancelled.
                    // This means we can either call the delegate or suspend
                    return .init(isWritable: isWritable, delegate: delegate)
                }

            case .writerFinished:
                // We are already finished and still tried to write something
                return .throwError(NIOAsyncWriterError.alreadyFinished())

            case .finished(let sinkError):
                // We are already finished and still tried to write something
                return .throwError(sinkError ?? NIOAsyncWriterError.alreadyFinished())

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        /// This method is called as a result of the above `yield` method if it decided that the task needs to get suspended.
        @inlinable
        /* fileprivate */ internal mutating func yield<S: Sequence>(
            contentsOf sequence: S,
            continuation: CheckedContinuation<Void, Error>,
            yieldID: YieldID
        ) where S.Element == Element {
            switch self._state {
            case .streaming(let isWritable, let cancelledYields, var suspendedYields, var elements, let delegate):
                // We have a suspended yield at this point that hasn't been cancelled yet.
                // We need to store the yield now.

                self._state = .modifying

                let suspendedYield = SuspendedYield(
                    yieldID: yieldID,
                    continuation: continuation
                )
                suspendedYields.append(suspendedYield)
                elements.append(contentsOf: sequence)

                self._state = .streaming(
                    isWritable: isWritable,
                    cancelledYields: cancelledYields,
                    suspendedYields: suspendedYields,
                    elements: elements,
                    delegate: delegate
                )

            case .initial, .finished, .writerFinished:
                preconditionFailure("This should have already been handled by `yield()`")

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        /// Actions returned by `cancel()`.
        @usableFromInline
        enum CancelAction {
            case resumeContinuation(CheckedContinuation<Void, Error>)
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        /* fileprivate */ internal mutating func cancel(
            yieldID: YieldID
        ) -> CancelAction {
            switch self._state {
            case .initial(let isWritable, let delegate):
                // We got a cancel before the yield happened. This means we
                // need to transition to streaming and store our cancelled state.

                self._state = .streaming(
                    isWritable: isWritable,
                    cancelledYields: [yieldID],
                    suspendedYields: [],
                    elements: .init(),
                    delegate: delegate
                )

                return .none

            case .streaming(let isWritable, var cancelledYields, var suspendedYields, let elements, let delegate):
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
                        cancelledYields: cancelledYields,
                        suspendedYields: suspendedYields,
                        elements: elements,
                        delegate: delegate
                    )

                    return .resumeContinuation(suspendedYield.continuation)

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
                        suspendedYields: suspendedYields,
                        elements: elements,
                        delegate: delegate
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

        /// Actions returned by `writerFinish()`.
        @usableFromInline
        enum WriterFinishAction {
            /// Indicates that ``NIOAsyncWriterSinkDelegate/didTerminate(completion:)`` should be called.
            case callDidTerminate(Delegate)
            /// Indicates that all continuations should be resumed.
            case resumeContinuations([SuspendedYield])
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        /* fileprivate */ internal mutating func writerFinish() -> WriterFinishAction {
            switch self._state {
            case .initial(_, let delegate):
                // Nothing was ever written so we can transition to finished
                self._state = .finished(sinkError: nil)

                return .callDidTerminate(delegate)

            case .streaming(_, _, let suspendedYields, let elements, let delegate):
                // We are currently streaming and the writer got finished.
                if elements.isEmpty {
                    // We have no elements left and can transition to finished directly
                    self._state = .finished(sinkError: nil)

                    return .callDidTerminate(delegate)
                } else {
                    // There are still elements left which we need to deliver once we become writable again
                    self._state = .writerFinished(
                        elements: elements,
                        delegate: delegate
                    )

                    // We are not resuming the continuations with the error here since their elements
                    // are still queued up. If they try to yield again they will run into an alreadyFinished error
                    return .resumeContinuations(suspendedYields)
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
        enum SinkFinishAction {
            /// Indicates that ``NIOAsyncWriterSinkDelegate/didTerminate(completion:)`` should be called.
            case callDidTerminate(Delegate, Error?)
            /// Indicates that ``NIOAsyncWriterSinkDelegate/didTerminate(completion:)`` should be called and all
            /// continuations should be resumed with the given error.
            case resumeContinuationsWithErrorAndCallDidTerminate(Delegate, [SuspendedYield], Error)
            /// Indicates that nothing should be done.
            case none
        }

        @inlinable
        /* fileprivate */ internal mutating func sinkFinish(error: Error?) -> SinkFinishAction {
            switch self._state {
            case .initial(_, let delegate):
                // Nothing was ever written so we can transition to finished
                self._state = .finished(sinkError: error)

                return .callDidTerminate(delegate, error)

            case .streaming(_, _, let suspendedYields, _, let delegate):
                // We are currently streaming and the writer got finished.
                // We can transition to finished and need to resume all continuations.
                self._state = .finished(sinkError: error)

                return .resumeContinuationsWithErrorAndCallDidTerminate(
                    delegate,
                    suspendedYields,
                    error ?? NIOAsyncWriterError.alreadyFinished()
                )

            case .writerFinished(_, let delegate):
                // The writer already finished and we were waiting to become writable again
                // The Sink finished before we became writable so we can drop the elements and
                // transition to finished
                self._state = .finished(sinkError: error)

                return .callDidTerminate(delegate, error)

            case .finished:
                // We are already finished and there is nothing to do
                return .none

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }
    }
}
