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

import NIOCore
import _NIODataStructures

import struct Foundation.UUID

/// Task‑local key that stores the UUID of the `AsyncEventLoop` currently
/// executing.  Lets us answer `inEventLoop` without private APIs.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
enum _CurrentEventLoopKey { @TaskLocal static var id: UUID? }

/// This is an actor designed to execute provided tasks in the order they enter the actor.
/// It also provides task scheduling, time manipulation, pool draining, and other mechanisms
/// required for fully supporting NIO event loop operations.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
actor AsyncEventLoopExecutor {
    private let executor: _AsyncEventLoopExecutor

    init(loopID: UUID, manualTimeMode: Bool = false) {
        self.executor = _AsyncEventLoopExecutor(loopID: loopID, manualTimeMode: manualTimeMode)
    }

    // MARK: - nonisolated API's -

    // NOTE: IMPORTANT! ⚠️
    //
    // The following API's provide non-isolated entry points
    //
    // It is VERY important that you call one and only one function inside each task block
    // to preserve first-in ordering, and to avoid interleaving issues.

    /// Schedules a job to run at a specified deadline and returns a UUID for the job that can be used to cancel the job if needed
    @discardableResult
    nonisolated func schedule(
        at deadline: NIODeadline,
        job: @Sendable @escaping () -> Void,
        failFn: @Sendable @escaping (Error) -> Void
    ) -> UUID {
        let id = UUID()
        Task { @_AsyncEventLoopExecutor._IsolatingSerialEntryActor [job, weak self] in
            // ^----- Ensures first-in entry from nonisolated contexts
            await self?.executor.schedule(at: deadline, id: id, job: job, failFn: failFn)
        }
        return id
    }

    /// Schedules a job to run after a specified delay and returns a UUID for the job that can be used to cancel the job if needed
    @discardableResult
    nonisolated func schedule(
        after delay: TimeAmount,
        job: @Sendable @escaping () -> Void,
        failFn: @Sendable @escaping (Error) -> Void
    ) -> UUID {
        let id = UUID()
        Task { @_AsyncEventLoopExecutor._IsolatingSerialEntryActor [delay, job, weak self] in
            // ^----- Ensures first-in entry from nonisolated contexts
            await self?.executor.schedule(after: delay, id: id, job: job, failFn: failFn)
        }
        return id
    }

    nonisolated func enqueue(_ job: @Sendable @escaping () -> Void) {
        Task { @_AsyncEventLoopExecutor._IsolatingSerialEntryActor [job, weak self] in
            // ^----- Ensures first-in entry from nonisolated contexts
            await self?.executor.enqueue(job)
        }
    }

    nonisolated func cancelScheduledJob(withID id: UUID) {
        Task { @_AsyncEventLoopExecutor._IsolatingSerialEntryActor [id, weak self] in
            // ^----- Ensures first-in entry from nonisolated contexts
            await self?.executor.cancelScheduledJob(withID: id)
        }
    }

    // MARK: - async API's -

    // NOTE: The following are async api's and don't require special handling

    func clearQueue() async {
        await executor.clearQueue()
    }

    func advanceTime(by increment: TimeAmount) async throws {
        try await executor.advanceTime(by: increment)
    }

    func advanceTime(to deadline: NIODeadline) async throws {
        try await executor.advanceTime(to: deadline)
    }

    func run() async {
        await executor.run()
    }
}

/// This class provides the private implementation details for ``AsyncEventLoopExecutor``.
///
/// However, it defers the nonisolated API's to ``AsyncEventLoopExecutor`` which
/// helps make the isolation boundary very clear.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
fileprivate actor _AsyncEventLoopExecutor {
    /// Used in unit testing only to enable adjusting
    /// the current time programmatically to test event scheduling and other
    private var _now = NIODeadline.now()

    private var now: NIODeadline {
        if manualTimeMode {
            _now
        } else {
            NIODeadline.now()
        }
    }

    /// We use this actor to make serialized first-in entry
    /// into the event loop. This is a shared instance between all
    /// event loops, so it is important that we ONLY use it to enqueue
    /// jobs that come from a non-isolated context.
    @globalActor
    fileprivate struct _IsolatingSerialEntryActor {
        actor ActorType {}
        static let shared = ActorType()
    }

    fileprivate typealias OrderIntegerType = UInt64

    fileprivate struct ScheduledJob {
        let id: UUID
        let deadline: NIODeadline
        let order: OrderIntegerType
        let job: @Sendable () -> Void
        let failFn: @Sendable (Error) -> Void

        init(
            id: UUID = UUID(),
            deadline: NIODeadline,
            order: OrderIntegerType,
            job: @Sendable @escaping () -> Void,
            failFn: @Sendable @escaping (Error) -> Void
        ) {
            self.id = id
            self.deadline = deadline
            self.order = order
            self.job = job
            self.failFn = failFn
        }
    }
    private var scheduledQueue = PriorityQueue<ScheduledJob>()
    private var nextScheduledItemOrder: OrderIntegerType = 0

    private var currentlyRunningExecutorTask: Task<Void, Never>?
    private let manualTimeMode: Bool
    private var wakeUpTask: Task<Void, Never>?
    private var jobQueue: [() -> Void] = []
    private var pendingCancellationJobIDs: Set<UUID> = []

    let loopID: UUID
    init(loopID: UUID, manualTimeMode: Bool = false) {
        self.loopID = loopID
        self.manualTimeMode = manualTimeMode
    }

    fileprivate func schedule(
        after delay: TimeAmount,
        id: UUID,
        job: @Sendable @escaping () -> Void,
        failFn: @Sendable @escaping (Error) -> Void
    ) {
        let base = self.schedulingNow()
        self.schedule(at: base + delay, id: id, job: job, failFn: failFn)
    }

    fileprivate func schedule(
        at deadline: NIODeadline,
        id: UUID,
        job: @Sendable @escaping () -> Void,
        failFn: @Sendable @escaping (Error) -> Void
    ) {
        if pendingCancellationJobIDs.remove(id) != nil {
            return
        }
        let order = nextScheduledItemOrder
        nextScheduledItemOrder += 1
        scheduledQueue.push(
            ScheduledJob(id: id, deadline: deadline, order: order, job: job, failFn: failFn)
        )

        runNextJobIfNeeded()
    }

    fileprivate func enqueue(_ job: @escaping () -> Void) async {
        jobQueue.append(job)
        await run()
    }

    /// Some operations in the serial executor need to wait until pending entry operations finish
    /// enqueing themselves.
    private func awaitPendingEntryOperations() async {
        await Task { @_IsolatingSerialEntryActor [] in
            // ^----- Ensures first-in entry from nonisolated contexts
            await noOp()  // We want to await for self here
        }.value
    }

    private func noOp() {}

    private func schedulingNow() -> NIODeadline {
        if manualTimeMode {
            return _now
        } else {
            let wallNow = NIODeadline.now()
            _now = max(_now, wallNow)
            return _now
        }
    }

    /// Moves time forward by specified increment, and runs event loop, causing
    /// all pending events either from enqueing or scheduling requirements to run.
    fileprivate func advanceTime(by increment: TimeAmount) async throws {
        guard manualTimeMode else {
            throw EventLoopError.unsupportedOperation
        }
        try await self.advanceTime(to: self._now + increment)
    }

    fileprivate func advanceTime(to deadline: NIODeadline) async throws {
        guard manualTimeMode else {
            throw EventLoopError.unsupportedOperation
        }
        await awaitPendingEntryOperations()

        // Wait for any existing tasks to run before starting our time advancement
        // (re-entrancy safeguard)
        if let existingTask = currentlyRunningExecutorTask {
            _ = await existingTask.value
        }

        // ========================================================
        // ℹ️ℹ️ℹ️ℹ️ IMPORTANT: ℹ️ℹ️ℹ️ℹ️
        // ========================================================
        //
        // This is non-obvious, but certain scheduled tasks can
        // schedule or kick off other scheduled tasks.
        //
        // It is CRITICAL that we advance time progressively to
        // the desired new deadline, by running the soonest
        // scheduled task (or group of tasks, if multiple have the
        // same deadline) first, sequentially until we ran all tasks
        // up to and including the new deadline.
        //
        // This way, we simulate a true progression of time. It
        // would be simpler and easier to simply jump to the new
        // deadline and run all tasks with deadlines occuring before
        // the new deadline. However, that simplistic approach
        // does not account for situations where a task may have needed
        // to generate multiple other tasks during the progression of time.

        // 1. Before we adjust time, we need to ensure we run a fresh loop
        // run with the current time, to capture t = now in our time progression
        // towards t = now + deadline.
        await run()
        await awaitPendingEntryOperations()
        if let existingTask = currentlyRunningExecutorTask {
            _ = await existingTask.value
        }

        // Deadlines before _now are interpretted moved to _now
        let finalDeadline = max(deadline, _now)
        var lastRanDeadline: NIODeadline?

        repeat {
            // 1. Get soonest task
            // Note that scheduledQueue is sorted as tasks are added, so the first item in the queue
            // should (must) always be the soonest in both deadline and priority terms.

            guard let nextSoonestTask = scheduledQueue.peek(),
                nextSoonestTask.deadline <= finalDeadline
            else {
                // 4. Repeat until the soonest task is AFTER the new deadline.
                break
            }

            // 2. Update time
            _now = max(nextSoonestTask.deadline, _now)

            // 3. Run all tasks through and up to the deadline of the soonest task
            guard let runnerTask = runNextJobIfNeeded() else {
                // Unknown how this case would happen. But if for whatever reason
                // runNextJobIfNeeded determines there are no jobs to run, we would
                // hit this condition, in which case we should stop iterating.
                assertionFailure(
                    "Unexpected use case, tried to run scheduled tasks, but unable to run them."
                )
                break
            }
            lastRanDeadline = nextSoonestTask.deadline
            await runnerTask.value
        } while !scheduledQueue.isEmpty

        // FINALLY, we update to the final deadline
        _now = finalDeadline

        // Final run of loop after time adjustment for t = now + deadline,
        // only if not already ran for this deadline.
        if let lastRanDeadline, lastRanDeadline <= finalDeadline {
            await run()
        }
    }

    fileprivate func run() async {
        await awaitPendingEntryOperations()
        if let runningTask = runNextJobIfNeeded() {
            await runningTask.value
        }
    }

    @discardableResult
    private func runNextJobIfNeeded() -> Task<Void, Never>? {
        // No need to start if a task is already running
        if let existingTask = currentlyRunningExecutorTask {
            return existingTask
        }

        // Stop if both queues are empty.
        if jobQueue.isEmpty && scheduledQueue.isEmpty {
            // no more tasks to run
            return nil
        }

        // If we reach this point, we're going to run a new loop series, and
        // we'll also set up wakeups if needed after the loop runs complete. We
        // should cancel any outstanding scheduled wakeups so they don't
        // inject themselves in the middle of a clean run.
        cancelScheduledWakeUp()

        let newTask: Task<Void, Never> = Task {
            defer {
                // When we finish, clear the handle to the existing runner task
                currentlyRunningExecutorTask = nil
            }
            await _CurrentEventLoopKey.$id.withValue(loopID) {
                // 1. Run all jobs currently in taskQueue
                runEnqueuedJobs()

                // 2. Run all jobs in scheduledQueue past the due date
                let snapshot = await runPastDueScheduledJobs(nowSnapshot: captureNowSnapshot())

                // 3. Schedule next run or wake‑up if needed.
                scheduleNextRunIfNeeded(latestSnapshot: snapshot)
            }
        }
        currentlyRunningExecutorTask = newTask
        return newTask
    }

    private func captureNowSnapshot() -> NIODeadline {
        if manualTimeMode {
            return self.now
        } else {
            _now = max(_now, NIODeadline.now())
            return self.now
        }
    }

    /// Runs all jobs currently in taskQueue
    private func runEnqueuedJobs() {
        while !jobQueue.isEmpty {
            // Run the job
            let job = jobQueue.removeFirst()
            job()
        }
    }

    /// Runs all jobs in scheduledQueue past the due date
    private func runPastDueScheduledJobs(nowSnapshot: NIODeadline) async -> NIODeadline {
        var lastCapturedSnapshot = nowSnapshot
        while true {
            // An expected edge case is that if an imminently scheduled task
            // is cancelled literally right after being scheduled, it should
            // be cancelled and not run. This behavior is asserted by the
            // test named testRepeatedTaskThatIsImmediatelyCancelledNeverFires.
            //
            // To guarantee this behavior, we do the following:
            //
            // - Ensure entry cancelScheduledJob is guarded by _IsolatingSerialEntryActor
            // - Await here for re-entry into _IsolatingSerialEntryActor using awaitPendingEntryOperations()
            await awaitPendingEntryOperations()
            guard let scheduled = scheduledQueue.peek() else {
                break
            }

            guard lastCapturedSnapshot >= scheduled.deadline else {
                break
            }

            // Run scheduled job
            scheduled.job()

            // Remove scheduled job
            _ = scheduledQueue.pop()

            lastCapturedSnapshot = captureNowSnapshot()
        }

        return lastCapturedSnapshot
    }

    private func scheduleNextRunIfNeeded(latestSnapshot: NIODeadline) {
        // It is important to run this as a separate task
        // to allow any tasks calling this to completely close out
        Task {
            await awaitPendingEntryOperations()

            if !jobQueue.isEmpty {
                // If there are items in the job queue, we need to run now
                runNextJobIfNeeded()
            } else if manualTimeMode && !scheduledQueue.isEmpty {
                // Under manual time we progress immediately instead of waiting for a wake‑up.
                runNextJobIfNeeded()
            } else if !scheduledQueue.isEmpty {
                // Schedule a wake-up at the next scheduled job time.
                scheduleWakeUp(nowSnapshot: latestSnapshot)
            } else {
                cancelScheduledWakeUp()
            }
        }
    }

    /// Schedules next run of jobs at or near the expected due date time for the next job.
    private func scheduleWakeUp(nowSnapshot: NIODeadline) {
        let shouldScheduleWakeUp = !manualTimeMode
        if shouldScheduleWakeUp, let nextScheduledTask = scheduledQueue.peek() {
            let interval = nextScheduledTask.deadline - nowSnapshot
            let nanoseconds = max(interval.nanoseconds, 0)
            wakeUpTask = Task { [weak self] in
                guard let self else { return }
                if nanoseconds > 0 {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(nanoseconds))
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                await self.run()
            }
        } else {
            cancelScheduledWakeUp()
        }
    }

    private func cancelScheduledWakeUp() {
        wakeUpTask?.cancel()
        wakeUpTask = nil
    }

    fileprivate func cancelScheduledJob(withID id: UUID) {
        scheduledQueue.removeFirst(where: { $0.id == id })
    }

    fileprivate func clearQueue() async {
        await awaitPendingEntryOperations()
        cancelScheduledWakeUp()
        pendingCancellationJobIDs.removeAll()
        await self.drainJobQueue()

        assert(jobQueue.isEmpty, "Job queue should become empty by this point")
        jobQueue.removeAll()

        // NOTE: Behavior in NIOPosix is to run all previously scheduled tasks as part
        // Refer to the `defer` block inside NIOPosix.SelectableEventLoop.run to find this behavior
        // The point in that code that calls failFn(EventLoopError._shutdown) calls fail
        // on the pending promises that are scheduled in the future.

        let finalDeadline = now
        while let scheduledJob = scheduledQueue.pop() {
            assert(scheduledJob.deadline > finalDeadline, "All remaining jobs should be in the future")
            scheduledJob.failFn(EventLoopError._shutdown)
        }

        await self.drainJobQueue()

        assert(jobQueue.isEmpty, "Job queue should become empty by this point")
        jobQueue.removeAll()
        cancelScheduledWakeUp()
        pendingCancellationJobIDs.removeAll()
    }

    private func drainJobQueue() async {
        while !jobQueue.isEmpty || currentlyRunningExecutorTask != nil {
            await run()
        }
    }

    private static func flooringSubtraction(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (partial, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard !overflow else { return UInt64.min }
        return partial
    }
}

extension EventLoopError {
    static let _shutdown: any Error = EventLoopError.shutdown
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension _AsyncEventLoopExecutor.ScheduledJob: Comparable {
    static func < (
        lhs: _AsyncEventLoopExecutor.ScheduledJob,
        rhs: _AsyncEventLoopExecutor.ScheduledJob
    ) -> Bool {
        if lhs.deadline == rhs.deadline {
            return lhs.order < rhs.order
        }
        return lhs.deadline < rhs.deadline
    }

    static func == (
        lhs: _AsyncEventLoopExecutor.ScheduledJob,
        rhs: _AsyncEventLoopExecutor.ScheduledJob
    ) -> Bool {
        lhs.id == rhs.id
    }
}

#endif  // os(WASI) || canImport(Testing)
