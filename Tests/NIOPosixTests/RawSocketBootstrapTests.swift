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
        let expectedMessages = (1...10).map { "Hello World \($0)" }
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
            #if canImport(Darwin)
            // On BSD the IP header will only contain the size of the ip packet body not the header.
            // This is known bug which can't be fixed without breaking old apps which already workaround the issue
            // like we do.
            XCTAssertEqual(Int(header.totalLength), data.readableBytes)
            // On BSD the checksum is always zero
            XCTAssertEqual(header.headerChecksum, 0)
            #elseif os(Linux)
            XCTAssertEqual(Int(header.totalLength), IPv4Header.size + data.readableBytes)
            XCTAssertTrue(header.isValidChecksum(), "\(header)")
            #endif
            
            XCTAssertEqual(header.sourceIpAddress, .init(127, 0, 0, 1))
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
        
        let expectedMessages = (1...10).map { "Hello World \($0)" }
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
            #if canImport(Darwin)
            // On BSD the IP header will only contain the size of the ip packet body not the header.
            // This is known bug which can't be fixed without breaking old apps which already workaround the issue
            // like we do.
            XCTAssertEqual(Int(header.totalLength), data.readableBytes)
            // On BSD the checksum is always zero
            XCTAssertEqual(header.headerChecksum, 0)
            #elseif os(Linux)
            XCTAssertEqual(Int(header.totalLength), IPv4Header.size + data.readableBytes)
            XCTAssertTrue(header.isValidChecksum(), "\(header)")
            #endif
            XCTAssertTrue(header.isValidChecksum())
            XCTAssertEqual(header.sourceIpAddress, .init(127, 0, 0, 1))
            XCTAssertEqual(header.destinationIpAddress, .init(127, 0, 0, 1))
            return String(buffer: data)
        })
        
        XCTAssertEqual(receivedMessages, Set(expectedMessages))
    }
    
    func testIpHdrincl() throws {
        try XCTSkipIfUserHasNotEnoughRightsForRawSocketAPI()
        
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }
        let channel = try RawSocketBootstrap(group: elg)
            .channelOption(ChannelOptions.ipOption(.ip_hdrincl), value: 1)
            .channelInitializer {
                $0.pipeline.addHandler(DatagramReadRecorder<ByteBuffer>(), name: "ByteReadRecorder")
            }
            .bind(host: "127.0.0.1", ipProtocol: .reservedForTesting).wait()
        defer { XCTAssertNoThrow(try channel.close().wait()) }
        try channel.configureForRecvMmsg(messageCount: 10)
        let expectedMessages = (1...10).map { "Hello World \($0)" }
        for message in expectedMessages.map(ByteBuffer.init(string:)) {
            var packet = ByteBuffer()
            var header = IPv4Header()
            header.version = 4
            header.internetHeaderLength = 5
            header.totalLength = UInt16(IPv4Header.size + message.readableBytes)
            header.protocol = .reservedForTesting
            header.timeToLive = 64
            header.destinationIpAddress = .init(127, 0, 0, 1)
            header.sourceIpAddress = .init(127, 0, 0, 1)
            header.setChecksum()
            header.write(to: &packet)
            packet.writeImmutableBuffer(message)
            _ = try channel.write(AddressedEnvelope(
                remoteAddress: SocketAddress(ipAddress: "127.0.0.1", port: 0),
                data: packet
            ))
        }
        channel.flush()
        
        let receivedMessages = Set(try channel.waitForDatagrams(count: 10).map { envelop -> String in
            var data = envelop.data
            let header = try XCTUnwrap(IPv4Header(buffer: &data))
            XCTAssertEqual(header.version, 4)
            XCTAssertEqual(header.protocol, .reservedForTesting)
            #if canImport(Darwin)
            // On BSD the IP header will only contain the size of the ip packet body not the header.
            // This is known bug which can't be fixed without breaking old apps which already workaround the issue
            // like we do.
            XCTAssertEqual(Int(header.totalLength), data.readableBytes)
            #elseif os(Linux)
            XCTAssertEqual(Int(header.totalLength), IPv4Header.size + data.readableBytes)
            #endif
            XCTAssertTrue(header.isValidChecksum())
            XCTAssertEqual(header.sourceIpAddress, .init(127, 0, 0, 1))
            XCTAssertEqual(header.destinationIpAddress, .init(127, 0, 0, 1))
            return String(buffer: data)
        })
        
        XCTAssertEqual(receivedMessages, Set(expectedMessages))
    }
}
