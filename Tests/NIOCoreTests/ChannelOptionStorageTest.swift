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

import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import XCTest

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
        cos.append(key: .socketOption(.so_reuseaddr), value: 1)
        cos.append(key: .backlog, value: 2)
        XCTAssertNoThrow(try cos.applyAllChannelOptions(to: optionsCollector).wait())
        XCTAssertEqual(2, optionsCollector.allOptions.count)
    }

    func testSetTwoOptionsOfSameType() throws {
        let options: [(ChannelOptions.Types.SocketOption, SocketOptionValue)] = [
            (.socketOption(.so_reuseaddr), 1),
            (.socketOption(.so_rcvtimeo), 2),
        ]
        var cos = ChannelOptions.Storage()
        let optionsCollector = OptionsCollectingChannel()
        for kv in options {
            cos.append(key: kv.0, value: kv.1)
        }
        XCTAssertNoThrow(try cos.applyAllChannelOptions(to: optionsCollector).wait())
        XCTAssertEqual(2, optionsCollector.allOptions.count)
        XCTAssertEqual(
            options.map { $0.0 },
            optionsCollector.allOptions.map { option in
                option.0 as! ChannelOptions.Types.SocketOption
            }
        )
        XCTAssertEqual(
            options.map { $0.1 },
            optionsCollector.allOptions.map { option in
                option.1 as! SocketOptionValue
            }
        )
    }

    func testSetOneOptionTwice() throws {
        var cos = ChannelOptions.Storage()
        let optionsCollector = OptionsCollectingChannel()
        cos.append(key: .socketOption(.so_reuseaddr), value: 1)
        cos.append(key: .socketOption(.so_reuseaddr), value: 2)
        XCTAssertNoThrow(try cos.applyAllChannelOptions(to: optionsCollector).wait())
        XCTAssertEqual(1, optionsCollector.allOptions.count)
        XCTAssertEqual(
            [.socketOption(.so_reuseaddr)],
            optionsCollector.allOptions.map { option in
                option.0 as! ChannelOptions.Types.SocketOption
            }
        )
        XCTAssertEqual(
            [SocketOptionValue(2)],
            optionsCollector.allOptions.map { option in
                option.1 as! SocketOptionValue
            }
        )
    }

    func testClearingOptions() throws {
        var cos = ChannelOptions.Storage()
        let optionsCollector = OptionsCollectingChannel()
        cos.append(key: .socketOption(.so_reuseaddr), value: 1)
        cos.append(key: .socketOption(.so_reuseaddr), value: 2)
        cos.append(key: .socketOption(.so_keepalive), value: 3)
        cos.append(key: .socketOption(.so_reuseaddr), value: 4)
        cos.append(key: .socketOption(.so_rcvbuf), value: 5)
        cos.append(key: .socketOption(.so_reuseaddr), value: 6)
        cos.remove(key: .socketOption(.so_reuseaddr))
        XCTAssertNoThrow(try cos.applyAllChannelOptions(to: optionsCollector).wait())
        XCTAssertEqual(2, optionsCollector.allOptions.count)
        XCTAssertEqual(
            [
                .socketOption(.so_keepalive),
                .socketOption(.so_rcvbuf),
            ],
            optionsCollector.allOptions.map { option in
                option.0 as! ChannelOptions.Types.SocketOption
            }
        )
        XCTAssertEqual(
            [SocketOptionValue(3), SocketOptionValue(5)],
            optionsCollector.allOptions.map { option in
                option.1 as! SocketOptionValue
            }
        )
    }
}

final class OptionsCollectingChannel: Channel {
    private let _allOptions = NIOLockedValueBox<[(any Sendable, any Sendable)]>([])
    var allOptions: [(any Sendable, any Sendable)] {
        get {
            self._allOptions.withLockedValue { $0 }
        }
        set {
            self._allOptions.withLockedValue { $0 = newValue }
        }
    }

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
        EmbeddedEventLoop()
    }
}
