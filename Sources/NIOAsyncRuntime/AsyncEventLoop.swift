//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(WASI) || canImport(Testing)

import NIOConcurrencyHelpers
import NIOCore
import struct Synchronization.Atomic
import protocol Synchronization.AtomicRepresentable

#if canImport(Dispatch)
import Dispatch
#endif

// MARK: - AsyncEventLoop -

/// An `EventLoop` implemented solely with Swift Concurrency.
///
/// This event loop allows enqueing and scheduling tasks, which will be ran using
/// Swift Concurrency. This implementation fulfills a similar role as
///
/// - note: This event loop is not intended to be used directly. Instead,
///         use `AsyncEventLoopGroup` to create and manage instances of
///         `AsyncEventLoop`.
/// - note: AsyncEventLoop and similar classes in NIOAsyncRuntime are not intended
///         to be used for I/O use cases. They are meant solely to provide an off-ramp
///         for code currently using only NIOPosix.MTELG to transition away from NIOPosix
///         and use Swift Concurrency instead.
///         `AsyncEventLoop`.
/// - note: If downstream packages are able to use the dependencies in NIOAsyncRuntime
///         without using NIOPosix, they have definitive proof that their package can transition
///         to Swift Concurrency and eliminate the swift-nio dependency altogether. NIOAsyncRuntime
///         provides a convenient stepping stone to that end.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
final class AsyncEventLoop: EventLoop, Sendable {
    /// This global atomic ID is loaded for each new event loop instance, and incremented atomically
    /// after being loaded into each new loop instance. While the usage of a global in not ideal, it is
    /// thread-safe due to the Atomic usage, and currently guaranteed to increment sequentially and
    /// therefore be unique.
    ///
    /// This approach is less heavy-handed in terms of dependencies than using something like
    /// Foundation.UUID.
    ///
    /// The following three lines are the entire implementation and usage of _globalLoopID.
    static private let _globalLoopID: Atomic<UInt> = .init(0)
    private let _id = _globalLoopID.wrappingAdd(1, ordering: .sequentiallyConsistent).oldValue  // unique identifier

    private let executor: AsyncEventLoopExecutor
    private enum ShutdownState: UInt8, AtomicRepresentable {
        case running = 0
        case closing = 1
        case closed = 2
    }
    private let shutdownState = Atomic<ShutdownState>(ShutdownState.running)

    /// Used to implement the behavior expected by testSelectableEventLoopHasPreSucceededFuturesOnlyOnTheEventLoop.
    private var cachedSucceededVoidFuture: EventLoopFuture<Void> {
        _cachedSucceededVoidFuture.withLockedValue { _cachedSucceededVoidFutureMutable in
            if let _cachedSucceededVoidFutureMutable {
                return _cachedSucceededVoidFutureMutable
            } else {
                let newFutureToBeCached = self.makeSucceededVoidFutureUncached()
                _cachedSucceededVoidFutureMutable = newFutureToBeCached
                return newFutureToBeCached
            }
        }
    }
    private let _cachedSucceededVoidFuture: NIOLockedValueBox<EventLoopFuture<Void>?> = NIOLockedValueBox(nil)

    /// - Parameter __testOnly_manualTimeMode: When true, enables a manual time mode that allows for artificial
    /// adjustments of time, outside of the real-world timeline. This should only be used for automated testing.
    init(__testOnly_manualTimeMode: Bool = false) {
        self.executor = AsyncEventLoopExecutor(loopID: _id, __testOnly_manualTimeMode: __testOnly_manualTimeMode)
    }

    // MARK: - EventLoop basics -

    @inlinable
    var inEventLoop: Bool {
        _CurrentEventLoopKey.id == _id
    }

    private func isAcceptingNewTasks() -> Bool {
        shutdownState.load(ordering: .acquiring) == ShutdownState.running
    }

    private func isFullyShutdown() -> Bool {
        shutdownState.load(ordering: .acquiring) == ShutdownState.closed
    }

    func execute(_ task: @escaping @Sendable () -> Void) {
        guard self.isAcceptingNewTasks() || self._canAcceptExecuteDuringShutdown else { return }
        executor.enqueue(task)
    }

    private var _canAcceptExecuteDuringShutdown: Bool {
        self.inEventLoop
            || AsyncEventLoopGroup._GroupContextKey.isFromAsyncEventLoopGroup
    }

    // MARK: - Promises / Futures -

    @inlinable
    func makeSucceededFuture<T: Sendable>(_ value: T) -> EventLoopFuture<T> {
        if T.self == Void.self {
            return self.makeSucceededVoidFuture() as! EventLoopFuture<T>
        }
        let p = makePromise(of: T.self)
        p.succeed(value)
        return p.futureResult
    }

    @inlinable
    func makeFailedFuture<T>(_ error: Error) -> EventLoopFuture<T> {
        let p = makePromise(of: T.self)
        p.fail(error)
        return p.futureResult
    }

    @inlinable
    func makeSucceededVoidFuture() -> EventLoopFuture<Void> {
        if self.inEventLoop {
            return self.cachedSucceededVoidFuture
        } else {
            return self.makeSucceededVoidFutureUncached()
        }
    }

    private func makeSucceededVoidFutureUncached() -> EventLoopFuture<Void> {
        let promise = self.makePromise(of: Void.self)
        promise.succeed(())
        return promise.futureResult
    }

    // MARK: - Submitting work -
    #if compiler(>=6.1)
    @preconcurrency
    @inlinable
    func submit<T>(_ task: @escaping @Sendable () throws -> T) -> EventLoopFuture<T> {
        self.submit { () throws -> _UncheckedSendable<T> in
            _UncheckedSendable(try task())
        }.map { $0.value }
    }
    #endif

    @inlinable
    func submit<T: Sendable>(_ task: @escaping @Sendable () throws -> T) -> EventLoopFuture<T> {
        guard self.isAcceptingNewTasks() else {
            return self.makeFailedFuture(EventLoopError.shutdown)
        }
        let promise = makePromise(of: T.self)
        executor.enqueue {
            do {
                let value = try task()
                promise.succeed(value)
            } catch { promise.fail(error) }
        }
        return promise.futureResult
    }

    @inlinable
    func flatSubmit<T: Sendable>(
        _ task: @escaping @Sendable () -> EventLoopFuture<T>
    )
        -> EventLoopFuture<T>
    {
        guard self.isAcceptingNewTasks() else {
            return self.makeFailedFuture(EventLoopError.shutdown)
        }
        let promise = makePromise(of: T.self)
        executor.enqueue {
            let future = task()
            future.cascade(to: promise)
        }
        return promise.futureResult
    }

    // MARK: - Scheduling -

    /// NOTE:
    ///
    /// Timing for execute vs submit vs schedule:
    ///
    /// Tasks scheduled via `execute` or `submit` are appended to the back of the event loop's task queue
    /// and are executed serially in FIFO order. Scheduled tasks (e.g., via `schedule(deadline:)`) are
    /// placed in a timing wheel and, when their deadline arrives, are enqueued at the back of the main
    /// queue after any already-pending work. This means that if the event loop is backed up, a scheduled
    /// task may execute slightly after its scheduled time, as it must wait for previously enqueued tasks
    /// to finish. Scheduled tasks never preempt or jump ahead of already-queued immediate work.
    @preconcurrency
    @inlinable
    func scheduleTask<T>(
        deadline: NIODeadline,
        _ task: @escaping @Sendable () throws -> T
    ) -> Scheduled<T> {
        let scheduled: Scheduled<_UncheckedSendable<T>> = self._scheduleTask(
            deadline: deadline,
            task: { try _UncheckedSendable(task()) }
        )
        return self._unsafelyRewrapScheduled(scheduled)
    }

    #if compiler(>=6.1)
    @inlinable
    func scheduleTask<T: Sendable>(
        deadline: NIODeadline,
        _ task: @escaping @Sendable () throws -> T
    ) -> Scheduled<T> {
        self._scheduleTask(deadline: deadline, task: task)
    }
    #endif

    @preconcurrency
    @inlinable
    func scheduleTask<T>(
        in delay: TimeAmount,
        _ task: @escaping @Sendable () throws -> T
    ) -> Scheduled<T> {
        let scheduled: Scheduled<_UncheckedSendable<T>> = self._scheduleTask(
            in: delay,
            task: { try _UncheckedSendable(task()) }
        )
        return self._unsafelyRewrapScheduled(scheduled)
    }

    #if compiler(>=6.1)
    @inlinable
    func scheduleTask<T: Sendable>(
        in delay: TimeAmount,
        _ task: @escaping @Sendable () throws -> T
    ) -> Scheduled<T> {
        self._scheduleTask(in: delay, task: task)
    }
    #endif

    private func _scheduleTask<T: Sendable>(
        deadline: NIODeadline,
        task: @escaping @Sendable () throws -> T
    ) -> Scheduled<T> {
        let promise = makePromise(of: T.self)
        guard self.isAcceptingNewTasks() else {
            promise.fail(EventLoopError._shutdown)
            return Scheduled(promise: promise) {}
        }

        let jobID = executor.schedule(
            at: deadline,
            job: {
                do {
                    promise.succeed(try task())
                } catch {
                    promise.fail(error)
                }
            },
            failFn: { error in
                promise.fail(error)
            }
        )

        return Scheduled(promise: promise) {
            // NOTE: Documented cancellation procedure indicates
            // cancellation is not guaranteed. As such, and to match existing Promise API's,
            // using a Task here to avoid pushing async up the software stack.
            self.executor.cancelScheduledJob(withID: jobID)

            // NOTE: NIO Core already fails the promise before calling the cancellation closure,
            // so we do NOT try to fail the promise. Also cancellation is not guaranteed, so we
            // allow cancellation to silently fail rather than re-negotiating to a throwing API.
        }
    }

    private func _scheduleTask<T: Sendable>(
        in delay: TimeAmount,
        task: @escaping @Sendable () throws -> T
    ) -> Scheduled<T> {
        // NOTE: This is very similar to the `scheduleTask(deadline:)` implementation. However
        // due to the nonisolated context here, we keep the implementations separate until they
        // reach isolating mechanisms within the executor.

        let promise = makePromise(of: T.self)
        guard self.isAcceptingNewTasks() else {
            promise.fail(EventLoopError._shutdown)
            return Scheduled(promise: promise) {}
        }

        let jobID = executor.schedule(
            after: delay,
            job: {
                do {
                    promise.succeed(try task())
                } catch {
                    promise.fail(error)
                }
            },
            failFn: { error in
                promise.fail(error)
            }
        )

        return Scheduled(promise: promise) {
            // NOTE: Documented cancellation procedure indicates
            // cancellation is not guaranteed. As such, and to match existing Promise API's,
            // using a Task here to avoid pushing async up the software stack.
            self.executor.cancelScheduledJob(withID: jobID)

            // NOTE: NIO Core already fails the promise before calling the cancellation closure,
            // so we do NOT try to fail the promise. Also cancellation is not guaranteed, so we
            // allow cancellation to silently fail rather than re-negotiating to a throwing API.
        }
    }

    func closeGracefully() async {
        let previous = shutdownState.exchange(ShutdownState.closing, ordering: .acquiring)
        guard previous != .closed else { return }
        self._cachedSucceededVoidFuture.withLockedValue { _cachedSucceededVoidFutureMutable in
            _cachedSucceededVoidFutureMutable = nil
        }
        await executor.clearQueue()
        shutdownState.store(ShutdownState.closed, ordering: .releasing)
    }

    @inlinable
    func next() -> EventLoop {
        self
    }
    func any() -> EventLoop {
        self
    }

    /// Moves time forward by specified increment, and runs event loop, causing
    /// all pending events either from enqueing or scheduling requirements to run.
    @inlinable
    func __testOnly_advanceTime(by increment: TimeAmount) async throws {
        try await executor.__testOnly_advanceTime(by: increment)
    }

    @inlinable
    func __testOnly_advanceTime(to deadline: NIODeadline) async throws {
        try await executor.__testOnly_advanceTime(to: deadline)
    }

    @inlinable
    func run() async {
        await executor.run()
    }

    #if canImport(Dispatch)
    func shutdownGracefully(
        queue: DispatchQueue,
        _ callback: @escaping @Sendable (Error?) -> Void
    ) {
        if AsyncEventLoopGroup._GroupContextKey.isFromAsyncEventLoopGroup {
            Task {
                await closeGracefully()
                queue.async { callback(nil) }
            }
        } else {
            // Bypassing the group shutdown and calling an event loop
            // shutdown directly is considered api-misuse
            callback(EventLoopError.unsupportedOperation)
        }
    }
    #endif

    func syncShutdownGracefully() throws {
        // The test AsyncEventLoopTests.testIllegalCloseOfEventLoopFails requires
        // this implementation to throw an error, because uses should call shutdown on
        // AsyncEventLoopGroup instead of calling it directly on the loop.
        throw EventLoopError.unsupportedOperation
    }

    func shutdownGracefully() async throws {
        await self.closeGracefully()
    }

    #if !canImport(Dispatch)
    func _preconditionSafeToSyncShutdown(file: StaticString, line: UInt) {
        assertionFailure("Synchronous shutdown API's are not currently supported by AsyncEventLoop")
    }
    #endif

    @preconcurrency
    private func _unsafelyRewrapScheduled<T>(
        _ scheduled: Scheduled<_UncheckedSendable<T>>
    ) -> Scheduled<T> {
        let promise = self.makePromise(of: T.self)
        scheduled.futureResult.whenComplete { result in
            switch result {
            case .success(let boxed):
                promise.assumeIsolatedUnsafeUnchecked().succeed(boxed.value)
            case .failure(let error):
                promise.fail(error)
            }
        }
        return Scheduled(promise: promise) {
            scheduled.cancel()
        }
    }

    /// This is a shim used to support older protocol-required API's without compiler warnings, and provide more modern
    /// concurrency-ready overloads.
    @preconcurrency
    private struct _UncheckedSendable<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
extension AsyncEventLoop: NIOSerialEventLoopExecutor {}

#endif  // os(WASI) || canImport(Testing)
