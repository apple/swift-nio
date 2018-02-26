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

public class EventLoopTest : XCTestCase {
    
    public func testSchedule() throws {
        let nanos = DispatchTime.now().uptimeNanoseconds
        let amount: TimeAmount = .seconds(1)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }
        let value = try eventLoopGroup.next().scheduleTask(in: amount) {
            return true
        }.futureResult.wait()
        
        XCTAssertTrue(DispatchTime.now().uptimeNanoseconds - nanos >= amount.nanoseconds)
        XCTAssertTrue(value)
    }

    public func testScheduleWithDelay() throws {
        let smallAmount: TimeAmount = .milliseconds(100)
        let longAmount: TimeAmount = .seconds(1)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }

        // First, we create a server and client channel, but don't connect them.
        let serverChannel = try ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "127.0.0.1", port: 0).wait()
        let clientBootstrap = ClientBootstrap(group: eventLoopGroup)

        // Now, schedule two tasks: one that takes a while, one that doesn't.
        let nanos = DispatchTime.now().uptimeNanoseconds
        let longFuture = eventLoopGroup.next().scheduleTask(in: longAmount) {
            return true
        }.futureResult

        _ = try eventLoopGroup.next().scheduleTask(in: smallAmount) {
            return true
        }.futureResult.wait()

        // Ok, the short one has happened. Now we should try connecting them. This connect should happen
        // faster than the final task firing.
        _ = try clientBootstrap.connect(to: serverChannel.localAddress!).wait()
        XCTAssertTrue(DispatchTime.now().uptimeNanoseconds - nanos < longAmount.nanoseconds)

        // Now wait for the long-delayed task.
        _ = try longFuture.wait()
        // Now we're ok.
        XCTAssertTrue(DispatchTime.now().uptimeNanoseconds - nanos >= longAmount.nanoseconds)
    }
    
    public func testScheduleCancelled() throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }
        let ran = Atomic<Bool>(value: false)
        let scheduled = eventLoopGroup.next().scheduleTask(in: .seconds(2)) {
            ran.store(true)
        }
        
        scheduled.cancel()
        
        let nanos = DispatchTime.now().uptimeNanoseconds
        let amount: TimeAmount = .seconds(2)
        let value = try eventLoopGroup.next().scheduleTask(in: amount) {
            return true
        }.futureResult.wait()
        
        XCTAssertTrue(DispatchTime.now().uptimeNanoseconds - nanos >= amount.nanoseconds)
        XCTAssertTrue(value)
        XCTAssertFalse(ran.load())
    }

    public func testMultipleShutdown() throws {
        // This test catches a regression that causes it to intermittently fail: it reveals bugs in synchronous shutdown.
        // Do not ignore intermittent failures in this test!
        let threads = 8
        let numBytes = 256
        let group = MultiThreadedEventLoopGroup(numThreads: threads)

        // Create a server channel.
        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "127.0.0.1", port: 0).wait()

        // We now want to connect to it. To try to slow this stuff down, we're going to use a multiple of the number
        // of event loops.
        for _ in 0..<(threads * 5) {
            let clientChannel = try ClientBootstrap(group: group).connect(to: serverChannel.localAddress!).wait()

            var buffer = clientChannel.allocator.buffer(capacity: numBytes)
            for i in 0..<numBytes {
                buffer.write(integer: UInt8(i % 256))
            }

            try clientChannel.writeAndFlush(NIOAny(buffer)).wait()
        }

        // We should now shut down gracefully.
        try group.syncShutdownGracefully()
    }

    public func testShuttingDownFailsRegistration() throws {
        // This test catches a regression where the selectable event loop would allow a socket registration while
        // it was nominally "shutting down". To do this, we take advantage of the fact that the event loop attempts
        // to cleanly shut down all the channels before it actually closes. We add a custom channel that we can use
        // to wedge the event loop in the "shutting down" state, ensuring that we have plenty of time to attempt the
        // registration.
        class WedgeOpenHandler: ChannelOutboundHandler {
            typealias OutboundIn = Any
            typealias OutboundOut = Any

            var closePromise: EventLoopPromise<Void>? = nil

            func close(ctx: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
                guard self.closePromise == nil else {
                    XCTFail("Attempted to create duplicate close promise")
                    return
                }
                self.closePromise = ctx.eventLoop.newPromise()
                self.closePromise!.futureResult.whenSuccess {
                    ctx.close(mode: mode, promise: promise)
                }
            }
        }

        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            do {
                try group.syncShutdownGracefully()
            } catch EventLoopError.shutdown {
                // Fine, that's expected if the test completed.
            } catch {
                XCTFail("Unexpected error on close: \(error)")
            }
        }
        let loop = group.next() as! SelectableEventLoop

        // We're going to create and register a channel, but not actually attempt to do anything with it.
        let wedgeHandler = WedgeOpenHandler()
        let channel = try SocketChannel(eventLoop: loop, protocolFamily: AF_INET)
        try channel.pipeline.add(handler: wedgeHandler).then {
            channel.register()
        }.wait()

        // Now we're going to start closing the event loop. This should not immediately succeed.
        let loopCloseFut = loop.closeGently()

        // Now we're going to attempt to register a new channel. This should immediately fail.
        let newChannel = try SocketChannel(eventLoop: loop, protocolFamily: AF_INET)

        do {
            try newChannel.register().wait()
            XCTFail("Register did not throw")
        } catch EventLoopError.shutdown {
            // All good
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Confirm that the loop still hasn't closed.
        XCTAssertFalse(loopCloseFut.fulfilled)

        // Now let it close.
        loop.execute {
            wedgeHandler.closePromise!.succeed(result: ())
        }
        XCTAssertNoThrow(try loopCloseFut.wait())
    }

    public func testEventLoopThreads() throws {
        var counter = 0
        let body: ThreadInitializer = { t in
            counter += 1
        }
        let threads: [ThreadInitializer] = [body, body]
        
        let group = MultiThreadedEventLoopGroup(threadInitializers: threads)
       
        XCTAssertEqual(2, counter)
        XCTAssertNoThrow(try group.syncShutdownGracefully())
    }
    
    public func testEventLoopPinned() throws {
        #if os(Linux)
            let body: ThreadInitializer = { t in
                let set = LinuxCPUSet(0)
                t.affinity = set
                XCTAssertEqual(set, t.affinity)
            }
            let threads: [ThreadInitializer] = [fn, body]
        
            let group = MultiThreadedEventLoopGroup(threadInitializers: threads)
        
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        #endif
    }
    
    public func testEventLoopPinnedCPUIdsConstructor() throws {
        #if os(Linux)
            let group = MultiThreadedEventLoopGroup(pinnedCPUIds: [0])
            let eventLoop = group.next()
            let set = try eventLoop.submit {
                return NIO.Thread.current.affinity
            }.wait()

            XCTAssertEqual(LinuxCPUSet(0), set)
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        #endif
    }
}
