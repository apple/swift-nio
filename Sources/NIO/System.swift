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

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
@_exported import Darwin.C
import CNIODarwin
internal typealias MMsgHdr = CNIODarwin_mmsghdr
#elseif os(Linux) || os(FreeBSD) || os(Android)
@_exported import Glibc
import CNIOLinux
internal typealias MMsgHdr = CNIOLinux_mmsghdr
#else
let badOS = { fatalError("unsupported OS") }()
#endif

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
private let sysShutdown = shutdown
private let sysBind = bind
private let sysFcntl: (CInt, CInt, CInt) -> CInt = fcntl
private let sysSocket = socket
private let sysSetsockopt = setsockopt
private let sysGetsockopt = getsockopt
private let sysListen = listen
private let sysAccept = accept
private let sysConnect = connect
private let sysOpen: (UnsafePointer<CChar>, CInt) -> CInt = open
private let sysOpenWithMode: (UnsafePointer<CChar>, CInt, mode_t) -> CInt = open
private let sysFtruncate = ftruncate
private let sysWrite = write
private let sysPwrite = pwrite
private let sysRead = read
private let sysPread = pread
private let sysLseek = lseek
private let sysPoll = poll
#if os(Android)
func sysRecvFrom_wrapper(sockfd: CInt, buf: UnsafeMutableRawPointer, len: CLong, flags: CInt, src_addr: UnsafeMutablePointer<sockaddr>, addrlen: UnsafeMutablePointer<socklen_t>) -> CLong {
    return recvfrom(sockfd, buf, len, flags, src_addr, addrlen) // src_addr is 'UnsafeMutablePointer', but it need to be 'UnsafePointer'
}
func sysWritev_wrapper(fd: CInt, iov: UnsafePointer<iovec>?, iovcnt: CInt) -> CLong {
    return CLong(writev(fd, iov, iovcnt)) // cast 'Int32' to 'CLong'
}
private let sysRecvFrom = sysRecvFrom_wrapper
private let sysWritev = sysWritev_wrapper
#else
private let sysRecvFrom: @convention(c) (CInt, UnsafeMutableRawPointer?, CLong, CInt, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?) -> CLong = recvfrom
private let sysWritev: @convention(c) (Int32, UnsafePointer<iovec>?, CInt) -> CLong = writev
#endif
private let sysSendTo: @convention(c) (CInt, UnsafeRawPointer?, CLong, CInt, UnsafePointer<sockaddr>?, socklen_t) -> CLong = sendto
private let sysDup: @convention(c) (CInt) -> CInt = dup
private let sysGetpeername: @convention(c) (CInt, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?) -> CInt = getpeername
private let sysGetsockname: @convention(c) (CInt, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?) -> CInt = getsockname
private let sysGetifaddrs: @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<ifaddrs>?>?) -> CInt = getifaddrs
private let sysFreeifaddrs: @convention(c) (UnsafeMutablePointer<ifaddrs>?) -> Void = freeifaddrs
private let sysIfNameToIndex: @convention(c) (UnsafePointer<CChar>?) -> CUnsignedInt = if_nametoindex
private let sysAF_INET = AF_INET
private let sysAF_INET6 = AF_INET6
private let sysAF_UNIX = AF_UNIX
private let sysInet_ntop: @convention(c) (CInt, UnsafeRawPointer?, UnsafeMutablePointer<CChar>?, socklen_t) -> UnsafePointer<CChar>? = inet_ntop
private let sysSocketpair: @convention(c) (CInt, CInt, CInt, UnsafeMutablePointer<CInt>?) -> CInt = socketpair

#if os(Linux)
private let sysFstat: @convention(c) (CInt, UnsafeMutablePointer<stat>) -> CInt = fstat
private let sysSendMmsg: @convention(c) (CInt, UnsafeMutablePointer<CNIOLinux_mmsghdr>?, CUnsignedInt, CInt) -> CInt = CNIOLinux_sendmmsg
private let sysRecvMmsg: @convention(c) (CInt, UnsafeMutablePointer<CNIOLinux_mmsghdr>?, CUnsignedInt, CInt, UnsafeMutablePointer<timespec>?) -> CInt  = CNIOLinux_recvmmsg
#else
private let sysFstat: @convention(c) (CInt, UnsafeMutablePointer<stat>?) -> CInt = fstat
private let sysKevent = kevent
private let sysSendMmsg: @convention(c) (CInt, UnsafeMutablePointer<CNIODarwin_mmsghdr>?, CUnsignedInt, CInt) -> CInt = CNIODarwin_sendmmsg
private let sysRecvMmsg: @convention(c) (CInt, UnsafeMutablePointer<CNIODarwin_mmsghdr>?, CUnsignedInt, CInt, UnsafeMutablePointer<timespec>?) -> CInt = CNIODarwin_recvmmsg
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

enum Shutdown {
    case RD
    case WR
    case RDWR

    fileprivate var cValue: CInt {
        switch self {
        case .RD:
            return CInt(Posix.SHUT_RD)
        case .WR:
            return CInt(Posix.SHUT_WR)
        case .RDWR:
            return CInt(Posix.SHUT_RDWR)
        }
    }
}

internal enum Posix {
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
    static let SOCK_STREAM: CInt = CInt(Darwin.SOCK_STREAM)
    static let SOCK_DGRAM: CInt = CInt(Darwin.SOCK_DGRAM)
    static let IPPROTO_TCP: CInt = CInt(Darwin.IPPROTO_TCP)
    static let UIO_MAXIOV: Int = 1024
    static let SHUT_RD: CInt = CInt(Darwin.SHUT_RD)
    static let SHUT_WR: CInt = CInt(Darwin.SHUT_WR)
    static let SHUT_RDWR: CInt = CInt(Darwin.SHUT_RDWR)
#elseif os(Linux) || os(FreeBSD) || os(Android)

#if os(Android)
    static let SOCK_STREAM: CInt = CInt(Glibc.SOCK_STREAM)
    static let SOCK_DGRAM: CInt = CInt(Glibc.SOCK_DGRAM)
#else
    static let SOCK_STREAM: CInt = CInt(Glibc.SOCK_STREAM.rawValue)
    static let SOCK_DGRAM: CInt = CInt(Glibc.SOCK_DGRAM.rawValue)
#endif
    static let IPPROTO_TCP: CInt = CInt(Glibc.IPPROTO_TCP)
    static let UIO_MAXIOV: Int = Int(Glibc.UIO_MAXIOV)
    static let SHUT_RD: CInt = CInt(Glibc.SHUT_RD)
    static let SHUT_WR: CInt = CInt(Glibc.SHUT_WR)
    static let SHUT_RDWR: CInt = CInt(Glibc.SHUT_RDWR)
#else
    static var SOCK_STREAM: CInt {
        fatalError("unsupported OS")
    }
    static var SOCK_DGRAM: CInt {
        fatalError("unsupported OS")
    }
    static var UIO_MAXIOV: Int {
        fatalError("unsupported OS")
    }
#endif

    static let AF_INET = sa_family_t(sysAF_INET)
    static let AF_INET6 = sa_family_t(sysAF_INET6)
    static let AF_UNIX = sa_family_t(sysAF_UNIX)

    @inline(never)
    public static func shutdown(descriptor: CInt, how: Shutdown) throws {
        _ = try syscall(blocking: false) {
            sysShutdown(descriptor, how.cValue)
        }
    }

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
    public static func bind(descriptor: CInt, ptr: UnsafePointer<sockaddr>, bytes: Int) throws {
         _ = try syscall(blocking: false) {
            sysBind(descriptor, ptr, socklen_t(bytes))
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
    public static func socket(domain: CInt, type: CInt, `protocol`: CInt) throws -> CInt {
        return try syscall(blocking: false) {
            return sysSocket(domain, type, `protocol`)
        }.result
    }

    @inline(never)
    public static func setsockopt(socket: CInt, level: CInt, optionName: CInt,
                                  optionValue: UnsafeRawPointer, optionLen: socklen_t) throws {
        _ = try syscall(blocking: false) {
            sysSetsockopt(socket, level, optionName, optionValue, optionLen)
        }
    }

    @inline(never)
    public static func getsockopt(socket: CInt, level: CInt, optionName: CInt,
                                  optionValue: UnsafeMutableRawPointer,
                                  optionLen: UnsafeMutablePointer<socklen_t>) throws {
        _ = try syscall(blocking: false) {
            sysGetsockopt(socket, level, optionName, optionValue, optionLen)
        }.result
    }

    @inline(never)
    public static func listen(descriptor: CInt, backlog: CInt) throws {
        _ = try syscall(blocking: false) {
            sysListen(descriptor, backlog)
        }
    }

    @inline(never)
    public static func accept(descriptor: CInt,
                              addr: UnsafeMutablePointer<sockaddr>?,
                              len: UnsafeMutablePointer<socklen_t>?) throws -> CInt? {
        let result: IOResult<CInt> = try syscall(blocking: true) {
            let fd = sysAccept(descriptor, addr, len)

            #if !os(Linux)
                if fd != -1 {
                    do {
                        try Posix.fcntl(descriptor: fd, command: F_SETNOSIGPIPE, value: 1)
                    } catch {
                        _ = sysClose(fd) // don't care about failure here
                        throw error
                    }
                }
            #endif
            return fd
        }

        if case .processed(let fd) = result {
            return fd
        } else {
            return nil
        }
    }

    @inline(never)
    public static func connect(descriptor: CInt, addr: UnsafePointer<sockaddr>, size: socklen_t) throws -> Bool {
        do {
            _ = try syscall(blocking: false) {
                sysConnect(descriptor, addr, size)
            }
            return true
        } catch let err as IOError {
            if err.errnoCode == EINPROGRESS {
                return false
            }
            throw err
        }
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
    public static func sendto(descriptor: CInt, pointer: UnsafeRawPointer, size: size_t,
                              destinationPtr: UnsafePointer<sockaddr>, destinationSize: socklen_t) throws -> IOResult<Int> {
        return try syscall(blocking: true) {
            sysSendTo(descriptor, pointer, size, 0, destinationPtr, destinationSize)
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

    @inline(never)
    public static func recvfrom(descriptor: CInt, pointer: UnsafeMutableRawPointer, len: size_t, addr: UnsafeMutablePointer<sockaddr>, addrlen: UnsafeMutablePointer<socklen_t>) throws -> IOResult<ssize_t> {
        return try syscall(blocking: true) {
            sysRecvFrom(descriptor, pointer, len, 0, addr, addrlen)
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

    @discardableResult
    @inline(never)
    public static func inet_ntop(addressFamily: sa_family_t, addressBytes: UnsafeRawPointer, addressDescription: UnsafeMutablePointer<CChar>, addressDescriptionLength: socklen_t) throws -> UnsafePointer<CChar> {
        return try wrapErrorIsNullReturnCall {
            sysInet_ntop(CInt(addressFamily), addressBytes, addressDescription, addressDescriptionLength)
        }
    }

    // It's not really posix but exists on Linux and MacOS / BSD so just put it here for now to keep it simple
    @inline(never)
    public static func sendfile(descriptor: CInt, fd: CInt, offset: off_t, count: size_t) throws -> IOResult<Int> {
        var written: off_t = 0
        do {
            _ = try syscall(blocking: false) { () -> ssize_t in
                #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
                    var w: off_t = off_t(count)
                    let result: CInt = Darwin.sendfile(fd, descriptor, offset, &w, nil, 0)
                    written = w
                    return ssize_t(result)
                #elseif os(Linux) || os(FreeBSD) || os(Android)
                    var off: off_t = offset
                    let result: ssize_t = Glibc.sendfile(descriptor, fd, &off, count)
                    if result >= 0 {
                        written = result
                    } else {
                        written = 0
                    }
                    return result
                #else
                    fatalError("unsupported OS")
                #endif
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
            Int(sysSendMmsg(sockfd, msgvec, vlen, flags))
        }
    }

    @inline(never)
    public static func recvmmsg(sockfd: CInt, msgvec: UnsafeMutablePointer<MMsgHdr>, vlen: CUnsignedInt, flags: CInt, timeout: UnsafeMutablePointer<timespec>?) throws -> IOResult<Int> {
        return try syscall(blocking: true) {
            Int(sysRecvMmsg(sockfd, msgvec, vlen, flags, timeout))
        }
    }

    @inline(never)
    public static func getpeername(socket: CInt, address: UnsafeMutablePointer<sockaddr>, addressLength: UnsafeMutablePointer<socklen_t>) throws {
        _ = try syscall(blocking: false) {
            return sysGetpeername(socket, address, addressLength)
        }
    }

    @inline(never)
    public static func getsockname(socket: CInt, address: UnsafeMutablePointer<sockaddr>, addressLength: UnsafeMutablePointer<socklen_t>) throws {
        _ = try syscall(blocking: false) {
            return sysGetsockname(socket, address, addressLength)
        }
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
    public static func poll(fds: UnsafeMutablePointer<pollfd>, nfds: nfds_t, timeout: CInt) throws -> CInt {
        return try syscall(blocking: false) {
            sysPoll(fds, nfds, timeout)
        }.result
    }

    @inline(never)
    public static func fstat(descriptor: CInt, outStat: UnsafeMutablePointer<stat>) throws {
        _ = try syscall(blocking: false) {
            sysFstat(descriptor, outStat)
        }
    }

    @inline(never)
    public static func socketpair(domain: CInt,
                                  type: CInt,
                                  protocol: CInt,
                                  socketVector: UnsafeMutablePointer<CInt>?) throws {
        _ = try syscall(blocking: false) {
            sysSocketpair(domain, type, `protocol`, socketVector)
        }
    }
}

/// `NIOFailedToSetSocketNonBlockingError` indicates that NIO was unable to set a socket to non-blocking mode, either
/// when connecting a socket as a client or when accepting a socket as a server.
///
/// This error should never happen because a socket should always be able to be set to non-blocking mode. Unfortunately,
/// we have seen this happen on Darwin.
public struct NIOFailedToSetSocketNonBlockingError: Error {}

internal extension Posix {
    static func setNonBlocking(socket: CInt) throws {
        let flags = try Posix.fcntl(descriptor: socket, command: F_GETFL, value: 0)
        do {
            let ret = try Posix.fcntl(descriptor: socket, command: F_SETFL, value: flags | O_NONBLOCK)
            assert(ret == 0, "unexpectedly, fcntl(\(socket), F_SETFL, \(flags) | O_NONBLOCK) returned \(ret)")
        } catch let error as IOError {
            if error.errnoCode == EINVAL {
                // Darwin seems to sometimes do this despite the docs claiming it can't happen
                throw NIOFailedToSetSocketNonBlockingError()
            }
            throw error
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
