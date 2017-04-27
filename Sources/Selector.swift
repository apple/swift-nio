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
#endif

public class Selector {
    let fd: Int32;
#if os(Linux)
    let events: UnsafeMutablePointer<epoll_event>
#endif

    var registrations = [Int: Registration]()
    
    init() throws {
#if os(Linux)
        fd = CEpoll.epoll_create(128)
        events = UnsafeMutablePointer<epoll_event>.allocate(capacity: MemoryLayout<epoll_event>.size * 2048) // max 2048 events per epoll_wait
#else
        fd = 0
#endif
    }
    
    deinit {
#if os(Linux)
        let _ = UnsafeMutablePointer.deallocate(events)
#endif
    }
    
    public func register(selectable: Selectable, interested: InterestedEvent, attachment: AnyObject?) throws {
#if os(Linux)
        var ev = epoll_event()
    
        switch interested {
        case InterestedEvent.Read:
            ev.events = EPOLLIN.rawValue
        case InterestedEvent.Write:
            ev.events = EPOLLOUT.rawValue
        case InterestedEvent.All:
            ev.events = EPOLLIN.rawValue | EPOLLOUT.rawValue
        }
        ev.data.fd = selectable.descriptor()
        let res = CEpoll.epoll_ctl(self.fd, EPOLL_CTL_ADD, selectable.descriptor(), &ev)
        guard res == 0 else {
            throw IOError(errno: errno, reason: "epoll_ctl(...) failed")
        }
        registrations[Int(selectable.descriptor())] = Registration(selectable: selectable, attachment: attachment)
#endif
    }
    
    public func reregister(selectable: Selectable, interested: InterestedEvent) throws {
#if os(Linux)
        var ev = epoll_event()
            
        switch interested {
        case InterestedEvent.Read:
            ev.events = EPOLLIN.rawValue
        case InterestedEvent.Write:
            ev.events = EPOLLOUT.rawValue
        case InterestedEvent.All:
            ev.events = EPOLLIN.rawValue | EPOLLOUT.rawValue
        }

        ev.data.fd = selectable.descriptor()
        let res = CEpoll.epoll_ctl(self.fd, EPOLL_CTL_MOD, selectable.descriptor(), &ev)
        guard res == 0 else {
            throw IOError(errno: errno, reason: "epoll_ctl(...) failed")
        }
#endif
    }
    
    public func deregister(selectable: Selectable) throws {
#if os(Linux)
        var ev = epoll_event()
        let res = CEpoll.epoll_ctl(self.fd, EPOLL_CTL_DEL, selectable.descriptor(), &ev)
        guard res == 0 else {
            throw IOError(errno: errno, reason: "epoll_ctl(...) failed")
        }
        registrations.removeValue(forKey: Int(selectable.descriptor()))
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
                sEvents.append(SelectorEvent(isReadable: (ev.events & EPOLLIN.rawValue) != 0, isWritable: (ev.events & EPOLLOUT.rawValue) != 0, selectable: registration.selectable, attachment: registration.attachment))
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
        guard res == 0 else {
            throw IOError(errno: errno, reason: "close(...) failed")
        }
#endif
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
