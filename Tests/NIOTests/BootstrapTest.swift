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

@testable import NIO
import NIOConcurrencyHelpers
import XCTest

class BootstrapTest: XCTestCase {
    var groupBag: [MultiThreadedEventLoopGroup]? = nil // protected by `self.lock`
    let lock = Lock()

    override func setUp() {
        self.lock.withLock {
            XCTAssertNil(self.groupBag)
            self.groupBag = []
        }
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.lock.withLock {
            guard let groupBag = self.groupBag else {
                XCTFail()
                return
            }
            XCTAssertNoThrow(try groupBag.forEach {
                XCTAssertNoThrow(try $0.syncShutdownGracefully())
            })
            self.groupBag = nil
        })
    }

    func freshEventLoop() -> EventLoop {
        let group: MultiThreadedEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.lock.withLock {
            self.groupBag!.append(group)
        }
        return group.next()
    }

    func testBootstrapsCallInitializersOnCorrectEventLoop() throws {
        for numThreads in [1 /* everything on one event loop */,
                           2 /* some stuff has shared event loops */,
                           5 /* everything on a different event loop */] {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: numThreads)
            defer {
                XCTAssertNoThrow(try group.syncShutdownGracefully())
            }

            let childChannelDone = group.next().makePromise(of: Void.self)
            let serverChannelDone = group.next().makePromise(of: Void.self)
            let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    XCTAssert(channel.eventLoop.inEventLoop)
                    childChannelDone.succeed(())
                    return channel.eventLoop.makeSucceededFuture(())
                }
                .serverChannelInitializer { channel in
                    XCTAssert(channel.eventLoop.inEventLoop)
                    serverChannelDone.succeed(())
                    return channel.eventLoop.makeSucceededFuture(())
                }
                .bind(host: "localhost", port: 0)
                .wait())
            defer {
                XCTAssertNoThrow(try serverChannel.close().wait())
            }

            let client = try assertNoThrowWithValue(ClientBootstrap(group: group)
                .channelInitializer { channel in
                    XCTAssert(channel.eventLoop.inEventLoop)
                    return channel.eventLoop.makeSucceededFuture(())
                }
                .connect(to: serverChannel.localAddress!)
                .wait(), message: "resolver debug info: \(try! resolverDebugInformation(eventLoop: group.next(),host: "localhost", previouslyReceivedResult: serverChannel.localAddress!))")
            defer {
                XCTAssertNoThrow(try client.syncCloseAcceptingAlreadyClosed())
            }
            XCTAssertNoThrow(try childChannelDone.futureResult.wait())
            XCTAssertNoThrow(try serverChannelDone.futureResult.wait())
        }
    }

    func testTCPBootstrapsTolerateFuturesFromDifferentEventLoopsReturnedInInitializers() throws {
        let childChannelDone = self.freshEventLoop().makePromise(of: Void.self)
        let serverChannelDone = self.freshEventLoop().makePromise(of: Void.self)
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: self.freshEventLoop())
            .childChannelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                defer {
                    childChannelDone.succeed(())
                }
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .serverChannelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                defer {
                    serverChannelDone.succeed(())
                }
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait())
        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let client = try assertNoThrowWithValue(ClientBootstrap(group: self.freshEventLoop())
            .channelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .connect(to: serverChannel.localAddress!)
            .wait())
        defer {
            XCTAssertNoThrow(try client.syncCloseAcceptingAlreadyClosed())
        }
        XCTAssertNoThrow(try childChannelDone.futureResult.wait())
        XCTAssertNoThrow(try serverChannelDone.futureResult.wait())
    }

    func testUDPBootstrapToleratesFuturesFromDifferentEventLoopsReturnedInInitializers() throws {
        XCTAssertNoThrow(try DatagramBootstrap(group: self.freshEventLoop())
            .channelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                return self.freshEventLoop().makeSucceededFuture(())
        }
        .bind(host: "127.0.0.1", port: 0)
        .wait()
        .close()
        .wait())
    }

    func testPreConnectedClientSocketToleratesFuturesFromDifferentEventLoopsReturnedInInitializers() throws {
        var socketFDs: [CInt] = [-1, -1]
        #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
        let err = socketpair(PF_LOCAL, SOCK_STREAM, 0, &socketFDs)
        #else
        let err = socketpair(PF_LOCAL, CInt(SOCK_STREAM.rawValue), 0, &socketFDs)
        #endif
        XCTAssertEqual(0, err)
        defer {
            // 0 is closed together with the Channel below.
            XCTAssertNoThrow(try Posix.close(descriptor: socketFDs[1]))
        }

        XCTAssertNoThrow(try ClientBootstrap(group: self.freshEventLoop())
            .channelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .withConnectedSocket(descriptor: socketFDs[0])
            .wait()
            .close()
            .wait())
    }

    func testPreConnectedServerSocketToleratesFuturesFromDifferentEventLoopsReturnedInInitializers() throws {
        let socket = try Posix.socket(domain: AF_INET, type: Posix.SOCK_STREAM, protocol: 0)

        let serverAddress = try assertNoThrowWithValue(SocketAddress.makeAddressResolvingHost("127.0.0.1", port: 0))
        try serverAddress.withSockAddr { serverAddressPtr, size in
            try Posix.bind(descriptor: socket, ptr: serverAddressPtr,
                           bytes: size)
        }

        let childChannelDone = self.freshEventLoop().next().makePromise(of: Void.self)
        let serverChannelDone = self.freshEventLoop().next().makePromise(of: Void.self)

        let serverChannel = try assertNoThrowWithValue(try ServerBootstrap(group: self.freshEventLoop())
            .childChannelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                defer {
                    childChannelDone.succeed(())
                }
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .serverChannelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                defer {
                    serverChannelDone.succeed(())
                }
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .withBoundSocket(descriptor: socket)
            .wait())
        let client = try assertNoThrowWithValue(ClientBootstrap(group: self.freshEventLoop())
            .channelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .connect(to: serverChannel.localAddress!)
            .wait())
        defer {
            XCTAssertNoThrow(try client.syncCloseAcceptingAlreadyClosed())
        }
        XCTAssertNoThrow(try childChannelDone.futureResult.wait())
        XCTAssertNoThrow(try serverChannelDone.futureResult.wait())
    }

    func testCanBindOnClientConnection() {
        XCTAssertNoThrow(try withTCPServerChannel { serverChannel in
            var maybeClient: Channel?
            XCTAssertNoThrow(maybeClient = try ClientBootstrap(group: serverChannel.eventLoop)
                .channelInitializer { childChannel in
                    childChannel.bind(to: try! .init(ipAddress: "127.0.0.1", port: 12345))
            }
            .connect(to: serverChannel.localAddress!)
            .wait())
            guard let client = maybeClient else {
                XCTFail()
                return
            }
            XCTAssertEqual(12345, client.localAddress?.port)
        })
    }
}
