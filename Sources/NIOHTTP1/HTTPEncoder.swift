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

import NIO

private func writeChunk(wrapOutboundOut: (IOData) -> NIOAny, ctx: ChannelHandlerContext, isChunked: Bool, chunk: IOData, promise: EventLoopPromise<Void>?) {
    let (mW1, mW2, mW3): (EventLoopPromise<Void>?, EventLoopPromise<Void>?, EventLoopPromise<Void>?)

    switch (isChunked, promise) {
    case (true, .some(let p)):
        /* chunked encoding and the user's interested: we need three promises and need to cascade into the users promise */
        let (w1, w2, w3) = (ctx.eventLoop.newPromise() as EventLoopPromise<Void>, ctx.eventLoop.newPromise() as EventLoopPromise<Void>, ctx.eventLoop.newPromise() as EventLoopPromise<Void>)
        w1.futureResult.and(w2.futureResult).and(w3.futureResult).map { (_: ((((), ()), ()))) in }.cascade(promise: p)
        (mW1, mW2, mW3) = (w1, w2, w3)
    case (false, .some(let p)):
        /* not chunked, so just use the user's promise for the actual data */
        (mW1, mW2, mW3) = (nil, p, nil)
    case (_, .none):
        /* user isn't interested, let's not bother even allocating promises */
        (mW1, mW2, mW3) = (nil, nil, nil)
    }

    let readableBytes = chunk.readableBytes

    /* we don't want to copy the chunk unnecessarily and therefore call write an annoyingly large number of times */
    if isChunked {
        var buffer = ctx.channel.allocator.buffer(capacity: 32)
        let len = String(readableBytes, radix: 16)
        buffer.write(string: len)
        buffer.write(staticString: "\r\n")
        ctx.write(wrapOutboundOut(.byteBuffer(buffer)), promise: mW1)

        ctx.write(wrapOutboundOut(chunk), promise: mW2)

        // Just move the buffers readerIndex to only make the \r\n readable and depend on COW semantics.
        buffer.moveReaderIndex(forwardBy: buffer.readableBytes - 2)
        ctx.write(wrapOutboundOut(.byteBuffer(buffer)), promise: mW3)
    } else {
        ctx.write(wrapOutboundOut(chunk), promise: mW2)
    }
}

private func writeTrailers(wrapOutboundOut: (IOData) -> NIOAny, ctx: ChannelHandlerContext, isChunked: Bool, trailers: HTTPHeaders?, promise: EventLoopPromise<Void>?) {
    switch (isChunked, promise) {
    case (true, let p):
        var buffer: ByteBuffer
        if let trailers = trailers {
            buffer = ctx.channel.allocator.buffer(capacity: 256)
            buffer.write(staticString: "0\r\n")
            buffer.write(headers: trailers) // Includes trailing CRLF.
        } else {
            buffer = ctx.channel.allocator.buffer(capacity: 8)
            buffer.write(staticString: "0\r\n\r\n")
        }
        ctx.write(wrapOutboundOut(.byteBuffer(buffer)), promise: p)
    case (false, .some(let p)):
        // Not chunked so we have nothing to write. However, we don't want to satisfy this promise out-of-order
        // so we issue a zero-length write down the chain.
        let buf = ctx.channel.allocator.buffer(capacity: 0)
        ctx.write(wrapOutboundOut(.byteBuffer(buf)), promise: p)
    case (false, .none):
        break
    }
}

private func writeHead(wrapOutboundOut: (IOData) -> NIOAny, writeStartLine: (inout ByteBuffer) -> Void, ctx: ChannelHandlerContext, headers: HTTPHeaders, promise: EventLoopPromise<Void>?) {

    var buffer = ctx.channel.allocator.buffer(capacity: 256)
    writeStartLine(&buffer)
    buffer.write(headers: headers)
    ctx.write(wrapOutboundOut(.byteBuffer(buffer)), promise: promise)
}

/// The type of framing that is used to mark the end of the body.
private enum BodyFraming {
    case chunked
    case contentLength
    case neither
}

/// Adjusts the response/request headers to ensure that the response/request will be well-framed.
///
/// This method strips Content-Length and Transfer-Encoding headers from responses/requests that must
/// not have a body. It also adds Transfer-Encoding headers to responses/requests that do have bodies
/// but do not have any other transport headers when using HTTP/1.1. This ensures that we can
/// always safely reuse a connection.
///
/// Note that for HTTP/1.0 if there is no Content-Length then the response should be followed
/// by connection close. We require that the user send that connection close: we don't do it.
private func sanitizeTransportHeaders(hasBody: HTTPMethod.HasBody, headers: inout HTTPHeaders, version: HTTPVersion) -> BodyFraming {
    switch hasBody {
    case .no:
        headers.remove(name: "content-length")
        headers.remove(name: "transfer-encoding")
        return .neither
    case .yes:
        if headers.contains(name: "content-length") {
            return .contentLength
        }
        if version.major == 1 && version.minor >= 1 {
            headers.replaceOrAdd(name: "transfer-encoding", value: "chunked")
            return .chunked
        } else {
            return .neither
        }
    case .unlikely:
        if headers.contains(name: "content-length") {
            return .contentLength
        }
        if version.major == 1 && version.minor >= 1 {
            return headers["transfer-encoding"].first == "chunked" ? .chunked : .neither
        }
        return .neither
    }
}

/// A `ChannelOutboundHandler` that can serialize HTTP requests.
///
/// This channel handler is used to translate messages from a series of
/// `HTTPClientRequestPart` into the HTTP/1.1 wire format.
public final class HTTPRequestEncoder: ChannelOutboundHandler {
    public typealias OutboundIn = HTTPClientRequestPart
    public typealias OutboundOut = IOData

    private var isChunked = false

    public init () { }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch self.unwrapOutboundIn(data) {
        case .head(var request):

            self.isChunked = sanitizeTransportHeaders(hasBody: request.method.hasRequestBody, headers: &request.headers, version: request.version) == .chunked

            writeHead(wrapOutboundOut: self.wrapOutboundOut, writeStartLine: { buffer in
                buffer.write(request: request)
            }, ctx: ctx, headers: request.headers, promise: promise)
        case .body(let bodyPart):
            writeChunk(wrapOutboundOut: self.wrapOutboundOut, ctx: ctx, isChunked: self.isChunked, chunk: bodyPart, promise: promise)
        case .end(let trailers):
            writeTrailers(wrapOutboundOut: self.wrapOutboundOut, ctx: ctx, isChunked: self.isChunked, trailers: trailers, promise: promise)
        }
    }
}

/// A `ChannelOutboundHandler` that can serialize HTTP responses.
///
/// This channel handler is used to translate messages from a series of
/// `HTTPServerResponsePart` into the HTTP/1.1 wire format.
public final class HTTPResponseEncoder: ChannelOutboundHandler {
    public typealias OutboundIn = HTTPServerResponsePart
    public typealias OutboundOut = IOData

    private var isChunked = false

    public init () { }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch self.unwrapOutboundIn(data) {
        case .head(var response):

            self.isChunked = sanitizeTransportHeaders(hasBody: response.status.mayHaveResponseBody ? .yes : .no, headers: &response.headers, version: response.version) == .chunked

            writeHead(wrapOutboundOut: self.wrapOutboundOut, writeStartLine: { buffer in
                buffer.write(response: response)
            }, ctx: ctx, headers: response.headers, promise: promise)
        case .body(let bodyPart):
            writeChunk(wrapOutboundOut: self.wrapOutboundOut, ctx: ctx, isChunked: self.isChunked, chunk: bodyPart, promise: promise)
        case .end(let trailers):
            writeTrailers(wrapOutboundOut: self.wrapOutboundOut, ctx: ctx, isChunked: self.isChunked, trailers: trailers, promise: promise)
        }
    }
}

private extension ByteBuffer {
    private mutating func write(status: HTTPResponseStatus) {
        self.write(string: String(status.code))
        self.writeWhitespace()
        self.write(string: status.reasonPhrase)
    }

    mutating func write(response: HTTPResponseHead) {
        switch (response.version.major, response.version.minor, response.status) {
        // Optimization for HTTP/1.0
        case (1, 0, .custom(_, _)):
            self.write(staticString: "HTTP/1.0 ")
            self.write(status: response.status)
            self.write(staticString: "\r\n")
        case (1, 0, .continue):
            self.write(staticString: "HTTP/1.0 100 Continue\r\n")
        case (1, 0, .switchingProtocols):
            self.write(staticString: "HTTP/1.0 101 Switching Protocols\r\n")
        case (1, 0, .processing):
            self.write(staticString: "HTTP/1.0 102 Processing\r\n")
        case (1, 0, .ok):
            self.write(staticString: "HTTP/1.0 200 OK\r\n")
        case (1, 0, .created):
            self.write(staticString: "HTTP/1.0 201 Created\r\n")
        case (1, 0, .accepted):
            self.write(staticString: "HTTP/1.0 202 Accepted\r\n")
        case (1, 0, .nonAuthoritativeInformation):
            self.write(staticString: "HTTP/1.0 203 Non-Authoritative Information\r\n")
        case (1, 0, .noContent):
            self.write(staticString: "HTTP/1.0 204 No Content\r\n")
        case (1, 0, .resetContent):
            self.write(staticString: "HTTP/1.0 205 Reset Content\r\n")
        case (1, 0, .partialContent):
            self.write(staticString: "HTTP/1.0 206 Partial Content\r\n")
        case (1, 0, .multiStatus):
            self.write(staticString: "HTTP/1.0 207 Multi-Status\r\n")
        case (1, 0, .alreadyReported):
            self.write(staticString: "HTTP/1.0 208 Already Reported\r\n")
        case (1, 0, .imUsed):
            self.write(staticString: "HTTP/1.0 226 IM Used\r\n")
        case (1, 0, .multipleChoices):
            self.write(staticString: "HTTP/1.0 300 Multiple Choices\r\n")
        case (1, 0, .movedPermanently):
            self.write(staticString: "HTTP/1.0 301 Moved Permanently\r\n")
        case (1, 0, .found):
            self.write(staticString: "HTTP/1.0 302 Found\r\n")
        case (1, 0, .seeOther):
            self.write(staticString: "HTTP/1.0 303 See Other\r\n")
        case (1, 0, .notModified):
            self.write(staticString: "HTTP/1.0 304 Not Modified\r\n")
        case (1, 0, .useProxy):
            self.write(staticString: "HTTP/1.0 305 Use Proxy\r\n")
        case (1, 0, .temporaryRedirect):
            self.write(staticString: "HTTP/1.0 307 Tempory Redirect\r\n")
        case (1, 0, .permanentRedirect):
            self.write(staticString: "HTTP/1.0 308 Permanent Redirect\r\n")
        case (1, 0, .badRequest):
            self.write(staticString: "HTTP/1.0 400 Bad Request\r\n")
        case (1, 0, .unauthorized):
            self.write(staticString: "HTTP/1.0 401 Unauthorized\r\n")
        case (1, 0, .paymentRequired):
            self.write(staticString: "HTTP/1.0 402 Payment Required\r\n")
        case (1, 0, .forbidden):
            self.write(staticString: "HTTP/1.0 403 Forbidden\r\n")
        case (1, 0, .notFound):
            self.write(staticString: "HTTP/1.0 404 Not Found\r\n")
        case (1, 0, .methodNotAllowed):
            self.write(staticString: "HTTP/1.0 405 Method Not Allowed\r\n")
        case (1, 0, .notAcceptable):
            self.write(staticString: "HTTP/1.0 406 Not Acceptable\r\n")
        case (1, 0, .proxyAuthenticationRequired):
            self.write(staticString: "HTTP/1.0 407 Proxy Authentication Required\r\n")
        case (1, 0, .requestTimeout):
            self.write(staticString: "HTTP/1.0 408 Request Timeout\r\n")
        case (1, 0, .conflict):
            self.write(staticString: "HTTP/1.0 409 Conflict\r\n")
        case (1, 0, .gone):
            self.write(staticString: "HTTP/1.0 410 Gone\r\n")
        case (1, 0, .lengthRequired):
            self.write(staticString: "HTTP/1.0 411 Length Required\r\n")
        case (1, 0, .preconditionFailed):
            self.write(staticString: "HTTP/1.0 412 Precondition Failed\r\n")
        case (1, 0, .payloadTooLarge):
            self.write(staticString: "HTTP/1.0 413 Payload Too Large\r\n")
        case (1, 0, .uriTooLong):
            self.write(staticString: "HTTP/1.0 414 URI Too Long\r\n")
        case (1, 0, .unsupportedMediaType):
            self.write(staticString: "HTTP/1.0 415 Unsupported Media Type\r\n")
        case (1, 0, .rangeNotSatisfiable):
            self.write(staticString: "HTTP/1.0 416 Range Not Satisfiable\r\n")
        case (1, 0, .expectationFailed):
            self.write(staticString: "HTTP/1.0 417 Expectation Failed\r\n")
        case (1, 0, .misdirectedRequest):
            self.write(staticString: "HTTP/1.0 421 Misdirected Request\r\n")
        case (1, 0, .unprocessableEntity):
            self.write(staticString: "HTTP/1.0 422 Unprocessable Entity\r\n")
        case (1, 0, .locked):
            self.write(staticString: "HTTP/1.0 423 Locked\r\n")
        case (1, 0, .failedDependency):
            self.write(staticString: "HTTP/1.0 424 Failed Dependency\r\n")
        case (1, 0, .upgradeRequired):
            self.write(staticString: "HTTP/1.0 426 Upgrade Required\r\n")
        case (1, 0, .preconditionRequired):
            self.write(staticString: "HTTP/1.0 428 Precondition Required\r\n")
        case (1, 0, .tooManyRequests):
            self.write(staticString: "HTTP/1.0 429 Too Many Requests\r\n")
        case (1, 0, .requestHeaderFieldsTooLarge):
            self.write(staticString: "HTTP/1.0 431 Request Header Fields Too Large\r\n")
        case (1, 0, .unavailableForLegalReasons):
            self.write(staticString: "HTTP/1.0 451 Unavailable For Legal Reasons\r\n")
        case (1, 0, .internalServerError):
            self.write(staticString: "HTTP/1.0 500 Internal Server Error\r\n")
        case (1, 0, .notImplemented):
            self.write(staticString: "HTTP/1.0 501 Not Implemented\r\n")
        case (1, 0, .badGateway):
            self.write(staticString: "HTTP/1.0 502 Bad Gateway\r\n")
        case (1, 0, .serviceUnavailable):
            self.write(staticString: "HTTP/1.0 503 Service Unavailable\r\n")
        case (1, 0, .gatewayTimeout):
            self.write(staticString: "HTTP/1.0 504 Gateway Timeout\r\n")
        case (1, 0, .httpVersionNotSupported):
            self.write(staticString: "HTTP/1.0 505 HTTP Version Not Supported\r\n")
        case (1, 0, .variantAlsoNegotiates):
            self.write(staticString: "HTTP/1.0 506 Variant Also Negotiates\r\n")
        case (1, 0, .insufficientStorage):
            self.write(staticString: "HTTP/1.0 507 Insufficient Storage\r\n")
        case (1, 0, .loopDetected):
            self.write(staticString: "HTTP/1.0 508 Loop Detected\r\n")
        case (1, 0, .notExtended):
            self.write(staticString: "HTTP/1.0 510 Not Extended\r\n")
        case (1, 0, .networkAuthenticationRequired):
            self.write(staticString: "HTTP/1.1 511 Network Authentication Required\r\n")

        // Optimization for HTTP/1.1
        case (1, 1, .custom(_, _)):
            self.write(staticString: "HTTP/1.1 ")
            self.write(status: response.status)
            self.write(staticString: "\r\n")
        case (1, 1, .continue):
            self.write(staticString: "HTTP/1.1 100 Continue\r\n")
        case (1, 1, .switchingProtocols):
            self.write(staticString: "HTTP/1.1 101 Switching Protocols\r\n")
        case (1, 1, .processing):
            self.write(staticString: "HTTP/1.1 102 Processing\r\n")
        case (1, 1, .ok):
            self.write(staticString: "HTTP/1.1 200 OK\r\n")
        case (1, 1, .created):
            self.write(staticString: "HTTP/1.1 201 Created\r\n")
        case (1, 1, .accepted):
            self.write(staticString: "HTTP/1.1 202 Accepted\r\n")
        case (1, 1, .nonAuthoritativeInformation):
            self.write(staticString: "HTTP/1.1 203 Non-Authoritative Information\r\n")
        case (1, 1, .noContent):
            self.write(staticString: "HTTP/1.1 204 No Content\r\n")
        case (1, 1, .resetContent):
            self.write(staticString: "HTTP/1.1 205 Reset Content\r\n")
        case (1, 1, .partialContent):
            self.write(staticString: "HTTP/1.1 206 Partial Content\r\n")
        case (1, 1, .multiStatus):
            self.write(staticString: "HTTP/1.1 207 Multi-Status\r\n")
        case (1, 1, .alreadyReported):
            self.write(staticString: "HTTP/1.1 208 Already Reported\r\n")
        case (1, 1, .imUsed):
            self.write(staticString: "HTTP/1.1 226 IM Used\r\n")
        case (1, 1, .multipleChoices):
            self.write(staticString: "HTTP/1.1 300 Multiple Choices\r\n")
        case (1, 1, .movedPermanently):
            self.write(staticString: "HTTP/1.1 301 Moved Permanently\r\n")
        case (1, 1, .found):
            self.write(staticString: "HTTP/1.1 302 Found\r\n")
        case (1, 1, .seeOther):
            self.write(staticString: "HTTP/1.1 303 See Other\r\n")
        case (1, 1, .notModified):
            self.write(staticString: "HTTP/1.1 304 Not Modified\r\n")
        case (1, 1, .useProxy):
            self.write(staticString: "HTTP/1.1 305 Use Proxy\r\n")
        case (1, 1, .temporaryRedirect):
            self.write(staticString: "HTTP/1.1 307 Tempory Redirect\r\n")
        case (1, 1, .permanentRedirect):
            self.write(staticString: "HTTP/1.1 308 Permanent Redirect\r\n")
        case (1, 1, .badRequest):
            self.write(staticString: "HTTP/1.1 400 Bad Request\r\n")
        case (1, 1, .unauthorized):
            self.write(staticString: "HTTP/1.1 401 Unauthorized\r\n")
        case (1, 1, .paymentRequired):
            self.write(staticString: "HTTP/1.1 402 Payment Required\r\n")
        case (1, 1, .forbidden):
            self.write(staticString: "HTTP/1.1 403 Forbidden\r\n")
        case (1, 1, .notFound):
            self.write(staticString: "HTTP/1.1 404 Not Found\r\n")
        case (1, 1, .methodNotAllowed):
            self.write(staticString: "HTTP/1.1 405 Method Not Allowed\r\n")
        case (1, 1, .notAcceptable):
            self.write(staticString: "HTTP/1.1 406 Not Acceptable\r\n")
        case (1, 1, .proxyAuthenticationRequired):
            self.write(staticString: "HTTP/1.1 407 Proxy Authentication Required\r\n")
        case (1, 1, .requestTimeout):
            self.write(staticString: "HTTP/1.1 408 Request Timeout\r\n")
        case (1, 1, .conflict):
            self.write(staticString: "HTTP/1.1 409 Conflict\r\n")
        case (1, 1, .gone):
            self.write(staticString: "HTTP/1.1 410 Gone\r\n")
        case (1, 1, .lengthRequired):
            self.write(staticString: "HTTP/1.1 411 Length Required\r\n")
        case (1, 1, .preconditionFailed):
            self.write(staticString: "HTTP/1.1 412 Precondition Failed\r\n")
        case (1, 1, .payloadTooLarge):
            self.write(staticString: "HTTP/1.1 413 Payload Too Large\r\n")
        case (1, 1, .uriTooLong):
            self.write(staticString: "HTTP/1.1 414 URI Too Long\r\n")
        case (1, 1, .unsupportedMediaType):
            self.write(staticString: "HTTP/1.1 415 Unsupported Media Type\r\n")
        case (1, 1, .rangeNotSatisfiable):
            self.write(staticString: "HTTP/1.1 416 Request Range Not Satisified\r\n")
        case (1, 1, .expectationFailed):
            self.write(staticString: "HTTP/1.1 417 Expectation Failed\r\n")
        case (1, 1, .misdirectedRequest):
            self.write(staticString: "HTTP/1.1 421 Misdirected Request\r\n")
        case (1, 1, .unprocessableEntity):
            self.write(staticString: "HTTP/1.1 422 Unprocessable Entity\r\n")
        case (1, 1, .locked):
            self.write(staticString: "HTTP/1.1 423 Locked\r\n")
        case (1, 1, .failedDependency):
            self.write(staticString: "HTTP/1.1 424 Failed Dependency\r\n")
        case (1, 1, .upgradeRequired):
            self.write(staticString: "HTTP/1.1 426 Upgrade Required\r\n")
        case (1, 1, .preconditionRequired):
            self.write(staticString: "HTTP/1.1 428 Precondition Required\r\n")
        case (1, 1, .tooManyRequests):
            self.write(staticString: "HTTP/1.1 429 Too Many Requests\r\n")
        case (1, 1, .requestHeaderFieldsTooLarge):
            self.write(staticString: "HTTP/1.1 431 Range Not Satisfiable\r\n")
        case (1, 1, .unavailableForLegalReasons):
            self.write(staticString: "HTTP/1.1 451 Unavailable For Legal Reasons\r\n")
        case (1, 1, .internalServerError):
            self.write(staticString: "HTTP/1.1 500 Internal Server Error\r\n")
        case (1, 1, .notImplemented):
            self.write(staticString: "HTTP/1.1 501 Not Implemented\r\n")
        case (1, 1, .badGateway):
            self.write(staticString: "HTTP/1.1 502 Bad Gateway\r\n")
        case (1, 1, .serviceUnavailable):
            self.write(staticString: "HTTP/1.1 503 Service Unavailable\r\n")
        case (1, 1, .gatewayTimeout):
            self.write(staticString: "HTTP/1.1 504 Gateway Timeout\r\n")
        case (1, 1, .httpVersionNotSupported):
            self.write(staticString: "HTTP/1.1 505 HTTP Version Not Supported\r\n")
        case (1, 1, .variantAlsoNegotiates):
            self.write(staticString: "HTTP/1.1 506 Variant Also Negotiates\r\n")
        case (1, 1, .insufficientStorage):
            self.write(staticString: "HTTP/1.1 507 Insufficient Storage\r\n")
        case (1, 1, .loopDetected):
            self.write(staticString: "HTTP/1.1 508 Loop Detected\r\n")
        case (1, 1, .notExtended):
            self.write(staticString: "HTTP/1.1 510 Not Extended\r\n")
        case (1, 1, .networkAuthenticationRequired):
            self.write(staticString: "HTTP/1.1 511 Network Authentication Required\r\n")

        // Fallback for non-known HTTP version
        default:
            self.write(version: response.version)
            self.writeWhitespace()
            self.write(status: response.status)
            self.write(staticString: "\r\n")
        }
    }

    private mutating func write(version: HTTPVersion) {
        switch (version.minor, version.major) {
        case (1, 0):
            self.write(staticString: "HTTP/1.0")
        case (1, 1):
            self.write(staticString: "HTTP/1.1")
        default:
            self.write(staticString: "HTTP/")
            self.write(string: String(version.major))
            self.write(staticString: ".")
            self.write(string: String(version.minor))
        }
    }

    mutating func write(request: HTTPRequestHead) {
        self.write(method: request.method)
        self.writeWhitespace()
        self.write(string: request.uri)
        self.writeWhitespace()
        self.write(version: request.version)
        self.write(staticString: "\r\n")
    }

    mutating func writeWhitespace() {
        self.write(integer: 32, as: UInt8.self)
    }

    private mutating func write(method: HTTPMethod) {
        switch method {
        case .GET:
            self.write(staticString: "GET")
        case .PUT:
            self.write(staticString: "PUT")
        case .ACL:
            self.write(staticString: "ACL")
        case .HEAD:
            self.write(staticString: "HEAD")
        case .POST:
            self.write(staticString: "POST")
        case .COPY:
            self.write(staticString: "COPY")
        case .LOCK:
            self.write(staticString: "LOCK")
        case .MOVE:
            self.write(staticString: "MOVE")
        case .BIND:
            self.write(staticString: "BIND")
        case .LINK:
            self.write(staticString: "LINK")
        case .PATCH:
            self.write(staticString: "PATCH")
        case .TRACE:
            self.write(staticString: "TRACE")
        case .MKCOL:
            self.write(staticString: "MKCOL")
        case .MERGE:
            self.write(staticString: "MERGE")
        case .PURGE:
            self.write(staticString: "PURGE")
        case .NOTIFY:
            self.write(staticString: "NOTIFY")
        case .SEARCH:
            self.write(staticString: "SEARCH")
        case .UNLOCK:
            self.write(staticString: "UNLOCK")
        case .REBIND:
            self.write(staticString: "REBIND")
        case .UNBIND:
            self.write(staticString: "UNBIND")
        case .REPORT:
            self.write(staticString: "REPORT")
        case .DELETE:
            self.write(staticString: "DELETE")
        case .UNLINK:
            self.write(staticString: "UNLINK")
        case .CONNECT:
            self.write(staticString: "CONNECT")
        case .MSEARCH:
            self.write(staticString: "MSEARCH")
        case .OPTIONS:
            self.write(staticString: "OPTIONS")
        case .PROPFIND:
            self.write(staticString: "PROPFIND")
        case .CHECKOUT:
            self.write(staticString: "CHECKOUT")
        case .PROPPATCH:
            self.write(staticString: "PROPPATCH")
        case .SUBSCRIBE:
            self.write(staticString: "SUBSCRIBE")
        case .MKCALENDAR:
            self.write(staticString: "MKCALENDAR")
        case .MKACTIVITY:
            self.write(staticString: "MKACTIVITY")
        case .UNSUBSCRIBE:
            self.write(staticString: "UNSUBSCRIBE")
        case .RAW(let value):
            self.write(string: value)
        }
    }
}
