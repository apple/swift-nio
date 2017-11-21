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

#if os(Linux)
import Glibc
#else
import Darwin
#endif

private enum SelectorLifecycleState {
    case open
    case closing
    case closed
}

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
        events.deinitialize()
        events.deallocate(capacity: capacity)
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
            return Epoll.EPOLLERR.rawValue | Epoll.EPOLLRDHUP.rawValue
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
            return toTimerspec(nanoseconds)
        }
    }

    private func keventChangeSetOnly(event: UnsafePointer<kevent>?, numEvents: Int32) throws {
        do {
            _ = try KQueue.kevent0(kq: self.fd, changelist: event, nchanges: numEvents, eventlist: nil, nevents: 0, timeout: nil)
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

        events.0.ident = UInt(selectable.descriptor)
        events.0.filter = Int16(EVFILT_READ)
        events.0.fflags = 0
        events.0.data = 0
        events.0.udata = nil

        events.1.ident = UInt(selectable.descriptor)
        events.1.filter = Int16(EVFILT_WRITE)
        events.1.fflags = 0
        events.1.data = 0
        events.1.udata = nil

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

    func register<S: Selectable>(selectable: S, interested: IOEvent = .read, makeRegistration: (IOEvent) -> R) throws {
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't register on selector as it's \(self.lifecycleState).")
        }
        
        assert(selectable.open)
        assert(registrations[Int(selectable.descriptor)] == nil)
#if os(Linux)
        var ev = Epoll.epoll_event()
        ev.events = Selector.toEpollEvents(interested: interested)
        ev.data.fd = selectable.descriptor

        _ = try Epoll.epoll_ctl(epfd: self.fd, op: Epoll.EPOLL_CTL_ADD, fd:  selectable.descriptor, event: &ev)
#else
        try register_kqueue(selectable: selectable, interested: interested, oldInterested: nil)
#endif
        registrations[Int(selectable.descriptor)] = makeRegistration(interested)
    }

    func reregister<S: Selectable>(selectable: S, interested: IOEvent) throws {
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't re-register on selector as it's \(self.lifecycleState).")
        }
        assert(selectable.open)
        
        var reg = registrations[Int(selectable.descriptor)]!

#if os(Linux)
        var ev = Epoll.epoll_event()
        ev.events = Selector.toEpollEvents(interested: interested)
        ev.data.fd = selectable.descriptor

        _ = try Epoll.epoll_ctl(epfd: self.fd, op: Epoll.EPOLL_CTL_MOD, fd:  selectable.descriptor, event: &ev)
#else
        try register_kqueue(selectable: selectable, interested: interested, oldInterested: reg.interested)
#endif
        reg.interested = interested
        registrations[Int(selectable.descriptor)] = reg
    }

    func deregister<S: Selectable>(selectable: S) throws {
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't deregister from selector as it's \(self.lifecycleState).")
        }
        assert(selectable.open)
        
        guard let reg = registrations.removeValue(forKey: Int(selectable.descriptor)) else {
            return
        }
        
#if os(Linux)
        var ev = Epoll.epoll_event()
        _ = try Epoll.epoll_ctl(epfd: self.fd, op: Epoll.EPOLL_CTL_DEL, fd:  selectable.descriptor, event: &ev)
#else
        try register_kqueue(selectable: selectable, interested: .none, oldInterested: reg.interested)
#endif
    }

     func whenReady(strategy: SelectorStrategy, _ fn: (SelectorEvent<R>) throws -> Void) throws -> Void {
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't call whenReady for selector as it's \(self.lifecycleState).")
        }

#if os(Linux)
        let ready: Int
    
        switch strategy {
        case .now:
            ready = Int(try Epoll.epoll_wait(epfd: self.fd, events: events, maxevents: Int32(eventsCapacity), timeout: 0))
        case .blockUntilTimeout(let nanoseconds):
            var ts = itimerspec()
            ts.it_value = toTimerspec(nanoseconds)
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
                try fn(
                    SelectorEvent(
                        readable: (ev.events & Epoll.EPOLLIN.rawValue) != 0 || (ev.events & Epoll.EPOLLERR.rawValue) != 0 || (ev.events & Epoll.EPOLLRDHUP.rawValue) != 0,
                        writable: (ev.events & Epoll.EPOLLOUT.rawValue) != 0 || (ev.events & Epoll.EPOLLERR.rawValue) != 0 || (ev.events & Epoll.EPOLLRDHUP.rawValue) != 0,
                        registration: registration))
            }
        }
    
        growEventArrayIfNeeded(ready: ready)
#else
        let timespec = toKQueueTimeSpec(strategy: strategy)

        let ready: Int
        if var ts = timespec {
            ready = Int(try KQueue.kevent0(kq: self.fd, changelist: nil, nchanges: 0, eventlist: events, nevents: Int32(eventsCapacity), timeout: &ts))
        } else {
            ready = Int(try KQueue.kevent0(kq: self.fd, changelist: nil, nchanges: 0, eventlist: events, nevents: Int32(eventsCapacity), timeout: nil))
        }
    
        for i in 0..<ready {
            let ev = events[i]
            switch Int32(ev.filter) {
            case EVFILT_USER:
                // woken-up by the user, just ignore
                break
            case EVFILT_READ:
                if let registration = registrations[Int(ev.ident)] {
                    try fn((SelectorEvent(readable: true, writable: false, registration: registration)))
                }
            case EVFILT_WRITE:
                if let registration = registrations[Int(ev.ident)] {
                    try fn((SelectorEvent(readable: false, writable: true, registration: registration)))
                }
            default:
                // We only use EVFILT_USER, EVFILT_READ and EVFILT_WRITE.
                fatalError("unexpected filter \(ev.filter)")
            }
        }
    
        growEventArrayIfNeeded(ready: ready)
#endif
    }

    private func toTimerspec(_ nanoseconds: UInt64) -> timespec {
        let delaySeconds = nanoseconds / 1000000000
        let delayNanoSeconds = nanoseconds - delaySeconds * 1000000000
        return timespec(tv_sec: Int(delaySeconds), tv_nsec: Int(delayNanoSeconds))
    }
    
    public func close() throws {
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't close selector as it's \(self.lifecycleState).")
        }
        self.lifecycleState = .closed

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
        /* this is fine as we're abusing ARC to close `self.eventfd`) */
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

struct SelectorEvent<R> {
    public let registration: R
    public let io: IOEvent
    
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

enum SelectorStrategy {
    case block
    case blockUntilTimeout(nanoseconds: UInt64)
    case now
}

public enum IOEvent {
    case read
    case write
    case all
    case none
}
