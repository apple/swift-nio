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

import Foundation
import NIO
import CHTTPParser

public final class HTTPRequestDecoder : ByteToMessageDecoder {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = HTTPRequest
    public var cumulationBuffer: ByteBuffer?
    
    private var parser: http_parser?
    private var settings: http_parser_settings?
    
    
    private enum DataAwaitingState {
        case messageBegin
        case url
        case headerField
        case headerValue
        case body
    }

    private var state: HTTPParserState!

    private func writeBytesToBuffer(currentState: DataAwaitingState,
                                    data: UnsafePointer<Int8>!,
                                    len: Int,
                                    previousComplete: (DataAwaitingState) -> Void) -> Void {
        if currentState != self.state.dataAwaitingState {
            let oldState = self.state.dataAwaitingState
            self.state.dataAwaitingState = currentState
            previousComplete(oldState)
        }
        self.state.parserBuffer.write(int8Data: data, len: len)
    }


    private func complete(state: DataAwaitingState) {
        switch state {
        case .messageBegin:
            assert(self.state.parserBuffer.readableBytes == 0, "non-empty buffer on begin (\(self.state.parserBuffer.readableBytes))")
        case .headerField:
            assert(self.state.currentUri != nil, "URI not set before header field")
            self.state.currentHeaderName = self.state.parserBuffer.readString()!
            self.state.parserBuffer.clear()
        case .headerValue:
            assert(self.state.currentUri != nil, "URI not set before header field")
            self.state.currentHeaders!.add(name: self.state.currentHeaderName!, value: self.state.parserBuffer.readString()!)
            self.state.parserBuffer.clear()
        case .url:
            assert(self.state.currentUri == nil)
            self.state.currentUri = self.state.parserBuffer.readString()!
            self.state.parserBuffer.clear()
        case .body:
            ()
        }
    }

    private struct HTTPParserState {
        var dataAwaitingState: DataAwaitingState = .messageBegin
        var currentHeaders: HTTPHeaders?
        var currentUri: String?
        var currentHeaderName: String?
        var parserBuffer: ByteBuffer

        mutating func reset() {
            self.currentHeaders = HTTPHeaders()
            self.currentUri = nil
            self.currentHeaderName = nil
            self.parserBuffer.clear()
        }

        mutating func finializeHTTPRequest(parser: UnsafeMutablePointer<http_parser>?) -> HTTPRequestHead? {
            guard let method = HTTPMethod.from(httpParserMethod: http_method(rawValue: parser!.pointee.method)) else {
                return nil
            }
            let version = HTTPVersion(major: parser!.pointee.http_major, minor: parser!.pointee.http_minor)
            let request = HTTPRequestHead(version: version, method: method, uri: currentUri!, headers: currentHeaders!)
            currentHeaders = nil
            return request
        }

        init(allocator: ByteBufferAllocator) throws {
            self.parserBuffer = allocator.buffer(capacity: 64)
        }
    }

    public init() { }

    public func decoderAdded(ctx: ChannelHandlerContext) throws {
        parser = http_parser()
        http_parser_init(&parser!, HTTP_REQUEST)
        parser!.data = Unmanaged.passUnretained(ctx).toOpaque()

        settings = http_parser_settings()
        http_parser_settings_init(&settings!)

        self.state = try HTTPParserState(allocator: ctx.channel!.allocator)

        settings!.on_message_begin = { parser in
            let ctx = evacuateContext(parser)
            let handler = (ctx.handler as! HTTPRequestDecoder)
            handler.state.reset()

            return 0
        }

        settings!.on_headers_complete = { parser in
            let ctx = evacuateContext(parser)
            let handler = ctx.handler as! HTTPRequestDecoder

            handler.complete(state: handler.state.dataAwaitingState)

            guard let request = handler.state.finializeHTTPRequest(parser: parser) else {
                return -1
            }

            handler.state.dataAwaitingState = .body

            ctx.fireChannelRead(data: handler.wrapInboundOut(HTTPRequest.head(request)))
            return 0
        }

        settings!.on_body = { parser, data, len in
            let ctx = evacuateContext(parser)
            let handler = ctx.handler as! HTTPRequestDecoder
            assert(handler.state.dataAwaitingState == .body)

            // This will never return nil as we allocated the buffer with the correct size
            handler.state.parserBuffer.write(int8Data: data!, len: len)
            ctx.fireChannelRead(data: handler.wrapInboundOut(HTTPRequest.body(HTTPBodyContent.more(buffer: handler.state.parserBuffer.readSlice(length: len)!))))

            return 0
        }

        settings!.on_header_field = { parser, data, len in
            let ctx = evacuateContext(parser)
            let handler = ctx.handler as! HTTPRequestDecoder

            handler.writeBytesToBuffer(currentState: .headerField, data: data, len: len) { previousState in
                handler.complete(state: previousState)
            }
            return 0
        }

        settings!.on_header_value = { parser, data, len in
            let ctx = evacuateContext(parser)
            let handler = ctx.handler as! HTTPRequestDecoder

            handler.writeBytesToBuffer(currentState: .headerValue, data: data, len: len) { previousState in
                handler.complete(state: previousState)
            }
            return 0
        }

        settings!.on_url = { parser, data, len in
            let ctx = evacuateContext(parser)
            let handler = ctx.handler as! HTTPRequestDecoder

            handler.writeBytesToBuffer(currentState: .url, data: data, len: len) { previousState in
                assert(previousState == .messageBegin, "expected: messageBegin, actual: \(previousState)")
                handler.complete(state: previousState)
            }
            return 0
        }

        settings!.on_message_complete = { parser in
            let ctx = evacuateContext(parser)
            let handler = ctx.handler as! HTTPRequestDecoder

            ctx.fireChannelRead(data: handler.wrapInboundOut(HTTPRequest.body(.last(buffer: nil))))
            handler.complete(state: handler.state.dataAwaitingState)
            handler.state.dataAwaitingState = .messageBegin
            return 0
        }
    }

    public func decoderRemoved(ctx: ChannelHandlerContext) {
        if parser != nil {
            parser!.data = UnsafeMutableRawPointer(bitPattern: 0x0000deadbeef0000)
            parser = nil
            settings = nil
        }
        
        state = nil
    }

    public func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> Bool {
        let result = try buffer.withReadPointer(body: { (pointer: UnsafePointer<UInt8>, len: Int) -> size_t in
            try pointer.withMemoryRebound(to: Int8.self, capacity: len, { (bytes: UnsafePointer<Int8>) -> size_t in
                let result = http_parser_execute(&parser!, &settings!, bytes, len)
                let errno = parser!.http_errno
                if errno != 0 {
                    throw HTTPParserError.httpError(fromCHTTPParserErrno:  http_errno(rawValue: errno))!
                }
                return result
            })
        })
        buffer.moveReaderIndex(forwardBy: result)
        return true
    }

    public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        ctx.fireErrorCaught(error: error)
        if error is HTTPParserError {
            _ = ctx.close()
        }
    }
}


private func evacuateContext(_ opaqueContext: UnsafeMutablePointer<http_parser>!) -> ChannelHandlerContext {
    return Unmanaged.fromOpaque(opaqueContext.pointee.data).takeUnretainedValue()
}

extension ByteBuffer {

    mutating func readString() -> String? {
        return withReadPointer(body: { (pointer, length) -> String? in
            return String(bytes: UnsafeBufferPointer(start: pointer, count: length), encoding: .utf8)
        })
    }

    @discardableResult mutating func write(int8Data: UnsafePointer<Int8>, len: Int) -> Int {
        return self.write(bytes: UnsafeRawBufferPointer(start: UnsafeRawPointer(int8Data), count: len))
    }
}

extension HTTPParserError {
    static func httpError(fromCHTTPParserErrno: http_errno) -> HTTPParserError? {
        switch fromCHTTPParserErrno {
        case HPE_INVALID_EOF_STATE:
            return .invalidEOFState
        case HPE_HEADER_OVERFLOW:
            return .headerOverflow
        case HPE_CLOSED_CONNECTION:
            return .closedConnection
        case HPE_INVALID_VERSION:
            return .invalidVersion
        case HPE_INVALID_STATUS:
            return .invalidStatus
        case HPE_INVALID_METHOD:
            return .invalidMethod
        case HPE_INVALID_URL:
            return .invalidURL
        case HPE_INVALID_HOST:
            return .invalidHost
        case HPE_INVALID_PORT:
            return .invalidPort
        case HPE_INVALID_PATH:
            return .invalidPath
        case HPE_INVALID_QUERY_STRING:
            return .invalidQueryString
        case HPE_INVALID_FRAGMENT:
            return .invalidFragment
        case HPE_LF_EXPECTED:
            return .lfExpected
        case HPE_INVALID_HEADER_TOKEN:
            return .invalidHeaderToken
        case HPE_INVALID_CONTENT_LENGTH:
            return .invalidContentLength
        case HPE_UNEXPECTED_CONTENT_LENGTH:
            return .unexpectedContentLength
        case HPE_INVALID_CHUNK_SIZE:
            return .invalidChunkSize
        case HPE_INVALID_CONSTANT:
            return .invalidConstant
        case HPE_STRICT:
            return .strictModeAssertion
        case HPE_PAUSED:
            return .paused
        case HPE_UNKNOWN:
            return .unknown
        default:
            return nil
        }
    }
}

extension HTTPMethod {
    static func from(httpParserMethod: http_method) -> HTTPMethod? {
        switch httpParserMethod {
        case HTTP_DELETE:
            return .DELETE
        case HTTP_GET:
            return .GET
        case HTTP_HEAD:
            return .HEAD
        case HTTP_POST:
            return .POST
        case HTTP_PUT:
            return .PUT
        case HTTP_CONNECT:
            return .CONNECT
        case HTTP_OPTIONS:
            return .OPTIONS
        case HTTP_TRACE:
            return .TRACE
        case HTTP_COPY:
            return .COPY
        case HTTP_LOCK:
            return .LOCK
        case HTTP_MKCOL:
            return .MKCOL
        case HTTP_MOVE:
            return .MOVE
        case HTTP_PROPFIND:
            return .PROPFIND
        case HTTP_PROPPATCH:
            return .PROPPATCH
        case HTTP_SEARCH:
            return .SEARCH
        case HTTP_UNLOCK:
            return .UNLOCK
        case HTTP_BIND:
            return .BIND
        case HTTP_REBIND:
            return .REBIND
        case HTTP_UNBIND:
            return .UNBIND
        case HTTP_ACL:
            return .ACL
        case HTTP_REPORT:
            return .REPORT
        case HTTP_MKACTIVITY:
            return .MKACTIVITY
        case HTTP_CHECKOUT:
            return .CHECKOUT
        case HTTP_MERGE:
            return .MERGE
        case HTTP_MSEARCH:
            return .MSEARCH
        case HTTP_NOTIFY:
            return .NOTIFY
        case HTTP_SUBSCRIBE:
            return .SUBSCRIBE
        case HTTP_UNSUBSCRIBE:
            return .UNSUBSCRIBE
        case HTTP_PATCH:
            return .PATCH
        case HTTP_PURGE:
            return .PURGE
        case HTTP_MKCALENDAR:
            return .MKCALENDAR
        case HTTP_LINK:
            return .LINK
        case HTTP_UNLINK:
            return .UNLINK
        default:
            return nil
        }
    }
}
