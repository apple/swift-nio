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

    fileprivate var versionAndIhl: UInt8
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
    fileprivate var dscpAndEcn: UInt8
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
    fileprivate var flagsAndFragmentOffset: UInt16
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

    fileprivate init(
        versionAndIhl: UInt8,
        dscpAndEcn: UInt8,
        totalLength: UInt16,
        identification: UInt16,
        flagsAndFragmentOffset: UInt16,
        timeToLive: UInt8,
        `protocol`: NIOIPProtocol,
        headerChecksum: UInt16,
        sourceIpAddress: IPv4Address,
        destinationIpAddress: IPv4Address
    ) {
        self.versionAndIhl = versionAndIhl
        self.dscpAndEcn = dscpAndEcn
        self.totalLength = totalLength
        self.identification = identification
        self.flagsAndFragmentOffset = flagsAndFragmentOffset
        self.timeToLive = timeToLive
        self.`protocol` = `protocol`
        self.headerChecksum = headerChecksum
        self.sourceIpAddress = sourceIpAddress
        self.destinationIpAddress = destinationIpAddress
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
}

extension FixedWidthInteger {
    func convertEndianness(to endianness: Endianness) -> Self {
        switch endianness {
        case .little:
            return self.littleEndian
        case .big:
            return self.bigEndian
        }
    }
}

extension ByteBuffer {
    mutating func readIPv4Header() -> IPv4Header? {
        guard
            let (
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
            ) = self.readMultipleIntegers(
                as: (
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
                ).self
            )
        else { return nil }
        return .init(
            versionAndIhl: versionAndIhl,
            dscpAndEcn: dscpAndEcn,
            totalLength: totalLength,
            identification: identification,
            flagsAndFragmentOffset: flagsAndFragmentOffset,
            timeToLive: timeToLive,
            protocol: .init(rawValue: `protocol`),
            headerChecksum: headerChecksum,
            sourceIpAddress: .init(rawValue: sourceIpAddress),
            destinationIpAddress: .init(rawValue: destinationIpAddress)
        )
    }

    mutating func readIPv4HeaderFromBSDRawSocket() -> IPv4Header? {
        guard var header = self.readIPv4Header() else { return nil }
        // On BSD, the total length is in host byte order
        header.totalLength = header.totalLength.convertEndianness(to: .big)
        // TODO: fragmentOffset is in host byte order as well but it is always zero in our tests
        // and fragmentOffset is 13 bits in size so we can't just use readInteger(endianness: .host)
        return header
    }

    mutating func readIPv4HeaderFromOSRawSocket() -> IPv4Header? {
        #if canImport(Darwin)
        return self.readIPv4HeaderFromBSDRawSocket()
        #else
        return self.readIPv4Header()
        #endif
    }
}

extension ByteBuffer {
    @discardableResult
    mutating func writeIPv4Header(_ header: IPv4Header) -> Int {
        assert(
            {
                var buffer = ByteBuffer()
                buffer._writeIPv4Header(header)
                let writtenHeader = buffer.readIPv4Header()
                return header == writtenHeader
            }()
        )
        return self._writeIPv4Header(header)
    }

    @discardableResult
    private mutating func _writeIPv4Header(_ header: IPv4Header) -> Int {
        self.writeMultipleIntegers(
            header.versionAndIhl,
            header.dscpAndEcn,
            header.totalLength,
            header.identification,
            header.flagsAndFragmentOffset,
            header.timeToLive,
            header.`protocol`.rawValue,
            header.headerChecksum,
            header.sourceIpAddress.rawValue,
            header.destinationIpAddress.rawValue
        )
    }

    @discardableResult
    mutating func writeIPv4HeaderToBSDRawSocket(_ header: IPv4Header) -> Int {
        assert(
            {
                var buffer = ByteBuffer()
                buffer._writeIPv4HeaderToBSDRawSocket(header)
                let writtenHeader = buffer.readIPv4HeaderFromBSDRawSocket()
                return header == writtenHeader
            }()
        )
        return self._writeIPv4HeaderToBSDRawSocket(header)
    }

    @discardableResult
    private mutating func _writeIPv4HeaderToBSDRawSocket(_ header: IPv4Header) -> Int {
        var header = header
        // On BSD, the total length needs to be in host byte order
        header.totalLength = header.totalLength.convertEndianness(to: .big)
        // TODO: fragmentOffset needs to be in host byte order as well but it is always zero in our tests
        // and fragmentOffset is 13 bits in size so we can't just use writeInteger(endianness: .host)
        return self._writeIPv4Header(header)
    }

    @discardableResult
    mutating func writeIPv4HeaderToOSRawSocket(_ header: IPv4Header) -> Int {
        #if canImport(Darwin)
        self.writeIPv4HeaderToBSDRawSocket(header)
        #else
        self.writeIPv4Header(header)
        #endif
    }
}

extension IPv4Header {
    func computeChecksum() -> UInt16 {
        let checksum = ~[
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
        assert(isValidChecksum(checksum))
        return checksum
    }
    mutating func setChecksum() {
        self.headerChecksum = computeChecksum()
    }
    func isValidChecksum(_ headerChecksum: UInt16) -> Bool {
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
    func isValidChecksum() -> Bool {
        isValidChecksum(headerChecksum)
    }
}

extension Sequence where Element == UInt8 {
    func computeIPChecksum() -> UInt16 {
        var sum = UInt16(0)

        var iterator = self.makeIterator()

        while let nextHigh = iterator.next() {
            let nextLow = iterator.next() ?? 0
            let next = (UInt16(nextHigh) << 8) | UInt16(nextLow)
            sum = onesComplementAdd(lhs: sum, rhs: next)
        }

        return ~sum
    }
}

private func onesComplementAdd<Integer: FixedWidthInteger>(lhs: Integer, rhs: Integer) -> Integer {
    var (sum, overflowed) = lhs.addingReportingOverflow(rhs)
    if overflowed {
        sum &+= 1
    }
    return sum
}

extension IPv4Header {
    var platformIndependentTotalLengthForReceivedPacketFromRawSocket: UInt16 {
        #if canImport(Darwin)
        // On BSD the IP header will only contain the size of the ip packet body, not the header.
        // This is known bug which can't be fixed without breaking old apps which already workaround the issue
        // like e.g. we do now too.
        return totalLength + 20
        #else
        return totalLength
        #endif
    }
    var platformIndependentChecksumForReceivedPacketFromRawSocket: UInt16 {
        #if canImport(Darwin)
        // On BSD the checksum is always zero and we need to compute it
        precondition(headerChecksum == 0)
        return computeChecksum()
        #else
        return headerChecksum
        #endif
    }
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
