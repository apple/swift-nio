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

import Atomics
import NIOCore

import struct Foundation.UUID

#if canImport(Dispatch)
import Dispatch
#endif

// MARK: - AsyncEventLoop -

/// A single‑threaded `EventLoop` implemented solely with Swift Concurrency.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public final class AsyncEventLoop: EventLoop, @unchecked Sendable {
    public enum AsynceEventLoopError: Error {
        case cancellationFailure
    }

    private let _id = UUID()  // unique identifier
    private let executor: AsyncEventLoopExecutor
    private var cachedSucceededVoidFuture: EventLoopFuture<Void>?
    private enum ShutdownState: UInt8 {
        case running = 0
        case closing = 1
        case closed = 2
    }
    private let shutdownState = ManagedAtomic<UInt8>(ShutdownState.running.rawValue)

    public init(manualTimeModeForTesting: Bool = false) {
        self.executor = AsyncEventLoopExecutor(loopID: _id, manualTimeMode: manualTimeModeForTesting)
    }

    // MARK: - EventLoop basics -

    public var inEventLoop: Bool {
        _CurrentEventLoopKey.id == _id
    }

    private func isAcceptingNewTasks() -> Bool {
        shutdownState.load(ordering: .acquiring) == ShutdownState.running.rawValue
    }

    private func isFullyShutdown() -> Bool {
        shutdownState.load(ordering: .acquiring) == ShutdownState.closed.rawValue
    }

    @_disfavoredOverload
    public func execute(_ task: @escaping @Sendable () -> Void) {
        guard self.isAcceptingNewTasks() || self._canAcceptExecuteDuringShutdown else { return }
        executor.enqueue(task)
    }

    private var _canAcceptExecuteDuringShutdown: Bool {
        self.inEventLoop
            || MultiThreadedEventLoopGroup._GroupContextKey.isFromMultiThreadedEventLoopGroup
    }

    // MARK: - Promises / Futures -

    public func makeSucceededFuture<T: Sendable>(_ value: T) -> EventLoopFuture<T> {
        if T.self == Void.self {
            return self.makeSucceededVoidFuture() as! EventLoopFuture<T>
        }
        let p = makePromise(of: T.self)
        p.succeed(value)
        return p.futureResult
    }

    public func makeFailedFuture<T>(_ error: Error) -> EventLoopFuture<T> {
        let p = makePromise(of: T.self)
        p.fail(error)
        return p.futureResult
    }

    public func makeSucceededVoidFuture() -> EventLoopFuture<Void> {
        if self.inEventLoop {
            if let cached = self.cachedSucceededVoidFuture {
                return cached
            }
            let future = self.makeSucceededVoidFutureUncached()
            self.cachedSucceededVoidFuture = future
            return future
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
    public func submit<T>(_ task: @escaping @Sendable () throws -> T) -> EventLoopFuture<T> {
        self.submit { () throws -> _UncheckedSendable<T> in
            _UncheckedSendable(try task())
        }.map { $0.value }
    }
    #endif

    public func submit<T: Sendable>(_ task: @escaping @Sendable () throws -> T) -> EventLoopFuture<T> {
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

    public func flatSubmit<T: Sendable>(
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
    public func scheduleTask<T>(
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
    public func scheduleTask<T: Sendable>(
        deadline: NIODeadline,
        _ task: @escaping @Sendable () throws -> T
    ) -> Scheduled<T> {
        self._scheduleTask(deadline: deadline, task: task)
    }
    #endif

    @preconcurrency
    public func scheduleTask<T>(
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
    public func scheduleTask<T: Sendable>(
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

        return Scheduled(promise: promise) { [weak self] in
            // NOTE: Documented cancellation procedure indicates
            // cancellation is not guaranteed. As such, and to match existing Promise API's,
            // using a Task here to avoid pushing async up the software stack.
            self?.executor.cancelScheduledJob(withID: jobID)

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

        return Scheduled(promise: promise) { [weak self] in
            // NOTE: Documented cancellation procedure indicates
            // cancellation is not guaranteed. As such, and to match existing Promise API's,
            // using a Task here to avoid pushing async up the software stack.
            self?.executor.cancelScheduledJob(withID: jobID)

            // NOTE: NIO Core already fails the promise before calling the cancellation closure,
            // so we do NOT try to fail the promise. Also cancellation is not guaranteed, so we
            // allow cancellation to silently fail rather than re-negotiating to a throwing API.
        }
    }

    func closeGracefully() async {
        let previous = shutdownState.exchange(ShutdownState.closing.rawValue, ordering: .acquiring)
        guard ShutdownState(rawValue: previous) != .closed else { return }
        self.cachedSucceededVoidFuture = nil
        await executor.clearQueue()
        shutdownState.store(ShutdownState.closed.rawValue, ordering: .releasing)
    }

    public func next() -> EventLoop {
        self
    }
    public func any() -> EventLoop {
        self
    }

    /// Moves time forward by specified increment, and runs event loop, causing
    /// all pending events either from enqueing or scheduling requirements to run.
    func advanceTime(by increment: TimeAmount) async throws {
        try await executor.advanceTime(by: increment)
    }

    func advanceTime(to deadline: NIODeadline) async throws {
        try await executor.advanceTime(to: deadline)
    }

    func run() async {
        await executor.run()
    }

    #if canImport(Dispatch)
    public func shutdownGracefully(
        queue: DispatchQueue,
        _ callback: @escaping @Sendable (Error?) -> Void
    ) {
        if MultiThreadedEventLoopGroup._GroupContextKey.isFromMultiThreadedEventLoopGroup {
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

    public func syncShutdownGracefully() throws {
        // The test AsyncEventLoopTests.testIllegalCloseOfEventLoopFails requires
        // this implementation to throw an error, because uses should call shutdown on
        // MultiThreadedEventLoopGroup instead of calling it directly on the loop.
        throw EventLoopError.unsupportedOperation
    }

    public func shutdownGracefully() async throws {
        await self.closeGracefully()
    }

    #if !canImport(Dispatch)
    public func _preconditionSafeToSyncShutdown(file: StaticString, line: UInt) {
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
    private struct _UncheckedSendable<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension AsyncEventLoop: NIOSerialEventLoopExecutor {}

#endif  // os(WASI) || canImport(Testing)
