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
import NIOConcurrencyHelpers

/// A protocol that covers an object that performs name resolution.
///
/// In general the rules for the resolver are relatively broad: there are no specific requirements on how
/// it operates. However, the rest of the code currently assumes that it obeys RFC 6724, particularly section 6 on
/// ordering returned addresses. That is, when possible, the IPv6 and IPv4 responses should be ordered by the destination
/// address ordering rules from that RFC. This specification is widely implemented by getaddrinfo
/// implementations, so any implementation based on getaddrinfo will work just fine. Other implementations
/// may need also to implement these sorting rules for the moment.
public protocol NIOStreamingResolver {
    /// Start a name resolution for a given name.
    ///
    /// - parameters:
    ///     - name: The name to resolve.
    ///     - destinationPort: The port we'll be connecting to.
    ///     - session: The resolution session object associated with the resolution.
    func resolve(name: String, destinationPort: Int, session: NIONameResolutionSession)

    /// Cancel an outstanding name resolution.
    ///
    /// This method is called whenever a name resolution that hasn't completed no longer has its
    /// results needed. The resolver should, if possible, abort any outstanding queries and clean
    /// up their state.
    ///
    /// This method is not guaranteed to terminate the outstanding queries.
    ///
    /// - parameters:
    ///     - session: The resolution session object associated with the resolution.
    func cancel(_ session: NIONameResolutionSession)
}

/// An object used by a resolver to deliver results and inform about the completion of a name
/// resolution.
///
/// A resolution session object is associated with a single name resolution.
public final class NIONameResolutionSession: @unchecked Sendable {
    private let lock: NIOLock
    private var resultsHandler: ResultsHandler?
    private var completionHandler: CompletionHandler?
    
    /// Create a `NIONameResolutionSession`.
    ///
    /// The `resultsHandler` and `completionHandler` closures are retained by the resolution session
    /// until one of the following happens:
    ///   - All references to the resolution session are dropped.
    ///   - The `resolutionComplete` method is called.
    ///   - The `cancelledBy` future completes.
    ///
    /// - parameters:
    ///     - resultsHandler: A closure that will be fired when new results are delivered.
    ///     - completionHandler: A close that will be fired when the name resolution completes.
    ///     - cancelledBy: A future that will be completed when the resolution session is no longer
    ///       needed.
    public init<T>(
        resultsHandler: @Sendable @escaping ([SocketAddress]) -> Void,
        completionHandler: @Sendable @escaping (Result<Void, Error>) -> Void,
        cancelledBy: EventLoopFuture<T>
    ) {
        self.lock = NIOLock()
        self.resultsHandler = resultsHandler
        self.completionHandler = completionHandler
        cancelledBy.whenComplete { _ in
            _ = self.invalidateAndReturnCompletionHandler()
        }
    }
    
    /// Create a `NIONameResolutionSession`.
    ///
    /// The `resultsHandler` and `completionHandler` closures are retained by the resolution session
    /// until one of the following happens:
    ///   - All references to the resolution session are dropped.
    ///   - The `resolutionComplete` method is called.
    ///
    /// - parameters:
    ///     - resultsHandler: A closure that will be fired when new results are delivered.
    ///     - completionHandler: A close that will be fired when the name resolution completes.
    public init(
        resultsHandler: @Sendable @escaping ([SocketAddress]) -> Void,
        completionHandler: @Sendable @escaping (Result<Void, Error>) -> Void
    ) {
        self.lock = NIOLock()
        self.resultsHandler = resultsHandler
        self.completionHandler = completionHandler
    }
    
    /// Deliver results for a name resolution.
    ///
    /// This method may be called any number of times until the name resolution completes. Calling
    /// this method with an empty array is allowed.
    ///
    /// - parameters:
    ///     - results: Zero or more socket addresses.
    public func deliverResults(_ results: [SocketAddress]) {
        let resultsHandler = self.lock.withLock { self.resultsHandler }
        resultsHandler?(results)
    }
    
    /// Signal the completion of a name resolution.
    ///
    /// Calling this method invalidates the resolution session. That is, all handlers are released
    /// and any future call to `deliverResults` or `resolutionComplete` will be silently ignored.
    ///
    /// - parameters:
    ///     - result: A `Result` value indicating whether the name resolution was successful or not.
    public func resolutionComplete(_ result: Result<Void, Error>) {
        let completionHandler = self.invalidateAndReturnCompletionHandler()
        completionHandler?(result)
    }
    
    private func invalidateAndReturnCompletionHandler() -> CompletionHandler? {
        self.lock.withLock {
            let completionHandler = self.completionHandler
            self.completionHandler = nil
            self.resultsHandler = nil
            return completionHandler
        }
    }
    
    private typealias ResultsHandler = ([SocketAddress]) -> Void
    private typealias CompletionHandler = (Result<Void, Error>) -> Void
}

extension NIOStreamingResolver {
    /// Start a non-cancellable name resolution that delivers all its result on completion.
    ///
    /// Results are accumulated until the name resolution completes.
    ///
    /// - parameters:
    ///     - name: The name to resolve.
    ///     - destinationPort: The port we'll be connecting to.
    ///     - eventLoop: The session associated with the resolution.
    /// - returns: A future that will receive the name resolution results.
    public func resolve(
        name: String, destinationPort: Int, on eventLoop: EventLoop
    ) -> EventLoopFuture<[SocketAddress]> {
        let box = NIOLockedValueBox([] as [SocketAddress])
        let promise = eventLoop.makePromise(of: [SocketAddress].self)
        
        let session = NIONameResolutionSession { results in
            box.withLockedValue {
                $0.append(contentsOf: results)
            }
        } completionHandler: { result in
            switch result {
            case .success:
                let results = box.withLockedValue({ $0 })
                promise.succeed(results)
            case .failure(let error):
                promise.fail(error)
            }
        }
        
        resolve(name: name, destinationPort: destinationPort, session: session)
        return promise.futureResult
    }
}

/// A protocol that covers an object that does DNS lookups.
///
/// In general the rules for the resolver are relatively broad: there are no specific requirements on how
/// it operates. However, the rest of the code assumes that it obeys RFC 6724, particularly section 6 on
/// ordering returned addresses. That is, the IPv6 and IPv4 responses should be ordered by the destination
/// address ordering rules from that RFC. This specification is widely implemented by getaddrinfo
/// implementations, so any implementation based on getaddrinfo will work just fine. In the future, a custom
/// resolver will need also to implement these sorting rules.
@available(*, deprecated, message: "Use NIOStreamingResoler instead.")
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

@available(*, deprecated)
internal struct NIOResolverToStreamingResolver: NIOStreamingResolver {
    var resolver: Resolver
    
    func resolve(name: String, destinationPort: Int, session: NIONameResolutionSession) {
        func deliverResults(_ results: [SocketAddress]) {
            if !results.isEmpty {
                session.deliverResults(results)
            }
        }
        
        let futures = [
            resolver.initiateAAAAQuery(host: name, port: destinationPort).map(deliverResults),
            resolver.initiateAQuery(host: name, port: destinationPort).map(deliverResults),
        ]
        let eventLoop = futures[0].eventLoop
        
        EventLoopFuture.whenAllComplete(futures, on: eventLoop).whenSuccess { results in
            for result in results {
                if case .failure = result {
                    return session.resolutionComplete(result)
                }
            }
            session.resolutionComplete(.success(()))
        }
    }
    
    func cancel(_ session: NIONameResolutionSession) {
        resolver.cancelQueries()
    }
}
