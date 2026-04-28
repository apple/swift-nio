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

import NIOCore
import Testing

#if !os(WASI)
@testable import NIOPosix

/// A mock DNS resolver that returns pre-configured results without real DNS lookups.
private final class MockResolver: Resolver, @unchecked Sendable {
    private let loop: EventLoop
    private let v4Results: [SocketAddress]
    private let v6Results: [SocketAddress]

    init(loop: EventLoop, v4Results: [SocketAddress] = [], v6Results: [SocketAddress] = []) {
        self.loop = loop
        self.v4Results = v4Results
        self.v6Results = v6Results
    }

    func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        self.loop.makeSucceededFuture(self.v4Results)
    }

    func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        self.loop.makeSucceededFuture(self.v6Results)
    }

    func cancelQueries() {}
}

/// A mock DNS resolver that always fails with an error.
private final class FailingMockResolver: Resolver, @unchecked Sendable {
    private let loop: EventLoop

    struct MockDNSError: Error {}

    init(loop: EventLoop) {
        self.loop = loop
    }

    func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        self.loop.makeFailedFuture(MockDNSError())
    }

    func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        self.loop.makeFailedFuture(MockDNSError())
    }

    func cancelQueries() {}
}

/// A mock DNS resolver that tracks whether cancelQueries was called.
private final class CancelTrackingMockResolver: Resolver, @unchecked Sendable {
    private let loop: EventLoop
    private(set) var cancelQueriesCalled = false

    init(loop: EventLoop) {
        self.loop = loop
    }

    func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        self.loop.makeSucceededFuture([])
    }

    func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        self.loop.makeSucceededFuture([])
    }

    func cancelQueries() {
        self.cancelQueriesCalled = true
    }
}

@Suite("NIORandomizedDNSResolverTest")
struct NIORandomizedDNSResolverTest {

    @Test
    func defaultInitializerResolves() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        let resolver = NIORandomizedDNSResolver(loop: group.next())

        // Both queries must be initiated before awaiting — initiateAAAAQuery
        // triggers the actual getaddrinfo call that completes both futures.
        let v4Future = resolver.initiateAQuery(host: "127.0.0.1", port: 80)
        let v6Future = resolver.initiateAAAAQuery(host: "127.0.0.1", port: 80)

        let addressV4 = try await v4Future.get()
        let addressV6 = try await v6Future.get()
        let expectedV4 = try SocketAddress(ipAddress: "127.0.0.1", port: 80)
        #expect(addressV4.count == 1)
        #expect(addressV4[0] == expectedV4)
        #expect(addressV6.isEmpty)
    }

    @Test
    func dnsFailurePropagates() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        let mock = FailingMockResolver(loop: group.next())
        let resolver = NIORandomizedDNSResolver(resolver: mock)

        #expect(throws: (any Error).self) {
            try resolver.initiateAQuery(host: "any.host", port: 80).wait()
        }
        #expect(throws: (any Error).self) {
            try resolver.initiateAAAAQuery(host: "any.host", port: 80).wait()
        }
    }

    @Test
    func multipleAddressesAreReversed() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        let v4Addresses = try (1...5).map {
            try SocketAddress(ipAddress: "10.0.0.\($0)", port: 80)
        }
        let mock = MockResolver(loop: group.next(), v4Results: v4Addresses)
        let resolver = NIORandomizedDNSResolver(
            resolver: mock,
            shuffleFunction: { $0.reversed() }
        )

        let results = try resolver.initiateAQuery(host: "multi.example.com", port: 80).wait()
        let expected = try (1...5).reversed().map {
            try SocketAddress(ipAddress: "10.0.0.\($0)", port: 80)
        }

        #expect(results.count == 5)
        #expect(results == expected)
    }

    @Test
    func multipleV6AddressesAreReversed() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        let v6Addresses = try (1...5).map {
            try SocketAddress(ipAddress: "fe80::\($0)", port: 443)
        }
        let mock = MockResolver(loop: group.next(), v6Results: v6Addresses)
        let resolver = NIORandomizedDNSResolver(
            resolver: mock,
            shuffleFunction: { $0.reversed() }
        )

        let results = try resolver.initiateAAAAQuery(host: "multi.example.com", port: 443).wait()
        let expected = try (1...5).reversed().map {
            try SocketAddress(ipAddress: "fe80::\($0)", port: 443)
        }

        #expect(results.count == 5)
        #expect(results == expected)
    }

    @Test
    func cancelQueriesForwardsToUnderlying() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        let mock = CancelTrackingMockResolver(loop: group.next())
        let resolver = NIORandomizedDNSResolver(resolver: mock)

        #expect(!mock.cancelQueriesCalled)
        resolver.cancelQueries()
        #expect(mock.cancelQueriesCalled)
    }
}
#endif  // !os(WASI)
