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

import XCTest
import NIOCore
import NIOPosix

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension NIOIPProtocol {
    static let reservedForTesting = Self(rawValue: 253)
}

func XCTSkipIfUserHasNotEnoughRightsForRawSocketAPI(file: StaticString = #filePath, line: UInt = #line) throws {
    try XCTSkipIf(geteuid() != 0, "Raw Socket API requires root privileges", file: file, line: line)
}

struct IPv4Address: Hashable {
    var rawValue: UInt32
}

extension IPv4Address {
    init(_ v1: UInt8, _ v2: UInt8, _ v3: UInt8, _ v4: UInt8) {
        rawValue = UInt32(v1) << 24 | UInt32(v2) << 16 | UInt32(v3) << 8 | UInt32(v4)
    }
}

struct IPv4Header {
    static let size: Int = 20
    
    private let versionAndIhl: UInt8
    var version: UInt8 {
        versionAndIhl >> 4
    }
    var internetHeaderLength: UInt8 {
        versionAndIhl & 0b0000_1111
    }
    private let dscpAndEcn: UInt8
    var differentiatedServicesCodePoint: UInt8 {
        dscpAndEcn >> 2
    }
    var explicitCongestionNotification: UInt8 {
        dscpAndEcn & 0b0000_0011
    }
    let totalLength: UInt16
    let identification: UInt16
    let flagsAndFragmentOffset: UInt16
    var flags: UInt8 {
        UInt8(flagsAndFragmentOffset >> 13)
    }
    var fragmentOffset: UInt16 {
        flagsAndFragmentOffset & 0b0001_1111_1111_1111
    }
    let timeToLive: UInt8
    let `protocol`: NIOIPProtocol
    let headerChecksum: UInt16
    let sourceIpAdress: IPv4Address
    let destinationIpAddress: IPv4Address
    
    init?(buffer: inout ByteBuffer) {
        guard let (
            versionAndIhl,
            dscpAndEcn,
            totalLength,
            identification,
            flagsAndFragmentOffset,
            timeToLive,
            `protocol`,
            headerChecksum,
            sourceIpAdress,
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
        self.versionAndIhl = versionAndIhl
        self.dscpAndEcn = dscpAndEcn
        self.totalLength = totalLength
        self.identification = identification
        self.flagsAndFragmentOffset = flagsAndFragmentOffset
        self.timeToLive = timeToLive
        self.`protocol` = .init(rawValue: `protocol`)
        self.headerChecksum = headerChecksum
        self.sourceIpAdress = .init(rawValue: sourceIpAdress)
        self.destinationIpAddress = .init(rawValue: destinationIpAddress)
    }
}

final class RawSocketBootstrapTests: XCTestCase {
    func testBindWithRecevMmsg() throws {
        try XCTSkipIfUserHasNotEnoughRightsForRawSocketAPI()
        
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }
        let channel = try RawSocketBootstrap(group: elg)
            .channelInitializer {
                $0.pipeline.addHandler(DatagramReadRecorder<ByteBuffer>(), name: "ByteReadRecorder")
            }
            .bind(host: "127.0.0.1", ipProtocol: .reservedForTesting).wait()
        defer { XCTAssertNoThrow(try channel.close().wait()) }
        try channel.configureForRecvMmsg(messageCount: 10)
        let expectedMessages = (0..<10).map { "Hello World \($0)" }
        for message in expectedMessages {
            _ = try channel.write(AddressedEnvelope(
                remoteAddress: SocketAddress(ipAddress: "127.0.0.1", port: 0),
                data: ByteBuffer(string: message)
            ))
        }
        channel.flush()
        
        let receivedMessages = Set(try channel.waitForDatagrams(count: 10).map { envelop -> String in
            var data = envelop.data
            let header = try XCTUnwrap(IPv4Header(buffer: &data))
            XCTAssertEqual(header.version, 4)
            XCTAssertEqual(header.protocol, .reservedForTesting)
            XCTAssertEqual(Int(header.totalLength), IPv4Header.size + data.readableBytes)
            XCTAssertEqual(header.sourceIpAdress, .init(127, 0, 0, 1))
            XCTAssertEqual(header.destinationIpAddress, .init(127, 0, 0, 1))
            return String(buffer: data)
        })
        
        XCTAssertEqual(receivedMessages, Set(expectedMessages))
    }
    
    func testConnect() throws {
        try XCTSkipIfUserHasNotEnoughRightsForRawSocketAPI()
        
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }
        let readChannel = try RawSocketBootstrap(group: elg)
            .channelInitializer {
                $0.pipeline.addHandler(DatagramReadRecorder<ByteBuffer>(), name: "ByteReadRecorder")
            }
            .bind(host: "127.0.0.1", ipProtocol: .reservedForTesting).wait()
        defer { XCTAssertNoThrow(try readChannel.close().wait()) }
        
        let writeChannel = try RawSocketBootstrap(group: elg)
            .channelInitializer {
                $0.pipeline.addHandler(DatagramReadRecorder<ByteBuffer>(), name: "ByteReadRecorder")
            }
            .bind(host: "127.0.0.1", ipProtocol: .reservedForTesting).wait()
        defer { XCTAssertNoThrow(try writeChannel.close().wait()) }
        
        let expectedMessages = (0..<10).map { "Hello World \($0)" }
        for message in expectedMessages {
            _ = try writeChannel.write(AddressedEnvelope(
                remoteAddress: SocketAddress(ipAddress: "127.0.0.1", port: 0),
                data: ByteBuffer(string: message)
            ))
        }
        writeChannel.flush()
        
        let receivedMessages = Set(try readChannel.waitForDatagrams(count: 10).map { envelop -> String in
            var data = envelop.data
            let header = try XCTUnwrap(IPv4Header(buffer: &data))
            XCTAssertEqual(header.version, 4)
            XCTAssertEqual(header.protocol, .reservedForTesting)
            XCTAssertEqual(Int(header.totalLength), IPv4Header.size + data.readableBytes)
            XCTAssertEqual(header.sourceIpAdress, .init(127, 0, 0, 1))
            XCTAssertEqual(header.destinationIpAddress, .init(127, 0, 0, 1))
            return String(buffer: data)
        })
        
        XCTAssertEqual(receivedMessages, Set(expectedMessages))
    }
    
}
