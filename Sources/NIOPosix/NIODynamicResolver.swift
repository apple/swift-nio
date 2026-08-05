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

/// A factory for resolvers that can be used with ``ClientBootstrap``.
///
/// A resolver is normally a single-use object: it performs one pair of A and AAAA
/// queries and is then discarded. ``NIODynamicResolver`` creates a new resolver for
/// every hostname connection, which makes it safe to configure a reusable
/// ``ClientBootstrap`` with a resolver that has single-use state.
///
/// The factory is called once when ``ClientBootstrap/connect(host:port:)`` starts a
/// resolution. Concurrent connections each receive a different resolver instance.
///
/// - Important: The factory must return a resolver configured for the supplied event
///   loop. The returned resolver must not be shared between connections.
public final class NIODynamicResolver: Sendable {
    private let resolverFactory: @Sendable (EventLoop) -> (Resolver & Sendable)

    /// Create a dynamic resolver from a resolver factory.
    ///
    /// - Parameter resolverFactory: A closure that creates a fresh resolver for the
    ///   event loop used by a connection.
    public init<ResolverType: Resolver & Sendable>(
        resolverFactory: @escaping @Sendable (EventLoop) -> ResolverType
    ) {
        self.resolverFactory = { eventLoop in
            resolverFactory(eventLoop)
        }
    }

    internal func makeResolver(for eventLoop: EventLoop) -> Resolver & Sendable {
        self.resolverFactory(eventLoop)
    }
}

#endif  // !os(WASI)
