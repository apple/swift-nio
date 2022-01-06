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

import let WinSDK.AF_INET
import let WinSDK.AF_INET6
import let WinSDK.AF_UNIX

import let WinSDK.PF_INET
import let WinSDK.PF_INET6
import let WinSDK.PF_UNIX

import let WinSDK.SO_ERROR
import let WinSDK.SO_KEEPALIVE
import let WinSDK.SO_LINGER
import let WinSDK.SO_RCVBUF
import let WinSDK.SO_RCVTIMEO
import let WinSDK.SO_REUSEADDR

import let WinSDK.SOL_SOCKET

import let WinSDK.TCP_NODELAY

import struct WinSDK.SOCKET

import func WinSDK.inet_ntop
import func WinSDK.inet_pton
#elseif os(Linux) || os(Android)
import Glibc
import CNIOLinux

private let sysInet_ntop: @convention(c) (CInt, UnsafeRawPointer?, UnsafeMutablePointer<CChar>?, socklen_t) -> UnsafePointer<CChar>? = inet_ntop
private let sysInet_pton: @convention(c) (CInt, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> CInt = inet_pton
#elseif os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin

private let sysInet_ntop: @convention(c) (CInt, UnsafeRawPointer?, UnsafeMutablePointer<CChar>?, socklen_t) -> UnsafePointer<CChar>? = inet_ntop
private let sysInet_pton: @convention(c) (CInt, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> CInt = inet_pton
#endif

#if os(Android)
let IFF_BROADCAST: CUnsignedInt = numericCast(SwiftGlibc.IFF_BROADCAST.rawValue)
let IFF_POINTOPOINT: CUnsignedInt = numericCast(SwiftGlibc.IFF_POINTOPOINT.rawValue)
let IFF_MULTICAST: CUnsignedInt = numericCast(SwiftGlibc.IFF_MULTICAST.rawValue)
#if arch(arm)
let SO_RCVTIMEO = SO_RCVTIMEO_OLD
let SO_TIMESTAMP = SO_TIMESTAMP_OLD
#endif
#elseif os(Linux)
// Work around SO_TIMESTAMP/SO_RCVTIMEO being awkwardly defined in glibc.
let SO_TIMESTAMP = CNIOLinux_SO_TIMESTAMP
let SO_RCVTIMEO = CNIOLinux_SO_RCVTIMEO
#endif

public enum NIOBSDSocket {
#if os(Windows)
    public typealias Handle = SOCKET
#else
    public typealias Handle = CInt
#endif
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

extension NIOBSDSocket {
    // Sadly this was defined on BSDSocket, and we need it for SocketAddress.
    @inline(never)
    internal static func inet_pton(addressFamily: NIOBSDSocket.AddressFamily, addressDescription: UnsafePointer<CChar>, address: UnsafeMutableRawPointer) throws {
        #if os(Windows)
        // TODO(compnerd) use `InetPtonW` to ensure that we handle unicode properly
        switch WinSDK.inet_pton(family.rawValue, addressDescription, address) {
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
    internal static func inet_ntop(addressFamily: NIOBSDSocket.AddressFamily, addressBytes: UnsafeRawPointer, addressDescription: UnsafeMutablePointer<CChar>, addressDescriptionLength: socklen_t) throws -> UnsafePointer<CChar> {
        #if os(Windows)
        // TODO(compnerd) use `InetNtopW` to ensure that we handle unicode properly
        guard let result = WinSDK.inet_ntop(family.rawValue, addressBytes, addressDescription,
                                            Int(addressDescriptionLength)) else {
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
