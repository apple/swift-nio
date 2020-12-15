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

#if os(Linux) || os(Android)
import CNIOLinux

internal enum TimerFd {
    public static let TFD_CLOEXEC = CNIOLinux.TFD_CLOEXEC
    public static let TFD_NONBLOCK = CNIOLinux.TFD_NONBLOCK

    @inline(never)
    public static func timerfd_settime(fd: Int32, flags: Int32, newValue: UnsafePointer<itimerspec>, oldValue: UnsafeMutablePointer<itimerspec>?) throws  {
        _ = try syscall(blocking: false) {
            CNIOLinux.timerfd_settime(fd, flags, newValue, oldValue)
        }
    }

    @inline(never)
    public static func timerfd_create(clockId: Int32, flags: Int32) throws -> Int32 {
        return try syscall(blocking: false) {
            CNIOLinux.timerfd_create(clockId, flags)
        }.result
    }
}

internal enum EventFd {
    public static let EFD_CLOEXEC = CNIOLinux.EFD_CLOEXEC
    public static let EFD_NONBLOCK = CNIOLinux.EFD_NONBLOCK
    public typealias eventfd_t = CNIOLinux.eventfd_t

    @inline(never)
    public static func eventfd_write(fd: Int32, value: UInt64) throws -> Int32 {
        return try syscall(blocking: false) {
            CNIOLinux.eventfd_write(fd, value)
        }.result
    }

    @inline(never)
    public static func eventfd_read(fd: Int32, value: UnsafeMutablePointer<UInt64>) throws -> Int32 {
        return try syscall(blocking: false) {
            CNIOLinux.eventfd_read(fd, value)
        }.result
    }

    @inline(never)
    public static func eventfd(initval: Int32, flags: Int32) throws -> Int32 {
        return try syscall(blocking: false) {
            CNIOLinux.eventfd(0, Int32(EFD_CLOEXEC | EFD_NONBLOCK))
        }.result
    }
}

internal enum Epoll {
    public typealias epoll_event = CNIOLinux.epoll_event

    public static let EPOLL_CTL_ADD: CInt = numericCast(CNIOLinux.EPOLL_CTL_ADD)
    public static let EPOLL_CTL_MOD: CInt = numericCast(CNIOLinux.EPOLL_CTL_MOD)
    public static let EPOLL_CTL_DEL: CInt = numericCast(CNIOLinux.EPOLL_CTL_DEL)

    #if os(Android)
    public static let EPOLLIN: CUnsignedInt = 1 //numericCast(CNIOLinux.EPOLLIN)
    public static let EPOLLOUT: CUnsignedInt = 4 //numericCast(CNIOLinux.EPOLLOUT)
    public static let EPOLLERR: CUnsignedInt = 8 // numericCast(CNIOLinux.EPOLLERR)
    public static let EPOLLRDHUP: CUnsignedInt = 8192 //numericCast(CNIOLinux.EPOLLRDHUP)
    public static let EPOLLHUP: CUnsignedInt = 16 //numericCast(CNIOLinux.EPOLLHUP)
    public static let EPOLLET: CUnsignedInt = 2147483648 //numericCast(CNIOLinux.EPOLLET)
    #else
    public static let EPOLLIN: CUnsignedInt = numericCast(CNIOLinux.EPOLLIN.rawValue)
    public static let EPOLLOUT: CUnsignedInt = numericCast(CNIOLinux.EPOLLOUT.rawValue)
    public static let EPOLLERR: CUnsignedInt = numericCast(CNIOLinux.EPOLLERR.rawValue)
    public static let EPOLLRDHUP: CUnsignedInt = numericCast(CNIOLinux.EPOLLRDHUP.rawValue)
    public static let EPOLLHUP: CUnsignedInt = numericCast(CNIOLinux.EPOLLHUP.rawValue)
    public static let EPOLLET: CUnsignedInt = numericCast(CNIOLinux.EPOLLET.rawValue)
    #endif

    public static let ENOENT: CUnsignedInt = numericCast(CNIOLinux.ENOENT)


    @inline(never)
    public static func epoll_create(size: Int32) throws -> Int32 {
        return try syscall(blocking: false) {
            CNIOLinux.epoll_create(size)
        }.result
    }

    @inline(never)
    @discardableResult
    public static func epoll_ctl(epfd: Int32, op: Int32, fd: Int32, event: UnsafeMutablePointer<epoll_event>) throws -> Int32 {
        return try syscall(blocking: false) {
            CNIOLinux.epoll_ctl(epfd, op, fd, event)
        }.result
    }

    @inline(never)
    public static func epoll_wait(epfd: Int32, events: UnsafeMutablePointer<epoll_event>, maxevents: Int32, timeout: Int32) throws -> Int32 {
        return try syscall(blocking: false) {
            CNIOLinux.epoll_wait(epfd, events, maxevents, timeout)
        }.result
    }
}

internal enum Linux {
    static let cfsQuotaPath = "/sys/fs/cgroup/cpu/cpu.cfs_quota_us"
    static let cfsPeriodPath = "/sys/fs/cgroup/cpu/cpu.cfs_period_us"
    static let cpuSetPath = "/sys/fs/cgroup/cpuset/cpuset.cpus"
#if os(Android)
    static let SOCK_CLOEXEC = Glibc.SOCK_CLOEXEC
    static let SOCK_NONBLOCK = Glibc.SOCK_NONBLOCK
#else
    static let SOCK_CLOEXEC = CInt(bitPattern: Glibc.SOCK_CLOEXEC.rawValue)
    static let SOCK_NONBLOCK = CInt(bitPattern: Glibc.SOCK_NONBLOCK.rawValue)
#endif
    @inline(never)
    public static func accept4(descriptor: CInt,
                               addr: UnsafeMutablePointer<sockaddr>?,
                               len: UnsafeMutablePointer<socklen_t>?,
                               flags: CInt) throws -> CInt? {
        guard case let .processed(fd) = try syscall(blocking: true, {
            CNIOLinux.CNIOLinux_accept4(descriptor, addr, len, flags)
        }) else {
          return nil
        }
        return fd
    }

    private static func firstLineOfFile(path: String) throws -> Substring {
        let fh = try NIOFileHandle(path: path)
        defer { try! fh.close() }
        // linux doesn't properly report /sys/fs/cgroup/* files lengths so we use a reasonable limit
        var buf = ByteBufferAllocator().buffer(capacity: 1024)
        try buf.writeWithUnsafeMutableBytes(minimumWritableBytes: buf.capacity) { ptr in
            let res = try fh.withUnsafeFileDescriptor { fd -> IOResult<ssize_t> in
                return try Posix.read(descriptor: fd, pointer: ptr.baseAddress!, size: ptr.count)
            }
            switch res {
            case .processed(let n):
                return n
            case .wouldBlock:
                preconditionFailure("read returned EWOULDBLOCK despite a blocking fd")
            }
        }
        return String(buffer: buf).prefix(while: { $0 != "\n" })
    }

    private static func countCoreIds(cores: Substring) -> Int {
        let ids = cores.split(separator: "-", maxSplits: 1)
        guard
            let first = ids.first.flatMap({ Int($0, radix: 10) }),
            let last = ids.last.flatMap({ Int($0, radix: 10) }),
            last >= first
        else { preconditionFailure("cpuset format is incorrect") }
        return 1 + last - first
    }

    static func coreCount(cpuset cpusetPath: String) -> Int? {
        guard
            let cpuset = try? firstLineOfFile(path: cpusetPath).split(separator: ","),
            !cpuset.isEmpty
        else { return nil }
        return cpuset.map(countCoreIds).reduce(0, +)
    }

    static func coreCount(quota quotaPath: String,  period periodPath: String) -> Int? {
        guard
            let quota = try? Int(firstLineOfFile(path: quotaPath)),
            quota > 0
        else { return nil }
        guard
            let period = try? Int(firstLineOfFile(path: periodPath)),
            period > 0
        else { return nil }
        return (quota - 1 + period) / period // always round up if fractional CPU quota requested
    }
}
#endif
