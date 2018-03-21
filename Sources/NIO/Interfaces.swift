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
//
//  Interfaces.swift
//  NIO
//
//  Created by Cory Benfield on 27/02/2018.
//

private extension ifaddrs {
    var dstaddr: UnsafeMutablePointer<sockaddr>? {
        #if os(Linux)
        return self.ifa_ifu.ifu_dstaddr
        #elseif os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
        return self.ifa_dstaddr
        #endif
    }

    var broadaddr: UnsafeMutablePointer<sockaddr>? {
        #if os(Linux)
        return self.ifa_ifu.ifu_broadaddr
        #elseif os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
        return self.ifa_dstaddr
        #endif
    }
}

/// A representation of a single network interface on a system.
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

    /// Create a brand new network interface.
    ///
    /// This constructor will fail if NIO does not understand the format of the underlying
    /// socket address family. This is quite common: for example, Linux will return AF_PACKET
    /// addressed interfaces on most platforms, which NIO does not currently understand.
    internal init?(_ caddr: ifaddrs) {
        self.name = String(cString: caddr.ifa_name)
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
    }
}

extension NIONetworkInterface: CustomDebugStringConvertible {
    public var debugDescription: String {
        let baseString = "Interface \(self.name): address \(self.address)"
        let maskString = self.netmask != nil ? " netmask \(self.netmask!)" : ""
        return baseString + maskString
    }
}

extension NIONetworkInterface: Equatable {
    public static func ==(lhs: NIONetworkInterface, rhs: NIONetworkInterface) -> Bool {
        return lhs.name == rhs.name &&
               lhs.address == rhs.address &&
               lhs.netmask == rhs.netmask &&
               lhs.broadcastAddress == rhs.broadcastAddress &&
               lhs.pointToPointDestinationAddress == rhs.pointToPointDestinationAddress
    }
}
