//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

struct IPv4Address: Hashable {
    var rawValue: UInt32
}

extension IPv4Address {
    init(_ v1: UInt8, _ v2: UInt8, _ v3: UInt8, _ v4: UInt8) {
        rawValue = UInt32(v1) << 24 | UInt32(v2) << 16 | UInt32(v3) << 8 | UInt32(v4)
    }
}

extension IPv4Address: CustomStringConvertible {
    var description: String {
        let v1 = rawValue >> 24
        let v2 = rawValue >> 16 & 0b1111_1111
        let v3 = rawValue >> 8 & 0b1111_1111
        let v4 = rawValue & 0b1111_1111
        return "\(v1).\(v2).\(v3).\(v4)"
    }
}

struct IPv4Header: Hashable {
    static let size: Int = 20
    
    private var versionAndIhl: UInt8
    var version: UInt8 {
        get {
            versionAndIhl >> 4
        }
        set {
            precondition(newValue & 0b1111_0000 == 0)
            versionAndIhl = newValue << 4 | (0b0000_1111 & versionAndIhl)
            assert(newValue == version, "\(newValue) != \(version) \(versionAndIhl)")
        }
    }
    var internetHeaderLength: UInt8 {
        get {
            versionAndIhl & 0b0000_1111
        }
        set {
            precondition(newValue & 0b1111_0000 == 0)
            versionAndIhl = newValue | (0b1111_0000 & versionAndIhl)
            assert(newValue == internetHeaderLength)
        }
    }
    private var dscpAndEcn: UInt8
    var differentiatedServicesCodePoint: UInt8 {
        get {
            dscpAndEcn >> 2
        }
        set {
            precondition(newValue & 0b0000_0011 == 0)
            dscpAndEcn = newValue << 2 | (0b0000_0011 & dscpAndEcn)
            assert(newValue == differentiatedServicesCodePoint)
        }
    }
    var explicitCongestionNotification: UInt8 {
        get {
            dscpAndEcn & 0b0000_0011
        }
        set {
            precondition(newValue & 0b0000_0011 == 0)
            dscpAndEcn = newValue | (0b1111_1100 & dscpAndEcn)
            assert(newValue == explicitCongestionNotification)
        }
    }
    var totalLength: UInt16
    var identification: UInt16
    private var flagsAndFragmentOffset: UInt16
    var flags: UInt8 {
        get {
            UInt8(flagsAndFragmentOffset >> 13)
        }
        set {
            precondition(newValue & 0b0000_0111 == 0)
            flagsAndFragmentOffset = UInt16(newValue) << 13 | (0b0001_1111_1111_1111 & flagsAndFragmentOffset)
            assert(newValue == flags)
        }
    }
    var fragmentOffset: UInt16 {
        get {
            flagsAndFragmentOffset & 0b0001_1111_1111_1111
        }
        set {
            precondition(newValue & 0b1110_0000_0000_0000 == 0)
            flagsAndFragmentOffset = newValue | (0b1110_0000_0000_0000 & flagsAndFragmentOffset)
            assert(newValue == fragmentOffset)
        }
    }
    var timeToLive: UInt8
    var `protocol`: NIOIPProtocol
    var headerChecksum: UInt16
    var sourceIpAddress: IPv4Address
    var destinationIpAddress: IPv4Address
    
    init?(buffer: inout ByteBuffer) {
        #if canImport(Darwin)
        guard
            let versionAndIhl: UInt8 = buffer.readInteger(),
            let dscpAndEcn: UInt8 = buffer.readInteger(),
            // On BSD, the total length is in host byte order
            let totalLength: UInt16 = buffer.readInteger(endianness: .host),
            let identification: UInt16 = buffer.readInteger(),
            // fragmentOffset is in host byte order as well but it is always zero in our tests
            // and fragmentOffset is 13 bits in size so we can't just use readInteger(endianness: .host)
            let flagsAndFragmentOffset: UInt16 = buffer.readInteger(),
            let timeToLive: UInt8 = buffer.readInteger(),
            let `protocol`: UInt8 = buffer.readInteger(),
            let headerChecksum: UInt16 = buffer.readInteger(),
            let sourceIpAddress: UInt32 = buffer.readInteger(),
            let destinationIpAddress: UInt32 = buffer.readInteger()
        else { return nil }
        #elseif os(Linux)
        guard let (
            versionAndIhl,
            dscpAndEcn,
            totalLength,
            identification,
            flagsAndFragmentOffset,
            timeToLive,
            `protocol`,
            headerChecksum,
            sourceIpAddress,
            destinationIpAddress
        ) = buffer.readMultipleIntegers(as: (
            UInt8,
            UInt8,
            UInt16,
            UInt16,
            UInt16,
            UInt8,
            UInt8,
            UInt16,
            UInt32,
            UInt32
        ).self) else { return nil }
        #endif
        self.versionAndIhl = versionAndIhl
        self.dscpAndEcn = dscpAndEcn
        self.totalLength = totalLength
        self.identification = identification
        self.flagsAndFragmentOffset = flagsAndFragmentOffset
        self.timeToLive = timeToLive
        self.`protocol` = .init(rawValue: `protocol`)
        self.headerChecksum = headerChecksum
        self.sourceIpAddress = .init(rawValue: sourceIpAddress)
        self.destinationIpAddress = .init(rawValue: destinationIpAddress)
    }
    init() {
        self.versionAndIhl = 0
        self.dscpAndEcn = 0
        self.totalLength = 0
        self.identification = 0
        self.flagsAndFragmentOffset = 0
        self.timeToLive = 0
        self.`protocol` = .init(rawValue: 0)
        self.headerChecksum = 0
        self.sourceIpAddress = .init(rawValue: 0)
        self.destinationIpAddress = .init(rawValue: 0)
    }
    
    mutating func setChecksum() {
        self.headerChecksum = ~[
            UInt16(versionAndIhl) << 8 | UInt16(dscpAndEcn),
            totalLength,
            identification,
            flagsAndFragmentOffset,
            UInt16(timeToLive) << 8 | UInt16(`protocol`.rawValue),
            UInt16(sourceIpAddress.rawValue >> 16),
            UInt16(sourceIpAddress.rawValue & 0b0000_0000_0000_0000_1111_1111_1111_1111),
            UInt16(destinationIpAddress.rawValue >> 16),
            UInt16(destinationIpAddress.rawValue & 0b0000_0000_0000_0000_1111_1111_1111_1111),
        ].reduce(UInt16(0), onesComplementAdd)
        
        assert(isValidChecksum())
    }
    
    func isValidChecksum() -> Bool {
        let sum = ~[
            UInt16(versionAndIhl) << 8 | UInt16(dscpAndEcn),
            totalLength,
            identification,
            flagsAndFragmentOffset,
            UInt16(timeToLive) << 8 | UInt16(`protocol`.rawValue),
            headerChecksum,
            UInt16(sourceIpAddress.rawValue >> 16),
            UInt16(sourceIpAddress.rawValue & 0b0000_0000_0000_0000_1111_1111_1111_1111),
            UInt16(destinationIpAddress.rawValue >> 16),
            UInt16(destinationIpAddress.rawValue & 0b0000_0000_0000_0000_1111_1111_1111_1111),
        ].reduce(UInt16(0), onesComplementAdd)
        return sum == 0
    }
    
    func write(to buffer: inout ByteBuffer) {
        assert({
            var buffer = ByteBuffer()
            self._write(to: &buffer)
            let newValue = Self(buffer: &buffer)
            return self == newValue
        }())
        self._write(to: &buffer)
    }
    
    private func _write(to buffer: inout ByteBuffer) {
        #if canImport(Darwin)
        buffer.writeInteger(versionAndIhl)
        buffer.writeInteger(dscpAndEcn)
        // On BSD, the total length needs to be in host byte order
        buffer.writeInteger(totalLength, endianness: .host)
        buffer.writeInteger(identification)
        // fragmentOffset needs to be in host byte order as well but it is always zero in our tests
        // and fragmentOffset is 13 bits in size so we can't just use writeInteger(endianness: .host)
        buffer.writeInteger(flagsAndFragmentOffset)
        buffer.writeInteger(timeToLive)
        buffer.writeInteger(`protocol`.rawValue)
        buffer.writeInteger(headerChecksum)
        buffer.writeInteger(sourceIpAddress.rawValue)
        buffer.writeInteger(destinationIpAddress.rawValue)
        #elseif os(Linux)
        buffer.writeMultipleIntegers(
            versionAndIhl,
            dscpAndEcn,
            totalLength,
            identification,
            flagsAndFragmentOffset,
            timeToLive,
            `protocol`.rawValue,
            headerChecksum,
            sourceIpAddress.rawValue,
            destinationIpAddress.rawValue
        )
        #endif
    }
}

private func onesComplementAdd<Integer: FixedWidthInteger>(lhs: Integer, rhs: Integer) -> Integer {
    var (sum, overflowed) = lhs.addingReportingOverflow(rhs)
    if overflowed {
        sum &+= 1
    }
    return sum
}

extension IPv4Header: CustomStringConvertible {
    var description: String {
        """
        Version: \(version)
        Header Length: \(internetHeaderLength * 4) bytes
        Differentiated Services: \(String(differentiatedServicesCodePoint, radix: 2))
        Explicit Congestion Notification: \(String(explicitCongestionNotification, radix: 2))
        Total Length: \(totalLength) bytes
        Identification: \(identification)
        Flags: \(String(flags, radix: 2))
        Fragment Offset: \(fragmentOffset) bytes
        Time to Live: \(timeToLive)
        Protocol: \(`protocol`)
        Header Checksum: \(headerChecksum) (\(isValidChecksum() ? "valid" : "*not* valid"))
        Source IP Address: \(sourceIpAddress)
        Destination IP Address: \(destinationIpAddress)
        """
    }
}
