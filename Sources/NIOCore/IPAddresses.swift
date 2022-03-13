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


/// `Error` that may be thrown if we fail to create a `IPAddress`
public enum IPAddressError: Error {
    /// Given string input is not supported IP Address
    case failedToParseIPString(String)
    /// Given string input is not supported IP Address
    case bytesArrayHasWrongLength(Int)
}

public typealias IPv4BytesTuple = (UInt8, UInt8, UInt8, UInt8)
public typealias IPv6BytesTuple = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

/// Represent the bytes for an `IPv4Address`.
public struct IPv4Bytes {
    public var bytes: IPv4BytesTuple
    
    public init(_ bytes: IPv4BytesTuple) {
        self.bytes = bytes
    }
}

/// Represent the bytes for an `IPv6Address.
public struct IPv6Bytes {
    public var bytes: IPv6BytesTuple
    
    public init(_ bytes: IPv6BytesTuple) {
        self.bytes = bytes
    }
}

/// Represent a single `IPAddress`.
public enum IPAddress: CustomStringConvertible {
    /// A single IPv4 address for `IPAddress`.
    public struct IPv4Address: CustomStringConvertible {
        /// The bytes storing the address of the IPv4 address.
        public var address: IPv4Bytes
        
        /// Get the `IPv4Address` as a string.
        public var ipAddress: String {
            self.address.lazy.map({String($0)}).joined(separator: ".")
        }
        
        /// A human-readable description of this `IPv4Address`. Mostly useful for logging.
        public var description: String {
            return "[IPv4]\(self.ipAddress)"
        }
        
        /// Get the libc address for an IPv4 address.
        public var posix: in_addr {
            get {
                return in_addr.init(s_addr: UInt32(uint8Tuple: self.address.bytes))
            }
        }
        
        /// Creates a new `IPv4Address`.
        ///
        /// - parameters:
        ///   - address: Bytes that hold the IPv4 address.
        public init(address: IPv4Bytes) {
            self.address = address
        }
        
        /// Creates a new `IPv4Address`.
        ///
        /// - parameters:
        ///   - packedBytes: Collection of UInt8 that holds the address.
        public init<Bytes: Collection>(packedBytes bytes: Bytes) where Bytes.Element == UInt8 {
            var bytes = bytes.prefix(4)
            
            self = .init(address: .init((
                bytes.popFirst()!,
                bytes.popFirst()!,
                bytes.popFirst()!,
                bytes.popFirst()!
            )))
        }
        
        /// Creates a new `IPv4Address`.
        ///
        /// - parameters:
        ///   - string: String representation of an IPv4 address.
        public init(string: String) throws {
            var bytes: [UInt8] = [0,0,0,0]
            var idx: Int = 0
            
            for char in string {
                if char == "." {
                    idx += 1
                } else if let number = char.wholeNumberValue {
                    if idx > 3 || bytes[idx] > 25 || (255 - number < (bytes[idx] * 10)) {
                        throw IPAddressError.failedToParseIPString(string)
                    }
                    bytes[idx] = bytes[idx] * 10 + UInt8(number)
                } else {
                    throw IPAddressError.failedToParseIPString(string)
                }
            }
            if idx != 3 {
                throw IPAddressError.failedToParseIPString(string)
            }
            self = .init(packedBytes: bytes)
        }
    }
    
    /// A single IPv6 address for `IPAddress`
    public struct IPv6Address: CustomStringConvertible {
        /// The bytes storing the address of the IPv6 address.
        public var address: IPv6Bytes
        
        /// Get the `IPv6Address` as a string.
        public var ipAddress: String {
            stride(from: 0, to: 15, by: 2).lazy.map({ idx in
                let hexValues = [
                    self.address[idx] >> 4,
                    self.address[idx] & 0x0F,
                    self.address[idx + 1] >> 4,
                    self.address[idx + 1] & 0x0F
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
        
        /// A human-readable description of this `IPv6Address`. Mostly useful for logging.
        public var description: String {
            return "[IPv6]\(self.ipAddress)"
        }
        
        /// Get the libc address for an IPv6 address.
        public var posix: in6_addr {
            get {
                return in6_addr.init(__u6_addr: .init(__u6_addr8: self.address.bytes))
            }
        }
        
        /// Creates a new `IPv6Address`.
        ///
        /// - parameters:
        ///   - address: Bytes that hold the IPv6 address.
        public init(address: IPv6Bytes) {
            self.address = address
        }
        
        /// Creates a new `IPv6Address`.
        ///
        /// - parameters:
        ///   - packedBytes: Collection of UInt8 that holds the address.
        public init<Bytes: Collection>(packedBytes bytes: Bytes) where Bytes.Element == UInt8, Bytes.Index == Int {
            self = .init(address: .init((
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            )))
        }
        
        /// Creates a new `IPv6Address`.
        ///
        /// - parameters:
        ///   - string: String representation of an IPv6 address.
        public init(string: String) throws {
            var idx = 0
            var ipv6Bytes: [UInt16] = [0,0,0,0,0,0,0,0]
            var isLastCharSeparator: Bool = false
            var shortenerIndex: Int?
            
            for char in string {
                if char == ":" {
                    if isLastCharSeparator {
                        if shortenerIndex != nil {
                            // Two shortener are not allowed.
                            throw IPAddressError.failedToParseIPString(string)
                        }
                        shortenerIndex = idx
                    }
                    idx += 1
                    isLastCharSeparator = true
                } else {
                    isLastCharSeparator = false
                    if let number = char.hexDigitValue {
                        if idx > 7 || ipv6Bytes[idx] > 4095 || (65535 - number < (ipv6Bytes[idx] * 16)) {
                            throw IPAddressError.failedToParseIPString(string)
                        }
                        ipv6Bytes[idx] = ipv6Bytes[idx]*16 + UInt16(number)
                    } else {
                        throw IPAddressError.failedToParseIPString(string)
                    }
                }
            }
            
            if let shortenerIndex = shortenerIndex {
                // For all i after shortenerIndex move to i + (7 - idx).
                let shiftBy = ipv6Bytes.count - 1 - idx
                
                // Go from last index backwards to the shortener position.
                for i in (shortenerIndex+1...idx).reversed() {
                    ipv6Bytes[i + shiftBy] = ipv6Bytes[i]
                    ipv6Bytes[i] = 0
                }
            } else {
                if (idx != ipv6Bytes.count - 1) {
                    // if IPv6 wasn't shortened, every segment should be set explicitly.
                    throw IPAddressError.failedToParseIPString(string)
                }
            }
            
            self = .init(packedBytes: ipv6Bytes.lazy.flatMap {[UInt8($0 >> 8), UInt8($0 & 0x00FF)]} )
        }
    }
    
    /// An IPv4 `IPAddress`.
    case v4(IPv4Address)

    /// An IPv6 `IPAddress`.
    case v6(IPv6Address)
    
    /// Get the `IPAddress` as a string.
    public var ipAddress: String {
        switch self {
        case .v4(let addr):
            return addr.ipAddress
        case .v6(let addr):
            return addr.ipAddress
        }
    }
    
    /// A human-readable description of this `IPAddress`. Mostly useful for logging.
    public var description: String {
        switch self {
        case .v4(let addr):
            return addr.description
        case .v6(let addr):
            return addr.description
        }
    }

    /// Creates a `IPAddress` directly out of UInt8 Tuple for IPv4.
    public init(_ ipv4BytesTuple: IPv4BytesTuple) {
        self = .v4(IPv4Address(address: .init(ipv4BytesTuple)))
    }
    
    /// Creates a `IPAddress` directly out of UInt8 Tuple for IPv6.
    public init(_ ipv6BytesTuple: IPv6BytesTuple) {
        self = .v6(IPv6Address(address: .init(ipv6BytesTuple)))
    }
    
    /// Creates a new `IPAddress` for the given string.
    /// "d.d.d.d" with decimal values for IPv4 and "h:h:h:h:h:h:h:h" with hexadecimal values for IPv6. Also allowing for shortened IPv6 representation with "::". Hybrid versions for IPv6 are not (yet) supported.
    ///
    /// - parameters:
    ///     - string: String representation of IPv4 or IPv6 Address
    /// - returns: The `IPAddress` for the given string
    /// - throws: May throw `IPAddressError.failedToParseIPString` if the string cannot be parsed to IPv4 or IPv6.
    public init(string: String) throws {
        do {
            try self = .v4(.init(string: string))
        } catch {
            try self = .v6(.init(string: string))
        }
    }
    
    /// Creates a new `IPAddress` for the given bytes.
    ///
    /// - parameters:
    ///     - bytes: Either 4 or 16 bytes representing the IPAddress value.
    /// - returns: The `IPAddress` for the given string or `nil` if the string representation is not supported.
    public init<Bytes: Collection>(packedBytes bytes: Bytes) throws where Bytes.Element == UInt8, Bytes.Index == Int {
        switch bytes.count {
        case 4: self = .v4(.init(packedBytes: bytes))
        case 16: self = .v6(.init(packedBytes: bytes))
        default:
            throw IPAddressError.bytesArrayHasWrongLength(bytes.count)
        }
    }
    
    /// Creates a new `IPAddress` for the given libc IPv4 address.
    ///
    /// - parameters:
    ///     - posixIPv4Address: libc ipv4 address.
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
    
    /// Creates a new `IPAddress` for the given libc IPv6 address.
    ///
    /// - parameters:
    ///     - posixIPv6Address: libc ipv6 address.
    public init(posixIPv6Address: in6_addr) {
        self = .v6(.init(address: .init(posixIPv6Address.__u6_addr.__u6_addr8)))
    }
}

extension UInt8 {
    /// Convenience function especially useful for representing IPv6 bytes as readable string.
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

extension UInt32 {
    /// Creates an integer from the given UInt8 tuple.
    init(uint8Tuple: (UInt8, UInt8, UInt8, UInt8)) {
        self = UInt32(uint8Tuple.0) << 24
            + UInt32(uint8Tuple.1) << 16
            + UInt32(uint8Tuple.2) << 8
            + UInt32(uint8Tuple.3)
    }
}

/// We define an extension on `IPv4Bytes` that gives it a collection conformance.
extension IPv4Bytes: Collection {
    public typealias Index = Int
    public typealias Element = UInt8
    
    public var startIndex: Index { 0 }
    public var endIndex: Index { 4 }
    
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

/// We define an extension on `IPv6Bytes` that gives it a collection conformance.
extension IPv6Bytes: Collection {
    public typealias Index = Int
    public typealias Element = UInt8
    
    public var startIndex: Index { 0 }
    public var endIndex: Index { 16 }
    
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

/// We define an extension on `IPv4Bytes` that gives it an equatable conformance.
extension IPv4Bytes: Equatable {
    public static func == (lhs: IPv4Bytes, rhs: IPv4Bytes) -> Bool {
        return lhs.bytes == rhs.bytes
    }
}

/// We define an extension on `IPv6Bytes` that gives it an element wise equatable conformance.
extension IPv6Bytes: Equatable {
    public static func == (lhs: IPv6Bytes, rhs: IPv6Bytes) -> Bool {
        return zip(lhs, rhs).allSatisfy {$0 == $1}
    }
}

extension IPAddress.IPv4Address: Equatable {}
extension IPAddress.IPv6Address: Equatable {}
extension IPAddress: Equatable {}


/// We define an extension on `IPv4Bytes` that combines each byte to the hasher.
extension IPv4Bytes: Hashable {
    public func hash(into hasher: inout Hasher) {
        self.forEach { hasher.combine($0) }
    }
}

/// We define an extension on `IPv6Bytes` that combines each byte to the hasher.
extension IPv6Bytes: Hashable {
    public func hash(into hasher: inout Hasher) {
        self.forEach { hasher.combine($0) }
    }
}

extension IPAddress.IPv4Address: Hashable {}
extension IPAddress.IPv6Address: Hashable {}
extension IPAddress: Hashable {}
