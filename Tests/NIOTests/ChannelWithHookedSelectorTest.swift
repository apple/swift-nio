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

@testable import NIO
import XCTest

class HookedSocket: Socket {
    var remainingBytesToRead = 10

    override func ignoreSIGPIPE() throws {}
    override func localAddress() throws -> SocketAddress {
        return try .init(ipAddress: "127.0.0.1", port: 1)
    }
    
    override func remoteAddress() throws -> SocketAddress {
        return try .init(ipAddress: "127.0.0.1", port: 2)
    }

    override func connect(to address: SocketAddress) throws -> Bool {
        print("\(#function) \(address)")
        return true
    }

    override func read(pointer: UnsafeMutableRawBufferPointer) throws -> IOResult<Int> {
        self.remainingBytesToRead -= 1
        if self.remainingBytesToRead > 0 {
            return .processed(1)
        } else {
            return .processed(0)
        }
    }

    override func close() throws {
    }
}

final class ChannelWithHookedSelectorTest: XCTestCase {
    func testFoojj() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1,
                                                selectorFactory: { try HookedSelector() })
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let channel = try! SocketChannel(socket: HookedSocket(descriptor: .max),
                                    eventLoop: group.next() as! SelectableEventLoop)
        var buffer = channel.allocator.buffer(capacity: 10)
        buffer.writeString("xxx")

        XCTAssertNoThrow(try channel.register().wait())
        XCTAssertNoThrow(try channel.connect(to: .init(ipAddress: "1.2.3.4", port: 5)).wait())
        XCTAssertNoThrow(try channel.writeAndFlush(buffer).wait())
    }
}
