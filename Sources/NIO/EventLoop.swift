//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers
import Dispatch

/// Returned once a task was scheduled on the `EventLoop` for later execution.
///
/// A `Scheduled` allows the user to either `cancel()` the execution of the scheduled task (if possible) or obtain a reference to the `EventLoopFuture` that
/// will be notified once the execution is complete.
public struct Scheduled<T> {
    private let promise: EventLoopPromise<T>
    private let cancellationTask: () -> Void

    public init(promise: EventLoopPromise<T>, cancellationTask: @escaping () -> Void) {
        self.promise = promise
        promise.futureResult.whenFailure { error in
            guard let err = error as? EventLoopError else {
                return
            }
            if err == .cancelled {
                cancellationTask()
            }
        }
        self.cancellationTask = cancellationTask
    }

    /// Try to cancel the execution of the scheduled task.
    ///
    /// Whether this is successful depends on whether the execution of the task already begun.
    ///  This means that cancellation is not guaranteed.
    public func cancel() {
        promise.fail(error: EventLoopError.cancelled)
    }

    /// Returns the `EventLoopFuture` which will be notified once the execution of the scheduled task completes.
    public var futureResult: EventLoopFuture<T> {
        return promise.futureResult
    }
}

/// Returned once a task was scheduled to be repeatedly executed on the `EventLoop`.
///
/// A `RepeatedTask` allows the user to `cancel()` the repeated scheduling of further tasks.
public final class RepeatedTask {
    private let delay: TimeAmount
    private let eventLoop: EventLoop
    private var scheduled: Scheduled<EventLoopFuture<Void>>?
    private var task: ((RepeatedTask) -> EventLoopFuture<Void>)?

    internal init(interval: TimeAmount, eventLoop: EventLoop, task: @escaping (RepeatedTask) -> EventLoopFuture<Void>) {
        self.delay = interval
        self.eventLoop = eventLoop
        self.task = task
    }

    internal func begin(in delay: TimeAmount) {
        if self.eventLoop.inEventLoop {
            self.begin0(in: delay)
        } else {
            self.eventLoop.execute {
                self.begin0(in: delay)
            }
        }
    }

    private func begin0(in delay: TimeAmount) {
        assert(self.eventLoop.inEventLoop)
        guard let task = self.task else {
            return
        }
        self.scheduled = self.eventLoop.scheduleTask(in: delay) {
            task(self)
        }
        self.reschedule()
    }

    /// Try to cancel the execution of the repeated task.
    ///
    /// Whether the execution of the task is immediately canceled depends on whether the execution of a task has already begun.
    ///  This means immediate cancellation is not guaranteed.
    ///
    /// The safest way to cancel is by using the passed reference of `RepeatedTask` inside the task closure.
    public func cancel() {
        if self.eventLoop.inEventLoop {
            self.cancel0()
        } else {
            self.eventLoop.execute {
                self.cancel0()
            }
        }
    }

    private func cancel0() {
        assert(self.eventLoop.inEventLoop)
        self.scheduled?.cancel()
        self.scheduled = nil
        self.task = nil
    }

    private func reschedule() {
        assert(self.eventLoop.inEventLoop)
        guard let scheduled = self.scheduled else {
            return
        }

        scheduled.futureResult.whenSuccess { future in
            future.whenComplete {
                self.reschedule0()
            }
        }

        scheduled.futureResult.whenFailure { (_: Error) in
            self.cancel0()
        }
    }

    private func reschedule0() {
        assert(self.eventLoop.inEventLoop)
        guard self.task != nil else {
            return
        }
        self.scheduled = self.eventLoop.scheduleTask(in: self.delay) {
            // we need to repeat this as we might have been cancelled in the meantime
            guard let task = self.task else {
                return self.eventLoop.newSucceededFuture(result: ())
            }
            return task(self)
        }
        self.reschedule()
    }
}

/// An iterator over the `EventLoop`s forming an `EventLoopGroup`.
///
/// Usually returned by an `EventLoopGroup`'s `makeIterator()` method.
///
///     let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
///     group.makeIterator()?.forEach { loop in
///         // Do something with each loop
///     }
///
public struct EventLoopIterator: Sequence, IteratorProtocol {
    public typealias Element = EventLoop
    private var eventLoops: IndexingIterator<[EventLoop]>

    internal init(_ eventLoops: [EventLoop]) {
        self.eventLoops = eventLoops.makeIterator()
    }

    /// Advances to the next `EventLoop` and returns it, or `nil` if no next element exists.
    ///
    /// - returns: The next `EventLoop` if a next element exists; otherwise, `nil`.
    public mutating func next() -> EventLoop? {
        return self.eventLoops.next()
    }
}

/// An EventLoop processes IO / tasks in an endless loop for `Channel`s until it's closed.
///
/// Usually multiple `Channel`s share the same `EventLoop` for processing IO / tasks and so share the same processing `Thread`.
/// For a better understanding of how such an `EventLoop` works internally the following pseudo code may be helpful:
///
/// ```
/// while eventLoop.isOpen {
///     /// Block until there is something to process for 1...n Channels
///     let readyChannels = blockUntilIoOrTasksAreReady()
///     /// Loop through all the Channels
///     for channel in readyChannels {
///         /// Process IO and / or tasks for the Channel.
///         /// This may include things like:
///         ///    - accept new connection
///         ///    - connect to a remote host
///         ///    - read from socket
///         ///    - write to socket
///         ///    - tasks that were submitted via EventLoop methods
///         /// and others.
///         processIoAndTasks(channel)
///     }
/// }
/// ```
///
/// Because an `EventLoop` may be shared between multiple `Channel`s it's important to _NOT_ block while processing IO / tasks. This also includes long running computations which will have the same
/// effect as blocking in this case.
public protocol EventLoop: EventLoopGroup {
    /// Returns `true` if the current `Thread` is the same as the `Thread` that is tied to this `EventLoop`. `false` otherwise.
    var inEventLoop: Bool { get }

    /// Submit a given task to be executed by the `EventLoop`
    func execute(_ task: @escaping () -> Void)

    /// Submit a given task to be executed by the `EventLoop`. Once the execution is complete the returned `EventLoopFuture` is notified.
    ///
    /// - parameters:
    ///     - task: The closure that will be submitted to the `EventLoop` for execution.
    /// - returns: `EventLoopFuture` that is notified once the task was executed.
    func submit<T>(_ task: @escaping () throws -> T) -> EventLoopFuture<T>

    /// Schedule a `task` that is executed by this `SelectableEventLoop` after the given amount of time.
    func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws -> T) -> Scheduled<T>
}

/// Represents a time _interval_.
///
/// - note: `TimeAmount` should not be used to represent a point in time.
public struct TimeAmount {
  
    #if arch(arm) // 32-bit, Raspi/AppleWatch/etc
        public typealias Value = Int64
    #else // 64-bit, keeping that at Int for SemVer in the 1.x line.
        public typealias Value = Int
    #endif

    /// The nanoseconds representation of the `TimeAmount`.
    public let nanoseconds: Value

    private init(_ nanoseconds: Value) {
        self.nanoseconds = nanoseconds
    }

    /// Creates a new `TimeAmount` for the given amount of nanoseconds.
    ///
    /// - parameters:
    ///     - amount: the amount of nanoseconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func nanoseconds(_ amount: Value) -> TimeAmount {
        return TimeAmount(amount)
    }

    /// Creates a new `TimeAmount` for the given amount of microseconds.
    ///
    /// - parameters:
    ///     - amount: the amount of microseconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func microseconds(_ amount: Value) -> TimeAmount {
        return TimeAmount(amount * 1000)
    }

    /// Creates a new `TimeAmount` for the given amount of milliseconds.
    ///
    /// - parameters:
    ///     - amount: the amount of milliseconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func milliseconds(_ amount: Value) -> TimeAmount {
        return TimeAmount(amount * 1000 * 1000)
    }

    /// Creates a new `TimeAmount` for the given amount of seconds.
    ///
    /// - parameters:
    ///     - amount: the amount of seconds this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func seconds(_ amount: Value) -> TimeAmount {
        return TimeAmount(amount * 1000 * 1000 * 1000)
    }

    /// Creates a new `TimeAmount` for the given amount of minutes.
    ///
    /// - parameters:
    ///     - amount: the amount of minutes this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func minutes(_ amount: Value) -> TimeAmount {
        return TimeAmount(amount * 1000 * 1000 * 1000 * 60)
    }

    /// Creates a new `TimeAmount` for the given amount of hours.
    ///
    /// - parameters:
    ///     - amount: the amount of hours this `TimeAmount` represents.
    /// - returns: the `TimeAmount` for the given amount.
    public static func hours(_ amount: Value) -> TimeAmount {
        return TimeAmount(amount * 1000 * 1000 * 1000 * 60 * 60)
    }
}

extension TimeAmount: Comparable {
    public static func < (lhs: TimeAmount, rhs: TimeAmount) -> Bool {
        return lhs.nanoseconds < rhs.nanoseconds
    }

    public static func == (lhs: TimeAmount, rhs: TimeAmount) -> Bool {
        return lhs.nanoseconds == rhs.nanoseconds
    }
}

extension EventLoop {
    public func submit<T>(_ task: @escaping () throws -> T) -> EventLoopFuture<T> {
        let promise: EventLoopPromise<T> = newPromise(file: #file, line: #line)

        self.execute {
            do {
                promise.succeed(result: try task())
            } catch let err {
                promise.fail(error: err)
            }
        }

        return promise.futureResult
    }

    /// Creates and returns a new `EventLoopPromise` that will be notified using this `EventLoop` as execution `Thread`.
    public func newPromise<T>(file: StaticString = #file, line: UInt = #line) -> EventLoopPromise<T> {
        return EventLoopPromise<T>(eventLoop: self, file: file, line: line)
    }

    /// Creates and returns a new `EventLoopFuture` that is already marked as failed. Notifications will be done using this `EventLoop` as execution `Thread`.
    ///
    /// - parameters:
    ///     - error: the `Error` that is used by the `EventLoopFuture`.
    /// - returns: a failed `EventLoopFuture`.
    public func newFailedFuture<T>(error: Error) -> EventLoopFuture<T> {
        return EventLoopFuture<T>(eventLoop: self, error: error, file: "n/a", line: 0)
    }

    /// Creates and returns a new `EventLoopFuture` that is already marked as success. Notifications will be done using this `EventLoop` as execution `Thread`.
    ///
    /// - parameters:
    ///     - result: the value that is used by the `EventLoopFuture`.
    /// - returns: a succeeded `EventLoopFuture`.
    public func newSucceededFuture<T>(result: T) -> EventLoopFuture<T> {
        return EventLoopFuture<T>(eventLoop: self, result: result, file: "n/a", line: 0)
    }

    public func next() -> EventLoop {
        return self
    }

    public func close() throws {
        // Do nothing
    }

    /// Schedule a repeated task to be executed by the `EventLoop` with a fixed delay between the end and start of each task.
    ///
    /// - parameters:
    ///     - initialDelay: The delay after which the first task is executed.
    ///     - delay: The delay between the end of one task and the start of the next.
    ///     - task: The closure that will be executed.
    /// - return: `RepeatedTask`
    @discardableResult
    public func scheduleRepeatedTask(initialDelay: TimeAmount, delay: TimeAmount, _ task: @escaping (RepeatedTask) throws -> Void) -> RepeatedTask {
        let futureTask: (RepeatedTask) -> EventLoopFuture<Void> = { repeatedTask in
            do {
                try task(repeatedTask)
                return self.newSucceededFuture(result: ())
            } catch {
                return self.newFailedFuture(error: error)
            }
        }
        return self.scheduleRepeatedTask(initialDelay: initialDelay, delay: delay, futureTask)
    }

    /// Schedule a repeated task to be executed by the `EventLoop` with a fixed delay between the end and start of each task.
    ///
    /// - parameters:
    ///     - initialDelay: The delay after which the first task is executed.
    ///     - delay: The delay between the end of one task and the start of the next.
    ///     - task: The closure that will be executed.
    /// - return: `RepeatedTask`
    @discardableResult
    public func scheduleRepeatedTask(initialDelay: TimeAmount, delay: TimeAmount, _ task: @escaping (RepeatedTask) -> EventLoopFuture<Void>) -> RepeatedTask {
        let repeated = RepeatedTask(interval: delay, eventLoop: self, task: task)
        repeated.begin(in: initialDelay)
        return repeated
    }

    /// Returns an `EventLoopIterator` over this `EventLoop`.
    ///
    /// - note: The return value of `makeIterator` is currently optional as requiring it would be SemVer major. From NIO 2.0.0 on it will return a non-optional iterator.
    /// - returns: `EventLoopIterator`
    public func makeIterator() -> EventLoopIterator? {
        return EventLoopIterator([self])
    }
}

/// Internal representation of a `Registration` to an `Selector`.
///
/// Whenever a `Selectable` is registered to a `Selector` a `Registration` is created internally that is also provided within the
/// `SelectorEvent` that is provided to the user when an event is ready to be consumed for a `Selectable`. As we need to have access to the `ServerSocketChannel`
/// and `SocketChannel` (to dispatch the events) we create our own `Registration` that holds a reference to these.
enum NIORegistration: Registration {
    case serverSocketChannel(ServerSocketChannel, SelectorEventSet)
    case socketChannel(SocketChannel, SelectorEventSet)
    case datagramChannel(DatagramChannel, SelectorEventSet)

    /// The `SelectorEventSet` in which this `NIORegistration` is interested in.
    var interested: SelectorEventSet {
        set {
            switch self {
            case .serverSocketChannel(let c, _):
                self = .serverSocketChannel(c, newValue)
            case .socketChannel(let c, _):
                self = .socketChannel(c, newValue)
            case .datagramChannel(let c, _):
                self = .datagramChannel(c, newValue)
            }
        }
        get {
            switch self {
            case .serverSocketChannel(_, let i):
                return i
            case .socketChannel(_, let i):
                return i
            case .datagramChannel(_, let i):
                return i
            }
        }
    }
}

/// Execute the given closure and ensure we release all auto pools if needed.
private func withAutoReleasePool<T>(_ execute: () throws -> T) rethrows -> T {
    #if os(Linux)
    return try execute()
    #else
    return try autoreleasepool {
        try execute()
    }
    #endif
}

/// The different state in the lifecycle of an `EventLoop`.
private enum EventLoopLifecycleState {
    /// `EventLoop` is open and so can process more work.
    case open
    /// `EventLoop` is currently in the process of closing.
    case closing
    /// `EventLoop` is closed.
    case closed
}

/// `EventLoop` implementation that uses a `Selector` to get notified once there is more I/O or tasks to process.
/// The whole processing of I/O and tasks is done by a `Thread` that is tied to the `SelectableEventLoop`. This `Thread`
/// is guaranteed to never change!
internal final class SelectableEventLoop: EventLoop {
    private let selector: NIO.Selector<NIORegistration>
    private let thread: Thread
    private var scheduledTasks = PriorityQueue<ScheduledTask>(ascending: true)
    private var tasksCopy = ContiguousArray<() -> Void>()

    private let tasksLock = Lock()
    private var lifecycleState: EventLoopLifecycleState = .open

    private let _iovecs: UnsafeMutablePointer<IOVector>
    private let _storageRefs: UnsafeMutablePointer<Unmanaged<AnyObject>>

    let iovecs: UnsafeMutableBufferPointer<IOVector>
    let storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>

    // Used for gathering UDP writes.
    private let _msgs: UnsafeMutablePointer<MMsgHdr>
    private let _addresses: UnsafeMutablePointer<sockaddr_storage>
    let msgs: UnsafeMutableBufferPointer<MMsgHdr>
    let addresses: UnsafeMutableBufferPointer<sockaddr_storage>

    /// Creates a new `SelectableEventLoop` instance that is tied to the given `pthread_t`.

    private let promiseCreationStoreLock = Lock()
    private var _promiseCreationStore: [ObjectIdentifier: (file: StaticString, line: UInt)] = [:]
    internal func promiseCreationStoreAdd<T>(future: EventLoopFuture<T>, file: StaticString, line: UInt) {
        precondition(_isDebugAssertConfiguration())
        self.promiseCreationStoreLock.withLock {
            self._promiseCreationStore[ObjectIdentifier(future)] = (file: file, line: line)
        }
    }

    internal func promiseCreationStoreRemove<T>(future: EventLoopFuture<T>) -> (file: StaticString, line: UInt) {
        precondition(_isDebugAssertConfiguration())
        return self.promiseCreationStoreLock.withLock {
            self._promiseCreationStore[ObjectIdentifier(future)]!
        }
    }

    public init(thread: Thread) throws {
        self.selector = try NIO.Selector()
        self.thread = thread
        self._iovecs = UnsafeMutablePointer.allocate(capacity: Socket.writevLimitIOVectors)
        self._storageRefs = UnsafeMutablePointer.allocate(capacity: Socket.writevLimitIOVectors)
        self.iovecs = UnsafeMutableBufferPointer(start: self._iovecs, count: Socket.writevLimitIOVectors)
        self.storageRefs = UnsafeMutableBufferPointer(start: self._storageRefs, count: Socket.writevLimitIOVectors)
        self._msgs = UnsafeMutablePointer.allocate(capacity: Socket.writevLimitIOVectors)
        self._addresses = UnsafeMutablePointer.allocate(capacity: Socket.writevLimitIOVectors)
        self.msgs = UnsafeMutableBufferPointer(start: _msgs, count: Socket.writevLimitIOVectors)
        self.addresses = UnsafeMutableBufferPointer(start: _addresses, count: Socket.writevLimitIOVectors)
        // We will process 4096 tasks per while loop.
        self.tasksCopy.reserveCapacity(4096)
    }

    deinit {
        _iovecs.deallocate()
        _storageRefs.deallocate()
        _msgs.deallocate()
        _addresses.deallocate()
    }

    /// Is this `SelectableEventLoop` still open (ie. not shutting down or shut down)
    internal var isOpen: Bool {
        assert(self.inEventLoop)
        return self.lifecycleState == .open
    }

    /// Register the given `SelectableChannel` with this `SelectableEventLoop`. After this point all I/O for the `SelectableChannel` will be processed by this `SelectableEventLoop` until it
    /// is deregistered by calling `deregister`.
    public func register<C: SelectableChannel>(channel: C) throws {
        assert(inEventLoop)

        // Don't allow registration when we're closed.
        guard self.lifecycleState == .open else {
            throw EventLoopError.shutdown
        }

        try selector.register(selectable: channel.selectable, interested: channel.interestedEvent, makeRegistration: channel.registrationFor(interested:))
    }

    /// Deregister the given `SelectableChannel` from this `SelectableEventLoop`.
    public func deregister<C: SelectableChannel>(channel: C) throws {
        assert(inEventLoop)
        guard lifecycleState == .open else {
            // It's possible the EventLoop was closed before we were able to call deregister, so just return in this case as there is no harm.
            return
        }
        try selector.deregister(selectable: channel.selectable)
    }

    /// Register the given `SelectableChannel` with this `SelectableEventLoop`. This should be done whenever `channel.interestedEvents` has changed and it should be taken into account when
    /// waiting for new I/O for the given `SelectableChannel`.
    public func reregister<C: SelectableChannel>(channel: C) throws {
        assert(inEventLoop)
        try selector.reregister(selectable: channel.selectable, interested: channel.interestedEvent)
    }

    public var inEventLoop: Bool {
        return thread.isCurrent
    }

    public func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws -> T) -> Scheduled<T> {
        let promise: EventLoopPromise<T> = newPromise()
        let task = ScheduledTask({
            do {
                promise.succeed(result: try task())
            } catch let err {
                promise.fail(error: err)
            }
        }, { error in
            promise.fail(error: error)
        },`in`)

        let scheduled = Scheduled(promise: promise, cancellationTask: {
            self.tasksLock.withLockVoid {
                self.scheduledTasks.remove(task)
            }
            self.wakeupSelector()
        })

        schedule0(task)
        return scheduled
    }

    public func execute(_ task: @escaping () -> Void) {
        schedule0(ScheduledTask(task, { error in
            // do nothing
        }, .nanoseconds(0)))
    }

    /// Add the `ScheduledTask` to be executed.
    private func schedule0(_ task: ScheduledTask) {
        tasksLock.withLockVoid {
            scheduledTasks.push(task)
        }
        wakeupSelector()
    }

    /// Wake the `Selector` which means `Selector.whenReady(...)` will unblock.
    private func wakeupSelector() {
        do {
            try selector.wakeup()
        } catch let err {
            fatalError("Error during Selector.wakeup(): \(err)")
        }
    }

    /// Handle the given `SelectorEventSet` for the `SelectableChannel`.
    private func handleEvent<C: SelectableChannel>(_ ev: SelectorEventSet, channel: C) {
        guard channel.selectable.isOpen else {
            return
        }

        // process resets first as they'll just cause the writes to fail anyway.
        if ev.contains(.reset) {
            channel.reset()
        } else {
            if ev.contains(.write) {
                channel.writable()

                guard channel.selectable.isOpen else {
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

        let nextReady = sched.readyIn(DispatchTime.now())
        if nextReady <= .nanoseconds(0) {
            // Something is ready to be processed just do a non-blocking select of events.
            return .now
        } else {
            return .blockUntilTimeout(nextReady)
        }
    }

    /// Start processing I/O and tasks for this `SelectableEventLoop`. This method will continue running (and so block) until the `SelectableEventLoop` is closed.
    public func run() throws {
        precondition(self.inEventLoop, "tried to run the EventLoop on the wrong thread.")
        defer {
            var scheduledTasksCopy = ContiguousArray<ScheduledTask>()
            tasksLock.withLockVoid {
                // reserve the correct capacity so we don't need to realloc later on.
                scheduledTasksCopy.reserveCapacity(scheduledTasks.count)
                while let sched = scheduledTasks.pop() {
                    scheduledTasksCopy.append(sched)
                }
            }

            // Fail all the scheduled tasks.
            for task in scheduledTasksCopy {
                task.fail(error: EventLoopError.shutdown)
            }
        }
        var nextReadyTask: ScheduledTask? = nil
        while lifecycleState != .closed {
            // Block until there are events to handle or the selector was woken up
            /* for macOS: in case any calls we make to Foundation put objects into an autoreleasepool */
            try withAutoReleasePool {
                try selector.whenReady(strategy: currentSelectorStrategy(nextReadyTask: nextReadyTask)) { ev in
                    switch ev.registration {
                    case .serverSocketChannel(let chan, _):
                        self.handleEvent(ev.io, channel: chan)
                    case .socketChannel(let chan, _):
                        self.handleEvent(ev.io, channel: chan)
                    case .datagramChannel(let chan, _):
                        self.handleEvent(ev.io, channel: chan)
                    }
                }
            }

            // We need to ensure we process all tasks, even if a task added another task again
            while true {
                // TODO: Better locking
                tasksLock.withLockVoid {
                    if !scheduledTasks.isEmpty {
                        // We only fetch the time one time as this may be expensive and is generally good enough as if we miss anything we will just do a non-blocking select again anyway.
                        let now = DispatchTime.now()

                        // Make a copy of the tasks so we can execute these while not holding the lock anymore
                        while tasksCopy.count < tasksCopy.capacity, let task = scheduledTasks.peek() {
                            if task.readyIn(now) <= .nanoseconds(0) {
                                _ = scheduledTasks.pop()
                                tasksCopy.append(task.task)
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
                if tasksCopy.isEmpty {
                    break
                }

                // Execute all the tasks that were summited
                for task in tasksCopy {
                    /* for macOS: in case any calls we make to Foundation put objects into an autoreleasepool */
                    withAutoReleasePool {
                        task()
                    }
                }
                // Drop everything (but keep the capacity) so we can fill it again on the next iteration.
                tasksCopy.removeAll(keepingCapacity: true)
            }
        }

        // This EventLoop was closed so also close the underlying selector.
        try self.selector.close()
    }

    fileprivate func close0() throws {
        if inEventLoop {
            self.lifecycleState = .closed
        } else {
            self.execute {
                self.lifecycleState = .closed
            }
        }
    }

    /// Gently close this `SelectableEventLoop` which means we will close all `SelectableChannel`s before finally close this `SelectableEventLoop` as well.
    public func closeGently() -> EventLoopFuture<Void> {
        func closeGently0() -> EventLoopFuture<Void> {
            guard self.lifecycleState == .open else {
                return self.newFailedFuture(error: EventLoopError.shutdown)
            }
            self.lifecycleState = .closing
            return self.selector.closeGently(eventLoop: self)
        }
        if self.inEventLoop {
            return closeGently0()
        } else {
            let p: EventLoopPromise<Void> = self.newPromise()
            _ = self.submit {
                closeGently0().cascade(promise: p)
            }
            return p.futureResult
        }
    }

    func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        self.closeGently().map {
            do {
                try self.close0()
                queue.async {
                    callback(nil)
                }
            } catch {
                queue.async {
                    callback(error)
                }
            }
        }.whenFailure { error in
            _ = try? self.close0()
            queue.async {
                callback(error)
            }
        }
    }
}

extension SelectableEventLoop: CustomStringConvertible {
    var description: String {
        return self.tasksLock.withLock {
            return "SelectableEventLoop { selector = \(self.selector), scheduledTasks = \(self.scheduledTasks.description) }"
        }
    }
}


/// Provides an endless stream of `EventLoop`s to use.
public protocol EventLoopGroup: class {
    /// Returns the next `EventLoop` to use.
    func next() -> EventLoop

    /// Shuts down the eventloop gracefully. This function is clearly an outlier in that it uses a completion
    /// callback instead of an EventLoopFuture. The reason for that is that NIO's EventLoopFutures will call back on an event loop.
    /// The virtue of this function is to shut the event loop down. To work around that we call back on a DispatchQueue
    /// instead.
    func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void)

    /// Returns an `EventLoopIterator` over the `EventLoop`s in this `EventLoopGroup`.
    ///
    /// - note: The return value of `makeIterator` is currently optional as requiring it would be SemVer major. From NIO 2.0.0 on it will return a non-optional iterator.
    /// - returns: `EventLoopIterator`
    func makeIterator() -> EventLoopIterator?
}

extension EventLoopGroup {
    public func shutdownGracefully(_ callback: @escaping (Error?) -> Void) {
        self.shutdownGracefully(queue: .global(), callback)
    }

    public func syncShutdownGracefully() throws {
        let errorStorageLock = Lock()
        var errorStorage: Error? = nil
        let continuation = DispatchWorkItem {}
        self.shutdownGracefully { error in
            if let error = error {
                errorStorageLock.withLock {
                    errorStorage = error
                }
            }
            continuation.perform()
        }
        continuation.wait()
        try errorStorageLock.withLock {
            if let error = errorStorage {
                throw error
            }
        }
    }

    public func makeIterator() -> EventLoopIterator? {
        return nil
    }
}

/// Called per `Thread` that is created for an EventLoop to do custom initialization of the `Thread` before the actual `EventLoop` is run on it.
typealias ThreadInitializer = (Thread) -> Void

/// An `EventLoopGroup` which will create multiple `EventLoop`s, each tied to its own `Thread`.
///
/// The effect of initializing a `MultiThreadedEventLoopGroup` is to spawn `numberOfThreads` fresh threads which will
/// all run their own `EventLoop`. Those threads will not be shut down until `shutdownGracefully` or
/// `syncShutdownGracefully` is called.
///
/// - note: It's good style to call `MultiThreadedEventLoopGroup.shutdownGracefully` or
///         `MultiThreadedEventLoopGroup.syncShutdownGracefully` when you no longer need this `EventLoopGroup`. In
///         many cases that is just before your program exits.
/// - warning: Unit tests often spawn one `MultiThreadedEventLoopGroup` per unit test to force isolation between the
///            tests. In those cases it's important to shut the `MultiThreadedEventLoopGroup` down at the end of the
///            test. A good place to start a `MultiThreadedEventLoopGroup` is the `setUp` method of your `XCTestCase`
///            subclass, a good place to shut it down is the `tearDown` method.
final public class MultiThreadedEventLoopGroup: EventLoopGroup {

    private static let threadSpecificEventLoop = ThreadSpecificVariable<SelectableEventLoop>()

    private let index = Atomic<Int>(value: 0)
    private let eventLoops: [SelectableEventLoop]

    private static func setupThreadAndEventLoop(name: String, initializer: @escaping ThreadInitializer)  -> SelectableEventLoop {
        let lock = Lock()
        /* the `loopUpAndRunningGroup` is done by the calling thread when the EventLoop has been created and was written to `_loop` */
        let loopUpAndRunningGroup = DispatchGroup()

        /* synchronised by `lock` */
        var _loop: SelectableEventLoop! = nil

        loopUpAndRunningGroup.enter()
        Thread.spawnAndRun(name: name) { t in
            initializer(t)

            do {
                /* we try! this as this must work (just setting up kqueue/epoll) or else there's not much we can do here */
                let l = try! SelectableEventLoop(thread: t)
                threadSpecificEventLoop.currentValue = l
                defer {
                    threadSpecificEventLoop.currentValue = nil
                }
                lock.withLock {
                    _loop = l
                }
                loopUpAndRunningGroup.leave()
                try l.run()
            } catch let err {
                fatalError("unexpected error while executing EventLoop \(err)")
            }
        }
        loopUpAndRunningGroup.wait()
        return lock.withLock { _loop }
    }

    /// Creates a `MultiThreadedEventLoopGroup` instance which uses `numberOfThreads`.
    ///
    /// - note: Don't forget to call `shutdownGracefully` or `syncShutdownGracefully` when you no longer need this
    ///         `EventLoopGroup`. If you forget to shut the `EventLoopGroup` down you will leak `numberOfThreads`
    ///         (kernel) threads which are costly resources. This is especially important in unit tests where one
    ///         `MultiThreadedEventLoopGroup` is started per test case.
    ///
    /// - arguments:
    ///     - numberOfThreads: The number of `Threads` to use.
    public convenience init(numberOfThreads: Int) {
        let initializers: [ThreadInitializer] = Array(repeating: { _ in }, count: numberOfThreads)
        self.init(threadInitializers: initializers)
    }
    
    /// Creates a `MultiThreadedEventLoopGroup` instance which uses `numThreads`.
    ///
    /// - arguments:
    ///     - numThreads: The number of `Threads` to use.
    @available(*, deprecated, renamed: "init(numberOfThreads:)")
    public convenience init(numThreads: Int) {
        self.init(numberOfThreads: numThreads)
    }

    /// Creates a `MultiThreadedEventLoopGroup` instance which uses the given `ThreadInitializer`s. One `Thread` per `ThreadInitializer` is created and used.
    ///
    /// - arguments:
    ///     - threadInitializers: The `ThreadInitializer`s to use.
    internal init(threadInitializers: [ThreadInitializer]) {
        var idx = 0
        self.eventLoops = threadInitializers.map { initializer in
            // Maximum name length on linux is 16 by default.
            let ev = MultiThreadedEventLoopGroup.setupThreadAndEventLoop(name: "NIO-ELT-#\(idx)", initializer: initializer)
            idx += 1
            return ev
        }
    }

    /// Returns the `EventLoop` for the calling thread.
    ///
    /// - returns: The current `EventLoop` for the calling thread or `nil` if none is assigned to the thread.
    public static var currentEventLoop: EventLoop? {
        return threadSpecificEventLoop.currentValue
    }

    /// Returns an `EventLoopIterator` over the `EventLoop`s in this `MultiThreadedEventLoopGroup`.
    ///
    /// - note: The return value of `makeIterator` is currently optional as requiring it would be SemVer major. From NIO 2.0.0 on it will return a non-optional iterator.
    /// - returns: `EventLoopIterator`
    public func makeIterator() -> EventLoopIterator? {
        return EventLoopIterator(self.eventLoops)
    }

    public func next() -> EventLoop {
        return eventLoops[abs(index.add(1) % eventLoops.count)]
    }

    internal func unsafeClose() throws {
        for loop in eventLoops {
            // TODO: Should we log this somehow or just rethrow the first error ?
            _ = try loop.close0()
        }
    }

    /// Shut this `MultiThreadedEventLoopGroup` down which causes the `EventLoop`s and their associated threads to be
    /// shut down and release their resources.
    ///
    /// - parameters:
    ///    - queue: The `DispatchQueue` to run `handler` on when the shutdown operation completes.
    ///    - handler: The handler which is called after the shutdown operation completes. The parameter will be `nil`
    ///               on success and contain the `Error` otherwise.
    public func shutdownGracefully(queue: DispatchQueue, _ handler: @escaping (Error?) -> Void) {
        // This method cannot perform its final cleanup using EventLoopFutures, because it requires that all
        // our event loops still be alive, and they may not be. Instead, we use Dispatch to manage
        // our shutdown signaling, and then do our cleanup once the DispatchQueue is empty.
        let g = DispatchGroup()
        let q = DispatchQueue(label: "nio.shutdownGracefullyQueue", target: queue)
        var error: Error? = nil

        for loop in self.eventLoops {
            g.enter()
            loop.closeGently().mapIfError { err in
                q.sync { error = err }
            }.whenComplete {
                g.leave()
            }
        }

        g.notify(queue: q) {
            let failure = self.eventLoops.map { try? $0.close0() }.filter { $0 == nil }.count > 0

            // TODO: For Swift NIO 2.0 we should join in the threads used by the EventLoop before invoking the callback
            //       to ensure they're really gone (#581).
            if failure {
                error = EventLoopError.shutdownFailed
            }

            handler(error)
        }
    }
}

private final class ScheduledTask {
    let task: () -> Void
    private let failFn: (Error) ->()
    private let readyTime: TimeAmount.Value

    init(_ task: @escaping () -> Void, _ failFn: @escaping (Error) -> Void, _ time: TimeAmount) {
        self.task = task
        self.failFn = failFn
        self.readyTime = time.nanoseconds + TimeAmount.Value(DispatchTime.now().uptimeNanoseconds)
    }

    func readyIn(_ t: DispatchTime) -> TimeAmount {
        if readyTime < t.uptimeNanoseconds {
            return .nanoseconds(0)
        }
        return .nanoseconds(readyTime - TimeAmount.Value(t.uptimeNanoseconds))
    }

    func fail(error: Error) {
        failFn(error)
    }
}

extension ScheduledTask: CustomStringConvertible {
    var description: String {
        return "ScheduledTask(readyTime: \(self.readyTime))"
    }
}

extension ScheduledTask: Comparable {
    public static func < (lhs: ScheduledTask, rhs: ScheduledTask) -> Bool {
        return lhs.readyTime < rhs.readyTime
    }

    public static func == (lhs: ScheduledTask, rhs: ScheduledTask) -> Bool {
        return lhs === rhs
    }
}

/// Different `Error`s that are specific to `EventLoop` operations / implementations.
public enum EventLoopError: Error {
    /// An operation was executed that is not supported by the `EventLoop`
    case unsupportedOperation

    /// An scheduled task was cancelled.
    case cancelled

    /// The `EventLoop` was shutdown already.
    case shutdown

    /// Shutting down the `EventLoop` failed.
    case shutdownFailed
}
