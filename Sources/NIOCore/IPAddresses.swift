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


import Darwin
import CNIOLinux
import CoreFoundation


extension UInt8 {
    var hexValue: String {
        let table: StaticString = "0123456789ABCDEF"
        
        let b0 = table.withUTF8Buffer { table in
            table[Int(self >> 4)]
        }
        let b1 = table.withUTF8Buffer { table in
            table[Int(self & 0x0F)]
        }
        return String(UnicodeScalar(b0)) + String(UnicodeScalar(b1))
    }
}

public typealias IPv4BytesTuple = (UInt8, UInt8, UInt8, UInt8)
public typealias IPv6BytesTuple = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

public struct IPv4Bytes: Collection, IteratorProtocol{
    public typealias Index = Int
    public typealias Element = UInt8
    private var _times = 0
    public let startIndex: Index = 0
    public let endIndex: Index = 3
    
    private let _storage: IPv4BytesTuple
    
    
    public var bytes: IPv4BytesTuple {
        return self._storage
    }
    
    init(_ bytes: IPv4BytesTuple) {
        self._storage = bytes
    }
    
    mutating public func next() -> Element? {
        let nextVal: Element? = self[self._times]
        self._times += 1
        return nextVal
    }
    
    public subscript(position: Index) -> Element {
        get {
            switch position {
            case 0: return self.bytes.0
            case 1: return self.bytes.1
            case 2: return self.bytes.2
            case 3: return self.bytes.3
            default: return 0  // can never be the case TODO: guard?
            }
        }
    }
    
    public func index(after: Index) -> Index {
        return after + 1
    }
}

public struct IPv6Bytes: Collection, IteratorProtocol{
    public typealias Index = Int
    public typealias Element = UInt8
    private var _times = 0
    public let startIndex: Index = 0
    public let endIndex: Index = 15
    
    private let _storage: IPv6BytesTuple
    
    
    public var bytes: IPv6BytesTuple {
        return self._storage
    }
    
    init(_ bytes: IPv6BytesTuple) {
        self._storage = bytes
    }
    
    mutating public func next() -> Element? {
        let nextVal: Element? = self[self._times]
        self._times += 1
        return nextVal
    }
    
    public subscript(position: Index) -> Element {
        get {
            switch position {
            case 0: return self.bytes.0
            case 1: return self.bytes.1
            case 2: return self.bytes.2
            case 3: return self.bytes.3
            case 4: return self.bytes.4
            case 5: return self.bytes.5
            case 6: return self.bytes.6
            case 7: return self.bytes.7
            case 8: return self.bytes.8
            case 9: return self.bytes.9
            case 10: return self.bytes.10
            case 11: return self.bytes.11
            case 12: return self.bytes.12
            case 13: return self.bytes.13
            case 14: return self.bytes.14
            case 15: return self.bytes.15
            default: return 0  // can never be the case TODO: guard?
            }
        }
    }
    
    public func index(after: Index) -> Index {
        return after + 1
    }
}


/// Represent a IP address
public enum IPAddress: CustomStringConvertible {
    
    /// A single IPv4 address for `IPAddress`.
    public struct IPv4Address {
        /// The libc ip address for an IPv4 address.
        private let _storage: IPv4Bytes
        
        public var address: IPv4Bytes {
            return self._storage
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
            addressString = addr.address.map({"\($0)"}).joined(separator: ".")
            type = "IPv4"
        case .v6(let addr):
            addressString = stride(from: 0, to: 15, by: 2).map({ idx in
                addr.address[idx].hexValue + addr.address[idx + 1].hexValue
            }).joined(separator: ":")
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
        self = .v4(.init(address: .init((0,0,0,0))))
    }
    
    public init(bytes: [UInt8]) {
        if bytes.count == 4 {
            self = .v4(.init(address: .init((
                bytes[0], bytes[1], bytes[2], bytes[3]
            ))))
        }
        if bytes.count == 16 {
            self = .v6(.init(address: .init((
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))))
        } else {
            // TODO: throw exception
            self = .v4(.init(address: .init((0,0,0,0))))
        }
    }
    
    /*
    public init(_ addr: in_addr) {
        self = .v4(.init(address: addr.s_addr))
    }
    */
    
    public init(_ addr: in6_addr) {
        self = .v6(.init(address: .init(addr.__u6_addr.__u6_addr8)))
    }
    
}
