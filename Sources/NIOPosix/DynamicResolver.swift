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

/// A protocol that covers an object that does DNS A and AAAA queries via a single method.
protocol DNSResolver {
    associatedtype T
    
    /// Initiate DNS A and AAAA queries for a given host.
    ///
    /// - parameters:
    ///     - host: The hostname to do a lookup on.
    ///     - port: The port we'll be connecting to.
    /// - returns: The future results (A and AAAA) of the lookup, as well as the instance of the resolver that performed the lookup.
    func initiateDNSLookup(host: String, port: Int) -> DNSResolverResult
    
    /// Cancel all outstanding DNS queries of resolver.
    func cancelQueries(resolver: T)
}

/// The result of a lookup performed by resolver.
/// Stores the A and AAAA futures as well as the instance of the resolver that performed the lookup.
struct DNSResolverResult {
    let resolver: Resolver
    let v4Future: EventLoopFuture<[SocketAddress]>
    let v6Future: EventLoopFuture<[SocketAddress]>
}

/// Wraps a use-exactly-once resolver and allows to use it never or more than once.
///
/// It uses a different instance of the wrapped resolver each time a lookup is performed.
/// This can be useful in situations where it's not possible to assure that the resolver's single-use nature is honored.
class DynamicResolver<T: Resolver>: DNSResolver {
    private let resolverFactory: () -> T
    
    init(resolverFactory: @escaping () -> T) {
        self.resolverFactory = resolverFactory
    }
    
    func initiateDNSLookup(host: String, port: Int) -> DNSResolverResult {
        let resolver = resolverFactory()
        let v4Future = resolver.initiateAQuery(host: host, port: port)
        let v6Future = resolver.initiateAAAAQuery(host: host, port: port)
        return DNSResolverResult(resolver: resolver, v4Future: v4Future, v6Future: v6Future)
    }
    
    func cancelQueries(resolver: Resolver) {
        resolver.cancelQueries()
    }
}
