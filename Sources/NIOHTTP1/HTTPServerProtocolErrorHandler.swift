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
import NIOCore

/// A simple channel handler that catches errors emitted by parsing HTTP requests
/// and sends 400 Bad Request responses.
///
/// This channel handler provides the basic behaviour that the majority of simple HTTP
/// servers want. This handler does not suppress the parser errors: it allows them to
/// continue to pass through the pipeline so that other handlers (e.g. logging ones) can
/// deal with the error.
public final class HTTPServerProtocolErrorHandler: ChannelDuplexHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias InboundOut = HTTPServerRequestPart
    public typealias OutboundIn = HTTPServerResponsePart
    public typealias OutboundOut = HTTPServerResponsePart

    private var hasUnterminatedResponse: Bool = false

    public init() {}

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard error is HTTPParserError else {
            context.fireErrorCaught(error)
            return
        }

        // Any HTTPParserError is automatically fatal, and we don't actually need (or want) to
        // provide that error to the client: we just want to tell it that it screwed up and then
        // let the rest of the pipeline shut the door in its face. However, we can only send an
        // HTTP error response if another response hasn't started yet.
        //
        // A side note here: we cannot block or do any delayed work. ByteToMessageDecoder is going
        // to come along and close the channel right after we return from this function.
        if !self.hasUnterminatedResponse {
            let headers = HTTPHeaders([("Connection", "close"), ("Content-Length", "0")])
            let head = HTTPResponseHead(version: .http1_1, status: .badRequest, headers: headers)
            context.write(self.wrapOutboundOut(.head(head)), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }

        // Now pass the error on in case someone else wants to see it.
        context.fireErrorCaught(error)
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let res = self.unwrapOutboundIn(data)
        switch res {
        case .head(let head) where head.isInformational:
            precondition(!self.hasUnterminatedResponse)
        case .head:
            precondition(!self.hasUnterminatedResponse)
            self.hasUnterminatedResponse = true
        case .body:
            precondition(self.hasUnterminatedResponse)
        case .end:
            precondition(self.hasUnterminatedResponse)
            self.hasUnterminatedResponse = false
        }
        context.write(data, promise: promise)
    }
}
