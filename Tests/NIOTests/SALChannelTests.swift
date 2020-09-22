//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
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
import NIOConcurrencyHelpers

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

        let writableNotificationStepExpectation = NIOAtomic<Int>.makeAtomic(value: 0)

        final class DoWriteFromWritabilityChangedNotification: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            var numberOfCalls = 0

            var writableNotificationStepExpectation: NIOAtomic<Int>

            init(writableNotificationStepExpectation: NIOAtomic<Int>) {
                self.writableNotificationStepExpectation = writableNotificationStepExpectation
            }

            func channelWritabilityChanged(context: ChannelHandlerContext) {
                self.numberOfCalls += 1

                XCTAssertEqual(self.writableNotificationStepExpectation.load(),
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
                    XCTAssertTrue(self.writableNotificationStepExpectation.compareAndExchange(expected: 2, desired: 3))
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
            XCTAssertTrue(writableNotificationStepExpectation.compareAndExchange(expected: 1, desired: 2))
            try self.assertWaitingForNotification(result: .some(.init(io: [.write],
                                                                      registration: .socketChannel(channel, [.write]))))
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
            try self.assertWaitingForNotification(result: .some(.init(io: [.write],
                                                                      registration: .socketChannel(channel, [.write]))))

            // This time, we'll make the write write everything which should also lead to a final channelWritability
            // change.
            XCTAssertTrue(writableNotificationStepExpectation.compareAndExchange(expected: 3, desired: 4))
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
                XCTAssertTrue(writableNotificationStepExpectation.compareAndExchange(expected: 0, desired: 1))
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
            try self.assertWaitingForNotification(result: .some(.init(io: [.read],
                                                                      registration: .socketChannel(channel, [.read]))))
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

}
