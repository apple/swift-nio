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

private enum SelectorLifecycleState {
    case open
    case closing
    case closed
}

private extension timespec {
    init(timeAmount amount: TimeAmount) {
        let nsecPerSec: Int = 1_000_000_000
        let ns = amount.nanoseconds
        let sec = ns / nsecPerSec
        self = timespec(tv_sec: sec, tv_nsec: ns - sec * nsecPerSec)
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
    #else
    private typealias EventType = kevent
    #endif

    private let fd: Int32
    private var eventsCapacity = 64
    private var events: UnsafeMutablePointer<EventType>
    private var registrations = [Int: R]()

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
        ev.events = Selector.toEpollEvents(interested: .read)
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

        try keventChangeSetOnly(event: &event, numEvents: 1)
#endif
    }

    deinit {
        assert(self.lifecycleState == .closed, "Selector \(self.lifecycleState) (expected .closed) on deinit")
        Selector.deallocateEventsArray(events: events, capacity: eventsCapacity)

        /* this is technically a bad idea as we're abusing ARC to deallocate scarce resources (a file descriptor)
         for us. However, this is used for the event loop so there shouldn't be much churn.
         The reson we do this is because `self.wakeup()` may (and will!) be called on arbitrary threads. To not
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

#if os(Linux)

    private static func toEpollEvents(interested: IOEvent) -> UInt32 {
        // Also merge EPOLLRDHUP in so we can easily detect connection-reset
        switch interested {
        case .read:
            return Epoll.EPOLLIN.rawValue | Epoll.EPOLLERR.rawValue | Epoll.EPOLLRDHUP.rawValue
        case .write:
            return Epoll.EPOLLOUT.rawValue | Epoll.EPOLLERR.rawValue | Epoll.EPOLLRDHUP.rawValue
        case .all:
            return Epoll.EPOLLIN.rawValue | Epoll.EPOLLOUT.rawValue | Epoll.EPOLLERR.rawValue | Epoll.EPOLLRDHUP.rawValue
        case .none:
            return Epoll.EPOLLERR.rawValue
        }
    }
#else
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

    private func keventChangeSetOnly(event: UnsafePointer<kevent>?, numEvents: Int32) throws {
        do {
            _ = try KQueue.kevent(kq: self.fd, changelist: event, nchanges: numEvents, eventlist: nil, nevents: 0, timeout: nil)
        } catch let err as IOError {
            if err.errnoCode == EINTR {
                // See https://www.freebsd.org/cgi/man.cgi?query=kqueue&sektion=2
                // When kevent() call fails with EINTR error, all changes in the changelist have been applied.
                return
            }
            throw err
        }
    }

    private func register_kqueue<S: Selectable>(selectable: S, interested: IOEvent, oldInterested: IOEvent?) throws {
        // Allocated on the stack
        var events = (kevent(), kevent())
        try selectable.withUnsafeFileDescriptor { fd in

            events.0.ident = UInt(fd)
            events.0.filter = Int16(EVFILT_READ)
            events.0.fflags = 0
            events.0.data = 0
            events.0.udata = nil

            events.1.ident = UInt(fd)
            events.1.filter = Int16(EVFILT_WRITE)
            events.1.fflags = 0
            events.1.data = 0
            events.1.udata = nil
        }

        switch interested {
        case .read:
            events.0.flags = UInt16(EV_ADD)
            events.1.flags = UInt16(EV_DELETE)
        case .write:
            events.0.flags = UInt16(EV_DELETE)
            events.1.flags = UInt16(EV_ADD)
        case .all:
            events.0.flags = UInt16(EV_ADD)
            events.1.flags = UInt16(EV_ADD)
        case .none:
            events.0.flags = UInt16(EV_DELETE)
            events.1.flags = UInt16(EV_DELETE)
        }

        var offset: Int = 0
        var numEvents: Int32 = 2

        if let old = oldInterested {
            switch old {
            case .read:
                if events.1.flags == UInt16(EV_DELETE) {
                    numEvents -= 1
                }
            case .write:
                if events.0.flags == UInt16(EV_DELETE) {
                    offset += 1
                    numEvents -= 1
                }
            case .none:
                // Only discard the delete events
                if events.0.flags == UInt16(EV_DELETE) {
                    offset += 1
                    numEvents -= 1
                }
                if events.1.flags == UInt16(EV_DELETE) {
                    numEvents -= 1
                }
            case .all:
                // No need to adjust anything
                break
            }
        } else {
            // If its not reregister operation we MUST NOT include EV_DELETE as otherwise kevent will fail with ENOENT.
            if events.0.flags == UInt16(EV_DELETE) {
                offset += 1
                numEvents -= 1
            }
            if events.1.flags == UInt16(EV_DELETE) {
                numEvents -= 1
            }
        }

        if numEvents > 0 {
            try withUnsafeMutableBytes(of: &events) { event_ptr in
                precondition(MemoryLayout<kevent>.size * 2 == event_ptr.count)
                let ptr = event_ptr.baseAddress?.bindMemory(to: kevent.self, capacity: 2)

                try keventChangeSetOnly(event: ptr!.advanced(by: offset), numEvents: numEvents)
            }
        }
    }
#endif

    /// Register `Selectable` on the `Selector`.
    ///
    /// - parameters:
    ///     - selectable: The `Selectable` to register.
    ///     - interested: The `IOEvent`s in which we are interested and want to be notified about.
    ///     - makeRegistration: Creates the registration data for the given `IOEvent`.
    func register<S: Selectable>(selectable: S, interested: IOEvent = .read, makeRegistration: (IOEvent) -> R) throws {
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't register on selector as it's \(self.lifecycleState).")
        }

        try selectable.withUnsafeFileDescriptor { fd in
            assert(registrations[Int(fd)] == nil)
            #if os(Linux)
                var ev = Epoll.epoll_event()
                ev.events = Selector.toEpollEvents(interested: interested)
                ev.data.fd = fd

                _ = try Epoll.epoll_ctl(epfd: self.fd, op: Epoll.EPOLL_CTL_ADD, fd: fd, event: &ev)
            #else
                try register_kqueue(selectable: selectable, interested: interested, oldInterested: nil)
            #endif
            registrations[Int(fd)] = makeRegistration(interested)
        }
    }

    /// Re-register `Selectable`, must be registered via `register` before.
    ///
    /// - parameters:
    ///     - selectable: The `Selectable` to re-register.
    ///     - interested: The `IOEvent`s in which we are interested and want to be notified about.
    func reregister<S: Selectable>(selectable: S, interested: IOEvent) throws {
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't re-register on selector as it's \(self.lifecycleState).")
        }
        try selectable.withUnsafeFileDescriptor { fd in
            var reg = registrations[Int(fd)]!

            #if os(Linux)
                var ev = Epoll.epoll_event()
                ev.events = Selector.toEpollEvents(interested: interested)
                ev.data.fd = fd

                _ = try Epoll.epoll_ctl(epfd: self.fd, op: Epoll.EPOLL_CTL_MOD, fd: fd, event: &ev)
            #else
                try register_kqueue(selectable: selectable, interested: interested, oldInterested: reg.interested)
            #endif
            reg.interested = interested
            registrations[Int(fd)] = reg
        }
    }

    /// Deregister `Selectable`, must be registered via `register` before.
    ///
    /// After the `Selectable is deregistered no `IOEvent`s will be produced anymore for the `Selectable`.
    ///
    /// - parameters:
    ///     - selectable: The `Selectable` to deregister.
    func deregister<S: Selectable>(selectable: S) throws {
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't deregister from selector as it's \(self.lifecycleState).")
        }
        try selectable.withUnsafeFileDescriptor { fd in
            guard let reg = registrations.removeValue(forKey: Int(fd)) else {
                return
            }

            #if os(Linux)
                var ev = Epoll.epoll_event()
                _ = try Epoll.epoll_ctl(epfd: self.fd, op: Epoll.EPOLL_CTL_DEL, fd: fd, event: &ev)
            #else
                try register_kqueue(selectable: selectable, interested: .none, oldInterested: reg.interested)
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
            var ts = itimerspec()
            ts.it_value = timespec(timeAmount: timeAmount)
            try TimerFd.timerfd_settime(fd: timerfd, flags: 0, newValue: &ts, oldValue: nil)
            fallthrough
        case .block:
            ready = Int(try Epoll.epoll_wait(epfd: self.fd, events: events, maxevents: Int32(eventsCapacity), timeout: -1))
        }

        for i in 0..<ready {
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
            default:
                let registration = registrations[Int(ev.data.fd)]!
                try body(
                    SelectorEvent(
                        readable: (ev.events & Epoll.EPOLLIN.rawValue) != 0 || (ev.events & Epoll.EPOLLERR.rawValue) != 0 || (ev.events & Epoll.EPOLLRDHUP.rawValue) != 0,
                        writable: (ev.events & Epoll.EPOLLOUT.rawValue) != 0 || (ev.events & Epoll.EPOLLERR.rawValue) != 0 || (ev.events & Epoll.EPOLLRDHUP.rawValue) != 0,
                        registration: registration))
            }
        }

        growEventArrayIfNeeded(ready: ready)
#else
        let timespec = toKQueueTimeSpec(strategy: strategy)
        let ready = try timespec.withUnsafeOptionalPointer { ts in
            Int(try KQueue.kevent(kq: self.fd, changelist: nil, nchanges: 0, eventlist: events, nevents: Int32(eventsCapacity), timeout: ts))
        }

        for i in 0..<ready {
            let ev = events[i]
            switch Int32(ev.filter) {
            case EVFILT_USER:
                // woken-up by the user, just ignore
                break
            case EVFILT_READ:
                if let registration = registrations[Int(ev.ident)] {
                    try body((SelectorEvent(readable: true, writable: false, registration: registration)))
                }
            case EVFILT_WRITE:
                if let registration = registrations[Int(ev.ident)] {
                    try body((SelectorEvent(readable: false, writable: true, registration: registration)))
                }
            default:
                // We only use EVFILT_USER, EVFILT_READ and EVFILT_WRITE.
                fatalError("unexpected filter \(ev.filter)")
            }
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
        try keventChangeSetOnly(event: &event, numEvents: 1)
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
    public let io: IOEvent

    /// Create new instance
    ///
    /// - parameters:
    ///     - readable: `true` if readable.
    ///     - writable: `true` if writable
    ///     - registration: The registration that belongs to the event.
    init(readable: Bool, writable: Bool, registration: R) {
        if readable {
            io = writable ? .all : .read
        } else if writable {
            io = .write
        } else {
            io = .none
        }
        self.registration = registration
    }
}

internal extension Selector where R == NIORegistration {
    /// Gently close the `Selector` after all registered `Channel`s are closed.
    internal func closeGently(eventLoop: EventLoop) -> EventLoopFuture<Void> {
        let p0: EventLoopPromise<Void> = eventLoop.newPromise()
        guard self.lifecycleState == .open else {
            p0.fail(error: IOError(errnoCode: EBADF, reason: "can't close selector gently as it's \(self.lifecycleState)."))
            return p0.futureResult
        }

        let futures: [EventLoopFuture<Void>] = self.registrations.map { (_, reg: NIORegistration) -> EventLoopFuture<Void> in
            switch reg {
            case .serverSocketChannel(let chan, _):
                return chan.close()
            case .socketChannel(let chan, _):
                return chan.close()
            case .datagramChannel(let chan, _):
                return chan.close()
            }
        }

        guard futures.count > 0 else {
            p0.succeed(result: ())
            return p0.futureResult
        }

        p0.succeed(result: ())
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
public enum IOEvent {
    /// Something is ready to be read.
    case read

    /// Its possible to write some data again.
    case write

    /// Combination of `read` and `write`.
    case all

    /// Not interested in any event.
    case none
}
