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

#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
@_exported
import Darwin.C
#elseif os(Windows)
import ucrt

import let WinSDK.AF_INET
import let WinSDK.AF_INET6
import let WinSDK.AF_UNIX

import let WinSDK.IPPROTO_IP
import let WinSDK.IPPROTO_IPV6
import let WinSDK.IPPROTO_TCP

import let WinSDK.IP_ADD_MEMBERSHIP
import let WinSDK.IP_DROP_MEMBERSHIP
import let WinSDK.IP_MULTICAST_IF
import let WinSDK.IP_MULTICAST_LOOP
import let WinSDK.IP_MULTICAST_TTL

import let WinSDK.IPV6_JOIN_GROUP
import let WinSDK.IPV6_LEAVE_GROUP
import let WinSDK.IPV6_MULTICAST_HOPS
import let WinSDK.IPV6_MULTICAST_IF
import let WinSDK.IPV6_MULTICAST_LOOP
import let WinSDK.IPV6_V6ONLY

import let WinSDK.PF_INET
import let WinSDK.PF_INET6
import let WinSDK.PF_UNIX

import let WinSDK.TCP_NODELAY

import let WinSDK.SO_ERROR
import let WinSDK.SO_KEEPALIVE
import let WinSDK.SO_LINGER
import let WinSDK.SO_RCVBUF
import let WinSDK.SO_RCVTIMEO
import let WinSDK.SO_REUSEADDR
import let WinSDK.SO_REUSE_UNICASTPORT

import let WinSDK.SOL_SOCKET

import let WinSDK.SOCK_DGRAM
import let WinSDK.SOCK_STREAM

import let WinSDK.SOCKET_ERROR

import func WinSDK.WSAGetLastError

import struct WinSDK.socklen_t
import struct WinSDK.SOCKADDR

internal typealias sockaddr = WinSDK.SOCKADDR
#else
@_exported
import Glibc
#endif

#if !os(Windows)
let cAccept: @convention(c) (CInt, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?) -> CInt = accept
let cBind: @convention(c) (CInt, UnsafePointer<sockaddr>?, socklen_t) -> CInt = bind
let cClose: @convention(c) (CInt) -> CInt = close
let cConnect: @convention(c) (CInt, UnsafePointer<sockaddr>?, socklen_t) -> CInt = connect
let cGetpeername: @convention(c) (CInt, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?) -> CInt = getpeername
let cGetsockname: @convention(c) (CInt, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?) -> CInt = getsockname
let cGetsockopt: @convention(c) (CInt, CInt, CInt, UnsafeMutableRawPointer?, UnsafeMutablePointer<socklen_t>?) -> CInt = getsockopt
let cListen: @convention(c) (CInt, CInt) -> CInt = listen
let cRead: @convention(c) (CInt, UnsafeMutableRawPointer?, size_t, CInt) -> ssize_t = recv
let cRecvfrom: @convention(c) (CInt, UnsafeMutableRawPointer?, size_t, CInt, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?) -> ssize_t = recvfrom
let cSend: @convention(c) (CInt, UnsafeRawPointer?, size_t, CInt) -> ssize_t = send
let cSetsockopt: @convention(c) (CInt, CInt, CInt, UnsafeRawPointer?, socklen_t) -> CInt = setsockopt
let cSendto: @convention(c) (CInt, UnsafeRawPointer?, size_t, CInt, UnsafePointer<sockaddr>?, socklen_t) -> ssize_t = sendto
let cShutdown: @convention(c) (CInt, CInt) -> CInt = shutdown
let cSocket: @convention(c) (CInt, CInt, CInt) -> CInt = socket

let cPread: @convention(c) (CInt, UnsafeMutableRawPointer?, size_t, off_t) -> ssize_t = pread
let cPwrite: @convention(c) (CInt, UnsafeRawPointer?, size_t, off_t) -> ssize_t = pwrite

let cPoll: @convention(c) (UnsafeMutablePointer<pollfd>?, nfds_t, CInt) -> CInt = poll

let cInet_ntop: @convention(c) (CInt, UnsafeRawPointer?, UnsafeMutablePointer<CChar>?, socklen_t) -> UnsafePointer<CChar>? = inet_ntop
let cInet_pton: @convention(c) (CInt, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> CInt = inet_pton

let cErrno: CInt = errno
#endif

#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
import CNIODarwin
internal typealias MMsgHdr = CNIODarwin_mmsghdr

let crecvmmsg: @convention(c) (NIOBSDSocket.Handle, UnsafeMutablePointer<CNIODarwin_mmsghdr>?, CUnsignedInt, CInt, UnsafeMutablePointer<timespec>?) -> CInt = CNIODarwin_recvmmsg
let csendmmsg: @convention(c) (NIOBSDSocket.Handle, UnsafeMutablePointer<CNIODarwin_mmsghdr>?, CUnsignedInt, CInt) -> CInt = CNIODarwin_sendmmsg
#elseif os(Windows)
import CNIOWindows
internal typealias MMsgHdr = CNIOWindows_mmsghdr

let crecvmmsg: @convention(c) (NIOBSDSocket.Handle, UnsafeMutablePointer<CNIOWindows_mmsghdr>?, CUnsignedInt, CInt, UnsafeMutablePointer<timespec>?) -> CInt = CNIOWindows_recvmmsg
let csendmmsg: @convention(c) (NIOBSDSocket.Handle, UnsafeMutablePointer<CNIOWindows_mmsghdr>?, CUnsignedInt, CInt) -> CInt = CNIOWindows_sendmmsg
#else
import CNIOLinux
internal typealias MMsgHdr = CNIOLinux_mmsghdr

let crecvmmsg: @convention(c) (NIOBSDSocket.Handle, UnsafeMutablePointer<CNIOLinux_mmsghdr>?, CUnsignedInt, CInt, UnsafeMutablePointer<timespec>?) -> CInt = CNIOLinux_recvmmsg
let csendmmsg: @convention(c) (NIOBSDSocket.Handle, UnsafeMutablePointer<CNIOLinux_mmsghdr>?, CUnsignedInt, CInt) -> CInt = CNIOLinux_sendmmsg
#endif

internal enum Shutdown {
    case RD
    case WR
    case RDWR

    internal var cValue: CInt {
        switch self {
        case .RD:
            #if os(Windows)
                return WinSDK.SD_RECEIVE
            #else
                return CInt(SHUT_RD)
            #endif
        case .WR:
            #if os(Windows)
                return WinSDK.SD_SEND
            #else
                return CInt(SHUT_WR)
            #endif
        case .RDWR:
            #if os(Windows)
                return WinSDK.SD_BOTH
            #else
                return CInt(SHUT_RDWR)
            #endif
        }
    }
}

public enum NIOBSDSocket {
#if os(Windows)
    public typealias Handle = SOCKET
#else
    public typealias Handle = CInt
#endif
}

extension NIOBSDSocket {
    /// Specifies the type of socket.
    internal struct SocketType: RawRepresentable {
        public typealias RawValue = CInt
        public var rawValue: RawValue
        public init(rawValue: RawValue) {
            self.rawValue = rawValue
        }
    }
}

extension NIOBSDSocket.SocketType: Equatable {
}

extension NIOBSDSocket.SocketType: Hashable {
}

extension NIOBSDSocket {
    /// Specifies the addressing scheme that the socket can use.
    public struct AddressFamily: RawRepresentable {
        public typealias RawValue = CInt
        public var rawValue: RawValue
        public init(rawValue: RawValue) {
            self.rawValue = rawValue
        }
    }
}

extension NIOBSDSocket.AddressFamily: Equatable {
}

extension NIOBSDSocket.AddressFamily: Hashable {
}

extension NIOBSDSocket {
    /// Specifies the type of protocol that the socket can use.
    public struct ProtocolFamily: RawRepresentable {
        public typealias RawValue = CInt
        public var rawValue: RawValue
        public init(rawValue: RawValue) {
            self.rawValue = rawValue
        }
    }
}

extension NIOBSDSocket.ProtocolFamily: Equatable {
}

extension NIOBSDSocket.ProtocolFamily: Hashable {
}

extension NIOBSDSocket {
    /// Defines socket option levels.
    public struct OptionLevel: RawRepresentable {
        public typealias RawValue = CInt
        public var rawValue: RawValue
        public init(rawValue: RawValue) {
            self.rawValue = rawValue
        }
    }
}

extension NIOBSDSocket.OptionLevel: Equatable {
}

extension NIOBSDSocket.OptionLevel: Hashable {
}

extension NIOBSDSocket {
    /// Defines configuration option names.
    public struct Option: RawRepresentable {
        public typealias RawValue = CInt
        public var rawValue: RawValue
        public init(rawValue: RawValue) {
            self.rawValue = rawValue
        }
    }
}

extension NIOBSDSocket.Option: Equatable {
}

extension NIOBSDSocket.Option: Hashable {
}

// Address Family
extension NIOBSDSocket.AddressFamily {
    /// Address for IP version 4.
    public static let inet: NIOBSDSocket.AddressFamily =
            NIOBSDSocket.AddressFamily(rawValue: AF_INET)

    /// Address for IP version 6.
    public static let inet6: NIOBSDSocket.AddressFamily =
            NIOBSDSocket.AddressFamily(rawValue: AF_INET6)

    /// Unix local to host address.
    public static let unix: NIOBSDSocket.AddressFamily =
            NIOBSDSocket.AddressFamily(rawValue: AF_UNIX)
}

// Protocol Family
extension NIOBSDSocket.ProtocolFamily {
    /// IP network 4 protocol.
    public static let inet: NIOBSDSocket.ProtocolFamily =
            NIOBSDSocket.ProtocolFamily(rawValue: PF_INET)

    /// IP network 6 protocol.
    public static let inet6: NIOBSDSocket.ProtocolFamily =
            NIOBSDSocket.ProtocolFamily(rawValue: PF_INET6)

    /// UNIX local to the host.
    public static let unix: NIOBSDSocket.ProtocolFamily =
            NIOBSDSocket.ProtocolFamily(rawValue: PF_UNIX)
}

#if !os(Windows)
    extension NIOBSDSocket.ProtocolFamily {
        /// UNIX local to the host, alias for `PF_UNIX` (`.unix`)
        public static let local: NIOBSDSocket.ProtocolFamily =
                NIOBSDSocket.ProtocolFamily(rawValue: PF_LOCAL)
    }
#endif

// Socket Types
extension NIOBSDSocket.SocketType {
    /// Supports datagrams, which are connectionless, unreliable messages of a
    /// fixed (typically small) maximum length.
    #if os(Linux)
        internal static let datagram: NIOBSDSocket.SocketType =
                NIOBSDSocket.SocketType(rawValue: CInt(SOCK_DGRAM.rawValue))
    #else
        internal static let datagram: NIOBSDSocket.SocketType =
                NIOBSDSocket.SocketType(rawValue: SOCK_DGRAM)
    #endif

    /// Supports reliable, two-way, connection-based byte streams without
    /// duplication of data and without preservation of boundaries.
    #if os(Linux)
        internal static let stream: NIOBSDSocket.SocketType =
                NIOBSDSocket.SocketType(rawValue: CInt(SOCK_STREAM.rawValue))
    #else
        internal static let stream: NIOBSDSocket.SocketType =
                NIOBSDSocket.SocketType(rawValue: SOCK_STREAM)
    #endif
}

// Option Level
extension NIOBSDSocket.OptionLevel {
    /// Socket options that apply only to IP sockets.
    #if os(Linux)
        public static let ip: NIOBSDSocket.OptionLevel =
                NIOBSDSocket.OptionLevel(rawValue: CInt(IPPROTO_IP))
    #else
        public static let ip: NIOBSDSocket.OptionLevel =
                NIOBSDSocket.OptionLevel(rawValue: IPPROTO_IP)
    #endif

    /// Socket options that apply only to IPv6 sockets.
    #if os(Linux)
        public static let ipv6: NIOBSDSocket.OptionLevel =
                NIOBSDSocket.OptionLevel(rawValue: CInt(IPPROTO_IPV6))
    #elseif os(Windows)
        public static let ipv6: NIOBSDSocket.OptionLevel =
                NIOBSDSocket.OptionLevel(rawValue: IPPROTO_IPV6.rawValue)
    #else
        public static let ipv6: NIOBSDSocket.OptionLevel =
                NIOBSDSocket.OptionLevel(rawValue: IPPROTO_IPV6)
    #endif

    /// Socket options that apply only to TCP sockets.
    #if os(Linux)
        public static let tcp: NIOBSDSocket.OptionLevel =
                NIOBSDSocket.OptionLevel(rawValue: CInt(IPPROTO_TCP))
    #elseif os(Windows)
        public static let tcp: NIOBSDSocket.OptionLevel =
                NIOBSDSocket.OptionLevel(rawValue: IPPROTO_TCP.rawValue)
    #else
        public static let tcp: NIOBSDSocket.OptionLevel =
                NIOBSDSocket.OptionLevel(rawValue: IPPROTO_TCP)
    #endif

    /// Socket options that apply to all sockets.
    public static let socket: NIOBSDSocket.OptionLevel =
            NIOBSDSocket.OptionLevel(rawValue: SOL_SOCKET)
}

// IPv4 Options
extension NIOBSDSocket.Option {
    /// Add a multicast group membership.
    public static let ip_add_membership: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: IP_ADD_MEMBERSHIP)

    /// Drop a multicast group membership.
    public static let ip_drop_membership: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: IP_DROP_MEMBERSHIP)

    /// Set the interface for outgoing multicast packets.
    public static let ip_multicast_if: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: IP_MULTICAST_IF)

    /// Control multicast loopback.
    public static let ip_multicast_loop: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: IP_MULTICAST_LOOP)

    /// Control multicast time-to-live.
    public static let ip_multicast_ttl: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: IP_MULTICAST_TTL)
}

// IPv6 Options
extension NIOBSDSocket.Option {
    /// Add an IPv6 group membership.
    public static let ipv6_join_group: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: IPV6_JOIN_GROUP)

    /// Drop an IPv6 group membership.
    public static let ipv6_leave_group: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: IPV6_LEAVE_GROUP)

    /// Specify the maximum number of router hops for an IPv6 packet.
    public static let ipv6_multicast_hops: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: IPV6_MULTICAST_HOPS)

    /// Set the interface for outgoing multicast packets.
    public static let ipv6_multicast_if: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: IPV6_MULTICAST_IF)

    /// Control multicast loopback.
    public static let ipv6_multicast_loop: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: IPV6_MULTICAST_LOOP)

    /// Indicates if a socket created for the `AF_INET6` address family is
    /// restricted to IPv6 only.
    public static let ipv6_v6only: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: IPV6_V6ONLY)
}

// TCP Options
extension NIOBSDSocket.Option {
    /// Disables the Nagle algorithm for send coalescing.
    public static let tcp_nodelay: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: TCP_NODELAY)
}

#if os(Linux) || os(FreeBSD)
extension NIOBSDSocket.Option {
    /// Get information about the TCP connection.
    public static let tcp_info: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: TCP_INFO)
}
#endif

#if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
extension NIOBSDSocket.Option {
    /// Get information about the TCP connection.
    public static let tcp_connection_info: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: TCP_CONNECTION_INFO)
}
#endif

// Socket Options
extension NIOBSDSocket.Option {
    /// Get the error status and clear.
    public static let so_error: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: SO_ERROR)

    /// Use keep-alives.
    public static let so_keepalive: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: SO_KEEPALIVE)

    /// Linger on close if unsent data is present.
    public static let so_linger: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: SO_LINGER)

    /// Specifies the total per-socket buffer space reserved for receives.
    public static let so_rcvbuf: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: SO_RCVBUF)

    /// Specifies the receive timeout.
    public static let so_rcvtimeo: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: SO_RCVTIMEO)

    /// Allows the socket to be bound to an address that is already in use.
    public static let so_reuseaddr: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: SO_REUSEADDR)
}

#if !os(Windows)
extension NIOBSDSocket.Option {
    /// Indicate when to generate timestamps.
    public static let so_timestamp: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: SO_TIMESTAMP)
}
#endif

extension NIOBSDSocket {
    @inline(never)
    internal static func accept(socket s: NIOBSDSocket.Handle,
                                address addr: UnsafeMutablePointer<sockaddr>?,
                                address_len addrlen: UnsafeMutablePointer<socklen_t>?)
            throws -> NIOBSDSocket.Handle? {
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
            guard case let .processed(fd) = try syscall(blocking: true, { () -> NIOBSDSocket.Handle in
                let fd = cAccept(s, addr, addrlen)
                guard fd > 0 else {
                    return fd
                }

                do {
                    try Posix.fcntl(descriptor: fd, command: F_SETNOSIGPIPE, value: 1)
                } catch {
                    _ = cClose(fd)  // don't care about failure here
                    throw error
                }

                return fd
            }) else {
                return nil
            }

            return fd
        #elseif os(Windows)
              let socket: NIOBSDSocket.Handle = WinSDK.accept(s, addr, addrlen)
              if socket == WinSDK.INVALID_SOCKET {
                  throw IOError(winsock: WSAGetLastError(), reason: "accept")
              }
              return socket
        #else
            guard case let .processed(fd) = try syscall(blocking: true, {
                cAccept(s, addr, addrlen)
            }) else {
                return nil
            }

            return fd
        #endif
    }

    @inline(never)
    internal static func bind(socket s: NIOBSDSocket.Handle,
                              address addr: UnsafePointer<sockaddr>,
                              address_len namelen: socklen_t) throws {
        #if os(Windows)
            if WinSDK.bind(s, addr, namelen) == SOCKET_ERROR {
                throw IOError(winsock: WSAGetLastError(), reason: "bind")
            }
        #else
            _ = try syscall(blocking: false) {
                cBind(s, addr, namelen)
            }
        #endif
    }


    @inline(never)
    internal static func close(socket s: NIOBSDSocket.Handle) throws {
        #if os(Windows)
            if WinSDK.closesocket(s) == SOCKET_ERROR {
                throw IOError(winsock: WSAGetLastError(), reason: "close")
            }
        #else
            let result: CInt = cClose(s)
            if result == -1 {
                let errnoCode = cErrno
                if errnoCode == EINTR {
                    return
                }
                preconditionIsNotBlacklistedErrno(err: errnoCode, where: #function)
                throw IOError(errnoCode: errnoCode, reason: "close")
            }
        #endif
    }

    @inline(never)
    internal static func connect(socket s: NIOBSDSocket.Handle,
                                 address name: UnsafePointer<sockaddr>,
                                 address_len namelen: socklen_t)
            throws -> Bool {
        #if os(Windows)
            if WinSDK.connect(s, name, namelen) == SOCKET_ERROR {
                throw IOError(winsock: WSAGetLastError(), reason: "connect")
            }
            return true
        #else
            do {
                _ = try syscall(blocking: false) {
                    cConnect(s, name, namelen)
                }
                return true
            } catch let error as IOError {
                if error.errnoCode == EINPROGRESS {
                    return false
                }
                throw error
            }
        #endif
    }

    @inline(never)
    internal static func getpeername(socket s: NIOBSDSocket.Handle,
                                     address name: UnsafeMutablePointer<sockaddr>,
                                     address_len namelen: UnsafeMutablePointer<socklen_t>)
            throws {
        #if os(Windows)
            if WinSDK.getpeername(s, name, namelen) == SOCKET_ERROR {
                throw IOError(winsock: WSAGetLastError(), reason: "getpeername")
            }
        #else
            _ = try syscall(blocking: false) {
              cGetpeername(s, name, namelen)
            }
        #endif
    }

    @inline(never)
    internal static func getsockname(socket s: NIOBSDSocket.Handle,
                                     address name: UnsafeMutablePointer<sockaddr>,
                                     address_len namelen: UnsafeMutablePointer<socklen_t>)
            throws {
        #if os(Windows)
            if WinSDK.getsockname(s, name, namelen) == SOCKET_ERROR {
                throw IOError(winsock: WSAGetLastError(), reason: "getsockname")
            }
        #else
            _ = try syscall(blocking: false) {
                cGetsockname(s, name, namelen)
            }
        #endif
    }

    @inline(never)
    internal static func getsockopt(socket: NIOBSDSocket.Handle,
                                    level: NIOBSDSocket.OptionLevel,
                                    option_name optname: NIOBSDSocket.Option,
                                    option_value optval: UnsafeMutableRawPointer,
                                    option_len optlen: UnsafeMutablePointer<socklen_t>)
            throws {
        #if os(Windows)
            if CNIOWindows_getsockopt(socket, level.rawValue, optname.rawValue,
                                      optval, optlen) == SOCKET_ERROR {
                throw IOError(winsock: WSAGetLastError(), reason: "getsockopt")
            }
        #else
            _ = try syscall(blocking: false) {
                cGetsockopt(socket, level.rawValue, optname.rawValue, optval, optlen)
            }
        #endif
    }

    @inline(never)
    internal static func listen(socket s: NIOBSDSocket.Handle, backlog: CInt)
            throws {
        #if os(Windows)
            if WinSDK.listen(s, backlog) == SOCKET_ERROR {
              throw IOError(winsock: WSAGetLastError(), reason: "listen")
            }
        #else
              _ = try syscall(blocking: false) {
                  cListen(s, backlog)
              }
        #endif
    }

    @inline(never)
    internal static func recv(socket s: NIOBSDSocket.Handle,
                              buffer buf: UnsafeMutableRawPointer,
                              length len: size_t) throws -> IOResult<size_t> {
        #if os(Windows)
            let iResult: CInt = CNIOWindows_recv(s, buf, CInt(len), 0)
            if iResult == SOCKET_ERROR {
                throw IOError(winsock: WSAGetLastError(), reason: "recv")
            }
            return .processed(size_t(iResult))
        #else
            return try syscall(blocking: true) {
                cRead(s, buf, len, 0)
            }
        #endif
    }

    @inline(never)
    internal static func recvfrom(socket s: NIOBSDSocket.Handle,
                                  buffer buf: UnsafeMutableRawPointer,
                                  length len: size_t,
                                  address from: UnsafeMutablePointer<sockaddr>,
                                  address_len fromlen: UnsafeMutablePointer<socklen_t>)
            throws -> IOResult<size_t> {
        #if os(Windows)
            let iResult: CInt =
                CNIOWindows_recvfrom(s, buf, CInt(len), 0, from, fromlen)
            if iResult == SOCKET_ERROR {
                throw IOError(winsock: WSAGetLastError(), reason: "recvfrom")
            }
            return .processed(size_t(iResult))
        #else
            return try syscall(blocking: true) {
                cRecvfrom(s, buf, len, 0, from, fromlen)
            }
        #endif
    }

    @inline(never)
    internal static func send(socket s: NIOBSDSocket.Handle,
                              buffer buf: UnsafeRawPointer,
                              length len: size_t) throws -> IOResult<size_t> {
        #if os(Windows)
            let iResult: CInt = CNIOWindows_send(s, buf, CInt(len), 0)
            if iResult == SOCKET_ERROR {
                throw IOError(winsock: WSAGetLastError(), reason: "send")
            }
            return .processed(size_t(iResult))
        #else
            return try syscall(blocking: true) {
                cSend(s, buf, len, 0)
            }
        #endif
    }

    @inline(never)
    internal static func setsockopt(socket: NIOBSDSocket.Handle,
                                    level: NIOBSDSocket.OptionLevel,
                                    option_name optname: NIOBSDSocket.Option,
                                    option_value optval: UnsafeRawPointer,
                                    option_len optlen: socklen_t) throws {
        #if os(Windows)
            if CNIOWindows_setsockopt(socket, level.rawValue, optname.rawValue,
                                      optval, optlen) == SOCKET_ERROR {
                throw IOError(winsock: WSAGetLastError(), reason: "setsockopt")
            }
        #else
            _ = try syscall(blocking: false) {
                cSetsockopt(socket, level.rawValue, optname.rawValue, optval, optlen)
            }
        #endif
    }

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    @inline(never)
    internal static func sendto(socket s: NIOBSDSocket.Handle,
                                buffer buf: UnsafeRawPointer, length len: size_t,
                                dest_addr to: UnsafePointer<sockaddr>,
                                dest_len tolen: socklen_t)
            throws -> IOResult<size_t> {
        #if os(Windows)
            let iResult: CInt =
                CNIOWindows_sendto(s, buf, CInt(len), 0, to, tolen)
            if iResult == SOCKET_ERROR {
                throw IOError(winsock: WSAGetLastError(), reason: "sendto")
            }
            return .processed(size_t(iResult))
        #else
            return try syscall(blocking: true) {
                cSendto(s, buf, len, 0, to, tolen)
            }
        #endif
    }

    @inline(never)
    internal static func shutdown(socket: NIOBSDSocket.Handle, how: Shutdown)
            throws {
        #if os(Windows)
            if WinSDK.shutdown(socket, how.cValue) == SOCKET_ERROR {
                throw IOError(winsock: WSAGetLastError(), reason: "shutdown")
            }
        #else
            _ = try syscall(blocking: false) {
                cShutdown(socket, how.cValue)
            }
        #endif
    }

    @inline(never)
    internal static func socket(domain af: NIOBSDSocket.ProtocolFamily,
                                type: NIOBSDSocket.SocketType, `protocol`: CInt)
            throws -> NIOBSDSocket.Handle {
        #if os(Windows)
            let socket: NIOBSDSocket.Handle =
                WinSDK.socket(af.rawValue, type.rawValue, `protocol`)
            if socket == WinSDK.INVALID_SOCKET {
                throw IOError(winsock: WSAGetLastError(), reason: "socket")
            }
            return socket
        #else
            return try syscall(blocking: false) {
                cSocket(af.rawValue, type.rawValue, `protocol`)
            }.result
        #endif
    }
}

extension NIOBSDSocket {
    @inline(never)
    internal static func recvmmsg(socket: NIOBSDSocket.Handle,
                                  msgvec: UnsafeMutablePointer<MMsgHdr>,
                                  vlen: CUnsignedInt, flags: CInt,
                                  timeout: UnsafeMutablePointer<timespec>?)
            throws -> IOResult<Int> {
        return try syscall(blocking: true) {
            Int(crecvmmsg(socket, msgvec, vlen, flags, timeout))
        }
    }

    @inline(never)
    internal static func sendmmsg(socket: NIOBSDSocket.Handle,
                                  msgvec: UnsafeMutablePointer<MMsgHdr>,
                                  vlen: CUnsignedInt, flags: CInt)
            throws -> IOResult<Int> {
        return try syscall(blocking: true) {
            Int(csendmmsg(socket, msgvec, vlen, flags))
        }
    }
}

// POSIX Extensions
extension NIOBSDSocket {
    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    @inline(never)
    internal static func pread(socket: NIOBSDSocket.Handle,
                               pointer: UnsafeMutableRawPointer,
                               size: size_t, offset: off_t)
            throws -> IOResult<CInt> {
        #if os(Windows)
            var ovlOverlapped: OVERLAPPED = OVERLAPPED()
            ovlOverlapped.OffsetHigh = DWORD(UInt32(offset >> 32) & 0xffffffff)
            ovlOverlapped.Offset = DWORD(UInt32(offset >> 0) & 0xffffffff)
            var nNumberOfBytesRead: DWORD = 0
            if !ReadFile(HANDLE(bitPattern: UInt(socket)), pointer, DWORD(size),
                         &nNumberOfBytesRead, &ovlOverlapped) {
                throw IOError(windows: GetLastError(), reason: "ReadFile")
            }
            return .processed(CInt(nNumberOfBytesRead))
        #else
            return try syscall(blocking: true) {
                CInt(cPread(socket, pointer, size, offset))
            }
        #endif
    }

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    @inline(never)
    internal static func pwrite(socket: NIOBSDSocket.Handle,
                                pointer: UnsafeRawPointer, size: size_t,
                                offset: off_t) throws -> IOResult<CInt> {
        #if os(Windows)
            var ovlOverlapped: OVERLAPPED = OVERLAPPED()
            ovlOverlapped.OffsetHigh = DWORD(UInt32(offset >> 32) & 0xffffffff)
            ovlOverlapped.Offset = DWORD(UInt32(offset >> 0) & 0xffffffff)
            var nNumberOfBytesWritten: DWORD = 0
            if !WriteFile(HANDLE(bitPattern: UInt(socket)), pointer, DWORD(size),
                          &nNumberOfBytesWritten, &ovlOverlapped) {
              throw IOError(windows: GetLastError(), reason: "WriteFile")
            }
            return .processed(CInt(nNumberOfBytesWritten))
        #else
            return try syscall(blocking: true) {
                CInt(cPwrite(socket, pointer, size, offset))
            }
        #endif
    }
}

// Testing APIs
#if !os(Windows)
    // NOTE: We do not support this on Windows as WSAPoll behaves differently
    // from poll with reporting of failed connections (Connect Report 309411),
    // which recommended that you use NetAPI instead.
    extension NIOBSDSocket {
        @inline(never)
        public static func poll(fds: UnsafeMutablePointer<pollfd>, nfds: nfds_t,
                                timeout: CInt) throws -> CInt {
            return try syscall(blocking: false) {
                cPoll(fds, nfds, timeout)
            }.result
        }
    }
#endif

// TCP/IP Operations
extension NIOBSDSocket {
    @discardableResult
    @inline(never)
    internal static func inet_ntop(af Family: NIOBSDSocket.AddressFamily,
                                   src pAddr: UnsafeRawPointer,
                                   dst pStringBuf: UnsafeMutablePointer<CChar>,
                                   size StringBufSize: socklen_t)
            throws -> UnsafePointer<CChar>? {
        #if os(Windows)
            // TODO(compnerd) use `InetNtopW` to ensure that we handle unicode properly
            guard let result = WinSDK.inet_ntop(Family.rawValue, pAddr, pStringBuf,
                                                Int(StringBufSize)) else {
                throw IOError(windows: GetLastError(), reason: "inet_ntop")
            }
            return result
        #else
            return try wrapErrorIsNullReturnCall {
                cInet_ntop(Family.rawValue, pAddr, pStringBuf, StringBufSize)
            }
        #endif
    }

    @inline(never)
    internal static func inet_pton(af Family: NIOBSDSocket.AddressFamily,
                                   src pszAddrString: UnsafePointer<CChar>,
                                   dst pAddrBuf: UnsafeMutableRawPointer)
            throws {
        #if os(Windows)
            // TODO(compnerd) use `InetPtonW` to ensure that we handle unicode properly
            switch WinSDK.inet_pton(Family.rawValue, pszAddrString, pAddrBuf) {
            case 0: throw IOError(errnoCode: EINVAL, reason: "inet_pton")
            case 1: return
            default: throw IOError(winsock: WSAGetLastError(), reason: "inet_pton")
            }
        #else
            switch cInet_pton(Family.rawValue, pszAddrString, pAddrBuf) {
            case 0: throw IOError(errnoCode: EINVAL, reason: "inet_pton")
            case 1: return
            default: throw IOError(errnoCode: errno, reason: "inet_pton")
            }
        #endif
    }

    @inline(never)
    internal static func sendfile(socket s: NIOBSDSocket.Handle, fd: CInt,
                                  offset: off_t,
                                  len nNumberOfBytesToWrite: off_t)
            throws -> IOResult<Int> {
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
            var written: off_t = 0
            do {
                _ = try syscall(blocking: false) { () -> ssize_t in
                    var len: off_t = off_t(nNumberOfBytesToWrite)
                    let result: CInt = Darwin.sendfile(s, fd, offset, &len, nil, 0)
                    written = len
                    return ssize_t(result)
                }
                return .processed(Int(written))
            } catch let error as IOError {
                if error.errnoCode == EAGAIN {
                    return .wouldBlock(Int(written))
                }
                throw error
            }
        #elseif os(Windows)
            let hFile: HANDLE = HANDLE(bitPattern: ucrt._get_osfhandle(fd))!
            if hFile == INVALID_HANDLE_VALUE {
                throw IOError(errnoCode: EBADF, reason: "_get_osfhandle")
            }

            var ovlOverlapped: OVERLAPPED = OVERLAPPED()
            ovlOverlapped.Offset = DWORD(UInt32(offset >> 0) & 0xffffffff)
            ovlOverlapped.OffsetHigh = DWORD(UInt32(offset >> 32) & 0xffffffff)
            if !TransmitFile(s, hFile, DWORD(nNumberOfBytesToWrite), 0,
                             &ovlOverlapped, nil, DWORD(TF_USE_KERNEL_APC)) {
                throw IOError(winsock: WSAGetLastError(), reason: "TransmitFile")
            }

            return .processed(Int(nNumberOfBytesToWrite))
        #else
            var written: off_t = 0
            do {
                _ = try syscall(blocking: false) { () -> ssize_t in
                    var off: off_t = offset
                    let result: ssize_t =
                            Glibc.sendfile(s, fd, &off, nNumberOfBytesToWrite)
                    written = result >= 0 ? result : 0
                    return result
                }
                return .processed(Int(written))
            } catch let error as IOError {
                if error.errnoCode == EAGAIN {
                    return .wouldBlock(Int(written))
                }
                throw error
            }
        #endif
    }
}

/// `NIOFailedToSetSocketNonBlockingError` indicates that NIO was unable to set a socket to non-blocking mode, either
/// when connecting a socket as a client or when accepting a socket as a server.
///
/// This error should never happen because a socket should always be able to be set to non-blocking mode. Unfortunately,
/// we have seen this happen on Darwin.
public struct NIOFailedToSetSocketNonBlockingError: Error {}

// Helper Functions
extension NIOBSDSocket {
    internal static func setNonBlocking(socket: NIOBSDSocket.Handle) throws {
        #if os(Windows)
            var ulMode: u_long = 1
            if WinSDK.ioctlsocket(socket, FIONBIO, &ulMode) == SOCKET_ERROR {
                throw IOError(winsock: WSAGetLastError(), reason: "ioctlsocket")
            }
        #else
            let flags = try Posix.fcntl(descriptor: socket, command: F_GETFL, value: 0)
            do {
                let ret = try Posix.fcntl(descriptor: socket, command: F_SETFL,
                                          value: flags | O_NONBLOCK)
                assert(ret == 0, "unexpectedly, fcntl(\(socket), F_SETFL, \(flags) | O_NONBLOCK) returned \(ret)")
            } catch let error as IOError {
                if error.errnoCode == EINVAL {
                    // Darwin seems to sometimes do this despite the docs claiming
                    // it can't happen
                    throw NIOFailedToSetSocketNonBlockingError()
                }
                throw error
            }
        #endif
    }
}
