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
            events = UnsafeMutablePointer<epoll_event>.allocate(capacity: MemoryLayout<epoll_event>.size * 1024)
        #else
        fd = 0
        #endif
    }
    
    deinit {
#if os(Linux)
        let _ = UnsafeMutablePointer.deallocate(events)
#endif
    }
    
    public func register(socket: Socket, interested: InterestedEvent) throws {
#if os(Linux)
        var ev = epoll_event()
    
        switch interested {
        case InterestedEvent.Read:
            ev.events = EPOLLIN.rawValue
            break
        case InterestedEvent.Write:
            ev.events = EPOLLOUT.rawValue
            break
        case InterestedEvent.All:
            ev.events = EPOLLIN.rawValue | EPOLLOUT.rawValue
            break
        }
        ev.data.fd = socket.fd
        let res = CEpoll.epoll_ctl(self.fd, EPOLL_CTL_ADD, socket.fd, &ev)
        guard res == 0 else {
            throw IOError(errno: errno, reason: "epoll_ctl(...) failed")
        }
        registrations[Int(socket.fd)] = Registration(socket: socket)
#endif
    }
    
    public func reregister(socket: Socket, interested: InterestedEvent) throws {
        #if os(Linux)
            var ev = epoll_event()
            
            switch interested {
            case InterestedEvent.Read:
                ev.events = EPOLLIN.rawValue
                break
            case InterestedEvent.Write:
                ev.events = EPOLLOUT.rawValue
                break
            case InterestedEvent.All:
                ev.events = EPOLLIN.rawValue | EPOLLOUT.rawValue
                break
            }
            ev.data.fd = socket.fd
            let res = CEpoll.epoll_ctl(self.fd, EPOLL_CTL_MOD, socket.fd, &ev)
            guard res == 0 else {
                throw IOError(errno: errno, reason: "epoll_ctl(...) failed")
            }
        #endif
    }
    
    public func deregister(socket: Socket) throws {
#if os(Linux)
        var ev = epoll_event()
        let res = CEpoll.epoll_ctl(self.fd, EPOLL_CTL_DEL, socket.fd, &ev)
        guard res == 0 else {
            throw IOError(errno: errno, reason: "epoll_ctl(...) failed")
        }
        registrations.removeValue(forKey: Int(socket.fd))
#endif
    }
    
    public func awaitReady() throws -> Array<SelectorEvent>? {
        #if os(Linux)
            let ready = CEpoll.epoll_wait(self.fd, events, 1024, 0)
            if (ready > 0) {
                var sEvents = [SelectorEvent]()
                var i = 0;
                while (i < Int(ready)) {
                    let ev = events[Int(i)]
                    let socket = registrations[Int(ev.data.fd)]!.socket
                    sEvents.append(SelectorEvent(isReadable: (ev.events & EPOLLIN.rawValue) != 0, isWritable: (ev.events & EPOLLOUT.rawValue) != 0, socket: socket))
                    
                    i += 1
                }
                return sEvents
            }
        #endif
        return nil
    }
    public func close() throws {
        #if os(Linux)
            let _ = Glibc.close(self.fd)
        #endif
    }
}

struct Registration {
    let socket: Socket
    // TODO: Attach data ?
}

public struct SelectorEvent {
    let isReadable: Bool
    let isWritable: Bool
    let socket: Socket
}

public enum InterestedEvent {
    case Read
    case Write
    case All
}
