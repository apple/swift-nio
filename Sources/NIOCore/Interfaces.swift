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
#if canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Bionic)
@preconcurrency import Bionic
#endif
import CNIOLinux
#elseif os(OpenBSD)
import CNIOOpenBSD
#elseif canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
@preconcurrency import WASILibc
#elseif os(Windows)
import let WinSDK.AF_INET
import let WinSDK.AF_INET6

import let WinSDK.INET_ADDRSTRLEN
import let WinSDK.INET6_ADDRSTRLEN

import struct WinSDK.ADDRESS_FAMILY
import struct WinSDK.IP_ADAPTER_ADDRESSES
import struct WinSDK.IP_ADAPTER_UNICAST_ADDRESS

import struct WinSDK.sockaddr
import struct WinSDK.sockaddr_in
import struct WinSDK.sockaddr_in6
import struct WinSDK.sockaddr_storage
import struct WinSDK.sockaddr_un

import typealias WinSDK.UINT8
#else
#error("The Core interfaces module was unable to identify your C library.")
#endif

#if !os(Windows) && !os(WASI)
extension ifaddrs {
    fileprivate var dstaddr: UnsafeMutablePointer<sockaddr>? {
        #if os(Linux) || os(Android)
        return self.ifa_ifu.ifu_dstaddr
        #elseif canImport(Darwin) || os(OpenBSD)
        return self.ifa_dstaddr
        #endif
    }

    fileprivate var broadaddr: UnsafeMutablePointer<sockaddr>? {
        #if os(Linux) || os(Android)
        return self.ifa_ifu.ifu_broadaddr
        #elseif canImport(Darwin) || os(OpenBSD)
        return self.ifa_dstaddr
        #endif
    }
}
#endif

/// A representation of a single network interface on a system.
@available(*, deprecated, renamed: "NIONetworkDevice")
public final class NIONetworkInterface: Sendable {
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

    #if os(WASI)
    @available(*, unavailable)
    init() { fatalError() }
    #endif

    #if os(Windows)
    internal init?(
        _ pAdapter: UnsafeMutablePointer<IP_ADAPTER_ADDRESSES>,
        _ pAddress: UnsafeMutablePointer<IP_ADAPTER_UNICAST_ADDRESS>
    ) {
        self.name = String(
            decodingCString: pAdapter.pointee.FriendlyName,
            as: UTF16.self
        )
        guard let address = pAddress.pointee.Address.lpSockaddr.convert() else {
            return nil
        }
        self.address = address

        switch pAddress.pointee.Address.lpSockaddr.pointee.sa_family {
        case ADDRESS_FAMILY(AF_INET):
            self.netmask = SocketAddress(ipv4MaskForPrefix: Int(pAddress.pointee.OnLinkPrefixLength))
            self.interfaceIndex = Int(pAdapter.pointee.IfIndex)
            break
        case ADDRESS_FAMILY(AF_INET6):
            self.netmask = SocketAddress(ipv6MaskForPrefix: Int(pAddress.pointee.OnLinkPrefixLength))
            self.interfaceIndex = Int(pAdapter.pointee.Ipv6IfIndex)
            break
        default:
            return nil
        }

        // TODO(compnerd) handle broadcast/ppp/multicast information
        self.broadcastAddress = nil
        self.pointToPointDestinationAddress = nil
        self.multicastSupported = false
    }
    #elseif !os(WASI)
    internal init?(_ caddr: ifaddrs) {
        self.name = String(cString: caddr.ifa_name!)

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
    #endif
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
    public static func == (lhs: NIONetworkInterface, rhs: NIONetworkInterface) -> Bool {
        lhs.name == rhs.name && lhs.address == rhs.address && lhs.netmask == rhs.netmask
            && lhs.broadcastAddress == rhs.broadcastAddress
            && lhs.pointToPointDestinationAddress == rhs.pointToPointDestinationAddress
            && lhs.interfaceIndex == rhs.interfaceIndex
    }
}

/// A helper extension for working with sockaddr pointers.
extension UnsafeMutablePointer where Pointee == sockaddr {
    /// Converts the `sockaddr` to a `SocketAddress`.
    fileprivate func convert() -> SocketAddress? {
        let addressBytes = UnsafeRawPointer(self)
        switch NIOBSDSocket.AddressFamily(rawValue: CInt(pointee.sa_family)) {
        case .inet:
            return SocketAddress(addressBytes.load(as: sockaddr_in.self))
        case .inet6:
            return SocketAddress(addressBytes.load(as: sockaddr_in6.self))
        case .unix:
            return SocketAddress(addressBytes.load(as: sockaddr_un.self))
        default:
            return nil
        }
    }
}

/// A representation of a single network device on a system.
public struct NIONetworkDevice {
    private var backing: Backing

    /// The name of the network device.
    public var name: String {
        get {
            self.backing.name
        }
        set {
            self.uniquifyIfNeeded()
            self.backing.name = newValue
        }
    }

    /// The address associated with the given network device.
    public var address: SocketAddress? {
        get {
            self.backing.address
        }
        set {
            self.uniquifyIfNeeded()
            self.backing.address = newValue
        }
    }

    /// The netmask associated with this address, if any.
    public var netmask: SocketAddress? {
        get {
            self.backing.netmask
        }
        set {
            self.uniquifyIfNeeded()
            self.backing.netmask = newValue
        }
    }

    /// The broadcast address associated with this socket interface, if it has one. Some
    /// interfaces do not, especially those that have a `pointToPointDestinationAddress`.
    public var broadcastAddress: SocketAddress? {
        get {
            self.backing.broadcastAddress
        }
        set {
            self.uniquifyIfNeeded()
            self.backing.broadcastAddress = newValue
        }
    }

    /// The address of the peer on a point-to-point interface, if this is one. Some
    /// interfaces do not have such an address: most of those have a `broadcastAddress`
    /// instead.
    public var pointToPointDestinationAddress: SocketAddress? {
        get {
            self.backing.pointToPointDestinationAddress
        }
        set {
            self.uniquifyIfNeeded()
            self.backing.pointToPointDestinationAddress = newValue
        }
    }

    /// If the Interface supports Multicast
    public var multicastSupported: Bool {
        get {
            self.backing.multicastSupported
        }
        set {
            self.uniquifyIfNeeded()
            self.backing.multicastSupported = newValue
        }
    }

    /// The index of the interface, as provided by `if_nametoindex`.
    public var interfaceIndex: Int {
        get {
            self.backing.interfaceIndex
        }
        set {
            self.uniquifyIfNeeded()
            self.backing.interfaceIndex = newValue
        }
    }

    /// Create a brand new network interface.
    ///
    /// This constructor will fail if NIO does not understand the format of the underlying
    /// socket address family. This is quite common: for example, Linux will return AF_PACKET
    /// addressed interfaces on most platforms, which NIO does not currently understand.
    #if os(Windows)
    internal init?(
        _ pAdapter: UnsafeMutablePointer<IP_ADAPTER_ADDRESSES>,
        _ pAddress: UnsafeMutablePointer<IP_ADAPTER_UNICAST_ADDRESS>
    ) {
        guard let backing = Backing(pAdapter, pAddress) else {
            return nil
        }
        self.backing = backing
    }
    #elseif !os(WASI)
    internal init?(_ caddr: ifaddrs) {
        guard let backing = Backing(caddr) else {
            return nil
        }

        self.backing = backing
    }
    #endif

    #if !os(Windows) && !os(WASI)
    /// Convert a `NIONetworkInterface` to a `NIONetworkDevice`. As `NIONetworkDevice`s are a superset of `NIONetworkInterface`s,
    /// it is always possible to perform this conversion.
    @available(*, deprecated, message: "This is a compatibility helper, and will be removed in a future release")
    public init(_ interface: NIONetworkInterface) {
        self.backing = Backing(
            name: interface.name,
            address: interface.address,
            netmask: interface.netmask,
            broadcastAddress: interface.broadcastAddress,
            pointToPointDestinationAddress: interface.pointToPointDestinationAddress,
            multicastSupported: interface.multicastSupported,
            interfaceIndex: interface.interfaceIndex
        )
    }
    #endif

    public init(
        name: String,
        address: SocketAddress?,
        netmask: SocketAddress?,
        broadcastAddress: SocketAddress?,
        pointToPointDestinationAddress: SocketAddress,
        multicastSupported: Bool,
        interfaceIndex: Int
    ) {
        self.backing = Backing(
            name: name,
            address: address,
            netmask: netmask,
            broadcastAddress: broadcastAddress,
            pointToPointDestinationAddress: pointToPointDestinationAddress,
            multicastSupported: multicastSupported,
            interfaceIndex: interfaceIndex
        )
    }

    private mutating func uniquifyIfNeeded() {
        if !isKnownUniquelyReferenced(&self.backing) {
            self.backing = Backing(copying: self.backing)
        }
    }
}

extension NIONetworkDevice: @unchecked Sendable {}

extension NIONetworkDevice {
    fileprivate final class Backing {
        /// The name of the network interface.
        var name: String

        /// The address associated with the given network interface.
        var address: SocketAddress?

        /// The netmask associated with this address, if any.
        var netmask: SocketAddress?

        /// The broadcast address associated with this socket interface, if it has one. Some
        /// interfaces do not, especially those that have a `pointToPointDestinationAddress`.
        var broadcastAddress: SocketAddress?

        /// The address of the peer on a point-to-point interface, if this is one. Some
        /// interfaces do not have such an address: most of those have a `broadcastAddress`
        /// instead.
        var pointToPointDestinationAddress: SocketAddress?

        /// If the Interface supports Multicast
        var multicastSupported: Bool

        /// The index of the interface, as provided by `if_nametoindex`.
        var interfaceIndex: Int

        /// Create a brand new network interface.
        ///
        /// This constructor will fail if NIO does not understand the format of the underlying
        /// socket address family. This is quite common: for example, Linux will return AF_PACKET
        /// addressed interfaces on most platforms, which NIO does not currently understand.
        #if os(Windows)
        internal init?(
            _ pAdapter: UnsafeMutablePointer<IP_ADAPTER_ADDRESSES>,
            _ pAddress: UnsafeMutablePointer<IP_ADAPTER_UNICAST_ADDRESS>
        ) {
            self.name = String(
                decodingCString: pAdapter.pointee.FriendlyName,
                as: UTF16.self
            )
            self.address = pAddress.pointee.Address.lpSockaddr.convert()

            switch pAddress.pointee.Address.lpSockaddr.pointee.sa_family {
            case ADDRESS_FAMILY(AF_INET):
                self.netmask = SocketAddress(ipv4MaskForPrefix: Int(pAddress.pointee.OnLinkPrefixLength))
                self.interfaceIndex = Int(pAdapter.pointee.IfIndex)
                break
            case ADDRESS_FAMILY(AF_INET6):
                self.netmask = SocketAddress(ipv6MaskForPrefix: Int(pAddress.pointee.OnLinkPrefixLength))
                self.interfaceIndex = Int(pAdapter.pointee.Ipv6IfIndex)
                break
            default:
                return nil
            }

            // TODO(compnerd) handle broadcast/ppp/multicast information
            self.broadcastAddress = nil
            self.pointToPointDestinationAddress = nil
            self.multicastSupported = false
        }
        #elseif !os(WASI)
        internal init?(_ caddr: ifaddrs) {
            self.name = String(cString: caddr.ifa_name!)
            self.address = caddr.ifa_addr.flatMap { $0.convert() }
            self.netmask = caddr.ifa_netmask.flatMap { $0.convert() }

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

            self.multicastSupported = (caddr.ifa_flags & UInt32(IFF_MULTICAST)) != 0
            do {
                self.interfaceIndex = Int(try SystemCalls.if_nametoindex(caddr.ifa_name))
            } catch {
                return nil
            }
        }
        #endif

        init(copying original: Backing) {
            self.name = original.name
            self.address = original.address
            self.netmask = original.netmask
            self.broadcastAddress = original.broadcastAddress
            self.pointToPointDestinationAddress = original.pointToPointDestinationAddress
            self.multicastSupported = original.multicastSupported
            self.interfaceIndex = original.interfaceIndex
        }

        init(
            name: String,
            address: SocketAddress?,
            netmask: SocketAddress?,
            broadcastAddress: SocketAddress?,
            pointToPointDestinationAddress: SocketAddress?,
            multicastSupported: Bool,
            interfaceIndex: Int
        ) {
            self.name = name
            self.address = address
            self.netmask = netmask
            self.broadcastAddress = broadcastAddress
            self.pointToPointDestinationAddress = pointToPointDestinationAddress
            self.multicastSupported = multicastSupported
            self.interfaceIndex = interfaceIndex
        }
    }
}

extension NIONetworkDevice: CustomDebugStringConvertible {
    public var debugDescription: String {
        let baseString = "Device \(self.name): address \(String(describing: self.address))"
        let maskString = self.netmask != nil ? " netmask \(self.netmask!)" : ""
        return baseString + maskString
    }
}

// Sadly, as this is class-backed we cannot synthesise the implementation.
extension NIONetworkDevice: Equatable {
    public static func == (lhs: NIONetworkDevice, rhs: NIONetworkDevice) -> Bool {
        lhs.name == rhs.name && lhs.address == rhs.address && lhs.netmask == rhs.netmask
            && lhs.broadcastAddress == rhs.broadcastAddress
            && lhs.pointToPointDestinationAddress == rhs.pointToPointDestinationAddress
            && lhs.interfaceIndex == rhs.interfaceIndex
    }
}

extension NIONetworkDevice: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.name)
        hasher.combine(self.address)
        hasher.combine(self.netmask)
        hasher.combine(self.broadcastAddress)
        hasher.combine(self.pointToPointDestinationAddress)
        hasher.combine(self.interfaceIndex)
    }
}
