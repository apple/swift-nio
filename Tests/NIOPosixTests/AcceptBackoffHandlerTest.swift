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

import XCTest
import NIOCore
@testable import NIOPosix
import Atomics


public final class AcceptBackoffHandlerTest: XCTestCase {

    private let acceptHandlerName = "AcceptBackoffHandler"

    public func testECONNABORTED() throws {
        try assertBackoffRead(error: ECONNABORTED)
    }

    public func testEMFILE() throws {
        try assertBackoffRead(error: EMFILE)
    }

    public func testENFILE() throws {
        try assertBackoffRead(error: ENFILE)
    }

    public func testENOBUFS() throws {
        try assertBackoffRead(error: ENOBUFS)
    }

    public func testENOMEM() throws {
        try assertBackoffRead(error: ENOMEM)
    }

    private func assertBackoffRead(error: Int32) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let readCountHandler = ReadCountHandler()
        let serverChannel = try setupChannel(group: group,
                                             readCountHandler: readCountHandler,
                                             backoffProvider: { _ in return .milliseconds(100) },
                                             errors: [error])
        XCTAssertEqual(0, try serverChannel.eventLoop.submit {
            serverChannel.readable()
            serverChannel.read()
            return readCountHandler.readCount
            }.wait())

        // Inspect the read count after our scheduled backoff elapsed.
        XCTAssertEqual(1, try serverChannel.eventLoop.scheduleTask(in: .milliseconds(100)) {
            return readCountHandler.readCount
        }.futureResult.wait())

        // The read should go through as the scheduled read happened
        XCTAssertEqual(2, try serverChannel.eventLoop.submit {
            serverChannel.read()
            return readCountHandler.readCount
        }.wait())

        XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
    }

    public func testRemovalTriggerReadWhenPreviousReadScheduled() throws {
        try assertRemoval(read: true)
    }

    public func testRemovalTriggerNoReadWhenPreviousNoReadScheduled() throws {
        try assertRemoval(read: false)
    }

    private func assertRemoval(read: Bool) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let readCountHandler = ReadCountHandler()
        let serverChannel = try setupChannel(group: group, readCountHandler: readCountHandler, backoffProvider: { err in
            return .hours(1)
        }, errors: [ENFILE])
        XCTAssertEqual(0, try serverChannel.eventLoop.submit {
            serverChannel.readable()
            if read {
                serverChannel.read()
            }
            return readCountHandler.readCount
        }.wait())

        XCTAssertNoThrow(try serverChannel.pipeline.removeHandler(name: acceptHandlerName).wait())

        if read {
            // Removal should have triggered a read.
            XCTAssertEqual(1, try serverChannel.eventLoop.submit {
                return readCountHandler.readCount
            }.wait())
        } else {
            // Removal should have triggered no read.
            XCTAssertEqual(0, try serverChannel.eventLoop.submit {
                return readCountHandler.readCount
            }.wait())
        }
        XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
    }

    public func testNotScheduleReadIfAlreadyScheduled() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let readCountHandler = ReadCountHandler()
        let serverChannel = try setupChannel(group: group, readCountHandler: readCountHandler, backoffProvider: { err in
            return .milliseconds(10)
        }, errors: [ENFILE])
        XCTAssertEqual(0, try serverChannel.eventLoop.submit {
            serverChannel.readable()
            serverChannel.read()
            serverChannel.read()
            return readCountHandler.readCount
        }.wait())

        // Inspect the read count after our scheduled backoff elapsed multiple times. This should still only have triggered one read as we should only ever
        // schedule one read.
        XCTAssertEqual(1, try serverChannel.eventLoop.scheduleTask(in: .milliseconds(500)) {
            return readCountHandler.readCount
        }.futureResult.wait())

        // The read should go through as the scheduled read happened
        XCTAssertEqual(2, try serverChannel.eventLoop.submit {
            serverChannel.read()
            return readCountHandler.readCount
        }.wait())

        XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
    }

    public func testChannelInactiveCancelScheduled() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        class InactiveVerificationHandler: ChannelInboundHandler {
            typealias InboundIn = Any


            private let promise: EventLoopPromise<Void>

            init(promise: EventLoopPromise<Void>) {
                self.promise = promise
            }

            public func channelInactive(context: ChannelHandlerContext) {
                promise.succeed(())
            }

            func waitForInactive() throws {
                try promise.futureResult.wait()
            }
        }

        let readCountHandler = ReadCountHandler()
        let serverChannel = try setupChannel(group: group, readCountHandler: readCountHandler, backoffProvider: { err in
            return .milliseconds(10)
        }, errors: [ENFILE])

        let inactiveVerificationHandler = InactiveVerificationHandler(promise: serverChannel.eventLoop.makePromise())
        XCTAssertNoThrow(try serverChannel.pipeline.addHandler(inactiveVerificationHandler).wait())

        XCTAssertEqual(0, try serverChannel.eventLoop.submit {
            serverChannel.readable()
            serverChannel.read()
            // Close the channel, this should also take care of cancel the scheduled read.
            serverChannel.close(promise: nil)
            return readCountHandler.readCount
        }.wait())

        // Inspect the read count after our scheduled backoff elapsed multiple times. This should have triggered no read as the channel was closed.
        XCTAssertEqual(0, try serverChannel.eventLoop.scheduleTask(in: .milliseconds(500)) {
            return readCountHandler.readCount
        }.futureResult.wait())

        XCTAssertNoThrow(try inactiveVerificationHandler.waitForInactive())
    }

    public func testSecondErrorUpdateScheduledRead() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let readCountHandler = ReadCountHandler()

        let backoffProviderCalled = ManagedAtomic(0)
        let serverChannel = try setupChannel(group: group, readCountHandler: readCountHandler, backoffProvider: { err in
            if backoffProviderCalled.loadThenWrappingIncrement(ordering: .relaxed) == 0 {
                return .seconds(1)
            }
            return .seconds(2)
        }, errors: [ENFILE, EMFILE])

        XCTAssertEqual(0, try serverChannel.eventLoop.submit {
            serverChannel.readable()
            serverChannel.read()
            let readCount = readCountHandler.readCount
            // Directly trigger a read again without going through the pipeline. This will allow us to use serverChannel.readable()
            serverChannel._channelCore.read0()
            serverChannel.readable()
            return readCount
        }.wait())

        // This should have not fired a read yet as we updated the scheduled read because we received two errors.
        XCTAssertEqual(0, try serverChannel.eventLoop.scheduleTask(in: .seconds(1)) {
            return readCountHandler.readCount
        }.futureResult.wait())

        // This should have fired now as the updated scheduled read task should have been complete by now
        XCTAssertEqual(1, try serverChannel.eventLoop.scheduleTask(in: .seconds(1)) {
            return readCountHandler.readCount
        }.futureResult.wait())

        XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())

        XCTAssertEqual(2, backoffProviderCalled.load(ordering: .relaxed))
    }

    private final class ReadCountHandler: ChannelOutboundHandler {
        typealias OutboundIn = NIOAny
        typealias OutboundOut = NIOAny

        var readCount = 0

        func read(context: ChannelHandlerContext) {
            readCount += 1
            context.read()
        }
    }

    private func setupChannel(group: EventLoopGroup,
                              readCountHandler: ReadCountHandler,
                              backoffProvider: @escaping (IOError) -> TimeAmount? = AcceptBackoffHandler.defaultBackoffProvider,
                              errors: [Int32]) throws -> ServerSocketChannel {
        let eventLoop = group.next() as! SelectableEventLoop
        let socket = try NonAcceptingServerSocket(errors: errors)
        let serverChannel = try assertNoThrowWithValue(ServerSocketChannel(serverSocket: socket,
                                                                           eventLoop: eventLoop,
                                                                           group: group))

        XCTAssertNoThrow(try serverChannel.setOption(ChannelOptions.autoRead, value: false).wait())
        XCTAssertNoThrow(try serverChannel.pipeline.addHandler(readCountHandler).flatMap { _ in
            serverChannel.pipeline.addHandler(AcceptBackoffHandler(backoffProvider: backoffProvider),
                                              name: self.acceptHandlerName)
        }.wait())

        let bindFuture = eventLoop.flatSubmit {
            // this is pretty delicate at the moment:
            // `bind` must be _synchronously_ follow `register`, otherwise in our current implementation, `epoll` will
            // send us `EPOLLHUP`. To have it run synchronously, we need to invoke the `flatMap` on the eventloop that the
            // `register` will succeed.
            serverChannel.register().flatMap { () -> EventLoopFuture<()> in
                return serverChannel.bind(to: try! SocketAddress(ipAddress: "127.0.0.1", port: 0))
            }
        }

        // If bind fails, the error will propagate up
        try bindFuture.wait()

        return serverChannel
    }
}
