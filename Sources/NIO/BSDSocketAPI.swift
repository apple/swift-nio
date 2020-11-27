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

#if os(Windows)
import ucrt

import let WinSDK.INVALID_SOCKET

import let WinSDK.IPPROTO_IP
import let WinSDK.IPPROTO_IPV6
import let WinSDK.IPPROTO_TCP

import let WinSDK.IP_ADD_MEMBERSHIP
import let WinSDK.IP_DROP_MEMBERSHIP
import let WinSDK.IP_MULTICAST_IF
import let WinSDK.IP_MULTICAST_LOOP
import let WinSDK.IP_MULTICAST_TTL
import let WinSDK.IP_RECVTOS
import let WinSDK.IPV6_JOIN_GROUP
import let WinSDK.IPV6_LEAVE_GROUP
import let WinSDK.IPV6_MULTICAST_HOPS
import let WinSDK.IPV6_MULTICAST_IF
import let WinSDK.IPV6_MULTICAST_LOOP
import let WinSDK.IPV6_RECVTCLASS
import let WinSDK.IPV6_V6ONLY

import let WinSDK.AF_INET
import let WinSDK.AF_INET6
import let WinSDK.AF_UNIX

import let WinSDK.PF_INET
import let WinSDK.PF_INET6
import let WinSDK.PF_UNIX

import let WinSDK.SOCK_DGRAM
import let WinSDK.SOCK_STREAM

import let WinSDK.SO_ERROR
import let WinSDK.SO_KEEPALIVE
import let WinSDK.SO_LINGER
import let WinSDK.SO_RCVBUF
import let WinSDK.SO_RCVTIMEO
import let WinSDK.SO_REUSEADDR

import let WinSDK.SOL_SOCKET

import let WinSDK.TCP_NODELAY

import struct WinSDK.SOCKET

import struct WinSDK.WSACMSGHDR
import struct WinSDK.WSAMSG

import struct WinSDK.socklen_t

internal typealias msghdr = WSAMSG
internal typealias cmsghdr = WSACMSGHDR
#endif

protocol _SocketShutdownProtocol {
    var cValue: CInt { get }
}

internal enum Shutdown: _SocketShutdownProtocol {
    case RD
    case WR
    case RDWR
}

public enum NIOBSDSocket {
#if os(Windows)
    public typealias Handle = SOCKET
#else
    public typealias Handle = CInt
#endif

#if os(Windows)
    internal static let invalidHandle: Handle = INVALID_SOCKET
#else
    internal static let invalidHandle: Handle = -1
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
    #if os(Linux) || os(Android)
        public static let ip: NIOBSDSocket.OptionLevel =
                NIOBSDSocket.OptionLevel(rawValue: CInt(IPPROTO_IP))
    #else
        public static let ip: NIOBSDSocket.OptionLevel =
                NIOBSDSocket.OptionLevel(rawValue: IPPROTO_IP)
    #endif

    /// Socket options that apply only to IPv6 sockets.
    #if os(Linux) || os(Android)
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
    #if os(Linux) || os(Android)
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

    /// Request that we are passed type of service details when receiving
    /// datagrams.
    ///
    /// Not public as the way to request this is to use
    /// `ChannelOptions.explicitCongestionNotification` which works for both
    /// IPv4 and IPv6.
    static let ip_recv_tos: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: IP_RECVTOS)
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

    /// Request that we are passed traffic class details when receiving
    /// datagrams.
    ///
    /// Not public as the way to request this is to use
    /// `ChannelOptions.explicitCongestionNotification` which works for both
    /// IPv4 and IPv6.
    static let ipv6_recv_tclass: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: IPV6_RECVTCLASS)
}

// TCP Options
extension NIOBSDSocket.Option {
    /// Disables the Nagle algorithm for send coalescing.
    public static let tcp_nodelay: NIOBSDSocket.Option =
            NIOBSDSocket.Option(rawValue: TCP_NODELAY)
}

#if os(Linux) || os(FreeBSD) || os(Android)
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

/// The requested UDS path exists and has wrong type (not a socket).
public struct UnixDomainSocketPathWrongType: Error {}

/// This protocol defines the methods that are expected to be found on
/// `NIOBSDSocket`. While defined as a protocol there is no expectation that any
/// object other than `NIOBSDSocket` will implement this protocol: instead, this
/// protocol acts as a reference for what new supported operating systems must
/// implement.
protocol _BSDSocketProtocol {
    static func accept(socket s: NIOBSDSocket.Handle,
                       address addr: UnsafeMutablePointer<sockaddr>?,
                       address_len addrlen: UnsafeMutablePointer<socklen_t>?) throws -> NIOBSDSocket.Handle?

    static func bind(socket s: NIOBSDSocket.Handle,
                     address addr: UnsafePointer<sockaddr>,
                     address_len namelen: socklen_t) throws

    static func close(socket s: NIOBSDSocket.Handle) throws

    static func connect(socket s: NIOBSDSocket.Handle,
                        address name: UnsafePointer<sockaddr>,
                        address_len namelen: socklen_t) throws -> Bool

    static func getpeername(socket s: NIOBSDSocket.Handle,
                            address name: UnsafeMutablePointer<sockaddr>,
                            address_len namelen: UnsafeMutablePointer<socklen_t>) throws

    static func getsockname(socket s: NIOBSDSocket.Handle,
                            address name: UnsafeMutablePointer<sockaddr>,
                            address_len namelen: UnsafeMutablePointer<socklen_t>) throws

    static func getsockopt(socket: NIOBSDSocket.Handle,
                           level: NIOBSDSocket.OptionLevel,
                           option_name optname: NIOBSDSocket.Option,
                           option_value optval: UnsafeMutableRawPointer,
                           option_len optlen: UnsafeMutablePointer<socklen_t>) throws

    static func listen(socket s: NIOBSDSocket.Handle, backlog: CInt) throws

    static func recv(socket s: NIOBSDSocket.Handle,
                     buffer buf: UnsafeMutableRawPointer,
                     length len: size_t) throws -> IOResult<size_t>

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    static func recvmsg(socket: NIOBSDSocket.Handle,
                        msgHdr: UnsafeMutablePointer<msghdr>, flags: CInt)
            throws -> IOResult<size_t>

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    static func sendmsg(socket: NIOBSDSocket.Handle,
                        msgHdr: UnsafePointer<msghdr>, flags: CInt)
            throws -> IOResult<size_t>

    static func send(socket s: NIOBSDSocket.Handle,
                     buffer buf: UnsafeRawPointer,
                     length len: size_t) throws -> IOResult<size_t>

    static func setsockopt(socket: NIOBSDSocket.Handle,
                           level: NIOBSDSocket.OptionLevel,
                           option_name optname: NIOBSDSocket.Option,
                           option_value optval: UnsafeRawPointer,
                           option_len optlen: socklen_t) throws

    static func shutdown(socket: NIOBSDSocket.Handle, how: Shutdown) throws

    static func socket(domain af: NIOBSDSocket.ProtocolFamily,
                       type: NIOBSDSocket.SocketType,
                       `protocol`: CInt) throws -> NIOBSDSocket.Handle

    static func recvmmsg(socket: NIOBSDSocket.Handle,
                         msgvec: UnsafeMutablePointer<MMsgHdr>,
                         vlen: CUnsignedInt,
                         flags: CInt,
                         timeout: UnsafeMutablePointer<timespec>?) throws -> IOResult<Int>

    static func sendmmsg(socket: NIOBSDSocket.Handle,
                         msgvec: UnsafeMutablePointer<MMsgHdr>,
                         vlen: CUnsignedInt,
                         flags: CInt) throws -> IOResult<Int>

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    static func pread(socket: NIOBSDSocket.Handle,
                      pointer: UnsafeMutableRawPointer,
                      size: size_t,
                      offset: off_t) throws -> IOResult<size_t>

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    static func pwrite(socket: NIOBSDSocket.Handle,
                       pointer: UnsafeRawPointer,
                       size: size_t,
                       offset: off_t) throws -> IOResult<size_t>

#if !os(Windows)
    // NOTE: We do not support this on Windows as WSAPoll behaves differently
    // from poll with reporting of failed connections (Connect Report 309411),
    // which recommended that you use NetAPI instead.
    //
    // This is safe to exclude as this is a testing-only API.
    static func poll(fds: UnsafeMutablePointer<pollfd>, nfds: nfds_t,
                     timeout: CInt) throws -> CInt
#endif

    static func inet_ntop(af family: NIOBSDSocket.AddressFamily,
                          src addr: UnsafeRawPointer,
                          dst dstBuf: UnsafeMutablePointer<CChar>,
                          size dstSize: socklen_t) throws -> UnsafePointer<CChar>?

    static func inet_pton(af family: NIOBSDSocket.AddressFamily,
                          src description: UnsafePointer<CChar>,
                          dst address: UnsafeMutableRawPointer) throws

    static func sendfile(socket s: NIOBSDSocket.Handle,
                         fd: CInt,
                         offset: off_t,
                         len: off_t) throws -> IOResult<Int>

    // MARK: non-BSD APIs added by NIO

    static func setNonBlocking(socket: NIOBSDSocket.Handle) throws

    static func cleanupUnixDomainSocket(atPath path: String) throws
}

/// If this extension is hitting a compile error, your platform is missing one
/// of the functions defined above!
extension NIOBSDSocket: _BSDSocketProtocol { }

/// This protocol defines the methods that are expected to be found on
/// `NIOBSDControlMessage`. While defined as a protocol there is no expectation
/// that any object other than `NIOBSDControlMessage` will implement this
/// protocol: instead, this protocol acts as a reference for what new supported
/// operating systems must implement.
protocol _BSDSocketControlMessageProtocol {
    static func firstHeader(inside msghdr: UnsafePointer<msghdr>)
            -> UnsafeMutablePointer<cmsghdr>?

    static func nextHeader(inside msghdr: UnsafeMutablePointer<msghdr>,
                           after: UnsafeMutablePointer<cmsghdr>)
            -> UnsafeMutablePointer<cmsghdr>?

    static func data(for header: UnsafePointer<cmsghdr>)
            -> UnsafeRawBufferPointer?

    static func data(for header: UnsafeMutablePointer<cmsghdr>)
            -> UnsafeMutableRawBufferPointer?

    static func length(payloadSize: size_t) -> size_t

    static func space(payloadSize: size_t) -> size_t
}

/// If this extension is hitting a compile error, your platform is missing one
/// of the functions defined above!
enum NIOBSDSocketControlMessage: _BSDSocketControlMessageProtocol { }
