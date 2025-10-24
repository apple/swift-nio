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

#if os(Windows)
import ucrt

import let WinSDK.IPPROTO_IP
import let WinSDK.IPPROTO_IPV6
import let WinSDK.IPPROTO_TCP
import let WinSDK.IPPROTO_UDP

import let WinSDK.IP_ADD_MEMBERSHIP
import let WinSDK.IP_DROP_MEMBERSHIP
import let WinSDK.IP_HDRINCL
import let WinSDK.IP_MULTICAST_IF
import let WinSDK.IP_MULTICAST_LOOP
import let WinSDK.IP_MULTICAST_TTL
import let WinSDK.IPV6_JOIN_GROUP
import let WinSDK.IPV6_LEAVE_GROUP
import let WinSDK.IPV6_MULTICAST_HOPS
import let WinSDK.IPV6_MULTICAST_IF
import let WinSDK.IPV6_MULTICAST_LOOP
import let WinSDK.IPV6_V6ONLY

import let WinSDK.AF_INET
import let WinSDK.AF_INET6
import let WinSDK.AF_UNIX

import let WinSDK.PF_INET
import let WinSDK.PF_INET6
import let WinSDK.PF_UNIX

import let WinSDK.SO_BROADCAST
import let WinSDK.SO_ERROR
import let WinSDK.SO_KEEPALIVE
import let WinSDK.SO_LINGER
import let WinSDK.SO_RCVBUF
import let WinSDK.SO_RCVTIMEO
import let WinSDK.SO_REUSEADDR
import let WinSDK.SO_SNDBUF

import let WinSDK.SOL_SOCKET

import let WinSDK.TCP_NODELAY

import struct WinSDK.SOCKET

import func WinSDK.inet_ntop
import func WinSDK.inet_pton

import func WinSDK.GetLastError
import func WinSDK.WSAGetLastError

internal typealias socklen_t = ucrt.size_t
#elseif os(Linux) || os(Android)
#if canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Android)
@preconcurrency import Android
#endif
import CNIOLinux

#if os(Android)
private let sysInet_ntop:
    @convention(c) (CInt, UnsafeRawPointer, UnsafeMutablePointer<CChar>, socklen_t) -> UnsafePointer<CChar>? = inet_ntop
private let sysInet_pton: @convention(c) (CInt, UnsafePointer<CChar>, UnsafeMutableRawPointer) -> CInt = inet_pton
#else
private let sysInet_ntop:
    @convention(c) (CInt, UnsafeRawPointer?, UnsafeMutablePointer<CChar>?, socklen_t) -> UnsafePointer<CChar>? =
        inet_ntop
private let sysInet_pton: @convention(c) (CInt, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> CInt = inet_pton
#endif
#elseif os(OpenBSD)
@preconcurrency import Glibc
import CNIOOpenBSD

private let sysInet_ntop:
    @convention(c) (CInt, UnsafeRawPointer?, UnsafeMutablePointer<CChar>?, socklen_t) -> UnsafePointer<CChar>? =
        inet_ntop
private let sysInet_pton: @convention(c) (CInt, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> CInt = inet_pton
#elseif canImport(Darwin)
import Darwin

private let sysInet_ntop:
    @convention(c) (CInt, UnsafeRawPointer?, UnsafeMutablePointer<CChar>?, socklen_t) -> UnsafePointer<CChar>? =
        inet_ntop
private let sysInet_pton: @convention(c) (CInt, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> CInt = inet_pton
#elseif canImport(WASILibc)
@preconcurrency import WASILibc

private let sysInet_ntop:
    @convention(c) (CInt, UnsafeRawPointer?, UnsafeMutablePointer<CChar>?, socklen_t) -> UnsafePointer<CChar>? =
        inet_ntop
private let sysInet_pton: @convention(c) (CInt, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> CInt = inet_pton
#else
#error("The BSD Socket module was unable to identify your C library.")
#endif

#if os(Android)
@usableFromInline let IFF_BROADCAST: CUnsignedInt = numericCast(Android.IFF_BROADCAST.rawValue)
@usableFromInline let IFF_POINTOPOINT: CUnsignedInt = numericCast(Android.IFF_POINTOPOINT.rawValue)
@usableFromInline let IFF_MULTICAST: CUnsignedInt = numericCast(Android.IFF_MULTICAST.rawValue)
#if arch(arm)
@usableFromInline let SO_RCVTIMEO = SO_RCVTIMEO_OLD
@usableFromInline let SO_TIMESTAMP = SO_TIMESTAMP_OLD
#endif
#elseif os(Linux)
// Work around SO_TIMESTAMP/SO_RCVTIMEO being awkwardly defined in glibc.
@usableFromInline let SO_TIMESTAMP = CNIOLinux_SO_TIMESTAMP
@usableFromInline let SO_RCVTIMEO = CNIOLinux_SO_RCVTIMEO
#endif

public enum NIOBSDSocket: Sendable {
    #if os(Windows)
    public typealias Handle = SOCKET
    #else
    public typealias Handle = CInt
    #endif
}

extension NIOBSDSocket {
    /// Specifies the addressing scheme that the socket can use.
    public struct AddressFamily: RawRepresentable, Sendable {
        public typealias RawValue = CInt
        public var rawValue: RawValue

        @inlinable
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
    public struct ProtocolFamily: RawRepresentable, Sendable {
        public typealias RawValue = CInt
        public var rawValue: RawValue

        @inlinable
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
    public struct OptionLevel: RawRepresentable, Sendable {
        public typealias RawValue = CInt
        public var rawValue: RawValue

        @inlinable
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
    public struct Option: RawRepresentable, Sendable {
        public typealias RawValue = CInt
        public var rawValue: RawValue

        @inlinable
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
    @inlinable
    public static var inet: NIOBSDSocket.AddressFamily {
        NIOBSDSocket.AddressFamily(rawValue: AF_INET)
    }

    /// Address for IP version 6.
    @inlinable
    public static var inet6: NIOBSDSocket.AddressFamily {
        NIOBSDSocket.AddressFamily(rawValue: AF_INET6)
    }

    /// Unix local to host address.
    @inlinable
    public static var unix: NIOBSDSocket.AddressFamily {
        NIOBSDSocket.AddressFamily(rawValue: AF_UNIX)
    }
}

// Protocol Family
extension NIOBSDSocket.ProtocolFamily {
    /// IP network 4 protocol.
    @inlinable
    public static var inet: NIOBSDSocket.ProtocolFamily {
        NIOBSDSocket.ProtocolFamily(rawValue: PF_INET)
    }

    /// IP network 6 protocol.
    @inlinable
    public static var inet6: NIOBSDSocket.ProtocolFamily {
        NIOBSDSocket.ProtocolFamily(rawValue: PF_INET6)
    }

    #if !os(WASI)
    /// UNIX local to the host.
    @inlinable
    public static var unix: NIOBSDSocket.ProtocolFamily {
        NIOBSDSocket.ProtocolFamily(rawValue: PF_UNIX)
    }
    #endif
}

#if !os(Windows) && !os(WASI)
extension NIOBSDSocket.ProtocolFamily {
    /// UNIX local to the host, alias for `PF_UNIX` (`.unix`)
    @inlinable
    public static var local: NIOBSDSocket.ProtocolFamily {
        NIOBSDSocket.ProtocolFamily(rawValue: PF_LOCAL)
    }
}
#endif

// Option Level
extension NIOBSDSocket.OptionLevel {
    /// Socket options that apply only to IP sockets.
    #if os(Linux) || os(Android)
    @inlinable
    public static var ip: NIOBSDSocket.OptionLevel {
        NIOBSDSocket.OptionLevel(rawValue: CInt(IPPROTO_IP))
    }
    #else
    @inlinable
    public static var ip: NIOBSDSocket.OptionLevel {
        NIOBSDSocket.OptionLevel(rawValue: IPPROTO_IP)
    }
    #endif

    /// Socket options that apply only to IPv6 sockets.
    #if os(Linux) || os(Android)
    @inlinable
    public static var ipv6: NIOBSDSocket.OptionLevel {
        NIOBSDSocket.OptionLevel(rawValue: CInt(IPPROTO_IPV6))
    }
    #elseif os(Windows)
    @inlinable
    public static var ipv6: NIOBSDSocket.OptionLevel {
        NIOBSDSocket.OptionLevel(rawValue: IPPROTO_IPV6.rawValue)
    }
    #else
    @inlinable
    public static var ipv6: NIOBSDSocket.OptionLevel {
        NIOBSDSocket.OptionLevel(rawValue: IPPROTO_IPV6)
    }
    #endif

    /// Socket options that apply only to TCP sockets.
    #if os(Linux) || os(Android)
    @inlinable
    public static var tcp: NIOBSDSocket.OptionLevel {
        NIOBSDSocket.OptionLevel(rawValue: CInt(IPPROTO_TCP))
    }
    #elseif os(Windows)
    @inlinable
    public static var tcp: NIOBSDSocket.OptionLevel {
        NIOBSDSocket.OptionLevel(rawValue: IPPROTO_TCP.rawValue)
    }
    #else
    @inlinable
    public static var tcp: NIOBSDSocket.OptionLevel {
        NIOBSDSocket.OptionLevel(rawValue: IPPROTO_TCP)
    }
    #endif

    /// Socket options that apply to MPTCP sockets.
    ///
    /// These only work on Linux currently.
    @inlinable
    public static var mptcp: NIOBSDSocket.OptionLevel {
        NIOBSDSocket.OptionLevel(rawValue: 284)
    }

    /// Socket options that apply to all sockets.
    @inlinable
    public static var socket: NIOBSDSocket.OptionLevel {
        NIOBSDSocket.OptionLevel(rawValue: SOL_SOCKET)
    }

    /// Socket options that apply only to UDP sockets.
    #if os(Linux) || os(Android)
    @inlinable
    public static var udp: NIOBSDSocket.OptionLevel {
        NIOBSDSocket.OptionLevel(rawValue: CInt(IPPROTO_UDP))
    }
    #elseif os(Windows)
    @inlinable
    public static var udp: NIOBSDSocket.OptionLevel {
        NIOBSDSocket.OptionLevel(rawValue: IPPROTO_UDP.rawValue)
    }
    #else
    @inlinable
    public static var udp: NIOBSDSocket.OptionLevel {
        NIOBSDSocket.OptionLevel(rawValue: IPPROTO_UDP)
    }
    #endif
}

// IPv4 Options
extension NIOBSDSocket.Option {
    /// Add a multicast group membership.
    @inlinable
    public static var ip_add_membership: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: IP_ADD_MEMBERSHIP)
    }

    /// Drop a multicast group membership.
    @inlinable
    public static var ip_drop_membership: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: IP_DROP_MEMBERSHIP)
    }

    /// Set the interface for outgoing multicast packets.
    @inlinable
    public static var ip_multicast_if: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: IP_MULTICAST_IF)
    }

    /// Control multicast loopback.
    @inlinable
    public static var ip_multicast_loop: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: IP_MULTICAST_LOOP)
    }

    /// Control multicast time-to-live.
    @inlinable
    public static var ip_multicast_ttl: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: IP_MULTICAST_TTL)
    }

    /// The IPv4 layer generates an IP header when sending a packet
    /// unless the ``ip_hdrincl`` socket option is enabled on the socket.
    /// When it is enabled, the packet must contain an IP header.  For
    /// receiving, the IP header is always included in the packet.
    @inlinable
    public static var ip_hdrincl: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: IP_HDRINCL)
    }
}

// IPv6 Options
extension NIOBSDSocket.Option {
    /// Add an IPv6 group membership.
    @inlinable
    public static var ipv6_join_group: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: IPV6_JOIN_GROUP)
    }

    /// Drop an IPv6 group membership.
    @inlinable
    public static var ipv6_leave_group: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: IPV6_LEAVE_GROUP)
    }

    /// Specify the maximum number of router hops for an IPv6 packet.
    @inlinable
    public static var ipv6_multicast_hops: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: IPV6_MULTICAST_HOPS)
    }

    /// Set the interface for outgoing multicast packets.
    @inlinable
    public static var ipv6_multicast_if: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: IPV6_MULTICAST_IF)
    }

    /// Control multicast loopback.
    @inlinable
    public static var ipv6_multicast_loop: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: IPV6_MULTICAST_LOOP)
    }

    /// Indicates if a socket created for the `AF_INET6` address family is
    /// restricted to IPv6 only.
    @inlinable
    public static var ipv6_v6only: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: IPV6_V6ONLY)
    }
}

// TCP Options
extension NIOBSDSocket.Option {
    /// Disables the Nagle algorithm for send coalescing.
    @inlinable
    public static var tcp_nodelay: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: TCP_NODELAY)
    }
}

#if os(Linux) || os(FreeBSD) || os(Android)
extension NIOBSDSocket.Option {
    /// Get information about the TCP connection.
    @inlinable
    public static var tcp_info: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: TCP_INFO)
    }
}
#endif

#if canImport(Darwin)
extension NIOBSDSocket.Option {
    /// Get information about the TCP connection.
    @inlinable
    public static var tcp_connection_info: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: TCP_CONNECTION_INFO)
    }
}
#endif

#if os(Linux)
extension NIOBSDSocket.Option {
    // Note: UDP_SEGMENT and UDP_GRO are not available on all Linux platforms so values are
    // hardcoded.

    /// Use UDP segmentation offload (UDP_SEGMENT, or 'GSO'). Only available on Linux.
    @inlinable
    public static var udp_segment: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: 103)
    }

    /// Use UDP generic receive offload (GRO). Only available on Linux.
    @inlinable
    public static var udp_gro: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: 104)
    }
}
#endif

// MPTCP options
//
// These values are hardcoded as they're fairly new, and not available in all
// header files yet.
extension NIOBSDSocket.Option {
    /// Get info about an MPTCP connection
    @inlinable
    public static var mptcp_info: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: 1)
    }
}

#if !os(WASI)
// Socket Options
extension NIOBSDSocket.Option {
    /// Get the error status and clear.
    @inlinable
    public static var so_error: NIOBSDSocket.Option {
        Self(rawValue: SO_ERROR)
    }

    /// Use keep-alives.
    @inlinable
    public static var so_keepalive: NIOBSDSocket.Option {
        Self(rawValue: SO_KEEPALIVE)
    }

    /// Linger on close if unsent data is present.
    @inlinable
    public static var so_linger: NIOBSDSocket.Option {
        Self(rawValue: SO_LINGER)
    }

    /// Specifies the total per-socket buffer space reserved for receives.
    @inlinable
    public static var so_rcvbuf: NIOBSDSocket.Option {
        Self(rawValue: SO_RCVBUF)
    }

    /// Specifies the total per-socket buffer space reserved for sends.
    @inlinable
    public static var so_sndbuf: NIOBSDSocket.Option {
        Self(rawValue: SO_SNDBUF)
    }

    /// Specifies the receive timeout.
    @inlinable
    public static var so_rcvtimeo: NIOBSDSocket.Option {
        Self(rawValue: SO_RCVTIMEO)
    }

    /// Allows the socket to be bound to an address that is already in use.
    @inlinable
    public static var so_reuseaddr: NIOBSDSocket.Option {
        Self(rawValue: SO_REUSEADDR)
    }

    /// Allows the socket to send broadcast messages.
    @inlinable
    public static var so_broadcast: NIOBSDSocket.Option {
        Self(rawValue: SO_BROADCAST)
    }
}
#endif

#if !os(Windows) && !os(WASI)
extension NIOBSDSocket.Option {
    /// Indicate when to generate timestamps.
    @inlinable
    public static var so_timestamp: NIOBSDSocket.Option {
        NIOBSDSocket.Option(rawValue: SO_TIMESTAMP)
    }
}
#endif

extension NIOBSDSocket {
    // Sadly this was defined on BSDSocket, and we need it for SocketAddress.
    @inline(never)
    internal static func inet_pton(
        addressFamily: NIOBSDSocket.AddressFamily,
        addressDescription: UnsafePointer<CChar>,
        address: UnsafeMutableRawPointer
    ) throws {
        #if os(Windows)
        // TODO(compnerd) use `InetPtonW` to ensure that we handle unicode properly
        switch WinSDK.inet_pton(addressFamily.rawValue, addressDescription, address) {
        case 0: throw IOError(errnoCode: EINVAL, reason: "inet_pton")
        case 1: return
        default: throw IOError(winsock: WSAGetLastError(), reason: "inet_pton")
        }
        #else
        switch sysInet_pton(CInt(addressFamily.rawValue), addressDescription, address) {
        case 0: throw IOError(errnoCode: EINVAL, reason: #function)
        case 1: return
        default: throw IOError(errnoCode: errno, reason: #function)
        }
        #endif
    }

    @discardableResult
    @inline(never)
    internal static func inet_ntop(
        addressFamily: NIOBSDSocket.AddressFamily,
        addressBytes: UnsafeRawPointer,
        addressDescription: UnsafeMutablePointer<CChar>,
        addressDescriptionLength: socklen_t
    ) throws -> UnsafePointer<CChar> {
        #if os(Windows)
        // TODO(compnerd) use `InetNtopW` to ensure that we handle unicode properly
        guard
            let result = WinSDK.inet_ntop(
                addressFamily.rawValue,
                addressBytes,
                addressDescription,
                Int(addressDescriptionLength)
            )
        else {
            throw IOError(windows: GetLastError(), reason: "inet_ntop")
        }
        return result
        #else
        switch sysInet_ntop(CInt(addressFamily.rawValue), addressBytes, addressDescription, addressDescriptionLength) {
        case .none: throw IOError(errnoCode: errno, reason: #function)
        case .some(let ptr): return ptr
        }
        #endif
    }
}
