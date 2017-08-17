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

import Foundation

#if os(Linux)
    import CEpoll
    import CEventfd
    import CTimerfd
    import Glibc
#else
    import Darwin
#endif

final class Selector<R: Registration> {
    private var open: Bool
    
    #if os(Linux)
    private typealias EventType = epoll_event
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
        self.open = false

#if os(Linux)
        fd = try wrapSyscall({ $0 >= 0 }, function: "epoll_create") {
            CEpoll.epoll_create(128)
        }

        eventfd = try wrapSyscall({ $0 >= 0 }, function: "eventfd") {
            CEventfd.eventfd(0, Int32(EFD_CLOEXEC | EFD_NONBLOCK))
        }
    
        timerfd = try wrapSyscall({ $0 >= 0 }, function: "timerfd_create") {
            CTimerfd.timerfd_create(CLOCK_MONOTONIC, Int32(CTimerfd.TFD_CLOEXEC | CTimerfd.TFD_NONBLOCK));
        }
    
        self.open = true

        var ev = epoll_event()
        ev.events = Selector.toEpollEvents(interested: .read)
        ev.data.fd = eventfd

        let _ = try wrapSyscall({ $0 == 0 }, function: "epoll_ctl") {
            CEpoll.epoll_ctl(self.fd, EPOLL_CTL_ADD, eventfd, &ev)
        }
    
        var timerev = epoll_event()
        timerev.events = EPOLLIN.rawValue | EPOLLERR.rawValue | EPOLLRDHUP.rawValue | EPOLLET.rawValue
        timerev.data.fd = timerfd
        let _ = try wrapSyscall({ $0 == 0 }, function: "epoll_ctl") {
            CEpoll.epoll_ctl(self.fd, EPOLL_CTL_ADD, timerfd, &timerev)
        }
#else
        fd = try wrapSyscall({ $0 >= 0 }, function: "kqueue") {
            Darwin.kqueue()
        }
        self.open = true
    
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
        assert(!self.open, "Selector still open on deinit")
        Selector.deallocateEventsArray(events: events, capacity: eventsCapacity)
    }

#if os(Linux)

    private static func toEpollEvents(interested: IOEvent) -> UInt32 {
        // Also merge EPOLLRDHUP in so we can easily detect connection-reset
        switch interested {
        case .read:
            return EPOLLIN.rawValue | EPOLLERR.rawValue | EPOLLRDHUP.rawValue
        case .write:
            return EPOLLOUT.rawValue | EPOLLERR.rawValue | EPOLLRDHUP.rawValue
        case .all:
            return EPOLLIN.rawValue | EPOLLOUT.rawValue | EPOLLERR.rawValue | EPOLLRDHUP.rawValue
        case .none:
            return EPOLLERR.rawValue | EPOLLRDHUP.rawValue
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
        let _ = try wrapSyscall({ $0 >= 0 }, function: "kevent") {
            let res = kevent(self.fd, event, numEvents, nil, 0, nil)
            if res < 0  && errno == EINTR {
                // See https://www.freebsd.org/cgi/man.cgi?query=kqueue&sektion=2
                // When kevent() call fails with EINTR error, all changes in the changelist have been applied.
                return 0
            }
            return Int(res)
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
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't register on selector as it's not open anymore.")
        }
        
        assert(selectable.open)
        assert(registrations[Int(selectable.descriptor)] == nil)
#if os(Linux)
        var ev = epoll_event()
        ev.events = Selector.toEpollEvents(interested: interested)
        ev.data.fd = selectable.descriptor

        let _ = try wrapSyscall({ $0 == 0 }, function: "epoll_ctl") {
            CEpoll.epoll_ctl(self.fd, EPOLL_CTL_ADD, selectable.descriptor, &ev)
        }
#else
        try register_kqueue(selectable: selectable, interested: interested, oldInterested: nil)
#endif
        registrations[Int(selectable.descriptor)] = makeRegistration(interested)
    }

    func reregister<S: Selectable>(selectable: S, interested: IOEvent) throws {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't re-register on selector as it's not open anymore.")
        }
        assert(selectable.open)
        
        var reg = registrations[Int(selectable.descriptor)]!

#if os(Linux)
        var ev = epoll_event()
        ev.events = Selector.toEpollEvents(interested: interested)
        ev.data.fd = selectable.descriptor

        let _ = try wrapSyscall({ $0 == 0 }, function: "epoll_ctl") {
            CEpoll.epoll_ctl(self.fd, EPOLL_CTL_MOD, selectable.descriptor, &ev)
        }
#else
        try register_kqueue(selectable: selectable, interested: interested, oldInterested: reg.interested)
#endif
        reg.interested = interested
        registrations[Int(selectable.descriptor)] = reg
    }

    func deregister<S: Selectable>(selectable: S) throws {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't deregister from selector as it's not open anymore.")
        }
        assert(selectable.open)
        
        guard let reg = registrations.removeValue(forKey: Int(selectable.descriptor)) else {
            return
        }
        
#if os(Linux)
        var ev = epoll_event()
        let _ = try wrapSyscall({ $0 == 0 }, function: "epoll_ctl") {
            CEpoll.epoll_ctl(self.fd, EPOLL_CTL_DEL, selectable.descriptor, &ev)
        }
#else
        try register_kqueue(selectable: selectable, interested: .none, oldInterested: reg.interested)
#endif
    }

     func whenReady(strategy: SelectorStrategy, _ fn: (SelectorEvent<R>) throws -> Void) throws -> Void {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't call whenReady for selector as it's not open anymore.")
        }

#if os(Linux)
        let ready = try wrapSyscall({ $0 >= 0 }, function: "epoll_wait") {
            switch strategy {
            case .now:
                return Int(CEpoll.epoll_wait(self.fd, events, Int32(eventsCapacity), 0))
            case .blockUntilTimeout(let nanoseconds):
                var ts = itimerspec()
                ts.it_value = toTimerspec(nanoseconds)
                if (CTimerfd.timerfd_settime(timerfd, 0, &ts, nil) < 0) {
                    return -1
                }
                fallthrough
            case .block:
                return Int(CEpoll.epoll_wait(self.fd, events, Int32(eventsCapacity), -1))
            }
        }
        for i in 0..<ready {
            let ev = events[i]
            switch ev.data.fd {
            case eventfd:
                var val = eventfd_t()
                // Consume event
                _ = eventfd_read(eventfd, &val)
            case timerfd:
                // Consume event
                var val: UInt = 0
                _ = Glibc.read(timerfd, &val, MemoryLayout<UInt>.size)
            default:
                let registration = registrations[Int(ev.data.fd)]!
                try fn(
                    SelectorEvent(
                        readable: (ev.events & EPOLLIN.rawValue) != 0 || (ev.events & EPOLLERR.rawValue) != 0 || (ev.events & EPOLLRDHUP.rawValue) != 0,
                        writable: (ev.events & EPOLLOUT.rawValue) != 0 || (ev.events & EPOLLERR.rawValue) != 0 || (ev.events & EPOLLRDHUP.rawValue) != 0,
                        registration: registration))
            }
        }
    
        growEventArrayIfNeeded(ready: ready)
#else
        let timespec = toKQueueTimeSpec(strategy: strategy)

        let ready = try wrapSyscall({ $0 >= 0 }, function: "kevent") {
            if var ts = timespec {
                return Int(kevent(self.fd, nil, 0, events, Int32(eventsCapacity), &ts))
            } else {
                return Int(kevent(self.fd, nil, 0, events, Int32(eventsCapacity), nil))
            }
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
    
    func close() throws {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't close selector as it's not open anymore.")
        }
        self.open = false
        let _ = try wrapSyscall({ $0 >= 0 }, function: "close") {
#if os(Linux)
            // Ignore closing error for eventfd and timerfd
            let _ = Glibc.close(self.eventfd)
            let _ = Glibc.close(self.timerfd)
            return Int(Glibc.close(self.fd))
#else
            return Int(Darwin.close(self.fd))
#endif
        }
    }

    func wakeup() throws {
        guard self.open else {
            throw IOError(errno: EBADF, reason: "can't wakeup selector as it's not open anymore.")
        }
#if os(Linux)
        let _ = try wrapSyscall({ $0 == 0 }, function: "eventfd_write") {
            CEventfd.eventfd_write(eventfd, 1)
        }
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

enum SelectorStrategy {
    case block
    case blockUntilTimeout(nanoseconds: UInt64)
    case now
}

enum IOEvent {
    case read
    case write
    case all
    case none
}
