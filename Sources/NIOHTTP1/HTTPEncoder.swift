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
import Foundation // TODO(JW): investigate linker errors if this is missing

private func writeChunk(wrapOutboundOut: (IOData) -> NIOAny, ctx: ChannelHandlerContext, isChunked: Bool, chunk: IOData, promise: EventLoopPromise<Void>?) {
    let (mW1, mW2, mW3): (EventLoopPromise<()>?, EventLoopPromise<()>?, EventLoopPromise<()>?)
    
    switch (isChunked, promise) {
    case (true, .some(let p)):
        /* chunked encoding and the user's interested: we need three promises and need to cascade into the users promise */
        let (w1, w2, w3) = (ctx.eventLoop.newPromise() as EventLoopPromise<()>, ctx.eventLoop.newPromise() as EventLoopPromise<()>, ctx.eventLoop.newPromise() as EventLoopPromise<()>)
        w1.futureResult.and(w2.futureResult).and(w3.futureResult).then { _ in () }.cascade(promise: p)
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
        var buffer = ctx.channel!.allocator.buffer(capacity: 32)
        let len = String(readableBytes, radix: 16)
        buffer.write(string: len)
        buffer.write(staticString: "\r\n")
        ctx.write(data: wrapOutboundOut(.byteBuffer(buffer)), promise: mW1)
        
        ctx.write(data: wrapOutboundOut(chunk), promise: mW2)
        
        // Just move the buffers readerIndex to only make the \r\n readable and depend on COW semantics.
        buffer.moveReaderIndex(forwardBy: buffer.readableBytes - 2)
        ctx.write(data: wrapOutboundOut(.byteBuffer(buffer)), promise: mW3)
    } else {
        ctx.write(data: wrapOutboundOut(chunk), promise: mW2)
    }
}

private func writeTrailers(wrapOutboundOut: (IOData) -> NIOAny, ctx: ChannelHandlerContext, isChunked: Bool, trailers: HTTPHeaders?, promise: EventLoopPromise<Void>?) {
    switch (isChunked, promise) {
    case (true, let p):
        var buffer: ByteBuffer
        if let trailers = trailers {
            buffer = ctx.channel!.allocator.buffer(capacity: 256)
            buffer.write(staticString: "0\r\n")
            trailers.write(buffer: &buffer)  // Includes trailing CRLF.
        } else {
            buffer = ctx.channel!.allocator.buffer(capacity: 8)
            buffer.write(staticString: "0\r\n\r\n")
        }
        ctx.write(data: wrapOutboundOut(.byteBuffer(buffer)), promise: p)
    case (false, .some(let p)):
        // Not chunked so we have nothing to write. However, we don't want to satisfy this promise out-of-order
        // so we issue a zero-length write down the chain.
        let buf = ctx.channel!.allocator.buffer(capacity: 0)
        ctx.write(data: wrapOutboundOut(.byteBuffer(buf)), promise: p)
    case (false, .none):
        break
    }
}

private func writeHead(wrapOutboundOut: (IOData) -> NIOAny, writeStartLine: (inout ByteBuffer) -> (), ctx: ChannelHandlerContext, headers: HTTPHeaders, promise: EventLoopPromise<Void>?) {
    
    var buffer = ctx.channel!.allocator.buffer(capacity: 256)
    writeStartLine(&buffer)
    headers.write(buffer: &buffer)
    ctx.write(data: wrapOutboundOut(.byteBuffer(buffer)), promise: promise)
}

private func isChunkedPart(_ headers: HTTPHeaders) -> Bool {
    return headers["transfer-encoding"].contains("chunked")
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
private func sanitizeTransportHeaders(hasBody: HTTPMethod.HasBody, headers: inout HTTPHeaders, version: HTTPVersion) {
    switch hasBody {
    case .no:
        headers.remove(name: "content-length")
        headers.remove(name: "transfer-encoding")
    case .yes where headers["content-length"].count == 0 && version.major == 1 && version.minor >= 1:
        headers.replaceOrAdd(name: "transfer-encoding", value: "chunked")
    case .yes, .unlikely:
        /* leave alone */
        ()
    }
}

/// A `ChannelOutboundHandler` that can serialize HTTP requests.
///
/// This channel handler is used to translate messages from a series of
/// `HTTPClientRequestPart` into the HTTP/1.1 wire format.
public final class HTTPRequestEncoder : ChannelOutboundHandler {
    public typealias OutboundIn = HTTPClientRequestPart
    public typealias OutboundOut = IOData
    
    private var isChunked = false
    
    public init () { }
    
    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch self.unwrapOutboundIn(data) {
        case .head(var request):
            sanitizeTransportHeaders(hasBody: request.method.hasRequestBody, headers: &request.headers, version: request.version)

            self.isChunked = isChunkedPart(request.headers)
            
            writeHead(wrapOutboundOut: self.wrapOutboundOut, writeStartLine: { buffer in
                request.method.write(buffer: &buffer)
                buffer.write(staticString: " ")
                buffer.write(string: request.uri)
                buffer.write(staticString: " ")
                request.version.write(buffer: &buffer)
                buffer.write(staticString: "\r\n")
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
public final class HTTPResponseEncoder : ChannelOutboundHandler {
    public typealias OutboundIn = HTTPServerResponsePart
    public typealias OutboundOut = IOData

    private var isChunked = false

    public init () { }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch self.unwrapOutboundIn(data) {
        case .head(var response):
            sanitizeTransportHeaders(hasBody: response.status.mayHaveResponseBody ? .yes : .no, headers: &response.headers, version: response.version)
            
            self.isChunked = isChunkedPart(response.headers)
            writeHead(wrapOutboundOut: self.wrapOutboundOut, writeStartLine: { buffer in
                response.version.write(buffer: &buffer)
                buffer.write(staticString: " ")
                response.status.write(buffer: &buffer)
                buffer.write(staticString: "\r\n")
            }, ctx: ctx, headers: response.headers, promise: promise)
        case .body(let bodyPart):
            writeChunk(wrapOutboundOut: self.wrapOutboundOut, ctx: ctx, isChunked: self.isChunked, chunk: bodyPart, promise: promise)
        case .end(let trailers):
            writeTrailers(wrapOutboundOut: self.wrapOutboundOut, ctx: ctx, isChunked: self.isChunked, trailers: trailers, promise: promise)
        }
    }
}
