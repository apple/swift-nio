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
#endif

extension NIOIPProtocol {
    static let reservedForTesting = Self(rawValue: 253)
}

final class RawSocketBootstrapTests: XCTestCase {
    func testWriteAndRead() throws {
        #if canImport(Darwin)
        try XCTSkipIf(geteuid() != 0, "Raw Socket API requires root privileges on Darwin")
        #endif
        
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
        
        let receivedMessages = Set(try channel.waitForDatagrams(count: 10).map(\.data).map { buffer in
            String(
                decoding: buffer.readableBytesView.dropFirst(4 * 5), // skip the IPv4 header
                as: UTF8.self
            )
        })
        
        XCTAssertEqual(receivedMessages, Set(expectedMessages))
    }
}
