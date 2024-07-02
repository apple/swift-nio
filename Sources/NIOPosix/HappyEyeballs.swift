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

// This module implements Happy Eyeballs 2 (RFC 8305). A few notes should be made about the design.
//
// The natural implementation of RFC 8305 is to use an explicit FSM, and this module does so. However,
// it doesn't use the natural Swift idiom for an FSM of using an enum with mutating methods. The reason
// for this is that the RFC 8305 FSM here needs to trigger a number of concurrent asynchronous operations,
// each of which will register callbacks that attempt to mutate `self`. This gets tricky fast, because enums
// are value types, while all of these callbacks need to trigger state transitions on the same underlying
// state machine.
//
// For this reason, we fall back to the less Swifty but more clear approach of embedding the FSM in a class.
// We naturally still use an enum to hold our state, but the FSM is now inside a class, which makes the shared
// state nature of this FSM a bit clearer.

private extension Array where Element == EventLoopFuture<Channel> {
    mutating func remove(element: Element) {
        guard let channelIndex = self.firstIndex(where: { $0 === element }) else {
            return
        }

        remove(at: channelIndex)
    }
}

/// An error that occurred during connection to a given target.
public struct SingleConnectionFailure: Sendable {
    /// The target we were trying to connect to when we encountered the error.
    public let target: SocketAddress

    /// The error we encountered.
    public let error: Error
}

/// A representation of all the errors that happened during an attempt to connect
/// to a given host and port.
public struct NIOConnectionError: Error {
    /// The hostname SwiftNIO was trying to connect to.
    public let host: String

    /// The port SwiftNIO was trying to connect to.
    public let port: Int

    /// The error we encountered doing the name resolution, if any.
    public fileprivate(set) var resolutionError: Error? = nil

    /// The error we encountered doing the DNS A lookup, if any.
    @available(*, deprecated, renamed: "resolutionError")
    public var dnsAError: Error? { resolutionError }

    /// The error we encountered doing the DNS AAAA lookup, if any.
    @available(*, deprecated, renamed: "resolutionError")
    public var dnsAAAAError: Error? { resolutionError }

    /// The errors we encountered during the connection attempts.
    public fileprivate(set) var connectionErrors: [SingleConnectionFailure] = []

    fileprivate init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// A simple iterator that manages iterating over the possible targets.
///
/// This iterator knows how to merge together IPv4 and IPv6 addresses in a sensible way:
/// specifically, it keeps track of what the last address family it emitted was, and emits the
/// address of the opposite family next.
private struct TargetIterator: IteratorProtocol {
    typealias Element = SocketAddress

    private enum AddressFamily {
        case v4
        case v6
    }

    private var previousAddressFamily: AddressFamily = .v4
    private var v4Results: [SocketAddress] = []
    private var v6Results: [SocketAddress] = []

    mutating func resultsAvailable(_ results: [SocketAddress]) {
        for result in results {
            switch result.protocol {
            case .inet:
                v4Results.append(result)
            case .inet6:
                v6Results.append(result)
            default:
                break
            }
        }
    }

    mutating func next() -> Element? {
        switch previousAddressFamily {
        case .v4:
            return popV6() ?? popV4()
        case .v6:
            return popV4() ?? popV6()
        }
    }

    private mutating func popV4() -> SocketAddress? {
        if v4Results.count > 0 {
            previousAddressFamily = .v4
            return v4Results.removeFirst()
        }

        return nil
    }

    private mutating func popV6() -> SocketAddress? {
        if v6Results.count > 0 {
            previousAddressFamily = .v6
            return v6Results.removeFirst()
        }

        return nil
    }
}

/// Given a DNS resolver and an event loop, attempts to establish a connection to
/// the target host over both IPv4 and IPv6.
///
/// This class provides the code that implements RFC 8305: Happy Eyeballs 2. This
/// is a connection establishment strategy that attempts to efficiently and quickly
/// establish connections to a host that has multiple IP addresses available to it,
/// potentially over two different IP protocol versions (4 and 6).
///
/// This class should be created when a connection attempt is made and will remain
/// active until a connection is established. It is responsible for actually creating
/// connections and managing timeouts.
///
/// This class's public API is thread-safe: the constructor and `resolveAndConnect` can
/// be called from any thread. `resolveAndConnect` will dispatch itself to the event
/// loop to force serialization.
///
/// This class's private API is *not* thread-safe, and expects to be called from the
/// event loop thread of the `loop` it is passed.
///
/// The `ChannelBuilderResult` generic type can used to tunnel an arbitrary type
/// from the `channelBuilderCallback` to the `resolve` methods return value.
internal final class HappyEyeballsConnector<ChannelBuilderResult> {
    /// An enum for keeping track of connection state.
    private enum ConnectionState {
        /// Initial state. No work outstanding.
        case idle

        /// No results have been returned yet.
        case resolving

        /// The resolver has returned IPv4 results, but no IPv6 results yet, and the
        /// resolution delay has not yet elapsed.
        case resolvedWaiting

        /// The resolver has returned IPv6 results, or the resolution delay has elapsed.
        /// We can begin connecting immediately, but should not give up if we run out of
        /// targets until the resolver completes.
        case resolvedConnecting

        /// All DNS results are in. We can make connection attempts until we run out
        /// of targets.
        case allResolved

        /// The connection attempt is complete.
        case complete
    }

    /// An enum of inputs for the connector state machine.
    private enum ConnectorInput {
        /// Begin DNS resolution.
        case resolve

        /// The resolver received IPv4 results.
        case resolverIPv4ResultsAvailable

        /// The resolver received IPv6 results.
        case resolverIPv6ResultsAvailable

        /// The name resolution completed.
        case resolverCompleted

        /// The delay between the IPv4 result and the IPv6 result has elapsed.
        case resolutionDelayElapsed

        /// The delay between starting one connection and the next has elapsed.
        case connectDelayElapsed

        /// The overall connect timeout has elapsed.
        case connectTimeoutElapsed

        /// A connection attempt has succeeded.
        case connectSuccess

        /// A connection attempt has failed.
        case connectFailed

        /// There are no connect targets remaining: all have been connected to and
        /// failed.
        case noTargetsRemaining
    }

    /// The DNS resolver provided by the user.
    private let resolver: NIOStreamingResolver

    /// The event loop this connector will run on.
    private let loop: EventLoop

    /// The host name we're connecting to.
    private let host: String

    /// The port we're connecting to.
    private let port: Int

    /// A callback, provided by the user, that is used to build a channel.
    ///
    /// This callback is expected to build *and register* a channel with the event loop that
    /// was used with this resolver. It is free to set up the channel asynchronously, but note
    /// that the time taken to set the channel up will be counted against the connection delay,
    /// meaning that long channel setup times may cause more connections to be outstanding
    /// than intended.
    ///
    /// The channel builder callback takes an event loop and a protocol family as arguments.
    private let channelBuilderCallback: (EventLoop, NIOBSDSocket.ProtocolFamily) -> EventLoopFuture<(Channel, ChannelBuilderResult)>

    /// The amount of time to wait for an IPv6 response to come in after a IPv4 response is
    /// received. By default this is 50ms.
    private let resolutionDelay: TimeAmount
    
    private var resolutionSession: Optional<NIONameResolutionSession>

    /// A reference to the task that will execute after the resolution delay expires, if
    /// one is scheduled. This is held to ensure that we can cancel this task if the IPv6
    /// response comes in before the resolution delay expires.
    private var resolutionTask: Optional<Scheduled<Void>>

    /// The amount of time to wait for a connection to succeed before beginning a new connection
    /// attempt. By default this is 250ms.
    private let connectionDelay: TimeAmount

    /// A reference to the task that will execute after the connection delay expires, if one
    /// is scheduled. This is held to ensure that we can cancel this task if a connection
    /// succeeds before the connection delay expires.
    private var connectionTask: Optional<Scheduled<Void>>

    /// The amount of time to allow for the overall connection process before timing it out.
    private let connectTimeout: TimeAmount

    /// A reference to the task that will time us out.
    private var timeoutTask: Optional<Scheduled<Void>>

    /// The promise that will hold the final connected channel.
    private let resolutionPromise: EventLoopPromise<(Channel, ChannelBuilderResult)>

    /// Our state machine state.
    private var state: ConnectionState

    /// Our iterator of resolved targets. This keeps track of what targets are left to have
    /// connection attempts made to them, and emits them in the appropriate order as needed.
    private var targets: TargetIterator = TargetIterator()

    /// An array of futures of channels that are currently attempting to connect.
    ///
    /// This is kept to ensure that we can clean up after ourselves once a connection succeeds,
    /// and throw away all pending connection attempts that are no longer needed.
    private var pendingConnections: [EventLoopFuture<(Channel, ChannelBuilderResult)>] = []

    /// An object that holds any errors we encountered.
    private var error: NIOConnectionError

    @inlinable
    init(resolver: NIOStreamingResolver,
         loop: EventLoop,
         host: String,
         port: Int,
         connectTimeout: TimeAmount,
         resolutionDelay: TimeAmount = .milliseconds(50),
         connectionDelay: TimeAmount = .milliseconds(250),
         channelBuilderCallback: @escaping (EventLoop, NIOBSDSocket.ProtocolFamily) -> EventLoopFuture<(Channel, ChannelBuilderResult)>) {
        self.resolver = resolver
        self.loop = loop
        self.host = host
        self.port = port
        self.connectTimeout = connectTimeout
        self.channelBuilderCallback = channelBuilderCallback
        self.resolutionSession = nil
        self.resolutionTask = nil
        self.connectionTask = nil
        self.timeoutTask = nil

        self.state = .idle
        self.resolutionPromise = self.loop.makePromise()
        self.error = NIOConnectionError(host: host, port: port)

        precondition(resolutionDelay.nanoseconds > 0, "Resolution delay must be greater than zero, got \(resolutionDelay).")
        self.resolutionDelay = resolutionDelay

        precondition(connectionDelay >= .milliseconds(100) && connectionDelay <= .milliseconds(2000), "Connection delay must be between 100 and 2000 ms, got \(connectionDelay)")
        self.connectionDelay = connectionDelay
    }

    @inlinable
    convenience init(
        resolver: NIOStreamingResolver,
        loop: EventLoop,
        host: String,
        port: Int,
        connectTimeout: TimeAmount,
        resolutionDelay: TimeAmount = .milliseconds(50),
        connectionDelay: TimeAmount = .milliseconds(250),
        channelBuilderCallback: @escaping (EventLoop, NIOBSDSocket.ProtocolFamily) -> EventLoopFuture<Channel>
    ) where ChannelBuilderResult == Void {
        self.init(
            resolver: resolver,
            loop: loop,
            host: host,
            port: port,
            connectTimeout: connectTimeout,
            resolutionDelay: resolutionDelay,
            connectionDelay: connectionDelay) { loop, protocolFamily in
                channelBuilderCallback(loop, protocolFamily).map { ($0, ()) }
            }
    }

    /// Initiate a DNS resolution attempt using Happy Eyeballs 2.
    ///
    /// returns: An `EventLoopFuture` that fires with a connected `Channel`.
    @inlinable
    func resolveAndConnect() -> EventLoopFuture<(Channel, ChannelBuilderResult)> {
        // We dispatch ourselves onto the event loop, rather than do all the rest of our processing from outside it.
        self.loop.execute {
            self.timeoutTask = self.loop.scheduleTask(in: self.connectTimeout) { self.processInput(.connectTimeoutElapsed) }
            self.processInput(.resolve)
        }
        return resolutionPromise.futureResult
    }

    /// Initiate a DNS resolution attempt using Happy Eyeballs 2.
    ///
    /// returns: An `EventLoopFuture` that fires with a connected `Channel`.
    @inlinable
    func resolveAndConnect() -> EventLoopFuture<Channel> where ChannelBuilderResult == Void {
        self.resolveAndConnect().map { $0.0 }
    }

    /// Spin the state machine.
    ///
    /// - parameters:
    ///     - input: The input to the state machine.
    private func processInput(_ input: ConnectorInput) {
        switch (state, input) {
        // Only one valid transition from idle: to start resolving.
        case (.idle, .resolve):
            state = .resolving
            beginResolutionSession()

        // In the resolving state, we can exit four ways: either IPv4 results are available, IPv6
        // results are available, the resoler completes, or the overall connect timeout fires.
        case (.resolving, .resolverIPv4ResultsAvailable):
            state = .resolvedWaiting
            beginResolutionDelay()
        case (.resolving, .resolverIPv6ResultsAvailable):
            state = .resolvedConnecting
            beginConnecting()
        case (.resolving, .resolverCompleted):
            state = .allResolved
            beginConnecting()
        case (.resolving, .connectTimeoutElapsed):
            state = .complete
            timedOut()

        // In the resolvedWaiting state, a number of inputs are valid: More IPv4 results can be
        // available, IPv6 results can be available, the resolver can complete, the resolution
        // delay can elapse, and the overall connect timeout can fire.
        case (.resolvedWaiting, .resolverIPv4ResultsAvailable):
            break
        case (.resolvedWaiting, .resolverIPv6ResultsAvailable):
            state = .resolvedConnecting
            beginConnecting()
        case (.resolvedWaiting, .resolverCompleted):
            state = .allResolved
            beginConnecting()
        case (.resolvedWaiting, .resolutionDelayElapsed):
            state = .resolvedConnecting
            beginConnecting()
        case (.resolvedWaiting, .connectTimeoutElapsed):
            state = .complete
            timedOut()

        // In the resolvedConnecting state, a number of inputs are valid: More IPv4 or IPv6 results
        // can be available, the resolver can complete, the connectionDelay can elapse, the overall
        // connection timeout can fire, a connection can succeed, a connection can fail, and we can
        // run out of targets.
        case (.resolvedConnecting, .resolverIPv4ResultsAvailable):
            connectToNewTargets()
        case (.resolvedConnecting, .resolverIPv6ResultsAvailable):
            connectToNewTargets()
        case (.resolvedConnecting, .resolverCompleted):
            state = .allResolved
            connectToNewTargets()
        case (.resolvedConnecting, .connectDelayElapsed):
            connectionDelayElapsed()
        case (.resolvedConnecting, .connectTimeoutElapsed):
            state = .complete
            timedOut()
        case (.resolvedConnecting, .connectSuccess):
            state = .complete
            connectSuccess()
        case (.resolvedConnecting, .connectFailed):
            connectFailed()
        case (.resolvedConnecting, .noTargetsRemaining):
            // We are still waiting for the IPv6 results, so we
            // do nothing.
            break

        // In the allResolved state, a number of inputs are valid: the connectionDelay can elapse,
        // the overall connection timeout can fire, a connection can succeed, a connection can fail,
        // and possibly we can run out of targets.
        case (.allResolved, .connectDelayElapsed):
            connectionDelayElapsed()
        case (.allResolved, .connectTimeoutElapsed):
            state = .complete
            timedOut()
        case (.allResolved, .connectSuccess):
            state = .complete
            connectSuccess()
        case (.allResolved, .connectFailed):
            connectFailed()
        case (.allResolved, .noTargetsRemaining):
            state = .complete
            failed()

        // Once we've completed, it's not impossible that we'll get state machine events for
        // some amounts of work. For example, we could get late DNS results and late connection
        // notifications, and can also get late scheduled task callbacks. We want to just quietly
        // ignore these, as our transition into the complete state should have already sent
        // cleanup messages to all of these things.
        case (.complete, .resolverIPv4ResultsAvailable),
             (.complete, .resolverIPv6ResultsAvailable),
             (.complete, .resolverCompleted),
             (.complete, .connectSuccess),
             (.complete, .connectFailed),
             (.complete, .connectDelayElapsed),
             (.complete, .connectTimeoutElapsed),
             (.complete, .resolutionDelayElapsed):
            break
        default:
            fatalError("Invalid FSM transition attempt: state \(state), input \(input)")
        }
    }

    /// Fire off a pair of DNS queries.
    private func beginResolutionSession() {
        let resolutionSession = NIONameResolutionSession(
            resultsHandler: { [self] results in
                if self.loop.inEventLoop {
                    self.resolverDeliverResults(results)
                } else {
                    self.loop.execute {
                        self.resolverDeliverResults(results)
                    }
                }
            }, completionHandler: { result in
                if self.loop.inEventLoop {
                    self.resolutionComplete(result: result)
                } else {
                    self.loop.execute {
                        self.resolutionComplete(result: result)
                    }
                }
            }, cancelledBy: self.resolutionPromise.futureResult
        )
        self.resolutionSession = resolutionSession
        resolver.resolve(name: self.host, destinationPort: self.port, session: resolutionSession)
    }
    
    /// Called when IPv4 results are available before IPv6 results.
    ///
    /// Happy Eyeballs 2 prefers to connect over IPv6 if it's possible to do so. This means that
    /// if only IPv4 results are available we want to wait a small amount of time before we begin
    /// our connection attempts, in the hope that IPv6 results will be returned.
    ///
    /// This method sets off a scheduled task for the resolution delay.
    private func beginResolutionDelay() {
        resolutionTask = loop.scheduleTask(in: resolutionDelay, resolutionDelayComplete)
    }

    /// Called when we're ready to start connecting to targets.
    ///
    /// This function sets off the first connection attempt, and also sets the connect delay task.
    private func beginConnecting() {
        precondition(connectionTask == nil, "beginConnecting called while connection attempts outstanding")
        guard let target = targets.next() else {
            if self.pendingConnections.isEmpty {
                processInput(.noTargetsRemaining)
            }
            return
        }

        connectionTask = loop.scheduleTask(in: connectionDelay) { self.processInput(.connectDelayElapsed) }
        connectToTarget(target)
    }

    /// Called when the state machine wants us to connect to new targets, but we may already
    /// be connecting.
    ///
    /// This method takes into account the possibility that we may still be connecting to
    /// other targets.
    private func connectToNewTargets() {
        guard connectionTask == nil else {
            // Already connecting, no need to do anything here.
            return
        }

        // We're not in the middle of connecting, so we can start connecting!
        beginConnecting()
    }

    /// Called when the connection delay timer has elapsed.
    ///
    /// When the connection delay elapses we are going to initiate another connection
    /// attempt.
    private func connectionDelayElapsed() {
        connectionTask = nil
        beginConnecting()
    }

    /// Called when an outstanding connection attempt fails.
    ///
    /// This method checks that we don't have any connection attempts outstanding. If
    /// we discover we don't, it automatically triggers the next connection attempt.
    private func connectFailed() {
        if self.pendingConnections.isEmpty {
            self.connectionTask?.cancel()
            self.connectionTask = nil
            beginConnecting()
        }
    }

    /// Called when an outstanding connection attempt succeeds.
    ///
    /// Cleans up internal state.
    private func connectSuccess() {
        cleanUp()
    }

    /// Called when the overall connection timeout fires.
    ///
    /// Cleans up internal state and fails the connection promise.
    private func timedOut() {
        cleanUp()
        self.resolutionPromise.fail(ChannelError.connectTimeout(self.connectTimeout))
    }

    /// Called when we've attempted to connect to all our resolved targets,
    /// and were unable to connect to any of them.
    ///
    /// Asserts that there is nothing left on the internal state, and then fails the connection
    /// promise.
    private func failed() {
        precondition(pendingConnections.isEmpty, "failed with pending connections")
        cleanUp()
        self.resolutionPromise.fail(self.error)
    }

    /// Called to connect to a given target.
    ///
    /// - parameters:
    ///     - target: The address to connect to.
    private func connectToTarget(_ target: SocketAddress) {
        let channelFuture = channelBuilderCallback(self.loop, target.protocol)
        pendingConnections.append(channelFuture)

        channelFuture.whenSuccess { (channel, result) in
            // If we are in the complete state then we want to abandon this channel. Otherwise, begin
            // connecting.
            if case .complete = self.state {
                self.pendingConnections.removeAll { $0 === channelFuture }
                channel.close(promise: nil)
            } else {
                channel.connect(to: target).map {
                    // The channel has connected. If we are in the complete state we want to abandon this channel.
                    // Otherwise, fire the channel connected event. Either way we don't want the channel future to
                    // be in our list of pending connections, so we don't either double close or close the connection
                    // we want to use.
                    self.pendingConnections.removeAll { $0 === channelFuture }

                    if case .complete = self.state {
                        channel.close(promise: nil)
                    } else {
                        self.processInput(.connectSuccess)
                        self.resolutionPromise.succeed((channel, result))
                    }
                }.whenFailure { err in
                    // The connection attempt failed. If we're in the complete state then there's nothing
                    // to do. Otherwise, notify the state machine of the failure.
                    if case .complete = self.state {
                        assert(self.pendingConnections.firstIndex { $0 === channelFuture } == nil, "failed but was still in pending connections")
                    } else {
                        self.error.connectionErrors.append(SingleConnectionFailure(target: target, error: err))
                        self.pendingConnections.removeAll { $0 === channelFuture }
                        self.processInput(.connectFailed)
                    }
                }
            }
        }
        channelFuture.whenFailure { error in
            self.error.connectionErrors.append(SingleConnectionFailure(target: target, error: error))
            self.pendingConnections.removeAll { $0 === channelFuture }
            self.processInput(.connectFailed)
        }
    }

    // Cleans up all internal state, ensuring that there are no reference cycles and allowing
    // everything to eventually be deallocated.
    private func cleanUp() {
        assert(self.state == .complete, "Clean up in invalid state \(self.state)")

        if let resolutionSession = self.resolutionSession {
            self.resolver.cancel(resolutionSession)
            self.resolutionSession = nil
        }

        if let resolutionTask = self.resolutionTask {
            resolutionTask.cancel()
            self.resolutionTask = nil
        }

        if let connectionTask = self.connectionTask {
            connectionTask.cancel()
            self.connectionTask = nil
        }

        if let timeoutTask = self.timeoutTask {
            timeoutTask.cancel()
            self.timeoutTask = nil
        }

        let connections = self.pendingConnections
        self.pendingConnections = []
        for connection in connections {
            connection.whenSuccess { (channel, _) in channel.close(promise: nil) }
        }
    }
    
    private func resolverDeliverResults(_ results: [SocketAddress]) {
        self.targets.resultsAvailable(results)
        
        let protocols = results.map(\.protocol)
        if protocols.contains(.inet6) {
            self.resolutionTask?.cancel()
            self.resolutionTask = nil

            self.processInput(.resolverIPv6ResultsAvailable)
        } else if protocols.contains(.inet) {
            self.processInput(.resolverIPv4ResultsAvailable)
        }
    }
    
    private func resolutionComplete(result: Result<Void, Error>) {
        if case .failure(let error) = result {
            self.error.resolutionError = error
        }

        self.resolutionSession = nil

        self.resolutionTask?.cancel()
        self.resolutionTask = nil

        self.processInput(.resolverCompleted)
    }

    /// A future callback that fires when the resolution delay completes.
    private func resolutionDelayComplete() {
        resolutionTask = nil
        processInput(.resolutionDelayElapsed)
    }
}
