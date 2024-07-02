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

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#else
    #error("The Happy Eyeballs test module was unable to identify your C library.")
#endif
import XCTest
@testable import NIOCore
import NIOEmbedded
@testable import NIOPosix

private let CONNECT_RECORDER = "connectRecorder"
private let CONNECT_DELAYER = "connectDelayer"
private let SINGLE_IPv6_RESULT = [SocketAddress(host: "example.com", ipAddress: "fe80::1", port: 80)]
private let SINGLE_IPv4_RESULT = [SocketAddress(host: "example.com", ipAddress: "10.0.0.1", port: 80)]
private let SECOND_IPv4_RESULT = [SocketAddress(host: "example.com", ipAddress: "10.0.0.2", port: 80)]
private let MANY_IPv6_RESULTS = (1...10).map { SocketAddress(host: "example.com", ipAddress: "fe80::\($0)", port: 80) }
private let MANY_IPv4_RESULTS = (1...10).map { SocketAddress(host: "example.com", ipAddress: "10.0.0.\($0)", port: 80) }

private extension Array where Element == Channel {
    func finishAll() {
        self.forEach {
            do {
                _ = try($0 as! EmbeddedChannel).finish()
                // We're happy with no error
            } catch ChannelError.alreadyClosed {
                return // as well as already closed.
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

    public func connect(context: ChannelHandlerContext, to: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.targetHost = to.toString()
        let connectPromise = promise ?? context.eventLoop.makePromise()
        connectPromise.futureResult.whenSuccess {
            self.state = .connected
        }
        context.connect(to: to, promise: connectPromise)
    }

    public func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        let connectPromise = promise ?? context.eventLoop.makePromise()
        connectPromise.futureResult.whenComplete { (_: Result<Void, Error>) in
            self.state = .closed
        }
        context.close(promise: connectPromise)
    }
}

private class ConnectionDelayer: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    public var connectPromise: EventLoopPromise<Void>?

    public func connect(context: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
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
            ($0.handler as! ConnectionDelayer).connectPromise!.succeed(())
        }.wait()
    }

    func failConnection(error: Error) {
        return try! self.pipeline.context(name: CONNECT_DELAYER).map {
            ($0.handler as! ConnectionDelayer).connectPromise!.fail(error)
        }.wait()
    }

    func state() -> ConnectRecorder.State {
        return try! self.pipeline.context(name: CONNECT_RECORDER).map {
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

private extension SocketAddress {
    init(host: String, ipAddress: String, port: Int) {
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

    func toString() -> String {
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: 256, alignment: 1).bindMemory(to: Int8.self, capacity: 256)
        switch self {
        case .v4(let address):
            var baseAddress = address.address
            try! NIOBSDSocket.inet_ntop(addressFamily: .inet, addressBytes: &baseAddress.sin_addr, addressDescription: ptr, addressDescriptionLength: 256)
        case .v6(let address):
            var baseAddress = address.address
            try! NIOBSDSocket.inet_ntop(addressFamily: .inet6, addressBytes: &baseAddress.sin6_addr, addressDescription: ptr, addressDescriptionLength: 256)
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
private class DummyResolver: NIOStreamingResolver {

    enum Event {
        case resolve(name: String, destinationPort: Int)
        case cancel
    }

    var session: NIONameResolutionSession?
    var events: [Event] = []

    func resolve(name: String, destinationPort: Int, session: NIONameResolutionSession) {
        self.session = session
        events.append(.resolve(name: name, destinationPort: destinationPort))
    }

    func cancel(_ session: NIONameResolutionSession) {
        events.append(.cancel)
    }
}

extension DummyResolver.Event: Equatable {
}

private func defaultChannelBuilder(loop: EventLoop, family: NIOBSDSocket.ProtocolFamily) -> EventLoopFuture<Channel> {
    let channel = EmbeddedChannel(loop: loop as! EmbeddedEventLoop)
    XCTAssertNoThrow(try channel.pipeline.addHandler(ConnectRecorder(), name: CONNECT_RECORDER).wait())
    return loop.makeSucceededFuture(channel)
}

private func buildEyeballer(
    host: String,
    port: Int,
    connectTimeout: TimeAmount = .seconds(10),
    channelBuilderCallback: @escaping (EventLoop, NIOBSDSocket.ProtocolFamily) -> EventLoopFuture<Channel> = defaultChannelBuilder
) -> (eyeballer: HappyEyeballsConnector<Void>, resolver: DummyResolver, loop: EmbeddedEventLoop) {
    let loop = EmbeddedEventLoop()
    let resolver = DummyResolver()
    let eyeballer = HappyEyeballsConnector(resolver: resolver,
                                           loop: loop,
                                           host: host,
                                           port: port,
                                           connectTimeout: connectTimeout,
                                           channelBuilderCallback: channelBuilderCallback)
    return (eyeballer: eyeballer, resolver: resolver, loop: loop)
}

public final class HappyEyeballsTest : XCTestCase {
    func testIPv4OnlyResolution() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().flatMapThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        resolver.session!.deliverResults(SINGLE_IPv4_RESULT)
        resolver.session!.resolutionComplete(.success(()))
        loop.run()

        // No time should have needed to pass: we return only one target and it connects immediately.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "10.0.0.1")

        // We should have had one query.
        XCTAssertEqual(resolver.events, expectedQueries)
    }

    func testIPv6OnlyResolution() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().flatMapThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        resolver.session!.deliverResults(SINGLE_IPv6_RESULT)
        loop.run()

        // No time should have needed to pass: we return only one target and it connects immediately.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "fe80::1")

        // We should have had one query. We should then have had a cancel, because the resolver
        // never completed.
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])

        // Now complete. Nothing bad should happen.
        resolver.session!.resolutionComplete(.success(()))
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])
    }

    func testIPv4AndIPv6Resolution() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().flatMapThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        resolver.session!.deliverResults(SINGLE_IPv4_RESULT + SINGLE_IPv6_RESULT)
        loop.run()

        // No time should have needed to pass: we return only one target and it connects immediately.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "fe80::1")

        // We should have had one query. We should then have had a cancel, because the resolver
        // never completed.
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])

        // Now complete. Nothing bad should happen.
        resolver.session!.resolutionComplete(.success(()))
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])
    }

    func testTimeOutDuringDNSResolution() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .seconds(10))
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
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
        resolver.session!.deliverResults(SINGLE_IPv6_RESULT)
        resolver.session!.deliverResults(SINGLE_IPv4_RESULT)
        resolver.session!.resolutionComplete(.success(()))
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])
    }

    func testIPv6ResultsReturningFirst() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().flatMapThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        resolver.session!.deliverResults(SINGLE_IPv6_RESULT)
        loop.run()

        // No time should have needed to pass: we return only one target and it connects immediately.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "fe80::1")

        // We should have had one query. We should then have had a cancel, because the resolver
        // never completed.
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])

        // Now return an IPv4 result and complete. Nothing bad should happen.
        resolver.session!.deliverResults(SINGLE_IPv4_RESULT)
        resolver.session!.resolutionComplete(.success(()))
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])
    }

    func testIPv4ResultsReturningFirstDelayElapses() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().flatMapThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        resolver.session!.deliverResults(SINGLE_IPv4_RESULT)
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

        // We should have had one query. We should then have had a cancel, because the resolver
        // never completed.
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])

        // Now return an IPv6 result. Nothing bad should happen.
        resolver.session!.deliverResults(SINGLE_IPv6_RESULT)
        resolver.session!.resolutionComplete(.success(()))
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])
    }

    func testIPv4ReturningFirstThenIPv6Results() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().flatMapThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        resolver.session!.deliverResults(SINGLE_IPv4_RESULT)
        loop.run()

        // There should have been no connection attempt yet.
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        // Now the IPv6 result returns.
        resolver.session!.deliverResults(SINGLE_IPv6_RESULT)
        loop.run()

        // The connection attempt should have been made with the IPv6 result.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "fe80::1")

        // We should have had one query. We should then have had a cancel, because the resolver
        // never completed.
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])

        // Now complete. Nothing bad should happen.
        resolver.session!.resolutionComplete(.success(()))
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])
    }

    func testIPv4ResultsReturningFirstThenFailure() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().flatMapThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        resolver.session!.deliverResults(SINGLE_IPv4_RESULT)
        loop.run()

        // There should have been no connection attempt yet.
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        // Now the resolver fails.
        resolver.session!.resolutionComplete(.failure(DummyError()))
        loop.run()

        // The connection attempt should have been made with the IPv4 result.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "10.0.0.1")

        // We should have had one query, with no cancel.
        XCTAssertEqual(resolver.events, expectedQueries)
    }

    func testIPv4ResultsReturningFirstThenSuccess() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let targetFuture = eyeballer.resolveAndConnect().flatMapThrowing { (channel) -> String? in
            let target = channel.connectTarget()
            _ = try (channel as! EmbeddedChannel).finish()
            return target
        }
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        resolver.session!.deliverResults(SINGLE_IPv4_RESULT)
        loop.run()

        // There should have been no connection attempt yet.
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(targetFuture.isFulfilled)

        // Now the resolver completes.
        resolver.session!.resolutionComplete(.success(()))
        loop.run()

        // The connection attempt should have been made with the IPv4 result.
        let target = try targetFuture.wait()
        XCTAssertEqual(target!, "10.0.0.1")

        // We should have had one query, with no cancel.
        XCTAssertEqual(resolver.events, expectedQueries)
    }

    func testEmptyResultsFail() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        resolver.session!.resolutionComplete(.success(()))
        loop.run()


        // We should have had one query, with no cancel.
        XCTAssertEqual(resolver.events, expectedQueries)

        // But we should have failed.
        if let error = channelFuture.getError() as? NIOConnectionError {
            XCTAssertEqual(error.host, "example.com")
            XCTAssertEqual(error.port, 80)
            XCTAssertNil(error.resolutionError)
            XCTAssertEqual(error.connectionErrors.count, 0)
        } else {
            XCTFail("Got \(String(describing: channelFuture.getError()))")
        }
    }

    func testResolverFails() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80)
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        let resolutionError = DummyError()
        resolver.session!.resolutionComplete(.failure(resolutionError))
        loop.run()

        // We should have had one query, with no cancel.
        XCTAssertEqual(resolver.events, expectedQueries)

        // But we should have failed.
        if let error = channelFuture.getError() as? NIOConnectionError {
            XCTAssertEqual(error.host, "example.com")
            XCTAssertEqual(error.port, 80)
            XCTAssertEqual(error.resolutionError as? DummyError, resolutionError)
            XCTAssertEqual(error.connectionErrors.count, 0)
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
                try! channel.pipeline.addHandler(ConnectionDelayer(), name: CONNECT_DELAYER, position: .first).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // We're providing the IPv4 and IPv6 results. This will lead to 20 total hosts
        // for us to try to connect to.
        resolver.session!.deliverResults(MANY_IPv4_RESULTS + MANY_IPv6_RESULTS)
        resolver.session!.resolutionComplete(.success(()))

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
                try! channel.pipeline.addHandler(ConnectionDelayer(), name: CONNECT_DELAYER, position: .first).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // We're providing the IPv4 and IPv6 results. This will lead to 20 total hosts
        // for us to try to connect to.
        resolver.session!.deliverResults(MANY_IPv4_RESULTS + MANY_IPv6_RESULTS)
        resolver.session!.resolutionComplete(.success(()))

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
            XCTAssertNil(error.resolutionError)
            XCTAssertEqual(error.connectionErrors.count, 20)

            for (idx, error) in error.connectionErrors.enumerated() {
                XCTAssertEqual(error.error as? DummyError, errors[idx])
            }
        } else {
            XCTFail("Got \(String(describing: channelFuture.getError()))")
        }
    }

    func testDelayedIPv6Results() throws {
        var channels: [Channel] = []
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .hours(1)) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.addHandler(ConnectionDelayer(), name: CONNECT_DELAYER, position: .first).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Provide the IPv4 results and let five connection attempts play out.
        resolver.session!.deliverResults(MANY_IPv4_RESULTS)
        loop.advanceTime(by: .milliseconds(50))

        for connectionCount in 1...4 {
            XCTAssertEqual(channels.last!.connectTarget()!, "10.0.0.\(connectionCount)")
            loop.advanceTime(by: .milliseconds(250))
        }
        XCTAssertEqual(channels.last!.connectTarget()!, "10.0.0.5")

        // Now the IPv6 results come in.
        resolver.session!.deliverResults(MANY_IPv6_RESULTS)
        resolver.session!.resolutionComplete(.success(()))

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

    func testTimeoutWaitingForIPv6() throws {
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .milliseconds(49))
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the IPv4 result returns, but the timeout is sufficiently low that the connect attempt
        // times out before the IPv6 can return.
        resolver.session!.deliverResults(SINGLE_IPv4_RESULT)
        loop.advanceTime(by: .milliseconds(48))
        XCTAssertFalse(channelFuture.isFulfilled)

        loop.advanceTime(by: .milliseconds(1))
        XCTAssertTrue(channelFuture.isFulfilled)

        // We should have had one query. We should then have had a cancel, because the resolver
        // never completed.
        XCTAssertEqual(resolver.events, expectedQueries + [.cancel])
        switch channelFuture.getError() {
        case .some(ChannelError.connectTimeout(.milliseconds(49))):
            break
        default:
            XCTFail("Got unexpected error: \(String(describing: channelFuture.getError()))")
        }
    }

    func testTimeoutAfterIPv4Results() throws {
        var channels: [Channel] = []
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .milliseconds(100)) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.addHandler(ConnectionDelayer(), name: CONNECT_DELAYER, position: .first).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the IPv4 result returns.
        resolver.session!.deliverResults(SINGLE_IPv4_RESULT)
        XCTAssertEqual(channels.count, 0)

        // Here another IPv4 result returns before the resolution delay (default of 50 ms) elapses.
        loop.advanceTime(by: .milliseconds(49))
        resolver.session!.deliverResults(SECOND_IPv4_RESULT)
        XCTAssertEqual(channels.count, 0)

        // Now the resolution delay has elapsed.
        loop.advanceTime(by: .milliseconds(1))
        XCTAssertFalse(channelFuture.isFulfilled)
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels.first!.state(), .idle)
        loop.advanceTime(by: .milliseconds(49))
        XCTAssertFalse(channelFuture.isFulfilled)

        // Now the timeout fires before the connection succeeds.
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

    func testIPv4ConnectFailsWaitingForIPv6() throws {
        var channels: [Channel] = []
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .milliseconds(100)) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.addHandler(ConnectionDelayer(), name: CONNECT_DELAYER, position: .first).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the IPv4 result returns and a connection attempt is made. This fails, and we test that
        // we wait for the IPv6 result to come in before acting. That connection attempt then times out.
        resolver.session!.deliverResults(SINGLE_IPv4_RESULT)
        loop.advanceTime(by: .milliseconds(50))
        XCTAssertFalse(channelFuture.isFulfilled)
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels.first!.state(), .idle)

        // The connection attempt fails. We still have no answer.
        channels.first!.failConnection(error: DummyError())
        XCTAssertFalse(channelFuture.isFulfilled)

        // Now the IPv6 result returns.
        resolver.session!.deliverResults(SINGLE_IPv6_RESULT)
        resolver.session!.resolutionComplete(.success(()))
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

    func testDelayedIPv4Results() throws {
        var channels: [Channel] = []
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .hours(1)) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.addHandler(ConnectionDelayer(), name: CONNECT_DELAYER, position: .first).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Provide the IPv6 results and let all 10 connection attempts play out.
        resolver.session!.deliverResults(MANY_IPv6_RESULTS)

        for connectionCount in 1...10 {
            XCTAssertEqual(channels.last!.connectTarget()!, "fe80::\(connectionCount)")
            loop.advanceTime(by: .milliseconds(250))
        }
        XCTAssertFalse(channelFuture.isFulfilled)

        // Advance time by 30 minutes just to prove that we'll wait a long, long time for
        // more results.
        loop.advanceTime(by: .minutes(30))
        XCTAssertFalse(channelFuture.isFulfilled)

        // Now the IPv4 results come in. Let all 10 connection attempts play out.
        resolver.session!.deliverResults(MANY_IPv4_RESULTS)
        resolver.session!.resolutionComplete(.success(()))
        for connectionCount in 1...10 {
            XCTAssertEqual(channels.last!.connectTarget()!, "10.0.0.\(connectionCount)")
            loop.advanceTime(by: .milliseconds(250))
        }
        XCTAssertFalse(channelFuture.isFulfilled)
    }

    func testTimeoutBeforeIPv4Result() throws {
        var channels: [Channel] = []
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .milliseconds(100)) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.addHandler(ConnectionDelayer(), name: CONNECT_DELAYER, position: .first).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the IPv6 result returns, but the timeout is sufficiently low that the connect attempt
        // times out before the IPv4 result returns.
        resolver.session!.deliverResults(SINGLE_IPv6_RESULT)
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
                try! channel.pipeline.addHandler(ConnectionDelayer(), name: CONNECT_DELAYER, position: .first).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the IPv6 and IPv4 results return. We are going to fail the connections
        // instantly, which should cause all 20 to appear.
        resolver.session!.deliverResults(MANY_IPv6_RESULTS)
        for channelCount in 1...10 {
            XCTAssertFalse(channelFuture.isFulfilled)
            XCTAssertEqual(channels.count, channelCount)
            XCTAssertEqual(channels.last!.state(), .idle)
            channels.last?.failConnection(error: DummyError())
        }

        resolver.session!.deliverResults(MANY_IPv4_RESULTS)
        resolver.session!.resolutionComplete(.success(()))
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
        var channels: [Channel] = []
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.addHandler(ConnectionDelayer(), name: CONNECT_DELAYER, position: .first).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the IPv6 results return. Let all the connection attempts go out.
        resolver.session!.deliverResults(MANY_IPv6_RESULTS)
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
            ourChannelFutures.append(loop.makePromise())
            return ourChannelFutures.last!.futureResult
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Return the IPv6 results and observe the channel creation attempts.
        resolver.session!.deliverResults(MANY_IPv6_RESULTS)
        for channelCount in 1...10 {
            XCTAssertEqual(ourChannelFutures.count, channelCount)
            loop.advanceTime(by: .milliseconds(250))
        }
        XCTAssertFalse(channelFuture.isFulfilled)

        // Succeed the first channel future, which will connect because the default
        // channel builder always does.
        defaultChannelBuilder(loop: loop, family: .inet6).whenSuccess {
            ourChannelFutures.first!.succeed($0)
            XCTAssertEqual($0.state(), .connected)
        }
        XCTAssertTrue(channelFuture.isFulfilled)

        // Ok, now succeed the second channel future. This should cause the channel to immediately be closed.
        defaultChannelBuilder(loop: loop, family: .inet6).whenSuccess {
            ourChannelFutures[1].succeed($0)
            XCTAssertEqual($0.state(), .closed)
        }

        // Ok, now fail the third channel future. Nothing bad should happen here.
        ourChannelFutures[2].fail(DummyError())

        // Verify that the first channel is the one listed as connected.
        XCTAssertTrue((try ourChannelFutures.first!.futureResult.wait()) === (try channelFuture.wait()))
    }

    func testChannelCreationFails() throws {
        var errors: [DummyError] = []
        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80) { loop, _ in
            errors.append(DummyError())
            return loop.makeFailedFuture(errors.last!)
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the IPv6 and IPv4 results return. We are going to fail the channel creation
        // instantly, which should cause all 20 to appear.
        resolver.session!.deliverResults(MANY_IPv6_RESULTS)
        XCTAssertEqual(errors.count, 10)
        XCTAssertFalse(channelFuture.isFulfilled)
        resolver.session!.deliverResults(MANY_IPv4_RESULTS)
        resolver.session!.resolutionComplete(.success(()))
        XCTAssertEqual(errors.count, 20)

        XCTAssertTrue(channelFuture.isFulfilled)
        if let error = channelFuture.getError() as? NIOConnectionError {
            XCTAssertEqual(error.connectionErrors.map { $0.error as! DummyError }, errors)
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
                try! channel.pipeline.addHandler(ConnectionDelayer(), name: CONNECT_DELAYER, position: .first).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the IPv6 results return. Let the first connection attempt go out.
        resolver.session!.deliverResults(MANY_IPv6_RESULTS)
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
        var channels: [Channel] = []
        defer {
            channels.finishAll()
        }

        let (eyeballer, resolver, loop) = buildEyeballer(host: "example.com", port: 80, connectTimeout: .milliseconds(50)) {
            let channelFuture = defaultChannelBuilder(loop: $0, family: $1)
            channelFuture.whenSuccess { channel in
                try! channel.pipeline.addHandler(ConnectionDelayer(), name: CONNECT_DELAYER, position: .first).wait()
                channels.append(channel)
            }
            return channelFuture
        }
        let channelFuture = eyeballer.resolveAndConnect()
        let expectedQueries: [DummyResolver.Event] = [
            .resolve(name: "example.com", destinationPort: 80),
        ]
        loop.run()
        XCTAssertEqual(resolver.events, expectedQueries)
        XCTAssertFalse(channelFuture.isFulfilled)

        // Here the IPv4 results return. Let the first connection attempt go out.
        resolver.session!.deliverResults(MANY_IPv4_RESULTS)
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
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
        let connectionLoop = group.next()
        let resolver = GetaddrinfoResolver(aiSocktype: .stream, aiProtocol: .tcp)
        let client = try ClientBootstrap(group: connectionLoop)
            .resolver(resolver)
            .connect(host: "localhost", port: server.localAddress!.port!)
            .wait()

        XCTAssertNoThrow(try client.close().wait())
    }
}
