//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore

#if os(Windows)
import ucrt

import let WinSDK.INVALID_SOCKET

import let WinSDK.IP_RECVTOS
import let WinSDK.IPV6_RECVTCLASS

import let WinSDK.SOCK_DGRAM
import let WinSDK.SOCK_STREAM
import let WinSDK.SOCK_RAW

import struct WinSDK.socklen_t
#endif

protocol _SocketShutdownProtocol {
    var cValue: CInt { get }
}

@usableFromInline
internal enum Shutdown: _SocketShutdownProtocol, Sendable {
    case RD
    case WR
    case RDWR
}

extension NIOBSDSocket {
    #if os(Windows)
    internal static let invalidHandle: Handle = INVALID_SOCKET
    #else
    internal static let invalidHandle: Handle = -1
    #endif
}

extension NIOBSDSocket {
    /// Specifies the type of socket.
    @usableFromInline
    internal struct SocketType: RawRepresentable, Sendable {
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

// Socket Types
extension NIOBSDSocket.SocketType {
    /// Supports datagrams, which are connectionless, unreliable messages of a
    /// fixed (typically small) maximum length.
    #if os(Linux) && !canImport(Musl)
    internal static let datagram: NIOBSDSocket.SocketType =
        NIOBSDSocket.SocketType(rawValue: CInt(SOCK_DGRAM.rawValue))
    #else
    internal static let datagram: NIOBSDSocket.SocketType =
        NIOBSDSocket.SocketType(rawValue: SOCK_DGRAM)
    #endif

    /// Supports reliable, two-way, connection-based byte streams without
    /// duplication of data and without preservation of boundaries.
    #if os(Linux) && !canImport(Musl)
    internal static let stream: NIOBSDSocket.SocketType =
        NIOBSDSocket.SocketType(rawValue: CInt(SOCK_STREAM.rawValue))
    #else
    internal static let stream: NIOBSDSocket.SocketType =
        NIOBSDSocket.SocketType(rawValue: SOCK_STREAM)
    #endif

    #if os(Linux) && !canImport(Musl)
    internal static let raw: NIOBSDSocket.SocketType =
        NIOBSDSocket.SocketType(rawValue: CInt(SOCK_RAW.rawValue))
    #else
    internal static let raw: NIOBSDSocket.SocketType =
        NIOBSDSocket.SocketType(rawValue: SOCK_RAW)
    #endif
}

// IPv4 Options
#if !os(OpenBSD)
extension NIOBSDSocket.Option {
    /// Request that we are passed type of service details when receiving
    /// datagrams.
    ///
    /// Not public as the way to request this is to use
    /// `ChannelOptions.explicitCongestionNotification` which works for both
    /// IPv4 and IPv6.
    static let ip_recv_tos: NIOBSDSocket.Option =
        NIOBSDSocket.Option(rawValue: IP_RECVTOS)

    /// Request that we are passed destination address and the receiving interface index when
    /// receiving datagrams.
    ///
    /// This option is not public as the way to request this is to use
    /// `ChannelOptions.receivePacketInfo` which works for both
    /// IPv4 and IPv6.
    static let ip_recv_pktinfo: NIOBSDSocket.Option =
        NIOBSDSocket.Option(rawValue: Posix.IP_RECVPKTINFO)
}
#endif

// IPv6 Options
extension NIOBSDSocket.Option {
    /// Request that we are passed traffic class details when receiving
    /// datagrams.
    ///
    /// Not public as the way to request this is to use
    /// `ChannelOptions.explicitCongestionNotification` which works for both
    /// IPv4 and IPv6.
    static let ipv6_recv_tclass: NIOBSDSocket.Option =
        NIOBSDSocket.Option(rawValue: IPV6_RECVTCLASS)

    #if !os(OpenBSD)
    /// Request that we are passed destination address and the receiving interface index when
    /// receiving datagrams.
    ///
    /// This option is not public as the way to request this is to use
    /// `ChannelOptions.receivePacketInfo` which works for both
    /// IPv4 and IPv6.
    static let ipv6_recv_pktinfo: NIOBSDSocket.Option =
        NIOBSDSocket.Option(rawValue: Posix.IPV6_RECVPKTINFO)
    #endif
}

extension NIOBSDSocket {
    /// Defines a protocol subtype.
    ///
    /// Protocol subtypes are the third argument passed to the `socket` system call.
    /// They aren't necessarily protocols in their own right: for example, ``mptcp``
    /// is not. They act to modify the socket type instead: thus, ``mptcp`` acts
    /// to modify `SOCK_STREAM` to ask for ``mptcp`` support.
    public struct ProtocolSubtype: RawRepresentable, Hashable, Sendable {
        public typealias RawValue = CInt

        /// The underlying value of the protocol subtype.
        public var rawValue: RawValue

        /// Construct a protocol subtype from its underlying value.
        @inlinable
        public init(rawValue: RawValue) {
            self.rawValue = rawValue
        }
    }
}

extension NIOBSDSocket.ProtocolSubtype {
    /// Refers to the "default" protocol subtype for a given socket type.
    public static var `default`: NIOBSDSocket.ProtocolSubtype {
        Self(rawValue: 0)
    }

    /// The protocol subtype for MPTCP.
    ///
    /// - Returns: nil if MPTCP is not supported.
    @inlinable
    public static var mptcp: Self? {
        #if os(Linux)
        // Defined by the linux kernel, this is IPPROTO_MPTCP.
        return .init(rawValue: 262)
        #else
        return nil
        #endif
    }
}

extension NIOBSDSocket.ProtocolSubtype {
    /// Construct a protocol subtype from an IP protocol.
    @inlinable
    public init(_ protocol: NIOIPProtocol) {
        self.rawValue = CInt(`protocol`.rawValue)
    }
}

/// This protocol defines the methods that are expected to be found on
/// `NIOBSDSocket`. While defined as a protocol there is no expectation that any
/// object other than `NIOBSDSocket` will implement this protocol: instead, this
/// protocol acts as a reference for what new supported operating systems must
/// implement.
protocol _BSDSocketProtocol {
    static func accept(
        socket s: NIOBSDSocket.Handle,
        address addr: UnsafeMutablePointer<sockaddr>?,
        address_len addrlen: UnsafeMutablePointer<socklen_t>?
    ) throws -> NIOBSDSocket.Handle?

    static func bind(
        socket s: NIOBSDSocket.Handle,
        address addr: UnsafePointer<sockaddr>,
        address_len namelen: socklen_t
    ) throws

    static func close(socket s: NIOBSDSocket.Handle) throws

    static func connect(
        socket s: NIOBSDSocket.Handle,
        address name: UnsafePointer<sockaddr>,
        address_len namelen: socklen_t
    ) throws -> Bool

    static func getpeername(
        socket s: NIOBSDSocket.Handle,
        address name: UnsafeMutablePointer<sockaddr>,
        address_len namelen: UnsafeMutablePointer<socklen_t>
    ) throws

    static func getsockname(
        socket s: NIOBSDSocket.Handle,
        address name: UnsafeMutablePointer<sockaddr>,
        address_len namelen: UnsafeMutablePointer<socklen_t>
    ) throws

    static func getsockopt(
        socket: NIOBSDSocket.Handle,
        level: NIOBSDSocket.OptionLevel,
        option_name optname: NIOBSDSocket.Option,
        option_value optval: UnsafeMutableRawPointer,
        option_len optlen: UnsafeMutablePointer<socklen_t>
    ) throws

    static func listen(socket s: NIOBSDSocket.Handle, backlog: CInt) throws

    static func recv(
        socket s: NIOBSDSocket.Handle,
        buffer buf: UnsafeMutableRawPointer,
        length len: size_t
    ) throws -> IOResult<size_t>

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    static func recvmsg(
        socket: NIOBSDSocket.Handle,
        msgHdr: UnsafeMutablePointer<msghdr>,
        flags: CInt
    )
        throws -> IOResult<size_t>

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    static func sendmsg(
        socket: NIOBSDSocket.Handle,
        msgHdr: UnsafePointer<msghdr>,
        flags: CInt
    )
        throws -> IOResult<size_t>

    static func send(
        socket s: NIOBSDSocket.Handle,
        buffer buf: UnsafeRawPointer,
        length len: size_t
    ) throws -> IOResult<size_t>

    static func setsockopt(
        socket: NIOBSDSocket.Handle,
        level: NIOBSDSocket.OptionLevel,
        option_name optname: NIOBSDSocket.Option,
        option_value optval: UnsafeRawPointer,
        option_len optlen: socklen_t
    ) throws

    static func shutdown(socket: NIOBSDSocket.Handle, how: Shutdown) throws

    static func socket(
        domain af: NIOBSDSocket.ProtocolFamily,
        type: NIOBSDSocket.SocketType,
        protocolSubtype: NIOBSDSocket.ProtocolSubtype
    ) throws -> NIOBSDSocket.Handle

    static func recvmmsg(
        socket: NIOBSDSocket.Handle,
        msgvec: UnsafeMutablePointer<MMsgHdr>,
        vlen: CUnsignedInt,
        flags: CInt,
        timeout: UnsafeMutablePointer<timespec>?
    ) throws -> IOResult<Int>

    static func sendmmsg(
        socket: NIOBSDSocket.Handle,
        msgvec: UnsafeMutablePointer<MMsgHdr>,
        vlen: CUnsignedInt,
        flags: CInt
    ) throws -> IOResult<Int>

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    static func pread(
        socket: NIOBSDSocket.Handle,
        pointer: UnsafeMutableRawPointer,
        size: size_t,
        offset: off_t
    ) throws -> IOResult<size_t>

    // NOTE: this should return a `ssize_t`, however, that is not a standard
    // type, and defining that type is difficult.  Opt to return a `size_t`
    // which is the same size, but is unsigned.
    static func pwrite(
        socket: NIOBSDSocket.Handle,
        pointer: UnsafeRawPointer,
        size: size_t,
        offset: off_t
    ) throws -> IOResult<size_t>

    #if !os(Windows)
    // NOTE: We do not support this on Windows as WSAPoll behaves differently
    // from poll with reporting of failed connections (Connect Report 309411),
    // which recommended that you use NetAPI instead.
    //
    // This is safe to exclude as this is a testing-only API.
    static func poll(
        fds: UnsafeMutablePointer<pollfd>,
        nfds: nfds_t,
        timeout: CInt
    ) throws -> CInt
    #endif

    static func sendfile(
        socket s: NIOBSDSocket.Handle,
        fd: CInt,
        offset: off_t,
        len: off_t
    ) throws -> IOResult<Int>

    // MARK: non-BSD APIs added by NIO

    static func setNonBlocking(socket: NIOBSDSocket.Handle) throws

    static func cleanupUnixDomainSocket(atPath path: String) throws
}

/// If this extension is hitting a compile error, your platform is missing one
/// of the functions defined above!
extension NIOBSDSocket: _BSDSocketProtocol {}

/// This protocol defines the methods that are expected to be found on
/// `NIOBSDControlMessage`. While defined as a protocol there is no expectation
/// that any object other than `NIOBSDControlMessage` will implement this
/// protocol: instead, this protocol acts as a reference for what new supported
/// operating systems must implement.
protocol _BSDSocketControlMessageProtocol {
    static func firstHeader(
        inside msghdr: UnsafePointer<msghdr>
    )
        -> UnsafeMutablePointer<cmsghdr>?

    static func nextHeader(
        inside msghdr: UnsafeMutablePointer<msghdr>,
        after: UnsafeMutablePointer<cmsghdr>
    )
        -> UnsafeMutablePointer<cmsghdr>?

    static func data(
        for header: UnsafePointer<cmsghdr>
    )
        -> UnsafeRawBufferPointer?

    static func data(
        for header: UnsafeMutablePointer<cmsghdr>
    )
        -> UnsafeMutableRawBufferPointer?

    static func length(payloadSize: size_t) -> size_t

    static func space(payloadSize: size_t) -> size_t
}

/// If this extension is hitting a compile error, your platform is missing one
/// of the functions defined above!
enum NIOBSDSocketControlMessage: _BSDSocketControlMessageProtocol {}

/// The requested UDS path exists and has wrong type (not a socket).
public struct UnixDomainSocketPathWrongType: Error {}
