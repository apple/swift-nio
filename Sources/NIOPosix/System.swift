//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2024 Apple Inc. and the SwiftNIO project authors
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

#if canImport(Darwin)
@_exported import Darwin.C
import CNIODarwin
internal typealias MMsgHdr = CNIODarwin_mmsghdr
#elseif os(Linux) || os(FreeBSD) || os(Android)
#if canImport(Glibc)
@_exported @preconcurrency import Glibc
#elseif canImport(Musl)
@_exported @preconcurrency import Musl
#elseif canImport(Android)
@_exported @preconcurrency import Android
#endif
import CNIOLinux
internal typealias MMsgHdr = CNIOLinux_mmsghdr
internal typealias in6_pktinfo = CNIOLinux_in6_pktinfo
#elseif os(OpenBSD)
@_exported @preconcurrency import Glibc
import CNIOOpenBSD
internal typealias MMsgHdr = CNIOOpenBSD_mmsghdr
let INADDR_ANY = UInt32(0)
#elseif os(Windows)
@_exported import ucrt

import CNIOWindows

internal typealias MMsgHdr = CNIOWindows_mmsghdr
#else
#error("The POSIX system module was unable to identify your C library.")
#endif

#if os(Android)
let INADDR_ANY = UInt32(0)  // #define INADDR_ANY ((unsigned long int) 0x00000000)
let IFF_BROADCAST: CUnsignedInt = numericCast(Android.IFF_BROADCAST.rawValue)
let IFF_POINTOPOINT: CUnsignedInt = numericCast(Android.IFF_POINTOPOINT.rawValue)
let IFF_MULTICAST: CUnsignedInt = numericCast(Android.IFF_MULTICAST.rawValue)
internal typealias in_port_t = UInt16
extension ipv6_mreq {  // http://lkml.iu.edu/hypermail/linux/kernel/0106.1/0080.html
    init(ipv6mr_multiaddr: in6_addr, ipv6mr_interface: UInt32) {
        self.init(
            ipv6mr_multiaddr: ipv6mr_multiaddr,
            ipv6mr_ifindex: Int32(bitPattern: ipv6mr_interface)
        )
    }
}
#if arch(arm)
let S_IFSOCK = UInt32(Android.S_IFSOCK)
let S_IFMT = UInt32(Android.S_IFMT)
let S_IFREG = UInt32(Android.S_IFREG)
let S_IFDIR = UInt32(Android.S_IFDIR)
let S_IFLNK = UInt32(Android.S_IFLNK)
let S_IFBLK = UInt32(Android.S_IFBLK)
#endif
#endif

// Declare aliases to share more code and not need to repeat #if #else blocks
#if !os(Windows)
private let sysClose = close
private let sysShutdown = shutdown
private let sysBind = bind
private let sysFcntl: @Sendable @convention(c) (CInt, CInt, CInt) -> CInt = { fcntl($0, $1, $2) }
private let sysSocket = socket
private let sysSetsockopt = setsockopt
private let sysGetsockopt = getsockopt
private let sysListen = listen
private let sysAccept = accept
private let sysConnect = connect
private let sysOpen: @Sendable @convention(c) (UnsafePointer<CChar>, CInt) -> CInt = { open($0, $1) }
private let sysOpenWithMode: @Sendable @convention(c) (UnsafePointer<CChar>, CInt, mode_t) -> CInt = {
    open($0, $1, $2)
}
private let sysFtruncate = ftruncate
private let sysWrite = write
private let sysPwrite = pwrite
private let sysRead = read
private let sysPread = pread
private let sysLseek = lseek
private let sysPoll = poll
#else
private let sysWrite = _write
private let sysRead = _read
private let sysLseek = _lseek
private let sysFtruncate = _chsize_s
#endif

#if os(Android)
func sysRecvFrom_wrapper(
    sockfd: CInt,
    buf: UnsafeMutableRawPointer,
    len: CLong,
    flags: CInt,
    src_addr: UnsafeMutablePointer<sockaddr>,
    addrlen: UnsafeMutablePointer<socklen_t>
) -> CLong {
    // src_addr is 'UnsafeMutablePointer', but it need to be 'UnsafePointer'
    recvfrom(sockfd, buf, len, flags, src_addr, addrlen)
    // src_addr is 'UnsafeMutablePointer', but it need to be 'UnsafePointer'
}
func sysWritev_wrapper(fd: CInt, iov: UnsafePointer<iovec>?, iovcnt: CInt) -> CLong {
    CLong(writev(fd, iov!, iovcnt))  // cast 'Int32' to 'CLong'// cast 'Int32' to 'CLong'
}
private let sysWritev = sysWritev_wrapper
#elseif !os(Windows)
private let sysWritev: @convention(c) (Int32, UnsafePointer<iovec>?, CInt) -> CLong = writev
#endif
#if canImport(Android)
private let sysRecvMsg: @convention(c) (CInt, UnsafeMutablePointer<msghdr>, CInt) -> ssize_t = recvmsg
private let sysSendMsg: @convention(c) (CInt, UnsafePointer<msghdr>, CInt) -> ssize_t = sendmsg
#elseif !os(Windows)
private let sysRecvMsg: @convention(c) (CInt, UnsafeMutablePointer<msghdr>?, CInt) -> ssize_t = recvmsg
private let sysSendMsg: @convention(c) (CInt, UnsafePointer<msghdr>?, CInt) -> ssize_t = sendmsg
#endif
#if os(Windows)
private let sysDup: @convention(c) (CInt) -> CInt = _dup
#else
private let sysDup: @convention(c) (CInt) -> CInt = dup
#endif
#if canImport(Android)
private let sysGetpeername:
    @convention(c) (CInt, UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) -> CInt = getpeername
private let sysGetsockname:
    @convention(c) (CInt, UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) -> CInt = getsockname
#elseif !os(Windows)
private let sysGetpeername:
    @convention(c) (CInt, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?) -> CInt = getpeername
private let sysGetsockname:
    @convention(c) (CInt, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?) -> CInt = getsockname
#endif

#if os(Android)
private let sysIfNameToIndex: @convention(c) (UnsafePointer<CChar>) -> CUnsignedInt = if_nametoindex
#else
private let sysIfNameToIndex: @convention(c) (UnsafePointer<CChar>?) -> CUnsignedInt = if_nametoindex
#endif
#if canImport(Android)
private let sysSocketpair: @convention(c) (CInt, CInt, CInt, UnsafeMutablePointer<CInt>) -> CInt = socketpair
#elseif !os(Windows)
private let sysSocketpair: @convention(c) (CInt, CInt, CInt, UnsafeMutablePointer<CInt>?) -> CInt = socketpair
#endif

#if os(Linux) || os(Android) || canImport(Darwin) || os(OpenBSD)
private let sysFstat = fstat
private let sysStat = stat
private let sysLstat = lstat
private let sysSymlink = symlink
private let sysReadlink = readlink
private let sysUnlink = unlink
private let sysMkdir = mkdir
private let sysOpendir = opendir
private let sysReaddir = readdir
private let sysClosedir = closedir
private let sysRename = rename
private let sysRemove = remove
#endif
#if os(Linux) || os(Android)
private let sysSendMmsg = CNIOLinux_sendmmsg
private let sysRecvMmsg = CNIOLinux_recvmmsg
#elseif os(OpenBSD)
private let sysKevent = kevent
private let sysSendMmsg = CNIOOpenBSD_sendmmsg
private let sysRecvMmsg = CNIOOpenBSD_recvmmsg
#elseif canImport(Darwin)
private let sysKevent = kevent
private let sysMkpath = mkpath_np
private let sysSendMmsg = CNIODarwin_sendmmsg
private let sysRecvMmsg = CNIODarwin_recvmmsg
#endif
#if !os(Windows)
private let sysIoctl: @convention(c) (CInt, CUnsignedLong, UnsafeMutableRawPointer) -> CInt = ioctl
#endif  // !os(Windows)

@inlinable
func isUnacceptableErrno(_ code: CInt) -> Bool {
    // On iOS, EBADF is a possible result when a file descriptor has been reaped in the background.
    // In particular, it's possible to get EBADF from accept(), where the underlying accept() FD
    // is valid but the accepted one is not. The right solution here is to perform a check for
    // SO_ISDEFUNCT when we see this happen, but we haven't yet invested the time to do that.
    // In the meantime, we just tolerate EBADF on iOS.
    #if canImport(Darwin) && !os(macOS)
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

@inlinable
public func isUnacceptableErrnoOnClose(_ code: CInt) -> Bool {
    // We treat close() differently to all other FDs: we still want to catch EBADF here.
    switch code {
    case EFAULT, EBADF:
        return true
    default:
        return false
    }
}

@inlinable
internal func isUnacceptableErrnoForbiddingEINVAL(_ code: CInt) -> Bool {
    // We treat read() and pread() differently since we also want to catch EINVAL.
    #if canImport(Darwin) && !os(macOS)
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

#if os(Windows)
@inlinable
internal func strerror(_ errno: CInt) -> String {
    withUnsafeTemporaryAllocation(of: CChar.self, capacity: 95) {
        let result = strerror_s($0.baseAddress, $0.count, errno)
        guard result == 0 else { return "Unknown error: \(errno)" }
        return String(cString: $0.baseAddress!)
    }
}
#endif

@inlinable
internal func preconditionIsNotUnacceptableErrno(err: CInt, where function: String) {
    // strerror is documented to return "Unknown error: ..." for illegal value so it won't ever fail
    #if os(Windows)
    precondition(!isUnacceptableErrno(err), "unacceptable errno \(err) \(strerror(err)) in \(function))")
    #else
    precondition(
        !isUnacceptableErrno(err),
        "unacceptable errno \(err) \(String(cString: strerror(err)!)) in \(function))"
    )
    #endif
}

@inlinable
internal func preconditionIsNotUnacceptableErrnoOnClose(err: CInt, where function: String) {
    // strerror is documented to return "Unknown error: ..." for illegal value so it won't ever fail
    #if os(Windows)
    precondition(!isUnacceptableErrnoOnClose(err), "unacceptable errno \(err) \(strerror(err)) in \(function))")
    #else
    precondition(
        !isUnacceptableErrnoOnClose(err),
        "unacceptable errno \(err) \(String(cString: strerror(err)!)) in \(function))"
    )
    #endif
}

@inlinable
internal func preconditionIsNotUnacceptableErrnoForbiddingEINVAL(err: CInt, where function: String) {
    // strerror is documented to return "Unknown error: ..." for illegal value so it won't ever fail
    #if os(Windows)
    precondition(
        !isUnacceptableErrnoForbiddingEINVAL(err),
        "unacceptable errno \(err) \(strerror(err)) in \(function))"
    )
    #else
    precondition(
        !isUnacceptableErrnoForbiddingEINVAL(err),
        "unacceptable errno \(err) \(String(cString: strerror(err)!)) in \(function))"
    )
    #endif
}

// Sorry, we really try hard to not use underscored attributes. In this case
// however we seem to break the inlining threshold which makes a system call
// take twice the time, ie. we need this exception.
@inline(__always)
@discardableResult
@inlinable
internal func syscall<T: FixedWidthInteger>(
    blocking: Bool,
    where function: String = #function,
    _ body: () throws -> T
)
    throws -> IOResult<T>
{
    while true {
        let res = try body()
        if res == -1 {
            #if os(Windows)
            var err: CInt = 0
            _get_errno(&err)
            #else
            let err = errno
            #endif
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

#if canImport(Darwin)
@inline(__always)
@inlinable
@discardableResult
internal func syscall<T>(
    where function: String = #function,
    _ body: () throws -> UnsafeMutablePointer<T>?
)
    throws -> UnsafeMutablePointer<T>
{
    while true {
        if let res = try body() {
            return res
        } else {
            let err = errno
            switch err {
            case EINTR:
                continue
            default:
                preconditionIsNotUnacceptableErrno(err: err, where: function)
                throw IOError(errnoCode: err, reason: function)
            }
        }
    }
}
#elseif os(Linux) || os(Android) || os(OpenBSD)
@inline(__always)
@inlinable
@discardableResult
internal func syscall(
    where function: String = #function,
    _ body: () throws -> OpaquePointer?
)
    throws -> OpaquePointer
{
    while true {
        if let res = try body() {
            return res
        } else {
            let err = errno
            switch err {
            case EINTR:
                continue
            default:
                preconditionIsNotUnacceptableErrno(err: err, where: function)
                throw IOError(errnoCode: err, reason: function)
            }
        }
    }
}
#endif

#if !os(Windows)
@inline(__always)
@inlinable
@discardableResult
internal func syscallOptional<T>(
    where function: String = #function,
    _ body: () throws -> UnsafeMutablePointer<T>?
)
    throws -> UnsafeMutablePointer<T>?
{
    while true {
        errno = 0
        if let res = try body() {
            return res
        } else {
            let err = errno
            switch err {
            case 0:
                return nil
            case EINTR:
                continue
            default:
                preconditionIsNotUnacceptableErrno(err: err, where: function)
                throw IOError(errnoCode: err, reason: function)
            }
        }
    }
}
#endif

// Sorry, we really try hard to not use underscored attributes. In this case
// however we seem to break the inlining threshold which makes a system call
// take twice the time, ie. we need this exception.
@inline(__always)
@inlinable
@discardableResult
internal func syscallForbiddingEINVAL<T: FixedWidthInteger>(
    where function: String = #function,
    _ body: () throws -> T
)
    throws -> IOResult<T>
{
    while true {
        let res = try body()
        if res == -1 {
            #if os(Windows)
            var err: CInt = 0
            _get_errno(&err)
            #else
            let err = errno
            #endif
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

@usableFromInline
internal enum Posix: Sendable {
    #if canImport(Darwin)
    @usableFromInline
    static let UIO_MAXIOV: Int = 1024
    @usableFromInline
    static let SHUT_RD: CInt = CInt(Darwin.SHUT_RD)
    @usableFromInline
    static let SHUT_WR: CInt = CInt(Darwin.SHUT_WR)
    @usableFromInline
    static let SHUT_RDWR: CInt = CInt(Darwin.SHUT_RDWR)
    #elseif os(Linux) || os(FreeBSD) || os(Android) || os(OpenBSD)
    #if canImport(Glibc)
    @usableFromInline
    static let UIO_MAXIOV: Int = Int(Glibc.UIO_MAXIOV)
    @usableFromInline
    static let SHUT_RD: CInt = CInt(Glibc.SHUT_RD)
    @usableFromInline
    static let SHUT_WR: CInt = CInt(Glibc.SHUT_WR)
    @usableFromInline
    static let SHUT_RDWR: CInt = CInt(Glibc.SHUT_RDWR)
    #elseif canImport(Musl)
    @usableFromInline
    static let UIO_MAXIOV: Int = Int(Musl.UIO_MAXIOV)
    @usableFromInline
    static let SHUT_RD: CInt = CInt(Musl.SHUT_RD)
    @usableFromInline
    static let SHUT_WR: CInt = CInt(Musl.SHUT_WR)
    @usableFromInline
    static let SHUT_RDWR: CInt = CInt(Musl.SHUT_RDWR)
    #elseif canImport(Android)
    @usableFromInline
    static let UIO_MAXIOV: Int = Int(Android.UIO_MAXIOV)
    @usableFromInline
    static let SHUT_RD: CInt = CInt(Android.SHUT_RD)
    @usableFromInline
    static let SHUT_WR: CInt = CInt(Android.SHUT_WR)
    @usableFromInline
    static let SHUT_RDWR: CInt = CInt(Android.SHUT_RDWR)
    #endif
    #else
    @usableFromInline
    static var UIO_MAXIOV: Int {
        fatalError("unsupported OS")
    }
    @usableFromInline
    static var SHUT_RD: Int {
        fatalError("unsupported OS")
    }
    @usableFromInline
    static var SHUT_WR: Int {
        fatalError("unsupported OS")
    }
    @usableFromInline
    static var SHUT_RDWR: Int {
        fatalError("unsupported OS")
    }
    #endif

    #if canImport(Darwin)
    static let IPTOS_ECN_NOTECT: CInt = CNIODarwin_IPTOS_ECN_NOTECT
    static let IPTOS_ECN_MASK: CInt = CNIODarwin_IPTOS_ECN_MASK
    static let IPTOS_ECN_ECT0: CInt = CNIODarwin_IPTOS_ECN_ECT0
    static let IPTOS_ECN_ECT1: CInt = CNIODarwin_IPTOS_ECN_ECT1
    static let IPTOS_ECN_CE: CInt = CNIODarwin_IPTOS_ECN_CE
    #elseif os(Linux) || os(FreeBSD) || os(Android)
    #if os(Android)
    static let IPTOS_ECN_NOTECT: CInt = CInt(CNIOLinux.IPTOS_ECN_NOTECT)
    #else
    static let IPTOS_ECN_NOTECT: CInt = CInt(CNIOLinux.IPTOS_ECN_NOT_ECT)
    #endif
    static let IPTOS_ECN_MASK: CInt = CInt(CNIOLinux.IPTOS_ECN_MASK)
    static let IPTOS_ECN_ECT0: CInt = CInt(CNIOLinux.IPTOS_ECN_ECT0)
    static let IPTOS_ECN_ECT1: CInt = CInt(CNIOLinux.IPTOS_ECN_ECT1)
    static let IPTOS_ECN_CE: CInt = CInt(CNIOLinux.IPTOS_ECN_CE)
    #elseif os(OpenBSD)
    static let IPTOS_ECN_NOTECT: CInt = CInt(CNIOOpenBSD.IPTOS_ECN_NOTECT)
    static let IPTOS_ECN_MASK: CInt = CInt(CNIOOpenBSD.IPTOS_ECN_MASK)
    static let IPTOS_ECN_ECT0: CInt = CInt(CNIOOpenBSD.IPTOS_ECN_ECT0)
    static let IPTOS_ECN_ECT1: CInt = CInt(CNIOOpenBSD.IPTOS_ECN_ECT1)
    static let IPTOS_ECN_CE: CInt = CInt(CNIOOpenBSD.IPTOS_ECN_CE)
    #elseif os(Windows)
    static let IPTOS_ECN_NOTECT: CInt = CInt(0x00)
    static let IPTOS_ECN_MASK: CInt = CInt(0x03)
    static let IPTOS_ECN_ECT0: CInt = CInt(0x02)
    static let IPTOS_ECN_ECT1: CInt = CInt(0x01)
    static let IPTOS_ECN_CE: CInt = CInt(0x03)
    #endif

    #if canImport(Darwin)
    static let IP_RECVPKTINFO: CInt = CNIODarwin.IP_RECVPKTINFO
    static let IP_PKTINFO: CInt = CNIODarwin.IP_PKTINFO

    static let IPV6_RECVPKTINFO: CInt = CNIODarwin_IPV6_RECVPKTINFO
    static let IPV6_PKTINFO: CInt = CNIODarwin_IPV6_PKTINFO
    #elseif os(Linux) || os(FreeBSD) || os(Android)
    static let IP_RECVPKTINFO: CInt = CInt(CNIOLinux.IP_PKTINFO)
    static let IP_PKTINFO: CInt = CInt(CNIOLinux.IP_PKTINFO)

    static let IPV6_RECVPKTINFO: CInt = CInt(CNIOLinux.IPV6_RECVPKTINFO)
    static let IPV6_PKTINFO: CInt = CInt(CNIOLinux.IPV6_PKTINFO)
    #elseif os(OpenBSD)
    static let IP_PKTINFO: CInt = CInt(-1)  // Not actually present.

    static let IPV6_RECVPKTINFO: CInt = CInt(CNIOOpenBSD.IPV6_RECVPKTINFO)
    static let IPV6_PKTINFO: CInt = CInt(CNIOOpenBSD.IPV6_PKTINFO)
    #elseif os(Windows)
    static let IP_RECVPKTINFO: CInt = CInt(WinSDK.IP_PKTINFO)
    static let IP_PKTINFO: CInt = CInt(WinSDK.IP_PKTINFO)

    static let IPV6_RECVPKTINFO: CInt = CInt(WinSDK.IPV6_PKTINFO)
    static let IPV6_PKTINFO: CInt = CInt(WinSDK.IPV6_PKTINFO)
    #endif

    #if canImport(Darwin)
    static let SOL_UDP: CInt = CInt(IPPROTO_UDP)
    #elseif os(Linux) || os(FreeBSD) || os(Android) || os(OpenBSD)
    static let SOL_UDP: CInt = CInt(IPPROTO_UDP)
    #elseif os(Windows)
    static let SOL_UDP: CInt = CInt(IPPROTO_UDP)
    #endif

    #if !os(Windows)
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
            #if os(Windows)
            var err: CInt = 0
            _get_errno(&err)
            #else
            let err = errno
            #endif

            // There is really nothing "good" we can do when EINTR was reported on close.
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
    public static func bind(descriptor: CInt, ptr: UnsafePointer<sockaddr>, bytes: Int) throws {
        _ = try syscall(blocking: false) {
            sysBind(descriptor, ptr, socklen_t(bytes))
        }
    }

    @inline(never)
    @discardableResult
    @usableFromInline
    // TODO: Allow varargs
    internal static func fcntl(descriptor: CInt, command: CInt, value: CInt) throws -> CInt {
        try syscall(blocking: false) {
            sysFcntl(descriptor, command, value)
        }.result
    }

    @inline(never)
    public static func socket(
        domain: NIOBSDSocket.ProtocolFamily,
        type: NIOBSDSocket.SocketType,
        protocolSubtype: NIOBSDSocket.ProtocolSubtype
    ) throws -> CInt {
        try syscall(blocking: false) {
            sysSocket(domain.rawValue, type.rawValue, protocolSubtype.rawValue)
        }.result
    }

    @inline(never)
    public static func setsockopt(
        socket: CInt,
        level: CInt,
        optionName: CInt,
        optionValue: UnsafeRawPointer,
        optionLen: socklen_t
    ) throws {
        _ = try syscall(blocking: false) {
            sysSetsockopt(socket, level, optionName, optionValue, optionLen)
        }
    }

    @inline(never)
    public static func getsockopt(
        socket: CInt,
        level: CInt,
        optionName: CInt,
        optionValue: UnsafeMutableRawPointer,
        optionLen: UnsafeMutablePointer<socklen_t>
    ) throws {
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
    public static func accept(
        descriptor: CInt,
        addr: UnsafeMutablePointer<sockaddr>?,
        len: UnsafeMutablePointer<socklen_t>?
    ) throws -> CInt? {
        let result: IOResult<CInt> = try syscall(blocking: true) {
            sysAccept(descriptor, addr, len)
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
        try syscall(blocking: false) {
            sysOpenWithMode(file, oFlag, mode)
        }.result
    }

    @inline(never)
    public static func open(file: UnsafePointer<CChar>, oFlag: CInt) throws -> CInt {
        try syscall(blocking: false) {
            sysOpen(file, oFlag)
        }.result
    }

    @inline(never)
    public static func pwrite(
        descriptor: CInt,
        pointer: UnsafeRawPointer,
        size: Int,
        offset: off_t
    ) throws -> IOResult<Int> {
        try syscall(blocking: true) {
            sysPwrite(descriptor, pointer, size, offset)
        }
    }

    @inline(never)
    public static func writev(descriptor: CInt, iovecs: UnsafeBufferPointer<IOVector>) throws -> IOResult<Int> {
        try syscall(blocking: true) {
            sysWritev(descriptor, iovecs.baseAddress!, CInt(iovecs.count))
        }
    }

    @inline(never)
    public static func pread(
        descriptor: CInt,
        pointer: UnsafeMutableRawPointer,
        size: size_t,
        offset: off_t
    ) throws -> IOResult<ssize_t> {
        try syscallForbiddingEINVAL {
            sysPread(descriptor, pointer, size, offset)
        }
    }

    @inline(never)
    public static func recvmsg(
        descriptor: CInt,
        msgHdr: UnsafeMutablePointer<msghdr>,
        flags: CInt
    ) throws -> IOResult<ssize_t> {
        try syscall(blocking: true) {
            sysRecvMsg(descriptor, msgHdr, flags)
        }
    }

    @inline(never)
    public static func sendmsg(
        descriptor: CInt,
        msgHdr: UnsafePointer<msghdr>,
        flags: CInt
    ) throws -> IOResult<ssize_t> {
        try syscall(blocking: true) {
            sysSendMsg(descriptor, msgHdr, flags)
        }
    }
    #endif

    @inline(never)
    public static func read(
        descriptor: CInt,
        pointer: UnsafeMutableRawPointer,
        size: size_t
    ) throws -> IOResult<ssize_t> {
        try syscallForbiddingEINVAL {
            #if os(Windows)
            // Windows read, reads at most UInt32. Lets clamp size there.
            let size = UInt32(clamping: size)
            return ssize_t(sysRead(descriptor, pointer, size))
            #else
            sysRead(descriptor, pointer, size)
            #endif
        }
    }

    @inline(never)
    public static func write(descriptor: CInt, pointer: UnsafeRawPointer, size: Int) throws -> IOResult<Int> {
        try syscall(blocking: true) {
            #if os(Windows)
            let size = UInt32(clamping: size)
            #endif
            return numericCast(sysWrite(descriptor, pointer, size))
        }
    }

    @discardableResult
    @inline(never)
    public static func ftruncate(descriptor: CInt, size: off_t) throws -> CInt {
        try syscall(blocking: false) {
            sysFtruncate(descriptor, numericCast(size))
        }.result
    }

    @discardableResult
    @inline(never)
    public static func lseek(descriptor: CInt, offset: off_t, whence: CInt) throws -> off_t {
        try syscall(blocking: false) {
            sysLseek(descriptor, offset, whence)
        }.result
    }

    @discardableResult
    @inline(never)
    public static func dup(descriptor: CInt) throws -> CInt {
        try syscall(blocking: false) {
            sysDup(descriptor)
        }.result
    }

    #if !os(Windows)
    // It's not really posix but exists on Linux and MacOS / BSD so just put it here for now to keep it simple
    @inline(never)
    public static func sendfile(descriptor: CInt, fd: CInt, offset: off_t, count: size_t) throws -> IOResult<Int> {
        var written: off_t = 0
        do {
            _ = try syscall(blocking: false) { () -> ssize_t in
                #if canImport(Darwin)
                var w: off_t = off_t(count)
                let result: CInt = Darwin.sendfile(fd, descriptor, offset, &w, nil, 0)
                written = w
                return ssize_t(result)
                #elseif os(Linux) || os(FreeBSD) || os(Android)
                var off: off_t = offset
                #if canImport(Glibc)
                let result: ssize_t = Glibc.sendfile(descriptor, fd, &off, count)
                #elseif canImport(Musl)
                let result: ssize_t = Musl.sendfile(descriptor, fd, &off, count)
                #elseif canImport(Android)
                let result: ssize_t = Android.sendfile(descriptor, fd, &off, count)
                #endif
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
    public static func sendmmsg(
        sockfd: CInt,
        msgvec: UnsafeMutablePointer<MMsgHdr>,
        vlen: CUnsignedInt,
        flags: CInt
    ) throws -> IOResult<Int> {
        try syscall(blocking: true) {
            Int(sysSendMmsg(sockfd, msgvec, vlen, flags))
        }
    }

    @inline(never)
    public static func recvmmsg(
        sockfd: CInt,
        msgvec: UnsafeMutablePointer<MMsgHdr>,
        vlen: CUnsignedInt,
        flags: CInt,
        timeout: UnsafeMutablePointer<timespec>?
    ) throws -> IOResult<Int> {
        try syscall(blocking: true) {
            Int(sysRecvMmsg(sockfd, msgvec, vlen, flags, timeout))
        }
    }

    @inline(never)
    public static func getpeername(
        socket: CInt,
        address: UnsafeMutablePointer<sockaddr>,
        addressLength: UnsafeMutablePointer<socklen_t>
    ) throws {
        _ = try syscall(blocking: false) {
            sysGetpeername(socket, address, addressLength)
        }
    }

    @inline(never)
    public static func getsockname(
        socket: CInt,
        address: UnsafeMutablePointer<sockaddr>,
        addressLength: UnsafeMutablePointer<socklen_t>
    ) throws {
        _ = try syscall(blocking: false) {
            sysGetsockname(socket, address, addressLength)
        }
    }
    #endif

    @inline(never)
    public static func if_nametoindex(_ name: UnsafePointer<CChar>?) throws -> CUnsignedInt {
        try syscall(blocking: false) {
            sysIfNameToIndex(name!)
        }.result
    }

    #if !os(Windows)
    @inline(never)
    public static func poll(fds: UnsafeMutablePointer<pollfd>, nfds: nfds_t, timeout: CInt) throws -> CInt {
        try syscall(blocking: false) {
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
    public static func stat(pathname: String, outStat: UnsafeMutablePointer<stat>) throws {
        _ = try syscall(blocking: false) {
            sysStat(pathname, outStat)
        }
    }

    @inline(never)
    public static func lstat(pathname: String, outStat: UnsafeMutablePointer<stat>) throws {
        _ = try syscall(blocking: false) {
            sysLstat(pathname, outStat)
        }
    }

    @inline(never)
    public static func symlink(pathname: String, destination: String) throws {
        _ = try syscall(blocking: false) {
            sysSymlink(destination, pathname)
        }
    }

    @inline(never)
    public static func readlink(
        pathname: String,
        outPath: UnsafeMutablePointer<CChar>,
        outPathSize: Int
    ) throws -> CLong {
        try syscall(blocking: false) {
            sysReadlink(pathname, outPath, outPathSize)
        }.result
    }

    @inline(never)
    public static func unlink(pathname: String) throws {
        _ = try syscall(blocking: false) {
            sysUnlink(pathname)
        }
    }

    @inline(never)
    public static func mkdir(pathname: String, mode: mode_t) throws {
        _ = try syscall(blocking: false) {
            sysMkdir(pathname, mode)
        }
    }

    #if canImport(Darwin)
    @inline(never)
    public static func mkpath_np(pathname: String, mode: mode_t) throws {
        _ = try syscall(blocking: false) {
            sysMkpath(pathname, mode)
        }
    }

    @inline(never)
    public static func opendir(pathname: String) throws -> UnsafeMutablePointer<DIR> {
        try syscall {
            sysOpendir(pathname)
        }
    }

    @inline(never)
    public static func readdir(dir: UnsafeMutablePointer<DIR>) throws -> UnsafeMutablePointer<dirent>? {
        try syscallOptional {
            sysReaddir(dir)
        }
    }

    @inline(never)
    public static func closedir(dir: UnsafeMutablePointer<DIR>) throws {
        _ = try syscall(blocking: true) {
            sysClosedir(dir)
        }
    }
    #elseif os(Linux) || os(FreeBSD) || os(Android) || os(OpenBSD)
    @inline(never)
    public static func opendir(pathname: String) throws -> OpaquePointer {
        try syscall {
            sysOpendir(pathname)
        }
    }

    @inline(never)
    public static func readdir(dir: OpaquePointer) throws -> UnsafeMutablePointer<dirent>? {
        try syscallOptional {
            sysReaddir(dir)
        }
    }

    @inline(never)
    public static func closedir(dir: OpaquePointer) throws {
        _ = try syscall(blocking: true) {
            sysClosedir(dir)
        }
    }
    #endif

    @inline(never)
    public static func rename(pathname: String, newName: String) throws {
        _ = try syscall(blocking: true) {
            sysRename(pathname, newName)
        }
    }

    @inline(never)
    public static func remove(pathname: String) throws {
        _ = try syscall(blocking: true) {
            sysRemove(pathname)
        }
    }

    @inline(never)
    public static func socketpair(
        domain: NIOBSDSocket.ProtocolFamily,
        type: NIOBSDSocket.SocketType,
        protocolSubtype: NIOBSDSocket.ProtocolSubtype,
        socketVector: UnsafeMutablePointer<CInt>?
    ) throws {
        _ = try syscall(blocking: false) {
            sysSocketpair(domain.rawValue, type.rawValue, protocolSubtype.rawValue, socketVector!)
        }
    }
    #endif
    #if !os(Windows)
    @inline(never)
    public static func ioctl(fd: CInt, request: CUnsignedLong, ptr: UnsafeMutableRawPointer) throws {
        _ = try syscall(blocking: false) {
            /// `numericCast` to support musl which accepts `CInt` (cf. `CUnsignedLong`).
            sysIoctl(fd, numericCast(request), ptr)
        }
    }
    #endif  // !os(Windows)
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
extension Posix {
    public static func setNonBlocking(socket: CInt) throws {
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

#if canImport(Darwin) || os(OpenBSD)
#if canImport(Darwin)
internal typealias kevent_timespec = Darwin.timespec
#elseif os(OpenBSD)
internal typealias kevent_timespec = CNIOOpenBSD.timespec
#else
#error("implementation missing")
#endif

@usableFromInline
internal enum KQueue: Sendable {

    // TODO: Figure out how to specify a typealias to the kevent struct without run into trouble with the swift compiler

    @inline(never)
    public static func kqueue() throws -> CInt {
        try syscall(blocking: false) {
            #if canImport(Darwin)
            Darwin.kqueue()
            #elseif os(OpenBSD)
            CNIOOpenBSD.kqueue()
            #else
            #error("implementation missing")
            #endif
        }.result
    }

    @inline(never)
    @discardableResult
    public static func kevent(
        kq: CInt,
        changelist: UnsafePointer<kevent>?,
        nchanges: CInt,
        eventlist: UnsafeMutablePointer<kevent>?,
        nevents: CInt,
        timeout: UnsafePointer<kevent_timespec>?
    ) throws -> CInt {
        try syscall(blocking: false) {
            sysKevent(kq, changelist, nchanges, eventlist, nevents, timeout)
        }.result
    }
}
#endif
