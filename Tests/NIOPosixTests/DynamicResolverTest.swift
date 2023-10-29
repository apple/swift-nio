//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2023 Apple Inc. and the SwiftNIO project authors
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

class DynamicResolverTest: XCTestCase {
    
    func testDynamicResolver() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let dynamicResolver = DynamicResolver(){ GetaddrinfoResolver(loop: group.next(), aiSocktype: .stream, aiProtocol: .tcp) }
        
        let resolutionFirstQuery = dynamicResolver.initiateDNSLookup(host: "127.0.0.1", port: 12345)
        // Should have no effect, as the cancelQueries implementation of `GetaddrinfoResolver` is a no-op.
        dynamicResolver.cancelQueries(resolver: resolutionFirstQuery.resolver)
        let addressV4FirstResult = try resolutionFirstQuery.v4Future.wait()
        let addressV6FirstResult = try resolutionFirstQuery.v6Future.wait()

        XCTAssertEqual(1, addressV4FirstResult.count)
        XCTAssertEqual(try SocketAddress(ipAddress: "127.0.0.1", port: 12345), addressV4FirstResult[0])
        XCTAssertTrue(addressV6FirstResult.isEmpty)
        
        let resolutionSecondQuery = dynamicResolver.initiateDNSLookup(host: "::1", port: 12345)
        // Should have no effect, as the cancelQueries implementation of `GetaddrinfoResolver` is a no-op.
        dynamicResolver.cancelQueries(resolver: resolutionSecondQuery.resolver)
        let addressV4SecondResult = try resolutionSecondQuery.v4Future.wait()
        let addressV6SecondResult = try resolutionSecondQuery.v6Future.wait()

        XCTAssertEqual(1, addressV6SecondResult.count)
        XCTAssertEqual(try SocketAddress(ipAddress: "::1", port: 12345), addressV6SecondResult[0])
        XCTAssertTrue(addressV4SecondResult.isEmpty)
    }
}
