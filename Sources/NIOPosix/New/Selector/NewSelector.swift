import NIOCore
import NIOConcurrencyHelpers

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
struct NewSelectorRegistration {
    /// The `SelectorEventSet` in which the `Registration` is interested.
    var interested: SelectorEventSet
    var registrationID: SelectorRegistrationID
    var readContinuation: CheckedContinuation<SelectorEventSet, Error>?
    var writeContinuation: CheckedContinuation<SelectorEventSet, Error>?
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
struct NewSelectorEvent {
    public let registration: NewSelectorRegistration
    public var io: SelectorEventSet

    /// Create new instance
    ///
    /// - parameters:
    ///     - io: The `SelectorEventSet` that triggered this event.
    ///     - registration: The registration that belongs to the event.
    init(io: SelectorEventSet, registration: NewSelectorRegistration) {
        self.io = io
        self.registration = registration
    }
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
struct NewKQueueSelector {
    private static let initialEventsCapacity = 64
    fileprivate enum State {
        fileprivate struct Open {
            fileprivate var registrations = [Int: NewSelectorRegistration]()
            fileprivate var currentRegistrationID = SelectorRegistrationID.initialRegistrationID
            fileprivate let myThread: NIOThread
            fileprivate var selectorFD: CInt
            fileprivate var events: UnsafeMutablePointer<kevent>
            fileprivate var eventsCapacity: Int
        }
        case open(Open)
        case closed
    }

    private var state: State

    private var _selectorFD: CInt {
        switch self.state {
        case .open(let open):
            return open.selectorFD
        case .closed:
            return -1
        }
    }

    init() throws {
        let selectorFD = try KQueue.kqueue()
        self.state = .open(.init(
            myThread: NIOThread.current,
            selectorFD: selectorFD,
            events: Self.allocateEventsArray(capacity: Self.initialEventsCapacity),
            eventsCapacity: Self.initialEventsCapacity
        ))

        var event = kevent()
        event.ident = 0
        event.filter = Int16(EVFILT_USER)
        event.fflags = UInt32(NOTE_FFNOP)
        event.data = 0
        event.udata = nil
        event.flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR)
        try withUnsafeMutablePointer(to: &event) { ptr in
            try Self.kqueueApplyEventChangeSet(selectorFD: selectorFD, keventBuffer: UnsafeMutableBufferPointer(start: ptr, count: 1))
        }
    }

    /// Apply a kqueue changeset by calling the `kevent` function with the `kevent`s supplied in `keventBuffer`.
    private static func kqueueApplyEventChangeSet(
        selectorFD: CInt,
        keventBuffer: UnsafeMutableBufferPointer<kevent>
    ) throws {
        // WARNING: This is called on `self.myThread` OR with `self.externalSelectorFDLock` held.
        // So it MUST NOT touch anything on `self.` apart from constants and `self.selectorFD`.
        guard keventBuffer.count > 0 else {
            // nothing to do
            return
        }
        do {
            try KQueue.kevent(
                kq: selectorFD,
                changelist: keventBuffer.baseAddress!,
                nchanges: CInt(keventBuffer.count),
                eventlist: nil,
                nevents: 0,
                timeout: nil
            )
        } catch let err as IOError {
            if err.errnoCode == EINTR {
                // See https://www.freebsd.org/cgi/man.cgi?query=kqueue&sektion=2
                // When kevent() call fails with EINTR error, all changes in the changelist have been applied.
                return
            }
            throw err
        }
    }

    private func kqueueUpdateEventNotifications<S: Selectable>(
        selectorFD: CInt,
        selectable: S,
        interested: SelectorEventSet,
        oldInterested: SelectorEventSet?,
        registrationID: SelectorRegistrationID
    ) throws {
//        assert(self.myThread == NIOThread.current)
        let oldKQueueFilters = KQueueEventFilterSet(selectorEventSet: oldInterested ?? ._none)
        let newKQueueFilters = KQueueEventFilterSet(selectorEventSet: interested)
        assert(interested.contains(.reset))
        assert(oldInterested?.contains(.reset) ?? true)

        try selectable.withUnsafeHandle {
            try newKQueueFilters.calculateKQueueFilterSetChanges(
                previousKQueueFilterSet: oldKQueueFilters,
                fileDescriptor: $0,
                registrationID: registrationID,
                selectorFD: selectorFD,
                Self.kqueueApplyEventChangeSet
            )
        }
    }

    private static func toKQueueTimeSpec(strategy: SelectorStrategy) -> timespec? {
        switch strategy {
        case .block:
            return nil
        case .now:
            return timespec(tv_sec: 0, tv_nsec: 0)
        case .blockUntilTimeout(let nanoseconds):
            // A scheduledTask() specified with a zero or negative timeAmount, will be scheduled immediately
            // and therefore SHOULD NOT result in a kevent being created with a negative or zero timespec.
            precondition(nanoseconds.nanoseconds > 0, "\(nanoseconds) is invalid (0 < nanoseconds)")

            var ts = timespec(timeAmount: nanoseconds)
            // Check that the timespec tv_nsec field conforms to the definition in the C11 standard (ISO/IEC 9899:2011).
            assert((0..<1_000_000_000).contains(ts.tv_nsec), "\(ts) is invalid (0 <= tv_nsec < 1_000_000_000)")

            // The maximum value in seconds supported by the Darwin-kernel interval timer (kern_time.c:itimerfix())
            // (note that - whilst unlikely - this value *could* change).
            let sysIntervalTimerMaxSec = 100_000_000

            // Clamp the timespec tv_sec value to the maximum supported by the Darwin-kernel.
            // Whilst this schedules the event far into the future (several years) it will still be triggered provided
            // the system stays up.
            ts.tv_sec = min(ts.tv_sec, sysIntervalTimerMaxSec)

            return ts
        }
    }

//    deinit {
//        self.deinitAssertions0()
//        assert(self.registrations.count == 0, "left-over registrations: \(self.registrations)")
//        assert(self.lifecycleState == .closed, "Selector \(self.lifecycleState) (expected .closed) on deinit")
//        assert(self.selectorFD == -1, "self.selectorFD == \(self.selectorFD) on Selector deinit, forgot close?")
//        Selector.deallocateEventsArray(events: events, capacity: eventsCapacity)
//    }

    private static func allocateEventsArray(capacity: Int) -> UnsafeMutablePointer<kevent> {
        let events: UnsafeMutablePointer<kevent> = UnsafeMutablePointer.allocate(capacity: capacity)
        events.initialize(to: kevent())
        return events
    }

    private static func deallocateEventsArray(events: UnsafeMutablePointer<kevent>, capacity: Int) {
        events.deinitialize(count: capacity)
        events.deallocate()
    }

    private mutating func growEventArrayIfNeeded(ready: Int) {
//          assert(self.myThread == NIOThread.current)
        switch self.state {
        case .open(var open):
            Self.deallocateEventsArray(events: open.events, capacity: open.eventsCapacity)
            // double capacity
            open.eventsCapacity = ready << 1
            open.events = Self.allocateEventsArray(capacity: open.eventsCapacity)
            self.state = .open(open)

        case .closed:
            fatalError()
        }
      }

    /// Register `Selectable` on the `Selector`.
    ///
    /// - parameters:
    ///     - selectable: The `Selectable` to register.
    ///     - interested: The `SelectorEventSet` in which we are interested and want to be notified about.
    ///     - makeRegistration: Creates the registration data for the given `SelectorEventSet`.
    mutating func register<S: Selectable>(
        selectable: S,
        interested: SelectorEventSet,
        makeRegistration: (SelectorEventSet, SelectorRegistrationID) -> NewSelectorRegistration
    ) throws {
//        assert(self.myThread == NIOThread.current)
        assert(interested.contains(.reset))

        switch self.state {
        case .open(var open):
            try selectable.withUnsafeHandle { fd in
                assert(open.registrations[Int(fd)] == nil)
                try kqueueUpdateEventNotifications(
                    selectorFD: open.selectorFD,
                    selectable: selectable,
                    interested: interested,
                    oldInterested: nil,
                    registrationID: open.currentRegistrationID
                )
                let newRegistrationID = open.currentRegistrationID.nextRegistrationID()
                let registration = makeRegistration(interested, newRegistrationID)

                open.registrations[Int(fd)] = registration
                self.state = .open(open)
            }
        case .closed:
            throw IOError(errnoCode: EBADF, reason: "can't register on closed selector.")
        }
    }

    mutating func reregister<S: Selectable>(
        selectable: S,
        _ body: (inout NewSelectorRegistration) -> Void
    ) throws {
        // assert(self.myThread == NIOThread.current)

        switch self.state {
        case .open(var open):
            try selectable.withUnsafeHandle { fd in
                var registration = open.registrations[Int(fd)]!
                let oldInterested = registration.interested
                body(&registration)

                assert(registration.interested.contains(.reset), "must register for at least .reset but tried registering for \(registration.interested)")
                try kqueueUpdateEventNotifications(
                    selectorFD: open.selectorFD,
                    selectable: selectable,
                    interested: registration.interested,
                    oldInterested: oldInterested,
                    registrationID: registration.registrationID
                )
                open.registrations[Int(fd)] = registration
                self.state = .open(open)
            }
        case .closed:
            throw IOError(errnoCode: EBADF, reason: "can't re-register on closed selector.")
        }
    }

    mutating func deregister<S: Selectable>(
        selectable: S
    ) throws -> NewSelectorRegistration? {
//        assert(self.myThread == NIOThread.current)
        switch self.state {
        case .open(var open):
            return try selectable.withUnsafeHandle { fd in
                guard let registration = open.registrations.removeValue(forKey: Int(fd)) else {
                    return nil
                }
                self.state = .open(open)
                try kqueueUpdateEventNotifications(
                    selectorFD: open.selectorFD,
                    selectable: selectable,
                    interested: .reset,
                    oldInterested: registration.interested,
                    registrationID: open.currentRegistrationID
                )

                return registration
            }

        case .closed:
            throw IOError(errnoCode: EBADF, reason: "can't deregister from selector as it's closed.")
        }
    }

    mutating func whenReady(
        strategy: SelectorStrategy,
        onLoopBegin loopStart: () -> Void,
        _ body: (SelectorEventSet, inout NewSelectorRegistration) throws -> Void
    ) throws -> Void {
//        assert(self.myThread == NIOThread.current)

        switch self.state {
        case .open(var open):
            let timespec = Self.toKQueueTimeSpec(strategy: strategy)
            let ready = try timespec.withUnsafeOptionalPointer { ts in
                Int(try KQueue.kevent(
                    kq: open.selectorFD,
                    changelist: nil,
                    nchanges: 0,
                    eventlist: open.events,
                    nevents: Int32(open.eventsCapacity),
                    timeout: ts
                ))
            }

            loopStart()

            for i in 0..<ready {
                let ev = open.events[i]
                let filter = Int32(ev.filter)
                let eventRegistrationID = SelectorRegistrationID(kqueueUData: ev.udata)
                guard Int32(ev.flags) & EV_ERROR == 0 else {
                    throw IOError(errnoCode: Int32(ev.data), reason: "kevent returned with EV_ERROR set: \(String(describing: ev))")
                }
                guard filter != EVFILT_USER, var registration = open.registrations[Int(ev.ident)] else {
                    continue
                }
                guard eventRegistrationID == registration.registrationID else {
                    continue
                }
                var selectorEvent: SelectorEventSet = ._none
                switch filter {
                case EVFILT_READ:
                    selectorEvent.formUnion(.read)
                    fallthrough // falling through here as `EVFILT_READ` also delivers `EV_EOF` (meaning `.readEOF`)
                case EVFILT_EXCEPT:
                    if Int32(ev.flags) & EV_EOF != 0 && registration.interested.contains(.readEOF) {
                        // we only add `.readEOF` if it happened and the user asked for it
                        selectorEvent.formUnion(.readEOF)
                    }
                case EVFILT_WRITE:
                    selectorEvent.formUnion(.write)
                default:
                    // We only use EVFILT_USER, EVFILT_READ, EVFILT_EXCEPT and EVFILT_WRITE.
                    fatalError("unexpected filter \(ev.filter)")
                }
                if ev.fflags != 0 {
                    selectorEvent.formUnion(.reset)
                }
                // we can only verify the events for i == 0 as for i > 0 the user might have changed the registrations since then.
                assert(i != 0 || selectorEvent.isSubset(of: registration.interested), "selectorEvent: \(selectorEvent), registration: \(registration)")

                // in any case we only want what the user is currently registered for & what we got
                selectorEvent = selectorEvent.intersection(registration.interested)

                guard selectorEvent != ._none else {
                    continue
                }
                do {
                    try body(selectorEvent, &registration)
                    open.registrations[Int(ev.ident)] = registration
                    self.state = .open(open)
                } catch {
                    open.registrations[Int(ev.ident)] = registration
                    self.state = .open(open)
                    throw error
                }
            }

            self.growEventArrayIfNeeded(ready: ready)
        case .closed:
            throw IOError(errnoCode: EBADF, reason: "can't call whenReady for selector as it's closed.")
        }
    }
//
//    /// Close the `Selector`.
//    ///
//    /// After closing the `Selector` it's no longer possible to use it.
//    func close() throws {
//        assert(self.myThread == NIOThread.current)
//        guard self.lifecycleState == .open else {
//            throw IOError(errnoCode: EBADF, reason: "can't close selector as it's \(self.lifecycleState).")
//        }
//        try self.close0()
//        self.lifecycleState = .closed
//        self.registrations.removeAll()
//    }
//
    /* attention, this may (will!) be called from outside the event loop, ie. can't access mutable shared state (such as `self.open`) */
    func wakeup() throws {
//        assert(NIOThread.current != self.myThread)
        guard self._selectorFD >= 0 else {
            throw EventLoopError.shutdown
        }
        var event = kevent()
        event.ident = 0
        event.filter = Int16(EVFILT_USER)
        event.fflags = UInt32(NOTE_TRIGGER | NOTE_FFNOP)
        event.data = 0
        event.udata = nil
        event.flags = 0
        try withUnsafeMutablePointer(to: &event) { ptr in
            try Self.kqueueApplyEventChangeSet(selectorFD: self._selectorFD, keventBuffer: UnsafeMutableBufferPointer(start: ptr, count: 1))
        }
    }
}
