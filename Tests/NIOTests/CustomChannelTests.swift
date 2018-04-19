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
import NIOConcurrencyHelpers

struct NotImplementedError: Error { }

struct InvalidTypeError: Error { }

/// A basic ChannelCore that expects write0 to receive a NIOAny containing an Int.
///
/// Everything else either throws or returns a failed future, except for things that cannot,
/// which precondition instead.
private class IntChannelCore: ChannelCore {
    func localAddress0() throws -> SocketAddress {
        throw NotImplementedError()
    }

    func remoteAddress0() throws -> SocketAddress {
        throw NotImplementedError()
    }

    func register0(promise: EventLoopPromise<Void>?) {
        promise?.fail(error: NotImplementedError())
    }

    func registerAlreadyConfigured0(promise: EventLoopPromise<Void>?) {
        promise?.fail(error: NotImplementedError())
    }

    func bind0(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.fail(error: NotImplementedError())
    }

    func connect0(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.fail(error: NotImplementedError())
    }

    func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        _ = self.unwrapData(data, as: Int.self)
        promise?.succeed(result: ())
    }

    func flush0() {
        preconditionFailure("Must not flush")
    }

    func read0() {
        preconditionFailure("Must not ew")
    }

    func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        promise?.fail(error: NotImplementedError())
    }

    func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        promise?.fail(error: NotImplementedError())
    }

    func channelRead0(_ data: NIOAny) {
        preconditionFailure("Must not call channelRead0")
    }

    func errorCaught0(error: Error) {
        preconditionFailure("Must not call errorCaught0")
    }
}

class CustomChannelTests: XCTestCase {
    func testWritingIntToSpecialChannel() throws {
        let loop = EmbeddedEventLoop()
        let intCore = IntChannelCore()
        let writePromise: EventLoopPromise<Void> = loop.newPromise()

        intCore.write0(NIOAny(5), promise: writePromise)
        XCTAssertNoThrow(try writePromise.futureResult.wait())
    }
}
