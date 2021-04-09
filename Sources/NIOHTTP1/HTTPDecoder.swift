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
#if compiler(>=5.1)
@_implementationOnly import CNIOHTTPParser
#else
import CNIOHTTPParser
#endif

private extension UnsafeMutablePointer where Pointee == http_parser {
    /// Returns the `KeepAliveState` for the current message that is parsed.
    var keepAliveState: KeepAliveState {
        return c_nio_http_should_keep_alive(self) == 0 ? .close : .keepAlive
    }
}

private enum HTTPDecodingState {
    case beforeMessageBegin
    case afterMessageBegin
    case url
    case headerName
    case headerValue
    case trailerName
    case trailerValue
    case headersComplete
}

private class BetterHTTPParser {
    var delegate: HTTPDecoderDelegate! = nil
    private var parser: http_parser? = http_parser() // nil if unaccessible because reference passed away exclusively
    private var settings = http_parser_settings()
    private var decodingState: HTTPDecodingState = .beforeMessageBegin
    private var firstNonDiscardableOffset: Int? = nil
    private var currentFieldByteLength = 0
    private var httpParserOffset = 0
    private var rawBytesView: UnsafeRawBufferPointer = .init(start: UnsafeRawPointer(bitPattern: 0xcafbabe), count: 0)
    private var httpErrno: http_errno? = nil
    private var richerError: Error? = nil
    private let kind: HTTPDecoderKind
    var requestHeads = CircularBuffer<HTTPRequestHead>(initialCapacity: 1)

    enum MessageContinuation {
        case normal
        case skipBody
        case error(http_errno)
    }

    private static func fromOpaque(_ opaque: UnsafePointer<http_parser>?) -> BetterHTTPParser {
        return Unmanaged<BetterHTTPParser>.fromOpaque(UnsafeRawPointer(opaque!.pointee.data)).takeUnretainedValue()
    }

    init(kind: HTTPDecoderKind) {
        self.kind = kind
        c_nio_http_parser_settings_init(&self.settings)
        self.withExclusiveHTTPParser { parserPtr in
            switch kind {
            case .request:
                c_nio_http_parser_init(parserPtr, HTTP_REQUEST)
            case .response:
                c_nio_http_parser_init(parserPtr, HTTP_RESPONSE)
            }
        }
        self.settings.on_body = { opaque, bytes, len in
            BetterHTTPParser.fromOpaque(opaque).didReceiveBodyData(UnsafeRawBufferPointer(start: bytes, count: len))
            return 0
        }
        self.settings.on_header_field = { opaque, bytes, len in
            BetterHTTPParser.fromOpaque(opaque).didReceiveHeaderFieldData(UnsafeRawBufferPointer(start: bytes, count: len))
            return 0
        }
        self.settings.on_header_value = { opaque, bytes, len in
            BetterHTTPParser.fromOpaque(opaque).didReceiveHeaderValueData(UnsafeRawBufferPointer(start: bytes, count: len))
            return 0
        }
        self.settings.on_status = { opaque, bytes, len in
            BetterHTTPParser.fromOpaque(opaque).didReceiveStatusData(UnsafeRawBufferPointer(start: bytes, count: len))
            return 0
        }
        self.settings.on_url = { opaque, bytes, len in
            BetterHTTPParser.fromOpaque(opaque).didReceiveURLData(UnsafeRawBufferPointer(start: bytes, count: len))
            return 0
        }
        self.settings.on_chunk_complete = { opaque in
            BetterHTTPParser.fromOpaque(opaque).didReceiveChunkCompleteNotification()
            return 0
        }
        self.settings.on_chunk_header = { opaque in
            BetterHTTPParser.fromOpaque(opaque).didReceiveChunkHeaderNotification()
            return 0
        }
        self.settings.on_message_begin = { opaque in
            BetterHTTPParser.fromOpaque(opaque).didReceiveMessageBeginNotification()
            return 0
        }
        self.settings.on_headers_complete = { opaque in
            let parser = BetterHTTPParser.fromOpaque(opaque)
            switch parser.didReceiveHeadersCompleteNotification(versionMajor: Int(opaque!.pointee.http_major),
                                                                versionMinor: Int(opaque!.pointee.http_minor),
                                                                statusCode: Int(opaque!.pointee.status_code),
                                                                isUpgrade: opaque!.pointee.upgrade != 0,
                                                                method: http_method(rawValue: opaque!.pointee.method),
                                                                keepAliveState: opaque!.keepAliveState) {
            case .normal:
                return 0
            case .skipBody:
                return 1
            case .error(let err):
                parser.httpErrno = err
                return -1 // error
            }
        }
        self.settings.on_message_complete = { opaque in
            BetterHTTPParser.fromOpaque(opaque).didReceiveMessageCompleteNotification()
            return 0
        }
    }

    private func start(bytes: UnsafeRawBufferPointer, newState: HTTPDecodingState) {
        assert(self.firstNonDiscardableOffset == nil)
        self.firstNonDiscardableOffset = bytes.baseAddress! - self.rawBytesView.baseAddress!
        self.decodingState = newState
    }

    private func finish(_ callout: (inout HTTPDecoderDelegate, UnsafeRawBufferPointer) -> Void) {
        var currentFieldByteLength = 0
        swap(&currentFieldByteLength, &self.currentFieldByteLength)
        let start = self.rawBytesView.startIndex + self.firstNonDiscardableOffset!
        let end = start + currentFieldByteLength
        self.firstNonDiscardableOffset = nil
        precondition(start >= self.rawBytesView.startIndex && end <= self.rawBytesView.endIndex)
        callout(&self.delegate, .init(rebasing: self.rawBytesView[start ..< end]))
    }

    private func didReceiveBodyData(_ bytes: UnsafeRawBufferPointer) {
        self.delegate.didReceiveBody(bytes)
    }

    private func didReceiveHeaderFieldData(_ bytes: UnsafeRawBufferPointer) {
        switch self.decodingState {
        case .headerName, .trailerName:
            ()
        case .headerValue:
            self.finish { delegate, bytes in
                delegate.didReceiveHeaderValue(bytes)
            }
            self.start(bytes: bytes, newState: .headerName)
        case .trailerValue:
            self.finish { delegate, bytes in
                delegate.didReceiveTrailerValue(bytes)
            }
            self.start(bytes: bytes, newState: .trailerName)
        case .url:
            self.finish { delegate, bytes in
                delegate.didReceiveURL(bytes)
            }
            self.start(bytes: bytes, newState: .headerName)
        case .headersComplete:
            // these are trailers
            self.start(bytes: bytes, newState: .trailerName)
        case .afterMessageBegin:
            // in case we're parsing responses
            self.start(bytes: bytes, newState: .headerName)
        case .beforeMessageBegin:
            preconditionFailure()
        }
        self.currentFieldByteLength += bytes.count
    }

    private func didReceiveHeaderValueData(_ bytes: UnsafeRawBufferPointer) {
        switch self.decodingState {
        case .headerValue, .trailerValue:
            ()
        case .headerName:
            self.finish { delegate, bytes in
                delegate.didReceiveHeaderName(bytes)
            }
            self.start(bytes: bytes, newState: .headerValue)
        case .trailerName:
            self.finish { delegate, bytes in
                delegate.didReceiveTrailerName(bytes)
            }
            self.start(bytes: bytes, newState: .trailerValue)
        case .beforeMessageBegin, .afterMessageBegin, .headersComplete, .url:
            preconditionFailure()
        }
        self.currentFieldByteLength += bytes.count
    }

    private func didReceiveStatusData(_ bytes: UnsafeRawBufferPointer) {
        // we don't do anything special here because we'll need the whole 'head' anyway
    }

    private func didReceiveURLData(_ bytes: UnsafeRawBufferPointer) {
        switch self.decodingState {
        case .url:
            ()
        case .afterMessageBegin:
            self.start(bytes: bytes, newState: .url)
        case .beforeMessageBegin, .headersComplete, .headerName, .headerValue, .trailerName, .trailerValue:
            preconditionFailure()
        }
        self.currentFieldByteLength += bytes.count
    }

    private func didReceiveChunkCompleteNotification() {
        // nothing special to do, we handle chunks just like any other body part
    }

    private func didReceiveChunkHeaderNotification() {
        // nothing special to do, we handle chunks just like any other body part
    }

    private func didReceiveMessageBeginNotification() {
        switch self.decodingState {
        case .beforeMessageBegin:
            self.decodingState = .afterMessageBegin
        case .headersComplete, .headerName, .headerValue, .trailerName, .trailerValue, .afterMessageBegin, .url:
            preconditionFailure()
        }
    }

    private func didReceiveMessageCompleteNotification() {
        switch self.decodingState {
        case .headersComplete:
            ()
        case .trailerValue:
            self.finish { delegate, bytes in
                delegate.didReceiveTrailerValue(bytes)
            }
        case .beforeMessageBegin, .headerName, .headerValue, .trailerName, .afterMessageBegin, .url:
            preconditionFailure()
        }
        self.decodingState = .beforeMessageBegin
        self.delegate.didFinishMessage()
    }

    private func didReceiveHeadersCompleteNotification(versionMajor: Int,
                                                       versionMinor: Int,
                                                       statusCode: Int,
                                                       isUpgrade: Bool,
                                                       method: http_method,
                                                       keepAliveState: KeepAliveState) -> MessageContinuation {
        switch self.decodingState {
        case .headerValue:
            self.finish { delegate, bytes in
                delegate.didReceiveHeaderValue(bytes)
            }
        case .url:
            self.finish { delegate, bytes in
                delegate.didReceiveURL(bytes)
            }
        case .afterMessageBegin:
            // we're okay here for responses (as they don't have URLs) but for requests we must have seen a URL/headers
            precondition(self.kind == .response)
        case .beforeMessageBegin, .headersComplete, .headerName, .trailerName, .trailerValue:
            preconditionFailure()
        }
        assert(self.firstNonDiscardableOffset == nil)
        self.decodingState = .headersComplete

        var skipBody = false

        if self.kind == .response {
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
            guard let method = self.requestHeads.popFirst()?.method else {
                self.richerError = NIOHTTPDecoderError.unsolicitedResponse
                return .error(HPE_UNKNOWN)
            }

            if method == .HEAD || method == .CONNECT {
                skipBody = true
            } else if statusCode / 100 == 1 ||  // 1XX codes
                statusCode == 204 || statusCode == 304 {
                skipBody = true
            }
        }

        let success = self.delegate.didFinishHead(versionMajor: versionMajor,
                                                  versionMinor: versionMinor,
                                                  isUpgrade: isUpgrade,
                                                  method: method,
                                                  statusCode: statusCode,
                                                  keepAliveState: keepAliveState)
        guard success else {
            return .error(HPE_INVALID_VERSION)
        }

        return skipBody ? .skipBody : .normal
    }

    func start() {
        self.withExclusiveHTTPParser { parserPtr in
            parserPtr.pointee.data = Unmanaged.passRetained(self).toOpaque()
        }
    }

    func stop() {
        self.withExclusiveHTTPParser { parserPtr in
            let selfRef = parserPtr.pointee.data
            Unmanaged<BetterHTTPParser>.fromOpaque(selfRef!).release()
            parserPtr.pointee.data = UnsafeMutableRawPointer(bitPattern: 0xdedbeef)
        }
    }

    @inline(__always) // this need to be optimised away
    func withExclusiveHTTPParser<T>(_ body: (UnsafeMutablePointer<http_parser>) -> T) -> T {
        var parser: http_parser? = nil
        assert(self.parser != nil, "parser must not be nil here, must be a re-entrancy issue")
        swap(&parser, &self.parser)
        defer {
            assert(self.parser == nil, "parser must not nil here")
            swap(&parser, &self.parser)
        }
        return body(&parser!)
    }

    func feedInput(_ bytes: UnsafeRawBufferPointer?) throws -> Int {
        var parserErrno: UInt32 = 0
        let parserConsumed = self.withExclusiveHTTPParser { parserPtr -> Int in
            let parserResult: Int
            if let bytes = bytes {
                self.rawBytesView = bytes
                defer {
                    self.rawBytesView = .init(start: UnsafeRawPointer(bitPattern: 0xdafbabe), count: 0)
                }
                parserResult = c_nio_http_parser_execute_swift(parserPtr,
                                                               &self.settings,
                                                               bytes.baseAddress! + self.httpParserOffset,
                                                               bytes.count - self.httpParserOffset)
            } else {
                parserResult = c_nio_http_parser_execute(parserPtr, &self.settings, nil, 0)
            }
            parserErrno = parserPtr.pointee.http_errno
            return parserResult
        }
        assert(parserConsumed >= 0)
        // self.parser must be non-nil here because we can't be re-entered here (ByteToMessageDecoder guarantee)
        guard parserErrno == 0 else {
            // if we chose to abort (eg. wrong HTTP version) the error will be in self.httpErrno, otherwise http_parser
            // will tell us...
            // self.parser must be non-nil here because we can't be re-entered here (ByteToMessageDecoder guarantee)
            // If we have a richer error than the errno code, and the errno is unknown, we'll use it. Otherwise, we use the
            // error from http_parser.
            let err = self.httpErrno ?? http_errno(rawValue: parserErrno)
            if err == HPE_UNKNOWN, let richerError = self.richerError {
                throw richerError
            } else {
                throw HTTPParserError.httpError(fromCHTTPParserErrno: err)!
            }
        }
        if let firstNonDiscardableOffset = self.firstNonDiscardableOffset {
            self.httpParserOffset += parserConsumed - firstNonDiscardableOffset
            self.firstNonDiscardableOffset = 0
            return firstNonDiscardableOffset
        } else {
            // By definition we've consumed all of the http parser offset at this stage. There may still be bytes
            // left in the buffer though: we didn't consume them because they aren't ours to consume, as they may belong
            // to an upgraded protocol.
            //
            // Set the HTTP parser offset back to zero, and tell the parent that we consumed
            // the whole buffer.
            let consumedBytes = self.httpParserOffset + parserConsumed
            self.httpParserOffset = 0
            return consumedBytes
        }
    }
}

private protocol HTTPDecoderDelegate {
    mutating func didReceiveBody(_ bytes: UnsafeRawBufferPointer)
    mutating func didReceiveHeaderName(_ bytes: UnsafeRawBufferPointer)
    mutating func didReceiveHeaderValue(_ bytes: UnsafeRawBufferPointer)
    mutating func didReceiveTrailerName(_ bytes: UnsafeRawBufferPointer)
    mutating func didReceiveTrailerValue(_ bytes: UnsafeRawBufferPointer)
    mutating func didReceiveURL(_ bytes: UnsafeRawBufferPointer)
    mutating func didFinishHead(versionMajor: Int,
                                versionMinor: Int,
                                isUpgrade: Bool,
                                method: http_method,
                                statusCode: Int,
                                keepAliveState: KeepAliveState) -> Bool
    mutating func didFinishMessage()
}

/// A `ByteToMessageDecoder` used to decode HTTP/1.x responses. See the documentation
/// on `HTTPDecoder` for more.
///
/// The `HTTPResponseDecoder` must be placed later in the channel pipeline than the `HTTPRequestEncoder`,
/// as it needs to see the outbound messages in order to keep track of what the HTTP request methods
/// were for accurate decoding.
///
/// Rather than set this up manually, consider using `ChannelPipeline.addHTTPClientHandlers`.
public typealias HTTPResponseDecoder = HTTPDecoder<HTTPClientResponsePart, HTTPClientRequestPart>

/// A `ByteToMessageDecoder` used to decode HTTP requests. See the documentation
/// on `HTTPDecoder` for more.
///
/// While the `HTTPRequestDecoder` does not currently have a specific ordering requirement in the
/// `ChannelPipeline` (unlike `HTTPResponseDecoder`), it is possible that it will develop one. For
/// that reason, applications should try to ensure that the `HTTPRequestDecoder` *later* in the
/// `ChannelPipeline` than the `HTTPResponseEncoder`.
///
/// Rather than set this up manually, consider using `ChannelPipeline.configureHTTPServerPipeline`.
public typealias HTTPRequestDecoder = HTTPDecoder<HTTPServerRequestPart, HTTPServerResponsePart>

public enum HTTPDecoderKind {
    case request
    case response
}

extension HTTPDecoder: WriteObservingByteToMessageDecoder where In == HTTPClientResponsePart, Out == HTTPClientRequestPart {
    public typealias OutboundIn = Out

    public func write(data: HTTPClientRequestPart) {
        if case .head(let head) = data {
            self.parser.requestHeads.append(head)
        }
    }
}

/// A `ChannelInboundHandler` that parses HTTP/1-style messages, converting them from
/// unstructured bytes to a sequence of HTTP messages.
///
/// The `HTTPDecoder` is a generic channel handler which can produce messages in
/// either the form of `HTTPClientResponsePart` or `HTTPServerRequestPart`: that is,
/// it produces messages that correspond to the semantic units of HTTP produced by
/// the remote peer.
public final class HTTPDecoder<In, Out>: ByteToMessageDecoder, HTTPDecoderDelegate {
    public typealias InboundOut = In

    // things we build incrementally
    private var headers: [(String, String)] = []
    private var trailers: [(String, String)]? = nil
    private var currentHeaderName: String? = nil
    private var url: String? = nil
    private var isUpgrade: Bool? = nil

    // temporary, set and unset by `feedInput`
    private var buffer: ByteBuffer? = nil
    private var context: ChannelHandlerContext? = nil

    // the actual state
    private let parser: BetterHTTPParser
    private let leftOverBytesStrategy: RemoveAfterUpgradeStrategy
    private let kind: HTTPDecoderKind
    private var stopParsing = false // set on upgrade or HTTP version error

    /// Creates a new instance of `HTTPDecoder`.
    ///
    /// - parameters:
    ///     - leftOverBytesStrategy: The strategy to use when removing the decoder from the pipeline and an upgrade was,
    ///                              detected. Note that this does not affect what happens on EOF.
    public init(leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes) {
        self.headers.reserveCapacity(16)
        if In.self == HTTPServerRequestPart.self {
            self.kind = .request
        } else if In.self == HTTPClientResponsePart.self {
            self.kind = .response
        } else {
            preconditionFailure("unknown HTTP message type \(In.self)")
        }
        self.parser = BetterHTTPParser(kind: kind)
        self.leftOverBytesStrategy = leftOverBytesStrategy
    }

    func didReceiveBody(_ bytes: UnsafeRawBufferPointer) {
        let offset = self.buffer!.withUnsafeReadableBytes { allBytes -> Int in
            let offset = bytes.baseAddress! - allBytes.baseAddress!
            assert(offset >= 0)
            assert(offset + bytes.count <= allBytes.count)
            return offset
        }
        self.buffer!.moveReaderIndex(forwardBy: offset)
        switch self.kind {
        case .request:
            self.context!.fireChannelRead(NIOAny(HTTPServerRequestPart.body(self.buffer!.readSlice(length: bytes.count)!)))
        case .response:
            self.context!.fireChannelRead(NIOAny(HTTPClientResponsePart.body(self.buffer!.readSlice(length: bytes.count)!)))
        }

    }

    func didReceiveHeaderName(_ bytes: UnsafeRawBufferPointer) {
        assert(self.currentHeaderName == nil)
        self.currentHeaderName = String(decoding: bytes, as: Unicode.UTF8.self)
    }

    func didReceiveHeaderValue(_ bytes: UnsafeRawBufferPointer) {
        self.headers.append((self.currentHeaderName!, String(decoding: bytes, as: Unicode.UTF8.self)))
        self.currentHeaderName = nil
    }

    func didReceiveTrailerName(_ bytes: UnsafeRawBufferPointer) {
        assert(self.currentHeaderName == nil)
        self.currentHeaderName = String(decoding: bytes, as: Unicode.UTF8.self)
    }

    func didReceiveTrailerValue(_ bytes: UnsafeRawBufferPointer) {
        if self.trailers == nil {
            self.trailers = []
        }
        self.trailers?.append((self.currentHeaderName!, String(decoding: bytes, as: Unicode.UTF8.self)))
        self.currentHeaderName = nil
    }

    func didReceiveURL(_ bytes: UnsafeRawBufferPointer) {
        assert(self.url == nil)
        self.url = String(decoding: bytes, as: Unicode.UTF8.self)
    }

    func didFinishHead(versionMajor: Int,
                       versionMinor: Int,
                       isUpgrade: Bool,
                       method: http_method,
                       statusCode: Int,
                       keepAliveState: KeepAliveState) -> Bool {
        let message: NIOAny

        guard versionMajor == 1 else {
            self.stopParsing = true
            self.context!.fireErrorCaught(HTTPParserError.invalidVersion)
            return false
        }

        switch self.kind {
        case .request:
            let reqHead = HTTPRequestHead(version: .init(major: versionMajor, minor: versionMinor),
                                          method: HTTPMethod.from(httpParserMethod: method),
                                          uri: self.url!,
                                          headers: HTTPHeaders(self.headers,
                                                               keepAliveState: keepAliveState))
            message = NIOAny(HTTPServerRequestPart.head(reqHead))
        case .response:
            let resHead: HTTPResponseHead = HTTPResponseHead(version: .init(major: versionMajor, minor: versionMinor),
                                                             status: .init(statusCode: statusCode),
                                                             headers: HTTPHeaders(self.headers,
                                                                                  keepAliveState: keepAliveState))
            message = NIOAny(HTTPClientResponsePart.head(resHead))
        }
        self.url = nil
        self.headers.removeAll(keepingCapacity: true)
        self.context!.fireChannelRead(message)
        self.isUpgrade = isUpgrade
        return true
    }

    func didFinishMessage() {
        var trailers: [(String, String)]? = nil
        swap(&trailers, &self.trailers)
        switch self.kind {
        case .request:
            self.context!.fireChannelRead(NIOAny(HTTPServerRequestPart.end(trailers.map(HTTPHeaders.init))))
        case .response:
            self.context!.fireChannelRead(NIOAny(HTTPClientResponsePart.end(trailers.map(HTTPHeaders.init))))
        }
        self.stopParsing = self.isUpgrade!
        self.isUpgrade = nil
    }

    public func decoderAdded(context: ChannelHandlerContext) {
        self.parser.delegate = self
        self.parser.start()
    }

    public func decoderRemoved(context: ChannelHandlerContext) {
        self.parser.stop()
        self.parser.delegate = nil
    }

    private func feedEOF(context: ChannelHandlerContext) throws {
        self.context = context
        defer {
            self.context = nil
        }
        // we don't care how much http_parser consumed here because we just fed an EOF so there won't be any more data.
        _ = try self.parser.feedInput(nil)
    }

    private func feedInput(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws {
        self.buffer = buffer
        self.context = context
        defer {
            self.buffer = nil
            self.context = nil
        }
        let consumed = try buffer.withUnsafeReadableBytes { bytes -> Int in
            try self.parser.feedInput(bytes)
        }
        buffer.moveReaderIndex(forwardBy: consumed)
    }

    public func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if !self.stopParsing {
            try self.feedInput(context: context, buffer: &buffer)
        }
        return .needMoreData
    }

    public func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        if !self.stopParsing {
            while buffer.readableBytes > 0, case .continue = try self.decode(context: context, buffer: &buffer) {}
            if seenEOF {
                try self.feedEOF(context: context)
            }
        }
        if buffer.readableBytes > 0 && !seenEOF {
            // We only do this if we haven't seen EOF because the left-overs strategy must only be invoked when we're
            // sure that this is the completion of an upgrade.
            switch self.leftOverBytesStrategy {
            case .dropBytes:
                ()
            case .fireError:
                context.fireErrorCaught(ByteToMessageDecoderError.leftoverDataWhenDone(buffer))
            case .forwardBytes:
                context.fireChannelRead(NIOAny(buffer))
            }
        }
        return .needMoreData
    }
}

/// Strategy to use when a HTTPDecoder is removed from a pipeline after a HTTP upgrade was detected.
public enum RemoveAfterUpgradeStrategy {
    /// Forward all the remaining bytes that are currently buffered in the deccoder to the next handler in the pipeline.
    case forwardBytes
    /// Fires a `ByteToMessageDecoder.leftoverDataWhenDone` error through the pipeline
    case fireError
    /// Discard all the remaining bytes that are currently buffered in the decoder.
    case dropBytes
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
        case HPE_INVALID_TRANSFER_ENCODING:
            // The downside of enums here, we don't have a case for this. Map it to .unknown for now.
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


/// Errors thrown by `HTTPRequestDecoder` and `HTTPResponseDecoder` in addition to
/// `HTTPParserError`.
public struct NIOHTTPDecoderError: Error {
    private enum BaseError: Hashable {
        case unsolicitedResponse
    }

    private let baseError: BaseError
}


extension NIOHTTPDecoderError {
    /// A response was received from a server without an associated request having been sent.
    public static let unsolicitedResponse: NIOHTTPDecoderError = .init(baseError: .unsolicitedResponse)
}


extension NIOHTTPDecoderError: Hashable { }


extension NIOHTTPDecoderError: CustomDebugStringConvertible {
    public var debugDescription: String {
        return String(describing: self.baseError)
    }
}
