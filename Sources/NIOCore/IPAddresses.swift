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

import Foundation
import Darwin
import CNIOLinux
import CoreFoundation

public typealias IPv4Bytes = (UInt8, UInt8, UInt8, UInt8)
public typealias IPv6Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)


/// Represent a IP address
public enum IPAddress: CustomStringConvertible {
    
    /// A single IPv4 address for `IPAddress`.
    public struct IPv4Address {
        /// The libc ip address for an IPv4 address.
        /// 8b.8b.8b.8b => 32b Int
        private let _storage: IPv4Bytes
        
        public var address: IPv4Bytes {
            return _storage
        }
    
        fileprivate init(address: IPv4Bytes) {
            self._storage = address
        }
    }
    
    /// A single IPv6 address for `IPAddress`
    public struct IPv6Address {
        /// The libc ip address for an IPv6 address.
        private let _storage: Box<(address: IPv6Bytes, zone: String?)>
        
        public var address: IPv6Bytes {
            return self._storage.value.address
        }
        
        public var zone: String? {
            return self._storage.value.zone
        }
    
        fileprivate init(address: IPv6Bytes, zone: String?=nil) {
            self._storage = Box((address: address, zone: zone))
        }
    }
        
    /// An IPv4 `IPAddress`.
    case v4(IPv4Address)

    /// An IPv6 `IPAddress`.
    case v6(IPv6Address)

    /// A human-readable description of this `IPAddress`. Mostly useful for logging.
    public var description: String {
        var addressString: String
        let type: String
        switch self {
        case .v4(let addr):
            addressString = "\(addr.address)"
            type = "IPv4"
        case .v6(let addr):
            let hexRepresentation = Mirror(reflecting: addr.address).children.map {String(format: "%02X", $0.value as! UInt8)}
            addressString = "\(hexRepresentation.joined(separator: ":"))"
            
            if let zone = addr.zone {
                addressString += "%<\(zone)>"
            }
            type = "IPv6"
        }
        return "[\(type)]\(addressString)"
    }
    
// TODO:
//    "While NIO requires that we be able to produce C types, we don't need to store things there!"
//    accept: IPv4 a.b.c.d
//    accept: IPv6
//       a) x:x:x:x:x:x:x:x with x one to four hex digits
//       b) x:x:x::x:x where '::' represents fill up zeros
//       c) x:x:x:x:x:x:d.d.d.d where d's are decimal values of the four low-order 8-bit pieces
//       d) <address>%<zone_id> where address is a literal IPv6 address and zone_id is a string identifying the zone


    public init(string: String) {
        self = .v4(.init(address: (0,0,0,0)))
    }
    
    public init(bytes: [UInt8]) {
        if bytes.count == 16 {
            var byteTuple: IPv6Bytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
            withUnsafeMutablePointer(to: &byteTuple) { dst -> () in
                memcpy(dst, bytes, 16)
                return
            }
            self = .v6(.init(address: byteTuple))
        } else {
            // TODO: throw exception
            self = .v4(.init(address: (0,0,0,0)))
        }
    }
    
    /*
    public init(_ addr: in_addr) {
        self = .v4(.init(address: addr.s_addr))
    }
    */
    
    public init(_ addr: in6_addr) {
        self = .v6(.init(address: addr.__u6_addr.__u6_addr8))
    }
    
}
