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

import NIOCore
@testable import NIOPosix
import XCTest

class GetaddrinfoResolverTest: XCTestCase {

    func testResolveNoDuplicatesV4() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let resolver = GetaddrinfoResolver(aiSocktype: .stream, aiProtocol: .tcp)
        let future = resolver.resolve(name: "127.0.0.1", destinationPort: 12345, on: group.next())

        let results = try future.wait()
        XCTAssertEqual(1, results.count)
        XCTAssertEqual(try SocketAddress(ipAddress: "127.0.0.1", port: 12345), results[0])
    }

    func testResolveNoDuplicatesV6() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let resolver = GetaddrinfoResolver(aiSocktype: .stream, aiProtocol: .tcp)
        let future = resolver.resolve(name: "::1", destinationPort: 12345, on: group.next())

        let results = try future.wait()
        XCTAssertEqual(1, results.count)
        XCTAssertEqual(try SocketAddress(ipAddress: "::1", port: 12345), results[0])
    }
}
