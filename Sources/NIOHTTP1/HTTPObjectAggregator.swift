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

/// The parts of a complete HTTP response from the view of the client.
///
/// A full HTTP request is made up of a response header encoded by `.head`
/// and an optional `.body`.
public struct HTTPServerRequestFull {
    public var head: HTTPRequestHead
    public var body: ByteBuffer?

    public init(head: HTTPRequestHead, body: ByteBuffer?) {
        self.head = head
        self.body = body
    }
}

extension HTTPServerRequestFull: Equatable {}

/// The parts of a complete HTTP response from the view of the client.
///
/// Afull HTTP response is made up of a response header encoded by `.head`
/// and an optional `.body`.
public struct HTTPClientResponseFull {
    public var head: HTTPResponseHead
    public var body: ByteBuffer?

    public init(head: HTTPResponseHead, body: ByteBuffer?) {
        self.head = head
        self.body = body
    }
}

extension HTTPClientResponseFull: Equatable {}

public struct HTTPObjectAggregatorError: Error, Equatable {
    private enum Base {
        case frameTooLong
        case connectionClosed
        case endingIgnoredMessage
        case unexpectedMessageHead
        case unexpectedMessageBody
        case unexpectedMessageEnd
    }

    private var base: Base

    private init(base: Base) {
        self.base = base
    }

    public static let frameTooLong = HTTPObjectAggregatorError(base: .frameTooLong)
    public static let connectionClosed = HTTPObjectAggregatorError(base: .connectionClosed)
    public static let endingIgnoredMessage = HTTPObjectAggregatorError(base: .endingIgnoredMessage)
    public static let unexpectedMessageHead = HTTPObjectAggregatorError(base: .unexpectedMessageHead)
    public static let unexpectedMessageBody = HTTPObjectAggregatorError(base: .unexpectedMessageBody)
    public static let unexpectedMessageEnd = HTTPObjectAggregatorError(base: .unexpectedMessageEnd)
}

public struct HTTPObjectAggregatorEvent: Hashable {
    private enum Base {
        case httpExpectationFailed
        case httpContinue
        case httpFrameTooLong
    }

    private var base: Base

    private init(base: Base) {
        self.base = base
    }

    public static let httpExpectationFailed = HTTPObjectAggregatorEvent(base: .httpExpectationFailed)
    public static let httpContinue = HTTPObjectAggregatorEvent(base: .httpContinue)
    public static let httpFrameTooLong = HTTPObjectAggregatorEvent(base: .httpFrameTooLong)
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

    mutating func messageHeadReceived() throws {
        switch self {
        case .idle:
            self = .receiving
        case .ignoringContent, .receiving:
            throw HTTPObjectAggregatorError.unexpectedMessageHead
        case .closed:
            throw HTTPObjectAggregatorError.connectionClosed
        }
    }

    mutating func messageBodyReceived() throws {
        switch self {
        case .receiving:
            ()
        case .ignoringContent:
            throw HTTPObjectAggregatorError.frameTooLong
        case .idle:
            throw HTTPObjectAggregatorError.unexpectedMessageBody
        case .closed:
            throw HTTPObjectAggregatorError.connectionClosed
        }
    }


    mutating func messageEndReceived() throws {
        switch self {
        case .receiving:
            // Got the request end we were waiting for.
            self = .idle
        case .ignoringContent:
            // Expected transition from a state where message contents are getting
            // ignored because the message is too large. Throwing an error prevents
            // the normal control flow from continuing into dispatching the completed
            // invalid message to the next handler.
            self = .idle
            throw HTTPObjectAggregatorError.endingIgnoredMessage
        case .idle:
            throw HTTPObjectAggregatorError.unexpectedMessageEnd
        case .closed:
            throw HTTPObjectAggregatorError.connectionClosed
        }
    }

    mutating func handlingOversizeMessage() throws {
        switch self {
        case .receiving, .idle:
            self = .ignoringContent
        case .ignoringContent:
            // If we are already ignoring content, do not want to proceed to
            // sending entity too large response
            throw HTTPObjectAggregatorError.frameTooLong
        case .closed:
            throw HTTPObjectAggregatorError.connectionClosed
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

    private var fullMessageHead: HTTPRequestHead? = nil
    private var buffer: ByteBuffer! = nil
    private var maxContentLength: Int
    private var closeOnExpectationFailed: Bool
    private var state: AggregatorState
    
    public init(maxContentLength: Int, closeOnExpectationFailed: Bool = false) {
        precondition(maxContentLength >= 0, "maxContentLength must not be negative")
        self.maxContentLength = maxContentLength
        self.closeOnExpectationFailed = closeOnExpectationFailed
        self.state = .idle
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let msg = self.unwrapInboundIn(data)
        var serverResponse: HTTPResponseHead? = nil

        do {
            switch msg {
            case .head(let httpHead):
                try self.state.messageHeadReceived()
                try serverResponse = self.beginAggregation(context: context, request: httpHead, message: msg)
                if serverResponse?.status == .payloadTooLarge {
                    try self.state.handlingOversizeMessage()
                }
            case .body(var content):
                try self.state.messageBodyReceived()
                try serverResponse = self.aggregate(context: context, content: &content, message: msg)
            case .end(let trailingHeaders):
                try self.state.messageEndReceived()
                self.endAggregation(context: context, trailingHeaders: trailingHeaders)
            }
        } catch let error as HTTPObjectAggregatorError {
            context.fireErrorCaught(error)
            // Won't be able to complete those
            self.fullMessageHead = nil
            self.buffer.clear()
        } catch {
            // Ignore other types of errors
        }

        // Generated a server esponse to send back
        if let response = serverResponse {
            context.write(self.wrapOutboundOut(.head(response)), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            if !response.headers.isKeepAlive(version: response.version) {
                context.close(promise: nil)
                self.state.closed()
            }
        }
    }

    private func beginAggregation(context: ChannelHandlerContext, request: HTTPRequestHead, message: InboundIn) throws -> HTTPResponseHead? {
        self.fullMessageHead = request
        if let response = self.generateContinueResponse(context: context, request: request) {
            // Remove `Expect` header from the aggregated message
            self.fullMessageHead?.headers.remove(name: "expect")
            return response
        } else if let contentLength = request.contentLength, contentLength > self.maxContentLength {
            // If client has no `Expect` header, but indicated content length is too large
            try self.state.handlingOversizeMessage()
            return self.handleOversizeMessage(message: message)
        }
        return nil
    }

    private func aggregate(context: ChannelHandlerContext, content: inout ByteBuffer, message: InboundIn) throws -> HTTPResponseHead? {
        if (content.readableBytes > self.maxContentLength - self.buffer.readableBytes) {
            try self.state.handlingOversizeMessage()
            return self.handleOversizeMessage(message: message)
        } else {
            self.buffer.writeBuffer(&content)
            return nil
        }
    }

    private func endAggregation(context: ChannelHandlerContext, trailingHeaders: HTTPHeaders?) {
        if var aggregated = self.fullMessageHead {
            // Remove `Trailer` from existing header fields and append trailer fields to existing header fields
            // See rfc7230 4.1.3 Decoding Chunked
            if let headers = trailingHeaders {
                aggregated.headers.remove(name: "trailer")
                aggregated.headers.add(contentsOf: headers)
            }

            let fullMessage = HTTPServerRequestFull(head: aggregated,
                                                    body: self.buffer.readableBytes > 0 ? self.buffer : nil)
            self.fullMessageHead = nil
            self.buffer.clear()
            context.fireChannelRead(NIOAny(fullMessage))
        }
    }
    
    private func generateContinueResponse(context: ChannelHandlerContext, request: HTTPRequestHead) -> HTTPResponseHead? {
        var maybeResponse: HTTPResponseHead? = nil
        if request.isUnsupportedExpectation {
            // if the request contains an unsupported expectation, we return 417
            context.fireUserInboundEventTriggered(HTTPObjectAggregatorEvent.httpExpectationFailed)
            maybeResponse = HTTPResponseHead(
                version: request.version,
                status: .expectationFailed,
                headers: HTTPHeaders([("content-length", "0")]))
        } else if request.isContinueExpected {
            if let contentLength = request.contentLength, contentLength <= self.maxContentLength {
                context.fireUserInboundEventTriggered(HTTPObjectAggregatorEvent.httpContinue)
                maybeResponse = HTTPResponseHead(
                    version: request.version,
                    status: .continue,
                    headers: HTTPHeaders())
            } else {
                // if the request contains 100-continue but the content-length is too large, we return 413
                context.fireUserInboundEventTriggered(HTTPObjectAggregatorEvent.httpExpectationFailed)
                maybeResponse = HTTPResponseHead(
                    version: request.version,
                    status: .payloadTooLarge,
                    headers: HTTPHeaders([("content-length", "0")]))
            }
        }

        if var response = maybeResponse, self.closeOnExpectationFailed && response.status.clientErrorClass {
            response.headers.add(name: "connection", value: "close")
        }
        return maybeResponse
    }
    
    private func handleOversizeMessage(message: InboundIn) -> HTTPResponseHead {
        var payloadTooLargeHead = HTTPResponseHead(
            version: self.fullMessageHead?.version ?? .init(major: 1, minor: 1),
            status: .payloadTooLarge,
            headers: HTTPHeaders([("content-length", "0")]))

        switch message {
        case .head(let request):
            if request.isContinueExpected || request.isKeepAlive {
                // Message too large, but 'Expect: 100-continue' or keep-alive is on.
                // Send back a 413 and keep the connection open.
                return payloadTooLargeHead
            } else {
                // If keep-alive is off and 'Expect: 100-continue' is missing, no need to leave the connection open.
                // Send back a 413 and close the connection.
                payloadTooLargeHead.headers.add(name: "connection", value: "close")
                return payloadTooLargeHead
            }
        default:
            // The client started to send data already, close because it's impossible to recover.
            // Send back a 413 and close the connection.
            payloadTooLargeHead.headers.add(name: "connection", value: "close")
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

    private var fullMessageHead: HTTPResponseHead? = nil
    private var buffer: ByteBuffer! = nil
    private var maxContentLength: Int
    private var state: AggregatorState

    public init(maxContentLength: Int) {
        precondition(maxContentLength >= 0, "maxContentLength must not be negative")
        self.maxContentLength = maxContentLength
        self.state = .idle
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let msg = self.unwrapInboundIn(data)

        do {
            switch msg {
            case .head(let httpHead):
                try self.state.messageHeadReceived()
                try self.beginAggregation(context: context, response: httpHead)
            case .body(var content):
                try self.state.messageBodyReceived()
                try self.aggregate(context: context, content: &content)
            case .end(let trailingHeaders):
                try self.state.messageEndReceived()
                self.endAggregation(context: context, trailingHeaders: trailingHeaders)
            }
        } catch let error as HTTPObjectAggregatorError {
            context.fireErrorCaught(error)
            // Won't be able to complete those
            self.fullMessageHead = nil
            self.buffer.clear()
        } catch {
            // Ignore other types of errors
        }
    }

    private func beginAggregation(context: ChannelHandlerContext, response: HTTPResponseHead) throws {
        self.fullMessageHead = response
        if let contentLength = response.contentLength, contentLength > self.maxContentLength {
            try self.state.handlingOversizeMessage()
            context.fireUserInboundEventTriggered(HTTPObjectAggregatorEvent.httpFrameTooLong)
            context.fireErrorCaught(HTTPObjectAggregatorError.frameTooLong)
        }
    }

    private func aggregate(context: ChannelHandlerContext, content: inout ByteBuffer) throws {
        if (content.readableBytes > self.maxContentLength - self.buffer.readableBytes) {
            try self.state.handlingOversizeMessage()
            context.fireUserInboundEventTriggered(HTTPObjectAggregatorEvent.httpFrameTooLong)
            context.fireErrorCaught(HTTPObjectAggregatorError.frameTooLong)
        } else {
            self.buffer.writeBuffer(&content)
        }
    }

    private func endAggregation(context: ChannelHandlerContext, trailingHeaders: HTTPHeaders?) {
        if var aggregated = self.fullMessageHead {
            // Remove `Trailer` from existing header fields and append trailer fields to existing header fields
            // See rfc7230 4.1.3 Decoding Chunked
            if let headers = trailingHeaders {
                aggregated.headers.remove(name: "trailer")
                aggregated.headers.add(contentsOf: headers)
            }

            let fullMessage = HTTPClientResponseFull(
                head: aggregated,
                body: self.buffer.readableBytes > 0 ? self.buffer : nil)
            self.fullMessageHead = nil
            self.buffer.clear()
            context.fireChannelRead(NIOAny(fullMessage))
        }
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        self.buffer = context.channel.allocator.buffer(capacity: 0)
    }
}
