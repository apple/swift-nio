//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if !os(WASI)

import NIOConcurrencyHelpers
import NIOCore
import XCTest

@testable import NIOPosix

private final class SingleUseTestResolver: Resolver, @unchecked Sendable {
    private let loop: EventLoop
    private let address: SocketAddress
    private let queryCount = NIOLockedValueBox(0)

    init(loop: EventLoop, address: SocketAddress) {
        self.loop = loop
        self.address = address
    }

    var numberOfQueries: Int {
        self.queryCount.withLockedValue { $0 }
    }

    func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        self.queryCount.withLockedValue { $0 += 1 }
        return self.loop.makeSucceededFuture([self.address])
    }

    func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        self.queryCount.withLockedValue { $0 += 1 }
        return self.loop.makeSucceededFuture([])
    }

    func cancelQueries() {}
}

final class NIODynamicResolverTest: XCTestCase {
    func testCreatesFreshResolverForConcurrentConnections() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let server = try ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeSucceededFuture(())
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        defer {
            XCTAssertNoThrow(try server.close().wait())
        }

        let address = try XCTUnwrap(server.localAddress)
        let resolvers = NIOLockedValueBox<[SingleUseTestResolver]>([])
        let dynamicResolver = NIODynamicResolver { eventLoop in
            let resolver = SingleUseTestResolver(loop: eventLoop, address: address)
            resolvers.withLockedValue { $0.append(resolver) }
            return resolver
        }

        let bootstrap = ClientBootstrap(group: group)
            .resolver(dynamicResolver)
            .channelInitializer { channel in
                channel.eventLoop.makeSucceededFuture(())
            }

        let connectionFutures = (0..<2).map { _ in
            bootstrap.connect(host: "dynamic-resolver.test", port: address.port!)
        }
        let channels = try connectionFutures.map { try $0.wait() }
        defer {
            for channel in channels {
                XCTAssertNoThrow(try channel.close().wait())
            }
        }

        let createdResolvers = resolvers.withLockedValue { $0 }
        XCTAssertEqual(createdResolvers.count, 2)
        XCTAssertTrue(createdResolvers.allSatisfy { $0.numberOfQueries == 2 })
    }
}

#endif  // !os(WASI)
