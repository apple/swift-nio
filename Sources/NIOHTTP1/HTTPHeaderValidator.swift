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

/// A ChannelHandler to validate that outbound request headers are spec-compliant.
///
/// The HTTP RFCs constrain the bytes that are validly present within a HTTP/1.1 header block.
/// ``NIOHTTPRequestHeadersValidator`` polices this constraint and ensures that only valid header blocks
/// are emitted on the network. If a header block is invalid, then ``NIOHTTPRequestHeadersValidator``
/// will send a ``HTTPParserError/invalidHeaderToken``.
///
/// ``NIOHTTPRequestHeadersValidator`` will also valid that the HTTP trailers are within specification,
/// if they are present.
public final class NIOHTTPRequestHeadersValidator: ChannelOutboundHandler, RemovableChannelHandler {
    public typealias OutboundIn = HTTPClientRequestPart
    public typealias OutboundOut = HTTPClientRequestPart

    public init() {}

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch NIOHTTPRequestHeadersValidator.unwrapOutboundIn(data) {
        case .head(let head):
            guard head.headers.areValidToSend else {
                promise?.fail(HTTPParserError.invalidHeaderToken)
                context.fireErrorCaught(HTTPParserError.invalidHeaderToken)
                return
            }
        case .body, .end(.none):
            ()
        case .end(.some(let trailers)):
            guard trailers.areValidToSend else {
                promise?.fail(HTTPParserError.invalidHeaderToken)
                context.fireErrorCaught(HTTPParserError.invalidHeaderToken)
                return
            }
        }

        context.write(data, promise: promise)
    }
}

/// A ChannelHandler to validate that outbound response headers are spec-compliant.
///
/// The HTTP RFCs constrain the bytes that are validly present within a HTTP/1.1 header block.
/// ``NIOHTTPResponseHeadersValidator`` polices this constraint and ensures that only valid header blocks
/// are emitted on the network. If a header block is invalid, then ``NIOHTTPResponseHeadersValidator``
/// will send a ``HTTPParserError/invalidHeaderToken``.
///
/// ``NIOHTTPResponseHeadersValidator`` will also valid that the HTTP trailers are within specification,
/// if they are present.
public final class NIOHTTPResponseHeadersValidator: ChannelOutboundHandler, RemovableChannelHandler {
    public typealias OutboundIn = HTTPServerResponsePart
    public typealias OutboundOut = HTTPServerResponsePart

    private enum State {
        /// Validating response parts.
        case validating
        /// Dropping all response parts. This is a terminal state.
        case dropping
    }

    private var state: State

    public init() {
        self.state = .validating
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch (NIOHTTPResponseHeadersValidator.unwrapOutboundIn(data), self.state) {
        case (.head(let head), .validating):
            if head.headers.areValidToSend {
                context.write(data, promise: promise)
            } else {
                self.state = .dropping
                promise?.fail(HTTPParserError.invalidHeaderToken)
                context.fireErrorCaught(HTTPParserError.invalidHeaderToken)
            }

        case (.body, .validating):
            context.write(data, promise: promise)

        case (.end(let trailers), .validating):
            // No trailers are always valid trailers.
            if trailers?.areValidToSend ?? true {
                context.write(data, promise: promise)
            } else {
                self.state = .dropping
                promise?.fail(HTTPParserError.invalidHeaderToken)
                context.fireErrorCaught(HTTPParserError.invalidHeaderToken)
            }

        case (.head, .dropping), (.body, .dropping), (.end, .dropping):
            promise?.fail(HTTPParserError.invalidHeaderToken)
        }
    }
}

@available(*, unavailable)
extension NIOHTTPRequestHeadersValidator: Sendable {}

@available(*, unavailable)
extension NIOHTTPResponseHeadersValidator: Sendable {}
