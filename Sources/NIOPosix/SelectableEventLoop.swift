//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
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
import Dispatch
import NIOConcurrencyHelpers
import NIOCore
import _NIODataStructures

/// Execute the given closure and ensure we release all auto pools if needed.
@inlinable
internal func withAutoReleasePool<T>(_ execute: () throws -> T) rethrows -> T {
    #if canImport(Darwin)
    return try autoreleasepool {
        try execute()
    }
    #else
    return try execute()
    #endif
}

/// Information about an EventLoop tick
public struct NIOEventLoopTickInfo: Sendable, Hashable {
    /// The eventloop which ticked
    public var eventLoopID: ObjectIdentifier
    /// The number of tasks which were executed in this tick
    public var numberOfTasks: Int
    /// The time at which the tick began
    public var startTime: NIODeadline

    internal init(eventLoopID: ObjectIdentifier, numberOfTasks: Int, startTime: NIODeadline) {
        self.eventLoopID = eventLoopID
        self.numberOfTasks = numberOfTasks
        self.startTime = startTime
    }
}

/// Implement this delegate to receive information about the EventLoop, such as each tick
public protocol NIOEventLoopMetricsDelegate: Sendable {
    /// Called after a tick has run
    /// This function is called after every tick - avoid long-running tasks here
    /// - Warning: This function is called after every event loop tick and on the event loop thread. Any non-trivial work in this function will block the event loop and cause latency increases and performance degradation.
    /// - Parameter info: Information about the tick, such as how many tasks were executed
    func processedTick(info: NIOEventLoopTickInfo)
}

/// `EventLoop` implementation that uses a `Selector` to get notified once there is more I/O or tasks to process.
/// The whole processing of I/O and tasks is done by a `NIOThread` that is tied to the `SelectableEventLoop`. This `NIOThread`
/// is guaranteed to never change!
@usableFromInline
internal final class SelectableEventLoop: EventLoop {

    static let strictModeEnabled: Bool = {
        switch getenv("SWIFTNIO_STRICT").map({ String.init(cString: $0).lowercased() }) {
        case "true", "y", "yes", "on", "1":
            return true
        default:
            return false
        }
    }()

    /// The different state in the lifecycle of an `EventLoop` seen from _outside_ the `EventLoop`.
    private enum ExternalState {
        /// `EventLoop` is open and so can process more work.
        case open
        /// `EventLoop` is currently in the process of closing.
        case closing
        /// `EventLoop` is closed.
        case closed
        /// `EventLoop` is closed and is currently trying to reclaim resources (such as the EventLoop thread).
        case reclaimingResources
        /// `EventLoop` is closed and all the resources (such as the EventLoop thread) have been reclaimed.
        case resourcesReclaimed
    }

    /// The different state in the lifecycle of an `EventLoop` seen from _inside_ the `EventLoop`.
    private enum InternalState {
        case runningAndAcceptingNewRegistrations
        case runningButNotAcceptingNewRegistrations
        case noLongerRunning
        case exitingThread
    }

    internal let _selector: NIOPosix.Selector<NIORegistration>
    private let thread: NIOThread
    @usableFromInline
    // _pendingTaskPop is set to `true` if the event loop is about to pop tasks off the task queue.
    // This may only be read/written while holding the _tasksLock.
    internal var _pendingTaskPop = false
    @usableFromInline
    internal var scheduledTaskCounter = ManagedAtomic<UInt64>(0)
    @usableFromInline
    internal var _scheduledTasks = PriorityQueue<ScheduledTask>()
    @usableFromInline
    internal var _immediateTasks = Deque<UnderlyingTask>()

    // We only need the ScheduledTask's task closure. However, an `Array<() -> Void>` allocates
    // for every appended closure. https://bugs.swift.org/browse/SR-15872
    private var tasksCopy = ContiguousArray<UnderlyingTask>()
    private static var tasksCopyBatchSize: Int {
        4096
    }

    @usableFromInline
    internal var _succeededVoidFuture: EventLoopFuture<Void>? = nil {
        didSet {
            self.assertInEventLoop()
        }
    }

    private let canBeShutdownIndividually: Bool
    @usableFromInline
    internal let _tasksLock = NIOLock()
    private let _externalStateLock = NIOLock()
    private var externalStateLock: NIOLock {
        // The assert is here to check that we never try to read the external state on the EventLoop unless we're
        // shutting down.
        assert(
            !self.inEventLoop || self.internalState != .runningAndAcceptingNewRegistrations,
            "lifecycle lock taken whilst up and running and in EventLoop"
        )
        return self._externalStateLock
    }
    // protected by the EventLoop thread
    private var internalState: InternalState = .runningAndAcceptingNewRegistrations
    // protected by externalStateLock
    private var externalState: ExternalState = .open

    let bufferPool: Pool<PooledBuffer>
    let msgBufferPool: Pool<PooledMsgBuffer>

    // The `_parentGroup` will always be set unless this is a thread takeover or we shut down.
    @usableFromInline
    internal var _parentGroup: Optional<MultiThreadedEventLoopGroup>

    /// Creates a new `SelectableEventLoop` instance that is tied to the given `pthread_t`.

    private let promiseCreationStoreLock = NIOLock()
    private var _promiseCreationStore: [_NIOEventLoopFutureIdentifier: (file: StaticString, line: UInt)] = [:]

    private let metricsDelegate: (any NIOEventLoopMetricsDelegate)?

    @usableFromInline
    internal func _promiseCreated(futureIdentifier: _NIOEventLoopFutureIdentifier, file: StaticString, line: UInt) {
        precondition(_isDebugAssertConfiguration())
        self.promiseCreationStoreLock.withLock {
            self._promiseCreationStore[futureIdentifier] = (file: file, line: line)
        }
    }

    @usableFromInline
    internal func _promiseCompleted(
        futureIdentifier: _NIOEventLoopFutureIdentifier
    ) -> (file: StaticString, line: UInt)? {
        precondition(_isDebugAssertConfiguration())
        return self.promiseCreationStoreLock.withLock {
            self._promiseCreationStore.removeValue(forKey: futureIdentifier)
        }
    }

    @usableFromInline
    internal func _preconditionSafeToWait(file: StaticString, line: UInt) {
        let explainer: () -> String = {
            """
            BUG DETECTED: wait() must not be called when on an EventLoop.
            Calling wait() on any EventLoop can lead to
            - deadlocks
            - stalling processing of other connections (Channels) that are handled on the EventLoop that wait was called on

            Further information:
            - current eventLoop: \(MultiThreadedEventLoopGroup.currentEventLoop.debugDescription)
            - event loop associated to future: \(self)
            """
        }
        precondition(!self.inEventLoop, explainer(), file: file, line: line)
        precondition(MultiThreadedEventLoopGroup.currentEventLoop == nil, explainer(), file: file, line: line)
    }

    @usableFromInline
    internal var _validInternalStateToScheduleTasks: Bool {
        switch self.internalState {
        case .exitingThread:
            return false
        case .runningAndAcceptingNewRegistrations, .runningButNotAcceptingNewRegistrations, .noLongerRunning:
            return true
        }
    }

    // access with `externalStateLock` held
    private var validExternalStateToScheduleTasks: Bool {
        switch self.externalState {
        case .open, .closing:
            return true
        case .closed, .reclaimingResources, .resourcesReclaimed:
            return false
        }
    }

    internal var testsOnly_validExternalStateToScheduleTasks: Bool {
        self.externalStateLock.withLock {
            self.validExternalStateToScheduleTasks
        }
    }

    internal init(
        thread: NIOThread,
        parentGroup: MultiThreadedEventLoopGroup?,  // nil iff thread take-over
        selector: NIOPosix.Selector<NIORegistration>,
        canBeShutdownIndividually: Bool,
        metricsDelegate: NIOEventLoopMetricsDelegate?
    ) {
        self.metricsDelegate = metricsDelegate
        self._parentGroup = parentGroup
        self._selector = selector
        self.thread = thread
        self.bufferPool = Pool<PooledBuffer>(maxSize: 16)
        self.msgBufferPool = Pool<PooledMsgBuffer>(maxSize: 16)
        self.tasksCopy.reserveCapacity(Self.tasksCopyBatchSize)
        self.canBeShutdownIndividually = canBeShutdownIndividually
        // note: We are creating a reference cycle here that we'll break when shutting the SelectableEventLoop down.
        // note: We have to create the promise and complete it because otherwise we'll hit a loop in `makeSucceededFuture`. This is
        //       fairly dumb, but it's the only option we have.
        let voidPromise = self.makePromise(of: Void.self)
        voidPromise.succeed(())
        self._succeededVoidFuture = voidPromise.futureResult
    }

    deinit {
        assert(
            self.internalState == .exitingThread,
            "illegal internal state on deinit: \(self.internalState)"
        )
        assert(
            self.externalState == .resourcesReclaimed,
            "illegal external state on shutdown: \(self.externalState)"
        )
    }

    /// Is this `SelectableEventLoop` still open (ie. not shutting down or shut down)
    internal var isOpen: Bool {
        self.assertInEventLoop()
        switch self.internalState {
        case .noLongerRunning, .runningButNotAcceptingNewRegistrations, .exitingThread:
            return false
        case .runningAndAcceptingNewRegistrations:
            return true
        }
    }

    /// Register the given `SelectableChannel` with this `SelectableEventLoop`. After this point all I/O for the `SelectableChannel` will be processed by this `SelectableEventLoop` until it
    /// is deregistered by calling `deregister`.
    internal func register<C: SelectableChannel>(channel: C) throws {
        self.assertInEventLoop()

        // Don't allow registration when we're closed.
        guard self.isOpen else {
            throw EventLoopError._shutdown
        }

        try channel.register(selector: self._selector, interested: channel.interestedEvent)
    }

    /// Deregister the given `SelectableChannel` from this `SelectableEventLoop`.
    internal func deregister<C: SelectableChannel>(channel: C, mode: CloseMode = .all) throws {
        self.assertInEventLoop()
        guard self.isOpen else {
            // It's possible the EventLoop was closed before we were able to call deregister, so just return in this case as there is no harm.
            return
        }

        try channel.deregister(selector: self._selector, mode: mode)
    }

    /// Register the given `SelectableChannel` with this `SelectableEventLoop`. This should be done whenever `channel.interestedEvents` has changed and it should be taken into account when
    /// waiting for new I/O for the given `SelectableChannel`.
    internal func reregister<C: SelectableChannel>(channel: C) throws {
        self.assertInEventLoop()

        try channel.reregister(selector: self._selector, interested: channel.interestedEvent)
    }

    /// - see: `EventLoop.inEventLoop`
    @usableFromInline
    internal var inEventLoop: Bool {
        thread.isCurrent
    }

    /// - see: `EventLoop.scheduleTask(deadline:_:)`
    @inlinable
    internal func scheduleTask<T>(deadline: NIODeadline, _ task: @escaping () throws -> T) -> Scheduled<T> {
        let promise: EventLoopPromise<T> = self.makePromise()
        let task = ScheduledTask(
            id: self.scheduledTaskCounter.loadThenWrappingIncrement(ordering: .relaxed),
            {
                do {
                    promise.succeed(try task())
                } catch let err {
                    promise.fail(err)
                }
            },
            { error in
                promise.fail(error)
            },
            deadline
        )

        let taskId = task.id
        let scheduled = Scheduled(
            promise: promise,
            cancellationTask: {
                self._tasksLock.withLock { () -> Void in
                    self._scheduledTasks.removeFirst(where: { $0.id == taskId })
                }
                // We don't need to wake up the selector here, the scheduled task will never be picked up. Waking up the
                // selector would mean that we may be able to recalculate the shutdown to a later date. The cost of not
                // doing the recalculation is one potentially unnecessary wakeup which is exactly what we're
                // saving here. So in the worst case, we didn't do a performance optimisation, in the best case, we saved
                // one wakeup.
            }
        )

        do {
            try self._schedule0(.scheduled(task))
        } catch {
            promise.fail(error)
        }

        return scheduled
    }

    /// - see: `EventLoop.scheduleTask(in:_:)`
    @inlinable
    internal func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws -> T) -> Scheduled<T> {
        scheduleTask(deadline: .now() + `in`, task)
    }

    // - see: `EventLoop.execute`
    @inlinable
    internal func execute(_ task: @escaping () -> Void) {
        // nothing we can do if we fail enqueuing here.
        try? self._schedule0(.immediate(.function(task)))
    }

    #if compiler(>=5.9)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @usableFromInline
    func enqueue(_ job: consuming ExecutorJob) {
        // nothing we can do if we fail enqueuing here.
        let erasedJob = ErasedUnownedJob(job: UnownedJob(job))
        try? self._schedule0(.immediate(.unownedJob(erasedJob)))
    }
    #endif

    /// Add the `ScheduledTask` to be executed.
    @usableFromInline
    internal func _schedule0(_ task: LoopTask) throws {
        if self.inEventLoop {
            precondition(
                self._validInternalStateToScheduleTasks,
                "BUG IN NIO (please report): EventLoop is shutdown, yet we're on the EventLoop."
            )

            self._tasksLock.withLock { () -> Void in
                switch task {
                case .scheduled(let task):
                    self._scheduledTasks.push(task)
                case .immediate(let task):
                    self._immediateTasks.append(task)
                }
            }
        } else {
            let shouldWakeSelector: Bool = self.externalStateLock.withLock {
                guard self.validExternalStateToScheduleTasks else {
                    if Self.strictModeEnabled {
                        fatalError("Cannot schedule tasks on an EventLoop that has already shut down.")
                    }
                    fputs(
                        """
                        ERROR: Cannot schedule tasks on an EventLoop that has already shut down. \
                        This will be upgraded to a forced crash in future SwiftNIO versions.\n
                        """,
                        stderr
                    )
                    return false
                }

                return self._tasksLock.withLock {
                    switch task {
                    case .scheduled(let task):
                        self._scheduledTasks.push(task)
                    case .immediate(let task):
                        self._immediateTasks.append(task)
                    }

                    if self._pendingTaskPop == false {
                        // Our job to wake the selector.
                        self._pendingTaskPop = true
                        return true
                    } else {
                        // There is already an event-loop-tick scheduled, we don't need to wake the selector.
                        return false
                    }
                }
            }

            // We only need to wake up the selector if we're not in the EventLoop. If we're in the EventLoop already, we're
            // either doing IO tasks (which happens before checking the scheduled tasks) or we're running a scheduled task
            // already which means that we'll check at least once more if there are other scheduled tasks runnable. While we
            // had the task lock we also checked whether the loop was _already_ going to be woken. This saves us a syscall on
            // hot loops.
            //
            // In the future we'll use an MPSC queue here and that will complicate things, so we may get some spurious wakeups,
            // but as long as we're using the big dumb lock we can make this optimization safely.
            if shouldWakeSelector {
                try self._wakeupSelector()
            }
        }
    }

    /// Wake the `Selector` which means `Selector.whenReady(...)` will unblock.
    @usableFromInline
    internal func _wakeupSelector() throws {
        try _selector.wakeup()
    }

    /// Handle the given `SelectorEventSet` for the `SelectableChannel`.
    internal final func handleEvent<C: SelectableChannel>(_ ev: SelectorEventSet, channel: C) {
        guard channel.isOpen else {
            return
        }

        // process resets first as they'll just cause the writes to fail anyway.
        if ev.contains(.reset) {
            channel.reset()
        } else {
            if ev.contains(.writeEOF) {
                channel.writeEOF()

                guard channel.isOpen else {
                    return
                }
            } else if ev.contains(.write) {
                channel.writable()

                guard channel.isOpen else {
                    return
                }
            }

            if ev.contains(.readEOF) {
                channel.readEOF()
            } else if ev.contains(.read) {
                channel.readable()
            }
        }
    }

    private func currentSelectorStrategy(nextReadyDeadline: NIODeadline?) -> SelectorStrategy {
        guard let deadline = nextReadyDeadline else {
            // No tasks to handle so just block. If any tasks were added in the meantime wakeup(...) was called and so this
            // will directly unblock.
            return .block
        }

        let nextReady = deadline.readyIn(.now())
        if nextReady <= .nanoseconds(0) {
            // Something is ready to be processed just do a non-blocking select of events.
            return .now
        } else {
            return .blockUntilTimeout(nextReady)
        }
    }

    private func run(_ task: UnderlyingTask) {
        // for macOS: in case any calls we make to Foundation put objects into an autoreleasepool
        withAutoReleasePool {
            switch task {
            case .function(let function):
                function()
            #if compiler(>=5.9)
            case .unownedJob(let erasedUnownedJob):
                if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
                    erasedUnownedJob.unownedJob.runSynchronously(on: self.asUnownedSerialExecutor())
                } else {
                    fatalError("Tried to run an UnownedJob without runtime support")
                }
            #endif
            case .callback(let handler):
                handler.handleScheduledCallback(eventLoop: self)
            }
        }
    }

    private static func _popTasksLockedAssertInvariants(
        immediateTasks: Deque<UnderlyingTask>,
        scheduledTasks: PriorityQueue<ScheduledTask>,
        tasksCopy: ContiguousArray<UnderlyingTask>,
        tasksCopyBatchSize: Int,
        now: NIODeadline,
        nextDeadline: NIODeadline
    ) {
        assert(tasksCopy.count <= tasksCopyBatchSize)
        // When we exit the loop, we would expect to
        // * have taskCopy full, or:
        // * to have completely drained task queues
        //     * that means all immediateTasks, and:
        //     * all scheduledTasks that are ready
        assertExpression {
            if tasksCopy.count == tasksCopyBatchSize {
                return true
            }

            if !immediateTasks.isEmpty {
                return false
            }

            guard let nextScheduledTask = scheduledTasks.peek() else {
                return true
            }

            return nextScheduledTask.readyTime.readyIn(now) > .nanoseconds(0)
        }

        //  nextDeadline must be set to now if there are more immediate tasks left
        assertExpression {
            if immediateTasks.count == 0 {
                return true
            }

            return nextDeadline == now
        }

        // nextDeadline should be set to != now, iff there are more
        // scheduled tasks, and they are all scheduled for the future
        // Moreover, nextDeadline must equal the expiry time for the
        // "top-most" scheduled task
        assertExpression {
            if nextDeadline == now {
                return true
            }

            guard let topMostScheduledTask = scheduledTasks.peek() else {
                return false
            }

            return topMostScheduledTask.readyTime == nextDeadline
        }
    }

    private static func _popTasksLocked(
        immediateTasks: inout Deque<UnderlyingTask>,
        scheduledTasks: inout PriorityQueue<ScheduledTask>,
        tasksCopy: inout ContiguousArray<UnderlyingTask>,
        tasksCopyBatchSize: Int
    ) -> NIODeadline? {
        // We expect empty tasksCopy, to put a new batch of tasks into
        assert(tasksCopy.isEmpty)

        var moreImmediateTasksToConsider = !immediateTasks.isEmpty
        var moreScheduledTasksToConsider = !scheduledTasks.isEmpty

        guard moreImmediateTasksToConsider || moreScheduledTasksToConsider else {
            // Reset nextReadyDeadline to nil which means we will do a blocking select.
            return nil
        }

        // We only fetch the time one time as this may be expensive and is generally good enough as if we miss anything we will just do a non-blocking select again anyway.
        let now: NIODeadline = .now()
        var nextScheduledTaskDeadline = now

        while moreImmediateTasksToConsider || moreScheduledTasksToConsider {
            // We pick one item from immediateTasks & scheduledTask per iteration of the loop.
            // This prevents one task queue starving the other.
            if moreImmediateTasksToConsider, tasksCopy.count < tasksCopyBatchSize, let task = immediateTasks.popFirst()
            {
                tasksCopy.append(task)
            } else {
                moreImmediateTasksToConsider = false
            }

            if moreScheduledTasksToConsider, tasksCopy.count < tasksCopyBatchSize, let task = scheduledTasks.peek() {
                if task.readyTime.readyIn(now) <= .nanoseconds(0) {
                    scheduledTasks.pop()
                    switch task.kind {
                    case .task(let task, _): tasksCopy.append(.function(task))
                    case .callback(let handler): tasksCopy.append(.callback(handler))
                    }
                } else {
                    nextScheduledTaskDeadline = task.readyTime
                    moreScheduledTasksToConsider = false
                }
            } else {
                moreScheduledTasksToConsider = false
            }
        }

        let nextDeadline = immediateTasks.count > 0 ? now : nextScheduledTaskDeadline
        debugOnly {
            // The asserts are spun off to a separate functions to aid code clarity
            // and to remove mutable access to certain structures, e.g. `immediateTasks`.
            Self._popTasksLockedAssertInvariants(
                immediateTasks: immediateTasks,
                scheduledTasks: scheduledTasks,
                tasksCopy: tasksCopy,
                tasksCopyBatchSize: tasksCopyBatchSize,
                now: now,
                nextDeadline: nextDeadline
            )
        }

        return nextDeadline
    }

    private func runLoop(selfIdentifier: ObjectIdentifier) -> NIODeadline? {
        let tickStartTime: NIODeadline = .now()
        var tasksProcessedInTick = 0
        defer {
            let tickInfo = NIOEventLoopTickInfo(
                eventLoopID: selfIdentifier,
                numberOfTasks: tasksProcessedInTick,
                startTime: tickStartTime
            )
            self.metricsDelegate?.processedTick(info: tickInfo)
        }
        while true {
            let nextReadyDeadline = self._tasksLock.withLock { () -> NIODeadline? in
                let deadline = Self._popTasksLocked(
                    immediateTasks: &self._immediateTasks,
                    scheduledTasks: &self._scheduledTasks,
                    tasksCopy: &self.tasksCopy,
                    tasksCopyBatchSize: Self.tasksCopyBatchSize
                )
                if self.tasksCopy.isEmpty {
                    // Rare, but it's possible to find no tasks to execute if all scheduled tasks are expiring in the future.
                    self._pendingTaskPop = false
                }
                return deadline
            }

            // all pending tasks are set to occur in the future, so we can stop looping.
            if self.tasksCopy.isEmpty {
                return nextReadyDeadline
            }

            // Execute all the tasks that were submitted
            let (partialTotal, totalOverflowed) = tasksProcessedInTick.addingReportingOverflow(self.tasksCopy.count)
            if totalOverflowed {
                tasksProcessedInTick = Int.max
            } else {
                tasksProcessedInTick = partialTotal
            }
            for task in self.tasksCopy {
                self.run(task)
            }
            // Drop everything (but keep the capacity) so we can fill it again on the next iteration.
            self.tasksCopy.removeAll(keepingCapacity: true)
        }
    }

    /// Start processing I/O and tasks for this `SelectableEventLoop`. This method will continue running (and so block) until the `SelectableEventLoop` is closed.
    internal func run() throws {
        self.preconditionInEventLoop()
        defer {
            var iterations = 0
            var drained = false
            var scheduledTasksCopy = ContiguousArray<ScheduledTask>()
            var immediateTasksCopy = Deque<UnderlyingTask>()
            repeat {  // We may need to do multiple rounds of this because failing tasks may lead to more work.
                self._tasksLock.withLock {
                    // In this state we never want the selector to be woken again, so we pretend we're permanently running.
                    self._pendingTaskPop = true

                    // reserve the correct capacity so we don't need to realloc later on.
                    scheduledTasksCopy.reserveCapacity(self._scheduledTasks.count)
                    while let sched = self._scheduledTasks.pop() {
                        scheduledTasksCopy.append(sched)
                    }
                    swap(&immediateTasksCopy, &self._immediateTasks)
                }

                // Run all the immediate tasks. They're all "expired" and don't have failFn,
                // therefore the best course of action is to run them.
                for task in immediateTasksCopy {
                    self.run(task)
                }
                for task in scheduledTasksCopy {
                    switch task.kind {
                    // Fail all the scheduled tasks.
                    case .task(_, let failFn):
                        failFn(EventLoopError._shutdown)
                    // Call the cancellation handler for all the scheduled callbacks.
                    case .callback(let handler):
                        handler.didCancelScheduledCallback(eventLoop: self)
                    }
                }

                iterations += 1
                drained = immediateTasksCopy.count == 0 && scheduledTasksCopy.count == 0
                immediateTasksCopy.removeAll(keepingCapacity: true)
                scheduledTasksCopy.removeAll(keepingCapacity: true)
            } while !drained && iterations < 1000
            precondition(drained, "EventLoop \(self) didn't quiesce after 1000 ticks.")

            assert(self.internalState == .noLongerRunning, "illegal state: \(self.internalState)")
            self.internalState = .exitingThread
        }
        var nextReadyDeadline: NIODeadline? = nil
        self._tasksLock.withLock {
            if let firstScheduledTask = self._scheduledTasks.peek() {
                // The reason this is necessary is a very interesting race:
                // In theory (and with `makeEventLoopFromCallingThread` even in practise), we could publish an
                // `EventLoop` reference _before_ the EL thread has entered the `run` function.
                // If that is the case, we need to schedule the first wakeup at the ready time for this task that was
                // enqueued really early on, so let's do that :).
                nextReadyDeadline = firstScheduledTask.readyTime
            }
            if !self._immediateTasks.isEmpty {
                nextReadyDeadline = NIODeadline.now()
            }
        }
        let selfIdentifier = ObjectIdentifier(self)
        while self.internalState != .noLongerRunning && self.internalState != .exitingThread {
            // Block until there are events to handle or the selector was woken up
            // for macOS: in case any calls we make to Foundation put objects into an autoreleasepool
            try withAutoReleasePool {
                try self._selector.whenReady(
                    strategy: currentSelectorStrategy(nextReadyDeadline: nextReadyDeadline),
                    onLoopBegin: { self._tasksLock.withLock { () -> Void in self._pendingTaskPop = true } }
                ) { ev in
                    switch ev.registration.channel {
                    case .serverSocketChannel(let chan):
                        self.handleEvent(ev.io, channel: chan)
                    case .socketChannel(let chan):
                        self.handleEvent(ev.io, channel: chan)
                    case .datagramChannel(let chan):
                        self.handleEvent(ev.io, channel: chan)
                    case .pipeChannel(let chan, let direction):
                        var ev = ev
                        if ev.io.contains(.reset) {
                            // .reset needs special treatment here because we're dealing with two separate pipes instead
                            // of one socket. So we turn .reset input .readEOF/.writeEOF.
                            ev.io.subtract([.reset])
                            ev.io.formUnion([direction == .input ? .readEOF : .writeEOF])
                        }
                        self.handleEvent(ev.io, channel: chan)
                    }
                }
            }
            nextReadyDeadline = runLoop(selfIdentifier: selfIdentifier)
        }

        // This EventLoop was closed so also close the underlying selector.
        try self._selector.close()

        // This breaks the retain cycle created in `init`.
        self._succeededVoidFuture = nil
    }

    internal func initiateClose(queue: DispatchQueue, completionHandler: @escaping (Result<Void, Error>) -> Void) {
        func doClose() {
            self.assertInEventLoop()
            self._parentGroup = nil  // break the cycle
            // There should only ever be one call into this function so we need to be up and running, ...
            assert(self.internalState == .runningAndAcceptingNewRegistrations)
            self.internalState = .runningButNotAcceptingNewRegistrations

            self.externalStateLock.withLock {
                // ... but before this call happened, the lifecycle state should have been changed on some other thread.
                assert(self.externalState == .closing)
            }

            self._selector.closeGently(eventLoop: self).whenComplete { result in
                self.assertInEventLoop()
                assert(self.internalState == .runningButNotAcceptingNewRegistrations)
                self.internalState = .noLongerRunning
                self.execute {}  // force a new event loop tick, so the event loop definitely stops looping very soon.
                self.externalStateLock.withLock {
                    assert(self.externalState == .closing)
                    self.externalState = .closed
                }
                queue.async {
                    completionHandler(result)
                }
            }
        }
        if self.inEventLoop {
            queue.async {
                self.initiateClose(queue: queue, completionHandler: completionHandler)
            }
        } else {
            let goAhead = self.externalStateLock.withLock { () -> Bool in
                if self.externalState == .open {
                    self.externalState = .closing
                    return true
                } else {
                    return false
                }
            }
            guard goAhead else {
                queue.async {
                    completionHandler(Result.failure(EventLoopError._shutdown))
                }
                return
            }
            self.execute {
                doClose()
            }
        }
    }

    internal func syncFinaliseClose(joinThread: Bool) {
        // This may not be true in the future but today we need to join all ELs that can't be shut down individually.
        assert(joinThread != self.canBeShutdownIndividually)
        let goAhead = self.externalStateLock.withLock { () -> Bool in
            switch self.externalState {
            case .closed:
                self.externalState = .reclaimingResources
                return true
            case .resourcesReclaimed, .reclaimingResources:
                return false
            default:
                preconditionFailure("illegal lifecycle state in syncFinaliseClose: \(self.externalState)")
            }
        }
        guard goAhead else {
            return
        }
        if joinThread {
            self.thread.join()
        }
        self.externalStateLock.withLock {
            precondition(self.externalState == .reclaimingResources)
            self.externalState = .resourcesReclaimed
        }
    }

    @usableFromInline
    func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        if self.canBeShutdownIndividually {
            self.initiateClose(queue: queue) { result in
                self.syncFinaliseClose(joinThread: false)  // This thread was taken over by somebody else
                switch result {
                case .success:
                    callback(nil)
                case .failure(let error):
                    callback(error)
                }
            }
        } else {
            // This function is never called legally because the only possibly owner of an `SelectableEventLoop` is
            // `MultiThreadedEventLoopGroup` which calls `initiateClose` followed by `syncFinaliseClose`.
            queue.async {
                callback(EventLoopError._unsupportedOperation)
            }
        }
    }

    @inlinable
    public func makeSucceededVoidFuture() -> EventLoopFuture<Void> {
        guard self.inEventLoop, let voidFuture = self._succeededVoidFuture else {
            // We have to create the promise and complete it because otherwise we'll hit a loop in `makeSucceededFuture`. This is
            // fairly dumb, but it's the only option we have. This one can only happen after the loop is shut down, or when calling from off the loop.
            let voidPromise = self.makePromise(of: Void.self)
            voidPromise.succeed(())
            return voidPromise.futureResult
        }
        return voidFuture
    }

    @inlinable
    internal func parentGroupCallableFromThisEventLoopOnly() -> MultiThreadedEventLoopGroup? {
        self.assertInEventLoop()
        return self._parentGroup
    }
}

extension SelectableEventLoop: CustomStringConvertible, CustomDebugStringConvertible {
    @usableFromInline
    var description: String {
        "SelectableEventLoop { selector = \(self._selector), thread = \(self.thread) }"
    }

    @usableFromInline
    var debugDescription: String {
        self._tasksLock.withLock {
            "SelectableEventLoop { selector = \(self._selector), thread = \(self.thread), scheduledTasks = \(self._scheduledTasks.description) }"
        }
    }
}

// MARK: SerialExecutor conformance
#if compiler(>=5.9)
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension SelectableEventLoop: NIOSerialEventLoopExecutor {}
#endif

@usableFromInline
enum UnderlyingTask {
    case function(() -> Void)
    #if compiler(>=5.9)
    case unownedJob(ErasedUnownedJob)
    #endif
    case callback(any NIOScheduledCallbackHandler)
}

@usableFromInline
internal enum LoopTask {
    case scheduled(ScheduledTask)
    case immediate(UnderlyingTask)
}

@inlinable
internal func assertExpression(_ body: () -> Bool) {
    assert(
        {
            body()
        }()
    )
}

extension SelectableEventLoop {
    @inlinable
    func scheduleCallback(
        at deadline: NIODeadline,
        handler: some NIOScheduledCallbackHandler
    ) throws -> NIOScheduledCallback {
        let taskID = self.scheduledTaskCounter.loadThenWrappingIncrement(ordering: .relaxed)
        let task = ScheduledTask(id: taskID, handler, deadline)
        try self._schedule0(.scheduled(task))
        return NIOScheduledCallback(self, id: taskID)
    }

    @inlinable
    func cancelScheduledCallback(_ scheduledCallback: NIOScheduledCallback) {
        guard let id = scheduledCallback.customCallbackID else {
            preconditionFailure("No custom ID for callback")
        }
        self._tasksLock.withLock {
            guard let scheduledTask = self._scheduledTasks.removeFirst(where: { $0.id == id }) else {
                // Must have been cancelled already.
                return
            }
            guard case .callback(let handler) = scheduledTask.kind else {
                preconditionFailure("Incorrect task kind for callback")
            }
            handler.didCancelScheduledCallback(eventLoop: self)
        }
    }
}
