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
    import Glibc
#else
    import Darwin
#endif

public class Selector {
#if os(Linux)
    private typealias EventType = epoll_event
    private let eventsCapacity = 2048
    private let eventfd: Int32
#else
    private typealias EventType = kevent
    private let eventsCapacity = 2048
    // TODO: Just reserve 0 is most likely not the best idea, need to think about a better way to handle this.
    private static let EvUserIdent = UInt(0)
#endif

    private let fd: Int32
    private let events: UnsafeMutablePointer<EventType>
    private var registrations = [Int: Registration]()
    
    public init() throws {
        events = UnsafeMutablePointer.allocate(capacity: eventsCapacity)
        events.initialize(to: EventType())
        
#if os(Linux)
        fd = try wrapSyscall({ $0 >= 0 }, function: "epoll_create") {
            CEpoll.epoll_create(128)
        }
    
        eventfd = try wrapSyscall({ $0 >= 0 }, function: "eventfd") {
            CEventfd.eventfd(0, Int32(EFD_CLOEXEC | EFD_NONBLOCK))
        }
    
        var ev = epoll_event()
        ev.events = Selector.toEpollEvents(interested: .read)
        ev.data.fd = eventfd
    
        let _ = try wrapSyscall({ $0 == 0 }, function: "epoll_ctl") {
            CEpoll.epoll_ctl(self.fd, EPOLL_CTL_ADD, eventfd, &ev)
        }
#else
        fd = try wrapSyscall({ $0 >= 0 }, function: "kqueue") {
            Darwin.kqueue()
        }
    
        var event = kevent()
        event.ident = Selector.EvUserIdent
        event.filter = Int16(EVFILT_USER)
        event.fflags = UInt32(NOTE_FFNOP)
        event.data = 0
        event.udata = nil
        event.flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR)
    
        try keventChangeSetOnly(event: &event, numEvents: 1)
#endif
    }
    
    deinit {
        events.deinitialize()
        events.deallocate(capacity: eventsCapacity)
    }
    

#if os(Linux)
    private static func toEpollWaitTimeout(strategy: SelectorStrategy) -> Int32 {
        switch strategy {
        case .block:
            return -1
        case .now:
            return 0
        case .blockUntilTimeout(let ms):
            return Int32(ms)
        }
    }
    
    private static func toEpollEvents(interested: InterestedEvent) -> UInt32 {
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
    private static func toKQueueTimeSpec(strategy: SelectorStrategy) -> timespec? {
        switch strategy {
        case .block:
            return nil
        case .now:
            return timespec(tv_sec: 0, tv_nsec: 0)
        case .blockUntilTimeout(let ms):
            // Convert to nanoseconds
            return timespec(tv_sec: 0, tv_nsec: ms * 1000 * 1000)
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

    private func register_kqueue(selectable: Selectable, interested: InterestedEvent, oldInterested: InterestedEvent?) throws {
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
                numEvents = 0
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
 
    public func register(selectable: Selectable, interested: InterestedEvent = .read, attachment: AnyObject? = nil) throws {
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
        registrations[Int(selectable.descriptor)] = Registration(selectable: selectable, interested: interested,  attachment: attachment)
    }
    
    public func reregister(selectable: Selectable, interested: InterestedEvent) throws {
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
    
    public func deregister(selectable: Selectable) throws {
        let reg = registrations.removeValue(forKey: Int(selectable.descriptor))
        guard reg != nil else {
            return
        }
#if os(Linux)
        var ev = epoll_event()
        let _ = try wrapSyscall({ $0 == 0 }, function: "epoll_ctl") {
            CEpoll.epoll_ctl(self.fd, EPOLL_CTL_DEL, selectable.descriptor, &ev)
        }
#else
        try register_kqueue(selectable: selectable, interested: .none, oldInterested: reg!.interested)
#endif
    }
    

    public func whenReady(strategy: SelectorStrategy, _ fn: (SelectorEvent) throws -> Void) throws -> Void {
#if os(Linux)
        let timeout = Selector.toEpollWaitTimeout(strategy: strategy)
        let ready = try wrapSyscall({ $0 >= 0 }, function: "epoll_wait") {
            CEpoll.epoll_wait(self.fd, events, Int32(eventsCapacity), timeout)
        }
        if (ready > 0) {
            var sEvents = [SelectorEvent]()
            var i = 0;
            while (i < Int(ready)) {
                let ev = events[Int(i)]
                if ev.data.fd == eventfd {
                    var ev = eventfd_t()
                    // Consume event
                    let _ = eventfd_read(eventfd, &ev)
                } else {
                    let registration = registrations[Int(ev.data.fd)]!
                    try fn((
                        SelectorEvent(
                            isReadable: (ev.events & EPOLLIN.rawValue) != 0 || (ev.events & EPOLLERR.rawValue) != 0 || (ev.events & EPOLLRDHUP.rawValue) != 0,
                            isWritable: (ev.events & EPOLLOUT.rawValue) != 0 || (ev.events & EPOLLERR.rawValue) != 0 || (ev.events & EPOLLRDHUP.rawValue) != 0,
                            selectable: registration.selectable, attachment: registration.attachment)))
                }
                i += 1
            }
            if sEvents.isEmpty {
                return nil
            }
            return sEvents
        }
#else
        let timespec = Selector.toKQueueTimeSpec(strategy: strategy)
    
        let ready = try wrapSyscall({ $0 >= 0 }, function: "kevent") {
            if var ts = timespec {
                return Int(kevent(self.fd, nil, 0, events, Int32(eventsCapacity), &ts))
            } else {
                return Int(kevent(self.fd, nil, 0, events, Int32(eventsCapacity), nil))
            }
        }
        if (ready > 0) {
            var i = 0;
            while (i < Int(ready)) {
                let ev = events[Int(i)]
                
                if ev.ident != Selector.EvUserIdent {
                    let registration = registrations[Int(ev.ident)]!
                    try fn((SelectorEvent(isReadable: Int32(ev.filter) == EVFILT_READ, isWritable: Int32(ev.filter) == EVFILT_WRITE, selectable: registration.selectable, attachment: registration.attachment)))
                }

                i += 1
            }
        }
#endif
    }
    
    public func close() throws {
        let _ = try wrapSyscall({ $0 >= 0 }, function: "close") {
#if os(Linux)
            // Ignore closing error for eventfd
            let _ = Glibc.close(self.eventfd)
            return Int(Glibc.close(self.fd))
#else
            return Int(Darwin.close(self.fd))
#endif
        }
    }

    public func wakeup() throws {
#if os(Linux)
        // TODO: Should we throw an error if it returns != 0 ?
        let _ = CEventfd.eventfd_write(eventfd, 1)
#else
        var event = kevent()
        event.ident = Selector.EvUserIdent
        event.filter = Int16(EVFILT_USER)
        event.fflags = UInt32(NOTE_TRIGGER | NOTE_FFNOP)
        event.data = 0
        event.udata = nil
        event.flags = 0
        try keventChangeSetOnly(event: &event, numEvents: 1)
#endif
    }
}

private struct Registration {
    fileprivate(set) var interested: InterestedEvent
    fileprivate(set) var selectable: Selectable
    fileprivate(set) var attachment: AnyObject?

    init(selectable: Selectable, interested: InterestedEvent, attachment: AnyObject?) {
        self.selectable = selectable
        self.interested = interested
        self.attachment = attachment
    }
}

public struct SelectorEvent {
    
    public fileprivate(set) var isReadable: Bool
    public fileprivate(set) var isWritable: Bool
    public fileprivate(set) var selectable: Selectable
    public fileprivate(set) var attachment: AnyObject?
  
    init(isReadable: Bool, isWritable: Bool, selectable: Selectable, attachment: AnyObject?) {
        self.isReadable = isReadable
        self.isWritable = isWritable
        self.selectable = selectable
        self.attachment = attachment
    }
}

public enum SelectorStrategy {
    case block
    case blockUntilTimeout(ms: Int)
    case now
}

public enum InterestedEvent {
    case read
    case write
    case all
    case none
}
