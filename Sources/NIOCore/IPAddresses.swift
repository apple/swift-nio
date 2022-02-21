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


public enum IPAddressError: Error {
    /// Given string input is not supported IPv4 Style
    case failedToParseIPv4String
    /// Given string input is not supported IP Address
    case failedToParseIPString(String)
    /// Given string input is not supported IP Address
    case bytesArrayHasWrongLength(Int)
}

public typealias IPv4BytesTuple = (UInt8, UInt8, UInt8, UInt8)
public typealias IPv6BytesTuple = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

public struct IPv4Bytes: Collection {
    public typealias Index = Int
    public typealias Element = UInt8
    
    public let startIndex: Index = 0
    public let endIndex: Index = 4
    
    private let ipv4BytesTuple: IPv4BytesTuple
    
    public var bytes: IPv4BytesTuple {
        return self.ipv4BytesTuple
    }
    
    init(_ bytes: IPv4BytesTuple) {
        self.ipv4BytesTuple = bytes
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
    
    private let ipv6BytesTuple: IPv6BytesTuple
    
    public var bytes: IPv6BytesTuple {
        return self.ipv6BytesTuple
    }
    
    init(_ bytes: IPv6BytesTuple) {
        self.ipv6BytesTuple = bytes
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

extension UInt8 {
    func toHex() -> Character {
        switch self {
        case 0: return "0"
        case 1: return "1"
        case 2: return "2"
        case 3: return "3"
        case 4: return "4"
        case 5: return "5"
        case 6: return "6"
        case 7: return "7"
        case 8: return "8"
        case 9: return "9"
        case 10: return "A"
        case 11: return "B"
        case 12: return "C"
        case 13: return "D"
        case 14: return "E"
        case 15: return "F"
        default: preconditionFailure()
        }
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
        
        var posix: in6_addr {
            get {
                return in6_addr.init(__u6_addr: .init(__u6_addr8: self.address.bytes))
            }
        }
        
        fileprivate init(address: IPv6Bytes) {
            self.address = address
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
            return addr.address.map({String($0)}).joined(separator: ".")
        case .v6(let addr):
            return stride(from: 0, to: 15, by: 2).lazy.map({ idx in
                let hexValues = [
                    addr.address[idx] >> 4,
                    addr.address[idx] & 0x0F,
                    addr.address[idx + 1] >> 4,
                    addr.address[idx + 1] & 0x0F
                ]
                
                var removeLeadingZeros = 0
                if hexValues[0] + hexValues[1] + hexValues[2] == 0 {
                    removeLeadingZeros = 3
                } else if hexValues[0] + hexValues[1] == 0 {
                    removeLeadingZeros = 2
                } else if hexValues[0] == 0 {
                    removeLeadingZeros = 1
                }
                
                return String(hexValues[removeLeadingZeros...].lazy.map {$0.toHex()})
            }).joined(separator: ":")
        }
    }

    /// Creates a new `IPAddress` for the given string.
    /// "d.d.d.d" with decimal values for IPv4 and "h:h:h:h:h:h:h:h" with hexadecimal values for IPv6. Hybrid versions for IPv6 are not (yet) supported.
    ///
    /// - parameters:
    ///     - string: String representation of IPv4 or IPv6 Address
    /// - returns: The `IPAddress` for the given string or `nil` if the string representation is not supported.
    /// - throws: May throw `IPAddressError.failedToParseIPString` if the string cannot be parsed to IPv4 or IPv6.
    public init(string: String) throws {
        var bytes: [UInt8] = [0,0,0,0]
        var idx: Int = 0
        
        do {
            for char in string {
                if char == "." {
                    idx += 1
                } else if let number = char.wholeNumberValue {
                    bytes[idx] = bytes[idx]*10 + UInt8(number)
                } else {
                    throw IPAddressError.failedToParseIPv4String
                }
            }
        } catch {
            idx = 0
            var ipv6Bytes: [UInt16] = [0,0,0,0,0,0,0,0]
            var isLastCharSeparator: Bool = false
            var shortenerIndex: Int?
            
            for char in string {
                if char == ":" {
                    if isLastCharSeparator {
                        if shortenerIndex != nil {
                            // Two shortener are not allowed
                            throw IPAddressError.failedToParseIPString(string)
                        }
                        shortenerIndex = idx
                    }
                    idx += 1
                    isLastCharSeparator = true
                } else {
                    isLastCharSeparator = false
                    if let number = char.hexDigitValue {
                        ipv6Bytes[idx] = ipv6Bytes[idx]*16 + UInt16(number)
                    } else {
                        throw IPAddressError.failedToParseIPString(string)
                    }
                }
            }
            
            if let shortenerIndex = shortenerIndex {
                // For all i after shortenerIndex move to i + (7 - idx)
                let shiftBy = ipv6Bytes.count - 1 - idx
                
                // Go from last index backwards to the shortener position
                for i in (shortenerIndex+1...idx).reversed() {
                    ipv6Bytes[i + shiftBy] = ipv6Bytes[i]
                    ipv6Bytes[i] = 0
                }
            } else {
                if (idx != ipv6Bytes.count - 1) {
                    // if IPv6 wasn't shortened, every byte should be set explicitly
                    throw IPAddressError.failedToParseIPString(string)
                }
            }
            
            bytes = ipv6Bytes.flatMap {[UInt8($0 >> 8), UInt8($0 & 0x00FF)]}
        }
        try self.init(packedBytes: bytes)
    }
    
    /// Creates a new `IPAddress` for the given bytes and optional zone.
    ///
    /// - parameters:
    ///     - bytes: Either 4 or 16 bytes representing the IPAddress value.
    /// - returns: The `IPAddress` for the given string or `nil` if the string representation is not supported.
    // TODO: update to init<Bytes: Collection>(packedBytes bytes: Bytes) where Element == UInt8
    public init(packedBytes bytes: [UInt8]) throws {
        switch bytes.count {
        case 4: self = .v4(.init(address: .init((
            bytes[0], bytes[1], bytes[2], bytes[3]
        ))))
        case 16: self = .v6(.init(address: .init((
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))))
        default:
            throw IPAddressError.bytesArrayHasWrongLength(bytes.count)
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
            return addr1.address == addr2.address
        default:
            return false
        }
    }
}
