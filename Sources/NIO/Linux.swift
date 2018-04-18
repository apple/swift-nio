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

// This is a companion to System.swift that provides only Linux specials: either things that exist
// only on Linux, or things that have Linux-specific extensions.
import CNIOLinux

#if os(Linux)
internal enum TimerFd {
    public static let TFD_CLOEXEC = CNIOLinux.TFD_CLOEXEC
    public static let TFD_NONBLOCK = CNIOLinux.TFD_NONBLOCK

    @inline(never)
    public static func timerfd_settime(fd: Int32, flags: Int32, newValue: UnsafePointer<itimerspec>, oldValue: UnsafeMutablePointer<itimerspec>?) throws  {
        _ = try wrapSyscall {
            CNIOLinux.timerfd_settime(fd, flags, newValue, oldValue)
        }
    }

    @inline(never)
    public static func timerfd_create(clockId: Int32, flags: Int32) throws -> Int32 {
        return try wrapSyscall {
            CNIOLinux.timerfd_create(clockId, flags)
        }
    }
}

internal enum EventFd {
    public static let EFD_CLOEXEC = CNIOLinux.EFD_CLOEXEC
    public static let EFD_NONBLOCK = CNIOLinux.EFD_NONBLOCK
    public typealias eventfd_t = CNIOLinux.eventfd_t

    @inline(never)
    public static func eventfd_write(fd: Int32, value: UInt64) throws -> Int32 {
        return try wrapSyscall {
            CNIOLinux.eventfd_write(fd, value)
        }
    }

    @inline(never)
    public static func eventfd_read(fd: Int32, value: UnsafeMutablePointer<UInt64>) throws -> Int32 {
        return try wrapSyscall {
            CNIOLinux.eventfd_read(fd, value)
        }
    }

    @inline(never)
    public static func eventfd(initval: Int32, flags: Int32) throws -> Int32 {
        return try wrapSyscall {
            CNIOLinux.eventfd(0, Int32(EFD_CLOEXEC | EFD_NONBLOCK))
        }
    }
}

internal enum Epoll {
    public typealias epoll_event = CNIOLinux.epoll_event
    public static let EPOLL_CTL_ADD = CNIOLinux.EPOLL_CTL_ADD
    public static let EPOLL_CTL_MOD = CNIOLinux.EPOLL_CTL_MOD
    public static let EPOLL_CTL_DEL = CNIOLinux.EPOLL_CTL_DEL
    public static let EPOLLIN = CNIOLinux.EPOLLIN
    public static let EPOLLOUT = CNIOLinux.EPOLLOUT
    public static let EPOLLERR = CNIOLinux.EPOLLERR
    public static let EPOLLRDHUP = CNIOLinux.EPOLLRDHUP
    public static let EPOLLHUP = CNIOLinux.EPOLLHUP
    public static let EPOLLET = CNIOLinux.EPOLLET
    public static let ENOENT = CNIOLinux.ENOENT

    @inline(never)
    public static func epoll_create(size: Int32) throws -> Int32 {
        return try wrapSyscall {
            CNIOLinux.epoll_create(size)
        }
    }

    @inline(never)
    public static func epoll_ctl(epfd: Int32, op: Int32, fd: Int32, event: UnsafeMutablePointer<epoll_event>) throws -> Int32 {
        return try wrapSyscall {
            CNIOLinux.epoll_ctl(epfd, op, fd, event)
        }
    }

    @inline(never)
    public static func epoll_wait(epfd: Int32, events: UnsafeMutablePointer<epoll_event>, maxevents: Int32, timeout: Int32) throws -> Int32 {
        return try wrapSyscall {
            CNIOLinux.epoll_wait(epfd, events, maxevents, timeout)
        }
    }
}

internal enum Linux {
    static let SOCK_CLOEXEC = Int32(bitPattern: Glibc.SOCK_CLOEXEC.rawValue)
    static let SOCK_NONBLOCK = Int32(bitPattern: Glibc.SOCK_NONBLOCK.rawValue)

    @inline(never)
    public static func accept4(descriptor: CInt, addr: UnsafeMutablePointer<sockaddr>, len: UnsafeMutablePointer<socklen_t>, flags: Int32) throws -> CInt? {
        let result: IOResult<CInt> = try wrapSyscallMayBlock {
            CNIOLinux.CNIOLinux_accept4(descriptor, addr, len, flags)
        }
        switch result {
        case .processed(let fd):
            return fd
        default:
            return nil
        }
    }
}
#endif
