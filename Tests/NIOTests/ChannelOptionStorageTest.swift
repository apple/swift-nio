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

class ChannelOptionStorageTest: XCTestCase {
    func testWeStartWithNoOptions() throws {
        let cos = ChannelOptions.Storage()
        let optionsCollector = OptionsCollectingChannel()
        XCTAssertNoThrow(try cos.applyAllChannelOptions(to: optionsCollector).wait())
        XCTAssertEqual(0, optionsCollector.allOptions.count)
    }

    func testSetTwoOptionsOfDifferentType() throws {
        var cos = ChannelOptions.Storage()
        let optionsCollector = OptionsCollectingChannel()
        cos.append(key: ChannelOptions.Socket.allowLocalAddressReuse, value: 1)
        cos.append(key: ChannelOptions.backlog, value: 2)
        XCTAssertNoThrow(try cos.applyAllChannelOptions(to: optionsCollector).wait())
        XCTAssertEqual(2, optionsCollector.allOptions.count)
    }

    func testSetTwoOptionsOfSameType() throws {
        let options: [(ChannelOptions.Types.SocketOption, SocketOptionValue)] = [
            (ChannelOptions.Socket.allowLocalAddressReuse, 1),
            (ChannelOptions.Socket.allowLocalPortReuse, 2)
        ]
        var cos = ChannelOptions.Storage()
        let optionsCollector = OptionsCollectingChannel()
        for kv in options {
            cos.append(key: kv.0, value: kv.1)
        }
        XCTAssertNoThrow(try cos.applyAllChannelOptions(to: optionsCollector).wait())
        XCTAssertEqual(2, optionsCollector.allOptions.count)
        XCTAssertEqual(options.map { $0.0 },
                       (optionsCollector.allOptions as! [(ChannelOptions.Types.SocketOption, SocketOptionValue)]).map { $0.0 })
        XCTAssertEqual(options.map { $0.1 },
                       (optionsCollector.allOptions as! [(ChannelOptions.Types.SocketOption, SocketOptionValue)]).map { $0.1 })
    }

    func testSetOneOptionTwice() throws {
        var cos = ChannelOptions.Storage()
        let optionsCollector = OptionsCollectingChannel()
        cos.append(key: ChannelOptions.Socket.allowLocalAddressReuse, value: 1)
        cos.append(key: ChannelOptions.Socket.allowLocalAddressReuse, value: 2)
        XCTAssertNoThrow(try cos.applyAllChannelOptions(to: optionsCollector).wait())
        XCTAssertEqual(1, optionsCollector.allOptions.count)
        XCTAssertEqual([ChannelOptions.Socket.allowLocalAddressReuse],
                       (optionsCollector.allOptions as! [(ChannelOptions.Types.SocketOption, SocketOptionValue)]).map { $0.0 })
        XCTAssertEqual([SocketOptionValue(2)],
                       (optionsCollector.allOptions as! [(ChannelOptions.Types.SocketOption, SocketOptionValue)]).map { $0.1 })
    }
    
    func testConvenienceSocketOptions() {
        let enableDebugging = ChannelOptions.Socket.enableDebugging
        XCTAssertEqual(enableDebugging.level, SOL_SOCKET)
        XCTAssertEqual(enableDebugging.name, SO_DEBUG)
        
        let allowLocalAddressReuse = ChannelOptions.Socket.allowLocalAddressReuse
        XCTAssertEqual(allowLocalAddressReuse.level, SOL_SOCKET)
        XCTAssertEqual(allowLocalAddressReuse.name, SO_REUSEADDR)
        
        let keepAlive = ChannelOptions.Socket.keepAlive
        XCTAssertEqual(keepAlive.level, SOL_SOCKET)
        XCTAssertEqual(keepAlive.name, SO_KEEPALIVE)
        
        let enableBroadcastMessages = ChannelOptions.Socket.enableBroadcastMessages
        XCTAssertEqual(enableBroadcastMessages.level, SOL_SOCKET)
        XCTAssertEqual(enableBroadcastMessages.name, SO_BROADCAST)
        
        let useLoopback = ChannelOptions.Socket.useLoopback
        XCTAssertEqual(useLoopback.level, SOL_SOCKET)
        XCTAssertEqual(useLoopback.name, SO_USELOOPBACK)
        
        let allowLocalPortReuse = ChannelOptions.Socket.allowLocalPortReuse
        XCTAssertEqual(allowLocalPortReuse.level, SOL_SOCKET)
        XCTAssertEqual(allowLocalPortReuse.name, SO_REUSEPORT)
    }
    
}

class OptionsCollectingChannel: Channel {
    var allOptions: [(Any, Any)] = []

    var allocator: ByteBufferAllocator { fatalError() }

    var closeFuture: EventLoopFuture<Void> { fatalError() }

    var pipeline: ChannelPipeline { fatalError() }

    var localAddress: SocketAddress? { fatalError() }

    var remoteAddress: SocketAddress? { fatalError() }

    var parent: Channel? { fatalError() }

    func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> EventLoopFuture<Void> {
        self.allOptions.append((option, value))
        return self.eventLoop.makeSucceededFuture(())
    }

    func getOption<Option: ChannelOption>(_ option: Option) -> EventLoopFuture<Option.Value> {
        fatalError()
    }

    var isWritable: Bool { fatalError() }

    var isActive: Bool { fatalError() }

    var _channelCore: ChannelCore { fatalError() }

    var eventLoop: EventLoop {
        return EmbeddedEventLoop()
    }
}
