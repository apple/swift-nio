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
#if os(Linux) || os(FreeBSD) || os(Android)
import Glibc
import CNIOLinux
#elseif os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#elseif os(Windows)
import let WinSDK.AF_INET
import let WinSDK.AF_INET6

import let WinSDK.INET_ADDRSTRLEN
import let WinSDK.INET6_ADDRSTRLEN

import struct WinSDK.ADDRESS_FAMILY
import struct WinSDK.IP_ADAPTER_ADDRESSES
import struct WinSDK.IP_ADAPTER_UNICAST_ADDRESS

import typealias WinSDK.UINT8
#endif

#if !os(Windows)
private extension ifaddrs {
    var dstaddr: UnsafeMutablePointer<sockaddr>? {
        #if os(Linux) || os(Android)
        return self.ifa_ifu.ifu_dstaddr
        #elseif os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
        return self.ifa_dstaddr
        #endif
    }

    var broadaddr: UnsafeMutablePointer<sockaddr>? {
        #if os(Linux) || os(Android)
        return self.ifa_ifu.ifu_broadaddr
        #elseif os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
        return self.ifa_dstaddr
        #endif
    }
}
#endif

/// A representation of a single network interface on a system.
@available(*, deprecated, renamed: "NIONetworkDevice")
public final class NIONetworkInterface {
    // This is a class because in almost all cases this will carry
    // four structs that are backed by classes, and so will incur 4
    // refcount operations each time it is copied.

    /// The name of the network interface.
    public let name: String

    /// The address associated with the given network interface.
    public let address: SocketAddress

    /// The netmask associated with this address, if any.
    public let netmask: SocketAddress?

    /// The broadcast address associated with this socket interface, if it has one. Some
    /// interfaces do not, especially those that have a `pointToPointDestinationAddress`.
    public let broadcastAddress: SocketAddress?

    /// The address of the peer on a point-to-point interface, if this is one. Some
    /// interfaces do not have such an address: most of those have a `broadcastAddress`
    /// instead.
    public let pointToPointDestinationAddress: SocketAddress?

    /// If the Interface supports Multicast
    public let multicastSupported: Bool

    /// The index of the interface, as provided by `if_nametoindex`.
    public let interfaceIndex: Int

    fileprivate init?(_ caddr: ifaddrs) {
        self.name = String(cString: caddr.ifa_name)

        guard caddr.ifa_addr != nil else {
            return nil
        }

        guard let address = caddr.ifa_addr!.convert() else {
            return nil
        }
        self.address = address

        if let netmask = caddr.ifa_netmask {
            self.netmask = netmask.convert()
        } else {
            self.netmask = nil
        }

        if (caddr.ifa_flags & UInt32(IFF_BROADCAST)) != 0, let addr = caddr.broadaddr {
            self.broadcastAddress = addr.convert()
            self.pointToPointDestinationAddress = nil
        } else if (caddr.ifa_flags & UInt32(IFF_POINTOPOINT)) != 0, let addr = caddr.dstaddr {
            self.broadcastAddress = nil
            self.pointToPointDestinationAddress = addr.convert()
        } else {
            self.broadcastAddress = nil
            self.pointToPointDestinationAddress = nil
        }

        if (caddr.ifa_flags & UInt32(IFF_MULTICAST)) != 0 {
            self.multicastSupported = true
        } else {
            self.multicastSupported = false
        }

        do {
            self.interfaceIndex = Int(try SystemCalls.if_nametoindex(caddr.ifa_name))
        } catch {
            return nil
        }
    }

    // This is public just so we can avoid needing to pull over any of the System helpers: they can
    // construct this type directly. Ideally, we'd have avoided even needing this in NIOCore.
    public static func _construct(from caddr: ifaddrs) -> NIONetworkInterface? {
        return NIONetworkInterface(caddr)
    }
}

@available(*, deprecated, renamed: "NIONetworkDevice")
extension NIONetworkInterface: CustomDebugStringConvertible {
    public var debugDescription: String {
        let baseString = "Interface \(self.name): address \(self.address)"
        let maskString = self.netmask != nil ? " netmask \(self.netmask!)" : ""
        return baseString + maskString
    }
}

@available(*, deprecated, renamed: "NIONetworkDevice")
extension NIONetworkInterface: Equatable {
    public static func ==(lhs: NIONetworkInterface, rhs: NIONetworkInterface) -> Bool {
        return lhs.name == rhs.name &&
               lhs.address == rhs.address &&
               lhs.netmask == rhs.netmask &&
               lhs.broadcastAddress == rhs.broadcastAddress &&
               lhs.pointToPointDestinationAddress == rhs.pointToPointDestinationAddress &&
               lhs.interfaceIndex == rhs.interfaceIndex
    }
}

/// A helper extension for working with sockaddr pointers.
extension UnsafeMutablePointer where Pointee == sockaddr {
    /// Converts the `sockaddr` to a `SocketAddress`.
    fileprivate func convert() -> SocketAddress? {
        switch NIOBSDSocket.AddressFamily(rawValue: CInt(pointee.sa_family)) {
        case .inet:
            return self.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                SocketAddress($0.pointee)
            }
        case .inet6:
            return self.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                SocketAddress($0.pointee)
            }
        case .unix:
            return self.withMemoryRebound(to: sockaddr_un.self, capacity: 1) {
                SocketAddress($0.pointee)
            }
        default:
            return nil
        }
    }
}
