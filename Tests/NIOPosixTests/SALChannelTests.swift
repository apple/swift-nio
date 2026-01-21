//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
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
import XCTest

@testable import NIOPosix

final class SALChannelTest: XCTestCase {
    func testBasicConnectedChannel() throws {
        try withSALContext { context in
            let localAddress = try! SocketAddress(ipAddress: "0.1.2.3", port: 4)
            let serverAddress = try! SocketAddress(ipAddress: "9.8.7.6", port: 5)
            let buffer = ByteBuffer(string: "xxx")

            let channel = try context.makeConnectedSocketChannel(
                localAddress: localAddress,
                remoteAddress: serverAddress
            )

            try context.runSALOnEventLoopAndWait { _, _, _ in
                channel.writeAndFlush(buffer).flatMap {
                    channel.write(buffer, promise: nil)
                    return channel.writeAndFlush(buffer)
                }.flatMap {
                    channel.close()
                }
            } syscallAssertions: { assertions in
                try assertions.assertWrite(
                    expectedFD: .max,
                    expectedBytes: buffer,
                    return: .processed(buffer.readableBytes)
                )
                try assertions.assertWritev(
                    expectedFD: .max,
                    expectedBytes: [buffer, buffer],
                    return: .processed(2 * buffer.readableBytes)
                )
                try assertions.assertDeregister { selectable in
                    try selectable.withUnsafeHandle {
                        XCTAssertEqual(.max, $0)
                    }
                    return true
                }
                try assertions.assertClose(expectedFD: .max)
            }
        }
    }

    func testWritesFromWritabilityNotificationsDoNotGetLostIfWePreviouslyWroteEverything() throws {
        // This is a unit test, doing what
        //     testWriteAndFlushFromReentrantFlushNowTriggeredOutOfWritabilityWhereOuterSaysAllWrittenAndInnerDoesNot
        // does but in a deterministic way, without having to send actual bytes.

        let localAddress = try! SocketAddress(ipAddress: "0.1.2.3", port: 4)
        let serverAddress = try! SocketAddress(ipAddress: "9.8.7.6", port: 5)
        let buffer = ByteBuffer(string: "12")

        let writableNotificationStepExpectation = ManagedAtomic(0)

        final class DoWriteFromWritabilityChangedNotification: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            var numberOfCalls = 0

            var writableNotificationStepExpectation: ManagedAtomic<Int>

            init(writableNotificationStepExpectation: ManagedAtomic<Int>) {
                self.writableNotificationStepExpectation = writableNotificationStepExpectation
            }

            func channelWritabilityChanged(context: ChannelHandlerContext) {
                self.numberOfCalls += 1

                XCTAssertEqual(
                    self.writableNotificationStepExpectation.load(ordering: .relaxed),
                    numberOfCalls
                )
                switch self.numberOfCalls {
                case 1:
                    // First, we should see a `false` here because 2 bytes is above the high watermark.
                    XCTAssertFalse(context.channel.isWritable)
                case 2:
                    // Then, we should go back to `true` from a `writable` notification. Now, let's write 3 bytes which
                    // will exhaust the high watermark. We'll also set up (further down) that we only partially write
                    // those 3 bytes.
                    XCTAssertTrue(context.channel.isWritable)
                    var buffer = context.channel.allocator.buffer(capacity: 3)
                    buffer.writeString("ABC")

                    // We expect another channelWritabilityChanged notification
                    XCTAssertTrue(
                        self.writableNotificationStepExpectation.compareExchange(
                            expected: 2,
                            desired: 3,
                            ordering: .relaxed
                        ).exchanged
                    )
                    context.writeAndFlush(Self.wrapOutboundOut(buffer), promise: nil)
                case 3:
                    // Next, we should go to false because we never send all the bytes.
                    XCTAssertFalse(context.channel.isWritable)
                case 4:
                    // And finally, back to `true` because eventually, we'll write enough.
                    XCTAssertTrue(context.channel.isWritable)
                default:
                    XCTFail("call \(self.numberOfCalls) unexpected (\(context.channel.isWritable))")
                }
            }
        }

        try withSALContext { context in
            let channel = try context.makeConnectedSocketChannel(
                localAddress: localAddress,
                remoteAddress: serverAddress
            )

            try context.runSALOnEventLoopAndWait { _, _, _ in
                channel.setOption(.writeSpin, value: 0).flatMap {
                    channel.setOption(.writeBufferWaterMark, value: .init(low: 1, high: 1))
                }.flatMapThrowing {
                    let sync = channel.pipeline.syncOperations
                    try sync.addHandler(
                        DoWriteFromWritabilityChangedNotification(
                            writableNotificationStepExpectation: writableNotificationStepExpectation
                        )
                    )
                }.flatMap {
                    // This write should cause a Channel writability change.
                    XCTAssertTrue(
                        writableNotificationStepExpectation.compareExchange(expected: 0, desired: 1, ordering: .relaxed)
                            .exchanged
                    )
                    return channel.writeAndFlush(buffer)
                }
            } syscallAssertions: { assertions in
                // We get in a write of 2 bytes, and we claim we wrote 1 bytes of that.
                try assertions.assertWrite(expectedFD: .max, expectedBytes: buffer, return: .processed(1))

                // Next, we expect a reregistration which adds the `.write` notification
                try assertions.assertReregister { selectable, eventSet in
                    XCTAssert(selectable as? Socket === channel.socket)
                    XCTAssertEqual([.read, .reset, .error, .readEOF, .write], eventSet)
                    return true
                }

                // Before sending back the writable notification, we know that that'll trigger a Channel writability change
                XCTAssertTrue(
                    writableNotificationStepExpectation.compareExchange(expected: 1, desired: 2, ordering: .relaxed)
                        .exchanged
                )
                let writableEvent = SelectorEvent(
                    io: [.write],
                    registration: NIORegistration(
                        channel: .socketChannel(channel),
                        interested: [.write],
                        registrationID: .initialRegistrationID
                    )
                )
                try assertions.assertWaitingForNotification(result: writableEvent)
                try assertions.assertWrite(
                    expectedFD: .max,
                    expectedBytes: buffer.getSlice(at: 1, length: 1)!,
                    return: .processed(1)
                )
                var buffer = buffer
                buffer.clear()
                buffer.writeString("ABC")  // expected

                // This time, the write again, just writes one byte, so we should remain registered for writable.
                try assertions.assertWrite(
                    expectedFD: .max,
                    expectedBytes: buffer,
                    return: .processed(1)
                )
                buffer.moveReaderIndex(forwardBy: 1)

                // Let's send them another 'writable' notification:
                try assertions.assertWaitingForNotification(result: writableEvent)

                // This time, we'll make the write write everything which should also lead to a final channelWritability
                // change.
                XCTAssertTrue(
                    writableNotificationStepExpectation.compareExchange(expected: 3, desired: 4, ordering: .relaxed)
                        .exchanged
                )
                try assertions.assertWrite(
                    expectedFD: .max,
                    expectedBytes: buffer,
                    return: .processed(2)
                )

                // And lastly, after having written everything, we'd expect to unregister for write
                try assertions.assertReregister { selectable, eventSet in
                    XCTAssert(selectable as? Socket === channel.socket)
                    XCTAssertEqual([.read, .reset, .error, .readEOF], eventSet)
                    return true
                }

                try assertions.assertParkedRightNow()
            }
        }
    }

    func testWeSurviveIfIgnoringSIGPIPEFails() throws {
        try withSALContext { context in
            // We know this sometimes happens on Darwin, so let's test it.
            let expectedError = IOError(errnoCode: EINVAL, reason: "bad")
            XCTAssertThrowsError(try context.makeSocketChannelInjectingFailures(disableSIGPIPEFailure: expectedError)) {
                error in
                XCTAssertEqual(expectedError.errnoCode, (error as? IOError)?.errnoCode)
            }
        }
    }

    func testBasicRead() throws {
        final class SignalGroupOnRead: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            private let group: DispatchGroup
            private var numberOfCalls = 0

            init(group: DispatchGroup) {
                self.group = group
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                self.numberOfCalls += 1
                XCTAssertEqual(
                    "hello",
                    String(decoding: Self.unwrapInboundIn(data).readableBytesView, as: Unicode.UTF8.self)
                )
                if self.numberOfCalls == 1 {
                    self.group.leave()
                }
            }
        }

        let g = DispatchGroup()
        g.enter()

        try withSALContext { context in
            let localAddress = try! SocketAddress(ipAddress: "0.1.2.3", port: 4)
            let serverAddress = try! SocketAddress(ipAddress: "9.8.7.6", port: 5)
            let buffer = ByteBuffer(string: "hello")

            let channel = try context.makeConnectedSocketChannel(
                localAddress: localAddress,
                remoteAddress: serverAddress
            )

            try context.runSALOnEventLoopAndWait { _, _, _ in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(SignalGroupOnRead(group: g))
                }
            } syscallAssertions: { assertions in
                let readEvent = SelectorEvent(
                    io: [.read],
                    registration: NIORegistration(
                        channel: .socketChannel(channel),
                        interested: [.read],
                        registrationID: .initialRegistrationID
                    )
                )
                try assertions.assertWaitingForNotification(result: readEvent)
                try assertions.assertRead(expectedFD: .max, expectedBufferSpace: 2048, return: buffer)
            }
        }

        g.wait()
    }

    func testBasicConnectWithClientBootstrap() throws {
        try withSALContext { context in
            let channel = try context.makeSocketChannel()
            let localAddress = try! SocketAddress(ipAddress: "1.2.3.4", port: 5)
            let serverAddress = try! SocketAddress(ipAddress: "9.8.7.6", port: 5)

            try context.runSALOnEventLoopAndWait { _, _, _ in
                ClientBootstrap(group: channel.eventLoop)
                    .channelOption(.autoRead, value: false)
                    .testOnly_connect(injectedChannel: channel, to: serverAddress)
                    .flatMap { channel in
                        channel.close()
                    }
            } syscallAssertions: { assertions in
                try assertions.assertSetOption(expectedLevel: .tcp, expectedOption: .tcp_nodelay) { value in
                    (value as? SocketOptionValue) == 1
                }
                try assertions.assertConnect(expectedAddress: serverAddress, result: true)
                try assertions.assertLocalAddress(address: localAddress)
                try assertions.assertRemoteAddress(address: localAddress)
                try assertions.assertRegister { selectable, event, Registration in
                    XCTAssertEqual([.reset, .error], event)
                    return true
                }
                try assertions.assertReregister { selectable, event in
                    XCTAssertEqual([.reset, .error, .readEOF], event)
                    return true
                }
                try assertions.assertDeregister { selectable in
                    true
                }
                try assertions.assertClose(expectedFD: .max)
            }
        }
    }

    func testClientBootstrapBindIsDoneAfterSocketOptions() throws {
        try withSALContext { context in
            let channel = try context.makeSocketChannel()
            let localAddress = try! SocketAddress(ipAddress: "1.2.3.4", port: 5)
            let serverAddress = try! SocketAddress(ipAddress: "9.8.7.6", port: 5)

            try context.runSALOnEventLoopAndWait { _, _, _ in
                ClientBootstrap(group: channel.eventLoop)
                    .channelOption(.socketOption(.so_reuseaddr), value: 1)
                    .channelOption(.autoRead, value: false)
                    .bind(to: localAddress)
                    .testOnly_connect(injectedChannel: channel, to: serverAddress)
                    .flatMap { channel in
                        channel.close()
                    }
            } syscallAssertions: { assertions in
                try assertions.assertSetOption(expectedLevel: .tcp, expectedOption: .tcp_nodelay) { value in
                    (value as? SocketOptionValue) == 1
                }
                // This is the important bit: We need to apply the socket options _before_ ...
                try assertions.assertSetOption(expectedLevel: .socket, expectedOption: .so_reuseaddr) { value in
                    (value as? SocketOptionValue) == 1
                }
                // ... we call bind.
                try assertions.assertBind(expectedAddress: localAddress)
                try assertions.assertLocalAddress(address: nil)  // this is an inefficiency in `bind0`.
                try assertions.assertConnect(expectedAddress: serverAddress, result: true)
                try assertions.assertLocalAddress(address: localAddress)
                try assertions.assertRemoteAddress(address: localAddress)
                try assertions.assertRegister { selectable, event, Registration in
                    XCTAssertEqual([.reset, .error], event)
                    return true
                }
                try assertions.assertReregister { selectable, event in
                    XCTAssertEqual([.reset, .error, .readEOF], event)
                    return true
                }
                try assertions.assertDeregister { selectable in
                    true
                }
                try assertions.assertClose(expectedFD: .max)
            }
        }
    }

    func testAcceptingInboundConnections() throws {
        final class ConnectionRecorder: ChannelInboundHandler, Sendable {
            typealias InboundIn = Any
            typealias InboundOut = Any

            let readCount = ManagedAtomic(0)

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                readCount.wrappingIncrement(ordering: .sequentiallyConsistent)
                context.fireChannelRead(data)
            }
        }

        try withSALContext { context in
            let localAddress = try! SocketAddress(ipAddress: "1.2.3.4", port: 5)
            let remoteAddress = try! SocketAddress(ipAddress: "5.6.7.8", port: 10)
            let channel = try context.makeBoundServerSocketChannel(localAddress: localAddress)
            let unsafeTransferSocket = try context.makeSocket()

            let readRecorder = ConnectionRecorder()

            try context.runSALOnEventLoopAndWait { _, _, _ in
                channel.pipeline.addHandler(readRecorder)
            } syscallAssertions: { assertions in
                let readEvent = SelectorEvent(
                    io: [.read],
                    registration: NIORegistration(
                        channel: .serverSocketChannel(channel),
                        interested: [.read],
                        registrationID: .initialRegistrationID
                    )
                )
                try assertions.assertWaitingForNotification(result: readEvent)
                try assertions.assertAccept(
                    expectedFD: .max,
                    expectedNonBlocking: true,
                    return: unsafeTransferSocket.wrappedValue
                )
                try assertions.assertLocalAddress(address: localAddress)
                try assertions.assertRemoteAddress(address: remoteAddress)

                // This accept is expected: we delay inbound channel registration by one EL tick.
                try assertions.assertAccept(expectedFD: .max, expectedNonBlocking: true, return: nil)

                // Then we register the inbound channel.
                try assertions.assertRegister { selectable, eventSet, registration in
                    if case (.socketChannel(let channel), let registrationEventSet) =
                        (registration.channel, registration.interested)
                    {

                        XCTAssertEqual(localAddress, channel.localAddress)
                        XCTAssertEqual(remoteAddress, channel.remoteAddress)
                        XCTAssertEqual(eventSet, registrationEventSet)
                        XCTAssertEqual([.reset, .error], eventSet)
                        return true
                    } else {
                        return false
                    }
                }
                try assertions.assertReregister { selectable, eventSet in
                    XCTAssertEqual([.reset, .error, .readEOF], eventSet)
                    return true
                }
                // because autoRead is on by default
                try assertions.assertReregister { selectable, eventSet in
                    XCTAssertEqual([.reset, .error, .readEOF, .read], eventSet)
                    return true
                }

                try assertions.assertParkedRightNow()
            }

            XCTAssertEqual(readRecorder.readCount.load(ordering: .sequentiallyConsistent), 1)
        }
    }

    func testAcceptingInboundConnectionsDoesntUnregisterForReadIfTheSecondAcceptErrors() throws {
        final class ConnectionRecorder: ChannelInboundHandler, Sendable {
            typealias InboundIn = Any
            typealias InboundOut = Any

            let readCount = ManagedAtomic(0)

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                readCount.wrappingIncrement(ordering: .sequentiallyConsistent)
                context.fireChannelRead(data)
            }
        }

        try withSALContext { context in
            let localAddress = try! SocketAddress(ipAddress: "1.2.3.4", port: 5)
            let remoteAddress = try! SocketAddress(ipAddress: "5.6.7.8", port: 10)
            let channel = try context.makeBoundServerSocketChannel(localAddress: localAddress)
            let unsafeTransferSocket = try context.makeSocket()

            let readRecorder = ConnectionRecorder()

            try context.runSALOnEventLoopAndWait { _, _, _ in
                channel.pipeline.addHandler(readRecorder)
            } syscallAssertions: { assertions in
                let readEvent = SelectorEvent(
                    io: [.read],
                    registration: NIORegistration(
                        channel: .serverSocketChannel(channel),
                        interested: [.read],
                        registrationID: .initialRegistrationID
                    )
                )
                try assertions.assertWaitingForNotification(result: readEvent)
                try assertions.assertAccept(
                    expectedFD: .max,
                    expectedNonBlocking: true,
                    return: unsafeTransferSocket.wrappedValue
                )
                try assertions.assertLocalAddress(address: localAddress)
                try assertions.assertRemoteAddress(address: remoteAddress)

                // This accept is expected: we delay inbound channel registration by one EL tick. This one throws.
                // We throw a deliberate error here: this one hits the buggy codepath.
                try assertions.assertAccept(
                    expectedFD: .max,
                    expectedNonBlocking: true,
                    throwing: NIOFcntlFailedError()
                )

                // Then we register the inbound channel from the first accept.
                try assertions.assertRegister { selectable, eventSet, registration in
                    if case (.socketChannel(let channel), let registrationEventSet) =
                        (registration.channel, registration.interested)
                    {

                        XCTAssertEqual(localAddress, channel.localAddress)
                        XCTAssertEqual(remoteAddress, channel.remoteAddress)
                        XCTAssertEqual(eventSet, registrationEventSet)
                        XCTAssertEqual([.reset, .error], eventSet)
                        return true
                    } else {
                        return false
                    }
                }
                try assertions.assertReregister { selectable, eventSet in
                    XCTAssertEqual([.reset, .error, .readEOF], eventSet)
                    return true
                }
                // because autoRead is on by default
                try assertions.assertReregister { selectable, eventSet in
                    XCTAssertEqual([.reset, .error, .readEOF, .read], eventSet)
                    return true
                }

                // Importantly, we should now be _parked_. This test is mostly testing in the absence:
                // we expect not to see a reregister that removes readable.
                try assertions.assertParkedRightNow()
            }

            XCTAssertEqual(readRecorder.readCount.load(ordering: .sequentiallyConsistent), 1)
        }
    }

    func testWriteBeforeChannelActiveClientStreamDelayedConnect() throws {
        try withSALContext { context in
            let channel = try context.makeSocketChannel()
            let localAddress = try! SocketAddress(ipAddress: "1.2.3.4", port: 5)
            let serverAddress = try! SocketAddress(ipAddress: "9.8.7.6", port: 5)
            let firstWrite = ByteBuffer(string: "foo")
            let secondWrite = ByteBuffer(string: "bar")

            try context.runSALOnEventLoopAndWait { _, _, _ in
                ClientBootstrap(group: channel.eventLoop)
                    .channelOption(.autoRead, value: false)
                    .channelInitializer { channel in
                        channel.write(firstWrite, promise: nil)
                        channel.write(secondWrite).whenComplete { _ in
                            channel.close(promise: nil)
                        }
                        channel.flush()
                        return channel.eventLoop.makeSucceededVoidFuture()
                    }
                    .testOnly_connect(injectedChannel: channel, to: serverAddress)
                    .flatMap {
                        $0.closeFuture
                    }
            } syscallAssertions: { assertions in
                try assertions.assertSetOption(expectedLevel: .tcp, expectedOption: .tcp_nodelay) { value in
                    (value as? SocketOptionValue) == 1
                }
                try assertions.assertConnect(expectedAddress: serverAddress, result: false)
                try assertions.assertLocalAddress(address: localAddress)
                try assertions.assertRegister { selectable, event, Registration in
                    XCTAssertEqual([.reset, .error], event)
                    return true
                }
                try assertions.assertReregister { selectable, event in
                    XCTAssertEqual([.reset, .error, .write], event)
                    return true
                }

                let writeEvent = SelectorEvent(
                    io: [.write],
                    registration: NIORegistration(
                        channel: .socketChannel(channel),
                        interested: [.reset, .write],
                        registrationID: .initialRegistrationID
                    )
                )
                try assertions.assertWaitingForNotification(result: writeEvent)
                try assertions.assertGetOption(expectedLevel: .socket, expectedOption: .so_error, value: CInt(0))
                try assertions.assertRemoteAddress(address: serverAddress)

                try assertions.assertReregister { selectable, event in
                    XCTAssertEqual([.reset, .error, .readEOF, .write], event)
                    return true
                }
                try assertions.assertWritev(
                    expectedFD: .max,
                    expectedBytes: [firstWrite, secondWrite],
                    return: .processed(6)
                )

                try assertions.assertDeregister { selectable in
                    true
                }
                try assertions.assertClose(expectedFD: .max)
            }
        }
    }

    func testWriteBeforeChannelActiveClientStreamInstantConnect() throws {
        try withSALContext { context in
            let channel = try context.makeSocketChannel()
            let localAddress = try! SocketAddress(ipAddress: "1.2.3.4", port: 5)
            let serverAddress = try! SocketAddress(ipAddress: "9.8.7.6", port: 5)
            let firstWrite = ByteBuffer(string: "foo")
            let secondWrite = ByteBuffer(string: "bar")

            try context.runSALOnEventLoopAndWait { _, _, _ in
                ClientBootstrap(group: channel.eventLoop)
                    .channelOption(.autoRead, value: false)
                    .channelInitializer { channel in
                        channel.write(firstWrite, promise: nil)
                        channel.write(secondWrite).whenComplete { _ in
                            channel.close(promise: nil)
                        }
                        channel.flush()
                        return channel.eventLoop.makeSucceededVoidFuture()
                    }
                    .testOnly_connect(injectedChannel: channel, to: serverAddress)
                    .flatMap {
                        $0.closeFuture
                    }
            } syscallAssertions: { assertions in
                try assertions.assertSetOption(expectedLevel: .tcp, expectedOption: .tcp_nodelay) { value in
                    (value as? SocketOptionValue) == 1
                }
                try assertions.assertConnect(expectedAddress: serverAddress, result: true)
                try assertions.assertLocalAddress(address: localAddress)
                try assertions.assertRemoteAddress(address: serverAddress)
                try assertions.assertRegister { selectable, event, Registration in
                    XCTAssertEqual([.reset, .error], event)
                    return true
                }
                try assertions.assertReregister { selectable, event in
                    XCTAssertEqual([.reset, .error, .readEOF], event)
                    return true
                }
                try assertions.assertWritev(
                    expectedFD: .max,
                    expectedBytes: [firstWrite, secondWrite],
                    return: .processed(6)
                )

                try assertions.assertDeregister { selectable in
                    true
                }
                try assertions.assertClose(expectedFD: .max)
            }
        }
    }

    func testWriteBeforeChannelActiveClientStreamInstantConnect_shortWriteLeadsToWritable() throws {
        try withSALContext { context in
            let channel = try context.makeSocketChannel()
            let localAddress = try! SocketAddress(ipAddress: "1.2.3.4", port: 5)
            let serverAddress = try! SocketAddress(ipAddress: "9.8.7.6", port: 5)
            let firstWrite = ByteBuffer(string: "foo")
            let secondWrite = ByteBuffer(string: "bar")

            try context.runSALOnEventLoopAndWait { _, _, _ in
                ClientBootstrap(group: channel.eventLoop)
                    .channelOption(.autoRead, value: false)
                    .channelOption(.writeSpin, value: 1)
                    .channelInitializer { channel in
                        channel.write(firstWrite).whenComplete { _ in
                            // An extra EL spin here to ensure that the close doesn't
                            // beat the writable
                            channel.eventLoop.execute {
                                channel.close(promise: nil)
                            }
                        }
                        channel.write(secondWrite, promise: nil)
                        channel.flush()
                        return channel.eventLoop.makeSucceededVoidFuture()
                    }
                    .testOnly_connect(injectedChannel: channel, to: serverAddress)
                    .flatMap {
                        $0.closeFuture
                    }
            } syscallAssertions: { assertions in
                try assertions.assertSetOption(expectedLevel: .tcp, expectedOption: .tcp_nodelay) { value in
                    (value as? SocketOptionValue) == 1
                }
                try assertions.assertConnect(expectedAddress: serverAddress, result: true)
                try assertions.assertLocalAddress(address: localAddress)
                try assertions.assertRemoteAddress(address: serverAddress)
                try assertions.assertRegister { selectable, event, Registration in
                    XCTAssertEqual([.reset, .error], event)
                    return true
                }
                try assertions.assertReregister { selectable, event in
                    XCTAssertEqual([.reset, .error, .readEOF], event)
                    return true
                }
                try assertions.assertWritev(
                    expectedFD: .max,
                    expectedBytes: [firstWrite, secondWrite],
                    return: .processed(3)
                )
                try assertions.assertWrite(expectedFD: .max, expectedBytes: secondWrite, return: .wouldBlock(0))
                try assertions.assertReregister { selectable, event in
                    XCTAssertEqual([.reset, .error, .readEOF, .write], event)
                    return true
                }

                try assertions.assertDeregister { selectable in
                    true
                }
                try assertions.assertClose(expectedFD: .max)
            }
        }
    }

    func testWriteBeforeChannelActiveClientStreamInstantConnect_shortWriteLeadsToWritable_instantClose() throws {
        try withSALContext { context in
            let channel = try context.makeSocketChannel()
            let localAddress = try! SocketAddress(ipAddress: "1.2.3.4", port: 5)
            let serverAddress = try! SocketAddress(ipAddress: "9.8.7.6", port: 5)
            let firstWrite = ByteBuffer(string: "foo")
            let secondWrite = ByteBuffer(string: "bar")

            try context.runSALOnEventLoopAndWait { _, _, _ in
                ClientBootstrap(group: channel.eventLoop)
                    .channelOption(.autoRead, value: false)
                    .channelOption(.writeSpin, value: 1)
                    .channelInitializer { channel in
                        channel.write(firstWrite).whenComplete { _ in
                            // No EL spin here so the close happens in the middle of the write spin.
                            channel.close(promise: nil)
                        }
                        channel.write(secondWrite, promise: nil)
                        channel.flush()
                        return channel.eventLoop.makeSucceededVoidFuture()
                    }
                    .testOnly_connect(injectedChannel: channel, to: serverAddress)
                    .flatMap {
                        $0.closeFuture
                    }
            } syscallAssertions: { assertions in
                try assertions.assertSetOption(expectedLevel: .tcp, expectedOption: .tcp_nodelay) { value in
                    (value as? SocketOptionValue) == 1
                }
                try assertions.assertConnect(expectedAddress: serverAddress, result: true)
                try assertions.assertLocalAddress(address: localAddress)
                try assertions.assertRemoteAddress(address: serverAddress)
                try assertions.assertRegister { selectable, event, Registration in
                    XCTAssertEqual([.reset, .error], event)
                    return true
                }
                try assertions.assertReregister { selectable, event in
                    XCTAssertEqual([.reset, .error, .readEOF], event)
                    return true
                }
                try assertions.assertWritev(
                    expectedFD: .max,
                    expectedBytes: [firstWrite, secondWrite],
                    return: .processed(3)
                )

                try assertions.assertDeregister { selectable in
                    true
                }
                try assertions.assertClose(expectedFD: .max)
            }
        }
    }

    func testWriteBeforeChannelActiveServerStream() throws {
        try withSALContext { context in
            let localAddress = try! SocketAddress(ipAddress: "1.2.3.4", port: 5)
            let remoteAddress = try! SocketAddress(ipAddress: "5.6.7.8", port: 10)
            let channel = try context.makeBoundServerSocketChannel(localAddress: localAddress)

            let unsafeTransferSocket = try context.makeSocket()
            let firstWrite = ByteBuffer(string: "foo")
            let secondWrite = ByteBuffer(string: "bar")

            try context.runSALOnEventLoop { _, _, _ in
                try channel.pipeline.syncOperations.addHandler(
                    ServerBootstrap.AcceptHandler(
                        childChannelInitializer: { channel in
                            channel.write(firstWrite, promise: nil)
                            channel.write(secondWrite).whenComplete { _ in
                                channel.close(promise: nil)
                            }
                            channel.flush()
                            return channel.eventLoop.makeSucceededVoidFuture()
                        },
                        childChannelOptions: .init()
                    )
                )
            } syscallAssertions: { assertions in
                let readEvent = SelectorEvent(
                    io: [.read],
                    registration: NIORegistration(
                        channel: .serverSocketChannel(channel),
                        interested: [.read],
                        registrationID: .initialRegistrationID
                    )
                )
                try assertions.assertWaitingForNotification(result: readEvent)
                try assertions.assertAccept(
                    expectedFD: .max,
                    expectedNonBlocking: true,
                    return: unsafeTransferSocket.wrappedValue
                )
                try assertions.assertLocalAddress(address: localAddress)
                try assertions.assertRemoteAddress(address: remoteAddress)

                // This accept is expected: we delay inbound channel registration by one EL tick.
                try assertions.assertAccept(expectedFD: .max, expectedNonBlocking: true, return: nil)

                // Then we register the inbound channel.
                try assertions.assertRegister { selectable, eventSet, registration in
                    if case (.socketChannel(let channel), let registrationEventSet) =
                        (registration.channel, registration.interested)
                    {

                        XCTAssertEqual(localAddress, channel.localAddress)
                        XCTAssertEqual(remoteAddress, channel.remoteAddress)
                        XCTAssertEqual(eventSet, registrationEventSet)
                        XCTAssertEqual([.reset, .error], eventSet)
                        return true
                    } else {
                        return false
                    }
                }
                try assertions.assertReregister { selectable, event in
                    XCTAssertEqual([.reset, .error, .readEOF], event)
                    return true
                }

                // We then get an immediate write which completes, then a close.
                try assertions.assertWritev(
                    expectedFD: .max,
                    expectedBytes: [firstWrite, secondWrite],
                    return: .processed(6)
                )

                try assertions.assertDeregister { selectable in
                    true
                }
                try assertions.assertClose(expectedFD: .max)

                try assertions.assertParkedRightNow()
            }
        }
    }

    func testWriteBeforeChannelActiveServerStream_shortWriteLeadsToWritable() throws {
        try withSALContext { context in
            let localAddress = try! SocketAddress(ipAddress: "1.2.3.4", port: 5)
            let remoteAddress = try! SocketAddress(ipAddress: "5.6.7.8", port: 10)
            let channel = try context.makeBoundServerSocketChannel(localAddress: localAddress)

            let unsafeTransferSocket = try context.makeSocket()
            let firstWrite = ByteBuffer(string: "foo")
            let secondWrite = ByteBuffer(string: "bar")
            var childChannelOptions = ChannelOptions.Storage()
            childChannelOptions.append(key: .autoRead, value: false)

            try context.runSALOnEventLoop { [childChannelOptions] _, _, _ in
                try channel.pipeline.syncOperations.addHandler(
                    ServerBootstrap.AcceptHandler(
                        childChannelInitializer: { channel in
                            channel.write(firstWrite).whenComplete { _ in
                                // An extra EL spin here to ensure that the close doesn't
                                // beat the writable
                                channel.eventLoop.execute {
                                    channel.close(promise: nil)
                                }
                            }
                            channel.write(secondWrite, promise: nil)
                            channel.flush()
                            return channel.eventLoop.makeSucceededVoidFuture()
                        },
                        childChannelOptions: childChannelOptions
                    )
                )
            } syscallAssertions: { assertions in
                let readEvent = SelectorEvent(
                    io: [.read],
                    registration: NIORegistration(
                        channel: .serverSocketChannel(channel),
                        interested: [.read],
                        registrationID: .initialRegistrationID
                    )
                )
                try assertions.assertWaitingForNotification(result: readEvent)
                try assertions.assertAccept(
                    expectedFD: .max,
                    expectedNonBlocking: true,
                    return: unsafeTransferSocket.wrappedValue
                )
                try assertions.assertLocalAddress(address: localAddress)
                try assertions.assertRemoteAddress(address: remoteAddress)

                // This accept is expected: we delay inbound channel registration by one EL tick.
                try assertions.assertAccept(expectedFD: .max, expectedNonBlocking: true, return: nil)

                // Then we register the inbound channel.
                try assertions.assertRegister { selectable, eventSet, registration in
                    if case (.socketChannel(let channel), let registrationEventSet) =
                        (registration.channel, registration.interested)
                    {

                        XCTAssertEqual(localAddress, channel.localAddress)
                        XCTAssertEqual(remoteAddress, channel.remoteAddress)
                        XCTAssertEqual(eventSet, registrationEventSet)
                        XCTAssertEqual([.reset, .error], eventSet)
                        return true
                    } else {
                        return false
                    }
                }
                try assertions.assertReregister { selectable, event in
                    XCTAssertEqual([.reset, .error, .readEOF], event)
                    return true
                }

                try assertions.assertWritev(
                    expectedFD: .max,
                    expectedBytes: [firstWrite, secondWrite],
                    return: .processed(3)
                )
                try assertions.assertWrite(expectedFD: .max, expectedBytes: secondWrite, return: .wouldBlock(0))
                try assertions.assertReregister { selectable, event in
                    XCTAssertEqual([.reset, .error, .readEOF, .write], event)
                    return true
                }

                try assertions.assertDeregister { selectable in
                    true
                }
                try assertions.assertClose(expectedFD: .max)

                try assertions.assertParkedRightNow()
            }
        }
    }

    func testWriteBeforeChannelActiveServerStream_shortWriteLeadsToWritable_instantClose() throws {
        try withSALContext { context in
            let localAddress = try! SocketAddress(ipAddress: "1.2.3.4", port: 5)
            let remoteAddress = try! SocketAddress(ipAddress: "5.6.7.8", port: 10)
            let channel = try context.makeBoundServerSocketChannel(localAddress: localAddress)

            let unsafeTransferSocket = try context.makeSocket()
            let firstWrite = ByteBuffer(string: "foo")
            let secondWrite = ByteBuffer(string: "bar")
            var childChannelOptions = ChannelOptions.Storage()
            childChannelOptions.append(key: .autoRead, value: false)

            try context.runSALOnEventLoop { [childChannelOptions] _, _, _ in
                try channel.pipeline.syncOperations.addHandler(
                    ServerBootstrap.AcceptHandler(
                        childChannelInitializer: { channel in
                            channel.write(firstWrite).whenComplete { _ in
                                channel.close(promise: nil)
                            }
                            channel.write(secondWrite, promise: nil)
                            channel.flush()
                            return channel.eventLoop.makeSucceededVoidFuture()
                        },
                        childChannelOptions: childChannelOptions
                    )
                )
            } syscallAssertions: { assertions in
                let readEvent = SelectorEvent(
                    io: [.read],
                    registration: NIORegistration(
                        channel: .serverSocketChannel(channel),
                        interested: [.read],
                        registrationID: .initialRegistrationID
                    )
                )
                try assertions.assertWaitingForNotification(result: readEvent)
                try assertions.assertAccept(
                    expectedFD: .max,
                    expectedNonBlocking: true,
                    return: unsafeTransferSocket.wrappedValue
                )
                try assertions.assertLocalAddress(address: localAddress)
                try assertions.assertRemoteAddress(address: remoteAddress)

                // This accept is expected: we delay inbound channel registration by one EL tick.
                try assertions.assertAccept(expectedFD: .max, expectedNonBlocking: true, return: nil)

                // Then we register the inbound channel.
                try assertions.assertRegister { selectable, eventSet, registration in
                    if case (.socketChannel(let channel), let registrationEventSet) =
                        (registration.channel, registration.interested)
                    {

                        XCTAssertEqual(localAddress, channel.localAddress)
                        XCTAssertEqual(remoteAddress, channel.remoteAddress)
                        XCTAssertEqual(eventSet, registrationEventSet)
                        XCTAssertEqual([.reset, .error], eventSet)
                        return true
                    } else {
                        return false
                    }
                }
                try assertions.assertReregister { selectable, event in
                    XCTAssertEqual([.reset, .error, .readEOF], event)
                    return true
                }

                try assertions.assertWritev(
                    expectedFD: .max,
                    expectedBytes: [firstWrite, secondWrite],
                    return: .processed(3)
                )
                try assertions.assertDeregister { selectable in
                    true
                }
                try assertions.assertClose(expectedFD: .max)

                try assertions.assertParkedRightNow()
            }
        }
    }

    func testBaseSocketChannelFlushNowReentrancyCrash() throws {
        final class TestHandler: ChannelInboundHandler {
            typealias InboundIn = Any
            typealias OutboundOut = ByteBuffer

            private let buffer: ByteBuffer

            init(_ buffer: ByteBuffer) {
                self.buffer = buffer
            }

            func channelActive(context: ChannelHandlerContext) {
                context.write(self.wrapOutboundOut(buffer), promise: nil)
                context.write(self.wrapOutboundOut(buffer), promise: nil)
                context.flush()
                context.fireChannelActive()
            }

            func channelWritabilityChanged(context: ChannelHandlerContext) {
                if context.channel.isWritable {
                    context.close(promise: nil)
                }
                context.fireChannelWritabilityChanged()
            }
        }

        try withSALContext { context in
            let channel = try context.makeSocketChannel()
            let localAddress = try! SocketAddress(ipAddress: "1.2.3.4", port: 5)
            let serverAddress = try! SocketAddress(ipAddress: "9.8.7.6", port: 5)
            let buffer = ByteBuffer(repeating: 0, count: 1024)

            try context.runSALOnEventLoopAndWait { _, _, _ in
                ClientBootstrap(group: channel.eventLoop)
                    .channelOption(.autoRead, value: false)
                    .channelOption(.writeSpin, value: 0)
                    .channelOption(
                        .writeBufferWaterMark,
                        value: .init(low: buffer.readableBytes + 1, high: buffer.readableBytes + 1)
                    )
                    .channelInitializer { channel in
                        try! channel.pipeline.syncOperations.addHandler(TestHandler(buffer))
                        return channel.eventLoop.makeSucceededVoidFuture()
                    }
                    .testOnly_connect(injectedChannel: channel, to: serverAddress)
                    .flatMap {
                        $0.closeFuture
                    }
            } syscallAssertions: { assertions in
                try assertions.assertSetOption(expectedLevel: .tcp, expectedOption: .tcp_nodelay) { value in
                    (value as? SocketOptionValue) == 1
                }
                try assertions.assertConnect(expectedAddress: serverAddress, result: false)
                try assertions.assertLocalAddress(address: localAddress)
                try assertions.assertRegister { selectable, event, Registration in
                    XCTAssertEqual([.reset, .error], event)
                    return true
                }
                try assertions.assertReregister { selectable, event in
                    XCTAssertEqual([.reset, .error, .write], event)
                    return true
                }

                let writeEvent = SelectorEvent(
                    io: [.write],
                    registration: NIORegistration(
                        channel: .socketChannel(channel),
                        interested: [.reset, .write],
                        registrationID: .initialRegistrationID
                    )
                )
                try assertions.assertWaitingForNotification(result: writeEvent)
                try assertions.assertGetOption(expectedLevel: .socket, expectedOption: .so_error, value: CInt(0))
                try assertions.assertRemoteAddress(address: serverAddress)

                try assertions.assertReregister { selectable, event in
                    XCTAssertEqual([.reset, .error, .readEOF, .write], event)
                    return true
                }
                try assertions.assertWritev(
                    expectedFD: .max,
                    expectedBytes: [buffer, buffer],
                    return: .wouldBlock(0)
                )
                try assertions.assertWritev(
                    expectedFD: .max,
                    expectedBytes: [buffer, buffer],
                    return: .wouldBlock(0)
                )

                let canWriteEvent = SelectorEvent(
                    io: [.write],
                    registration: NIORegistration(
                        channel: .socketChannel(channel),
                        interested: [.reset, .readEOF, .write],
                        registrationID: .initialRegistrationID
                    )
                )
                try assertions.assertWaitingForNotification(result: canWriteEvent)
                try assertions.assertWritev(
                    expectedFD: .max,
                    expectedBytes: [buffer, buffer],
                    return: .processed(buffer.readableBytes)
                )

                try assertions.assertDeregister { selectable in
                    true
                }
                try assertions.assertClose(expectedFD: .max)
            }
        }
    }
}
