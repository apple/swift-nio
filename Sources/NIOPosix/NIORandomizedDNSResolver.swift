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

import NIOCore

/// A DNS resolver that randomizes the order of addresses returned by the system resolver
/// to enable round-robin DNS load balancing.
///
/// By default, the system's `getaddrinfo` function returns addresses in a deterministic order
/// as specified by RFC 6724 (destination address selection). While this ordering is correct
/// per the RFC, it defeats DNS-based load balancing techniques such as those used by Kubernetes
/// headless services, where multiple A/AAAA records are returned and clients are expected to
/// distribute connections across all available backends.
///
/// `NIORandomizedDNSResolver` wraps the standard `getaddrinfo`-based resolver and shuffles the
/// returned addresses within each address family (IPv4 and IPv6 independently) before returning
/// them. This ensures that connection attempts are distributed across all available backends
/// rather than always targeting the same one.
///
/// This resolver is a single-use object: it can only be used to perform a single host resolution,
/// just like the underlying system resolver.
///
/// ### Usage with `ClientBootstrap`
///
/// ```swift
/// let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
/// let bootstrap = ClientBootstrap(group: group)
///     .resolver(NIORandomizedDNSResolver(loop: group.next()))
/// let channel = try await bootstrap.connect(
///     host: "my-service.default.svc.cluster.local",
///     port: 8080
/// ).get()
/// ```
public final class NIORandomizedDNSResolver: Resolver, Sendable {
    private let underlying: Resolver & Sendable

    /// The function used to shuffle address results. Defaults to `Array.shuffled()`.
    /// Exposed as `internal` to allow deterministic testing via `@testable import`.
    internal let shuffleFunction: @Sendable ([SocketAddress]) -> [SocketAddress]

    /// Create a new `NIORandomizedDNSResolver` for use with TCP stream connections.
    ///
    /// - Parameters:
    ///   - loop: The `EventLoop` to use for DNS resolution.
    public init(loop: EventLoop) {
        self.underlying = GetaddrinfoResolver(
            loop: loop,
            aiSocktype: .stream,
            aiProtocol: .tcp
        )
        self.shuffleFunction = { $0.shuffled() }
    }

    /// Internal initializer for testing with an injectable resolver and shuffle function.
    ///
    /// - Parameters:
    ///   - resolver: The underlying resolver to delegate DNS queries to.
    ///   - shuffleFunction: A function that reorders the address array. Defaults to `Array.shuffled()`.
    init(
        resolver: Resolver & Sendable,
        shuffleFunction: @escaping @Sendable ([SocketAddress]) -> [SocketAddress] = { $0.shuffled() }
    ) {
        self.underlying = resolver
        self.shuffleFunction = shuffleFunction
    }

    /// Initiate a DNS A query for a given host.
    ///
    /// The results from the underlying system resolver are shuffled before being returned.
    ///
    /// - Parameters:
    ///   - host: The hostname to do an A lookup on.
    ///   - port: The port we'll be connecting to.
    /// - Returns: An `EventLoopFuture` that fires with the shuffled result of the A lookup.
    public func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        self.underlying.initiateAQuery(host: host, port: port).map { self.shuffleFunction($0) }
    }

    /// Initiate a DNS AAAA query for a given host.
    ///
    /// The results from the underlying system resolver are shuffled before being returned.
    ///
    /// - Parameters:
    ///   - host: The hostname to do a AAAA lookup on.
    ///   - port: The port we'll be connecting to.
    /// - Returns: An `EventLoopFuture` that fires with the shuffled result of the AAAA lookup.
    public func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        self.underlying.initiateAAAAQuery(host: host, port: port).map { self.shuffleFunction($0) }
    }

    /// Cancel all outstanding DNS queries.
    ///
    /// This forwards the cancellation to the underlying system resolver.
    public func cancelQueries() {
        self.underlying.cancelQueries()
    }
}

#endif  // !os(WASI)
