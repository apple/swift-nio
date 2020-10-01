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

import NIO

/// The parts of a complete HTTP message, either request or response.
///
/// A HTTP message is made up of a request or status line with several headers,
/// encoded by `.head`, zero or more body parts, and optionally some trailers. To
/// indicate that a complete HTTP message has been sent or received, we use `.end`,
/// which may also contain any trailers that make up the mssage.
public struct HTTPMessageFull<HeadT: Equatable, BodyT: Equatable> {
    public var head: HeadT
    public var body: BodyT?
    
    public init(head: HeadT, body: BodyT?) {
        self.head = head
        self.body = body
    }
}

extension HTTPMessageFull: Equatable {}

/// The components of a HTTP request from the view of a HTTP server.
public typealias HTTPServerRequestFull = HTTPMessageFull<HTTPRequestHead, ByteBuffer>

/// The components of a HTTP response from the view of a HTTP server.
public typealias HTTPClientResponseFull = HTTPMessageFull<HTTPResponseHead, ByteBuffer>


public enum HTTPObjectAggregatorError: Error {
    case frameTooLong
    case connectionClosed
    case messageDropped
}

public enum HTTPObjectAggregatorEvents {
    case httpExpectationFailedEvent
    case httpFrameTooLongEvent
}

/// The state of the aggregator  connection.
internal enum AggregatorState {
    /// Nothing is active on this connection, the next message we expect would be a request `.head`.
    case idle

    /// Ill-behaving client may be sending content that is too large
    case ignoringContent

    /// We are receiving and aggregating a request
    case receiving

    /// Connection should be closed
    case closed

    mutating func messageHeadReceived() {
        switch self {
        case .idle:
            self = .receiving
        case .ignoringContent, .receiving, .closed:
            debugOnly {
                preconditionFailure("Received request head in state \(self)")
            }
        }
    }

    mutating func messageEndReceived() {
        switch self {
        case .receiving, .ignoringContent:
            // Got the request end we were waiting for.
            self = .idle
        case .idle, .closed:
            debugOnly {
                preconditionFailure("Received dangling end in state \(self)")
            }
        }
    }

    mutating func handlingOversizeMessage() {
        switch self {
        case .receiving, .idle:
            self = .ignoringContent
        case .ignoringContent, .closed:
            debugOnly {
                preconditionFailure("Received payload too large in state \(self)")
            }
        }
    }

    mutating func closed() {
        self = .closed
    }
}

/// A `ChannelInboundHandler` that handles HTTP chunked `HTTPServerRequestPart`
/// messages by aggregating individual message chunks into a single
/// `HTTPServerRequestFull`. 
///
/// This is achieved by buffering the contents of all received `HTTPServerRequestPart`
/// messages until `HTTPServerRequestPart.end` is received, then assembling the
/// full message and firing a channel read upstream with it. It is useful for when you do not
/// want to deal with chunked messages and just want to receive everything at once, and
/// are happy with the additional memory used and delay handling of the message until
/// everything has been received.
///
/// `HTTPServerRequestAggregator` may end up sending a `HTTPResponseHead`:
/// - Response status `100 Continue` when a `100-continue` expectation is received
///     and the `content-length` doesn't exceed `maxContentLength`.
/// - Response status `417 Expectation Failed` when a `100-continue`
///     expectation is received and the `content-length` exceeds `maxContentLength`.
/// - Response status `413 Request Entity Too Large` when either the
///     `content-length` or the bytes received so far exceed `maxContentLength`.
///
/// `HTTPServerRequestAggregator` may close the connection if it is impossible
/// to recover:
/// - If `content-length` is too large and no `100-continue` expectation is received
///     and `keep-alive` is off.
/// - If the bytes received exceed `maxContentLength` and the client didn't signal
///     `content-length`
public final class HTTPServerRequestAggregator: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias InboundOut = HTTPServerRequestFull

    // Aggregator may generate responses of its own
    public typealias OutboundOut = HTTPServerResponsePart

    // TODO: could hold onto the ByteBuffers read from the channel instead of creating a single new one?
    private var buffer: ByteBuffer! = nil
    private var maxContentLength: Int
    private var closeOnExpectationFailed: Bool
    private var state: AggregatorState
    
    private var fullMessageHead: HTTPRequestHead! = nil
    
    public init(maxContentLength: Int, closeOnExpectationFailed: Bool = false) {
        if maxContentLength < 0 {
            preconditionFailure("maxContentLength must not be negative")
        }
        self.maxContentLength = maxContentLength
        self.closeOnExpectationFailed = closeOnExpectationFailed
        self.state = .idle
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard self.state != .closed else {
            context.fireErrorCaught(HTTPObjectAggregatorError.connectionClosed)
            return
        }

        let msg = self.unwrapInboundIn(data)
        var serverResponse: HTTPResponseHead? = nil

        switch msg {
        case .head(let httpHead):
            self.state.messageHeadReceived()
            serverResponse = self.beginAggregation(context: context, request: httpHead, message: msg)
        case .body(var content):
            if self.state == .receiving {
                serverResponse = self.aggregate(context: context, content: &content, message: msg)
            }
        case .end(let trailingHeaders):
            self.endAggregation(context: context, trailingHeaders: trailingHeaders)
            self.state.messageEndReceived()
        }

        // Generated a serverr esponse to send back
        if let response = serverResponse {
            context.write(self.wrapOutboundOut(.head(response)), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }

        if self.state == .closed {
            context.close(promise: nil)
        }
    }

    func beginAggregation(context: ChannelHandlerContext, request: HTTPRequestHead, message: InboundIn) -> HTTPResponseHead? {
        self.fullMessageHead = request
        if let response = self.generateContinueResponse(context: context, request: request) {
            if self.shouldCloseAfterContinueResponse(response: response) {
                self.state.closed()
            } else {
                // Won't close the connection, but handling an oversized message
                self.state.handlingOversizeMessage()
                // Remove `Expect` header from the aggregated message
                self.fullMessageHead?.headers.remove(name: "expect")
            }
            return response
        } else if request.hasContentLength && request.contentLength! > self.maxContentLength {
            // If client has no `Expect` header, but indicated content length is too large
            return self.handleOversizeMessage(message: message)
        }
        return nil
    }

    func aggregate(context: ChannelHandlerContext, content: inout ByteBuffer, message: InboundIn) -> HTTPResponseHead? {
        if (content.readableBytes > self.maxContentLength - self.buffer.readableBytes) {
            self.buffer.clear()  // Will not pass the aggregated message up anyway
            return self.handleOversizeMessage(message: message)
        } else {
            self.buffer.writeBuffer(&content)
        }
        return nil
    }

    func endAggregation(context: ChannelHandlerContext, trailingHeaders: HTTPHeaders?) {
        if self.state != .ignoringContent, var aggregated = self.fullMessageHead {
            // Remove `Trailer` from existing header fields and append trailer fields to existing header fields
            // See rfc7230 4.1.3 Decoding Chunked
            if let headers = trailingHeaders {
                aggregated.headers.remove(name: "trailer")
                aggregated.headers.add(contentsOf: headers)
            }

            // Set the 'Content-Length' header. If one isn't already set.
            // This is important as HEAD responses will use a 'Content-Length' header which
            // does not match the actual body, but the number of bytes that would be
            // transmitted if a GET would have been used.
            //
            // See rfc2616 14.13 Content-Length

            if !aggregated.hasContentLength && self.buffer.readableBytes > 0 {
                aggregated.headers.replaceOrAdd(
                    name: "content-length",
                    value: String(self.buffer.readableBytes))
            }

            context.fireChannelRead(NIOAny(HTTPServerRequestFull(
                                            head: aggregated,
                                            body: self.buffer.readableBytes > 0 ? self.buffer : nil)))
        }
        self.fullMessageHead = nil
        self.buffer.clear()
    }
    
    func generateContinueResponse(context: ChannelHandlerContext, request: HTTPRequestHead) -> HTTPResponseHead? {
        if request.isUnsupportedExpectation {
            // if the request contains an unsupported expectation, we return 417
            context.fireUserInboundEventTriggered(HTTPObjectAggregatorEvents.httpExpectationFailedEvent)
            return HTTPResponseHead(
                version: .init(major: 1, minor: 1),
                status: .expectationFailed,
                headers: HTTPHeaders([("Content-Length", "0")]))
        } else if request.isContinueExpected {
            if !request.hasContentLength || request.contentLength! <= self.maxContentLength {
                return HTTPResponseHead(
                    version: .init(major: 1, minor: 1),
                    status: .continue,
                    headers: HTTPHeaders())
            } else {
                // if the request contains 100-continue but the content-length is too large, we return 413
                context.fireUserInboundEventTriggered(HTTPObjectAggregatorEvents.httpExpectationFailedEvent)
                return HTTPResponseHead(
                    version: .init(major: 1, minor: 1),
                    status: .payloadTooLarge,
                    headers: HTTPHeaders([("Content-Length", "0")]))
            }
        }
        return nil
    }
    
    func shouldCloseAfterContinueResponse(response: HTTPResponseHead) -> Bool {
        return self.closeOnExpectationFailed && response.status.clientErrorClass
    }
    
    func handleOversizeMessage(message: InboundIn) -> HTTPResponseHead {
        var payloadTooLargeHead = HTTPResponseHead(
            version: self.fullMessageHead.version,
            status: .payloadTooLarge,
            headers: HTTPHeaders([("Content-Length", "0")]))

        self.state.handlingOversizeMessage()

        switch message {
        case .head(let request):
            if request.isContinueExpected || request.isKeepAlive {
                // Message too large, but 'Expect: 100-continue' or keep-alive is on.
                // Send back a 413 and keep the connection open.
                return payloadTooLargeHead
            } else {
                // If keep-alive is off and 'Expect: 100-continue' is missing, no need to leave the connection open.
                // Send back a 413 and close the connection.
                payloadTooLargeHead.headers.replaceOrAdd(name: "connection", value: "close")
                self.state.closed()
                return payloadTooLargeHead
            }
        default:
            // The client started to send data already, close because it's impossible to recover.
            // Send back a 413 and close the connection.
            payloadTooLargeHead.headers.replaceOrAdd(name: "connection", value: "close")
            self.state.closed()
            return payloadTooLargeHead
        }
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        self.buffer = context.channel.allocator.buffer(capacity: 0)
    }
}

/// A `ChannelInboundHandler` that handles HTTP chunked `HTTPClientResponsePart`
/// messages by aggregating individual message chunks into a single
/// `HTTPClientResponseFull`.
///
/// This is achieved by buffering the contents of all received `HTTPClientResponsePart`
/// messages until `HTTPClientResponsePart.end` is received, then assembling the
/// full message and firing a channel read upstream with it. Useful when you do not
/// want to deal with chunked messages and just want to receive everything at once, and
/// are happy with the additional memory used and delay handling of the message until
/// everything has been received.
///
/// If `HTTPClientResponseAggregator` encounters a message larger than
/// `maxContentLength`, it discards the aggregated contents until the next
/// `HTTPClientResponsePart.end` and signals that via
/// `fireUserInboundEventTriggered`.
public final class HTTPClientResponseAggregator: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPClientResponsePart
    public typealias InboundOut = HTTPClientResponseFull

    // TODO: could hold onto the ByteBuffers read from the channel instead of creating a single new one?
    private var buffer: ByteBuffer! = nil
    private var maxContentLength: Int
    private var state: AggregatorState

    private var fullMessageHead: HTTPResponseHead! = nil

    public init(maxContentLength: Int) {
        if maxContentLength < 0 {
            preconditionFailure("maxContentLength must not be negative")
        }
        self.maxContentLength = maxContentLength
        self.state = .idle
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let msg = self.unwrapInboundIn(data)

        switch msg {
        case .head(let httpHead):
            self.state.messageHeadReceived()
            self.beginAggregation(context: context, request: httpHead)
        case .body(var content):
            if self.state == .receiving {
                self.aggregate(context: context, content: &content)
            }
        case .end(let trailingHeaders):
            self.endAggregation(context: context, trailingHeaders: trailingHeaders)
            self.state.messageEndReceived()
        }
    }

    func beginAggregation(context: ChannelHandlerContext, request: HTTPResponseHead) {
        self.fullMessageHead = request
        if request.hasContentLength && request.contentLength! > self.maxContentLength {
            // If client has no `Expect` header, but indicated content length is too large
            self.state.handlingOversizeMessage()
            context.fireUserInboundEventTriggered(HTTPObjectAggregatorEvents.httpFrameTooLongEvent)
        }
    }

    func aggregate(context: ChannelHandlerContext, content: inout ByteBuffer) {
        if (content.readableBytes > self.maxContentLength - self.buffer.readableBytes) {
            self.state.handlingOversizeMessage()
            context.fireUserInboundEventTriggered(HTTPObjectAggregatorEvents.httpFrameTooLongEvent)
            self.buffer.clear()
        } else {
            self.buffer.writeBuffer(&content)
        }
    }

    func endAggregation(context: ChannelHandlerContext, trailingHeaders: HTTPHeaders?) {
        if self.state != .ignoringContent, var aggregated = self.fullMessageHead {
            // Remove `Trailer` from existing header fields and append trailer fields to existing header fields
            // See rfc7230 4.1.3 Decoding Chunked
            if let headers = trailingHeaders {
                aggregated.headers.remove(name: "trailer")
                aggregated.headers.add(contentsOf: headers)
            }

            if !aggregated.hasContentLength && self.buffer.readableBytes > 0 {
                aggregated.headers.replaceOrAdd(
                    name: "content-length",
                    value: String(self.buffer.readableBytes))
            }

            context.fireChannelRead(NIOAny(HTTPClientResponseFull(
                                            head: aggregated,
                                            body: self.buffer.readableBytes > 0 ? self.buffer : nil)))
        }
        self.fullMessageHead = nil
        self.buffer.clear()
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        self.buffer = context.channel.allocator.buffer(capacity: 0)
    }
}
