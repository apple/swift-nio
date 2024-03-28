import NIOCore
import NIOConcurrencyHelpers
import Atomics
import DequeModule

//struct SelectableExecutorRegistration: Registration {
//    var interested: SelectorEventSet
//    var registrationID: SelectorRegistrationID
//    var readContinuation: CheckedContinuation<SelectorEventSet, Error>?
//    var writeContinuation: CheckedContinuation<SelectorEventSet, Error>?
//}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
public final class IOExecutor: _TaskExecutor, SerialExecutor, @unchecked Sendable {
    enum Job {
        case job(UnownedJob)
        case deregister(BaseSocket)
    }
    public static func make(
        name: String
    )  -> IOExecutor {
        let lock = ConditionLock(value: 0)

        /* synchronised by `lock` */
        var _loop: IOExecutor! = nil

        NIOThread.spawnAndRun(name: name, detachThread: false) { thread in
            assert(NIOThread.current == thread)

            do {
                let loop = IOExecutor(
                    thread: thread
                )
                lock.lock(whenValue: 0)
                _loop = loop
                lock.unlock(withValue: 1)
                try loop.run()
            } catch {
                // We fatalError here because the only reasons this can be hit is if the underlying kqueue/epoll give us
                // errors that we cannot handle which is an unrecoverable error for us.
                fatalError("Unexpected error while running SelectableEventLoop: \(error).")
            }
        }
        lock.lock(whenValue: 1)
        defer { lock.unlock() }
        return _loop!
    }

    /// This is the state that is accessed from multiple threads; hence, it must be protected via a lock.
    @usableFromInline
    struct MultiThreadedState {
        /// Indicates if we are running and about to pop more tasks. If this is true then we don't have to wake the selector.
        @usableFromInline
        var pendingTaskPop = false
        /// This is the deque of enqueued jobs that we have to execute in the order they got enqueued.
        var jobs = Deque<Job>(minimumCapacity: 4096)
    }

    /// This is the state that is bound to this thread.
    @usableFromInline
    struct ThreadBoundState {
        /// The executor's thread.
        private var thread: NIOThread

        /// The executor's selector.
        var selector: NewKQueueSelector {
            get {
                assert(self.thread.isCurrent)
                return self._selector
            }
            set {
                assert(self.thread.isCurrent)
                self._selector = newValue
            }
        }

        /// The jobs that are next in line to be executed.
        var nextExecutedJobs: Deque<Job> {
            get {
                assert(self.thread.isCurrent)
                return self._nextExecutedJobs
            }
            set {
                assert(self.thread.isCurrent)
                self._nextExecutedJobs = newValue
            }
        }

        /// This method can be called from off thread so we are not asserting here.
        func wakeupSelector() throws {
            try self._selector.wakeup()
        }

        /// The backing storage for the selector.
        var _selector: NewKQueueSelector

        /// The backing storage of the next executed jobs.
        var _nextExecutedJobs: Deque<Job>

        init(thread: NIOThread, _selector: NewKQueueSelector, _nextExecutedJobs: Deque<Job>) {
            self.thread = thread
            self._selector = _selector
            self._nextExecutedJobs = _nextExecutedJobs
        }
    }

    /// This is the state that is accessed from multiple threads; hence, it is protected via a lock.
    ///
    /// - Note:In the future we could use an MPSC queue and atomics here.
    @usableFromInline
    var _multiThreadedState = NIOLockedValueBox(MultiThreadedState())

    /// This is the state that is accessed from the thread backing the executor.
    private var _threadBoundState: ThreadBoundState

    /// The thread of this executor
    private var thread: NIOThread

    internal init(thread: NIOThread) {
        var nextExecutedJobs = Deque<Job>()
        // We will process 4096 jobs per while loop.
        nextExecutedJobs.reserveCapacity(4096)
        self._threadBoundState = .init(
            thread: thread,
            _selector: try! NewKQueueSelector(),
            _nextExecutedJobs: nextExecutedJobs
        )
        self.thread = thread
    }

    deinit {
        // TODO: We should implement shutting down executors
        fatalError()
    }

    public func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        self.enqueue(.job(job))
    }

    private func enqueue(_ job: Job) {
        if self.onExecutor {
            // We are in the executor so we can just enqueue the job and
            // it will get dequed after the current run loop tick.
            self._multiThreadedState.withLockedValue { state in
                state.jobs.append(job)
            }
        } else {
            let shouldWakeSelector = self._multiThreadedState.withLockedValue { state in
                state.jobs.append(job)
                if state.pendingTaskPop {
                    // There is already a next tick scheduled so we don't have to wake the selector.
                    return false
                } else {
                    // We have to wake the selector and we are going to store that we are about to do that.
                    state.pendingTaskPop = true
                    return true
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
                // Nothing we can do really if we fail to wake the selector
                try? self._threadBoundState.wakeupSelector()
            }
        }
    }

    public func assertOnExecutor() {
        assert(self.onExecutor)
    }

    public func preconditionOnExecutor() {
        precondition(self.onExecutor)
    }

    /// Returns if we are currently running on the executor.
    private var onExecutor: Bool {
        return self.thread.isCurrent
    }

    /// - Note: This method must be called from the IOExecutor.
    func register(
        selectable: some Selectable,
        interestedEvent: SelectorEventSet,
        makeRegistration: (SelectorEventSet, SelectorRegistrationID) -> NewSelectorRegistration
    ) throws {
        // TODO: Check state
        try self._threadBoundState.selector.register(
            selectable: selectable,
            interested: interestedEvent,
            makeRegistration: makeRegistration
        )
    }

    /// - Note: This method must be called from the IOExecutor.
    func deregister(
        socket: BaseSocket
    ) throws {
        // TODO: Check state
        if self.onExecutor {
            guard var registration = try self._threadBoundState.selector.deregister(selectable: socket) else {
                return
            }
            registration.readContinuation?.resume(throwing: IOError(errnoCode: ECONNABORTED, reason: "Connection aborted"))
            registration.readContinuation = nil
            registration.writeContinuation?.resume(throwing: IOError(errnoCode: ECONNABORTED, reason: "Connection aborted"))
            registration.writeContinuation = nil
        } else {
            self.enqueue(.deregister(socket))
        }
    }

    /// - Note: This method must be called from the IOExecutor.
    func reregister(
        selectable: Selectable,
        _ body: (inout NewSelectorRegistration) -> Void
    ) throws {
        // TODO: Check state

        try self._threadBoundState.selector.reregister(selectable: selectable, body)
    }

    /// Wake the `Selector` which means `Selector.whenReady(...)` will unblock.
    @usableFromInline
    internal func _wakeupSelector() throws {
        try self._threadBoundState.selector.wakeup()
    }

    /// Start processing the jobs and handle any I/O.
    ///
    /// This method will continue running and blocking if needed.
    internal func run() throws {
        self.assertOnExecutor()

        // We need to ensure we process all jobs even if a job enqueued another job
        while true {
            self._multiThreadedState.withLockedValue { state in
                if !state.jobs.isEmpty {
                    // We got some jobs that we should execute. Let's copy them over so we can
                    // give up the lock.
                    while self._threadBoundState.nextExecutedJobs.count < 4096 {
                        guard let job = state.jobs.popFirst() else {
                            break
                        }

                        // TODO: The following CoWs right now. Need to fix that
                        self._threadBoundState.nextExecutedJobs.append(job)
                    }
                }

                if self._threadBoundState.nextExecutedJobs.isEmpty {
                    // We got no jobs to execute so we will block and need to be woken up.
                    state.pendingTaskPop = false
                }
            }

            // Execute all the tasks that were submitted
            let didExecuteJobs = !self._threadBoundState.nextExecutedJobs.isEmpty
            // TODO: The following CoWs right now. Need to fix that
            while let job = self._threadBoundState.nextExecutedJobs.popFirst() {
                withAutoReleasePool {
                    switch job {
                    case .job(let unownedJob):
                        unownedJob.runSynchronously(on: self.asUnownedSerialExecutor())
                    case .deregister(let socket):
                        try! self.deregister(socket: socket)
                    }
                }
            }

            if didExecuteJobs {
                // We executed some jobs that might have enqueued new jobs
                continue
            }

            try self._threadBoundState.selector.whenReady(
                strategy: .block,
                onLoopBegin: { self._multiThreadedState.withLockedValue { $0.pendingTaskPop = true } }
            ) { eventSet, registration in
                if eventSet.contains(.reset) {
                    registration.readContinuation?.resume(throwing: IOError(errnoCode: ECONNRESET, reason: "connection reset"))
                    registration.readContinuation = nil
                    registration.writeContinuation?.resume(throwing: IOError(errnoCode: ECONNRESET, reason: "connection reset"))
                    registration.writeContinuation = nil
                }

                if eventSet.contains(.read) || eventSet.contains(.readEOF) {
                    assert(registration.readContinuation != nil)
                    registration.readContinuation?.resume(returning: eventSet)
                    registration.readContinuation = nil
                }
                if eventSet.contains(.write) || eventSet.contains(.writeEOF) {
                    assert(registration.writeContinuation != nil)
                    registration.writeContinuation?.resume(returning: eventSet)
                    registration.writeContinuation = nil
                }
            }
        }
    }
}
