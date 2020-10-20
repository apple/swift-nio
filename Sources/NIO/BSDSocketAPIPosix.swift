//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
#if os(Linux) || os(Android) || os(FreeBSD) || os(iOS) || os(macOS) || os(tvOS) || os(watchOS)

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
    static func accept(socket s: NIOBSDSocket.Handle,
                       address addr: UnsafeMutablePointer<sockaddr>?,
                       address_len addrlen: UnsafeMutablePointer<socklen_t>?) throws -> NIOBSDSocket.Handle? {
        return try Posix.accept(descriptor: s, addr: addr, len: addrlen)
    }

    static func bind(socket s: NIOBSDSocket.Handle,
                     address addr: UnsafePointer<sockaddr>,
                     address_len namelen: socklen_t) throws {
        return try Posix.bind(descriptor: s, ptr: addr, bytes: Int(namelen))
    }

    static func close(socket s: NIOBSDSocket.Handle) throws {
        return try Posix.close(descriptor: s)
    }

    static func connect(socket s: NIOBSDSocket.Handle,
                        address name: UnsafePointer<sockaddr>,
                        address_len namelen: socklen_t) throws -> Bool {
        return try Posix.connect(descriptor: s, addr: name, size: namelen)
    }

    static func getpeername(socket s: NIOBSDSocket.Handle,
                            address name: UnsafeMutablePointer<sockaddr>,
                            address_len namelen: UnsafeMutablePointer<socklen_t>) throws {
        return try Posix.getpeername(socket: s, address: name, addressLength: namelen)
    }

    static func getsockname(socket s: NIOBSDSocket.Handle,
                            address name: UnsafeMutablePointer<sockaddr>,
                            address_len namelen: UnsafeMutablePointer<socklen_t>) throws {
        return try Posix.getsockname(socket: s, address: name, addressLength: namelen)
    }

    static func getsockopt(socket: NIOBSDSocket.Handle,
                           level: NIOBSDSocket.OptionLevel,
                           option_name optname: NIOBSDSocket.Option,
                           option_value optval: UnsafeMutableRawPointer,
                           option_len optlen: UnsafeMutablePointer<socklen_t>) throws {
        return try Posix.getsockopt(socket: socket,
                                    level: level.rawValue,
                                    optionName: optname.rawValue,
                                    optionValue: optval,
                                    optionLen: optlen)
    }

    static func listen(socket s: NIOBSDSocket.Handle, backlog: CInt) throws {
        return try Posix.listen(descriptor: s, backlog: backlog)
    }

    static func recv(socket s: NIOBSDSocket.Handle,
                     buffer buf: UnsafeMutableRawPointer,
                     length len: size_t) throws -> IOResult<size_t> {
        return try Posix.read(descriptor: s, pointer: buf, size: len)
    }

    static func recvmsg(socket: NIOBSDSocket.Handle,
                        msgHdr: UnsafeMutablePointer<msghdr>, flags: CInt)
            throws -> IOResult<size_t> {
        return try Posix.recvmsg(descriptor: socket, msgHdr: msgHdr, flags: flags)
    }

    static func sendmsg(socket: NIOBSDSocket.Handle,
                        msgHdr: UnsafePointer<msghdr>, flags: CInt)
            throws -> IOResult<size_t> {
        return try Posix.sendmsg(descriptor: socket, msgHdr: msgHdr, flags: flags)
    }

    static func send(socket s: NIOBSDSocket.Handle,
                     buffer buf: UnsafeRawPointer,
                     length len: size_t) throws -> IOResult<size_t> {
        return try Posix.write(descriptor: s, pointer: buf, size: len)
    }

    static func setsockopt(socket: NIOBSDSocket.Handle,
                           level: NIOBSDSocket.OptionLevel,
                           option_name optname: NIOBSDSocket.Option,
                           option_value optval: UnsafeRawPointer,
                           option_len optlen: socklen_t) throws {
        return try Posix.setsockopt(socket: socket,
                                    level: level.rawValue,
                                    optionName: optname.rawValue,
                                    optionValue: optval,
                                    optionLen: optlen)
    }

    static func shutdown(socket: NIOBSDSocket.Handle, how: Shutdown) throws {
        return try Posix.shutdown(descriptor: socket, how: how)
    }

    static func socket(domain af: NIOBSDSocket.ProtocolFamily,
                       type: NIOBSDSocket.SocketType,
                       `protocol`: CInt) throws -> NIOBSDSocket.Handle {
        return try Posix.socket(domain: af, type: type, protocol: `protocol`)
    }

    static func recvmmsg(socket: NIOBSDSocket.Handle,
                         msgvec: UnsafeMutablePointer<MMsgHdr>,
                         vlen: CUnsignedInt,
                         flags: CInt,
                         timeout: UnsafeMutablePointer<timespec>?) throws -> IOResult<Int> {
        return try Posix.recvmmsg(sockfd: socket,
                                  msgvec: msgvec,
                                  vlen: vlen,
                                  flags: flags,
                                  timeout: timeout)
    }

    static func sendmmsg(socket: NIOBSDSocket.Handle,
                         msgvec: UnsafeMutablePointer<MMsgHdr>,
                         vlen: CUnsignedInt,
                         flags: CInt) throws -> IOResult<Int> {
        return try Posix.sendmmsg(sockfd: socket,
                                  msgvec: msgvec,
                                  vlen: vlen,
                                  flags: flags)
    }

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    static func pread(socket: NIOBSDSocket.Handle,
                      pointer: UnsafeMutableRawPointer,
                      size: size_t,
                      offset: off_t) throws -> IOResult<size_t> {
        return try Posix.pread(descriptor: socket,
                               pointer: pointer,
                               size: size,
                               offset: offset)
    }

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    static func pwrite(socket: NIOBSDSocket.Handle,
                       pointer: UnsafeRawPointer,
                       size: size_t,
                       offset: off_t) throws -> IOResult<size_t> {
        return try Posix.pwrite(descriptor: socket, pointer: pointer, size: size, offset: offset)
    }

    static func poll(fds: UnsafeMutablePointer<pollfd>,
                     nfds: nfds_t,
                     timeout: CInt) throws -> CInt {
        return try Posix.poll(fds: fds, nfds: nfds, timeout: timeout)
    }

    @discardableResult
    static func inet_ntop(af family: NIOBSDSocket.AddressFamily,
                          src addr: UnsafeRawPointer,
                          dst dstBuf: UnsafeMutablePointer<CChar>,
                          size dstSize: socklen_t) throws -> UnsafePointer<CChar>? {
        return try Posix.inet_ntop(addressFamily: sa_family_t(family.rawValue),
                                   addressBytes: addr,
                                   addressDescription: dstBuf,
                                   addressDescriptionLength: dstSize)
    }

    static func inet_pton(af family: NIOBSDSocket.AddressFamily,
                          src description: UnsafePointer<CChar>,
                          dst address: UnsafeMutableRawPointer) throws {
        return try Posix.inet_pton(addressFamily: sa_family_t(family.rawValue),
                                   addressDescription: description,
                                   address: address)
    }

    static func sendfile(socket s: NIOBSDSocket.Handle,
                         fd: CInt,
                         offset: off_t,
                         len: off_t) throws -> IOResult<Int> {
        return try Posix.sendfile(descriptor: s, fd: fd, offset: offset, count: size_t(len))
    }

    static func setNonBlocking(socket: NIOBSDSocket.Handle) throws {
        return try Posix.setNonBlocking(socket: socket)
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

#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
import CNIODarwin
private let CMSG_FIRSTHDR = CNIODarwin_CMSG_FIRSTHDR
private let CMSG_NXTHDR = CNIODarwin_CMSG_NXTHDR
private let CMSG_DATA = CNIODarwin_CMSG_DATA
private let CMSG_DATA_MUTABLE = CNIODarwin_CMSG_DATA_MUTABLE
private let CMSG_SPACE = CNIODarwin_CMSG_SPACE
private let CMSG_LEN = CNIODarwin_CMSG_LEN
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
    static func firstHeader(inside msghdr: UnsafePointer<msghdr>)
            -> UnsafeMutablePointer<cmsghdr>? {
        return CMSG_FIRSTHDR(msghdr)
    }

    static func nextHeader(inside msghdr: UnsafeMutablePointer<msghdr>,
                           after: UnsafeMutablePointer<cmsghdr>)
            -> UnsafeMutablePointer<cmsghdr>? {
        return CMSG_NXTHDR(msghdr, after)
    }

    static func data(for header: UnsafePointer<cmsghdr>)
            -> UnsafeRawBufferPointer? {
        let data = CMSG_DATA(header)
        let length =
            size_t(header.pointee.cmsg_len) - NIOBSDSocketControlMessage.length(payloadSize: 0)
        return UnsafeRawBufferPointer(start: data, count: Int(length))
    }

    static func data(for header: UnsafeMutablePointer<cmsghdr>)
            -> UnsafeMutableRawBufferPointer? {
        let data = CMSG_DATA_MUTABLE(header)
        let length =
            size_t(header.pointee.cmsg_len) - NIOBSDSocketControlMessage.length(payloadSize: 0)
        return UnsafeMutableRawBufferPointer(start: data, count: Int(length))
    }

    static func length(payloadSize: size_t) -> size_t {
        return CMSG_LEN(payloadSize)
    }

    static func space(payloadSize: size_t) -> size_t {
        return CMSG_SPACE(payloadSize)
    }
}

#endif
