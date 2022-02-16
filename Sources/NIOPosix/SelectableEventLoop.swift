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

import Dispatch
import NIOCore
import NIOConcurrencyHelpers
import _NIODataStructures

/// Execute the given closure and ensure we release all auto pools if needed.
@inlinable
internal func withAutoReleasePool<T>(_ execute: () throws -> T) rethrows -> T {
#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
    return try autoreleasepool {
        try execute()
    }
#else
    return try execute()
#endif
}

/// `EventLoop` implementation that uses a `Selector` to get notified once there is more I/O or tasks to process.
/// The whole processing of I/O and tasks is done by a `NIOThread` that is tied to the `SelectableEventLoop`. This `NIOThread`
/// is guaranteed to never change!
@usableFromInline
internal final class SelectableEventLoop: EventLoop {
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

    /* private but tests */ internal let _selector: NIOPosix.Selector<NIORegistration>
    private let thread: NIOThread
    @usableFromInline
    // _pendingTaskPop is set to `true` if the event loop is about to pop tasks off the task queue.
    // This may only be read/written while holding the _tasksLock.
    internal var _pendingTaskPop = false
    @usableFromInline
    internal var scheduledTaskCounter = NIOAtomic.makeAtomic(value: UInt64(0))
    @usableFromInline
    internal var _scheduledTasks = PriorityQueue<ScheduledTask>()

    // We only need the ScheduledTask's task closure. However, an `Array<() -> Void>` allocates
    // for every appended closure. https://bugs.swift.org/browse/SR-15872
    private var tasksCopy = ContiguousArray<ScheduledTask>()
    @usableFromInline
    internal var _succeededVoidFuture: Optional<EventLoopFuture<Void>> = nil {
        didSet {
            self.assertInEventLoop()
        }
    }

    private let canBeShutdownIndividually: Bool
    @usableFromInline
    internal let _tasksLock = Lock()
    private let _externalStateLock = Lock()
    private var externalStateLock: Lock {
        // The assert is here to check that we never try to read the external state on the EventLoop unless we're
        // shutting down.
        assert(!self.inEventLoop || self.internalState != .runningAndAcceptingNewRegistrations,
               "lifecycle lock taken whilst up and running and in EventLoop")
        return self._externalStateLock
    }
    private var internalState: InternalState = .runningAndAcceptingNewRegistrations // protected by the EventLoop thread
    private var externalState: ExternalState = .open // protected by externalStateLock

    private let _iovecs: UnsafeMutablePointer<IOVector>
    private let _storageRefs: UnsafeMutablePointer<Unmanaged<AnyObject>>

    let iovecs: UnsafeMutableBufferPointer<IOVector>
    let storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>

    // Used for gathering UDP writes.
    private let _msgs: UnsafeMutablePointer<MMsgHdr>
    private let _addresses: UnsafeMutablePointer<sockaddr_storage>
    let msgs: UnsafeMutableBufferPointer<MMsgHdr>
    let addresses: UnsafeMutableBufferPointer<sockaddr_storage>
    
    // Used for UDP control messages.
    private(set) var controlMessageStorage: UnsafeControlMessageStorage

    // The `_parentGroup` will always be set unless this is a thread takeover or we shut down.
    @usableFromInline
    internal var _parentGroup: Optional<MultiThreadedEventLoopGroup>

    /// Creates a new `SelectableEventLoop` instance that is tied to the given `pthread_t`.

    private let promiseCreationStoreLock = Lock()
    private var _promiseCreationStore: [_NIOEventLoopFutureIdentifier: (file: StaticString, line: UInt)] = [:]

    @usableFromInline
    internal func _promiseCreated(futureIdentifier: _NIOEventLoopFutureIdentifier, file: StaticString, line: UInt) {
        precondition(_isDebugAssertConfiguration())
        self.promiseCreationStoreLock.withLock {
            self._promiseCreationStore[futureIdentifier] = (file: file, line: line)
        }
    }

    @usableFromInline
    internal func _promiseCompleted(futureIdentifier: _NIOEventLoopFutureIdentifier) -> (file: StaticString, line: UInt)? {
        precondition(_isDebugAssertConfiguration())
        return self.promiseCreationStoreLock.withLock {
            self._promiseCreationStore.removeValue(forKey: futureIdentifier)
        }
    }

    @usableFromInline
    internal func _preconditionSafeToWait(file: StaticString, line: UInt) {
        let explainer: () -> String = { """
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
        return self.externalStateLock.withLock {
            return self.validExternalStateToScheduleTasks
        }
    }

    internal init(thread: NIOThread,
                  parentGroup: MultiThreadedEventLoopGroup?, /* nil iff thread take-over */
                  selector: NIOPosix.Selector<NIORegistration>,
                  canBeShutdownIndividually: Bool) {
        self._parentGroup = parentGroup
        self._selector = selector
        self.thread = thread
        self._iovecs = UnsafeMutablePointer.allocate(capacity: Socket.writevLimitIOVectors)
        self._storageRefs = UnsafeMutablePointer.allocate(capacity: Socket.writevLimitIOVectors)
        self.iovecs = UnsafeMutableBufferPointer(start: self._iovecs, count: Socket.writevLimitIOVectors)
        self.storageRefs = UnsafeMutableBufferPointer(start: self._storageRefs, count: Socket.writevLimitIOVectors)
        self._msgs = UnsafeMutablePointer.allocate(capacity: Socket.writevLimitIOVectors)
        self._addresses = UnsafeMutablePointer.allocate(capacity: Socket.writevLimitIOVectors)
        self.msgs = UnsafeMutableBufferPointer(start: _msgs, count: Socket.writevLimitIOVectors)
        self.addresses = UnsafeMutableBufferPointer(start: _addresses, count: Socket.writevLimitIOVectors)
        self.controlMessageStorage = UnsafeControlMessageStorage.allocate(msghdrCount: Socket.writevLimitIOVectors)
        // We will process 4096 tasks per while loop.
        self.tasksCopy.reserveCapacity(4096)
        self.canBeShutdownIndividually = canBeShutdownIndividually
        // note: We are creating a reference cycle here that we'll break when shutting the SelectableEventLoop down.
        // note: We have to create the promise and complete it because otherwise we'll hit a loop in `makeSucceededFuture`. This is
        //       fairly dumb, but it's the only option we have.
        let voidPromise = self.makePromise(of: Void.self)
        voidPromise.succeed(())
        self._succeededVoidFuture = voidPromise.futureResult
    }

    deinit {
        assert(self.internalState == .exitingThread,
               "illegal internal state on deinit: \(self.internalState)")
        assert(self.externalState == .resourcesReclaimed,
               "illegal external state on shutdown: \(self.externalState)")
        _iovecs.deallocate()
        _storageRefs.deallocate()
        _msgs.deallocate()
        _addresses.deallocate()
        self.controlMessageStorage.deallocate()
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
            throw EventLoopError.shutdown
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
        return thread.isCurrent
    }

    /// - see: `EventLoop.scheduleTask(deadline:_:)`
    @inlinable
    internal func scheduleTask<T>(deadline: NIODeadline, _ task: @escaping () throws -> T) -> Scheduled<T> {
        let promise: EventLoopPromise<T> = self.makePromise()
        let task = ScheduledTask(id: self.scheduledTaskCounter.add(1), {
            do {
                promise.succeed(try task())
            } catch let err {
                promise.fail(err)
            }
        }, { error in
            promise.fail(error)
        }, deadline)

        let taskId = task.id
        let scheduled = Scheduled(promise: promise, cancellationTask: {
            self._tasksLock.withLockVoid {
                self._scheduledTasks.removeFirst(where: { $0.id == taskId })
            }
            // We don't need to wake up the selector here, the scheduled task will never be picked up. Waking up the
            // selector would mean that we may be able to recalculate the shutdown to a later date. The cost of not
            // doing the recalculation is one potentially unnecessary wakeup which is exactly what we're
            // saving here. So in the worst case, we didn't do a performance optimisation, in the best case, we saved
            // one wakeup.
        })

        do {
            try self._schedule0(task)
        } catch {
            promise.fail(error)
        }

        return scheduled
    }

    /// - see: `EventLoop.scheduleTask(in:_:)`
    @inlinable
    internal func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws -> T) -> Scheduled<T> {
        return scheduleTask(deadline: .now() + `in`, task)
    }

    // - see: `EventLoop.execute`
    @inlinable
    internal func execute(_ task: @escaping () -> Void) {
        // nothing we can do if we fail enqueuing here.
        try? self._schedule0(ScheduledTask(id: self.scheduledTaskCounter.add(1), task, { error in
            // do nothing
        }, .now()))
    }

    /// Add the `ScheduledTask` to be executed.
    @usableFromInline
    internal func _schedule0(_ task: ScheduledTask) throws {
        if self.inEventLoop {
            precondition(self._validInternalStateToScheduleTasks,
                         "BUG IN NIO (please report): EventLoop is shutdown, yet we're on the EventLoop.")

            self._tasksLock.withLockVoid {
                self._scheduledTasks.push(task)
            }
        } else {
            let shouldWakeSelector: Bool = self.externalStateLock.withLock {
                guard self.validExternalStateToScheduleTasks else {
                    print("ERROR: Cannot schedule tasks on an EventLoop that has already shut down. " +
                          "This will be upgraded to a forced crash in future SwiftNIO versions.")
                    return false
                }

                return self._tasksLock.withLock {
                    self._scheduledTasks.push(task)

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

    private func currentSelectorStrategy(nextReadyTask: ScheduledTask?) -> SelectorStrategy {
        guard let sched = nextReadyTask else {
            // No tasks to handle so just block. If any tasks were added in the meantime wakeup(...) was called and so this
            // will directly unblock.
            return .block
        }

        let nextReady = sched.readyIn(.now())
        if nextReady <= .nanoseconds(0) {
            // Something is ready to be processed just do a non-blocking select of events.
            return .now
        } else {
            return .blockUntilTimeout(nextReady)
        }
    }

    /// Start processing I/O and tasks for this `SelectableEventLoop`. This method will continue running (and so block) until the `SelectableEventLoop` is closed.
    internal func run() throws {
        self.preconditionInEventLoop()
        defer {
            var scheduledTasksCopy = ContiguousArray<ScheduledTask>()
            var iterations = 0
            repeat { // We may need to do multiple rounds of this because failing tasks may lead to more work.
                scheduledTasksCopy.removeAll(keepingCapacity: true)

                self._tasksLock.withLockVoid {
                    // In this state we never want the selector to be woken again, so we pretend we're permanently running.
                    self._pendingTaskPop = true

                    // reserve the correct capacity so we don't need to realloc later on.
                    scheduledTasksCopy.reserveCapacity(self._scheduledTasks.count)
                    while let sched = self._scheduledTasks.pop() {
                        scheduledTasksCopy.append(sched)
                    }
                }

                // Fail all the scheduled tasks.
                for task in scheduledTasksCopy {
                    task.fail(EventLoopError.shutdown)
                }
                iterations += 1
            } while scheduledTasksCopy.count > 0 && iterations < 1000
            precondition(scheduledTasksCopy.count == 0, "EventLoop \(self) didn't quiesce after 1000 ticks.")

            assert(self.internalState == .noLongerRunning, "illegal state: \(self.internalState)")
            self.internalState = .exitingThread
        }
        var nextReadyTask: ScheduledTask? = nil
        self._tasksLock.withLock {
            if let firstTask = self._scheduledTasks.peek() {
                // The reason this is necessary is a very interesting race:
                // In theory (and with `makeEventLoopFromCallingThread` even in practise), we could publish an
                // `EventLoop` reference _before_ the EL thread has entered the `run` function.
                // If that is the case, we need to schedule the first wakeup at the ready time for this task that was
                // enqueued really early on, so let's do that :).
                nextReadyTask = firstTask
            }
        }
        while self.internalState != .noLongerRunning && self.internalState != .exitingThread {
            // Block until there are events to handle or the selector was woken up
            /* for macOS: in case any calls we make to Foundation put objects into an autoreleasepool */
            try withAutoReleasePool {
                try self._selector.whenReady(
                    strategy: currentSelectorStrategy(nextReadyTask: nextReadyTask),
                    onLoopBegin: { self._tasksLock.withLockVoid { self._pendingTaskPop = true } }
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

            // We need to ensure we process all tasks, even if a task added another task again
            while true {
                // TODO: Better locking
                self._tasksLock.withLockVoid {
                    if !self._scheduledTasks.isEmpty {
                        // We only fetch the time one time as this may be expensive and is generally good enough as if we miss anything we will just do a non-blocking select again anyway.
                        let now: NIODeadline = .now()

                        // Make a copy of the tasks so we can execute these while not holding the lock anymore
                        while tasksCopy.count < tasksCopy.capacity, let task = self._scheduledTasks.peek() {
                            if task.readyIn(now) <= .nanoseconds(0) {
                                self._scheduledTasks.pop()
                                self.tasksCopy.append(task)
                            } else {
                                nextReadyTask = task
                                break
                            }
                        }
                    } else {
                        // Reset nextReadyTask to nil which means we will do a blocking select.
                        nextReadyTask = nil
                    }

                    if self.tasksCopy.isEmpty {
                        // We will not continue to loop here. We need to be woken if a new task is enqueued.
                        self._pendingTaskPop = false
                    }
                }

                // all pending tasks are set to occur in the future, so we can stop looping.
                if self.tasksCopy.isEmpty {
                    break
                }

                // Execute all the tasks that were submitted
                for task in self.tasksCopy {
                    /* for macOS: in case any calls we make to Foundation put objects into an autoreleasepool */
                    withAutoReleasePool {
                        task.task()
                    }
                }
                // Drop everything (but keep the capacity) so we can fill it again on the next iteration.
                self.tasksCopy.removeAll(keepingCapacity: true)
            }
        }

        // This EventLoop was closed so also close the underlying selector.
        try self._selector.close()

        // This breaks the retain cycle created in `init`.
        self._succeededVoidFuture = nil
    }

    internal func initiateClose(queue: DispatchQueue, completionHandler: @escaping (Result<Void, Error>) -> Void) {
        func doClose() {
            self.assertInEventLoop()
            self._parentGroup = nil // break the cycle
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
                self.execute {} // force a new event loop tick, so the event loop definitely stops looping very soon.
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
                    completionHandler(Result.failure(EventLoopError.shutdown))
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
                self.syncFinaliseClose(joinThread: false) // This thread was taken over by somebody else
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
                callback(EventLoopError.unsupportedOperation)
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
        return "SelectableEventLoop { selector = \(self._selector), thread = \(self.thread) }"
    }

    @usableFromInline
    var debugDescription: String {
        return self._tasksLock.withLock {
            return "SelectableEventLoop { selector = \(self._selector), thread = \(self.thread), scheduledTasks = \(self._scheduledTasks.description) }"
        }
    }
}
