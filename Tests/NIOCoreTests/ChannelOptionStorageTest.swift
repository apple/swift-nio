//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
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
import NIOEmbedded

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
        cos.append(key: ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        cos.append(key: ChannelOptions.backlog, value: 2)
        XCTAssertNoThrow(try cos.applyAllChannelOptions(to: optionsCollector).wait())
        XCTAssertEqual(2, optionsCollector.allOptions.count)
    }

    func testSetTwoOptionsOfSameType() throws {
        let options: [(ChannelOptions.Types.SocketOption, SocketOptionValue)] = [(ChannelOptions.socketOption(.so_reuseaddr), 1),
                                                            (ChannelOptions.socketOption(.so_rcvtimeo), 2)]
        var cos = ChannelOptions.Storage()
        let optionsCollector = OptionsCollectingChannel()
        for kv in options {
            cos.append(key: kv.0, value: kv.1)
        }
        XCTAssertNoThrow(try cos.applyAllChannelOptions(to: optionsCollector).wait())
        XCTAssertEqual(2, optionsCollector.allOptions.count)
        XCTAssertEqual(options.map { $0.0 },
                       optionsCollector.allOptions.map { option in
                           return option.0 as! ChannelOptions.Types.SocketOption
                       })
        XCTAssertEqual(options.map { $0.1 },
                       optionsCollector.allOptions.map { option in
                           return option.1 as! SocketOptionValue
                       })
    }

    func testSetOneOptionTwice() throws {
        var cos = ChannelOptions.Storage()
        let optionsCollector = OptionsCollectingChannel()
        cos.append(key: ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        cos.append(key: ChannelOptions.socketOption(.so_reuseaddr), value: 2)
        XCTAssertNoThrow(try cos.applyAllChannelOptions(to: optionsCollector).wait())
        XCTAssertEqual(1, optionsCollector.allOptions.count)
        XCTAssertEqual([ChannelOptions.socketOption(.so_reuseaddr)],
                       optionsCollector.allOptions.map { option in
                           return option.0 as! ChannelOptions.Types.SocketOption
                       })
        XCTAssertEqual([SocketOptionValue(2)],
                       optionsCollector.allOptions.map { option in
                           return option.1 as! SocketOptionValue
                       })
    }

    func testClearingOptions() throws {
        var cos = ChannelOptions.Storage()
        let optionsCollector = OptionsCollectingChannel()
        cos.append(key: ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        cos.append(key: ChannelOptions.socketOption(.so_reuseaddr), value: 2)
        cos.append(key: ChannelOptions.socketOption(.so_keepalive), value: 3)
        cos.append(key: ChannelOptions.socketOption(.so_reuseaddr), value: 4)
        cos.append(key: ChannelOptions.socketOption(.so_rcvbuf), value: 5)
        cos.append(key: ChannelOptions.socketOption(.so_reuseaddr), value: 6)
        cos.remove(key: ChannelOptions.socketOption(.so_reuseaddr))
        XCTAssertNoThrow(try cos.applyAllChannelOptions(to: optionsCollector).wait())
        XCTAssertEqual(2, optionsCollector.allOptions.count)
        XCTAssertEqual([ChannelOptions.socketOption(.so_keepalive),
                        ChannelOptions.socketOption(.so_rcvbuf)],
                       optionsCollector.allOptions.map { option in
                           return option.0 as! ChannelOptions.Types.SocketOption
                       })
        XCTAssertEqual([SocketOptionValue(3), SocketOptionValue(5)],
                       optionsCollector.allOptions.map { option in
                           return option.1 as! SocketOptionValue
                       })
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
