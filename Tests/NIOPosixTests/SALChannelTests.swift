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

import XCTest
import NIOCore
@testable import NIOPosix
import Atomics

final class SALChannelTest: XCTestCase, SALTest {
    var group: MultiThreadedEventLoopGroup!
    var kernelToUserBox: LockedBox<KernelToUser>!
    var userToKernelBox: LockedBox<UserToKernel>!
    var wakeups: LockedBox<()>!

    override func setUp() {
        self.setUpSAL()
    }

    override func tearDown() {
        self.tearDownSAL()
    }

    func testBasicConnectedChannel() throws {
        let localAddress = try! SocketAddress(ipAddress: "0.1.2.3", port: 4)
        let serverAddress = try! SocketAddress(ipAddress: "9.8.7.6", port: 5)
        let buffer = ByteBuffer(string: "xxx")

        let channel = try self.makeConnectedSocketChannel(localAddress: localAddress,
                                                          remoteAddress: serverAddress)

        try channel.eventLoop.runSAL(syscallAssertions: {
            try self.assertWrite(expectedFD: .max, expectedBytes: buffer, return: .processed(buffer.readableBytes))
            try self.assertWritev(expectedFD: .max, expectedBytes: [buffer, buffer], return: .processed(2 * buffer.readableBytes))
            try self.assertDeregister { selectable in
                try selectable.withUnsafeHandle {
                    XCTAssertEqual(.max, $0)
                }
                return true
            }
            try self.assertClose(expectedFD: .max)
        }) {
            channel.writeAndFlush(buffer).flatMap {
                channel.write(buffer, promise: nil)
                return channel.writeAndFlush(buffer)
            }.flatMap {
                channel.close()
            }
        }.salWait()
    }

    func testWritesFromWritabilityNotificationsDoNotGetLostIfWePreviouslyWroteEverything() {
        // This is a unit test, doing what
        //     testWriteAndFlushFromReentrantFlushNowTriggeredOutOfWritabilityWhereOuterSaysAllWrittenAndInnerDoesNot
        // does but in a deterministic way, without having to send actual bytes.

        let localAddress = try! SocketAddress(ipAddress: "0.1.2.3", port: 4)
        let serverAddress = try! SocketAddress(ipAddress: "9.8.7.6", port: 5)
        var buffer = ByteBuffer(string: "12")

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

                XCTAssertEqual(self.writableNotificationStepExpectation.load(ordering: .relaxed),
                               numberOfCalls)
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
                    XCTAssertTrue(self.writableNotificationStepExpectation.compareExchange(expected: 2, desired: 3, ordering: .relaxed).exchanged)
                    context.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil)
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

        var maybeChannel: SocketChannel? = nil
        XCTAssertNoThrow(maybeChannel = try self.makeConnectedSocketChannel(localAddress: localAddress,
                                                                            remoteAddress: serverAddress))
        guard let channel = maybeChannel else {
            XCTFail("couldn't construct channel")
            return
        }

        XCTAssertNoThrow(try channel.eventLoop.runSAL(syscallAssertions: {
            // We get in a write of 2 bytes, and we claim we wrote 1 bytes of that.
            try self.assertWrite(expectedFD: .max, expectedBytes: buffer, return: .processed(1))

            // Next, we expect a reregistration which adds the `.write` notification
            try self.assertReregister { selectable, eventSet in
                XCTAssert(selectable as? Socket === channel.socket)
                XCTAssertEqual([.read, .reset, .readEOF, .write], eventSet)
                return true
            }

            // Before sending back the writable notification, we know that that'll trigger a Channel writability change
            XCTAssertTrue(writableNotificationStepExpectation.compareExchange(expected: 1, desired: 2, ordering: .relaxed).exchanged)
            let writableEvent = SelectorEvent(io: [.write],
                                              registration: NIORegistration(channel: .socketChannel(channel),
                                                                            interested:  [.write],
                                                                            registrationID: .initialRegistrationID))
            try self.assertWaitingForNotification(result: writableEvent)
            try self.assertWrite(expectedFD: .max,
                                 expectedBytes: buffer.getSlice(at: 1, length: 1)!,
                                 return: .processed(1))
            buffer.clear()
            buffer.writeString("ABC") // expected

            // This time, the write again, just writes one byte, so we should remain registered for writable.
            try self.assertWrite(expectedFD: .max,
                                 expectedBytes: buffer,
                                 return: .processed(1))
            buffer.moveReaderIndex(forwardBy: 1)

            // Let's send them another 'writable' notification:
            try self.assertWaitingForNotification(result: writableEvent)

            // This time, we'll make the write write everything which should also lead to a final channelWritability
            // change.
            XCTAssertTrue(writableNotificationStepExpectation.compareExchange(expected: 3, desired: 4, ordering: .relaxed).exchanged)
            try self.assertWrite(expectedFD: .max,
                                 expectedBytes: buffer,
                                 return: .processed(2))

            // And lastly, after having written everything, we'd expect to unregister for write
            try self.assertReregister { selectable, eventSet in
                XCTAssert(selectable as? Socket === channel.socket)
                XCTAssertEqual([.read, .reset, .readEOF], eventSet)
                return true
            }

            try self.assertParkedRightNow()
        }) { () -> EventLoopFuture<Void> in
            channel.setOption(ChannelOptions.writeSpin, value: 0).flatMap {
                channel.setOption(ChannelOptions.writeBufferWaterMark, value: .init(low: 1, high: 1))
            }.flatMap {
                channel.pipeline.addHandler(DoWriteFromWritabilityChangedNotification(writableNotificationStepExpectation: writableNotificationStepExpectation))
            }.flatMap {
                // This write should cause a Channel writability change.
                XCTAssertTrue(writableNotificationStepExpectation.compareExchange(expected: 0, desired: 1, ordering: .relaxed).exchanged)
                return channel.writeAndFlush(buffer)
            }
        }.salWait())
    }

    func testWeSurviveIfIgnoringSIGPIPEFails() {
        // We know this sometimes happens on Darwin, so let's test it.
        let expectedError = IOError(errnoCode: EINVAL, reason: "bad")
        XCTAssertThrowsError(try self.makeSocketChannelInjectingFailures(disableSIGPIPEFailure: expectedError)) { error in
            XCTAssertEqual(expectedError.errnoCode, (error as? IOError)?.errnoCode)
        }
    }

    func testBasicRead() {
        let localAddress = try! SocketAddress(ipAddress: "0.1.2.3", port: 4)
        let serverAddress = try! SocketAddress(ipAddress: "9.8.7.6", port: 5)

        final class SignalGroupOnRead: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            private let group: DispatchGroup
            private var numberOfCalls = 0

            init(group: DispatchGroup) {
                self.group = group
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                self.numberOfCalls += 1
                XCTAssertEqual("hello",
                               String(decoding: self.unwrapInboundIn(data).readableBytesView, as: Unicode.UTF8.self))
                if self.numberOfCalls == 1 {
                    self.group.leave()
                }
            }
        }

        var maybeChannel: SocketChannel? = nil
        XCTAssertNoThrow(maybeChannel = try self.makeConnectedSocketChannel(localAddress: localAddress,
                                                                            remoteAddress: serverAddress))
        guard let channel = maybeChannel else {
            XCTFail("couldn't construct channel")
            return
        }

        let buffer = ByteBuffer(string: "hello")

        let g = DispatchGroup()
        g.enter()

        XCTAssertNoThrow(try channel.eventLoop.runSAL(syscallAssertions: {
            let readEvent = SelectorEvent(io: [.read],
                                          registration: NIORegistration(channel: .socketChannel(channel),
                                                                        interested: [.read],
                                                                        registrationID: .initialRegistrationID))
            try self.assertWaitingForNotification(result: readEvent)
            try self.assertRead(expectedFD: .max, expectedBufferSpace: 2048, return: buffer)
        }) {
            channel.pipeline.addHandler(SignalGroupOnRead(group: g))
        })

        g.wait()
    }

    func testBasicConnectWithClientBootstrap() {
        guard let channel = try? self.makeSocketChannel() else {
            XCTFail("couldn't make a channel")
            return
        }
        let localAddress = try! SocketAddress(ipAddress: "1.2.3.4", port: 5)
        let serverAddress = try! SocketAddress(ipAddress: "9.8.7.6", port: 5)
        XCTAssertNoThrow(try channel.eventLoop.runSAL(syscallAssertions: {
            try self.assertSetOption(expectedLevel: .tcp, expectedOption: .tcp_nodelay) { value in
                return (value as? SocketOptionValue) == 1
            }
            try self.assertConnect(expectedAddress: serverAddress, result: true)
            try self.assertLocalAddress(address: localAddress)
            try self.assertRemoteAddress(address: localAddress)
            try self.assertRegister { selectable, event, Registration in
                XCTAssertEqual([.reset], event)
                return true
            }
            try self.assertReregister { selectable, event in
                XCTAssertEqual([.reset, .readEOF], event)
                return true
            }
            try self.assertDeregister { selectable in
                return true
            }
            try self.assertClose(expectedFD: .max)
        }) {
            ClientBootstrap(group: channel.eventLoop)
                .channelOption(ChannelOptions.autoRead, value: false)
                .testOnly_connect(injectedChannel: channel, to: serverAddress)
                .flatMap { channel in
                    channel.close()
                }
        }.salWait())
    }

    func testClientBootstrapBindIsDoneAfterSocketOptions() {
        guard let channel = try? self.makeSocketChannel() else {
            XCTFail("couldn't make a channel")
            return
        }
        let localAddress = try! SocketAddress(ipAddress: "1.2.3.4", port: 5)
        let serverAddress = try! SocketAddress(ipAddress: "9.8.7.6", port: 5)
        XCTAssertNoThrow(try channel.eventLoop.runSAL(syscallAssertions: {
            try self.assertSetOption(expectedLevel: .tcp, expectedOption: .tcp_nodelay) { value in
                return (value as? SocketOptionValue) == 1
            }
            // This is the important bit: We need to apply the socket options _before_ ...
            try self.assertSetOption(expectedLevel: .socket, expectedOption: .so_reuseaddr) { value in
                return (value as? SocketOptionValue) == 1
            }
            // ... we call bind.
            try self.assertBind(expectedAddress: localAddress)
            try self.assertLocalAddress(address: nil) // this is an inefficiency in `bind0`.
            try self.assertConnect(expectedAddress: serverAddress, result: true)
            try self.assertLocalAddress(address: localAddress)
            try self.assertRemoteAddress(address: localAddress)
            try self.assertRegister { selectable, event, Registration in
                XCTAssertEqual([.reset], event)
                return true
            }
            try self.assertReregister { selectable, event in
                XCTAssertEqual([.reset, .readEOF], event)
                return true
            }
            try self.assertDeregister { selectable in
                return true
            }
            try self.assertClose(expectedFD: .max)
        }) {
            ClientBootstrap(group: channel.eventLoop)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelOption(ChannelOptions.autoRead, value: false)
                .bind(to: localAddress)
                .testOnly_connect(injectedChannel: channel, to: serverAddress)
                .flatMap { channel in
                    channel.close()
                }
        }.salWait())
    }

    func testAcceptingInboundConnections() throws {
        final class ConnectionRecorder: ChannelInboundHandler {
            typealias InboundIn = Any
            typealias InboundOut = Any

            let readCount = ManagedAtomic(0)

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                readCount.wrappingIncrement(ordering: .sequentiallyConsistent)
                context.fireChannelRead(data)
            }
        }

        let localAddress = try! SocketAddress(ipAddress: "1.2.3.4", port: 5)
        let remoteAddress = try! SocketAddress(ipAddress: "5.6.7.8", port: 10)
        let channel = try self.makeBoundServerSocketChannel(localAddress: localAddress)

        let socket = try self.makeSocket()

        let readRecorder = ConnectionRecorder()
        XCTAssertNoThrow(try channel.eventLoop.runSAL(syscallAssertions: {
            let readEvent = SelectorEvent(io: [.read],
                                          registration: NIORegistration(channel: .serverSocketChannel(channel),
                                                                        interested: [.read],
                                                                        registrationID: .initialRegistrationID))
            try self.assertWaitingForNotification(result: readEvent)
            try self.assertAccept(expectedFD: .max, expectedNonBlocking: true, return: socket)
            try self.assertLocalAddress(address: localAddress)
            try self.assertRemoteAddress(address: remoteAddress)

            // This accept is expected: we delay inbound channel registration by one EL tick.
            try self.assertAccept(expectedFD: .max, expectedNonBlocking: true, return: nil)

            // Then we register the inbound channel.
            try self.assertRegister { selectable, eventSet, registration in
                if case (.socketChannel(let channel), let registrationEventSet) =
                    (registration.channel, registration.interested) {

                    XCTAssertEqual(localAddress, channel.localAddress)
                    XCTAssertEqual(remoteAddress, channel.remoteAddress)
                    XCTAssertEqual(eventSet, registrationEventSet)
                    XCTAssertEqual(.reset, eventSet)
                    return true
                } else {
                    return false
                }
            }
            try self.assertReregister { selectable, eventSet in
                XCTAssertEqual([.reset, .readEOF], eventSet)
                return true
            }
            // because autoRead is on by default
            try self.assertReregister { selectable, eventSet in
                XCTAssertEqual([.reset, .readEOF, .read], eventSet)
                return true
            }

            try self.assertParkedRightNow()
        }) {
            channel.pipeline.addHandler(readRecorder)
        })

        XCTAssertEqual(readRecorder.readCount.load(ordering: .sequentiallyConsistent), 1)
    }

    func testAcceptingInboundConnectionsDoesntUnregisterForReadIfTheSecondAcceptErrors() throws {
        final class ConnectionRecorder: ChannelInboundHandler {
            typealias InboundIn = Any
            typealias InboundOut = Any

            let readCount = ManagedAtomic(0)

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                readCount.wrappingIncrement(ordering: .sequentiallyConsistent)
                context.fireChannelRead(data)
            }
        }

        let localAddress = try! SocketAddress(ipAddress: "1.2.3.4", port: 5)
        let remoteAddress = try! SocketAddress(ipAddress: "5.6.7.8", port: 10)
        let channel = try self.makeBoundServerSocketChannel(localAddress: localAddress)

        let socket = try self.makeSocket()

        let readRecorder = ConnectionRecorder()
        XCTAssertNoThrow(try channel.eventLoop.runSAL(syscallAssertions: {
            let readEvent = SelectorEvent(io: [.read],
                                          registration: NIORegistration(channel: .serverSocketChannel(channel),
                                                                        interested: [.read],
                                                                        registrationID: .initialRegistrationID))
            try self.assertWaitingForNotification(result: readEvent)
            try self.assertAccept(expectedFD: .max, expectedNonBlocking: true, return: socket)
            try self.assertLocalAddress(address: localAddress)
            try self.assertRemoteAddress(address: remoteAddress)

            // This accept is expected: we delay inbound channel registration by one EL tick. This one throws.
            // We throw a deliberate error here: this one hits the buggy codepath.
            try self.assertAccept(expectedFD: .max, expectedNonBlocking: true, throwing: NIOFcntlFailedError())

            // Then we register the inbound channel from the first accept.
            try self.assertRegister { selectable, eventSet, registration in
                if case (.socketChannel(let channel), let registrationEventSet) =
                    (registration.channel, registration.interested) {

                    XCTAssertEqual(localAddress, channel.localAddress)
                    XCTAssertEqual(remoteAddress, channel.remoteAddress)
                    XCTAssertEqual(eventSet, registrationEventSet)
                    XCTAssertEqual(.reset, eventSet)
                    return true
                } else {
                    return false
                }
            }
            try self.assertReregister { selectable, eventSet in
                XCTAssertEqual([.reset, .readEOF], eventSet)
                return true
            }
            // because autoRead is on by default
            try self.assertReregister { selectable, eventSet in
                XCTAssertEqual([.reset, .readEOF, .read], eventSet)
                return true
            }

            // Importantly, we should now be _parked_. This test is mostly testing in the absence:
            // we expect not to see a reregister that removes readable.
            try self.assertParkedRightNow()
        }) {
            channel.pipeline.addHandler(readRecorder)
        })

        XCTAssertEqual(readRecorder.readCount.load(ordering: .sequentiallyConsistent), 1)
    }

}
