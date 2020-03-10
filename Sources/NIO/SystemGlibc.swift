//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

//
//  This file contains code that ensures errno is captured correctly when doing
//  syscalls and no ARC traffic can happen inbetween that *could* change the
//  errno value before we were able to read it.  It's important that all static
//  methods are declared with `@inline(never)` so it's not possible any ARC
//  traffic happens while we need to read errno.
//
//  Created by Norman Maurer on 11/10/17.
//

#if os(Linux) || os(FreeBSD) || os(Android)

@_exported
import Glibc

import CNIOLinux

internal typealias MMsgHdr = CNIOLinux_mmsghdr

#if os(Android)

// #define INADDR_ANY ((unsigned long int) 0x00000000)
let INADDR_ANY = UInt32(0)

internal typealias sockaddr_storage = __kernel_sockaddr_storage

internal typealias in_port_t = UInt16

let freeifaddrs: @convention(c) (UnsafeMutablePointer<ifaddrs>?) -> Void = android_freeifaddrs

// http://lkml.iu.edu/hypermail/linux/kernel/0106.1/0080.html
extension ipv6_mreq {
    init (ipv6mr_multiaddr: in6_addr, ipv6mr_interface: UInt32) {
        self.ipv6mr_multiaddr = ipv6mr_multiaddr
        self.ipv6mr_ifindex = Int32(bitPattern: ipv6mr_interface)
    }
}
#endif

private func isBlacklistedErrno(_ code: Int32) -> Bool {
    switch code {
    case EFAULT, EBADF:
        return true
    default:
        return false
    }
}

private func preconditionIsNotBlacklistedErrno(err: CInt, where function: String) -> Void {
    // strerror is documented to return "Unknown error: ..." for illegal value so it won't ever fail
    precondition(!isBlacklistedErrno(err), "blacklisted errno \(err) \(String(cString: strerror(err)!)) in \(function))")
}

/*
 * Sorry, we really try hard to not use underscored attributes. In this case
 * however we seem to break the inlining threshold which makes a system call
 * take twice the time, ie. we need this exception.
 */
@inline(__always)
@discardableResult
internal func syscall<T: FixedWidthInteger>(blocking: Bool,
                                            where function: String = #function,
                                            _ body: () throws -> T)
        throws -> IOResult<T> {
    while true {
        let res = try body()
        if res == -1 {
            let err = errno
            switch (err, blocking) {
            case (EINTR, _):
                continue
            case (EWOULDBLOCK, true):
                return .wouldBlock(0)
            default:
                preconditionIsNotBlacklistedErrno(err: err, where: function)
                throw IOError(errnoCode: err, reason: function)
            }
        }
        return .processed(res)
    }
}

internal enum Posix {
    static let UIO_MAXIOV: Int = Int(Glibc.UIO_MAXIOV)

    @inline(never)
    public static func close(fd: CInt) throws {
        let res = Glibc.close(fd)
        if res == -1 {
            let err = errno

            // There is really nothing "sane" we can do when EINTR was reported on close.
            // So just ignore it and "assume" everything is fine == we closed the file descriptor.
            //
            // For more details see:
            //     - https://bugs.chromium.org/p/chromium/issues/detail?id=269623
            //     - https://lwn.net/Articles/576478/
            if err != EINTR {
                preconditionIsNotBlacklistedErrno(err: err, where: #function)
                throw IOError(errnoCode: err, reason: "close")
            }
        }
    }

    @inline(never)
    @discardableResult
    // TODO: Allow varargs
    public static func fcntl(descriptor: CInt, command: CInt, value: CInt) throws -> CInt {
        return try syscall(blocking: false) {
            Glibc.fcntl(descriptor, command, value)
        }.result
    }

    @inline(never)
    public static func open(file: UnsafePointer<CChar>, oFlag: CInt, mode: mode_t) throws -> CInt {
        let open3: (UnsafePointer<CChar>, CInt, mode_t) -> CInt = Glibc.open
        return try syscall(blocking: false) {
            open3(file, oFlag, mode)
        }.result
    }

    @inline(never)
    public static func open(file: UnsafePointer<CChar>, oFlag: CInt) throws -> CInt {
        let open2: (UnsafePointer<CChar>, CInt) -> CInt = Glibc.open
        return try syscall(blocking: false) {
            open2(file, oFlag)
        }.result
    }

    @inline(never)
    @discardableResult
    public static func ftruncate(descriptor: CInt, size: off_t) throws -> CInt {
        return try syscall(blocking: false) {
            Glibc.ftruncate(descriptor, size)
        }.result
    }

    @inline(never)
    public static func write(descriptor: CInt, pointer: UnsafeRawPointer, size: Int) throws -> IOResult<Int> {
        return try syscall(blocking: true) {
            Glibc.write(descriptor, pointer, size)
        }
    }

    @inline(never)
    public static func pwrite(descriptor: CInt, pointer: UnsafeRawPointer, size: Int, offset: off_t) throws -> IOResult<Int> {
        return try syscall(blocking: true) {
            Glibc.pwrite(descriptor, pointer, size, offset)
        }
    }

    @inline(never)
    public static func writev(descriptor: CInt, iovecs: UnsafeBufferPointer<IOVector>) throws -> IOResult<Int> {
        return try syscall(blocking: true) {
            Glibc.writev(descriptor, iovecs.baseAddress!, CInt(iovecs.count))
        }
    }

    @inline(never)
    public static func read(descriptor: CInt, pointer: UnsafeMutableRawPointer, size: size_t) throws -> IOResult<ssize_t> {
        return try syscall(blocking: true) {
            Glibc.read(descriptor, pointer, size)
        }
    }

    @inline(never)
    public static func pread(descriptor: CInt, pointer: UnsafeMutableRawPointer, size: size_t, offset: off_t) throws -> IOResult<ssize_t> {
        return try syscall(blocking: true) {
            Glibc.pread(descriptor, pointer, size, offset)
        }
    }

    @discardableResult
    @inline(never)
    public static func lseek(descriptor: CInt, offset: off_t, whence: CInt) throws -> off_t {
        return try syscall(blocking: false) {
            Glibc.lseek(descriptor, offset, whence)
        }.result
    }

    @discardableResult
    @inline(never)
    public static func dup(descriptor: CInt) throws -> CInt {
        return try syscall(blocking: false) {
            Glibc.dup(descriptor)
        }.result
    }

    // It's not really posix but exists on Linux and MacOS / BSD so just put it here for now to keep it simple
    @inline(never)
    public static func sendfile(descriptor: CInt, fd: CInt, offset: off_t, count: size_t) throws -> IOResult<Int> {
        var written: off_t = 0
        do {
            _ = try syscall(blocking: false) { () -> ssize_t in
                    var off: off_t = offset
                    let result: ssize_t = Glibc.sendfile(descriptor, fd, &off, count)
                    if result >= 0 {
                        written = result
                    } else {
                        written = 0
                    }
                    return result
            }
            return .processed(Int(written))
        } catch let err as IOError {
            if err.errnoCode == EAGAIN {
                return .wouldBlock(Int(written))
            }
            throw err
        }
    }

    @inline(never)
    public static func sendmmsg(sockfd: CInt, msgvec: UnsafeMutablePointer<MMsgHdr>, vlen: CUnsignedInt, flags: CInt) throws -> IOResult<Int> {
        return try syscall(blocking: true) {
            Int(CNIOLinux_sendmmsg(sockfd, msgvec, vlen, flags))
        }
    }

    @inline(never)
    public static func recvmmsg(sockfd: CInt, msgvec: UnsafeMutablePointer<MMsgHdr>, vlen: CUnsignedInt, flags: CInt, timeout: UnsafeMutablePointer<timespec>?) throws -> IOResult<Int> {
        return try syscall(blocking: true) {
            Int(CNIOLinux_recvmmsg(sockfd, msgvec, vlen, flags, timeout))
        }
    }

    @inline(never)
    public static func getifaddrs(_ addrs: UnsafeMutablePointer<UnsafeMutablePointer<ifaddrs>?>) throws {
        _ = try syscall(blocking: false) { () -> CInt in
#if os(Android)
            return android_getifaddrs(addrs)
#else
            return Glibc.getifaddrs(addrs)
#endif
        }
    }

    @inline(never)
    public static func if_nametoindex(_ name: UnsafePointer<CChar>?) throws -> CUnsignedInt {
        return try syscall(blocking: false) {
            Glibc.if_nametoindex(name)
        }.result
    }

    @inline(never)
    public static func poll(fds: UnsafeMutablePointer<pollfd>, nfds: nfds_t, timeout: CInt) throws -> CInt {
        return try syscall(blocking: false) {
            Glibc.poll(fds, nfds, timeout)
        }.result
    }

    @inline(never)
    public static func fstat(descriptor: CInt, outStat: UnsafeMutablePointer<stat>) throws {
        _ = try syscall(blocking: false) {
            Glibc.fstat(descriptor, outStat)
        }
    }

    @inline(never)
    public static func socketpair(domain: CInt,
                                  type: CInt,
                                  protocol: CInt,
                                  socketVector: UnsafeMutablePointer<CInt>?) throws {
        _ = try syscall(blocking: false) {
            Glibc.socketpair(domain, type, `protocol`, socketVector)
        }
    }
}

#endif
