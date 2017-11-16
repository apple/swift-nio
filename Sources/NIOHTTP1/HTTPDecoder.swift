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

public typealias HTTPRequestDecoder = HTTPDecoder<HTTPServerRequestPart>
public typealias HTTPResponseDecoder = HTTPDecoder<HTTPClientResponsePart>

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
        let string = self.cumulationBuffer!.string(at: index, length: length)!
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
}

public extension HTTPDecoder where HTTPMessageT == HTTPClientResponsePart {
    public convenience init() {
        self.init(type: HTTPMessageT.self)
    }
}

public extension HTTPDecoder where HTTPMessageT == HTTPServerRequestPart {
    public convenience init() {
        self.init(type: HTTPMessageT.self)
    }
}

public final class HTTPDecoder<HTTPMessageT>: ByteToMessageDecoder, AnyHTTPDecoder {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = HTTPMessageT
    
    private var parser = http_parser()
    private var settings = http_parser_settings()
    
    fileprivate var pendingCallouts: [() -> Void] = []
    fileprivate var state = HTTPParserState()
    
    private init(type: HTTPMessageT.Type) {
        /* this is a private init, the public versions only allow HTTPClientResponsePart and HTTPServerRequestPart */
        assert(HTTPMessageT.self == HTTPClientResponsePart.self || HTTPMessageT.self == HTTPServerRequestPart.self)
    }
    
    private func newRequestHead(_ parser: UnsafeMutablePointer<http_parser>!) -> HTTPRequestHead {
        let method = HTTPMethod.from(httpParserMethod: http_method(rawValue: parser.pointee.method))
        let version = HTTPVersion(major: parser.pointee.http_major, minor: parser.pointee.http_minor)
        let request = HTTPRequestHead(version: version, method: method, uri: state.currentUri!, headers: state.currentHeaders ?? HTTPHeaders())
        state.currentHeaders = nil
        return request
    }
    
    private func newResponseHead(_ parser: UnsafeMutablePointer<http_parser>!) -> HTTPResponseHead {
        let status = HTTPResponseStatus.from(parser.pointee.status_code, state.currentStatus!)
        let version = HTTPVersion(major: parser.pointee.http_major, minor: parser.pointee.http_minor)
        let response = HTTPResponseHead(version: version, status: status, headers: state.currentHeaders ?? HTTPHeaders())
        state.currentHeaders = nil
        return response
    }
    
    public func decoderAdded(ctx: ChannelHandlerContext) throws {
        if HTTPMessageT.self == HTTPServerRequestPart.self {
            http_parser_init(&parser, HTTP_REQUEST)
        } else if HTTPMessageT.self == HTTPClientResponsePart.self {
            http_parser_init(&parser, HTTP_RESPONSE)
        } else {
            fatalError("the impossible happened: MsgT neither HTTPClientRequestPart nor HTTPClientResponsePart but \(HTTPMessageT.self)")
        }

        parser.data = Unmanaged.passUnretained(ctx).toOpaque()

        http_parser_settings_init(&settings)

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
                    ctx.fireChannelRead(data: handler.wrapInboundOut(HTTPServerRequestPart.head(head)))
                }
            case let handler as HTTPResponseDecoder:
                let head = handler.newResponseHead(parser)
                handler.pendingCallouts.append {
                    ctx.fireChannelRead(data: handler.wrapInboundOut(HTTPClientResponsePart.head(head)))
                }
            default:
                fatalError("the impossible happened: handler neither a HTTPRequestDecoder nor a HTTPResponseDecoder which should be impossible")
            }
            return 0
        }

        settings.on_body = { parser, data, len in
            let ctx = evacuateChannelHandlerContext(parser)
            let handler = evacuateHTTPDecoder(parser)
            assert(handler.state.dataAwaitingState == .body)
            
            // Calculate the index of the data in the cumulationBuffer so we can slice out the ByteBuffer without doing any memory copy
            let index = handler.state.calculateIndex(data: data!, length: len)
            
            let slice = handler.state.cumulationBuffer!.slice(at: index, length: len)!
            handler.pendingCallouts.append {
                switch handler {
                case let handler as HTTPRequestDecoder:
                    ctx.fireChannelRead(data: handler.wrapInboundOut(HTTPServerRequestPart.body(slice)))
                case let handler as HTTPResponseDecoder:
                    ctx.fireChannelRead(data: handler.wrapInboundOut(HTTPClientResponsePart.body(slice)))
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
                    ctx.fireChannelRead(data: handler.wrapInboundOut(HTTPServerRequestPart.end(trailers)))
                case let handler as HTTPResponseDecoder:
                    ctx.fireChannelRead(data: handler.wrapInboundOut(HTTPClientResponsePart.end(trailers)))
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
    
    public func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> Bool {
        if let slice = state.slice {
            // If we stored a slice before we need to ensure we move the readerIndex so we not try to parse the data again and also
            // adjust the slice as it now starts from 0.
            state.slice = (readerIndex: 0 , length: slice.length)
            buffer.moveReaderIndex(forwardBy: state.readerIndexAdjustment)
        }
        
        let result = try buffer.withVeryUnsafeBytes { (pointer) -> size_t in
            state.baseAddress = pointer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            
            let result = state.baseAddress!.withMemoryRebound(to: Int8.self, capacity: pointer.count, { p in
                http_parser_execute(&parser, &settings, p.advanced(by: buffer.readerIndex), buffer.readableBytes)
            })
            
            state.baseAddress = nil
            
            let errno = parser.http_errno
            if errno != 0 {
                throw HTTPParserError.httpError(fromCHTTPParserErrno: http_errno(rawValue: errno))!
            }
            return result
        }

        if let slice = state.slice {
            buffer.moveReaderIndex(to: slice.readerIndex)
            state.readerIndexAdjustment = buffer.readableBytes
            return false
        } else {
            buffer.moveReaderIndex(forwardBy: result)
            state.readerIndexAdjustment = 0
            return true
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
        ctx.fireErrorCaught(error: error)
        if error is HTTPParserError {
            ctx.close(promise: nil)
        }
    }
}

public extension HTTPDecoder {
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

extension HTTPResponseStatus {
    static func from(_ statusCode: UInt32, _ reasonPhrase: String) -> HTTPResponseStatus {
        switch statusCode {
        case 100:
            return .`continue`
        case 101:
            return .switchingProtocols
        case 102:
            return .processing
        case 200:
            return .ok
        case 201:
            return .created
        case 202:
            return .accepted
        case 203:
            return .nonAuthoritativeInformation
        case 204:
            return .noContent
        case 205:
            return .resetContent
        case 206:
            return .partialContent
        case 207:
            return .multiStatus
        case 208:
            return .alreadyReported
        case 226:
            return .imUsed
        case 300:
            return .multipleChoices
        case 301:
            return .movedPermanently
        case 302:
            return .found
        case 303:
            return .seeOther
        case 304:
            return .notModified
        case 305:
            return .useProxy
        case 307:
            return .temporaryRedirect
        case 308:
            return .permanentRedirect
        case 400:
            return .badRequest
        case 401:
            return .unauthorized
        case 402:
            return .paymentRequired
        case 403:
            return .forbidden
        case 404:
            return .notFound
        case 405:
            return .methodNotAllowed
        case 406:
            return .notAcceptable
        case 407:
            return .proxyAuthenticationRequired
        case 408:
            return .requestTimeout
        case 409:
            return .conflict
        case 410:
            return .gone
        case 411:
            return .lengthRequired
        case 412:
            return .preconditionFailed
        case 413:
            return .payloadTooLarge
        case 414:
            return .uriTooLong
        case 415:
            return .unsupportedMediaType
        case 416:
            return .rangeNotSatisfiable
        case 417:
            return .expectationFailed
        case 421:
            return .misdirectedRequest
        case 422:
            return .unprocessableEntity
        case 423:
            return .locked
        case 424:
            return .failedDependency
        case 426:
            return .upgradeRequired
        case 428:
            return .preconditionRequired
        case 429:
            return .tooManyRequests
        case 431:
            return .requestHeaderFieldsTooLarge
        case 451:
            return .unavailableForLegalReasons
        case 500:
            return .internalServerError
        case 501:
            return .notImplemented
        case 502:
            return .badGateway
        case 503:
            return .serviceUnavailable
        case 504:
            return .gatewayTimeout
        case 505:
            return .httpVersionNotSupported
        case 506:
            return .variantAlsoNegotiates
        case 507:
            return .insufficientStorage
        case 508:
            return .loopDetected
        case 510:
            return .notExtended
        case 511:
            return .networkAuthenticationRequired
        default:
            return .custom(code: UInt(statusCode), reasonPhrase: reasonPhrase)
        }
    }
}
