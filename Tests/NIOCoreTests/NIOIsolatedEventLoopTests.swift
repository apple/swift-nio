//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
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

final class NIOIsolatedEventLoopTests: XCTestCase {
    func withEmbeddedEventLoop(_ body: (EmbeddedEventLoop) throws -> Void) rethrows {
        let loop = EmbeddedEventLoop()
        defer { try! loop.syncShutdownGracefully() }
        try body(loop)
    }

    func testMakeSucceededFuture() throws {
        try self.withEmbeddedEventLoop { loop in
            let future = loop.assumeIsolated().makeSucceededFuture(NotSendable())
            XCTAssertNoThrow(try future.map { _ in }.wait())
        }
    }

    func testMakeFailedFuture() throws {
        try self.withEmbeddedEventLoop { loop in
            let future: EventLoopFuture<NotSendable> = loop.assumeIsolated().makeFailedFuture(
                ChannelError.alreadyClosed
            )
            XCTAssertThrowsError(try future.map { _ in }.wait())
        }
    }

    func testMakeCompletedFuture() throws {
        try self.withEmbeddedEventLoop { loop in
            let result = Result<NotSendable, any Error>.success(NotSendable())
            let future: EventLoopFuture<NotSendable> = loop.assumeIsolated().makeCompletedFuture(result)
            XCTAssertNoThrow(try future.map { _ in }.wait())
        }
    }

    func testMakeCompletedFutureWithResultOfClosure() throws {
        try self.withEmbeddedEventLoop { loop in
            let future = loop.assumeIsolated().makeCompletedFuture { NotSendable() }
            XCTAssertNoThrow(try future.map { _ in }.wait())
        }
    }
}

private struct NotSendable {}

@available(*, unavailable)
extension NotSendable: Sendable {}
