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
import Foundation

public enum IPAddressError: Error {
    /// Given string input is not supported IPv4 Style
    case unsupportedIPv4Address
    /// Given string input is not supported IP Address
    case unsupportedIPAddress
}



extension UInt8 {
    var hexValue: String {
        let table: StaticString = "0123456789ABCDEF"
        
        return String.init(cString: [table.withUTF8Buffer { table in
            table[Int(self >> 4)]
        }, table.withUTF8Buffer { table in
            table[Int(self & 0x0F)]
        }])
    }
}

public typealias IPv4BytesTuple = (UInt8, UInt8, UInt8, UInt8)
public typealias IPv6BytesTuple = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

public struct IPv4Bytes: Collection {
    public typealias Index = Int
    public typealias Element = UInt8
    
    public let startIndex: Index = 0
    public let endIndex: Index = 4
    
    private let _storage: IPv4BytesTuple
    
    public var bytes: IPv4BytesTuple {
        return self._storage
    }
    
    init(_ bytes: IPv4BytesTuple) {
        self._storage = bytes
    }
    
    public subscript(position: Index) -> Element {
        get {
            switch position {
            case 0: return self.bytes.0
            case 1: return self.bytes.1
            case 2: return self.bytes.2
            case 3: return self.bytes.3
            default: preconditionFailure()
            }
        }
    }
    
    public func index(after: Index) -> Index {
        return after + 1
    }
}

public struct IPv6Bytes: Collection {
    public typealias Index = Int
    public typealias Element = UInt8
    
    public let startIndex: Index = 0
    public let endIndex: Index = 16
    
    private let _storage: IPv6BytesTuple
    
    public var bytes: IPv6BytesTuple {
        return self._storage
    }
    
    init(_ bytes: IPv6BytesTuple) {
        self._storage = bytes
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
            default: preconditionFailure()
            }
        }
    }
    
    public func index(after: Index) -> Index {
        return after + 1
    }
}

/// Represent a IP address
public enum IPAddress: CustomStringConvertible {
    public typealias Element = UInt8
    
    /// A single IPv4 address for `IPAddress`.
    public struct IPv4Address {
        /// The libc ip address for an IPv4 address.
        let address: IPv4Bytes
        
        var posix: in_addr {
            get {
                return in_addr.init(s_addr: UInt32(self.address.bytes.3) << 24
                                          + UInt32(self.address.bytes.2) << 16
                                          + UInt32(self.address.bytes.1) << 8
                                          + UInt32(self.address.bytes.0))
            }
        }
        
        fileprivate init(address: IPv4Bytes) {
            self.address = address
        }
    }
    
    /// A single IPv6 address for `IPAddress`
    public struct IPv6Address {
        /// The libc ip address for an IPv6 address.
        let address: IPv6Bytes
        let zone: String?
        
        var posix: in6_addr {
            get {
                return in6_addr.init(__u6_addr: .init(__u6_addr8: self.address.bytes))
            }
        }
        
        fileprivate init(address: IPv6Bytes, zone: String? = nil) {
            self.address = address
            self.zone = zone
        }
    }
        
    /// An IPv4 `IPAddress`.
    case v4(IPv4Address)

    /// An IPv6 `IPAddress`.
    case v6(IPv6Address)

    /// A human-readable description of this `IPAddress`. Mostly useful for logging.
    public var description: String {
        switch self {
        case .v4(_):
            return "[IPv4]\(self.ipAddress)"
        case .v6(_):
            return "[IPv6]\(self.ipAddress)"
        }
    }
    
    /// Get the IP address as a string
    public var ipAddress: String {
        switch self {
        case .v4(let addr):
            return addr.address.map({"\($0)"}).joined(separator: ".")
        case .v6(let addr):
            let addressString = stride(from: 0, to: 15, by: 2).map({ idx in
                addr.address[idx].hexValue + addr.address[idx + 1].hexValue
            }).joined(separator: ":")
            if let zone = addr.zone {
                return addressString + "%\(zone)"
            } else {
                return addressString
            }
        }
    }

    /// Creates a new `IPAddress` for the given string.
    /// "d.d.d.d" with decimal values for IPv4 and "h:h:h:h:h:h:h:h" or "h:h:h:h:h:h:h:h%<zone>" with hexadecimal values for IPv6 with optional zone/scope-id supported. Shortened and hybrid versions for IPv6 are not (yet) supported.
    ///
    /// - parameters:
    ///     - string: String representation of IPv4 or IPv6 Address
    /// - returns: The `IPAddress` for the given string or `nil` if the string representation is not supported.
    public init?(string: String) {
        var bytes: [UInt8] = [0,0,0,0]
        var zone: String? = nil
        var idx: Int = 0
        
        do {
            for char in string {
                if char == "." {
                    idx += 1
                } else if let number = char.wholeNumberValue {
                    bytes[idx] = bytes[idx]*10 + UInt8(number)
                } else {
                    throw IPAddressError.unsupportedIPv4Address
                }
            }
        } catch {
            idx = 0
            var ipv6Bytes: [UInt16] = [0,0,0,0,0,0,0,0]
            
            for char in string {
                if let z = zone {
                    zone = z + String(char)
                } else if char == ":" {
                    idx += 1
                } else if let number = char.hexDigitValue {
                    ipv6Bytes[idx] = ipv6Bytes[idx]*16 + UInt16(number)
                } else if char == "%" {
                    zone = ""
                } else {
                    return nil
                }
            }
            bytes = ipv6Bytes.flatMap {[UInt8($0 >> 8), UInt8($0 & 0x00FF)]}
        }
        self.init(packedBytes: bytes, zone: zone)
    }
    
    /// Creates a new `IPAddress` for the given bytes and optional zone.
    ///
    /// - parameters:
    ///     - bytes: Either 4 or 16 bytes representing the IPAddress value.
    ///     - zone: Optional zone/scope-id string for IPv6Address.
    /// - returns: The `IPAddress` for the given string or `nil` if the string representation is not supported.
    public init(packedBytes bytes: [UInt8], zone: String? = nil) {
        switch bytes.count {
        case 4: self = .v4(.init(address: .init((
            bytes[0], bytes[1], bytes[2], bytes[3]
        ))))
        case 16: self = .v6(.init(address: .init((
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )), zone: zone))
        default: self = .v4(.init(address: .init((0,0,0,0))))
        }
    }
    
    public init(posixIPv4Address: in_addr) {
        let uint8Bitmask: UInt32 = 0x000000FF
        
        let uint8AddressBytes: IPv4Bytes = .init((
            UInt8((posixIPv4Address.s_addr >> 24) & uint8Bitmask),
            UInt8((posixIPv4Address.s_addr >> 16) & uint8Bitmask),
            UInt8((posixIPv4Address.s_addr >> 8) & uint8Bitmask),
            UInt8(posixIPv4Address.s_addr & uint8Bitmask)
        ))
        
        self = .v4(.init(address: uint8AddressBytes))
    }
    
    public init(posixIPv6Address: in6_addr) {
        self = .v6(.init(address: .init(posixIPv6Address.__u6_addr.__u6_addr8)))
    }
    
}

/// We define an extension on `IPv4Bytes` that gives it an elementwise equatable conformance
extension IPv4Bytes: Equatable {
    public static func == (lhs: IPv4Bytes, rhs: IPv4Bytes) -> Bool {
        return lhs.bytes == rhs.bytes
    }
}

/// We define an extension on `IPv6Bytes` that gives it an elementwise equatable conformance
extension IPv6Bytes: Equatable {
    public static func == (lhs: IPv6Bytes, rhs: IPv6Bytes) -> Bool {
        return zip(lhs, rhs).allSatisfy {$0 == $1}
    }
}

/// We define an extension on `IPAddress` that gives it an elementwise equatable conformance
extension IPAddress: Equatable {
    public static func == (lhs: IPAddress, rhs: IPAddress) -> Bool {
        switch (lhs, rhs) {
        case (.v4(let addr1), .v4(let addr2)):
            return addr1.address == addr2.address
        case (.v6(let addr1), .v6(let addr2)):
            return addr1.address == addr2.address &&
                   addr1.zone == addr2.zone
        default:
            return false
        }
    }
}
