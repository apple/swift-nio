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
import XCTest
@testable import NIO
import Dispatch
import NIOConcurrencyHelpers

private extension Array {
    /// A helper function that asserts that a predicate is true for all elements.
    func assertAll(_ predicate: (Element) -> Bool) {
        self.enumerated().forEach { (index: Int, element: Element) in
            if !predicate(element) {
                XCTFail("Entry \(index) failed predicate, contents: \(element)")
            }
        }
    }
}

public class SocketChannelTest : XCTestCase {
    /// Validate that channel options are applied asynchronously.
    public func testAsyncSetOption() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 2)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        // Create two channels with different event loops.
        let channelA = try ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).wait()
        let channelB: Channel = try {
            while true {
                let channel = try ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).wait()
                if channel.eventLoop !== channelA.eventLoop {
                    return channel
                }
            }
        }()
        XCTAssert(channelA.eventLoop !== channelB.eventLoop)

        // Ensure we can dispatch two concurrent set option's on each others
        // event loops.
        let condition = Atomic<Int>(value: 0)
        let futureA = channelA.eventLoop.submit {
            _ = condition.add(1)
            while condition.load() < 2 { }
            _ = channelB.setOption(option: ChannelOptions.backlog, value: 1)
        }
        let futureB = channelB.eventLoop.submit {
            _ = condition.add(1)
            while condition.load() < 2 { }
            _ = channelA.setOption(option: ChannelOptions.backlog, value: 1)
        }
        try futureA.wait()
        try futureB.wait()
    }

    public func testDelayedConnectSetsUpRemotePeerAddress() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .bind(host: "127.0.0.1", port: 0).wait()

        // The goal of this test is to try to trigger at least one channel to have connection setup that is not
        // instantaneous. Due to the design of NIO this is not really observable to us, and due to the complex
        // overlapping interactions between SYN queues and loopback interfaces in modern kernels it's not
        // trivial to trigger this behaviour. The easiest thing we can do here is to try to slow the kernel down
        // enough that a connection eventually is delayed. To do this we're going to submit 50 connections more
        // or less at once.
        var clientConnectionFutures: [EventLoopFuture<Channel>] = []
        clientConnectionFutures.reserveCapacity(50)
        let clientBootstrap = ClientBootstrap(group: group)

        for _ in 0..<50 {
            let conn = clientBootstrap.connect(to: serverChannel.localAddress!)
            clientConnectionFutures.append(conn)
        }

        let remoteAddresses = try clientConnectionFutures.map { try $0.wait() }.map { $0.remoteAddress }

        // Now we want to check that they're all the same. The bug we're catching here is one where delayed connection
        // setup causes us to get nil as the remote address, even though we connected (and we did, as these are all
        // up right now).
        remoteAddresses.assertAll { $0 != nil }
    }
    
    public func testAcceptFailsWithECONNABORTED() throws {
        try assertAcceptFails(error: ECONNABORTED, active: true)
    }

    public func testAcceptFailsWithEMFILE() throws {
        try assertAcceptFails(error: EMFILE, active: true)
    }
    
    public func testAcceptFailsWithENFILE() throws {
        try assertAcceptFails(error: ENFILE, active: true)
    }
    
    public func testAcceptFailsWithENOBUFS() throws {
        try assertAcceptFails(error: ENOBUFS, active: true)
    }
    
    public func testAcceptFailsWithENOMEM() throws {
        try assertAcceptFails(error: ENOMEM, active: true)
    }
    
    public func testAcceptFailsWithEFAULT() throws {
        try assertAcceptFails(error: EFAULT, active: false)
    }
    
    private func assertAcceptFails(error: Int32, active: Bool) throws {
        final class AcceptHandler: ChannelInboundHandler {
            typealias InboundIn = Channel
            typealias InboundOut = Channel

            private let promise: EventLoopPromise<IOError>

            init(_ promise: EventLoopPromise<IOError>) {
                self.promise = promise
            }

            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                XCTFail("Should not accept a Channel but got \(self.unwrapInboundIn(data))")
            }

            func errorCaught(ctx: ChannelHandlerContext, error: Error) {
                if let ioError = error as? IOError {
                    self.promise.succeed(result: ioError)
                }
            }
        }
        
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let socket = try NonAcceptingServerSocket(errors: [error])
        let serverChannel = try ServerSocketChannel(serverSocket: socket, eventLoop: group.next() as! SelectableEventLoop, group: group)
        let promise: EventLoopPromise<IOError> = serverChannel.eventLoop.newPromise()

        XCTAssertNoThrow(try serverChannel.register().wait())
        XCTAssertNoThrow(try serverChannel.pipeline.add(handler: AcceptHandler(promise)).wait())
        XCTAssertNoThrow(try serverChannel.bind(to: SocketAddress.init(ipAddress: "127.0.0.1", port: 0)).wait())
    
        XCTAssertEqual(active, try serverChannel.eventLoop.submit {
            serverChannel.readable()
            return serverChannel.isActive
        }.wait())
    
        if active {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let ioError = try promise.futureResult.wait()
        XCTAssertEqual(error, ioError.errnoCode)
    }
}
