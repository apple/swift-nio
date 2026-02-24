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

import Atomics
import NIOCore
import NIOEmbedded
import NIOTestUtils
import XCTest

@testable import NIOPosix

final class AcceptBackoffHandlerTest: XCTestCase {
    @Sendable
    static func defaultBackoffProvider(error: IOError) -> TimeAmount? {
        AcceptBackoffHandler.defaultBackoffProvider(error: error)
    }

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
        let loop = group.next() as! SelectableEventLoop
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        // Only used from EL
        let readCountHandler = try! loop.submit {
            NIOLoopBound(ReadCountHandler(), eventLoop: loop)
        }.wait()
        let serverChannel = try setupChannel(
            eventLoop: loop,
            readCountHandler: readCountHandler,
            backoffProvider: { _ in .milliseconds(100) },
            errors: [error]
        )
        XCTAssertEqual(
            0,
            try serverChannel.eventLoop.submit {
                serverChannel.readable()
                serverChannel.read()
                return readCountHandler.value.readCount
            }.wait()
        )

        // Inspect the read count after our scheduled backoff elapsed.
        XCTAssertEqual(
            1,
            try serverChannel.eventLoop.scheduleTask(in: .milliseconds(100)) {
                readCountHandler.value.readCount
            }.futureResult.wait()
        )

        // The read should go through as the scheduled read happened
        XCTAssertEqual(
            2,
            try serverChannel.eventLoop.submit {
                serverChannel.read()
                return readCountHandler.value.readCount
            }.wait()
        )

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
        let loop = group.next() as! SelectableEventLoop
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let readCountHandler = try! loop.submit {
            NIOLoopBound(ReadCountHandler(), eventLoop: loop)
        }.wait()
        let serverChannel = try setupChannel(
            eventLoop: loop,
            readCountHandler: readCountHandler,
            backoffProvider: { err in
                .hours(1)
            },
            errors: [ENFILE]
        )
        XCTAssertEqual(
            0,
            try serverChannel.eventLoop.submit {
                serverChannel.readable()
                if read {
                    serverChannel.read()
                }
                return readCountHandler.value.readCount
            }.wait()
        )

        XCTAssertNoThrow(try serverChannel.pipeline.removeHandler(name: acceptHandlerName).wait())

        if read {
            // Removal should have triggered a read.
            XCTAssertEqual(
                1,
                try serverChannel.eventLoop.submit {
                    readCountHandler.value.readCount
                }.wait()
            )
        } else {
            // Removal should have triggered no read.
            XCTAssertEqual(
                0,
                try serverChannel.eventLoop.submit {
                    readCountHandler.value.readCount
                }.wait()
            )
        }
        XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
    }

    public func testNotScheduleReadIfAlreadyScheduled() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next() as! SelectableEventLoop
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let readCountHandler = try! loop.submit {
            NIOLoopBound(ReadCountHandler(), eventLoop: loop)
        }.wait()
        let serverChannel = try setupChannel(
            eventLoop: loop,
            readCountHandler: readCountHandler,
            backoffProvider: { err in
                .milliseconds(10)
            },
            errors: [ENFILE]
        )
        XCTAssertEqual(
            0,
            try serverChannel.eventLoop.submit {
                serverChannel.readable()
                serverChannel.read()
                serverChannel.read()
                return readCountHandler.value.readCount
            }.wait()
        )

        // Inspect the read count after our scheduled backoff elapsed multiple times. This should still only have triggered one read as we should only ever
        // schedule one read.
        XCTAssertEqual(
            1,
            try serverChannel.eventLoop.scheduleTask(in: .milliseconds(500)) {
                readCountHandler.value.readCount
            }.futureResult.wait()
        )

        // The read should go through as the scheduled read happened
        XCTAssertEqual(
            2,
            try serverChannel.eventLoop.submit {
                serverChannel.read()
                return readCountHandler.value.readCount
            }.wait()
        )

        XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
    }

    public func testChannelInactiveCancelScheduled() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next() as! SelectableEventLoop
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

        let readCountHandler = try! loop.submit {
            NIOLoopBound(ReadCountHandler(), eventLoop: loop)
        }.wait()

        let serverChannel = try setupChannel(
            eventLoop: loop,
            readCountHandler: readCountHandler,
            backoffProvider: { err in
                .milliseconds(10)
            },
            errors: [ENFILE]
        )

        let inactivePromise = serverChannel.eventLoop.makePromise(of: Void.self)
        let configured = loop.submit {
            let inactiveVerificationHandler = InactiveVerificationHandler(promise: inactivePromise)
            try serverChannel.pipeline.syncOperations.addHandler(inactiveVerificationHandler)
        }
        XCTAssertNoThrow(try configured.wait())

        XCTAssertEqual(
            0,
            try serverChannel.eventLoop.submit {
                serverChannel.readable()
                serverChannel.read()
                // Close the channel, this should also take care of cancel the scheduled read.
                serverChannel.close(promise: nil)
                return readCountHandler.value.readCount
            }.wait()
        )

        // Inspect the read count after our scheduled backoff elapsed multiple times. This should have triggered no read as the channel was closed.
        XCTAssertEqual(
            0,
            try serverChannel.eventLoop.scheduleTask(in: .milliseconds(500)) {
                readCountHandler.value.readCount
            }.futureResult.wait()
        )

        XCTAssertNoThrow(try inactivePromise.futureResult.wait())
    }

    public func testSecondErrorUpdateScheduledRead() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next() as! SelectableEventLoop
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let readCountHandler = try! loop.submit {
            NIOLoopBound(ReadCountHandler(), eventLoop: loop)
        }.wait()

        let backoffProviderCalled = ManagedAtomic(0)
        let serverChannel = try setupChannel(
            eventLoop: loop,
            readCountHandler: readCountHandler,
            backoffProvider: { err in
                if backoffProviderCalled.loadThenWrappingIncrement(ordering: .relaxed) == 0 {
                    return .seconds(1)
                }
                return .seconds(2)
            },
            errors: [ENFILE, EMFILE]
        )

        XCTAssertEqual(
            0,
            try serverChannel.eventLoop.submit {
                serverChannel.readable()
                serverChannel.read()
                let readCount = readCountHandler.value.readCount
                // Directly trigger a read again without going through the pipeline. This will allow us to use serverChannel.readable()
                serverChannel._channelCore.read0()
                serverChannel.readable()
                return readCount
            }.wait()
        )

        // This should have not fired a read yet as we updated the scheduled read because we received two errors.
        XCTAssertEqual(
            0,
            try serverChannel.eventLoop.scheduleTask(in: .seconds(1)) {
                readCountHandler.value.readCount
            }.futureResult.wait()
        )

        // This should have fired now as the updated scheduled read task should have been complete by now
        XCTAssertEqual(
            1,
            try serverChannel.eventLoop.scheduleTask(in: .seconds(1)) {
                readCountHandler.value.readCount
            }.futureResult.wait()
        )

        XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())

        XCTAssertEqual(2, backoffProviderCalled.load(ordering: .relaxed))
    }

    func testNotForwardingIOError() throws {
        let loop = EmbeddedEventLoop()
        let acceptBackOffHandler = AcceptBackoffHandler(shouldForwardIOErrorCaught: false)
        let eventCounterHandler = EventCounterHandler()
        let channel = EmbeddedChannel(handlers: [acceptBackOffHandler, eventCounterHandler], loop: loop)

        channel.pipeline.fireErrorCaught(IOError(errnoCode: 1, reason: "test"))
        XCTAssertEqual(eventCounterHandler.errorCaughtCalls, 0)
        channel.pipeline.fireErrorCaught(ChannelError.alreadyClosed)
        XCTAssertEqual(eventCounterHandler.errorCaughtCalls, 1)
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

    private func setupChannel(
        eventLoop: SelectableEventLoop,
        readCountHandler: NIOLoopBound<ReadCountHandler>,
        backoffProvider: @escaping @Sendable (IOError) -> TimeAmount? = AcceptBackoffHandlerTest.defaultBackoffProvider,
        errors: [Int32]
    ) throws -> ServerSocketChannel {
        let socket = try NonAcceptingServerSocket(errors: errors)
        let serverChannel = try assertNoThrowWithValue(
            ServerSocketChannel(
                serverSocket: socket,
                eventLoop: eventLoop,
                group: eventLoop
            )
        )

        XCTAssertNoThrow(try serverChannel.setOption(.autoRead, value: false).wait())

        let configured = eventLoop.submit { [acceptHandlerName = self.acceptHandlerName] in
            let sync = serverChannel.pipeline.syncOperations
            try sync.addHandler(readCountHandler.value)
            try sync.addHandler(
                AcceptBackoffHandler(backoffProvider: backoffProvider),
                name: acceptHandlerName
            )
        }

        XCTAssertNoThrow(try configured.wait())

        XCTAssertNoThrow(
            try eventLoop.flatSubmit {
                // this is pretty delicate at the moment:
                // `bind` must be _synchronously_ follow `register`, otherwise in our current implementation, `epoll` will
                // send us `EPOLLHUP`. To have it run synchronously, we need to invoke the `flatMap` on the eventloop that the
                // `register` will succeed.
                serverChannel.register().flatMap { () -> EventLoopFuture<()> in
                    serverChannel.bind(to: try! SocketAddress(ipAddress: "127.0.0.1", port: 0))
                }
            }.wait() as Void
        )
        return serverChannel
    }
}
