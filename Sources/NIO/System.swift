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
//  This file contains code that ensures errno is captured correctly when doing syscalls and no ARC traffic can happen inbetween that *could* change the errno
//  value before we were able to read it.
//  It's important that all static methods are declared with `@inline(never)` so it's not possible any ARC traffic happens while we need to read errno.
//
//  Created by Norman Maurer on 11/10/17.
//

#if os(Android)
let INADDR_ANY = UInt32(0) // #define INADDR_ANY ((unsigned long int) 0x00000000)
internal typealias sockaddr_storage = __kernel_sockaddr_storage
internal typealias in_port_t = UInt16
let getifaddrs: @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<ifaddrs>?>?) -> CInt = android_getifaddrs
let freeifaddrs: @convention(c) (UnsafeMutablePointer<ifaddrs>?) -> Void = android_freeifaddrs
extension ipv6_mreq { // http://lkml.iu.edu/hypermail/linux/kernel/0106.1/0080.html
    init (ipv6mr_multiaddr: in6_addr, ipv6mr_interface: UInt32) {
        self.ipv6mr_multiaddr = ipv6mr_multiaddr
        self.ipv6mr_ifindex = Int32(bitPattern: ipv6mr_interface)
    }
}
#endif

// Declare aliases to share more code and not need to repeat #if #else blocks
private let sysClose = close
private let sysFcntl: (CInt, CInt, CInt) -> CInt = fcntl
private let sysSocket = socket
private let sysOpen: (UnsafePointer<CChar>, CInt) -> CInt = open
private let sysOpenWithMode: (UnsafePointer<CChar>, CInt, mode_t) -> CInt = open
private let sysFtruncate = ftruncate
private let sysWrite = write
private let sysPwrite = pwrite
private let sysRead = read
private let sysPread = pread
private let sysLseek = lseek
#if os(Android)
func sysWritev_wrapper(fd: CInt, iov: UnsafePointer<iovec>?, iovcnt: CInt) -> CLong {
    return CLong(writev(fd, iov, iovcnt)) // cast 'Int32' to 'CLong'
}
private let sysRecvFrom = sysRecvFrom_wrapper
private let sysWritev = sysWritev_wrapper
#else
private let sysWritev: @convention(c) (Int32, UnsafePointer<iovec>?, CInt) -> CLong = writev
#endif
private let sysDup: @convention(c) (CInt) -> CInt = dup
private let sysGetifaddrs: @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<ifaddrs>?>?) -> CInt = getifaddrs
private let sysFreeifaddrs: @convention(c) (UnsafeMutablePointer<ifaddrs>?) -> Void = freeifaddrs
private let sysIfNameToIndex: @convention(c) (UnsafePointer<CChar>?) -> CUnsignedInt = if_nametoindex
private let sysSocketpair: @convention(c) (CInt, CInt, CInt, UnsafeMutablePointer<CInt>?) -> CInt = socketpair

#if os(Linux)
private let sysFstat: @convention(c) (CInt, UnsafeMutablePointer<stat>) -> CInt = fstat
#else
private let sysFstat: @convention(c) (CInt, UnsafeMutablePointer<stat>?) -> CInt = fstat
private let sysKevent = kevent
#endif

private func isBlacklistedErrno(_ code: Int32) -> Bool {
    switch code {
    case EFAULT, EBADF:
        return true
    default:
        return false
    }
}

internal func preconditionIsNotBlacklistedErrno(err: CInt, where function: String) -> Void {
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

/* Sorry, we really try hard to not use underscored attributes. In this case however we seem to break the inlining threshold which makes a system call take twice the time, ie. we need this exception. */
@inline(__always)
internal func wrapErrorIsNullReturnCall<T>(where function: String = #function, _ body: () throws -> T?) throws -> T {
    while true {
        guard let res = try body() else {
            let err = errno
            if err == EINTR {
                continue
            }
            preconditionIsNotBlacklistedErrno(err: err, where: function)
            throw IOError(errnoCode: err, reason: function)
        }
        return res
    }
}

internal enum Posix {
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
    static let UIO_MAXIOV: Int = 1024
#elseif os(Linux) || os(FreeBSD) || os(Android)
    static let UIO_MAXIOV: Int = Int(Glibc.UIO_MAXIOV)
#else
    static var UIO_MAXIOV: Int {
        fatalError("unsupported OS")
    }
#endif

    @inline(never)
    public static func close(descriptor: CInt) throws {
        let res = sysClose(descriptor)
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
            sysFcntl(descriptor, command, value)
        }.result
    }

    @inline(never)
    public static func open(file: UnsafePointer<CChar>, oFlag: CInt, mode: mode_t) throws -> CInt {
        return try syscall(blocking: false) {
            sysOpenWithMode(file, oFlag, mode)
        }.result
    }

    @inline(never)
    public static func open(file: UnsafePointer<CChar>, oFlag: CInt) throws -> CInt {
        return try syscall(blocking: false) {
            sysOpen(file, oFlag)
        }.result
    }

    @inline(never)
    @discardableResult
    public static func ftruncate(descriptor: CInt, size: off_t) throws -> CInt {
        return try syscall(blocking: false) {
            sysFtruncate(descriptor, size)
        }.result
    }
    
    @inline(never)
    public static func write(descriptor: CInt, pointer: UnsafeRawPointer, size: Int) throws -> IOResult<Int> {
        return try syscall(blocking: true) {
            sysWrite(descriptor, pointer, size)
        }
    }

    @inline(never)
    public static func pwrite(descriptor: CInt, pointer: UnsafeRawPointer, size: Int, offset: off_t) throws -> IOResult<Int> {
        return try syscall(blocking: true) {
            sysPwrite(descriptor, pointer, size, offset)
        }
    }

    @inline(never)
    public static func writev(descriptor: CInt, iovecs: UnsafeBufferPointer<IOVector>) throws -> IOResult<Int> {
        return try syscall(blocking: true) {
            sysWritev(descriptor, iovecs.baseAddress!, CInt(iovecs.count))
        }
    }

    @inline(never)
    public static func read(descriptor: CInt, pointer: UnsafeMutableRawPointer, size: size_t) throws -> IOResult<ssize_t> {
        return try syscall(blocking: true) {
            sysRead(descriptor, pointer, size)
        }
    }

    @inline(never)
    public static func pread(descriptor: CInt, pointer: UnsafeMutableRawPointer, size: size_t, offset: off_t) throws -> IOResult<ssize_t> {
        return try syscall(blocking: true) {
            sysPread(descriptor, pointer, size, offset)
        }
    }

    @discardableResult
    @inline(never)
    public static func lseek(descriptor: CInt, offset: off_t, whence: CInt) throws -> off_t {
        return try syscall(blocking: false) {
            sysLseek(descriptor, offset, whence)
        }.result
    }

    @discardableResult
    @inline(never)
    public static func dup(descriptor: CInt) throws -> CInt {
        return try syscall(blocking: false) {
            sysDup(descriptor)
        }.result
    }

    @inline(never)
    public static func getifaddrs(_ addrs: UnsafeMutablePointer<UnsafeMutablePointer<ifaddrs>?>) throws {
        _ = try syscall(blocking: false) {
            sysGetifaddrs(addrs)
        }
    }

    @inline(never)
    public static func if_nametoindex(_ name: UnsafePointer<CChar>?) throws -> CUnsignedInt {
        return try syscall(blocking: false) {
            sysIfNameToIndex(name)
        }.result
    }

    @inline(never)
    public static func fstat(descriptor: CInt, outStat: UnsafeMutablePointer<stat>) throws {
        _ = try syscall(blocking: false) {
            sysFstat(descriptor, outStat)
        }
    }

    @inline(never)
    public static func socketpair(domain: NIOBSDSocket.ProtocolFamily,
                                  type: NIOBSDSocket.SocketType,
                                  protocol: CInt,
                                  socketVector: UnsafeMutablePointer<CInt>?) throws {
        _ = try syscall(blocking: false) {
            sysSocketpair(domain.rawValue, type.rawValue, `protocol`, socketVector)
        }
    }
}

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
internal enum KQueue {

    // TODO: Figure out how to specify a typealias to the kevent struct without run into trouble with the swift compiler

    @inline(never)
    public static func kqueue() throws -> CInt {
        return try syscall(blocking: false) {
            Darwin.kqueue()
        }.result
    }

    @inline(never)
    @discardableResult
    public static func kevent(kq: CInt, changelist: UnsafePointer<kevent>?, nchanges: CInt, eventlist: UnsafeMutablePointer<kevent>?, nevents: CInt, timeout: UnsafePointer<Darwin.timespec>?) throws -> CInt {
        return try syscall(blocking: false) {
            sysKevent(kq, changelist, nchanges, eventlist, nevents, timeout)
        }.result
    }
}
#endif
