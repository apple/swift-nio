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
import NIO
import Dispatch
import NIOConcurrencyHelpers

public class EventLoopTest : XCTestCase {
    
    public func testSchedule() throws {
        let nanos = DispatchTime.now().uptimeNanoseconds
        let amount: TimeAmount = .seconds(1)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! eventLoopGroup.syncShutdownGracefully()
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
            try! eventLoopGroup.syncShutdownGracefully()
        }

        // First, we create a server and client channel, but don't connect them.
        let serverChannel = try ServerBootstrap(group: eventLoopGroup)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(to: "127.0.0.1", on: 0).wait()
        let clientBootstrap = ClientBootstrap(group: eventLoopGroup)

        // Now, schedule two tasks: one that takes a while, one that doesn't.
        let nanos = DispatchTime.now().uptimeNanoseconds
        let longFuture = eventLoopGroup.next().scheduleTask(in: longAmount) {
            return true
        }.futureResult

        let _ = try eventLoopGroup.next().scheduleTask(in: smallAmount) {
            return true
        }.futureResult.wait()

        // Ok, the short one has happened. Now we should try connecting them. This connect should happen
        // faster than the final task firing.
        let _ = try clientBootstrap.connect(to: serverChannel.localAddress!).wait()
        XCTAssertTrue(DispatchTime.now().uptimeNanoseconds - nanos < longAmount.nanoseconds)

        // Now wait for the long-delayed task.
        let _ = try longFuture.wait()
        // Now we're ok.
        XCTAssertTrue(DispatchTime.now().uptimeNanoseconds - nanos >= longAmount.nanoseconds)
    }
    
    public func testScheduleCancelled() throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! eventLoopGroup.syncShutdownGracefully()
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
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(to: "127.0.0.1", on: 0).wait()

        // We now want to connect to it. To try to slow this stuff down, we're going to use a multiple of the number
        // of event loops.
        for _ in 0..<(threads * 5) {
            let clientChannel = try ClientBootstrap(group: group).connect(to: serverChannel.localAddress!).wait()

            var buffer = clientChannel.allocator.buffer(capacity: numBytes)
            for i in 0..<numBytes {
                buffer.write(integer: UInt8(i % 256))
            }

            try clientChannel.writeAndFlush(data: NIOAny(buffer)).wait()
        }

        // We should now shut down gracefully.
        try group.syncShutdownGracefully()
    }
}
