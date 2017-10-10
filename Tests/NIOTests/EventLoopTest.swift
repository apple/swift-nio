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
import Foundation
import XCTest
import NIO
import Dispatch
import ConcurrencyHelpers

public class EventLoopTest : XCTestCase {
    
    public func testSchedule() throws {
        let nanos = DispatchTime.now().uptimeNanoseconds
        let amount: TimeAmount = .seconds(1)
        let eventLoopGroup = try MultiThreadedEventLoopGroup(numThreads: 1)
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
        let eventLoopGroup = try MultiThreadedEventLoopGroup(numThreads: 1)
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
        let eventLoopGroup = try MultiThreadedEventLoopGroup(numThreads: 1)
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
}
