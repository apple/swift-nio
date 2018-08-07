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

import Dispatch

private enum SelectorLifecycleState {
    case open
    case closing
    case closed
}

private extension timespec {
    init(timeAmount amount: TimeAmount) {
        let nsecPerSec: TimeAmount.Value = 1_000_000_000
        let ns = amount.nanoseconds
        let sec = ns / nsecPerSec
        self = timespec(tv_sec: Int(sec), tv_nsec: Int(ns - sec * nsecPerSec))
    }
}

private extension Optional {
    func withUnsafeOptionalPointer<T>(_ body: (UnsafePointer<Wrapped>?) throws -> T) rethrows -> T {
        if var this = self {
            return try withUnsafePointer(to: &this) { x in
                try body(x)
            }
        } else {
            return try body(nil)
        }
    }
}

/// Represents IO events NIO might be interested in. `SelectorEventSet` is used for two purposes:
///  1. To express interest in a given event set and
///  2. for notifications about an IO event set that has occured.
///
/// For example, if you were interested in reading and writing data from/to a socket and also obviously if the socket
/// receives a connection reset, express interest with `[.read, .write, .reset]`.
/// If then suddenly the socket becomes both readable and writable, the eventing mechanism will tell you about that
/// fact using `[.read, .write]`.
struct SelectorEventSet: OptionSet, Equatable {

    typealias RawValue = UInt8

    let rawValue: RawValue

    /// It's impossible to actually register for no events, therefore `_none` should only be used to bootstrap a set
    /// of flags or to compare against spurious wakeups.
    static let _none = SelectorEventSet(rawValue: 0)

    /// Connection reset or other errors.
    static let reset = SelectorEventSet(rawValue: 1 << 0)

    /// EOF at the read/input end of a `Selectable`.
    static let readEOF = SelectorEventSet(rawValue: 1 << 1)

    /// Interest in/availability of data to be read
    static let read = SelectorEventSet(rawValue: 1 << 2)

    /// Interest in/availability of data to be written
    static let write = SelectorEventSet(rawValue: 1 << 3)

    init(rawValue: SelectorEventSet.RawValue) {
        self.rawValue = rawValue
    }
}

/// Represents the `kqueue` filters we might use:
///
///  - `except` corresponds to `EVFILT_EXCEPT`
///  - `read` corresponds to `EVFILT_READ`
///  - `write` corresponds to `EVFILT_WRITE`
private struct KQueueEventFilterSet: OptionSet, Equatable {
    typealias RawValue = UInt8

    let rawValue: RawValue

    static let _none = KQueueEventFilterSet(rawValue: 0)
    // skipping `1 << 0` because kqueue doesn't have a direct match for `.reset` (`EPOLLHUP` for epoll)
    static let except = KQueueEventFilterSet(rawValue: 1 << 1)
    static let read = KQueueEventFilterSet(rawValue: 1 << 2)
    static let write = KQueueEventFilterSet(rawValue: 1 << 3)

    init(rawValue: RawValue) {
        self.rawValue = rawValue
    }
}

/// Represents the `epoll` filters/events we might use:
///
///  - `hangup` corresponds to `EPOLLHUP`
///  - `readHangup` corresponds to `EPOLLRDHUP`
///  - `input` corresponds to `EPOLLIN`
///  - `output` corresponds to `EPOLLOUT`
///  - `error` corresponds to `EPOLLERR`
private struct EpollFilterSet: OptionSet, Equatable {
    typealias RawValue = UInt8

    let rawValue: RawValue

    static let _none = EpollFilterSet(rawValue: 0)
    static let hangup = EpollFilterSet(rawValue: 1 << 0)
    static let readHangup = EpollFilterSet(rawValue: 1 << 1)
    static let input = EpollFilterSet(rawValue: 1 << 2)
    static let output = EpollFilterSet(rawValue: 1 << 3)
    static let error = EpollFilterSet(rawValue: 1 << 4)

    init(rawValue: RawValue) {
        self.rawValue = rawValue
    }
}

extension KQueueEventFilterSet {
    /// Convert NIO's `SelectorEventSet` set to a `KQueueEventFilterSet`
    init(selectorEventSet: SelectorEventSet) {
        var kqueueFilterSet: KQueueEventFilterSet = .init(rawValue: 0)
        if selectorEventSet.contains(.read) {
            kqueueFilterSet.formUnion(.read)
        }

        if selectorEventSet.contains(.write) {
            kqueueFilterSet.formUnion(.write)
        }

        if selectorEventSet.contains(.readEOF) {
            kqueueFilterSet.formUnion(.except)
        }
        self = kqueueFilterSet
    }

    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    /// Calculate the kqueue filter changes that are necessary to transition from `previousKQueueFilterSet` to `self`.
    /// The `body` closure is then called with the changes necessary expressed as a number of `kevent`.
    ///
    /// - parameters:
    ///    - previousKQueueFilterSet: The previous filter set that is currently registered with kqueue.
    ///    - fileDescriptor: The file descriptor the `kevent`s should be generated to.
    ///    - body: The closure that will then apply the change set.
    func calculateKQueueFilterSetChanges(previousKQueueFilterSet: KQueueEventFilterSet,
                                         fileDescriptor: CInt,
                                         _ body: (UnsafeMutableBufferPointer<kevent>) throws -> Void) rethrows {
        // we only use three filters (EVFILT_READ, EVFILT_WRITE and EVFILT_EXCEPT) so the number of changes would be 3.
        var keventsHopefullyOnStack = (kevent(), kevent(), kevent())
        try withUnsafeMutableBytes(of: &keventsHopefullyOnStack) { rawPtr in
            assert(MemoryLayout<kevent>.size * 3 == rawPtr.count)
            let keventBuffer = rawPtr.baseAddress!.bindMemory(to: kevent.self, capacity: 3)

            let differences = previousKQueueFilterSet.symmetricDifference(self) // contains all the events that need a change (either need to be added or removed)

            func calculateKQueueChange(event: KQueueEventFilterSet) -> UInt16? {
                guard differences.contains(event) else {
                    return nil
                }
                return UInt16(self.contains(event) ? EV_ADD : EV_DELETE)
            }

            var index: Int = 0
            for (event, filter) in [(KQueueEventFilterSet.read, EVFILT_READ), (.write, EVFILT_WRITE), (.except, EVFILT_EXCEPT)] {
                if let flags = calculateKQueueChange(event: event) {
                    keventBuffer[index].setEvent(fileDescriptor: fileDescriptor, filter: filter, flags: flags)
                    index += 1
                }
            }
            try body(UnsafeMutableBufferPointer(start: keventBuffer, count: index))
        }
    }
    #endif
}

extension EpollFilterSet {
    /// Convert NIO's `SelectorEventSet` set to a `EpollFilterSet`
    init(selectorEventSet: SelectorEventSet) {
        var thing: EpollFilterSet = [.error, .hangup]
        if selectorEventSet.contains(.read) {
            thing.formUnion(.input)
        }
        if selectorEventSet.contains(.write) {
            thing.formUnion(.output)
        }
        if selectorEventSet.contains(.readEOF) {
            thing.formUnion(.readHangup)
        }
        self = thing
    }
}

extension SelectorEventSet {
    #if os(Linux)
    var epollEventSet: UInt32 {
        assert(self != ._none)
        // EPOLLERR | EPOLLHUP is always set unconditionally anyway but it's easier to understand if we explicitly ask.
        var filter: UInt32 = Epoll.EPOLLERR.rawValue | Epoll.EPOLLHUP.rawValue
        let epollFilters = EpollFilterSet(selectorEventSet: self)
        if epollFilters.contains(.input) {
            filter |= Epoll.EPOLLIN.rawValue
        }
        if epollFilters.contains(.output) {
            filter |= Epoll.EPOLLOUT.rawValue
        }
        if epollFilters.contains(.readHangup) {
            filter |= Epoll.EPOLLRDHUP.rawValue
        }
        assert(filter & Epoll.EPOLLHUP.rawValue != 0) // both of these are reported
        assert(filter & Epoll.EPOLLERR.rawValue != 0) // always and can't be masked.
        return filter
    }

    fileprivate init(epollEvent: Epoll.epoll_event) {
        var selectorEventSet: SelectorEventSet = ._none
        if epollEvent.events & Epoll.EPOLLIN.rawValue != 0 {
            selectorEventSet.formUnion(.read)
        }
        if epollEvent.events & Epoll.EPOLLOUT.rawValue != 0 {
            selectorEventSet.formUnion(.write)
        }
        if epollEvent.events & Epoll.EPOLLRDHUP.rawValue != 0 {
            selectorEventSet.formUnion(.readEOF)
        }
        if epollEvent.events & Epoll.EPOLLHUP.rawValue != 0 || epollEvent.events & Epoll.EPOLLERR.rawValue != 0 {
            selectorEventSet.formUnion(.reset)
        }
        self = selectorEventSet
    }

    #endif
}


///  A `Selector` allows a user to register different `Selectable` sources to an underlying OS selector, and for that selector to notify them once IO is ready for them to process.
///
/// This implementation offers an consistent API over epoll (for linux) and kqueue (for Darwin, BSD).
/* this is deliberately not thread-safe, only the wakeup() function may be called unprotectedly */
final class Selector<R: Registration> {
    private var lifecycleState: SelectorLifecycleState

    #if os(Linux)
    private typealias EventType = Epoll.epoll_event
    private let eventfd: Int32
    private let timerfd: Int32
    private var earliestTimer: UInt64 = UInt64.max
    #else
    private typealias EventType = kevent
    #endif

    private let fd: Int32
    private var eventsCapacity = 64
    private var events: UnsafeMutablePointer<EventType>
    private var registrations = [Int: R]()
    // temporary workaround to stop us delivering outdated events; read in `whenReady`, set in `deregister`
    private var deregistrationsHappened: Bool = false

    private static func allocateEventsArray(capacity: Int) -> UnsafeMutablePointer<EventType> {
        let events: UnsafeMutablePointer<EventType> = UnsafeMutablePointer.allocate(capacity: capacity)
        events.initialize(to: EventType())
        return events
    }

    private static func deallocateEventsArray(events: UnsafeMutablePointer<EventType>, capacity: Int) {
        events.deinitialize(count: capacity)
        events.deallocate()
    }

    private func growEventArrayIfNeeded(ready: Int) {
        guard ready == eventsCapacity else {
            return
        }
        Selector.deallocateEventsArray(events: events, capacity: eventsCapacity)

        // double capacity
        eventsCapacity = ready << 1
        events = Selector.allocateEventsArray(capacity: eventsCapacity)
    }

    init() throws {
        events = Selector.allocateEventsArray(capacity: eventsCapacity)
        self.lifecycleState = .closed

#if os(Linux)
        fd = try Epoll.epoll_create(size: 128)
        eventfd = try EventFd.eventfd(initval: 0, flags: Int32(EventFd.EFD_CLOEXEC | EventFd.EFD_NONBLOCK))
        timerfd = try TimerFd.timerfd_create(clockId: CLOCK_MONOTONIC, flags: Int32(TimerFd.TFD_CLOEXEC | TimerFd.TFD_NONBLOCK))

        self.lifecycleState = .open

        var ev = Epoll.epoll_event()
        ev.events = SelectorEventSet.read.epollEventSet
        ev.data.fd = eventfd

        _ = try Epoll.epoll_ctl(epfd: self.fd, op: Epoll.EPOLL_CTL_ADD, fd: eventfd, event: &ev)

        var timerev = Epoll.epoll_event()
        timerev.events = Epoll.EPOLLIN.rawValue | Epoll.EPOLLERR.rawValue | Epoll.EPOLLRDHUP.rawValue | Epoll.EPOLLET.rawValue
        timerev.data.fd = timerfd
        _ = try Epoll.epoll_ctl(epfd: self.fd, op: Epoll.EPOLL_CTL_ADD, fd: timerfd, event: &timerev)
#else
        fd = try KQueue.kqueue()
        self.lifecycleState = .open

        var event = kevent()
        event.ident = 0
        event.filter = Int16(EVFILT_USER)
        event.fflags = UInt32(NOTE_FFNOP)
        event.data = 0
        event.udata = nil
        event.flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR)
        try withUnsafeMutablePointer(to: &event) { ptr in
            try kqueueApplyEventChangeSet(keventBuffer: UnsafeMutableBufferPointer(start: ptr, count: 1))
        }
#endif
    }

    deinit {
        assert(self.lifecycleState == .closed, "Selector \(self.lifecycleState) (expected .closed) on deinit")
        Selector.deallocateEventsArray(events: events, capacity: eventsCapacity)

        /* this is technically a bad idea as we're abusing ARC to deallocate scarce resources (a file descriptor)
         for us. However, this is used for the event loop so there shouldn't be much churn.
         The reason we do this is because `self.wakeup()` may (and will!) be called on arbitrary threads. To not
         suffer from race conditions we would need to protect waking the selector up and closing the selector. That
         is likely to cause performance problems. By abusing ARC, we get the guarantee that there won't be any future
         wakeup calls as there are no references to this selector left. 💁
         */
#if os(Linux)
        try! Posix.close(descriptor: self.eventfd)
#else
        try! Posix.close(descriptor: self.fd)
#endif
    }


#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    private func toKQueueTimeSpec(strategy: SelectorStrategy) -> timespec? {
        switch strategy {
        case .block:
            return nil
        case .now:
            return timespec(tv_sec: 0, tv_nsec: 0)
        case .blockUntilTimeout(let nanoseconds):
            return timespec(timeAmount: nanoseconds)
        }
    }

    /// Apply a kqueue changeset by calling the `kevent` function with the `kevent`s supplied in `keventBuffer`.
    private func kqueueApplyEventChangeSet(keventBuffer: UnsafeMutableBufferPointer<kevent>) throws {
        guard keventBuffer.count > 0 else {
            // nothing to do
            return
        }
        do {
            _ = try KQueue.kevent(kq: self.fd,
                                  changelist: keventBuffer.baseAddress!,
                                  nchanges: CInt(keventBuffer.count),
                                  eventlist: nil,
                                  nevents: 0,
                                  timeout: nil)
        } catch let err as IOError {
            if err.errnoCode == EINTR {
                // See https://www.freebsd.org/cgi/man.cgi?query=kqueue&sektion=2
                // When kevent() call fails with EINTR error, all changes in the changelist have been applied.
                return
            }
            throw err
        }
    }


    private func kqueueUpdateEventNotifications<S: Selectable>(selectable: S, interested: SelectorEventSet, oldInterested: SelectorEventSet?) throws {
        let oldKQueueFilters = KQueueEventFilterSet(selectorEventSet: oldInterested ?? ._none)
        let newKQueueFilters = KQueueEventFilterSet(selectorEventSet: interested)
        assert(interested.contains(.reset))
        assert(oldInterested?.contains(.reset) ?? true)

        try selectable.withUnsafeFileDescriptor { fd in
            try newKQueueFilters.calculateKQueueFilterSetChanges(previousKQueueFilterSet: oldKQueueFilters,
                                                                 fileDescriptor: fd,
                                                                 kqueueApplyEventChangeSet)
        }
    }
#endif

    /// Register `Selectable` on the `Selector`.
    ///
    /// - parameters:
    ///     - selectable: The `Selectable` to register.
    ///     - interested: The `SelectorEventSet` in which we are interested and want to be notified about.
    ///     - makeRegistration: Creates the registration data for the given `SelectorEventSet`.
    func register<S: Selectable>(selectable: S, interested: SelectorEventSet, makeRegistration: (SelectorEventSet) -> R) throws {
        assert(interested.contains(.reset))
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't register on selector as it's \(self.lifecycleState).")
        }

        try selectable.withUnsafeFileDescriptor { fd in
            assert(registrations[Int(fd)] == nil)
            #if os(Linux)
                var ev = Epoll.epoll_event()
                ev.events = interested.epollEventSet
                ev.data.fd = fd

                _ = try Epoll.epoll_ctl(epfd: self.fd, op: Epoll.EPOLL_CTL_ADD, fd: fd, event: &ev)
            #else
                try kqueueUpdateEventNotifications(selectable: selectable, interested: interested, oldInterested: nil)
            #endif
            registrations[Int(fd)] = makeRegistration(interested)
        }
    }

    /// Re-register `Selectable`, must be registered via `register` before.
    ///
    /// - parameters:
    ///     - selectable: The `Selectable` to re-register.
    ///     - interested: The `SelectorEventSet` in which we are interested and want to be notified about.
    func reregister<S: Selectable>(selectable: S, interested: SelectorEventSet) throws {
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't re-register on selector as it's \(self.lifecycleState).")
        }
        assert(interested.contains(.reset), "must register for at least .reset but tried registering for \(interested)")
        try selectable.withUnsafeFileDescriptor { fd in
            var reg = registrations[Int(fd)]!

            #if os(Linux)
                var ev = Epoll.epoll_event()
                ev.events = interested.epollEventSet
                ev.data.fd = fd

                _ = try Epoll.epoll_ctl(epfd: self.fd, op: Epoll.EPOLL_CTL_MOD, fd: fd, event: &ev)
            #else
                try kqueueUpdateEventNotifications(selectable: selectable, interested: interested, oldInterested: reg.interested)
            #endif
            reg.interested = interested
            registrations[Int(fd)] = reg
        }
    }

    /// Deregister `Selectable`, must be registered via `register` before.
    ///
    /// After the `Selectable is deregistered no `SelectorEventSet` will be produced anymore for the `Selectable`.
    ///
    /// - parameters:
    ///     - selectable: The `Selectable` to deregister.
    func deregister<S: Selectable>(selectable: S) throws {
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't deregister from selector as it's \(self.lifecycleState).")
        }
        // temporary workaround to stop us delivering outdated events
        self.deregistrationsHappened = true
        try selectable.withUnsafeFileDescriptor { fd in
            guard let reg = registrations.removeValue(forKey: Int(fd)) else {
                return
            }

            #if os(Linux)
                var ev = Epoll.epoll_event()
                _ = try Epoll.epoll_ctl(epfd: self.fd, op: Epoll.EPOLL_CTL_DEL, fd: fd, event: &ev)
            #else
                try kqueueUpdateEventNotifications(selectable: selectable, interested: .reset, oldInterested: reg.interested)
            #endif
        }
    }

    /// Apply the given `SelectorStrategy` and execute `fn` once it's complete (which may produce `SelectorEvent`s to handle).
    ///
    /// - parameters:
    ///     - strategy: The `SelectorStrategy` to apply
    ///     - body: The function to execute for each `SelectorEvent` that was produced.
    func whenReady(strategy: SelectorStrategy, _ body: (SelectorEvent<R>) throws -> Void) throws -> Void {
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't call whenReady for selector as it's \(self.lifecycleState).")
        }

#if os(Linux)
        let ready: Int

        switch strategy {
        case .now:
            ready = Int(try Epoll.epoll_wait(epfd: self.fd, events: events, maxevents: Int32(eventsCapacity), timeout: 0))
        case .blockUntilTimeout(let timeAmount):
            // Only call timerfd_settime if we not already scheduled one that will cover it.
            // This guards against calling timerfd_settime if not needed as this is generally speaking
            // expensive.
            let next = DispatchTime.now().uptimeNanoseconds + UInt64(timeAmount.nanoseconds)
            if next < self.earliestTimer {
                self.earliestTimer = next

                var ts = itimerspec()
                ts.it_value = timespec(timeAmount: timeAmount)
                try TimerFd.timerfd_settime(fd: timerfd, flags: 0, newValue: &ts, oldValue: nil)
            }
            fallthrough
        case .block:
            ready = Int(try Epoll.epoll_wait(epfd: self.fd, events: events, maxevents: Int32(eventsCapacity), timeout: -1))
        }

        // start with no deregistrations happened
        self.deregistrationsHappened = false
        // temporary workaround to stop us delivering outdated events; possibly set in `deregister`
        for i in 0..<ready where !self.deregistrationsHappened {
            let ev = events[i]
            switch ev.data.fd {
            case eventfd:
                var val = EventFd.eventfd_t()
                // Consume event
                _ = try EventFd.eventfd_read(fd: eventfd, value: &val)
            case timerfd:
                // Consume event
                var val: UInt = 0
                // We are not interested in the result
                _ = Glibc.read(timerfd, &val, MemoryLayout<UInt>.size)

                // Processed the earliest set timer so reset it.
                self.earliestTimer = UInt64.max
            default:
                // If the registration is not in the Map anymore we deregistered it during the processing of whenReady(...). In this case just skip it.
                if let registration = registrations[Int(ev.data.fd)] {
                    var selectorEvent = SelectorEventSet(epollEvent: ev)
                    // we can only verify the events for i == 0 as for i > 0 the user might have changed the registrations since then.
                    assert(i != 0 || selectorEvent.isSubset(of: registration.interested), "selectorEvent: \(selectorEvent), registration: \(registration)")

                    // in any case we only want what the user is currently registered for & what we got
                    selectorEvent = selectorEvent.intersection(registration.interested)

                    guard selectorEvent != ._none else {
                        continue
                    }

                    try body((SelectorEvent(io: selectorEvent, registration: registration)))
                }
            }
        }
        growEventArrayIfNeeded(ready: ready)
#else
        let timespec = toKQueueTimeSpec(strategy: strategy)
        let ready = try timespec.withUnsafeOptionalPointer { ts in
            Int(try KQueue.kevent(kq: self.fd, changelist: nil, nchanges: 0, eventlist: events, nevents: Int32(eventsCapacity), timeout: ts))
        }

        // start with no deregistrations happened
        self.deregistrationsHappened = false
        // temporary workaround to stop us delivering outdated events; possibly set in `deregister`
        for i in 0..<ready where !self.deregistrationsHappened {
            let ev = events[i]
            let filter = Int32(ev.filter)
            guard Int32(ev.flags) & EV_ERROR == 0 else {
                throw IOError(errnoCode: Int32(ev.data), reason: "kevent returned with EV_ERROR set: \(String(describing: ev))")
            }
            guard filter != EVFILT_USER, let registration = registrations[Int(ev.ident)] else {
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
            try body((SelectorEvent(io: selectorEvent, registration: registration)))
        }

        growEventArrayIfNeeded(ready: ready)
#endif
    }

    /// Close the `Selector`.
    ///
    /// After closing the `Selector` it's no longer possible to use it.
    public func close() throws {
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't close selector as it's \(self.lifecycleState).")
        }
        self.lifecycleState = .closed

        self.registrations.removeAll()

        /* note, we can't close `self.fd` (on macOS) or `self.eventfd` (on Linux) here as that's read unprotectedly and might lead to race conditions. Instead, we abuse ARC to close it for us. */
#if os(Linux)
        _ = try Posix.close(descriptor: self.timerfd)
#endif

#if os(Linux)
        /* `self.fd` is used as the event file descriptor to wake kevent() up so can't be closed here on macOS */
        _ = try Posix.close(descriptor: self.fd)
#endif
    }

    /* attention, this may (will!) be called from outside the event loop, ie. can't access mutable shared state (such as `self.open`) */
    func wakeup() throws {

#if os(Linux)
        /* this is fine as we're abusing ARC to close `self.eventfd` */
        _ = try EventFd.eventfd_write(fd: self.eventfd, value: 1)
#else
        var event = kevent()
        event.ident = 0
        event.filter = Int16(EVFILT_USER)
        event.fflags = UInt32(NOTE_TRIGGER | NOTE_FFNOP)
        event.data = 0
        event.udata = nil
        event.flags = 0
        try withUnsafeMutablePointer(to: &event) { ptr in
            try kqueueApplyEventChangeSet(keventBuffer: UnsafeMutableBufferPointer(start: ptr, count: 1))
        }
#endif
    }
}

extension Selector: CustomStringConvertible {
    var description: String {
        return "Selector { descriptor = \(self.fd) }"
    }
}

/// An event that is triggered once the `Selector` was able to select something.
struct SelectorEvent<R> {
    public let registration: R
    public let io: SelectorEventSet

    /// Create new instance
    ///
    /// - parameters:
    ///     - io: The `SelectorEventSet` that triggered this event.
    ///     - registration: The registration that belongs to the event.
    init(io: SelectorEventSet, registration: R) {
        self.io = io
        self.registration = registration
    }
}

internal extension Selector where R == NIORegistration {
    /// Gently close the `Selector` after all registered `Channel`s are closed.
    internal func closeGently(eventLoop: EventLoop) -> EventLoopFuture<Void> {
        guard self.lifecycleState == .open else {
            return eventLoop.newFailedFuture(error: IOError(errnoCode: EBADF, reason: "can't close selector gently as it's \(self.lifecycleState)."))
        }

        let futures: [EventLoopFuture<Void>] = self.registrations.map { (_, reg: NIORegistration) -> EventLoopFuture<Void> in
            // The futures will only be notified (of success) once also the closeFuture of each Channel is notified.
            // This only happens after all other actions on the Channel is complete and all events are propagated through the
            // ChannelPipeline. We do this to minimize the risk to left over any tasks / promises that are tied to the
            // EventLoop itself.
            func closeChannel(_ chan: Channel) -> EventLoopFuture<Void> {
                chan.close(promise: nil)
                return chan.closeFuture
            }

            switch reg {
            case .serverSocketChannel(let chan, _):
                return closeChannel(chan)
            case .socketChannel(let chan, _):
                return closeChannel(chan)
            case .datagramChannel(let chan, _):
                return closeChannel(chan)
            }
        }.map { future in
            future.thenIfErrorThrowing { error in
                if let error = error as? ChannelError, error == .alreadyClosed {
                    return ()
                } else {
                    throw error
                }
            }
        }

        guard futures.count > 0 else {
            return eventLoop.newSucceededFuture(result: ())
        }

        return EventLoopFuture<Void>.andAll(futures, eventLoop: eventLoop)
    }
}

/// The strategy used for the `Selector`.
enum SelectorStrategy {
    /// Block until there is some IO ready to be processed or the `Selector` is explicitly woken up.
    case block

    /// Block until there is some IO ready to be processed, the `Selector` is explicitly woken up or the given `TimeAmount` elapsed.
    case blockUntilTimeout(TimeAmount)

    /// Try to select all ready IO at this point in time without blocking at all.
    case now
}

/// The IO for which we want to be notified.
@available(*, deprecated, message: "IOEvent was made public by accident, is no longer used internally and will be removed with SwiftNIO 2.0.0")
public enum IOEvent {
    /// Something is ready to be read.
    case read

    /// It's possible to write some data again.
    case write

    /// Combination of `read` and `write`.
    case all

    /// Not interested in any event.
    case none
}


#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
extension kevent {
    /// Update a kevent for a given filter, file descriptor, and set of flags.
    mutating func setEvent(fileDescriptor fd: CInt, filter: CInt, flags: UInt16) {
        self.ident = UInt(fd)
        self.filter = Int16(filter)
        self.flags = flags
        self.udata = nil

        // On macOS, EVFILT_EXCEPT will fire whenever there is unread data in the socket receive
        // buffer. This is not a behaviour we want from EVFILT_EXCEPT: we only want it to tell us
        // about actually exceptional conditions. For this reason, when we set EVFILT_EXCEPT
        // we do it with NOTE_LOWAT set to Int.max, which will ensure that there is never enough data
        // in the send buffer to trigger EVFILT_EXCEPT. Thanks to the sensible design of kqueue,
        // this only affects our EXCEPT filter: EVFILT_READ behaves separately.
        if filter == EVFILT_EXCEPT {
            self.fflags = CUnsignedInt(NOTE_LOWAT)
            self.data = Int.max
        } else {
            self.fflags = 0
            self.data = 0
        }
    }
}
#endif
