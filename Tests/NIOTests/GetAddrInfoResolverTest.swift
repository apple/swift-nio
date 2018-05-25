//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import NIO
import XCTest

class GetaddrinfoResolverTest: XCTestCase {

    func testResolveNoDuplicatesV4() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let resolver = GetaddrinfoResolver(loop: group.next(), aiSocktype: Posix.SOCK_STREAM, aiProtocol: Posix.IPPROTO_TCP)
        let v4Future = resolver.initiateAQuery(host: "127.0.0.1", port: 12345)
        let v6Future = resolver.initiateAAAAQuery(host: "127.0.0.1", port: 12345)

        let addressV4 = try v4Future.wait()
        let addressV6 = try v6Future.wait()
        XCTAssertEqual(1, addressV4.count)
        XCTAssertEqual(try SocketAddress(ipAddress: "127.0.0.1", port: 12345), addressV4[0])
        XCTAssertTrue(addressV6.isEmpty)
    }

    func testResolveNoDuplicatesV6() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let resolver = GetaddrinfoResolver(loop: group.next(), aiSocktype: Posix.SOCK_STREAM, aiProtocol: Posix.IPPROTO_TCP)
        let v4Future = resolver.initiateAQuery(host: "::1", port: 12345)
        let v6Future = resolver.initiateAAAAQuery(host: "::1", port: 12345)

        let addressV4 = try v4Future.wait()
        let addressV6 = try v6Future.wait()
        XCTAssertEqual(1, addressV6.count)
        XCTAssertEqual(try SocketAddress(ipAddress: "::1", port: 12345), addressV6[0])
        XCTAssertTrue(addressV4.isEmpty)
    }
}
