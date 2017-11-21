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


class ChannelLifecycleHandler: ChannelInboundHandler {
    public typealias InboundIn = Any

    public enum ChannelState {
        case unregistered
        case inactive
        case active
    }

    public var currentState: ChannelState
    public var stateHistory: [ChannelState]

    public init() {
        currentState = .unregistered
        stateHistory = [.unregistered]
    }

    public func channelRegistered(ctx: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .unregistered)
        XCTAssertFalse(ctx.channel!.isActive)
        currentState = .inactive
        stateHistory.append(.inactive)
        ctx.fireChannelRegistered()
    }

    public func channelActive(ctx: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .inactive)
        XCTAssertTrue(ctx.channel!.isActive)
        currentState = .active
        stateHistory.append(.active)
        ctx.fireChannelActive()
    }

    public func channelInactive(ctx: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .active)
        XCTAssertFalse(ctx.channel!.isActive)
        currentState = .inactive
        stateHistory.append(.inactive)
        ctx.fireChannelInactive()
    }

    public func channelUnregistered(ctx: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .inactive)
        XCTAssertFalse(ctx.channel!.isActive)
        currentState = .unregistered
        stateHistory.append(.unregistered)
        ctx.fireChannelUnregistered()
    }
}

public class ChannelTests: XCTestCase {
    func testBasicLifecycle() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        var serverAcceptedChannel: Channel? = nil
        let serverLifecycleHandler = ChannelLifecycleHandler()
        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                serverAcceptedChannel = channel
                return channel.pipeline.add(handler: serverLifecycleHandler)
            })).bind(to: "127.0.0.1", on: 0).wait()

        let clientLifecycleHandler = ChannelLifecycleHandler()
        let clientChannel = try ClientBootstrap(group: group)
            .handler(handler: clientLifecycleHandler)
            .connect(to: serverChannel.localAddress!).wait()

        var buffer = clientChannel.allocator.buffer(capacity: 1)
        buffer.write(string: "a")
        try clientChannel.writeAndFlush(data: NIOAny(buffer)).wait()

        // Start shutting stuff down.
        try clientChannel.close().wait()

        // Wait for the close promises. These fire last.
        try EventLoopFuture<Void>.andAll([clientChannel.closeFuture, serverAcceptedChannel!.closeFuture], eventLoop: group.next()).then { _ in
            XCTAssertEqual(clientLifecycleHandler.currentState, .unregistered)
            XCTAssertEqual(serverLifecycleHandler.currentState, .unregistered)
            XCTAssertEqual(clientLifecycleHandler.stateHistory, [.unregistered, .inactive, .active, .inactive, .unregistered])
            XCTAssertEqual(serverLifecycleHandler.stateHistory, [.unregistered, .inactive, .active, .inactive, .unregistered])
        }.wait()
    }

    func testManyManyWrites() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(to: "127.0.0.1", on: 0).wait()

        let clientChannel = try ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait()

        // We're going to try to write loads, and loads, and loads of data. In this case, one more
        // write than the iovecs max.
        for _ in 0...Socket.writevLimit {
            var buffer = clientChannel.allocator.buffer(capacity: 1)
            buffer.write(string: "a")
            clientChannel.write(data: NIOAny(buffer), promise: nil)
        }
        try clientChannel.flush().wait()

        // Start shutting stuff down.
        try clientChannel.close().wait()
    }

    func testWritevLotsOfData() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(to: "127.0.0.1", on: 0).wait()

        let clientChannel = try ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait()

        let bufferSize = 1024 * 1024 * 2
        var buffer = clientChannel.allocator.buffer(capacity: bufferSize)
        for _ in 0..<bufferSize {
            buffer.write(staticString: "a")
        }

        var written = 0
        while written <= Int(INT32_MAX) {
            clientChannel.write(data: NIOAny(buffer), promise: nil)
            written += bufferSize
        }

        do {
            _ = try clientChannel.flush().wait()
        } catch let error {
            XCTFail("Error occured: \(error)")
        }

        // Start shutting stuff down.
        try clientChannel.close().wait()
    }

    func testParentsOfSocketChannels() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        let childChannelPromise: EventLoopPromise<Channel> = group.next().newPromise()
        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                childChannelPromise.succeed(result: channel)
                return channel.eventLoop.newSucceedFuture(result: ())
            })).bind(to: "127.0.0.1", on: 0).wait()

        let clientChannel = try ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait()

        // Check the child channel has a parent, and that that parent is the server channel.
        childChannelPromise.futureResult.whenComplete {
            switch $0 {
            case .success(let chan):
                XCTAssertTrue(chan.parent === serverChannel)
            case .failure(let err):
                XCTFail("Unexpected error \(err)")
            }
        }
        _ = try childChannelPromise.futureResult.wait()

        // Neither the server nor client channels have parents.
        XCTAssertNil(serverChannel.parent)
        XCTAssertNil(clientChannel.parent)

        // Start shutting stuff down.
        try clientChannel.close().wait()
    }
}
