//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore
import NIOEmbedded
import XCTest

final class AsyncChannelTests: XCTestCase {
    func testAsyncChannelBasicFunctionality() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let wrapped = try await NIOAsyncChannel(wrapping: channel, inboundIn: String.self, outboundOut: Never.self)

            var iterator = wrapped.inboundStream.makeAsyncIterator()
            try await channel.writeInbound("hello")
            let firstRead = try await iterator.next()
            XCTAssertEqual(firstRead, "hello")

            try await channel.writeInbound("world")
            let secondRead = try await iterator.next()
            XCTAssertEqual(secondRead, "world")

            try await channel.testingEventLoop.executeInContext {
                channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
            }

            let thirdRead = try await iterator.next()
            XCTAssertNil(thirdRead)

            try await channel.close()
        }
    }
}


