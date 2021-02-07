//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import NIOConcurrencyHelpers

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

    /* private but tests */ internal let _selector: NIO.Selector<NIORegistration>
    private let thread: NIOThread
    @usableFromInline
    internal var _scheduledTasks = PriorityQueue<ScheduledTask>()
    private var tasksCopy = ContiguousArray<() -> Void>()
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

    /// Creates a new `SelectableEventLoop` instance that is tied to the given `pthread_t`.

    private let promiseCreationStoreLock = Lock()
    private var _promiseCreationStore: [UInt: (file: StaticString, line: UInt)] = [:]

    @usableFromInline
    internal func promiseCreationStoreAdd<T>(future: EventLoopFuture<T>, file: StaticString, line: UInt) {
        precondition(_isDebugAssertConfiguration())
        self.promiseCreationStoreLock.withLock {
            self._promiseCreationStore[self.obfuscatePointerValue(future)] = (file: file, line: line)
        }
    }

    internal func promiseCreationStoreRemove<T>(future: EventLoopFuture<T>) -> (file: StaticString, line: UInt) {
        precondition(_isDebugAssertConfiguration())
        return self.promiseCreationStoreLock.withLock {
            self._promiseCreationStore.removeValue(forKey: self.obfuscatePointerValue(future))!
        }
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

    internal init(thread: NIOThread, selector: NIO.Selector<NIORegistration>, canBeShutdownIndividually: Bool) {
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
        self._succeededVoidFuture = EventLoopFuture(eventLoop: self, value: (), file: "n/a", line: 0)
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
        let task = ScheduledTask({
            do {
                promise.succeed(try task())
            } catch let err {
                promise.fail(err)
            }
        }, { error in
            promise.fail(error)
        }, deadline)

        let scheduled = Scheduled(promise: promise, cancellationTask: {
            self._tasksLock.withLockVoid {
                self._scheduledTasks.remove(task)
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
            scheduled._promise.fail(error)
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
        try? self._schedule0(ScheduledTask(task, { error in
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
            self.externalStateLock.withLockVoid {
                guard self.validExternalStateToScheduleTasks else {
                    print("ERROR: Cannot schedule tasks on an EventLoop that has already shut down. " +
                          "This will be upgraded to a forced crash in future SwiftNIO versions.")
                    return
                }

                self._tasksLock.withLockVoid {
                    self._scheduledTasks.push(task)
                }
            }

            // We only need to wake up the selector if we're not in the EventLoop. If we're in the EventLoop already, we're
            // either doing IO tasks (which happens before checking the scheduled tasks) or we're running a scheduled task
            // already which means that we'll check at least once more if there are other scheduled tasks runnable.
            try self._wakeupSelector()
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
    
    private func obfuscatePointerValue<T>(_ future: EventLoopFuture<T>) -> UInt {
        // Note:
        // 1. 0xbf15ca5d is randomly picked such that it fits into both 32 and 64 bit address spaces
        // 2. XOR with 0xbf15ca5d so that Memory Graph Debugger and other memory debugging tools
        // won't see it as a reference.
        return UInt(bitPattern: ObjectIdentifier(future)) ^ 0xbf15ca5d
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
                try self._selector.whenReady(strategy: currentSelectorStrategy(nextReadyTask: nextReadyTask)) { ev in
                    switch ev.registration {
                    case .serverSocketChannel(let chan, _):
                        self.handleEvent(ev.io, channel: chan)
                    case .socketChannel(let chan, _):
                        self.handleEvent(ev.io, channel: chan)
                    case .datagramChannel(let chan, _):
                        self.handleEvent(ev.io, channel: chan)
                    case .pipeChannel(let chan, let direction, _):
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
                                self.tasksCopy.append(task.task)
                            } else {
                                nextReadyTask = task
                                break
                            }
                        }
                    } else {
                        // Reset nextReadyTask to nil which means we will do a blocking select.
                        nextReadyTask = nil
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
                        task()
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
            return EventLoopFuture(eventLoop: self, value: (), file: "n/a", line: 0)
        }
        return voidFuture
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
