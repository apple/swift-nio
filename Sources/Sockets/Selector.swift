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
    import Glibc
#else
    import Darwin
#endif

public class Selector {
    let fd: Int32;
#if os(Linux)
    let events: UnsafeMutablePointer<epoll_event>
#else
    let events: UnsafeMutablePointer<kevent>
#endif

    var registrations = [Int: Registration]()
    
    public init() throws {
#if os(Linux)
        fd = CEpoll.epoll_create(128)
        guard fd >= 0 else {
            throw IOError(errno: errno, reason: "Creation of epoll failed")
        }
        events = UnsafeMutablePointer.allocate(capacity: 2048) // max 2048 events per epoll call
        events.initialize(to: epoll_event())
#else
        fd = Darwin.kqueue()
        guard fd >= 0 else {
            throw IOError(errno: errno, reason: "Creation of kqueue failed")
        }
        events = UnsafeMutablePointer.allocate(capacity: 2048) // max 2048 events per kqueue call
        events.initialize(to: kevent())
#endif
    }
    
    deinit {
        events.deinitialize()
        events.deallocate(capacity: 1)
    }
    

#if !os(Linux)
    private func register_kqueue(selectable: Selectable, interested: InterestedEvent) -> Int32 {
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
        case InterestedEvent.Read:
            events.0.flags = UInt16(Int16(EV_ADD))
            events.1.flags = UInt16(Int16(EV_DELETE))
        case InterestedEvent.Write:
            events.0.flags = UInt16(Int16(EV_DELETE))
            events.1.flags = UInt16(Int16(EV_ADD))
        case InterestedEvent.All:
            events.0.flags = UInt16(Int16(EV_ADD))
            events.1.flags = UInt16(Int16(EV_ADD))
        }
        
        return withUnsafeMutableBytes(of: &events) { event_ptr -> Int32 in
            precondition(MemoryLayout<kevent>.size * 2 == event_ptr.count)
            let ptr = event_ptr.baseAddress?.bindMemory(to: kevent.self, capacity: 2)
            return kevent(self.fd, ptr, 2, ptr, 2, nil)
        }
    }
#endif
    
#if os(Linux)
    private func toEpollEvents(interested: InterestedEvent) -> UInt32 {
        // Also merge EPOLL_ERR in so we can easily detect connection-reset
        switch interested {
        case InterestedEvent.Read:
            return EPOLLIN.rawValue | EPOLLERR.rawValue
        case InterestedEvent.Write:
            return EPOLLOUT.rawValue | EPOLLERR.rawValue
        case InterestedEvent.All:
            return EPOLLIN.rawValue | EPOLLOUT.rawValue | EPOLLERR.rawValue
        }

    }
#endif
 
    public func register(selectable: Selectable, interested: InterestedEvent = InterestedEvent.Read, attachment: AnyObject? = nil) throws {
#if os(Linux)
        var ev = epoll_event()
        ev.events = toEpollEvents(interested: interested)
        ev.data.fd = selectable.descriptor

        let res = CEpoll.epoll_ctl(self.fd, EPOLL_CTL_ADD, selectable.descriptor, &ev)
        guard res == 0 else {
            throw ioError(errno: errno, function: "epoll_ctl")
        }
        registrations[Int(selectable.descriptor)] = Registration(selectable: selectable, attachment: attachment)
#else
        let res = register_kqueue(selectable: selectable, interested: interested)
    
        guard res != -1 else {
            throw ioError(errno: errno, function: "kevent")
        }
        registrations[Int(selectable.descriptor)] = Registration(selectable: selectable, attachment: attachment)
#endif
    }
    
    public func reregister(selectable: Selectable, interested: InterestedEvent) throws {
#if os(Linux)
        var ev = epoll_event()
        ev.events = toEpollEvents(interested: interested)
        ev.data.fd = selectable.descriptor
 
        let res = CEpoll.epoll_ctl(self.fd, EPOLL_CTL_MOD, selectable.descriptor, &ev)
        guard res == 0 else {
            throw ioError(errno: errno, function: "epoll_ctl")
        }
#else
        let res = register_kqueue(selectable: selectable, interested: interested)
    
        guard res != -1 else {
            throw ioError(errno: errno, function: "kevent")
        }
#endif
    }
    
    public func deregister(selectable: Selectable) throws {
#if os(Linux)
        var ev = epoll_event()
        let res = CEpoll.epoll_ctl(self.fd, EPOLL_CTL_DEL, selectable.descriptor, &ev)
        guard res == 0 else {
            throw ioError(errno: errno, function: "epoll_ctl")
        }
        registrations.removeValue(forKey: Int(selectable.descriptor))
#else
        // Allocated on the stack
        var evs = (kevent(), kevent())
    
        evs.0.ident = UInt(selectable.descriptor)
        evs.0.filter = Int16(EVFILT_READ)
        evs.0.fflags = 0
        evs.0.data = 0
        evs.0.udata = nil
        evs.0.flags = UInt16(Int16(EV_DELETE))

        evs.1.ident = UInt(selectable.descriptor)
        evs.1.filter = Int16(EVFILT_WRITE)
        evs.1.fflags = 0
        evs.1.data = 0
        evs.1.udata = nil
        evs.1.flags = UInt16(Int16(EV_DELETE))

        let res = withUnsafeMutableBytes(of: &evs) { event_ptr -> Int32 in
            precondition(MemoryLayout<kevent>.size * 2 == event_ptr.count)
            let ptr = event_ptr.baseAddress?.bindMemory(to: kevent.self, capacity: 2)
            return kevent(self.fd, ptr, 2, ptr, 2, nil)
        }
    
        guard res != -1 else {
            throw ioError(errno: errno, function: "kevent")
        }
#endif
    }
    
    public func awaitReady() throws -> Array<SelectorEvent>? {
#if os(Linux)
        let ready = CEpoll.epoll_wait(self.fd, events, 2048, 0)
        if (ready > 0) {
            var sEvents = [SelectorEvent]()
            var i = 0;
            while (i < Int(ready)) {
                let ev = events[Int(i)]
                let registration = registrations[Int(ev.data.fd)]!
                sEvents.append(
                    SelectorEvent(isReadable: (ev.events & EPOLLIN.rawValue) != 0 || (ev.events & EPOLLERR.rawValue) != 0,
                                  isWritable: (ev.events & EPOLLOUT.rawValue) != 0 || (ev.events & EPOLLERR.rawValue) != 0,
                                  selectable: registration.selectable, attachment: registration.attachment))
                i += 1
            }
            return sEvents
        }
#else
        let ready = kevent(self.fd, nil, 0, events, 2048, nil);
        if (ready > 0) {
            var sEvents = [SelectorEvent]()
            var i = 0;
            while (i < Int(ready)) {
                let ev = events[Int(i)]
                
                let registration = registrations[Int(ev.ident)]!
                sEvents.append(SelectorEvent(isReadable: Int32(ev.filter) == EVFILT_READ, isWritable: Int32(ev.filter) == EVFILT_WRITE, selectable: registration.selectable, attachment: registration.attachment))
                i += 1
            }
            return sEvents
        }
#endif
        return nil
    }
    
    public func close() throws {
#if os(Linux)
        let res = Glibc.close(self.fd)
#else
        let res = Darwin.close(self.fd)
#endif
        guard res >= 0 else {
            throw ioError(errno: errno, function: "close")
        }
    }

}

struct Registration {
    public internal(set) var selectable: Selectable
    public internal(set) var attachment: AnyObject?

    init(selectable: Selectable, attachment: AnyObject?) {
        self.selectable = selectable
        self.attachment = attachment
    }
}

public struct SelectorEvent {
    
    public internal(set) var isReadable: Bool
    public internal(set) var isWritable: Bool
    public internal(set) var selectable: Selectable
    public internal(set) var attachment: AnyObject?
  
    init(isReadable: Bool, isWritable: Bool, selectable: Selectable, attachment: AnyObject?) {
        self.isReadable = isReadable
        self.isWritable = isWritable
        self.selectable = selectable
        self.attachment = attachment
    }
}

public enum InterestedEvent {
    case Read
    case Write
    case All
}
