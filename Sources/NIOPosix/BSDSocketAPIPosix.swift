//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore

#if os(Linux) || os(Android) || os(FreeBSD) || canImport(Darwin) || os(OpenBSD)

extension Shutdown {
    internal var cValue: CInt {
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

// MARK: Implementation of _BSDSocketProtocol for POSIX systems
extension NIOBSDSocket {
    static func accept(
        socket s: NIOBSDSocket.Handle,
        address addr: UnsafeMutablePointer<sockaddr>?,
        address_len addrlen: UnsafeMutablePointer<socklen_t>?
    ) throws -> NIOBSDSocket.Handle? {
        try Posix.accept(descriptor: s, addr: addr, len: addrlen)
    }

    static func bind(
        socket s: NIOBSDSocket.Handle,
        address addr: UnsafePointer<sockaddr>,
        address_len namelen: socklen_t
    ) throws {
        try Posix.bind(descriptor: s, ptr: addr, bytes: Int(namelen))
    }

    static func close(socket s: NIOBSDSocket.Handle) throws {
        try Posix.close(descriptor: s)
    }

    static func connect(
        socket s: NIOBSDSocket.Handle,
        address name: UnsafePointer<sockaddr>,
        address_len namelen: socklen_t
    ) throws -> Bool {
        try Posix.connect(descriptor: s, addr: name, size: namelen)
    }

    static func getpeername(
        socket s: NIOBSDSocket.Handle,
        address name: UnsafeMutablePointer<sockaddr>,
        address_len namelen: UnsafeMutablePointer<socklen_t>
    ) throws {
        try Posix.getpeername(socket: s, address: name, addressLength: namelen)
    }

    static func getsockname(
        socket s: NIOBSDSocket.Handle,
        address name: UnsafeMutablePointer<sockaddr>,
        address_len namelen: UnsafeMutablePointer<socklen_t>
    ) throws {
        try Posix.getsockname(socket: s, address: name, addressLength: namelen)
    }

    static func getsockopt(
        socket: NIOBSDSocket.Handle,
        level: NIOBSDSocket.OptionLevel,
        option_name optname: NIOBSDSocket.Option,
        option_value optval: UnsafeMutableRawPointer,
        option_len optlen: UnsafeMutablePointer<socklen_t>
    ) throws {
        try Posix.getsockopt(
            socket: socket,
            level: level.rawValue,
            optionName: optname.rawValue,
            optionValue: optval,
            optionLen: optlen
        )
    }

    static func listen(socket s: NIOBSDSocket.Handle, backlog: CInt) throws {
        try Posix.listen(descriptor: s, backlog: backlog)
    }

    static func recv(
        socket s: NIOBSDSocket.Handle,
        buffer buf: UnsafeMutableRawPointer,
        length len: size_t
    ) throws -> IOResult<size_t> {
        try Posix.read(descriptor: s, pointer: buf, size: len)
    }

    static func recvmsg(
        socket: NIOBSDSocket.Handle,
        msgHdr: UnsafeMutablePointer<msghdr>,
        flags: CInt
    )
        throws -> IOResult<size_t>
    {
        try Posix.recvmsg(descriptor: socket, msgHdr: msgHdr, flags: flags)
    }

    static func sendmsg(
        socket: NIOBSDSocket.Handle,
        msgHdr: UnsafePointer<msghdr>,
        flags: CInt
    )
        throws -> IOResult<size_t>
    {
        try Posix.sendmsg(descriptor: socket, msgHdr: msgHdr, flags: flags)
    }

    static func send(
        socket s: NIOBSDSocket.Handle,
        buffer buf: UnsafeRawPointer,
        length len: size_t
    ) throws -> IOResult<size_t> {
        try Posix.write(descriptor: s, pointer: buf, size: len)
    }

    static func writev(
        socket s: NIOBSDSocket.Handle,
        iovecs: UnsafeBufferPointer<IOVector>
    ) throws -> IOResult<Int> {
        try Posix.writev(descriptor: s, iovecs: iovecs)
    }

    static func setsockopt(
        socket: NIOBSDSocket.Handle,
        level: NIOBSDSocket.OptionLevel,
        option_name optname: NIOBSDSocket.Option,
        option_value optval: UnsafeRawPointer,
        option_len optlen: socklen_t
    ) throws {
        try Posix.setsockopt(
            socket: socket,
            level: level.rawValue,
            optionName: optname.rawValue,
            optionValue: optval,
            optionLen: optlen
        )
    }

    static func shutdown(socket: NIOBSDSocket.Handle, how: Shutdown) throws {
        try Posix.shutdown(descriptor: socket, how: how)
    }

    static func socket(
        domain af: NIOBSDSocket.ProtocolFamily,
        type: NIOBSDSocket.SocketType,
        protocolSubtype: NIOBSDSocket.ProtocolSubtype
    ) throws -> NIOBSDSocket.Handle {
        try Posix.socket(domain: af, type: type, protocolSubtype: protocolSubtype)
    }

    static func recvmmsg(
        socket: NIOBSDSocket.Handle,
        msgvec: UnsafeMutablePointer<MMsgHdr>,
        vlen: CUnsignedInt,
        flags: CInt,
        timeout: UnsafeMutablePointer<timespec>?
    ) throws -> IOResult<Int> {
        try Posix.recvmmsg(
            sockfd: socket,
            msgvec: msgvec,
            vlen: vlen,
            flags: flags,
            timeout: timeout
        )
    }

    static func sendmmsg(
        socket: NIOBSDSocket.Handle,
        msgvec: UnsafeMutablePointer<MMsgHdr>,
        vlen: CUnsignedInt,
        flags: CInt
    ) throws -> IOResult<Int> {
        try Posix.sendmmsg(
            sockfd: socket,
            msgvec: msgvec,
            vlen: vlen,
            flags: flags
        )
    }

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    static func pread(
        socket: NIOBSDSocket.Handle,
        pointer: UnsafeMutableRawPointer,
        size: size_t,
        offset: off_t
    ) throws -> IOResult<size_t> {
        try Posix.pread(
            descriptor: socket,
            pointer: pointer,
            size: size,
            offset: offset
        )
    }

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    static func pwrite(
        socket: NIOBSDSocket.Handle,
        pointer: UnsafeRawPointer,
        size: size_t,
        offset: off_t
    ) throws -> IOResult<size_t> {
        try Posix.pwrite(descriptor: socket, pointer: pointer, size: size, offset: offset)
    }

    static func poll(
        fds: UnsafeMutablePointer<pollfd>,
        nfds: nfds_t,
        timeout: CInt
    ) throws -> CInt {
        try Posix.poll(fds: fds, nfds: nfds, timeout: timeout)
    }

    static func sendfile(
        socket s: NIOBSDSocket.Handle,
        fd: CInt,
        offset: off_t,
        len: off_t
    ) throws -> IOResult<Int> {
        try Posix.sendfile(descriptor: s, fd: fd, offset: offset, count: size_t(len))
    }

    static func setNonBlocking(socket: NIOBSDSocket.Handle) throws {
        try Posix.setNonBlocking(socket: socket)
    }

    static func cleanupUnixDomainSocket(atPath path: String) throws {
        do {
            var sb: stat = stat()
            try withUnsafeMutablePointer(to: &sb) { sbPtr in
                try Posix.stat(pathname: path, outStat: sbPtr)
            }

            // Only unlink the existing file if it is a socket
            if sb.st_mode & S_IFSOCK == S_IFSOCK {
                try Posix.unlink(pathname: path)
            } else {
                throw UnixDomainSocketPathWrongType()
            }
        } catch let err as IOError {
            // If the filepath did not exist, we consider it cleaned up
            if err.errnoCode == ENOENT {
                return
            }
            throw err
        }
    }
}

#if canImport(Darwin)
import CNIODarwin
private let CMSG_FIRSTHDR = CNIODarwin_CMSG_FIRSTHDR
private let CMSG_NXTHDR = CNIODarwin_CMSG_NXTHDR
private let CMSG_DATA = CNIODarwin_CMSG_DATA
private let CMSG_DATA_MUTABLE = CNIODarwin_CMSG_DATA_MUTABLE
private let CMSG_SPACE = CNIODarwin_CMSG_SPACE
private let CMSG_LEN = CNIODarwin_CMSG_LEN
#elseif os(OpenBSD)
import CNIOOpenBSD
private let CMSG_FIRSTHDR = CNIOOpenBSD_CMSG_FIRSTHDR
private let CMSG_NXTHDR = CNIOOpenBSD_CMSG_NXTHDR
private let CMSG_DATA = CNIOOpenBSD_CMSG_DATA
private let CMSG_DATA_MUTABLE = CNIOOpenBSD_CMSG_DATA_MUTABLE
private let CMSG_SPACE = CNIOOpenBSD_CMSG_SPACE
private let CMSG_LEN = CNIOOpenBSD_CMSG_LEN
#else
import CNIOLinux
private let CMSG_FIRSTHDR = CNIOLinux_CMSG_FIRSTHDR
private let CMSG_NXTHDR = CNIOLinux_CMSG_NXTHDR
private let CMSG_DATA = CNIOLinux_CMSG_DATA
private let CMSG_DATA_MUTABLE = CNIOLinux_CMSG_DATA_MUTABLE
private let CMSG_SPACE = CNIOLinux_CMSG_SPACE
private let CMSG_LEN = CNIOLinux_CMSG_LEN
#endif

// MARK: _BSDSocketControlMessageProtocol implementation
extension NIOBSDSocketControlMessage {
    static func firstHeader(
        inside msghdr: UnsafePointer<msghdr>
    )
        -> UnsafeMutablePointer<cmsghdr>?
    {
        CMSG_FIRSTHDR(msghdr)
    }

    static func nextHeader(
        inside msghdr: UnsafeMutablePointer<msghdr>,
        after: UnsafeMutablePointer<cmsghdr>
    )
        -> UnsafeMutablePointer<cmsghdr>?
    {
        CMSG_NXTHDR(msghdr, after)
    }

    static func data(
        for header: UnsafePointer<cmsghdr>
    )
        -> UnsafeRawBufferPointer?
    {
        let data = CMSG_DATA(header)
        let length =
            size_t(header.pointee.cmsg_len) - NIOBSDSocketControlMessage.length(payloadSize: 0)
        return UnsafeRawBufferPointer(start: data, count: Int(length))
    }

    static func data(
        for header: UnsafeMutablePointer<cmsghdr>
    )
        -> UnsafeMutableRawBufferPointer?
    {
        let data = CMSG_DATA_MUTABLE(header)
        let length =
            size_t(header.pointee.cmsg_len) - NIOBSDSocketControlMessage.length(payloadSize: 0)
        return UnsafeMutableRawBufferPointer(start: data, count: Int(length))
    }

    static func length(payloadSize: size_t) -> size_t {
        CMSG_LEN(payloadSize)
    }

    static func space(payloadSize: size_t) -> size_t {
        CMSG_SPACE(payloadSize)
    }
}

extension NIOBSDSocket {
    static func setUDPSegmentSize(_ segmentSize: CInt, socket: NIOBSDSocket.Handle) throws {
        #if os(Linux)
        var segmentSize = segmentSize
        try Self.setsockopt(
            socket: socket,
            level: .udp,
            option_name: .udp_segment,
            option_value: &segmentSize,
            option_len: socklen_t(MemoryLayout<CInt>.size)
        )
        #else
        throw ChannelError._operationUnsupported
        #endif
    }

    static func getUDPSegmentSize(socket: NIOBSDSocket.Handle) throws -> CInt {
        #if os(Linux)
        var segmentSize: CInt = 0
        var optionLength = socklen_t(MemoryLayout<CInt>.size)
        try withUnsafeMutablePointer(to: &segmentSize) { segmentSizeBytes in
            try Self.getsockopt(
                socket: socket,
                level: .udp,
                option_name: .udp_segment,
                option_value: segmentSizeBytes,
                option_len: &optionLength
            )
        }
        return segmentSize
        #else
        throw ChannelError._operationUnsupported
        #endif
    }

    static func setUDPReceiveOffload(_ enabled: Bool, socket: NIOBSDSocket.Handle) throws {
        #if os(Linux)
        var isEnabled: CInt = enabled ? 1 : 0
        try Self.setsockopt(
            socket: socket,
            level: .udp,
            option_name: .udp_gro,
            option_value: &isEnabled,
            option_len: socklen_t(MemoryLayout<CInt>.size)
        )
        #else
        throw ChannelError._operationUnsupported
        #endif
    }

    static func getUDPReceiveOffload(socket: NIOBSDSocket.Handle) throws -> Bool {
        #if os(Linux)
        var enabled: CInt = 0
        var optionLength = socklen_t(MemoryLayout<CInt>.size)
        try withUnsafeMutablePointer(to: &enabled) { enabledBytes in
            try Self.getsockopt(
                socket: socket,
                level: .udp,
                option_name: .udp_gro,
                option_value: enabledBytes,
                option_len: &optionLength
            )
        }
        return enabled != 0
        #else
        throw ChannelError._operationUnsupported
        #endif
    }
}

extension msghdr {
    var control_ptr: UnsafeMutableRawBufferPointer {
        set {
            self.msg_control = newValue.baseAddress
            self.msg_controllen = numericCast(newValue.count)
        }
        get {
            UnsafeMutableRawBufferPointer(start: self.msg_control, count: Int(self.msg_controllen))
        }
    }
}
#endif
