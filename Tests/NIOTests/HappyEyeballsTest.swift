//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(macOS) || os(tvOS) || os(iOS)
    import Darwin
#else
    import Glibc
#endif
import XCTest
@testable import NIO

private let CONNECT_RECORDER = "connectRecorder"
private let CONNECT_DELAYER = "connectDelayer"
private let SINGLE_IPv6_RESULT = [SocketAddress(host: "example.com", ipAddress: "fe80::1", port: 80)]
private let SINGLE_IPv4_RESULT = [SocketAddress(host: "example.com", ipAddress: "10.0.0.1", port: 80)]
private let MANY_IPv6_RESULTS = (1...10).map { SocketAddress(host: "example.com", ipAddress: "fe80::\($0)", port: 80) }
private let MANY_IPv4_RESULTS = (1...10).map { SocketAddress(host: "example.com", ipAddress: "10.0.0.\($0)", port: 80) }

private extension Array where Element == Channel {
    func finishAll() {
        self.forEach {
            do {
                _ = try($0 as! EmbeddedChannel).finish()
            } catch ChannelError.alreadyClosed {
                return
            } catch {
                XCTFail("Finishing got error \(error)")
            }
        }
    }
}

private class DummyError: Error, Equatable {
    // For dummy error equality is identity.
    static func ==(lhs: DummyError, rhs: DummyError) -> Bool {
        return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
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

    public func connect(ctx: ChannelHandlerContext, to: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.targetHost = to.toString()
        let connectPromise = promise ?? ctx.eventLoop.newPromise()
        connectPromise.futureResult.whenSuccess {
            self.state = .connected
        }
        ctx.connect(to: to, promise: connectPromise)
    }

    public func close(ctx: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        let connectPromise = promise ?? ctx.eventLoop.newPromise()
        connectPromise.futureResult.whenComplete {
            self.state = .closed
        }
        ctx.close(promise: connectPromise)
    }
}

private class ConnectionDelayer: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    public var connectPromise: EventLoopPromise<Void>?

    public func connect(ctx: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.connectPromise = promise
    }
}

private extension Channel {
    func connectTarget() -> String? {
        return try! self.pipeline.context(name: CONNECT_RECORDER).map {
            ($0.handler as! ConnectRecorder).targetHost
        }.wait()
    }

    func succeedConnection() {
        return try! self.pipeline.context(name: CONNECT_DELAYER).map {
            ($0.handler as! ConnectionDelayer).connectPromise!.succeed(result: ())
        }.wait()
    }

    func failConnection(error: Error) {
        return try! self.pipeline.context(name: CONNECT_DELAYER).map {
            ($0.handler as! ConnectionDelayer).connectPromise!.fail(error: error)
        }.wait()
    }

    func state() -> ConnectRecorder.State {
        return try! self.pipeline.context(name: CONNECT_RECORDER).map {
            ($0.handler as! ConnectRecorder).state
        }.thenIfErrorThrowing {
            switch $0 {
            case ChannelPipelineError.notFound:
                return .closed
            default:
                throw $0
            }
        }.wait()
    }
}

private extension SocketAddress {
    init(host: String, ipAddress: String, port: Int) {
        var v4addr = in_addr()
        var v6addr = in6_addr()

        if inet_pton(AF_INET, ipAddress, &v4addr) == 1 {
            var sockaddr = sockaddr_in()
            sockaddr.sin_family = sa_family_t(AF_INET)
            sockaddr.sin_port = in_port_t(port).bigEndian
            sockaddr.sin_addr = v4addr
            self = .init(sockaddr, host: host)
        } else if inet_pton(AF_INET6, ipAddress, &v6addr) == 1 {
            var sockaddr = sockaddr_in6()
            sockaddr.sin6_family = sa_family_t(AF_INET6)
            sockaddr.sin6_port = in_port_t(port).bigEndian
            sockaddr.sin6_flowinfo = 0
            sockaddr.sin6_scope_id = 0
            sockaddr.sin6_addr = v6addr
            self = .init(sockaddr, host: host)
        } else {
            fatalError("Unable to convert to IP")
        }
    }

    func toString() -> String {
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: 256, alignment: 1).bindMemory(to: Int8.self, capacity: 256)
        switch self {
        case .v4(let address):
            var baseAddress = address.address
            precondition(inet_ntop(AF_INET, &baseAddress.sin_addr, ptr, 256) != nil)
        case .v6(let address):
            var baseAddress = address.address
            precondition(inet_ntop(AF_INET6, &baseAddress.sin6_addr, ptr, 256) != nil)
        case .unixDomainSocket:
            fatalError("No UDS support in happy eyeballs.")
        }

        let ipString = String(cString: ptr)
        ptr.deinitialize(count: 256).deallocate()
        return ipString
    }
}

private extension EventLoopFuture {
    func getError() -> Error? {
        guard self.isFulfilled else { return nil }

        var error: Error? = nil
        self.whenFailure { error = $0 }
        return error!
    }
}

// A simple resolver that allows control over the DNS resolution process.
private class DummyResolver: Resolver {
    let v4Promise: EventLoopPromise<[SocketAddress]>
    let v6Promise: EventLoopPromise<[SocketAddress]>

    enum Event {
        case a(host: String, port: Int)
        case aaaa(host: String, port: Int)
        case cancel
    }

    var events: [Event] = []

    init(loop: EventLoop) {
        self.v4Promise = loop.newPromise()
        self.v6Promise = loop.newPromise()
    }

    func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        events.append(.a(host: host, port: port))
        return self.v4Promise.futureResult
    }

    func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        events.append(.aaaa(host: host, port: port))
        return self.v6Promise.futureResult
    }

    func cancelQueries() {
        events.append(.cancel)
    }
}

extension DummyResolver.Event: Equatable {
    fileprivate static func ==(lhs: DummyResolver.Event, rhs: DummyResolver.Event) -> Bool {
        switch (lhs, rhs) {
        case (.a(let host1, let port1), .a(let host2, let port2)):
            return host1 == host2 && port1 == port2
        case (.aaaa(let host1, let port1), .aaaa(let host2, let port2)):
            return host1 == host2 && port1 == port2
        case(.cancel, .cancel):
            return true
        case (.a, _), (.aaaa, _), (.cancel, _):
            return false
        }
    }
}

private func defaultChannelBuilder(loop: EventLoop, family: Int32) -> EventLoopFuture<Channel> {
    let channel = EmbeddedChannel(loop: loop as! EmbeddedEventLoop)
    XCTAssertNoThrow(try channel.pipeline.add(name: CONNECT_RECORDER, handler: ConnectRecorder()).wait())
    return loop.newSucceededFuture(result: channel)
}

private func buildEyeballer(host: String,
                            port: Int,
                            connectTimeout: TimeAmount = .seconds(10),
                            channelBuilderCallback: @escaping (EventLoop, Int32) -> EventLoopFuture<Channel> = defaultChannelBuilder) -> (eyeballer: HappyEyeballsConnector, resolver: DummyResolver, loop: EmbeddedEventLoop) {
    let loop = EmbeddedEventLoop()
    let resolver = DummyResolver(loop: loop)
    let eyeballer = HappyEyeballsConnector(resolver: resolver,
                                           loop: loop,
                                           host: host,
                                           port: port,
                                           connectTimeout: connectTimeout,
                                           channelBuilderCallback: channelBuilderCallback)
    return (eyeballer: eyeballer, resolver: resolver, loop: loop)
}

public class HappyEyeballsTest : XCTestCase {
    func testIPv4OnlyResolution() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().thenThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        loop.run()
        resolver.v6Promise.fail(error: DummyError())
        resolver.v4Promise.succeed(result: SINGLE_IPv4_RESULT)
        loop.run()

        // No time should have needed to pass: we return only one target and it connects immediately.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "10.0.0.1")

        // We should have had queries for AAAA and A.
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        XCTAssertEqual(resolver.events, expectedQueries)
    }

    func testIPv6OnlyResolution() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().thenThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        loop.run()
        resolver.v4Promise.fail(error: DummyError())
        resolver.v6Promise.succeed(result: SINGLE_IPv6_RESULT)
        loop.run()

        // No time should have needed to pass: we return only one target and it connects immediately.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "fe80::1")

        // We should have had queries for AAAA and A.
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        XCTAssertEqual(resolver.events, expectedQueries)
    }

    func testTimeOutDuringDNSResolution() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .seconds(10))
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
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
        resolver.v6Promise.succeed(result: SINGLE_IPv6_RESULT)
        resolver.v4Promise.succeed(result: SINGLE_IPv4_RESULT)
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])
    }

    func testAAAAQueryReturningFirst() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().thenThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        resolver.v6Promise.succeed(result: SINGLE_IPv6_RESULT)
        loop.run()

        // No time should have needed to pass: we return only one target and it connects immediately.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "fe80::1")

        // We should have had queries for AAAA and A. We should then have had a cancel, because the A
        // never returned.
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])

        // Now return a result for the IPv4 query. Nothing bad should happen.
        resolver.v4Promise.succeed(result: SINGLE_IPv4_RESULT)
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])
    }

    func testAQueryReturningFirstDelayElapses() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().thenThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        resolver.v4Promise.succeed(result: SINGLE_IPv4_RESULT)
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
        resolver.v6Promise.succeed(result: SINGLE_IPv6_RESULT)
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])
    }

    func testAQueryReturningFirstThenAAAAReturns() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().thenThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        resolver.v4Promise.succeed(result: SINGLE_IPv4_RESULT)
        loop.run()

        // There should have been no connection attempt yet.
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        // Now the AAAA returns.
        resolver.v6Promise.succeed(result: SINGLE_IPv6_RESULT)
        loop.run()

        // The connection attempt should have been made with the IPv6 result.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "fe80::1")

        // We should have had queries for AAAA and A, with no cancel.
        XCTAssertEqual(resolver.events, expectedQueries)
    }

    func testAQueryReturningFirstThenAAAAErrors() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().thenThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        resolver.v4Promise.succeed(result: SINGLE_IPv4_RESULT)
        loop.run()

        // There should have been no connection attempt yet.
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        // Now the AAAA fails.
        resolver.v6Promise.fail(error: DummyError())
        loop.run()

        // The connection attempt should have been made with the IPv4 result.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "10.0.0.1")

        // We should have had queries for AAAA and A, with no cancel.
        XCTAssertEqual(resolver.events, expectedQueries)
    }

    func testAQueryReturningFirstThenEmptyAAAA() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().thenThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        resolver.v4Promise.succeed(result: SINGLE_IPv4_RESULT)
        loop.run()

        // There should have been no connection attempt yet.
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        // Now the AAAA returns empty.
        resolver.v6Promise.succeed(result: [])
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
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        resolver.v4Promise.succeed(result: [])
        resolver.v6Promise.succeed(result: [])
        loop.run()


        // We should have had queries for AAAA and A, with no cancel.
        XCTAssertEqual(resolver.events, expectedQueries)

        // But we should have failed.
        if case .some(ChannelError.connectFailed(let inner)) = channelFuture.getError() {
            XCTAssertEqual(inner.host, "example.com")
            XCTAssertEqual(inner.port, 80)
            XCTAssertNil(inner.dnsAError)
            XCTAssertNil(inner.dnsAAAAError)
            XCTAssertEqual(inner.connectionErrors.count, 0)
        } else {
            XCTFail("Got \(String(describing: channelFuture.getError()))")
        }
    }

    func testAllDNSFail() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        let v4Error = DummyError()
        let v6Error = DummyError()
        resolver.v4Promise.fail(error: v4Error)
        resolver.v6Promise.fail(error: v6Error)
        loop.run()

        // We should have had queries for AAAA and A, with no cancel.
        XCTAssertEqual(resolver.events, expectedQueries)

        // But we should have failed.
        if case .some(ChannelError.connectFailed(let inner)) = channelFuture.getError() {
            XCTAssertEqual(inner.host, "example.com")
            XCTAssertEqual(inner.port, 80)
            XCTAssertEqual(inner.dnsAError as? DummyError ?? DummyError(), v4Error)
            XCTAssertEqual(inner.dnsAAAAError as? DummyError ?? DummyError(), v6Error)
            XCTAssertEqual(inner.connectionErrors.count, 0)
        } else {
            XCTFail("Got \(String(describing: channelFuture.getError()))")
        }
    }

    func testMaximalConnectionDelay() throws {
        var channels: [Channel] = []
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .hours(1)) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.add(name: CONNECT_DELAYER, handler: ConnectionDelayer(), first: true).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // We're providing the IPv4 and IPv6 results. This will lead to 20 total hosts
        // for us to try to connect to.
        resolver.v4Promise.succeed(result: MANY_IPv4_RESULTS)
        resolver.v6Promise.succeed(result: MANY_IPv6_RESULTS)

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
        var channels: [Channel] = []
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .hours(1)) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.add(name: CONNECT_DELAYER, handler: ConnectionDelayer(), first: true).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // We're providing the IPv4 and IPv6 results. This will lead to 20 total hosts
        // for us to try to connect to.
        resolver.v4Promise.succeed(result: MANY_IPv4_RESULTS)
        resolver.v6Promise.succeed(result: MANY_IPv6_RESULTS)

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
        if case .some(ChannelError.connectFailed(let inner)) = channelFuture.getError() {
            XCTAssertEqual(inner.host, "example.com")
            XCTAssertEqual(inner.port, 80)
            XCTAssertNil(inner.dnsAError)
            XCTAssertNil(inner.dnsAAAAError)
            XCTAssertEqual(inner.connectionErrors.count, 20)

            for (idx, error) in inner.connectionErrors.enumerated() {
                XCTAssertEqual(error.error as? DummyError, errors[idx])
            }
        } else {
            XCTFail("Got \(String(describing: channelFuture.getError()))")
        }
    }

    func testDelayedAAAAResult() throws {
        var channels: [Channel] = []
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .hours(1)) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.add(name: CONNECT_DELAYER, handler: ConnectionDelayer(), first: true).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Provide the IPv4 results and let five connection attempts play out.
        resolver.v4Promise.succeed(result: MANY_IPv4_RESULTS)
        loop.advanceTime(by: .milliseconds(50))

        for connectionCount in 1...4 {
            XCTAssertEqual(channels.last!.connectTarget()!, "10.0.0.\(connectionCount)")
            loop.advanceTime(by: .milliseconds(250))
        }
        XCTAssertEqual(channels.last!.connectTarget()!, "10.0.0.5")

        // Now the IPv6 results come in.
        resolver.v6Promise.succeed(result: MANY_IPv6_RESULTS)

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
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .milliseconds(49))
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the A result returns, but the timeout is sufficiently low that the connect attempt
        // times out before the AAAA can return.
        resolver.v4Promise.succeed(result: SINGLE_IPv4_RESULT)
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
        var channels: [Channel] = []
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .milliseconds(100)) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.add(name: CONNECT_DELAYER, handler: ConnectionDelayer(), first: true).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the A result returns, but the timeout is sufficiently low that the connect attempt
        // times out before the AAAA can return and before the connection succeeds.
        resolver.v4Promise.succeed(result: SINGLE_IPv4_RESULT)
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
        var channels: [Channel] = []
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .milliseconds(100)) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.add(name: CONNECT_DELAYER, handler: ConnectionDelayer(), first: true).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the A result returns and a connection attempt is made. This fails, and we test that
        // we wait for the AAAA query to come in before acting. That connection attempt then times out.
        resolver.v4Promise.succeed(result: SINGLE_IPv4_RESULT)
        loop.advanceTime(by: .milliseconds(50))
        XCTAssertFalse(channelFuture.isFulfilled)
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels.first!.state(), .idle)

        // The connection attempt fails. We still have no answer.
        channels.first!.failConnection(error: DummyError())
        XCTAssertFalse(channelFuture.isFulfilled)

        // Now the AAAA returns.
        resolver.v6Promise.succeed(result: SINGLE_IPv6_RESULT)
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
        var channels: [Channel] = []
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .hours(1)) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.add(name: CONNECT_DELAYER, handler: ConnectionDelayer(), first: true).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Provide the IPv6 results and let all 10 connection attempts play out.
        resolver.v6Promise.succeed(result: MANY_IPv6_RESULTS)

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
        resolver.v4Promise.succeed(result: MANY_IPv4_RESULTS)
        for connectionCount in 1...10 {
            XCTAssertEqual(channels.last!.connectTarget()!, "10.0.0.\(connectionCount)")
            loop.advanceTime(by: .milliseconds(250))
        }
        XCTAssertFalse(channelFuture.isFulfilled)
    }

    func testTimeoutBeforeAResponse() throws {
        var channels: [Channel] = []
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .milliseconds(100)) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.add(name: CONNECT_DELAYER, handler: ConnectionDelayer(), first: true).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the AAAA result returns, but the timeout is sufficiently low that the connect attempt
        // times out before the A returns.
        resolver.v6Promise.succeed(result: SINGLE_IPv6_RESULT)
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
        var channels: [Channel] = []
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.add(name: CONNECT_DELAYER, handler: ConnectionDelayer(), first: true).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the AAAA and A results return. We are going to fail the connections
        // instantly, which should cause all 20 to appear.
        resolver.v6Promise.succeed(result: MANY_IPv6_RESULTS)
        for channelCount in 1...10 {
            XCTAssertFalse(channelFuture.isFulfilled)
            XCTAssertEqual(channels.count, channelCount)
            XCTAssertEqual(channels.last!.state(), .idle)
            channels.last?.failConnection(error: DummyError())
        }

        resolver.v4Promise.succeed(result: MANY_IPv4_RESULTS)
        for channelCount in 11...20 {
            XCTAssertFalse(channelFuture.isFulfilled)
            XCTAssertEqual(channels.count, channelCount)
            XCTAssertEqual(channels.last!.state(), .idle)
            channels.last?.failConnection(error: DummyError())
        }

        XCTAssertTrue(channelFuture.isFulfilled)
        switch channelFuture.getError() {
        case .some(ChannelError.connectFailed):
            break
        default:
            XCTFail("Got unexpected error: \(String(describing: channelFuture.getError()))")
        }
    }

    func testLaterConnections() throws {
        var channels: [Channel] = []
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.add(name: CONNECT_DELAYER, handler: ConnectionDelayer(), first: true).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the AAAA results return. Let all the connection attempts go out.
        resolver.v6Promise.succeed(result: MANY_IPv6_RESULTS)
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
        var ourChannelFutures: [EventLoopPromise<Channel>] = []
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80) { loop, _ in
            ourChannelFutures.append(loop.newPromise())
            return ourChannelFutures.last!.futureResult
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Return the IPv6 results and observe the channel creation attempts.
        resolver.v6Promise.succeed(result: MANY_IPv6_RESULTS)
        for channelCount in 1...10 {
            XCTAssertEqual(ourChannelFutures.count, channelCount)
            loop.advanceTime(by: .milliseconds(250))
        }
        XCTAssertFalse(channelFuture.isFulfilled)

        // Succeed the first channel future, which will connect because the default
        // channel builder always does.
        defaultChannelBuilder(loop: loop, family: AF_INET6).whenSuccess {
            ourChannelFutures.first!.succeed(result: $0)
            XCTAssertEqual($0.state(), .connected)
        }
        XCTAssertTrue(channelFuture.isFulfilled)

        // Ok, now succeed the second channel future. This should cause the channel to immediately be closed.
        defaultChannelBuilder(loop: loop, family: AF_INET6).whenSuccess {
            ourChannelFutures[1].succeed(result: $0)
            XCTAssertEqual($0.state(), .closed)
        }

        // Ok, now fail the third channel future. Nothing bad should happen here.
        ourChannelFutures[2].fail(error: DummyError())

        // Verify that the first channel is the one listed as connected.
        XCTAssertTrue((try? ourChannelFutures.first!.futureResult.wait()) === (try? channelFuture.wait()))
    }

    func testChannelCreationFails() throws {
        var errors: [DummyError] = []
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80) { loop, _ in
            errors.append(DummyError())
            return loop.newFailedFuture(error: errors.last!)
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the AAAA and A results return. We are going to fail the channel creation
        // instantly, which should cause all 20 to appear.
        resolver.v6Promise.succeed(result: MANY_IPv6_RESULTS)
        XCTAssertEqual(errors.count, 10)
        XCTAssertFalse(channelFuture.isFulfilled)
        resolver.v4Promise.succeed(result: MANY_IPv4_RESULTS)
        XCTAssertEqual(errors.count, 20)

        XCTAssertTrue(channelFuture.isFulfilled)
        if case .some(ChannelError.connectFailed(let inner)) = channelFuture.getError() {
            XCTAssertEqual(inner.connectionErrors.map { $0.error as! DummyError }, errors)
        } else {
            XCTFail("Got unexpected error: \(String(describing: channelFuture.getError()))")
        }
    }

    func testCancellationSyncWithConnectDelay() throws {
        var channels: [Channel] = []
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .milliseconds(250)) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.add(name: CONNECT_DELAYER, handler: ConnectionDelayer(), first: true).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the AAAA results return. Let the first connection attempt go out.
        resolver.v6Promise.succeed(result: MANY_IPv6_RESULTS)
        XCTAssertEqual(channels.count, 1)

        // Advance time by 250 ms.
        loop.advanceTime(by: .milliseconds(250))

        // At this time the connection attempt should have failed, as the connect timeout
        // fired.
        do {
            _ = try channelFuture.wait()
            XCTFail("connection succeeded")
        } catch ChannelError.connectTimeout(.milliseconds(250)) {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // There may be one or two channels, depending on ordering, but both
        // should be closed.
        XCTAssertTrue(channels.count == 1 || channels.count == 2, "Unexpected channel count: \(channels.count)")
        for channel in channels {
            XCTAssertEqual(channel.state(), .closed)
        }
    }

    func testCancellationSyncWithResolutionDelay() throws {
        var channels: [Channel] = []
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .milliseconds(50)) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.add(name: CONNECT_DELAYER, handler: ConnectionDelayer(), first: true).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .aaaa(host: "example.com", port: 80),
            .a(host: "example.com", port: 80)
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the A results return. Let the first connection attempt go out.
        resolver.v4Promise.succeed(result: MANY_IPv4_RESULTS)
        XCTAssertEqual(channels.count, 0)

        // Advance time by 50 ms.
        loop.advanceTime(by: .milliseconds(50))

        // At this time the connection attempt should have failed, as the connect timeout
        // fired.
        do {
            _ = try channelFuture.wait()
            XCTFail("connection succeeded")
        } catch ChannelError.connectTimeout(.milliseconds(50)) {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // There may be zero or one channels, depending on ordering, but if there is one it
        // should be closed
        XCTAssertTrue(channels.count == 0 || channels.count == 1, "Unexpected channel count: \(channels.count)")
        for channel in channels {
            XCTAssertEqual(channel.state(), .closed)
        }
    }
}

#if !swift(>=4.1)
extension UnsafeMutableRawPointer {
    public static func allocate(byteCount: Int, alignment: Int) -> UnsafeMutableRawPointer {
        return UnsafeMutableRawPointer.allocate(bytes: byteCount, alignedTo: alignment)
    }

    public func deallocate() {
        self.deallocate(bytes: 1, alignedTo: 1)
    }
}
#endif
