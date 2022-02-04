//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
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

import NIOCore

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
@_exported import Darwin.C
import CNIODarwin
internal typealias MMsgHdr = CNIODarwin_mmsghdr
#elseif os(Linux) || os(FreeBSD) || os(Android)
@_exported import Glibc
import CNIOLinux
internal typealias MMsgHdr = CNIOLinux_mmsghdr
internal typealias in6_pktinfo = CNIOLinux_in6_pktinfo
#elseif os(Windows)
import CNIOWindows
internal typealias sockaddr = WinSDK.SOCKADDR
internal typealias MMsgHdr = CNIOWindows_mmsghdr
#else
let badOS = { fatalError("unsupported OS") }()
#endif

#if os(Android)
let INADDR_ANY = UInt32(0) // #define INADDR_ANY ((unsigned long int) 0x00000000)
let IFF_BROADCAST: CUnsignedInt = numericCast(SwiftGlibc.IFF_BROADCAST.rawValue)
let IFF_POINTOPOINT: CUnsignedInt = numericCast(SwiftGlibc.IFF_POINTOPOINT.rawValue)
let IFF_MULTICAST: CUnsignedInt = numericCast(SwiftGlibc.IFF_MULTICAST.rawValue)
internal typealias in_port_t = UInt16
extension ipv6_mreq { // http://lkml.iu.edu/hypermail/linux/kernel/0106.1/0080.html
    init (ipv6mr_multiaddr: in6_addr, ipv6mr_interface: UInt32) {
        self.init(ipv6mr_multiaddr: ipv6mr_multiaddr,
                  ipv6mr_ifindex: Int32(bitPattern: ipv6mr_interface))
    }
}
#if arch(arm)
let S_IFSOCK = UInt32(SwiftGlibc.S_IFSOCK)
let S_IFMT = UInt32(SwiftGlibc.S_IFMT)
let S_IFREG = UInt32(SwiftGlibc.S_IFREG)
let S_IFDIR = UInt32(SwiftGlibc.S_IFDIR)
let S_IFLNK = UInt32(SwiftGlibc.S_IFLNK)
let S_IFBLK = UInt32(SwiftGlibc.S_IFBLK)
#endif
#endif

// Declare aliases to share more code and not need to repeat #if #else blocks
#if !os(Windows)
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
#endif

#if os(Android)
func sysRecvFrom_wrapper(sockfd: CInt, buf: UnsafeMutableRawPointer, len: CLong, flags: CInt, src_addr: UnsafeMutablePointer<sockaddr>, addrlen: UnsafeMutablePointer<socklen_t>) -> CLong {
    return recvfrom(sockfd, buf, len, flags, src_addr, addrlen) // src_addr is 'UnsafeMutablePointer', but it need to be 'UnsafePointer'
}
func sysWritev_wrapper(fd: CInt, iov: UnsafePointer<iovec>?, iovcnt: CInt) -> CLong {
    return CLong(writev(fd, iov, iovcnt)) // cast 'Int32' to 'CLong'
}
private let sysWritev = sysWritev_wrapper
#elseif !os(Windows)
private let sysWritev: @convention(c) (Int32, UnsafePointer<iovec>?, CInt) -> CLong = writev
#endif
#if !os(Windows)
private let sysRecvMsg: @convention(c) (CInt, UnsafeMutablePointer<msghdr>?, CInt) -> ssize_t = recvmsg
private let sysSendMsg: @convention(c) (CInt, UnsafePointer<msghdr>?, CInt) -> ssize_t = sendmsg
#endif
private let sysDup: @convention(c) (CInt) -> CInt = dup
#if !os(Windows)
private let sysGetpeername: @convention(c) (CInt, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?) -> CInt = getpeername
private let sysGetsockname: @convention(c) (CInt, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?) -> CInt = getsockname
#endif
private let sysFreeifaddrs: @convention(c) (UnsafeMutablePointer<ifaddrs>?) -> Void = freeifaddrs
private let sysIfNameToIndex: @convention(c) (UnsafePointer<CChar>?) -> CUnsignedInt = if_nametoindex
#if !os(Windows)
private let sysSocketpair: @convention(c) (CInt, CInt, CInt, UnsafeMutablePointer<CInt>?) -> CInt = socketpair
#endif

#if os(Linux)
private let sysFstat: @convention(c) (CInt, UnsafeMutablePointer<stat>) -> CInt = fstat
private let sysStat: @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<stat>) -> CInt = stat
private let sysUnlink: @convention(c) (UnsafePointer<CChar>) -> CInt = unlink
#elseif os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(Android)
private let sysFstat: @convention(c) (CInt, UnsafeMutablePointer<stat>?) -> CInt = fstat
private let sysStat: @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<stat>?) -> CInt = stat
private let sysUnlink: @convention(c) (UnsafePointer<CChar>?) -> CInt = unlink
#endif
#if os(Linux) || os(Android)
private let sysSendMmsg: @convention(c) (CInt, UnsafeMutablePointer<CNIOLinux_mmsghdr>?, CUnsignedInt, CInt) -> CInt = CNIOLinux_sendmmsg
private let sysRecvMmsg: @convention(c) (CInt, UnsafeMutablePointer<CNIOLinux_mmsghdr>?, CUnsignedInt, CInt, UnsafeMutablePointer<timespec>?) -> CInt  = CNIOLinux_recvmmsg
#elseif os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
private let sysKevent = kevent
private let sysSendMmsg: @convention(c) (CInt, UnsafeMutablePointer<CNIODarwin_mmsghdr>?, CUnsignedInt, CInt) -> CInt = CNIODarwin_sendmmsg
private let sysRecvMmsg: @convention(c) (CInt, UnsafeMutablePointer<CNIODarwin_mmsghdr>?, CUnsignedInt, CInt, UnsafeMutablePointer<timespec>?) -> CInt = CNIODarwin_recvmmsg
#endif

private func isUnacceptableErrno(_ code: Int32) -> Bool {
    // On iOS, EBADF is a possible result when a file descriptor has been reaped in the background.
    // In particular, it's possible to get EBADF from accept(), where the underlying accept() FD
    // is valid but the accepted one is not. The right solution here is to perform a check for
    // SO_ISDEFUNCT when we see this happen, but we haven't yet invested the time to do that.
    // In the meantime, we just tolerate EBADF on iOS.
    #if os(iOS) || os(watchOS) || os(tvOS)
    switch code {
    case EFAULT:
        return true
    default:
        return false
    }
    #else
    switch code {
    case EFAULT, EBADF:
        return true
    default:
        return false
    }
    #endif
}

private func isUnacceptableErrnoOnClose(_ code: Int32) -> Bool {
    // We treat close() differently to all other FDs: we still want to catch EBADF here.
    switch code {
    case EFAULT, EBADF:
        return true
    default:
        return false
    }
}

private func isUnacceptableErrnoForbiddingEINVAL(_ code: Int32) -> Bool {
    // We treat read() and pread() differently since we also want to catch EINVAL.
    #if os(iOS) || os(watchOS) || os(tvOS)
    switch code {
    case EFAULT, EINVAL:
        return true
    default:
        return false
    }
    #else
    switch code {
    case EFAULT, EBADF, EINVAL:
        return true
    default:
        return false
    }
    #endif
}

private func preconditionIsNotUnacceptableErrno(err: CInt, where function: String) -> Void {
    // strerror is documented to return "Unknown error: ..." for illegal value so it won't ever fail
    precondition(!isUnacceptableErrno(err), "unacceptable errno \(err) \(String(cString: strerror(err)!)) in \(function))")
}

private func preconditionIsNotUnacceptableErrnoOnClose(err: CInt, where function: String) -> Void {
    // strerror is documented to return "Unknown error: ..." for illegal value so it won't ever fail
    precondition(!isUnacceptableErrnoOnClose(err), "unacceptable errno \(err) \(String(cString: strerror(err)!)) in \(function))")
}

private func preconditionIsNotUnacceptableErrnoForbiddingEINVAL(err: CInt, where function: String) -> Void {
    // strerror is documented to return "Unknown error: ..." for illegal value so it won't ever fail
    precondition(!isUnacceptableErrnoForbiddingEINVAL(err), "unacceptable errno \(err) \(String(cString: strerror(err)!)) in \(function))")
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
                preconditionIsNotUnacceptableErrno(err: err, where: function)
                throw IOError(errnoCode: err, reason: function)
            }
        }
        return .processed(res)
    }
}


/*
 * Sorry, we really try hard to not use underscored attributes. In this case
 * however we seem to break the inlining threshold which makes a system call
 * take twice the time, ie. we need this exception.
 */
@inline(__always)
@discardableResult
internal func syscallForbiddingEINVAL<T: FixedWidthInteger>(where function: String = #function,
                                            _ body: () throws -> T)
        throws -> IOResult<T> {
    while true {
        let res = try body()
        if res == -1 {
            let err = errno
            switch err {
            case EINTR:
                continue
            case EWOULDBLOCK:
                return .wouldBlock(0)
            default:
                preconditionIsNotUnacceptableErrnoForbiddingEINVAL(err: err, where: function)
                throw IOError(errnoCode: err, reason: function)
            }
        }
        return .processed(res)
    }
}

internal enum Posix {
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
    static let UIO_MAXIOV: Int = 1024
    static let SHUT_RD: CInt = CInt(Darwin.SHUT_RD)
    static let SHUT_WR: CInt = CInt(Darwin.SHUT_WR)
    static let SHUT_RDWR: CInt = CInt(Darwin.SHUT_RDWR)
    static let IPTOS_ECN_NOTECT: CInt = CNIODarwin_IPTOS_ECN_NOTECT
    static let IPTOS_ECN_MASK: CInt = CNIODarwin_IPTOS_ECN_MASK
    static let IPTOS_ECN_ECT0: CInt = CNIODarwin_IPTOS_ECN_ECT0
    static let IPTOS_ECN_ECT1: CInt = CNIODarwin_IPTOS_ECN_ECT1
    static let IPTOS_ECN_CE: CInt = CNIODarwin_IPTOS_ECN_CE
    static let IP_RECVPKTINFO: CInt = CNIODarwin.IP_RECVPKTINFO
    static let IP_PKTINFO: CInt = CNIODarwin.IP_PKTINFO
    static let IPV6_RECVPKTINFO: CInt = CNIODarwin_IPV6_RECVPKTINFO
    static let IPV6_PKTINFO: CInt = CNIODarwin_IPV6_PKTINFO
#elseif os(Linux) || os(FreeBSD) || os(Android)

    static let UIO_MAXIOV: Int = Int(Glibc.UIO_MAXIOV)
    static let SHUT_RD: CInt = CInt(Glibc.SHUT_RD)
    static let SHUT_WR: CInt = CInt(Glibc.SHUT_WR)
    static let SHUT_RDWR: CInt = CInt(Glibc.SHUT_RDWR)
    #if os(Android)
    static let IPTOS_ECN_NOTECT: CInt = CInt(CNIOLinux.IPTOS_ECN_NOTECT)
    #else
    static let IPTOS_ECN_NOTECT: CInt = CInt(CNIOLinux.IPTOS_ECN_NOT_ECT)
    #endif
    static let IPTOS_ECN_MASK: CInt = CInt(CNIOLinux.IPTOS_ECN_MASK)
    static let IPTOS_ECN_ECT0: CInt = CInt(CNIOLinux.IPTOS_ECN_ECT0)
    static let IPTOS_ECN_ECT1: CInt = CInt(CNIOLinux.IPTOS_ECN_ECT1)
    static let IPTOS_ECN_CE: CInt = CInt(CNIOLinux.IPTOS_ECN_CE)
    static let IP_RECVPKTINFO: CInt = CInt(CNIOLinux.IP_PKTINFO)
    static let IP_PKTINFO: CInt = CInt(CNIOLinux.IP_PKTINFO)
    static let IPV6_RECVPKTINFO: CInt = CInt(CNIOLinux.IPV6_RECVPKTINFO)
    static let IPV6_PKTINFO: CInt = CInt(CNIOLinux.IPV6_PKTINFO)
#else
    static var UIO_MAXIOV: Int {
        fatalError("unsupported OS")
    }
    static var SHUT_RD: Int {
        fatalError("unsupported OS")
    }
    static var SHUT_WR: Int {
        fatalError("unsupported OS")
    }
    static var SHUT_RDWR: Int {
        fatalError("unsupported OS")
    }
#endif

#if !os(Windows)
    @inline(never)
    internal static func shutdown(descriptor: CInt, how: Shutdown) throws {
        _ = try syscall(blocking: false) {
            sysShutdown(descriptor, how.cValue)
        }
    }

    @inline(never)
    internal static func close(descriptor: CInt) throws {
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
                preconditionIsNotUnacceptableErrnoOnClose(err: err, where: #function)
                throw IOError(errnoCode: err, reason: "close")
            }
        }
    }

    @inline(never)
    internal static func bind(descriptor: CInt, ptr: UnsafePointer<sockaddr>, bytes: Int) throws {
         _ = try syscall(blocking: false) {
            sysBind(descriptor, ptr, socklen_t(bytes))
        }
    }

    @inline(never)
    @discardableResult
    // TODO: Allow varargs
    internal static func fcntl(descriptor: CInt, command: CInt, value: CInt) throws -> CInt {
        return try syscall(blocking: false) {
            sysFcntl(descriptor, command, value)
        }.result
    }

    @inline(never)
    internal static func socket(domain: NIOBSDSocket.ProtocolFamily, type: NIOBSDSocket.SocketType, `protocol`: CInt) throws -> CInt {
        return try syscall(blocking: false) {
            return sysSocket(domain.rawValue, type.rawValue, `protocol`)
        }.result
    }

    @inline(never)
    internal static func setsockopt(socket: CInt, level: CInt, optionName: CInt,
                                  optionValue: UnsafeRawPointer, optionLen: socklen_t) throws {
        _ = try syscall(blocking: false) {
            sysSetsockopt(socket, level, optionName, optionValue, optionLen)
        }
    }

    @inline(never)
    internal static func getsockopt(socket: CInt, level: CInt, optionName: CInt,
                                  optionValue: UnsafeMutableRawPointer,
                                  optionLen: UnsafeMutablePointer<socklen_t>) throws {
        _ = try syscall(blocking: false) {
            sysGetsockopt(socket, level, optionName, optionValue, optionLen)
        }.result
    }

    @inline(never)
    internal static func listen(descriptor: CInt, backlog: CInt) throws {
        _ = try syscall(blocking: false) {
            sysListen(descriptor, backlog)
        }
    }

    @inline(never)
    internal static func accept(descriptor: CInt,
                              addr: UnsafeMutablePointer<sockaddr>?,
                              len: UnsafeMutablePointer<socklen_t>?) throws -> CInt? {
        let result: IOResult<CInt> = try syscall(blocking: true) {
            return sysAccept(descriptor, addr, len)
        }

        if case .processed(let fd) = result {
            return fd
        } else {
            return nil
        }
    }

    @inline(never)
    internal static func connect(descriptor: CInt, addr: UnsafePointer<sockaddr>, size: socklen_t) throws -> Bool {
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
    internal static func open(file: UnsafePointer<CChar>, oFlag: CInt, mode: mode_t) throws -> CInt {
        return try syscall(blocking: false) {
            sysOpenWithMode(file, oFlag, mode)
        }.result
    }

    @inline(never)
    internal static func open(file: UnsafePointer<CChar>, oFlag: CInt) throws -> CInt {
        return try syscall(blocking: false) {
            sysOpen(file, oFlag)
        }.result
    }

    @inline(never)
    @discardableResult
    internal static func ftruncate(descriptor: CInt, size: off_t) throws -> CInt {
        return try syscall(blocking: false) {
            sysFtruncate(descriptor, size)
        }.result
    }
    
    @inline(never)
    internal static func write(descriptor: CInt, pointer: UnsafeRawPointer, size: Int) throws -> IOResult<Int> {
        return try syscall(blocking: true) {
            sysWrite(descriptor, pointer, size)
        }
    }

    @inline(never)
    internal static func pwrite(descriptor: CInt, pointer: UnsafeRawPointer, size: Int, offset: off_t) throws -> IOResult<Int> {
        return try syscall(blocking: true) {
            sysPwrite(descriptor, pointer, size, offset)
        }
    }

#if !os(Windows)
    @inline(never)
    internal static func writev(descriptor: CInt, iovecs: UnsafeBufferPointer<IOVector>) throws -> IOResult<Int> {
        return try syscall(blocking: true) {
            sysWritev(descriptor, iovecs.baseAddress!, CInt(iovecs.count))
        }
    }
#endif

    @inline(never)
    internal static func read(descriptor: CInt, pointer: UnsafeMutableRawPointer, size: size_t) throws -> IOResult<ssize_t> {
        return try syscallForbiddingEINVAL {
            sysRead(descriptor, pointer, size)
        }
    }

    @inline(never)
    internal static func pread(descriptor: CInt, pointer: UnsafeMutableRawPointer, size: size_t, offset: off_t) throws -> IOResult<ssize_t> {
        return try syscallForbiddingEINVAL {
            sysPread(descriptor, pointer, size, offset)
        }
    }

    @inline(never)
    internal static func recvmsg(descriptor: CInt, msgHdr: UnsafeMutablePointer<msghdr>, flags: CInt) throws -> IOResult<ssize_t> {
        return try syscall(blocking: true) {
            sysRecvMsg(descriptor, msgHdr, flags)
        }
    }
    
    @inline(never)
    internal static func sendmsg(descriptor: CInt, msgHdr: UnsafePointer<msghdr>, flags: CInt) throws -> IOResult<ssize_t> {
        return try syscall(blocking: true) {
            sysSendMsg(descriptor, msgHdr, flags)
        }
    }

    @discardableResult
    @inline(never)
    internal static func lseek(descriptor: CInt, offset: off_t, whence: CInt) throws -> off_t {
        return try syscall(blocking: false) {
            sysLseek(descriptor, offset, whence)
        }.result
    }
#endif

    @discardableResult
    @inline(never)
    internal static func dup(descriptor: CInt) throws -> CInt {
        return try syscall(blocking: false) {
            sysDup(descriptor)
        }.result
    }

#if !os(Windows)
    // It's not really posix but exists on Linux and MacOS / BSD so just put it here for now to keep it simple
    @inline(never)
    internal static func sendfile(descriptor: CInt, fd: CInt, offset: off_t, count: size_t) throws -> IOResult<Int> {
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
                        written = off_t(result)
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
    internal static func sendmmsg(sockfd: CInt, msgvec: UnsafeMutablePointer<MMsgHdr>, vlen: CUnsignedInt, flags: CInt) throws -> IOResult<Int> {
        return try syscall(blocking: true) {
            Int(sysSendMmsg(sockfd, msgvec, vlen, flags))
        }
    }

    @inline(never)
    internal static func recvmmsg(sockfd: CInt, msgvec: UnsafeMutablePointer<MMsgHdr>, vlen: CUnsignedInt, flags: CInt, timeout: UnsafeMutablePointer<timespec>?) throws -> IOResult<Int> {
        return try syscall(blocking: true) {
            Int(sysRecvMmsg(sockfd, msgvec, vlen, flags, timeout))
        }
    }

    @inline(never)
    internal static func getpeername(socket: CInt, address: UnsafeMutablePointer<sockaddr>, addressLength: UnsafeMutablePointer<socklen_t>) throws {
        _ = try syscall(blocking: false) {
            return sysGetpeername(socket, address, addressLength)
        }
    }

    @inline(never)
    internal static func getsockname(socket: CInt, address: UnsafeMutablePointer<sockaddr>, addressLength: UnsafeMutablePointer<socklen_t>) throws {
        _ = try syscall(blocking: false) {
            return sysGetsockname(socket, address, addressLength)
        }
    }
#endif

    @inline(never)
    internal static func if_nametoindex(_ name: UnsafePointer<CChar>?) throws -> CUnsignedInt {
        return try syscall(blocking: false) {
            sysIfNameToIndex(name)
        }.result
    }

#if !os(Windows)
    @inline(never)
    internal static func poll(fds: UnsafeMutablePointer<pollfd>, nfds: nfds_t, timeout: CInt) throws -> CInt {
        return try syscall(blocking: false) {
            sysPoll(fds, nfds, timeout)
        }.result
    }

    @inline(never)
    internal static func fstat(descriptor: CInt, outStat: UnsafeMutablePointer<stat>) throws {
        _ = try syscall(blocking: false) {
            sysFstat(descriptor, outStat)
        }
    }

    @inline(never)
    internal static func stat(pathname: String, outStat: UnsafeMutablePointer<stat>) throws {
        _ = try syscall(blocking: false) {
            sysStat(pathname, outStat)
        }
    }

    @inline(never)
    internal static func unlink(pathname: String) throws {
        _ = try syscall(blocking: false) {
            sysUnlink(pathname)
        }
    }

    @inline(never)
    internal static func socketpair(domain: NIOBSDSocket.ProtocolFamily,
                                  type: NIOBSDSocket.SocketType,
                                  protocol: CInt,
                                  socketVector: UnsafeMutablePointer<CInt>?) throws {
        _ = try syscall(blocking: false) {
            sysSocketpair(domain.rawValue, type.rawValue, `protocol`, socketVector)
        }
    }
#endif
}

/// `NIOFcntlFailedError` indicates that NIO was unable to perform an
/// operation on a socket.
///
/// This error should never happen, unfortunately, we have seen this happen on Darwin.
public struct NIOFcntlFailedError: Error {}

/// `NIOFailedToSetSocketNonBlockingError` indicates that NIO was unable to set a socket to non-blocking mode, either
/// when connecting a socket as a client or when accepting a socket as a server.
///
/// This error should never happen because a socket should always be able to be set to non-blocking mode. Unfortunately,
/// we have seen this happen on Darwin.
@available(*, deprecated, renamed: "NIOFcntlFailedError")
public struct NIOFailedToSetSocketNonBlockingError: Error {}

#if !os(Windows)
internal extension Posix {
    static func setNonBlocking(socket: CInt) throws {
        let flags = try Posix.fcntl(descriptor: socket, command: F_GETFL, value: 0)
        do {
            let ret = try Posix.fcntl(descriptor: socket, command: F_SETFL, value: flags | O_NONBLOCK)
            assert(ret == 0, "unexpectedly, fcntl(\(socket), F_SETFL, \(flags) | O_NONBLOCK) returned \(ret)")
        } catch let error as IOError {
            if error.errnoCode == EINVAL {
                // Darwin seems to sometimes do this despite the docs claiming it can't happen
                throw NIOFcntlFailedError()
            }
            throw error
        }
    }
}
#endif

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
internal enum KQueue {

    // TODO: Figure out how to specify a typealias to the kevent struct without run into trouble with the swift compiler

    @inline(never)
    internal static func kqueue() throws -> CInt {
        return try syscall(blocking: false) {
            Darwin.kqueue()
        }.result
    }

    @inline(never)
    @discardableResult
    internal static func kevent(kq: CInt, changelist: UnsafePointer<kevent>?, nchanges: CInt, eventlist: UnsafeMutablePointer<kevent>?, nevents: CInt, timeout: UnsafePointer<Darwin.timespec>?) throws -> CInt {
        return try syscall(blocking: false) {
            sysKevent(kq, changelist, nchanges, eventlist, nevents, timeout)
        }.result
    }
}
#endif
