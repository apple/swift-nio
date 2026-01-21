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

import CNIOLinux
import NIOConcurrencyHelpers
import NIOEmbedded
import XCTest

@testable import NIOCore
@testable import NIOPosix

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Bionic)
import Bionic
#else
#error("The Happy Eyeballs test module was unable to identify your C library.")
#endif

private let CONNECT_RECORDER = "connectRecorder"
private let CONNECT_DELAYER = "connectDelayer"
private let SINGLE_IPv6_RESULT = [SocketAddress(host: "example.com", ipAddress: "fe80::1", port: 80)]
private let SINGLE_IPv4_RESULT = [SocketAddress(host: "example.com", ipAddress: "10.0.0.1", port: 80)]
private let MANY_IPv6_RESULTS = (1...10).map { SocketAddress(host: "example.com", ipAddress: "fe80::\($0)", port: 80) }
private let MANY_IPv4_RESULTS = (1...10).map { SocketAddress(host: "example.com", ipAddress: "10.0.0.\($0)", port: 80) }

extension Array where Element == Channel {
    fileprivate func finishAll() {
        for element in self {
            do {
                _ = try (element as! EmbeddedChannel).finish()
                // We're happy with no error
            } catch ChannelError.alreadyClosed {
                return  // as well as already closed.
            } catch {
                XCTFail("Finishing got error \(error)")
            }
        }
    }
}

private final class DummyError: Error, Equatable {
    // For dummy error equality is identity.
    static func == (lhs: DummyError, rhs: DummyError) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
}

private class ConnectRecorder: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    enum State {
        case idle
        case connected
        case closed
    }

    var targetHost: String?
    var state: State = .idle

    public func connect(context: ChannelHandlerContext, to: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.targetHost = to.toString()
        let connectPromise = promise ?? context.eventLoop.makePromise()
        connectPromise.futureResult.hop(to: context.eventLoop).assumeIsolated().whenSuccess {
            self.state = .connected
        }
        context.connect(to: to, promise: connectPromise)
    }

    public func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        let connectPromise = promise ?? context.eventLoop.makePromise()
        connectPromise.futureResult.hop(to: context.eventLoop).assumeIsolated().whenComplete {
            (_: Result<Void, Error>) in
            self.state = .closed
        }
        context.close(promise: connectPromise)
    }
}

private class ConnectionDelayer: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    var connectPromise: EventLoopPromise<Void>?

    func connect(context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.connectPromise = promise
    }
}

extension Channel {
    fileprivate func connectTarget() -> String? {
        try! self.pipeline.context(name: CONNECT_RECORDER).map {
            ($0.handler as! ConnectRecorder).targetHost
        }.wait()
    }

    fileprivate func succeedConnection() {
        try! self.pipeline.context(name: CONNECT_DELAYER).map {
            ($0.handler as! ConnectionDelayer).connectPromise!.succeed(())
        }.wait()
    }

    fileprivate func failConnection(error: Error) {
        try! self.pipeline.context(name: CONNECT_DELAYER).map {
            ($0.handler as! ConnectionDelayer).connectPromise!.fail(error)
        }.wait()
    }

    fileprivate func state() -> ConnectRecorder.State {
        try! self.pipeline.context(name: CONNECT_RECORDER).map {
            ($0.handler as! ConnectRecorder).state
        }.flatMapErrorThrowing {
            switch $0 {
            case ChannelPipelineError.notFound:
                return .closed
            default:
                throw $0
            }
        }.wait()
    }
}

extension SocketAddress {
    fileprivate init(host: String, ipAddress: String, port: Int) {
        do {
            var v4addr = in_addr()
            try NIOBSDSocket.inet_pton(addressFamily: .inet, addressDescription: ipAddress, address: &v4addr)

            var sockaddr = sockaddr_in()
            sockaddr.sin_family = sa_family_t(NIOBSDSocket.AddressFamily.inet.rawValue)
            sockaddr.sin_port = in_port_t(port).bigEndian
            sockaddr.sin_addr = v4addr
            self = .init(sockaddr, host: host)
        } catch {
            do {
                var v6addr = in6_addr()
                try NIOBSDSocket.inet_pton(addressFamily: .inet6, addressDescription: ipAddress, address: &v6addr)

                var sockaddr = sockaddr_in6()
                sockaddr.sin6_family = sa_family_t(NIOBSDSocket.AddressFamily.inet6.rawValue)
                sockaddr.sin6_port = in_port_t(port).bigEndian
                sockaddr.sin6_flowinfo = 0
                sockaddr.sin6_scope_id = 0
                sockaddr.sin6_addr = v6addr
                self = .init(sockaddr, host: host)
            } catch {
                fatalError("Unable to convert to IP")
            }
        }
    }

    fileprivate func toString() -> String {
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: 256, alignment: 1).bindMemory(
            to: Int8.self,
            capacity: 256
        )
        switch self {
        case .v4(let address):
            var baseAddress = address.address
            try! NIOBSDSocket.inet_ntop(
                addressFamily: .inet,
                addressBytes: &baseAddress.sin_addr,
                addressDescription: ptr,
                addressDescriptionLength: 256
            )
        case .v6(let address):
            var baseAddress = address.address
            try! NIOBSDSocket.inet_ntop(
                addressFamily: .inet6,
                addressBytes: &baseAddress.sin6_addr,
                addressDescription: ptr,
                addressDescriptionLength: 256
            )
        case .unixDomainSocket:
            fatalError("No UDS support in happy eyeballs.")
        }

        let ipString = String(cString: ptr)
        ptr.deinitialize(count: 256).deallocate()
        return ipString
    }
}

extension EventLoopFuture {
    fileprivate func getError() -> Error? {
        guard self.isFulfilled else { return nil }

        let errorBox = NIOLockedValueBox<Error?>(nil)
        self.whenFailure { error in
            errorBox.withLockedValue { $0 = error }
        }
        return errorBox.withLockedValue { $0! }
    }
}

// A simple resolver that allows control over the DNS resolution process.
private final class DummyResolver: Resolver, Sendable {
    let v4Promise: EventLoopPromise<[SocketAddress]>
    let v6Promise: EventLoopPromise<[SocketAddress]>

    enum Event: Sendable {
        case a(host: String, port: Int)
        case aaaa(host: String, port: Int)
        case cancel
    }

    private let _events: NIOLockedValueBox<[Event]>

    var events: [Event] {
        self._events.withLockedValue { $0 }
    }

    init(loop: EventLoop) {
        self._events = NIOLockedValueBox([])
        self.v4Promise = loop.makePromise()
        self.v6Promise = loop.makePromise()
    }

    func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        self._events.withLockedValue { $0.append(.a(host: host, port: port)) }
        return self.v4Promise.futureResult
    }

    func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        self._events.withLockedValue { $0.append(.aaaa(host: host, port: port)) }
        return self.v6Promise.futureResult
    }

    func cancelQueries() {
        self._events.withLockedValue { $0.append(.cancel) }
    }
}

extension DummyResolver.Event: Equatable {
}

@Sendable
private func defaultChannelBuilder(loop: EventLoop, family: NIOBSDSocket.ProtocolFamily) -> EventLoopFuture<Channel> {
    let channel = EmbeddedChannel(loop: loop as! EmbeddedEventLoop)
    XCTAssertNoThrow(
        try channel.pipeline.syncOperations.addHandler(ConnectRecorder(), name: CONNECT_RECORDER)
    )
    return loop.makeSucceededFuture(channel)
}

private func buildEyeballer(
    host: String,
    port: Int,
    connectTimeout: TimeAmount = .seconds(10),
    channelBuilderCallback: @escaping @Sendable (EventLoop, NIOBSDSocket.ProtocolFamily) -> EventLoopFuture<Channel> =
        defaultChannelBuilder
) -> (eyeballer: HappyEyeballsConnector<Void>, resolver: DummyResolver, loop: EmbeddedEventLoop) {
    let loop = EmbeddedEventLoop()
    let resolver = DummyResolver(loop: loop)
    let eyeballer = HappyEyeballsConnector(
        resolver: resolver,
        loop: loop,
        host: host,
        port: port,
        connectTimeout: connectTimeout,
        channelBuilderCallback: channelBuilderCallback
    )
    return (eyeballer: eyeballer, resolver: resolver, loop: loop)
}

final class HappyEyeballsTest: XCTestCase {
    func testIPv4OnlyResolution() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().flatMapThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        loop.run()
        resolver.v6Promise.fail(DummyError())
        resolver.v4Promise.succeed(SINGLE_IPv4_RESULT)
        loop.run()

        // No time should have needed to pass: we return only one target and it connects immediately.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "10.0.0.1")

        // We should have had queries for AAAA and A.
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        XCTAssertEqual(resolver.events, expectedQueries)
    }

    func testIPv6OnlyResolution() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().flatMapThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        loop.run()
        resolver.v4Promise.fail(DummyError())
        resolver.v6Promise.succeed(SINGLE_IPv6_RESULT)
        loop.run()

        // No time should have needed to pass: we return only one target and it connects immediately.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "fe80::1")

        // We should have had queries for AAAA and A.
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        XCTAssertEqual(resolver.events, expectedQueries)
    }

    func testTimeOutDuringDNSResolution() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .seconds(10))
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertFalse(channelFuture.isFulfilled)
        XCTAssertEqual(resolver.events, expectedQueries)

        loop.advanceTime(by: .seconds(9))
        XCTAssertFalse(channelFuture.isFulfilled)
        XCTAssertEqual(resolver.events, expectedQueries)

        loop.advanceTime(by: .seconds(1))
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])

        if case .some(ChannelError.connectTimeout(let amount)) = channelFuture.getError() {
            XCTAssertEqual(amount, .seconds(10))
        } else {
            XCTFail("Got \(String(describing: channelFuture.getError()))")
        }

        // We now want to confirm that nothing awful happens if those DNS results
        // return late.
        resolver.v6Promise.succeed(SINGLE_IPv6_RESULT)
        resolver.v4Promise.succeed(SINGLE_IPv4_RESULT)
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])
    }

    func testAAAAQueryReturningFirst() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().flatMapThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        resolver.v6Promise.succeed(SINGLE_IPv6_RESULT)
        loop.run()

        // No time should have needed to pass: we return only one target and it connects immediately.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "fe80::1")

        // We should have had queries for AAAA and A. We should then have had a cancel, because the A
        // never returned.
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])

        // Now return a result for the IPv4 query. Nothing bad should happen.
        resolver.v4Promise.succeed(SINGLE_IPv4_RESULT)
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])
    }

    func testAQueryReturningFirstDelayElapses() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().flatMapThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        resolver.v4Promise.succeed(SINGLE_IPv4_RESULT)
        loop.run()

        // There should have been no connection attempt yet.
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        // Let the resolution delay (default of 50 ms) elapse.
        loop.advanceTime(by: .milliseconds(49))
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)
        loop.advanceTime(by: .milliseconds(1))

        // The connection attempt should have been made with the IPv4 result.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "10.0.0.1")

        // We should have had queries for AAAA and A. We should then have had a cancel, because the A
        // never returned.
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])

        // Now return a result for the IPv6 query. Nothing bad should happen.
        resolver.v6Promise.succeed(SINGLE_IPv6_RESULT)
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])
    }

    func testAQueryReturningFirstThenAAAAReturns() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().flatMapThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        resolver.v4Promise.succeed(SINGLE_IPv4_RESULT)
        loop.run()

        // There should have been no connection attempt yet.
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        // Now the AAAA returns.
        resolver.v6Promise.succeed(SINGLE_IPv6_RESULT)
        loop.run()

        // The connection attempt should have been made with the IPv6 result.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "fe80::1")

        // We should have had queries for AAAA and A, with no cancel.
        XCTAssertEqual(resolver.events, expectedQueries)
    }

    func testAQueryReturningFirstThenAAAAErrors() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().flatMapThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        resolver.v4Promise.succeed(SINGLE_IPv4_RESULT)
        loop.run()

        // There should have been no connection attempt yet.
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        // Now the AAAA fails.
        resolver.v6Promise.fail(DummyError())
        loop.run()

        // The connection attempt should have been made with the IPv4 result.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "10.0.0.1")

        // We should have had queries for AAAA and A, with no cancel.
        XCTAssertEqual(resolver.events, expectedQueries)
    }

    func testAQueryReturningFirstThenEmptyAAAA() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().flatMapThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        resolver.v4Promise.succeed(SINGLE_IPv4_RESULT)
        loop.run()

        // There should have been no connection attempt yet.
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        // Now the AAAA returns empty.
        resolver.v6Promise.succeed([])
        loop.run()

        // The connection attempt should have been made with the IPv4 result.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "10.0.0.1")

        // We should have had queries for AAAA and A, with no cancel.
        XCTAssertEqual(resolver.events, expectedQueries)
    }

    func testEmptyResultsFail() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        resolver.v4Promise.succeed([])
        resolver.v6Promise.succeed([])
        loop.run()

        // We should have had queries for AAAA and A, with no cancel.
        XCTAssertEqual(resolver.events, expectedQueries)

        // But we should have failed.
        if let error = channelFuture.getError() as? NIOConnectionError {
            XCTAssertEqual(error.host, "example.com")
            XCTAssertEqual(error.port, 80)
            XCTAssertNil(error.dnsAError)
            XCTAssertNil(error.dnsAAAAError)
            XCTAssertEqual(error.connectionErrors.count, 0)
        } else {
            XCTFail("Got \(String(describing: channelFuture.getError()))")
        }
    }

    func testAllDNSFail() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        let v4Error = DummyError()
        let v6Error = DummyError()
        resolver.v4Promise.fail(v4Error)
        resolver.v6Promise.fail(v6Error)
        loop.run()

        // We should have had queries for AAAA and A, with no cancel.
        XCTAssertEqual(resolver.events, expectedQueries)

        // But we should have failed.
        if let error = channelFuture.getError() as? NIOConnectionError {
            XCTAssertEqual(error.host, "example.com")
            XCTAssertEqual(error.port, 80)
            XCTAssertEqual(error.dnsAError as? DummyError ?? DummyError(), v4Error)
            XCTAssertEqual(error.dnsAAAAError as? DummyError ?? DummyError(), v6Error)
            XCTAssertEqual(error.connectionErrors.count, 0)
        } else {
            XCTFail("Got \(String(describing: channelFuture.getError()))")
        }
    }

    func testMaximalConnectionDelay() throws {
        let channels = ChannelSet()
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .hours(1)) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.syncOperations.addHandler(
                    ConnectionDelayer(),
                    name: CONNECT_DELAYER,
                    position: .first
                )
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // We're providing the IPv4 and IPv6 results. This will lead to 20 total hosts
        // for us to try to connect to.
        resolver.v4Promise.succeed(MANY_IPv4_RESULTS)
        resolver.v6Promise.succeed(MANY_IPv6_RESULTS)

        for connectionCount in 1...20 {
            XCTAssertEqual(channels.count, connectionCount)
            loop.advanceTime(by: .milliseconds(249))
            XCTAssertEqual(channels.count, connectionCount)
            loop.advanceTime(by: .milliseconds(1))
        }

        // Now there will be no further connection attempts, even if we advance by a few minutes.
        loop.advanceTime(by: .minutes(5))
        XCTAssertEqual(channels.count, 20)

        // Check that we attempted to connect to these hosts in the appropriate interleaved
        // order.
        var expectedAddresses = [String]()
        for endIndex in 1...10 {
            expectedAddresses.append("fe80::\(endIndex)")
            expectedAddresses.append("10.0.0.\(endIndex)")
        }
        let actualAddresses = channels.map { $0.connectTarget()! }
        XCTAssertEqual(actualAddresses, expectedAddresses)

        // We still shouldn't have actually connected.
        XCTAssertFalse(channelFuture.isFulfilled)
        for channel in channels {
            XCTAssertEqual(channel.state(), .idle)
        }

        // Connect the last channel. This should immediately succeed the
        // future.
        channels.last!.succeedConnection()
        XCTAssertTrue(channelFuture.isFulfilled)
        let connectedChannel = try! channelFuture.wait()
        XCTAssertTrue(connectedChannel === channels.last)
        XCTAssertEqual(connectedChannel.state(), .connected)

        // The other channels should be closed.
        for channel in channels.dropLast() {
            XCTAssertEqual(channel.state(), .closed)
        }
    }

    func testAllConnectionsFail() throws {
        let channels = ChannelSet()
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .hours(1)) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.syncOperations.addHandler(
                    ConnectionDelayer(),
                    name: CONNECT_DELAYER,
                    position: .first
                )
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // We're providing the IPv4 and IPv6 results. This will lead to 20 total hosts
        // for us to try to connect to.
        resolver.v4Promise.succeed(MANY_IPv4_RESULTS)
        resolver.v6Promise.succeed(MANY_IPv6_RESULTS)

        // Let all the connections fire.
        for _ in 1...20 {
            loop.advanceTime(by: .milliseconds(250))
        }

        // We still shouldn't have actually connected.
        XCTAssertEqual(channels.count, 20)
        XCTAssertFalse(channelFuture.isFulfilled)
        for channel in channels {
            XCTAssertEqual(channel.state(), .idle)
        }

        // Fail all the connection attempts.
        var errors = [DummyError]()
        for channel in channels.dropLast() {
            let error = DummyError()
            errors.append(error)
            channel.failConnection(error: error)
            XCTAssertFalse(channelFuture.isFulfilled)
        }

        // Fail the last channel. This should immediately fail the future.
        errors.append(DummyError())
        channels.last!.failConnection(error: errors.last!)
        XCTAssertTrue(channelFuture.isFulfilled)

        // Check the error.
        if let error = channelFuture.getError() as? NIOConnectionError {
            XCTAssertEqual(error.host, "example.com")
            XCTAssertEqual(error.port, 80)
            XCTAssertNil(error.dnsAError)
            XCTAssertNil(error.dnsAAAAError)
            XCTAssertEqual(error.connectionErrors.count, 20)

            for (idx, error) in error.connectionErrors.enumerated() {
                XCTAssertEqual(error.error as? DummyError, errors[idx])
            }
        } else {
            XCTFail("Got \(String(describing: channelFuture.getError()))")
        }
    }

    func testDelayedAAAAResult() throws {
        let channels = ChannelSet()
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .hours(1)) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.syncOperations.addHandler(
                    ConnectionDelayer(),
                    name: CONNECT_DELAYER,
                    position: .first
                )
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Provide the IPv4 results and let five connection attempts play out.
        resolver.v4Promise.succeed(MANY_IPv4_RESULTS)
        loop.advanceTime(by: .milliseconds(50))

        for connectionCount in 1...4 {
            XCTAssertEqual(channels.last!.connectTarget()!, "10.0.0.\(connectionCount)")
            loop.advanceTime(by: .milliseconds(250))
        }
        XCTAssertEqual(channels.last!.connectTarget()!, "10.0.0.5")

        // Now the IPv6 results come in.
        resolver.v6Promise.succeed(MANY_IPv6_RESULTS)

        // The next 10 connection attempts will interleave the IPv6 and IPv4 results,
        // starting with IPv6.
        for connectionCount in 1...5 {
            loop.advanceTime(by: .milliseconds(250))
            XCTAssertEqual(channels.last!.connectTarget()!, "fe80::\(connectionCount)")
            loop.advanceTime(by: .milliseconds(250))
            XCTAssertEqual(channels.last!.connectTarget()!, "10.0.0.\(connectionCount + 5)")
        }

        // We're now out of IPv4 addresses, so the last 5 will be IPv6.
        for connectionCount in 6...10 {
            loop.advanceTime(by: .milliseconds(250))
            XCTAssertEqual(channels.last!.connectTarget()!, "fe80::\(connectionCount)")
        }
    }

    func testTimeoutWaitingForAAAA() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(
            host: "example.com",
            port: 80,
            connectTimeout: .milliseconds(49)
        )
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the A result returns, but the timeout is sufficiently low that the connect attempt
        // times out before the AAAA can return.
        resolver.v4Promise.succeed(SINGLE_IPv4_RESULT)
        loop.advanceTime(by: .milliseconds(48))
        XCTAssertFalse(channelFuture.isFulfilled)

        loop.advanceTime(by: .milliseconds(1))
        XCTAssertTrue(channelFuture.isFulfilled)

        // We should have had queries for AAAA and A. We should then have had a cancel, because the AAAA
        // never returned.
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])
        switch channelFuture.getError() {
        case .some(ChannelError.connectTimeout(.milliseconds(49))):
            break
        default:
            XCTFail("Got unexpected error: \(String(describing: channelFuture.getError()))")
        }
    }

    func testTimeoutAfterAQuery() throws {
        let channels = ChannelSet()
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(
            host: "example.com",
            port: 80,
            connectTimeout: .milliseconds(100)
        ) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.syncOperations.addHandler(
                    ConnectionDelayer(),
                    name: CONNECT_DELAYER,
                    position: .first
                )
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the A result returns, but the timeout is sufficiently low that the connect attempt
        // times out before the AAAA can return and before the connection succeeds.
        resolver.v4Promise.succeed(SINGLE_IPv4_RESULT)
        loop.advanceTime(by: .milliseconds(99))
        XCTAssertFalse(channelFuture.isFulfilled)
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels.first!.state(), .idle)

        // Now the timeout fires.
        loop.advanceTime(by: .milliseconds(1))
        XCTAssertTrue(channelFuture.isFulfilled)
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels.first!.state(), .closed)

        switch channelFuture.getError() {
        case .some(ChannelError.connectTimeout(.milliseconds(100))):
            break
        default:
            XCTFail("Got unexpected error: \(String(describing: channelFuture.getError()))")
        }
    }

    func testAConnectFailsWaitingForAAAA() throws {
        let channels = ChannelSet()
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(
            host: "example.com",
            port: 80,
            connectTimeout: .milliseconds(100)
        ) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.syncOperations.addHandler(
                    ConnectionDelayer(),
                    name: CONNECT_DELAYER,
                    position: .first
                )
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the A result returns and a connection attempt is made. This fails, and we test that
        // we wait for the AAAA query to come in before acting. That connection attempt then times out.
        resolver.v4Promise.succeed(SINGLE_IPv4_RESULT)
        loop.advanceTime(by: .milliseconds(50))
        XCTAssertFalse(channelFuture.isFulfilled)
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels.first!.state(), .idle)

        // The connection attempt fails. We still have no answer.
        channels.first!.failConnection(error: DummyError())
        XCTAssertFalse(channelFuture.isFulfilled)

        // Now the AAAA returns.
        resolver.v6Promise.succeed(SINGLE_IPv6_RESULT)
        XCTAssertFalse(channelFuture.isFulfilled)
        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels.last!.state(), .idle)

        // Now the timeout fires.
        loop.advanceTime(by: .milliseconds(50))
        XCTAssertTrue(channelFuture.isFulfilled)
        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels.last!.state(), .closed)

        switch channelFuture.getError() {
        case .some(ChannelError.connectTimeout(.milliseconds(100))):
            break
        default:
            XCTFail("Got unexpected error: \(String(describing: channelFuture.getError()))")
        }
    }

    func testDelayedAResult() throws {
        let channels = ChannelSet()
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .hours(1)) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.syncOperations.addHandler(
                    ConnectionDelayer(),
                    name: CONNECT_DELAYER,
                    position: .first
                )
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Provide the IPv6 results and let all 10 connection attempts play out.
        resolver.v6Promise.succeed(MANY_IPv6_RESULTS)

        for connectionCount in 1...10 {
            XCTAssertEqual(channels.last!.connectTarget()!, "fe80::\(connectionCount)")
            loop.advanceTime(by: .milliseconds(250))
        }
        XCTAssertFalse(channelFuture.isFulfilled)

        // Advance time by 30 minutes just to prove that we'll wait a long, long time for the
        // A result.
        loop.advanceTime(by: .minutes(30))
        XCTAssertFalse(channelFuture.isFulfilled)

        // Now the IPv4 results come in. Let all 10 connection attempts play out.
        resolver.v4Promise.succeed(MANY_IPv4_RESULTS)
        for connectionCount in 1...10 {
            XCTAssertEqual(channels.last!.connectTarget()!, "10.0.0.\(connectionCount)")
            loop.advanceTime(by: .milliseconds(250))
        }
        XCTAssertFalse(channelFuture.isFulfilled)
    }

    func testTimeoutBeforeAResponse() throws {
        let channels = ChannelSet()
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(
            host: "example.com",
            port: 80,
            connectTimeout: .milliseconds(100)
        ) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.syncOperations.addHandler(
                    ConnectionDelayer(),
                    name: CONNECT_DELAYER,
                    position: .first
                )
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the AAAA result returns, but the timeout is sufficiently low that the connect attempt
        // times out before the A returns.
        resolver.v6Promise.succeed(SINGLE_IPv6_RESULT)
        loop.advanceTime(by: .milliseconds(99))
        XCTAssertFalse(channelFuture.isFulfilled)
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels.first!.state(), .idle)

        // Now the timeout fires.
        loop.advanceTime(by: .milliseconds(1))
        XCTAssertTrue(channelFuture.isFulfilled)
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels.first!.state(), .closed)

        switch channelFuture.getError() {
        case .some(ChannelError.connectTimeout(.milliseconds(100))):
            break
        default:
            XCTFail("Got unexpected error: \(String(describing: channelFuture.getError()))")
        }
    }

    func testAllConnectionsFailImmediately() throws {
        let channels = ChannelSet()
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.syncOperations.addHandler(
                    ConnectionDelayer(),
                    name: CONNECT_DELAYER,
                    position: .first
                )
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the AAAA and A results return. We are going to fail the connections
        // instantly, which should cause all 20 to appear.
        resolver.v6Promise.succeed(MANY_IPv6_RESULTS)
        for channelCount in 1...10 {
            XCTAssertFalse(channelFuture.isFulfilled)
            XCTAssertEqual(channels.count, channelCount)
            XCTAssertEqual(channels.last!.state(), .idle)
            channels.last?.failConnection(error: DummyError())
        }

        resolver.v4Promise.succeed(MANY_IPv4_RESULTS)
        for channelCount in 11...20 {
            XCTAssertFalse(channelFuture.isFulfilled)
            XCTAssertEqual(channels.count, channelCount)
            XCTAssertEqual(channels.last!.state(), .idle)
            channels.last?.failConnection(error: DummyError())
        }

        XCTAssertTrue(channelFuture.isFulfilled)
        switch channelFuture.getError() {
        case is NIOConnectionError:
            break
        default:
            XCTFail("Got unexpected error: \(String(describing: channelFuture.getError()))")
        }
    }

    func testLaterConnections() throws {
        let channels = ChannelSet()
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.syncOperations.addHandler(
                    ConnectionDelayer(),
                    name: CONNECT_DELAYER,
                    position: .first
                )
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the AAAA results return. Let all the connection attempts go out.
        resolver.v6Promise.succeed(MANY_IPv6_RESULTS)
        for channelCount in 1...10 {
            XCTAssertEqual(channels.count, channelCount)
            loop.advanceTime(by: .milliseconds(250))
        }

        // Now we want to connect the first of these. This should lead to success.
        channels.first!.succeedConnection()
        XCTAssertTrue((try? channelFuture.wait()) === channels.first)

        // Now we're going to accept the second connection as well. This should lead to
        // a call to close.
        channels[1].succeedConnection()
        XCTAssertEqual(channels[1].state(), .closed)
        XCTAssertTrue((try? channelFuture.wait()) === channels.first)

        // Now fail the third. This shouldn't change anything.
        channels[2].failConnection(error: DummyError())
        XCTAssertTrue((try? channelFuture.wait()) === channels.first)
    }

    func testDelayedChannelCreation() throws {
        // This lock isn't really needed as the test is single-threaded, but because
        // the buildEyeballer function constructs the event loop we can't use a LoopBoundBox.
        // This is fine anyway.
        let ourChannelFutures: NIOLockedValueBox<[EventLoopPromise<Channel>]> = NIOLockedValueBox([])
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80) { loop, _ in
            ourChannelFutures.withLockedValue {
                $0.append(loop.makePromise())
                return $0.last!.futureResult
            }
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Return the IPv6 results and observe the channel creation attempts.
        resolver.v6Promise.succeed(MANY_IPv6_RESULTS)
        for channelCount in 1...10 {
            XCTAssertEqual(
                ourChannelFutures.withLockedValue { $0.count },
                channelCount
            )
            loop.advanceTime(by: .milliseconds(250))
        }
        XCTAssertFalse(channelFuture.isFulfilled)

        // Succeed the first channel future, which will connect because the default
        // channel builder always does.
        defaultChannelBuilder(loop: loop, family: .inet6).whenSuccess { result in
            ourChannelFutures.withLockedValue {
                $0.first!.succeed(result)
            }
            XCTAssertEqual(result.state(), .connected)
        }
        XCTAssertTrue(channelFuture.isFulfilled)

        // Ok, now succeed the second channel future. This should cause the channel to immediately be closed.
        defaultChannelBuilder(loop: loop, family: .inet6).whenSuccess { result in
            ourChannelFutures.withLockedValue {
                $0[1].succeed(result)
            }
            XCTAssertEqual(result.state(), .closed)
        }

        try ourChannelFutures.withLockedValue {
            // Ok, now fail the third channel future. Nothing bad should happen here.
            $0[2].fail(DummyError())

            // Verify that the first channel is the one listed as connected.
            XCTAssertTrue((try $0.first!.futureResult.wait()) === (try channelFuture.wait()))
        }
    }

    func testChannelCreationFails() throws {
        // This lock isn't really needed as the test is single-threaded, but because
        // the buildEyeballer function constructs the event loop we can't use a LoopBoundBox.
        // This is fine anyway.
        let errors: NIOLockedValueBox<[DummyError]> = NIOLockedValueBox([])
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80) { loop, _ in
            errors.withLockedValue {
                $0.append(DummyError())
                return loop.makeFailedFuture($0.last!)
            }
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the AAAA and A results return. We are going to fail the channel creation
        // instantly, which should cause all 20 to appear.
        resolver.v6Promise.succeed(MANY_IPv6_RESULTS)
        XCTAssertEqual(errors.withLockedValue { $0.count }, 10)
        XCTAssertFalse(channelFuture.isFulfilled)
        resolver.v4Promise.succeed(MANY_IPv4_RESULTS)
        XCTAssertEqual(errors.withLockedValue { $0.count }, 20)

        XCTAssertTrue(channelFuture.isFulfilled)
        if let error = channelFuture.getError() as? NIOConnectionError {
            XCTAssertEqual(error.connectionErrors.map { $0.error as! DummyError }, errors.withLockedValue { $0 })
        } else {
            XCTFail("Got unexpected error: \(String(describing: channelFuture.getError()))")
        }
    }

    func testCancellationSyncWithConnectDelay() throws {
        let channels = ChannelSet()
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(
            host: "example.com",
            port: 80,
            connectTimeout: .milliseconds(250)
        ) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.syncOperations.addHandler(
                    ConnectionDelayer(),
                    name: CONNECT_DELAYER,
                    position: .first
                )
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the AAAA results return. Let the first connection attempt go out.
        resolver.v6Promise.succeed(MANY_IPv6_RESULTS)
        XCTAssertEqual(channels.count, 1)

        // Advance time by 250 ms.
        loop.advanceTime(by: .milliseconds(250))

        // At this time the connection attempt should have failed, as the connect timeout
        // fired.
        XCTAssertThrowsError(try channelFuture.wait()) { error in
            XCTAssertEqual(.connectTimeout(.milliseconds(250)), error as? ChannelError)
        }

        // There may be one or two channels, depending on ordering, but both
        // should be closed.
        XCTAssertTrue(channels.count == 1 || channels.count == 2, "Unexpected channel count: \(channels.count)")
        for channel in channels {
            XCTAssertEqual(channel.state(), .closed)
        }
    }

    func testCancellationSyncWithResolutionDelay() throws {
        let channels = ChannelSet()
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(
            host: "example.com",
            port: 80,
            connectTimeout: .milliseconds(50)
        ) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.syncOperations.addHandler(
                    ConnectionDelayer(),
                    name: CONNECT_DELAYER,
                    position: .first
                )
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the A results return. Let the first connection attempt go out.
        resolver.v4Promise.succeed(MANY_IPv4_RESULTS)
        XCTAssertEqual(channels.count, 0)

        // Advance time by 50 ms.
        loop.advanceTime(by: .milliseconds(50))

        // At this time the connection attempt should have failed, as the connect timeout
        // fired.
        XCTAssertThrowsError(try channelFuture.wait()) { error in
            XCTAssertEqual(.connectTimeout(.milliseconds(50)), error as? ChannelError)
        }

        // There may be zero or one channels, depending on ordering, but if there is one it
        // should be closed
        XCTAssertTrue(channels.count == 0 || channels.count == 1, "Unexpected channel count: \(channels.count)")
        for channel in channels {
            XCTAssertEqual(channel.state(), .closed)
        }
    }

    func testResolverOnDifferentEventLoop() throws {
        // Tests a regression where the happy eyeballs connector would update its state on the event
        // loop of the future returned by the resolver (which may be different to its own). Prior
        // to the fix this test would trigger TSAN warnings.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let server = try ServerBootstrap(group: group)
            .bind(host: "localhost", port: 0)
            .wait()

        defer {
            XCTAssertNoThrow(try server.close().wait())
        }

        // Run the resolver and connection on different event loops.
        let resolverLoop = group.next()
        let connectionLoop = group.next()
        XCTAssertNotIdentical(resolverLoop, connectionLoop)
        let resolver = GetaddrinfoResolver(loop: resolverLoop, aiSocktype: .stream, aiProtocol: .tcp)
        let client = try ClientBootstrap(group: connectionLoop)
            .resolver(resolver)
            .connect(host: "localhost", port: server.localAddress!.port!)
            .wait()

        XCTAssertNoThrow(try client.close().wait())
    }

    func testResolutionTimeoutAndResolutionInSameTick() throws {
        let channels = ChannelSet()
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.syncOperations.addHandler(
                    ConnectionDelayer(),
                    name: CONNECT_DELAYER,
                    position: .first
                )
                channels.append(channel)
            }
            return channelFuture
        }
        let targetFuture = eyeballer.resolveAndConnect().flatMapThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        loop.run()

        // Then, queue a task to resolve the v6 promise after 50ms.
        // Why 50ms? This is the same time as the resolution delay.
        let promise = resolver.v6Promise
        loop.scheduleTask(in: .milliseconds(50)) {
            promise.fail(DummyError())
        }

        // Kick off the IPv4 resolution. This triggers the timer for the resolution delay.
        resolver.v4Promise.succeed(SINGLE_IPv4_RESULT)
        loop.run()

        // Advance time 50ms.
        loop.advanceTime(by: .milliseconds(50))

        // Then complete the connection future.
        XCTAssertEqual(channels.count, 1)
        channels.first!.succeedConnection()

        // Should be done.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "10.0.0.1")

        // We should have had queries for AAAA and A.
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80),
        ]
        XCTAssertEqual(resolver.events, expectedQueries)
    }
}

struct ChannelSet: Sendable, Sequence {
    private let channels: NIOLockedValueBox<[Channel]> = .init([])

    func append(_ channel: Channel) {
        self.channels.withLockedValue { $0.append(channel) }
    }

    var first: Channel? {
        self.channels.withLockedValue { $0.first }
    }

    var last: Channel? {
        self.channels.withLockedValue { $0.last }
    }

    var count: Int {
        self.channels.withLockedValue { $0.count }
    }

    subscript(index: Int) -> Channel {
        self.channels.withLockedValue { $0[index] }
    }

    func makeIterator() -> some IteratorProtocol<Channel> {
        self.channels.withLockedValue { $0.makeIterator() }
    }

    func finishAll() {
        self.channels.withLockedValue { $0 }.finishAll()
    }
}
