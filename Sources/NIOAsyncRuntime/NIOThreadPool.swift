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

import DequeModule
import NIOConcurrencyHelpers

import class Atomics.ManagedAtomic
import protocol NIOCore.EventLoop
import class NIOCore.EventLoopFuture
import enum NIOCore.System

/// Errors that may be thrown when executing work on a `NIOThreadPool`.
public enum NIOThreadPoolError: Sendable {
    public struct ThreadPoolInactive: Error {
        public init() {}
    }

    public struct UnsupportedOperation: Error {
        public init() {}
    }
}

/// Drop‑in stand‑in for `NIOThreadPool`, powered by Swift Concurrency.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public final class NIOThreadPool: @unchecked Sendable {
    /// The state of the `WorkItem`.
    public enum WorkItemState: Sendable {
        /// The work item is currently being executed.
        case active
        /// The work item has been cancelled and will not run.
        case cancelled
    }

    /// The work that should be done by the thread pool.
    public typealias WorkItem = @Sendable (WorkItemState) -> Void

    @usableFromInline
    struct IdentifiableWorkItem: Sendable {
        @usableFromInline var workItem: WorkItem
        @usableFromInline var id: Int?
    }

    private let shutdownFlag = ManagedAtomic(false)
    private let started = ManagedAtomic(false)
    private let numberOfThreads: Int
    private let workQueue = WorkQueue()
    private let workerTasksLock = NIOLock()
    private var workerTasks: [Task<Void, Never>] = []

    public init(numberOfThreads: Int? = nil) {
        let threads = numberOfThreads ?? System.coreCount
        self.numberOfThreads = max(1, threads)
    }

    public func start() {
        startWorkersIfNeeded()
    }

    private var isActive: Bool {
        self.started.load(ordering: .acquiring) && !self.shutdownFlag.load(ordering: .acquiring)
    }

    // MARK: - Public API -

    public func submit(_ body: @escaping WorkItem) {
        guard self.isActive else {
            body(.cancelled)
            return
        }

        startWorkersIfNeeded()

        Task {
            await self.workQueue.enqueue(IdentifiableWorkItem(workItem: body, id: nil))
        }
    }

    @preconcurrency
    public func submit<T>(
        on eventLoop: EventLoop,
        _ fn: @escaping @Sendable () throws -> T
    )
        -> EventLoopFuture<T>
    {
        self.submit(on: eventLoop) { () throws -> _UncheckedSendable<T> in
            _UncheckedSendable(try fn())
        }.map { $0.value }
    }

    public func submit<T: Sendable>(
        on eventLoop: EventLoop,
        _ fn: @escaping @Sendable () throws -> T
    ) -> EventLoopFuture<T> {
        self.makeFutureByRunningOnPool(eventLoop: eventLoop, fn)
    }

    /// Async helper mirroring `runIfActive` without an EventLoop context.
    public func runIfActive<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard self.isActive else { throw CancellationError() }

        return try await Task {
            try Task.checkCancellation()
            guard self.isActive else { throw CancellationError() }
            return try body()
        }.value
    }

    /// Event‑loop variant returning only the future.
    @preconcurrency
    public func runIfActive<T>(
        eventLoop: EventLoop,
        _ body: @escaping @Sendable () throws -> T
    )
        -> EventLoopFuture<T>
    {
        self.runIfActive(eventLoop: eventLoop) { () throws -> _UncheckedSendable<T> in
            _UncheckedSendable(try body())
        }.map { $0.value }
    }

    public func runIfActive<T: Sendable>(
        eventLoop: EventLoop,
        _ body: @escaping @Sendable () throws -> T
    ) -> EventLoopFuture<T> {
        self.makeFutureByRunningOnPool(eventLoop: eventLoop, body)
    }

    private func makeFutureByRunningOnPool<T: Sendable>(
        eventLoop: EventLoop,
        _ body: @escaping @Sendable () throws -> T
    ) -> EventLoopFuture<T> {
        guard self.isActive else {
            return eventLoop.makeFailedFuture(NIOThreadPoolError.ThreadPoolInactive())
        }

        let promise = eventLoop.makePromise(of: T.self)
        self.submit { state in
            switch state {
            case .active:
                do {
                    let value = try body()
                    promise.succeed(value)
                } catch {
                    promise.fail(error)
                }
            case .cancelled:
                promise.fail(NIOThreadPoolError.ThreadPoolInactive())
            }
        }
        return promise.futureResult
    }

    // Lifecycle --------------------------------------------------------------

    public static let singleton: NIOThreadPool = {
        let pool = NIOThreadPool()
        pool.start()
        return pool
    }()

    @preconcurrency
    public func shutdownGracefully(_ callback: @escaping @Sendable (Error?) -> Void) {
        _shutdownGracefully {
            callback(nil)
        }
    }

    public func shutdownGracefully() async throws {
        try await withCheckedThrowingContinuation { continuation in
            _shutdownGracefully {
                continuation.resume(returning: ())
            }
        }
    }

    private func _shutdownGracefully(completion: (@Sendable () -> Void)? = nil) {
        if shutdownFlag.exchange(true, ordering: .acquiring) {
            completion?()
            return
        }

        Task {
            let remaining = await workQueue.shutdown()
            for item in remaining {
                item.workItem(.cancelled)
            }

            workerTasksLock.withLock {
                for worker in workerTasks {
                    worker.cancel()
                }
                workerTasks.removeAll()
            }

            started.store(false, ordering: .releasing)
            completion?()
        }
    }

    // MARK: - Worker infrastructure

    private func startWorkersIfNeeded() {
        if self.shutdownFlag.load(ordering: .acquiring) {
            return
        }

        if self.started.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged {
            spawnWorkers()
        }
    }

    private func spawnWorkers() {
        workerTasksLock.withLock {
            guard workerTasks.isEmpty else { return }
            for index in 0..<numberOfThreads {
                workerTasks.append(
                    Task.detached { [weak self] in
                        await self?.workerLoop(identifier: index)
                    }
                )
            }
        }
    }

    private func workerLoop(identifier _: Int) async {
        while let workItem = await workQueue.nextWorkItem(shutdownFlag: shutdownFlag) {
            if self.shutdownFlag.load(ordering: .acquiring) {
                workItem.workItem(.cancelled)
            } else {
                workItem.workItem(.active)
            }
        }
    }

    actor WorkQueue {
        private var queue = Deque<IdentifiableWorkItem>()
        private var waiters: [CheckedContinuation<IdentifiableWorkItem?, Never>] = []
        private var isShuttingDown = false

        func enqueue(_ item: IdentifiableWorkItem) {
            if let continuation = waiters.popLast() {
                continuation.resume(returning: item)
            } else {
                queue.append(item)
            }
        }

        func nextWorkItem(shutdownFlag: ManagedAtomic<Bool>) async -> IdentifiableWorkItem? {
            if !queue.isEmpty {
                return queue.removeFirst()
            }

            if isShuttingDown || shutdownFlag.load(ordering: .acquiring) {
                return nil
            }

            return await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func shutdown() -> [IdentifiableWorkItem] {
            isShuttingDown = true
            let remaining = Array(queue)
            queue.removeAll()
            while let waiter = waiters.popLast() {
                waiter.resume(returning: nil)
            }
            return remaining
        }
    }

    private struct _UncheckedSendable<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}

#endif  // os(WASI) || canImport(Testing)
