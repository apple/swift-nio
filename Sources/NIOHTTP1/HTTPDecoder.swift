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
import CNIOHTTPParser

private struct HTTPParserState {
    var dataAwaitingState: DataAwaitingState = .messageBegin
    var currentHeaders: HTTPHeaders?
    var currentUri: String?
    var currentStatus: String?
    var currentHeaderName: String?
    var slice: (readerIndex: Int, length: Int)?
    var readerIndexAdjustment = 0
    // This is set before http_parser_execute(...) is called and set to nil again after it finish
    var baseAddress: UnsafePointer<UInt8>?

    enum DataAwaitingState {
        case messageBegin
        case status
        case url
        case headerField
        case headerValue
        case body
    }

    mutating func reset() {
        self.currentHeaders = nil
        self.currentUri = nil
        self.currentStatus = nil
        self.currentHeaderName = nil
        self.slice = nil
        self.readerIndexAdjustment = 0
    }

    var cumulationBuffer: ByteBuffer?

    mutating func readCurrentString() -> String {
        let (index, length) = self.slice!
        let string = self.cumulationBuffer!.getString(at: index, length: length)!
        self.slice = nil
        return string
    }

    mutating func complete(state: DataAwaitingState) {
        switch state {
        case .messageBegin:
            assert(self.slice == nil, "non-empty slice on begin (\(self.slice!))")
        case .headerField:
            assert(self.currentUri != nil || self.currentStatus != nil, "URI or Status not set before header field")
            self.currentHeaderName = readCurrentString()
        case .headerValue:
            assert(self.currentUri != nil || self.currentStatus != nil, "URI or Status not set before header field")
            if self.currentHeaders == nil {
                self.currentHeaders = HTTPHeaders()
            }
            self.currentHeaders!.add(name: self.currentHeaderName!, value: readCurrentString())
        case .url:
            assert(self.currentUri == nil)
            self.currentUri = readCurrentString()
        case .status:
            assert(self.currentStatus == nil)
            self.currentStatus = readCurrentString()
        case .body:
            self.slice = nil
        }
    }

    func calculateIndex(data: UnsafePointer<Int8>, length: Int) -> Int {
        return data.withMemoryRebound(to: UInt8.self, capacity: length, { p in
            return self.baseAddress!.distance(to: p)
        })
    }

    mutating func storeSlice(currentState: DataAwaitingState,
                             data: UnsafePointer<Int8>!,
                             len: Int,
                             previousComplete: (inout HTTPParserState, DataAwaitingState) -> Void) -> Void {
        if currentState != self.dataAwaitingState {
            let oldState = self.dataAwaitingState
            self.dataAwaitingState = currentState
            previousComplete(&self, oldState)
        }
        if let slice = self.slice {
            // If we had a slice stored before we just need to update the length
            self.slice = (slice.readerIndex, slice.length + len)
        } else {
            // Store the slice
            let index = self.calculateIndex(data: data, length: len)
            assert(index >= 0)
            self.slice = (index, len)
        }
    }
}

private protocol AnyHTTPDecoder: class {
    var state: HTTPParserState { get set }
    var pendingCallouts: [() -> Void] { get set }
    func popRequestMethod() -> HTTPMethod?
}

/// A `ChannelInboundHandler` used to decode HTTP requests. See the documentation
/// on `HTTPDecoder` for more.
///
/// While the `HTTPRequestDecoder` does not currently have a specific ordering requirement in the
/// `ChannelPipeline` (unlike `HTTPResponseDecoder`), it is possible that it will develop one. For
/// that reason, applications should try to ensure that the `HTTPRequestDecoder` *later* in the
/// `ChannelPipeline` than the `HTTPResponseEncoder`.
///
/// Rather than set this up manually, consider using `ChannelPipeline.addHTTPServerHandlers`.
public final class HTTPRequestDecoder: HTTPDecoder<HTTPServerRequestPart> {
    public convenience init() {
        self.init(type: HTTPServerRequestPart.self)
    }
}

/// A `ChannelInboundHandler` used to decode HTTP responses. See the documentation
/// on `HTTPDecoder` for more.
///
/// The `HTTPResponseDecoder` must be placed later in the channel pipeline than the `HTTPRequestEncoder`,
/// as it needs to see the outbound messages in order to keep track of what the HTTP request methods
/// were for accurate decoding.
///
/// Rather than set this up manually, consider using `ChannelPipeline.addHTTPClientHandlers`.
public final class HTTPResponseDecoder: HTTPDecoder<HTTPClientResponsePart>, ChannelOutboundHandler {
    public typealias OutboundIn = HTTPClientRequestPart
    public typealias OutboundOut = HTTPClientRequestPart

    /// A FIFO buffer used to store the HTTP request verbs we've seen, to ensure
    /// we handle HTTP HEAD responses correctly.
    ///
    /// Because we have to handle pipelining, this is a FIFO buffer instead of a single
    /// state variable. However, most users will never pipeline, so we initialize the buffer
    /// to a base size of 1 to avoid allocating too much memory in the average case.
    private var methods: CircularBuffer<HTTPMethod> = CircularBuffer(initialRingCapacity: 1)

    /// The method of the request the next response will be responding to.
    fileprivate override func popRequestMethod() -> HTTPMethod? {
        return methods.removeFirst()
    }

    public convenience init() {
        self.init(type: HTTPClientResponsePart.self)
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch unwrapOutboundIn(data) {
        case .head(let head):
            methods.append(head.method)
        default:
            break
        }

        ctx.write(data, promise: promise)
    }
}

/// A `ChannelInboundHandler` that parses HTTP/1-style messages, converting them from
/// unstructured bytes to a sequence of HTTP messages.
///
/// The `HTTPDecoder` is a generic channel handler which can produce messages in
/// either the form of `HTTPClientResponsePart` or `HTTPServerRequestPart`: that is,
/// it produces messages that correspond to the semantic units of HTTP produced by
/// the remote peer.
public class HTTPDecoder<HTTPMessageT>: ByteToMessageDecoder, AnyHTTPDecoder {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = HTTPMessageT

    private var parser = http_parser()
    private var settings = http_parser_settings()

    fileprivate var pendingCallouts: [() -> Void] = []
    fileprivate var state = HTTPParserState()

    fileprivate init(type: HTTPMessageT.Type) {
        /* this is a private init, the public versions only allow HTTPClientResponsePart and HTTPServerRequestPart */
        assert(HTTPMessageT.self == HTTPClientResponsePart.self || HTTPMessageT.self == HTTPServerRequestPart.self)
    }

    /// The most recent method seen by request handlers.
    ///
    /// Naturally, in the base case this returns nil, as servers never issue requests!
    fileprivate func popRequestMethod() -> HTTPMethod? { return nil }

    private func newRequestHead(_ parser: UnsafeMutablePointer<http_parser>!) -> HTTPRequestHead {
        let method = HTTPMethod.from(httpParserMethod: http_method(rawValue: parser.pointee.method))
        let version = HTTPVersion(major: parser.pointee.http_major, minor: parser.pointee.http_minor)
        let request = HTTPRequestHead(version: version, method: method, uri: state.currentUri!, headers: state.currentHeaders ?? HTTPHeaders())
        state.currentHeaders = nil
        return request
    }

    private func newResponseHead(_ parser: UnsafeMutablePointer<http_parser>!) -> HTTPResponseHead {
        let status = HTTPResponseStatus(statusCode: Int(parser.pointee.status_code), reasonPhrase: state.currentStatus!)
        let version = HTTPVersion(major: parser.pointee.http_major, minor: parser.pointee.http_minor)
        let response = HTTPResponseHead(version: version, status: status, headers: state.currentHeaders ?? HTTPHeaders())
        state.currentHeaders = nil
        return response
    }

    public func decoderAdded(ctx: ChannelHandlerContext) {
        if HTTPMessageT.self == HTTPServerRequestPart.self {
            c_nio_http_parser_init(&parser, HTTP_REQUEST)
        } else if HTTPMessageT.self == HTTPClientResponsePart.self {
            c_nio_http_parser_init(&parser, HTTP_RESPONSE)
        } else {
            fatalError("the impossible happened: MsgT neither HTTPClientRequestPart nor HTTPClientResponsePart but \(HTTPMessageT.self)")
        }

        parser.data = Unmanaged.passUnretained(ctx).toOpaque()

        c_nio_http_parser_settings_init(&settings)

        settings.on_message_begin = { parser in
            let handler = evacuateHTTPDecoder(parser)
            handler.state.reset()

            return 0
        }

        settings.on_headers_complete = { parser in
            let ctx = evacuateChannelHandlerContext(parser)
            let handler = evacuateHTTPDecoder(parser)

            handler.state.complete(state: handler.state.dataAwaitingState)
            handler.state.dataAwaitingState = .body

            switch handler {
            case let handler as HTTPRequestDecoder:
                let head = handler.newRequestHead(parser)
                handler.pendingCallouts.append {
                    ctx.fireChannelRead(handler.wrapInboundOut(HTTPServerRequestPart.head(head)))
                }
                return 0
            case let handler as HTTPResponseDecoder:
                let head = handler.newResponseHead(parser)
                handler.pendingCallouts.append {
                    ctx.fireChannelRead(handler.wrapInboundOut(HTTPClientResponsePart.head(head)))
                }

                // http_parser doesn't correctly handle responses to HEAD requests. We have to do something
                // annoyingly opaque here, and in those cases return 1 instead of 0. This forces http_parser
                // to not expect a request body.
                //
                // See also: https://github.com/nodejs/http-parser/issues/251. Note that despite the text in
                // that issue, http_parser *does* seem to handle the case of 204 and friends: it's just HEAD
                // that doesn't work.
                //
                // Note that this issue is the *entire* reason this must be a duplex: we need to know what the
                // request verb is that we're seeing a response for.
                let method = handler.popRequestMethod()
                return method == .HEAD ? 1 : 0
            default:
                fatalError("the impossible happened: handler neither a HTTPRequestDecoder nor a HTTPResponseDecoder which should be impossible")
            }
        }

        settings.on_body = { parser, data, len in
            let ctx = evacuateChannelHandlerContext(parser)
            let handler = evacuateHTTPDecoder(parser)
            assert(handler.state.dataAwaitingState == .body)

            // Calculate the index of the data in the cumulationBuffer so we can slice out the ByteBuffer without doing any memory copy
            let index = handler.state.calculateIndex(data: data!, length: len)

            let slice = handler.state.cumulationBuffer!.getSlice(at: index, length: len)!
            handler.pendingCallouts.append {
                switch handler {
                case let handler as HTTPRequestDecoder:
                    ctx.fireChannelRead(handler.wrapInboundOut(HTTPServerRequestPart.body(slice)))
                case let handler as HTTPResponseDecoder:
                    ctx.fireChannelRead(handler.wrapInboundOut(HTTPClientResponsePart.body(slice)))
                default:
                    fatalError("the impossible happened: handler neither a HTTPRequestDecoder nor a HTTPResponseDecoder which should be impossible")
                }
            }

            return 0
        }

        settings.on_header_field = { parser, data, len in
            let handler = evacuateHTTPDecoder(parser)

            handler.state.storeSlice(currentState: .headerField, data: data, len: len) { parserState, previousState in
                parserState.complete(state: previousState)
            }
            return 0
        }

        settings.on_header_value = { parser, data, len in
            let handler = evacuateHTTPDecoder(parser)

            handler.state.storeSlice(currentState: .headerValue, data: data, len: len) { parserState, previousState in
                parserState.complete(state: previousState)
            }
            return 0
        }

        settings.on_status = { parser, data, len in
            let handler = evacuateHTTPDecoder(parser)
            assert(handler is HTTPResponseDecoder)

            handler.state.storeSlice(currentState: .status, data: data, len: len) { parserState, previousState in
                assert(previousState == .messageBegin, "expected: messageBegin, actual: \(previousState)")
                parserState.complete(state: previousState)
            }
            return 0
        }

        settings.on_url = { parser, data, len in
            let handler = evacuateHTTPDecoder(parser)
            assert(handler is HTTPRequestDecoder)

            handler.state.storeSlice(currentState: .url, data: data, len: len) { parserState, previousState in
                assert(previousState == .messageBegin, "expected: messageBegin, actual: \(previousState)")
                parserState.complete(state: previousState)
            }
            return 0
        }

        settings.on_message_complete = { parser in
            let ctx = evacuateChannelHandlerContext(parser)
            let handler = evacuateHTTPDecoder(parser)

            handler.state.complete(state: handler.state.dataAwaitingState)
            handler.state.dataAwaitingState = .messageBegin

            let trailers = handler.state.currentHeaders?.count ?? 0 > 0 ? handler.state.currentHeaders : nil
            handler.pendingCallouts.append {
                switch handler {
                case let handler as HTTPRequestDecoder:
                    ctx.fireChannelRead(handler.wrapInboundOut(HTTPServerRequestPart.end(trailers)))
                case let handler as HTTPResponseDecoder:
                    ctx.fireChannelRead(handler.wrapInboundOut(HTTPClientResponsePart.end(trailers)))
                default:
                    fatalError("the impossible happened: handler neither a HTTPRequestDecoder nor a HTTPResponseDecoder which should be impossible")
                }
            }
            return 0
        }
    }

    public func decoderRemoved(ctx: ChannelHandlerContext) {
        // Remove the stored reference to ChannelHandlerContext
        parser.data = UnsafeMutableRawPointer(bitPattern: 0x0000deadbeef0000)

        // Set the callbacks to nil as we dont need these anymore
        settings.on_body = nil
        settings.on_chunk_complete = nil
        settings.on_url = nil
        settings.on_status = nil
        settings.on_chunk_header = nil
        settings.on_chunk_complete = nil
        settings.on_header_field = nil
        settings.on_header_value = nil
        settings.on_message_begin = nil
    }

    public func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if let slice = state.slice {
            // If we stored a slice before we need to ensure we move the readerIndex so we don't try to parse the data again. We
            // also need to update the reader index to whatever it is now.
            state.slice = (buffer.readerIndex, slice.length)
            buffer.moveReaderIndex(forwardBy: state.readerIndexAdjustment)
        }

        let result = try buffer.withVeryUnsafeBytes { (pointer) -> size_t in
            state.baseAddress = pointer.baseAddress!.assumingMemoryBound(to: UInt8.self)

            let result = state.baseAddress!.withMemoryRebound(to: Int8.self, capacity: pointer.count, { p in
                c_nio_http_parser_execute(&parser, &settings, p.advanced(by: buffer.readerIndex), buffer.readableBytes)
            })

            state.baseAddress = nil

            let errno = parser.http_errno
            if errno != 0 {
                throw HTTPParserError.httpError(fromCHTTPParserErrno: http_errno(rawValue: errno))!
            }
            return result
        }

        if let slice = state.slice {
            // If we have a slice, we need to preserve all of these bytes. To do that, we move the
            // reader index to where the slice wants it, and then record how many readable bytes that leaves
            // us with. Then, invalidate the reader index, as it's not stable across calls to decode()
            // *anyway*, so we want to make sure we can see the bad value in debug errors.
            buffer.moveReaderIndex(to: slice.readerIndex)
            state.readerIndexAdjustment = buffer.readableBytes
            state.slice = (-1, slice.length)
            return .needMoreData
        } else {
            buffer.moveReaderIndex(forwardBy: result)
            state.readerIndexAdjustment = 0
            return .continue
        }
    }

    public func channelReadComplete(ctx: ChannelHandlerContext) {
        /* call all the callbacks generated while parsing */
        let pending = self.pendingCallouts
        self.pendingCallouts = []
        pending.forEach { $0() }
        ctx.fireChannelReadComplete()
    }

    public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        ctx.fireErrorCaught(error)
        if error is HTTPParserError {
            ctx.close(promise: nil)
        }
    }
}

extension HTTPDecoder {
    public var cumulationBuffer: ByteBuffer? {
        get {
            return self.state.cumulationBuffer
        }
        set {
            self.state.cumulationBuffer = newValue
        }
    }
}

private func evacuateChannelHandlerContext(_ opaqueContext: UnsafeMutablePointer<http_parser>!) -> ChannelHandlerContext {
    return Unmanaged.fromOpaque(opaqueContext.pointee.data).takeUnretainedValue()
}

private func evacuateHTTPDecoder(_ opaqueContext: UnsafeMutablePointer<http_parser>!) -> AnyHTTPDecoder {
    return evacuateChannelHandlerContext(opaqueContext).handler as! AnyHTTPDecoder
}

extension HTTPParserError {
    /// Create a `HTTPParserError` from an error returned by `http_parser`.
    ///
    /// - Parameter fromCHTTPParserErrno: The error from the underlying library.
    /// - Returns: The corresponding `HTTPParserError`, or `nil` if there is no
    ///     corresponding error.
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
    /// Create a `HTTPMethod` from a given `http_method` produced by
    /// `http_parser`.
    ///
    /// - Parameter httpParserMethod: The method returned by `http_parser`.
    /// - Returns: The corresponding `HTTPMethod`.
    static func from(httpParserMethod: http_method) -> HTTPMethod {
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
            fatalError("Unexpected http_method \(httpParserMethod)")
        }
    }
}
