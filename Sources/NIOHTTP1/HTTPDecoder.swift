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

private extension UnsafeMutablePointer where Pointee == http_parser {
    /// Returns the `KeepAliveState` for the current message that is parsed.
    var keepAliveState: KeepAliveState {
        return c_nio_http_should_keep_alive(self) == 0 ? .close : .keepAlive
    }
}

private struct HTTPParserState {
    var dataAwaitingState: DataAwaitingState = .messageBegin
    var currentNameIndex: HTTPHeaderIndex?
    var currentHeaders: [HTTPHeader]
    var currentURI: URI?
    var currentStatus: String?
    var slice: (readerIndex: Int, length: Int)?
    // This is set before http_parser_execute(...) is called and set to nil again after it finish
    var baseAddress: UnsafeRawPointer?
    var currentError: HTTPParserError?
    var seenEOF = false
    var headerStartIndex: Int?
    
    // Holds the data we need to forward via ctx.fireChannelRead(...) after invoking the parser.
    var pendingInOut: NIOAny? = nil

    enum DataAwaitingState {
        case messageBegin
        case status
        case url
        case headerField
        case headerValue
        case body
    }

    init() {
        // We start with space for 16 headers.
        self.currentHeaders = []
        self.currentHeaders.reserveCapacity(16)
    }

    mutating func reset() {
        self.currentNameIndex = nil
        self.currentHeaders.removeAll(keepingCapacity: true)
        self.currentURI = nil
        self.currentStatus = nil
        self.slice = nil
        self.headerStartIndex = nil
        self.pendingInOut = nil
    }

    var cumulationBuffer: ByteBuffer?

    private mutating func consumeSlice() -> (readerIndex: Int, length: Int) {
        defer {
             self.slice = nil
        }
        return self.slice!
    }

    mutating func complete(state: DataAwaitingState) {
        switch state {
        case .messageBegin:
            assert(self.slice == nil, "non-empty slice on begin (\(self.slice!))")
            assert(self.currentNameIndex == nil, "non-empty currentNameIndex on begin (\(self.currentNameIndex!))")
            assert(self.currentHeaders.isEmpty, "non-empty headers on begin (\(self.currentHeaders))")
        case .headerField:
            assert(self.currentURI != nil || self.currentStatus != nil, "URI or Status not set before header field")
            assert(self.currentNameIndex == nil, "non-empty currentNameIndex on .headerField (\(self.currentNameIndex!))")
            let (index, length) = consumeSlice()
            self.currentNameIndex = HTTPHeaderIndex(start: index, length: length)
        case .headerValue:
            assert(self.currentURI != nil || self.currentStatus != nil, "URI or Status not set before header field")
            let (index, length) = consumeSlice()
            self.currentHeaders.append(HTTPHeader(name: self.currentNameIndex!, value: HTTPHeaderIndex(start: index, length: length)))
            self.currentNameIndex = nil
        case .url:
            assert(self.currentURI == nil)
            let (index, length) = consumeSlice()
            self.currentURI = .byteBuffer(self.cumulationBuffer!.getSlice(at: index, length: length)!)
        case .status:
            assert(self.currentStatus == nil)
            let (index, length) = consumeSlice()
            self.currentStatus = self.cumulationBuffer!.getString(at: index, length: length)!
        case .body:
            assert(self.currentNameIndex == nil, "non-empty currentNameIndex on .body (\(self.currentNameIndex!))")
            assert(self.slice == nil, "non-empty slice on .body (\(self.slice!))")
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
        self.init(leftOverBytesStrategy: .dropBytes)
    }

    /// Creates a new instance of `HttpRequestDecoder`.
    ///
    /// - parameters:
    ///     - leftOverBytesStrategy: the strategy to use when removing the decoder from the pipeline and an upgrade was detected
    public convenience init(leftOverBytesStrategy: RemoveAfterUpgradeStrategy) {
        self.init(type: HTTPServerRequestPart.self, leftOverBytesStrategy: leftOverBytesStrategy)
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
        self.init(type: HTTPClientResponsePart.self, leftOverBytesStrategy: .dropBytes)
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if case .head(let head) = unwrapOutboundIn(data) {
            methods.append(head.method)
        }

        ctx.write(data, promise: promise)
    }
}

/// Strategy to use when a HTTPDecoder is removed from a pipeline after a HTTP upgrade was detected.
public enum RemoveAfterUpgradeStrategy {
    /// Forward all the remaining bytes that are currently buffered in the deccoder to the next handler in the pipeline.
    case forwardBytes
    /// Discard all the remaining bytes that are currently buffered in the decoder.
    case dropBytes
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

    private let leftOverBytesStrategy: RemoveAfterUpgradeStrategy
    private var parser = http_parser()
    private var settings = http_parser_settings()

    fileprivate var state = HTTPParserState()

    fileprivate init(type: HTTPMessageT.Type, leftOverBytesStrategy: RemoveAfterUpgradeStrategy) {
        /* this is a private init, the public versions only allow HTTPClientResponsePart and HTTPServerRequestPart */
        assert(HTTPMessageT.self == HTTPClientResponsePart.self || HTTPMessageT.self == HTTPServerRequestPart.self)
        self.leftOverBytesStrategy = leftOverBytesStrategy
    }

    deinit {
        // Remove the stored reference to ChannelHandlerContext
        self.parser.data = UnsafeMutableRawPointer(bitPattern: 0xdeadbee)

        // Remove references to callbacks.
        self.settings = http_parser_settings()
    }

    /// The most recent method seen by request handlers.
    ///
    /// Naturally, in the base case this returns nil, as servers never issue requests!
    fileprivate func popRequestMethod() -> HTTPMethod? { return nil }

    private func newRequestHead(_ parser: UnsafeMutablePointer<http_parser>!) -> HTTPRequestHead {
        let method = HTTPMethod.from(httpParserMethod: http_method(rawValue: parser.pointee.method))
        let version = HTTPVersion(major: parser.pointee.http_major, minor: parser.pointee.http_minor)
        let request = HTTPRequestHead(version: version, method: method, rawURI: state.currentURI!, headers: HTTPHeaders(buffer: cumulationBuffer!, headers: state.currentHeaders, keepAliveState: parser.keepAliveState))
        self.state.currentHeaders.removeAll(keepingCapacity: true)
        return request
    }

    private func newResponseHead(_ parser: UnsafeMutablePointer<http_parser>!) -> HTTPResponseHead {
        let status = HTTPResponseStatus(statusCode: Int(parser.pointee.status_code), reasonPhrase: state.currentStatus!)
        let version = HTTPVersion(major: parser.pointee.http_major, minor: parser.pointee.http_minor)
        let response = HTTPResponseHead(version: version, status: status, headers: HTTPHeaders(buffer: cumulationBuffer!, headers: state.currentHeaders, keepAliveState: parser.keepAliveState))
        self.state.currentHeaders.removeAll(keepingCapacity: true)
        return response
    }

    private func bytesToForwardOnRemoval(ctx: ChannelHandlerContext) -> ByteBuffer? {
        guard self.leftOverBytesStrategy == .forwardBytes && self.parser.upgrade == 1 && ctx.channel.isActive else {
            return nil
        }
        // We take a slice of the cumulationBuffer so the next handler in the pipeline will just see the readable portion of the buffer.
        // While this is not strictly needed it may make it easier to consume.
        if let buffer = self.cumulationBuffer?.slice(), buffer.readableBytes > 0 {
            return buffer
        }
        return nil
    }

    public func handlerRemoved(ctx: ChannelHandlerContext) {
        if let buffer = self.bytesToForwardOnRemoval(ctx: ctx) {
            ctx.fireChannelRead(NIOAny(buffer))
        }
        self.cumulationBuffer = nil
    }
    
    public func decoderAdded(ctx: ChannelHandlerContext) {
        if HTTPMessageT.self == HTTPServerRequestPart.self {
            c_nio_http_parser_init(&self.parser, HTTP_REQUEST)
        } else if HTTPMessageT.self == HTTPClientResponsePart.self {
            c_nio_http_parser_init(&self.parser, HTTP_RESPONSE)
        } else {
            fatalError("the impossible happened: MsgT neither HTTPClientRequestPart nor HTTPClientResponsePart but \(HTTPMessageT.self)")
        }

        self.parser.data = Unmanaged.passUnretained(ctx).toOpaque()

        c_nio_http_parser_settings_init(&self.settings)

        self.settings.on_message_begin = { parser in
            let handler = evacuateHTTPDecoder(parser)
            handler.state.reset()

            return 0
        }

        self.settings.on_headers_complete = { parser in
            let ctx = evacuateChannelHandlerContext(parser)
            let handler = ctx.handler as! AnyHTTPDecoder

            // Ensure we pause the parser after this callback is complete so we can safely callout
            // to the pipeline.
            c_nio_http_parser_pause(parser, 1)
            assert(handler.state.pendingInOut == nil)

            handler.state.complete(state: handler.state.dataAwaitingState)
            handler.state.dataAwaitingState = .body

            switch handler {
            case let handler as HTTPRequestDecoder:
                let head = handler.newRequestHead(parser)
                guard head.version.major == 1 else {
                    handler.state.currentError = HTTPParserError.invalidVersion
                    return -1
                }

                handler.state.pendingInOut = handler.wrapInboundOut(HTTPServerRequestPart.head(head))
                return 0
            case let handler as HTTPResponseDecoder:
                let head = handler.newResponseHead(parser)
                guard head.version.major == 1 else {
                    handler.state.currentError = HTTPParserError.invalidVersion
                    return -1
                }

                handler.state.pendingInOut = handler.wrapInboundOut(HTTPClientResponsePart.head(head))

                // http_parser doesn't correctly handle responses to HEAD requests. We have to do something
                // annoyingly opaque here, and in those cases return 1 instead of 0. This forces http_parser
                // to not expect a request body.
                //
                // The same logic applies to CONNECT: RFC 7230 says that regardless of what the headers say,
                // responses to CONNECT never have HTTP-level bodies.
                //
                // Finally, we need to work around a bug in http_parser for 1XX, 204, and 304 responses.
                // RFC 7230 says:
                //
                // > ... any response with a 1xx (Informational),
                // > 204 (No Content), or 304 (Not Modified) status
                // > code is always terminated by the first empty line after the
                // > header fields, regardless of the header fields present in the
                // > message, and thus cannot contain a message body.
                //
                // However, http_parser only does this for responses that do not contain length fields. That
                // does not meet the requirement of RFC 7230. This is an outstanding http_parser issue:
                // https://github.com/nodejs/http-parser/issues/251. As a result, we check for these status
                // codes and override http_parser's handling as well.
                let method = handler.popRequestMethod()
                if method == .HEAD || method == .CONNECT {
                    return 1
                }

                if (head.status.code / 100 == 1 ||  // 1XX codes
                    head.status.code == 204 ||
                    head.status.code == 304) {
                    return 1
                }

                return 0
            default:
                fatalError("the impossible happened: handler neither a HTTPRequestDecoder nor a HTTPResponseDecoder which should be impossible")
            }
        }

        self.settings.on_body = { parser, data, len in
            let ctx = evacuateChannelHandlerContext(parser)
            let handler = ctx.handler as! AnyHTTPDecoder
            assert(handler.state.dataAwaitingState == .body)

            // Ensure we pause the parser after this callback is complete so we can safely callout
            // to the pipeline.
            c_nio_http_parser_pause(parser, 1)
            assert(handler.state.pendingInOut == nil)

            // Calculate the index of the data in the cumulationBuffer so we can slice out the ByteBuffer without doing any memory copy
            let index = handler.state.calculateIndex(data: data!, length: len)
            let slice = handler.state.cumulationBuffer!.getSlice(at: index, length: len)!
            switch handler {
            case let handler as HTTPRequestDecoder:
                handler.state.pendingInOut = handler.wrapInboundOut(HTTPServerRequestPart.body(slice))
            case let handler as HTTPResponseDecoder:
                handler.state.pendingInOut = handler.wrapInboundOut(HTTPClientResponsePart.body(slice))
            default:
                fatalError("the impossible happened: handler neither a HTTPRequestDecoder nor a HTTPResponseDecoder which should be impossible")
            }

            return 0
        }

        self.settings.on_header_field = { parser, data, len in
            let handler = evacuateHTTPDecoder(parser)

            switch handler.state.dataAwaitingState {
            case .status, .url, .body:
                // Record the starting of headers / trailers so we can discard read bytes easily if needed.
                handler.state.headerStartIndex = handler.state.calculateIndex(data: data!, length: len)
            default:
                break
            }
            handler.state.storeSlice(currentState: .headerField, data: data, len: len) { parserState, previousState in
                parserState.complete(state: previousState)
            }
            return 0
        }

        self.settings.on_header_value = { parser, data, len in
            let handler = evacuateHTTPDecoder(parser)

            handler.state.storeSlice(currentState: .headerValue, data: data, len: len) { parserState, previousState in
                parserState.complete(state: previousState)
            }
            return 0
        }

        self.settings.on_status = { parser, data, len in
            let handler = evacuateHTTPDecoder(parser)
            assert(handler is HTTPResponseDecoder)

            handler.state.storeSlice(currentState: .status, data: data, len: len) { parserState, previousState in
                assert(previousState == .messageBegin, "expected: messageBegin, actual: \(previousState)")
                parserState.complete(state: previousState)
            }
            return 0
        }

        self.settings.on_url = { parser, data, len in
            let handler = evacuateHTTPDecoder(parser)
            assert(handler is HTTPRequestDecoder)

            handler.state.storeSlice(currentState: .url, data: data, len: len) { parserState, previousState in
                assert(previousState == .messageBegin, "expected: messageBegin, actual: \(previousState)")
                parserState.complete(state: previousState)
            }
            return 0
        }

        self.settings.on_message_complete = { parser in
            let ctx = evacuateChannelHandlerContext(parser)
            let handler = ctx.handler as! AnyHTTPDecoder
            
            // Ensure we pause the parser after this callback is complete so we can safely callout
            // to the pipeline.
            c_nio_http_parser_pause(parser, 1)
            assert(handler.state.pendingInOut == nil)

            handler.state.complete(state: handler.state.dataAwaitingState)
            handler.state.dataAwaitingState = .messageBegin

            // Just use unknown for trailers as there is no point for anything else.
            let trailers = handler.state.currentHeaders.isEmpty ? nil : HTTPHeaders(buffer: handler.state.cumulationBuffer!, headers: handler.state.currentHeaders, keepAliveState: .unknown)
            handler.state.currentHeaders.removeAll(keepingCapacity: true)
            switch handler {
            case let handler as HTTPRequestDecoder:
                handler.state.pendingInOut = handler.wrapInboundOut(HTTPServerRequestPart.end(trailers))
            case let handler as HTTPResponseDecoder:
                handler.state.pendingInOut = handler.wrapInboundOut(HTTPClientResponsePart.end(trailers))
            default:
                fatalError("the impossible happened: handler neither a HTTPRequestDecoder nor a HTTPResponseDecoder which should be impossible")
            }
            return 0
        }
    }

    private func rethrowParserError() throws {
        // Rethrow any error
        if let error = self.state.currentError {
            throw error
        }

        if let parserError = self.currentParserError() {
            self.state.currentError = parserError
            throw parserError
        }
    }

    // Decode HTTP until there is nothing more to decode.
    private func decodeHTTP(ctx: ChannelHandlerContext) throws {
        // We need to refetch the cumulationBuffer on each loop as it may has changed due re-entrance calls of channelRead(...)
        while let bufferSlice = self.cumulationBuffer, bufferSlice.readableBytes > 0 {
            // we need to get `readerIndex` and `readableBytes` now because `withVeryUnsafeBytes` owns the
            // `ByteBuffer` exclusively.
            let readerIndex = bufferSlice.readerIndex
            let readableBytes = bufferSlice.readableBytes

            // Using withVeryUnsafeBytes here as this simplifies the calculation of the readerIndex which is relative to the baseAddress.
            let result = bufferSlice.withVeryUnsafeBytes { (pointer) -> size_t in
                self.state.baseAddress = pointer.baseAddress!
                defer {
                    self.state.baseAddress = nil
                }
                return c_nio_http_parser_execute_swift(&self.parser,
                                                       &self.settings,
                                                       pointer.baseAddress!.advanced(by: readerIndex),
                                                       readableBytes)
            }
            
            try self.rethrowParserError()

            c_nio_http_parser_pause(&self.parser, 0)

            // Update readerIndex of the cumulationBuffer itself as we will refetch it in the next loop run if needed.
            self.cumulationBuffer?.moveReaderIndex(forwardBy: result)
            
            self.firePendingInOut(ctx: ctx)
        }

        if self.state.seenEOF {
            // We need to notify the parser about the EOF as we received it while in http_parser_execute.
            self.notifyParserEOF(ctx: ctx)
        }
    }

    private func firePendingInOut(ctx: ChannelHandlerContext) {
        if let pending = self.state.pendingInOut {
            self.state.pendingInOut = nil
            ctx.fireChannelRead(pending)
        }
    }
    
    private func discardDecodedBytes() {
        guard self.cumulationBuffer != nil else {
            // Guard against the case of closing the channel. In this case the cumulationBuffer will be nil.
            return
        }


        switch self.state.dataAwaitingState {
        case .body, .messageBegin:
            assert(self.state.currentNameIndex == nil)
            assert(self.state.currentHeaders.isEmpty)
            assert(self.state.slice == nil)
            
            if self.cumulationBuffer!.readableBytes == 0 {
                // It's safe to just drop the cumulationBuffer as we don't have any extra views into it that are represented as readerIndex / length.
                self.cumulationBuffer = nil
            }

        case .headerField, .headerValue:
            guard let headerStartIdx = self.state.headerStartIndex else {
                return
            }

            self.mayDiscardDecodedBytes(upTo: headerStartIdx) {
                // Reset the previous stored index that marks the start of the headers / trailers as we will adjust indices now.
                self.state.headerStartIndex = nil

                // We need to adjust the stored slice, currentNameIndex and also all the previous stored headers to reflect the new readerIndex after we discarded the bytes.
                if let slice = self.state.slice {
                    self.state.slice = (readerIndex: slice.readerIndex - headerStartIdx, slice.length)
                }

                func adjustedHeaderIndex(_ idx: HTTPHeaderIndex) -> HTTPHeaderIndex {
                    return HTTPHeaderIndex(start: idx.start - headerStartIdx, length: idx.length)
                }

                if let idx = self.state.currentNameIndex {
                    self.state.currentNameIndex = adjustedHeaderIndex(idx)
                }

                if !self.state.currentHeaders.isEmpty {
                    self.state.currentHeaders = self.state.currentHeaders.map { HTTPHeader(name: adjustedHeaderIndex($0.name), value: adjustedHeaderIndex($0.value)) }
                }
            }

        case .status, .url:
            assert(self.state.headerStartIndex == nil)
            if let slice = self.state.slice {
                self.mayDiscardDecodedBytes(upTo: slice.readerIndex) {
                    // We discarded everything before the slice so the slice now starts at index 0.
                    self.state.slice = (readerIndex: 0, slice.length)
                }
            }
        }
    }

    /// Will discard bytes till readerIndex if it's needed and then call `fn`.
    private func mayDiscardDecodedBytes(upTo: Int, _ fn: () -> Void) {
        assert(self.cumulationBuffer!.readerIndex == self.cumulationBuffer!.writerIndex)
        self.cumulationBuffer!.moveReaderIndex(to: upTo)
        if self.shouldReclaimBytes(buffer: self.cumulationBuffer!) && self.cumulationBuffer!.discardReadBytes() {
            // When discardReadBytes() returns true the readerIndex must be 0 again.
            assert(self.cumulationBuffer!.readerIndex == 0)

            fn()
        }

        self.cumulationBuffer!.moveReaderIndex(to: self.cumulationBuffer!.writerIndex)
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var buffer = self.unwrapInboundIn(data)

        // Either use the received buffer directly or merge it into the already existing cumulationBuffer.
        if self.cumulationBuffer == nil {
            self.cumulationBuffer = buffer
        } else {
            self.cumulationBuffer!.write(buffer: &buffer)
        }

        do {
            try self.decodeHTTP(ctx: ctx)
            self.discardDecodedBytes()
        } catch {
            self.cumulationBuffer = nil
            ctx.fireErrorCaught(error)
            ctx.close(promise: nil)
        }
    }

    /// This method should not be called and will be removed in the future
    public func decode(ctx: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        return DecodingState.needMoreData
    }

    public func channelReadComplete(ctx: ChannelHandlerContext) {
        ctx.fireChannelReadComplete()
    }

    public func channelInactive(ctx: ChannelHandlerContext) {
        self.readEOF(ctx: ctx)
        ctx.fireChannelInactive()
    }

    public func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        if case .some(.inputClosed) = event as? ChannelEvent {
            self.readEOF(ctx: ctx)
        }
        ctx.fireUserInboundEventTriggered(event)
    }

    public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        ctx.fireErrorCaught(error)
        if error is HTTPParserError {
            ctx.close(promise: nil)
        }
    }

    private func readEOF(ctx: ChannelHandlerContext) {
        guard self.state.currentError == nil else {
            // We're in readEOF because we hit an error and closed the connection.
            // No need to do this dance again, just return.
            return
        }

        guard !self.state.seenEOF else {
            // We're in readEOF but we have already processed it once for this connection.
            // Probably this is a channelInactive after half closure, but either way we
            // shouldn't tell http_parser about this again or it'll send us on_message_complete
            // again.
            return
        }

        // EOF is semantic in HTTP, so we need to tell the parser that we saw it.
        // We need to be a bit careful: the parser can call out to us, but should only
        // ever call on_message_complete, which won't do a read. As a result, it *should*
        // be totally safe to call this with a null data pointer. Just to make sure, though,
        // let's store nil in the base address. Once we've called this, we've seenEOF: don't
        // let us enter this function again.
        self.state.seenEOF = true

        self.notifyParserEOF(ctx: ctx)
    }

    private func notifyParserEOF(ctx: ChannelHandlerContext) {
        self.state.baseAddress = nil
        _ = c_nio_http_parser_execute(&self.parser, &self.settings, nil, 0)

        // We don't need the cumulation buffer, if we're holding it.
        self.cumulationBuffer = nil
        
        self.firePendingInOut(ctx: ctx)
        
        // No check to state.currentError because, if we hit it before, we already threw that
        // error. This never calls any of the callbacks that set that field anyway. Instead we
        // just check if the errno is set and throw.
        if let parserError = self.currentParserError() {
            self.state.currentError = parserError
            ctx.fireErrorCaught(parserError)
        }
    }
    
    private func currentParserError() -> HTTPParserError? {
        let httpError = self.parser.http_errno
        // Also take into account that we may have called c_nio_http_parser_pause(...)
        guard httpError != HPE_PAUSED.rawValue && httpError != 0 else {
            return nil
        }
        return HTTPParserError.httpError(fromCHTTPParserErrno: http_errno(rawValue: httpError))!
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
        case HTTP_SOURCE:
            // This isn't ideal really.
            return .RAW(value: "SOURCE")
        default:
            fatalError("Unexpected http_method \(httpParserMethod)")
        }
    }
}
