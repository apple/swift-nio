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

    static func recvmsg(descriptor: CInt, msgHdr: UnsafeMutablePointer<msghdr>, flags: CInt) throws -> IOResult<ssize_t> {
        return try Posix.recvmsg(descriptor: descriptor, msgHdr: msgHdr, flags: flags)
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

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    static func sendto(socket s: NIOBSDSocket.Handle,
                       buffer buf: UnsafeRawPointer,
                       length len: size_t,
                       dest_addr to: UnsafePointer<sockaddr>,
                       dest_len tolen: socklen_t) throws -> IOResult<size_t> {
        return try Posix.sendto(descriptor: s,
                                pointer: buf,
                                size: len,
                                destinationPtr: to,
                                destinationSize: tolen)
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
}

#endif
