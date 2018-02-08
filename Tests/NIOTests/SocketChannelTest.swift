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

public class SocketChannelTest : XCTestCase {
    /// Validate that channel options are applied asynchronously.
    public func testAsyncSetOption() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 2)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        // Create two channels with different event loops.
        let channelA = try ServerBootstrap(group: group).bind(to: "127.0.0.1", on: 0).wait()
        let channelB: Channel = try { 
            while true {
                let channel = try ServerBootstrap(group: group).bind(to: "127.0.0.1", on: 0).wait()
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
}
