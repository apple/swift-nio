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

/// A protocol that covers an object that does DNS lookups.
///
/// In general the rules for the resolver are relatively broad: there are no specific requirements on how
/// it operates. However, the rest of the code assumes that it obeys RFC 6724, particularly section 6 on
/// ordering returned addresses. That is, the IPv6 and IPv4 responses should be ordered by the destination
/// address ordering rules from that RFC. This specification is widely implemented by getaddrinfo
/// implementations, so any implementation based on getaddrinfo will work just fine. In the future, a custom
/// resolver will need also to implement these sorting rules.
public protocol Resolver {
    /// Initiate a DNS A query for a given host.
    ///
    /// - parameters:
    ///     - host: The hostname to do an A lookup on.
    ///     - port: The port we'll be connecting to.
    /// - returns: An `EventLoopFuture` that fires with the result of the lookup.
    func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]>

    /// Initiate a DNS AAAA query for a given host.
    ///
    /// - parameters:
    ///     - host: The hostname to do an AAAA lookup on.
    ///     - port: The port we'll be connecting to.
    /// - returns: An `EventLoopFuture` that fires with the result of the lookup.
    func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]>

    /// Cancel all outstanding DNS queries.
    ///
    /// This method is called whenever queries that have not completed no longer have their
    /// results needed. The resolver should, if possible, abort any outstanding queries and
    /// clean up their state.
    ///
    /// This method is not guaranteed to terminate the outstanding queries.
    func cancelQueries()
}
