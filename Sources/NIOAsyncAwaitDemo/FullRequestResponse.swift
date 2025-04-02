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

// THIS FILE IS MOSTLY COPIED FROM swift-nio-extras

import NIOCore
import NIOHTTP1

public final class MakeFullRequestHandler: ChannelOutboundHandler, Sendable {
    public typealias OutboundOut = HTTPClientRequestPart
    public typealias OutboundIn = HTTPRequestHead

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let req = Self.unwrapOutboundIn(data)

        context.write(Self.wrapOutboundOut(.head(req)), promise: nil)
        context.write(Self.wrapOutboundOut(.end(nil)), promise: promise)
    }
}

/// `RequestResponseHandler` receives a `Request` alongside an `EventLoopPromise<Response>` from the `Channel`'s
/// outbound side. It will fulfill the promise with the `Response` once it's received from the `Channel`'s inbound
/// side.
///
/// `RequestResponseHandler` does support pipelining `Request`s and it will send them pipelined further down the
/// `Channel`. Should `RequestResponseHandler` receive an error from the `Channel`, it will fail all promises meant for
/// the outstanding `Response`s and close the `Channel`. All requests enqueued after an error occurred will be immediately
/// failed with the first error the channel received.
///
/// `RequestResponseHandler` requires that the `Response`s arrive on `Channel` in the same order as the `Request`s
/// were submitted.
public final class RequestResponseHandler<Request: Sendable, Response: Sendable>: ChannelDuplexHandler {
    public typealias InboundIn = Response
    public typealias InboundOut = Never
    public typealias OutboundIn = (Request, EventLoopPromise<Response>)
    public typealias OutboundOut = Request

    private enum State {
        case operational
        case error(Error)

        var isOperational: Bool {
            switch self {
            case .operational:
                return true
            case .error:
                return false
            }
        }
    }

    private var state: State = .operational
    private var promiseBuffer: CircularBuffer<EventLoopPromise<Response>>

    /// Create a new `RequestResponseHandler`.
    ///
    /// - Parameters:
    ///    - initialBufferCapacity: `RequestResponseHandler` saves the promises for all outstanding responses in a
    ///          buffer. `initialBufferCapacity` is the initial capacity for this buffer. You usually do not need to set
    ///          this parameter unless you intend to pipeline very deeply and don't want the buffer to resize.
    public init(initialBufferCapacity: Int = 4) {
        self.promiseBuffer = CircularBuffer(initialCapacity: initialBufferCapacity)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        switch self.state {
        case .error:
            // We failed any outstanding promises when we entered the error state and will fail any
            // new promises in write.
            assert(self.promiseBuffer.count == 0)
        case .operational:
            let promiseBuffer = self.promiseBuffer
            self.promiseBuffer.removeAll()
            for promise in promiseBuffer {
                promise.fail(ChannelError.eof)
            }
        }
        context.fireChannelInactive()
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard self.state.isOperational else {
            // we're in an error state, ignore further responses
            assert(self.promiseBuffer.count == 0)
            return
        }

        let response = Self.unwrapInboundIn(data)
        let promise = self.promiseBuffer.removeFirst()

        promise.succeed(response)
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard self.state.isOperational else {
            assert(self.promiseBuffer.count == 0)
            return
        }
        self.state = .error(error)
        let promiseBuffer = self.promiseBuffer
        self.promiseBuffer.removeAll()
        context.close(promise: nil)
        for promise in promiseBuffer {
            promise.fail(error)
        }
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let (request, responsePromise) = Self.unwrapOutboundIn(data)
        switch self.state {
        case .error(let error):
            assert(self.promiseBuffer.count == 0)
            responsePromise.fail(error)
            promise?.fail(error)
        case .operational:
            self.promiseBuffer.append(responsePromise)
            context.write(Self.wrapOutboundOut(request), promise: promise)
        }
    }
}

@available(*, unavailable)
extension RequestResponseHandler: Sendable {}
