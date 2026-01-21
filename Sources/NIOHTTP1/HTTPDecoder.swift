//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

#if compiler(>=6.1)
private import CNIOLLHTTP
#else
@_implementationOnly import CNIOLLHTTP
#endif

extension UnsafeMutablePointer where Pointee == llhttp_t {
    /// Returns the `KeepAliveState` for the current message that is parsed.
    fileprivate var keepAliveState: KeepAliveState {
        c_nio_llhttp_should_keep_alive(self) == 0 ? .close : .keepAlive
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
    /// Maximum size of a HTTP header field name or value.
    /// This number is derived largely from the historical behaviour of NIO.
    private static let maximumHeaderFieldSize = 80 * 1024

    var delegate: HTTPDecoderDelegate! = nil
    private var parser: llhttp_t? = llhttp_t()  // nil if unaccessible because reference passed away exclusively
    private var settings: UnsafeMutablePointer<llhttp_settings_t>
    private var decodingState: HTTPDecodingState = .beforeMessageBegin
    private var firstNonDiscardableOffset: Int? = nil
    private var currentFieldByteLength = 0
    private var httpParserOffset = 0
    private var rawBytesView: UnsafeRawBufferPointer = .init(start: UnsafeRawPointer(bitPattern: 0xcafbabe), count: 0)
    private var httpErrno: llhttp_errno_t? = nil
    private var richerError: Error? = nil
    private let kind: HTTPDecoderKind
    var requestHeads = CircularBuffer<HTTPRequestHead>(initialCapacity: 1)

    enum MessageContinuation {
        case normal
        case skipBody
        case error(llhttp_errno_t)
    }

    private static func fromOpaque(_ opaque: UnsafePointer<llhttp_t>?) -> BetterHTTPParser {
        Unmanaged<BetterHTTPParser>.fromOpaque(UnsafeRawPointer(opaque!.pointee.data)).takeUnretainedValue()
    }

    init(kind: HTTPDecoderKind) {
        self.kind = kind
        self.settings = UnsafeMutablePointer.allocate(capacity: 1)
        c_nio_llhttp_settings_init(self.settings)
        self.settings.pointee.on_body = { opaque, bytes, len in
            BetterHTTPParser.fromOpaque(opaque).didReceiveBodyData(UnsafeRawBufferPointer(start: bytes, count: len))
            return 0
        }
        self.settings.pointee.on_header_field = { opaque, bytes, len in
            BetterHTTPParser.fromOpaque(opaque).didReceiveHeaderFieldData(
                UnsafeRawBufferPointer(start: bytes, count: len)
            )
        }
        self.settings.pointee.on_header_value = { opaque, bytes, len in
            BetterHTTPParser.fromOpaque(opaque).didReceiveHeaderValueData(
                UnsafeRawBufferPointer(start: bytes, count: len)
            )
        }
        self.settings.pointee.on_status = { opaque, bytes, len in
            BetterHTTPParser.fromOpaque(opaque).didReceiveStatusData(UnsafeRawBufferPointer(start: bytes, count: len))
            return 0
        }
        self.settings.pointee.on_url = { opaque, bytes, len in
            BetterHTTPParser.fromOpaque(opaque).didReceiveURLData(UnsafeRawBufferPointer(start: bytes, count: len))
        }
        self.settings.pointee.on_chunk_complete = { opaque in
            BetterHTTPParser.fromOpaque(opaque).didReceiveChunkCompleteNotification()
            return 0
        }
        self.settings.pointee.on_chunk_header = { opaque in
            BetterHTTPParser.fromOpaque(opaque).didReceiveChunkHeaderNotification()
            return 0
        }
        self.settings.pointee.on_message_begin = { opaque in
            BetterHTTPParser.fromOpaque(opaque).didReceiveMessageBeginNotification()
            return 0
        }
        self.settings.pointee.on_headers_complete = { opaque in
            let parser = BetterHTTPParser.fromOpaque(opaque)
            switch parser.didReceiveHeadersCompleteNotification(
                versionMajor: Int(opaque!.pointee.http_major),
                versionMinor: Int(opaque!.pointee.http_minor),
                statusCode: Int(opaque!.pointee.status_code),
                isUpgrade: opaque!.pointee.upgrade != 0,
                method: llhttp_method(rawValue: numericCast(opaque!.pointee.method)),
                keepAliveState: opaque!.keepAliveState
            ) {
            case .normal:
                return 0
            case .skipBody:
                return 1
            case .error(let err):
                parser.httpErrno = err
                return -1  // error
            }
        }
        self.settings.pointee.on_message_complete = { opaque in
            BetterHTTPParser.fromOpaque(opaque).didReceiveMessageCompleteNotification()
            // Temporary workaround for https://github.com/nodejs/llhttp/issues/202, should be removed
            // when that issue is fixed. We're tracking the work in https://github.com/apple/swift-nio/issues/2274.
            opaque?.pointee.content_length = 0
            return 0
        }
        self.withExclusiveHTTPParser { parserPtr in
            switch kind {
            case .request:
                c_nio_llhttp_init(parserPtr, HTTP_REQUEST, self.settings)
            case .response:
                c_nio_llhttp_init(parserPtr, HTTP_RESPONSE, self.settings)
            }
        }
    }

    deinit {
        self.settings.deallocate()
    }

    private func start(bytes: UnsafeRawBufferPointer, newState: HTTPDecodingState) {
        assert(self.firstNonDiscardableOffset == nil)
        self.firstNonDiscardableOffset = bytes.baseAddress! - self.rawBytesView.baseAddress!
        self.decodingState = newState
    }

    private func finish(_ callout: (inout HTTPDecoderDelegate, UnsafeRawBufferPointer) throws -> Void) rethrows {
        var currentFieldByteLength = 0
        swap(&currentFieldByteLength, &self.currentFieldByteLength)
        let start = self.rawBytesView.startIndex + self.firstNonDiscardableOffset!
        let end = start + currentFieldByteLength
        self.firstNonDiscardableOffset = nil
        precondition(start >= self.rawBytesView.startIndex && end <= self.rawBytesView.endIndex)
        try callout(&self.delegate, .init(rebasing: self.rawBytesView[start..<end]))
    }

    private func didReceiveBodyData(_ bytes: UnsafeRawBufferPointer) {
        self.delegate.didReceiveBody(bytes)
    }

    private func didReceiveHeaderFieldData(_ bytes: UnsafeRawBufferPointer) -> CInt {
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
        return self.validateHeaderLength(bytes.count)
    }

    private func didReceiveHeaderValueData(_ bytes: UnsafeRawBufferPointer) -> CInt {
        do {
            switch self.decodingState {
            case .headerValue, .trailerValue:
                ()
            case .headerName:
                try self.finish { delegate, bytes in
                    try delegate.didReceiveHeaderName(bytes)
                }
                self.start(bytes: bytes, newState: .headerValue)
            case .trailerName:
                try self.finish { delegate, bytes in
                    try delegate.didReceiveTrailerName(bytes)
                }
                self.start(bytes: bytes, newState: .trailerValue)
            case .beforeMessageBegin, .afterMessageBegin, .headersComplete, .url:
                preconditionFailure()
            }
            return self.validateHeaderLength(bytes.count)
        } catch {
            self.richerError = error
            return -1
        }
    }

    private func didReceiveStatusData(_ bytes: UnsafeRawBufferPointer) {
        // we don't do anything special here because we'll need the whole 'head' anyway
    }

    private func didReceiveURLData(_ bytes: UnsafeRawBufferPointer) -> CInt {
        switch self.decodingState {
        case .url:
            ()
        case .afterMessageBegin:
            self.start(bytes: bytes, newState: .url)
        case .beforeMessageBegin, .headersComplete, .headerName, .headerValue, .trailerName, .trailerValue:
            preconditionFailure()
        }
        return self.validateHeaderLength(bytes.count)
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

    private func didReceiveHeadersCompleteNotification(
        versionMajor: Int,
        versionMinor: Int,
        statusCode: Int,
        isUpgrade: Bool,
        method: llhttp_method,
        keepAliveState: KeepAliveState
    ) -> MessageContinuation {
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
            guard !self.requestHeads.isEmpty else {
                self.richerError = NIOHTTPDecoderError.unsolicitedResponse
                return .error(HPE_INTERNAL)
            }

            if 100 <= statusCode && statusCode < 200 && statusCode != 101 {
                // if the response status is in the range of 100..<200 but not 101 we don't want to
                // pop the request method. The actual request head is expected with the next HTTP
                // head.
                skipBody = true
            } else {
                let method = self.requestHeads.removeFirst().method
                if method == .HEAD || method == .CONNECT {
                    skipBody = true
                } else if statusCode / 100 == 1  // 1XX codes
                    || statusCode == 204 || statusCode == 304
                {
                    skipBody = true
                }
            }
        }

        let success = self.delegate.didFinishHead(
            versionMajor: versionMajor,
            versionMinor: versionMinor,
            isUpgrade: isUpgrade,
            method: method,
            statusCode: statusCode,
            keepAliveState: keepAliveState
        )
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

    private func validateHeaderLength(_ newLength: Int) -> CInt {
        self.currentFieldByteLength += newLength
        if self.currentFieldByteLength > Self.maximumHeaderFieldSize {
            self.richerError = HTTPParserError.headerOverflow
            return -1
        }

        return 0
    }

    @inline(__always)  // this need to be optimised away
    func withExclusiveHTTPParser<T>(_ body: (UnsafeMutablePointer<llhttp_t>) -> T) -> T {
        var parser: llhttp_t? = nil
        assert(self.parser != nil, "parser must not be nil here, must be a re-entrancy issue")
        swap(&parser, &self.parser)
        defer {
            assert(self.parser == nil, "parser must not nil here")
            swap(&parser, &self.parser)
        }
        return body(&parser!)
    }

    func feedInput(_ bytes: UnsafeRawBufferPointer?) throws -> Int {
        var bytesRead = 0
        let parserErrno: llhttp_errno_t = self.withExclusiveHTTPParser { parserPtr -> llhttp_errno_t in
            var rc: llhttp_errno_t

            if let bytes = bytes {
                self.rawBytesView = bytes
                defer {
                    self.rawBytesView = .init(start: UnsafeRawPointer(bitPattern: 0xdafbabe), count: 0)
                }

                let startPointer = bytes.baseAddress! + self.httpParserOffset
                let bytesToRead = bytes.count - self.httpParserOffset

                rc = c_nio_llhttp_execute_swift(
                    parserPtr,
                    startPointer,
                    bytesToRead
                )

                if rc == HPE_PAUSED_UPGRADE {
                    // This is a special pause. We don't need to stop here (our other code will prevent us
                    // parsing past this point, but we do need a special hook to work out how many bytes were read.
                    // The force-unwrap is safe: we know we hit an "error".
                    bytesRead = UnsafeRawPointer(c_nio_llhttp_get_error_pos(parserPtr)!) - startPointer
                    c_nio_llhttp_resume_after_upgrade(parserPtr)
                    rc = HPE_OK
                } else {
                    bytesRead = bytesToRead
                }
            } else {
                rc = c_nio_llhttp_finish(parserPtr)
                bytesRead = 0
            }

            return rc
        }

        // self.parser must be non-nil here because we can't be re-entered here (ByteToMessageDecoder guarantee)
        guard parserErrno == HPE_OK else {
            // if we chose to abort (eg. wrong HTTP version) the error will be in self.httpErrno, otherwise http_parser
            // will tell us...
            // self.parser must be non-nil here because we can't be re-entered here (ByteToMessageDecoder guarantee)
            // If we have a richer error than the errno code, and the errno is internal, we'll use it. Otherwise, we use the
            // error from http_parser.
            let err = self.httpErrno ?? parserErrno
            if err == HPE_INTERNAL || err == HPE_USER, let richerError = self.richerError {
                throw richerError
            } else {
                throw HTTPParserError.httpError(fromCHTTPParserErrno: err)!
            }
        }

        if let firstNonDiscardableOffset = self.firstNonDiscardableOffset {
            self.httpParserOffset += bytesRead - firstNonDiscardableOffset
            self.firstNonDiscardableOffset = 0
            return firstNonDiscardableOffset
        } else {
            // By definition we've consumed all of the http parser offset at this stage. There may still be bytes
            // left in the buffer though: we didn't consume them because they aren't ours to consume, as they may belong
            // to an upgraded protocol.
            //
            // Set the HTTP parser offset back to zero, and tell the parent that we consumed
            // the whole buffer.
            let consumedBytes = self.httpParserOffset + bytesRead
            self.httpParserOffset = 0
            return consumedBytes
        }
    }
}

private protocol HTTPDecoderDelegate {
    mutating func didReceiveBody(_ bytes: UnsafeRawBufferPointer)
    mutating func didReceiveHeaderName(_ bytes: UnsafeRawBufferPointer) throws
    mutating func didReceiveHeaderValue(_ bytes: UnsafeRawBufferPointer)
    mutating func didReceiveTrailerName(_ bytes: UnsafeRawBufferPointer) throws
    mutating func didReceiveTrailerValue(_ bytes: UnsafeRawBufferPointer)
    mutating func didReceiveURL(_ bytes: UnsafeRawBufferPointer)
    mutating func didFinishHead(
        versionMajor: Int,
        versionMinor: Int,
        isUpgrade: Bool,
        method: llhttp_method,
        statusCode: Int,
        keepAliveState: KeepAliveState
    ) -> Bool
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

public enum HTTPDecoderKind: Sendable {
    case request
    case response
}

extension HTTPDecoder: WriteObservingByteToMessageDecoder
where In == HTTPClientResponsePart, Out == HTTPClientRequestPart {
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
    private let informationalResponseStrategy: NIOInformationalResponseStrategy
    private let kind: HTTPDecoderKind
    private var stopParsing = false  // set on upgrade or HTTP version error
    private var lastResponseHeaderWasInformational = false

    /// Creates a new instance of `HTTPDecoder`.
    ///
    /// - Parameters:
    ///   - leftOverBytesStrategy: The strategy to use when removing the decoder from the pipeline and an upgrade was,
    ///                              detected. Note that this does not affect what happens on EOF.
    public convenience init(leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes) {
        self.init(leftOverBytesStrategy: leftOverBytesStrategy, informationalResponseStrategy: .drop)
    }

    /// Creates a new instance of `HTTPDecoder`.
    ///
    /// - Parameters:
    ///   - leftOverBytesStrategy: The strategy to use when removing the decoder from the pipeline and an upgrade was,
    ///                              detected. Note that this does not affect what happens on EOF.
    ///   - informationalResponseStrategy: Should informational responses (like http status 100) be forwarded or dropped.
    ///                              Default is `.drop`. This property is only respected when decoding responses.
    public init(
        leftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
        informationalResponseStrategy: NIOInformationalResponseStrategy = .drop
    ) {
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
        self.informationalResponseStrategy = informationalResponseStrategy
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
            self.context!.fireChannelRead(
                NIOAny(HTTPServerRequestPart.body(self.buffer!.readSlice(length: bytes.count)!))
            )
        case .response:
            self.context!.fireChannelRead(
                NIOAny(HTTPClientResponsePart.body(self.buffer!.readSlice(length: bytes.count)!))
            )
        }

    }

    func didReceiveHeaderName(_ bytes: UnsafeRawBufferPointer) throws {
        assert(self.currentHeaderName == nil)

        // Defensive check: llhttp tolerates a zero-length header field name, but we don't.
        guard bytes.count > 0 else {
            throw HTTPParserError.invalidHeaderToken
        }
        self.currentHeaderName = String(decoding: bytes, as: Unicode.UTF8.self)
    }

    func didReceiveHeaderValue(_ bytes: UnsafeRawBufferPointer) {
        self.headers.append((self.currentHeaderName!, String(decoding: bytes, as: Unicode.UTF8.self)))
        self.currentHeaderName = nil
    }

    func didReceiveTrailerName(_ bytes: UnsafeRawBufferPointer) throws {
        assert(self.currentHeaderName == nil)

        // Defensive check: llhttp tolerates a zero-length header field name, but we don't.
        guard bytes.count > 0 else {
            throw HTTPParserError.invalidHeaderToken
        }
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

    fileprivate func didFinishHead(
        versionMajor: Int,
        versionMinor: Int,
        isUpgrade: Bool,
        method: llhttp_method,
        statusCode: Int,
        keepAliveState: KeepAliveState
    ) -> Bool {
        let message: NIOAny?

        guard versionMajor == 1 else {
            self.stopParsing = true
            self.context!.fireErrorCaught(HTTPParserError.invalidVersion)
            return false
        }

        switch self.kind {
        case .request:
            let reqHead = HTTPRequestHead(
                version: .init(major: versionMajor, minor: versionMinor),
                method: HTTPMethod.from(httpParserMethod: method),
                uri: self.url!,
                headers: HTTPHeaders(
                    self.headers,
                    keepAliveState: keepAliveState
                )
            )
            message = NIOAny(HTTPServerRequestPart.head(reqHead))

        case .response where (100..<200).contains(statusCode) && statusCode != 101:
            self.lastResponseHeaderWasInformational = true
            switch self.informationalResponseStrategy.base {
            case .forward:
                let resHeadPart = HTTPClientResponsePart.head(
                    versionMajor: versionMajor,
                    versionMinor: versionMinor,
                    statusCode: statusCode,
                    keepAliveState: keepAliveState,
                    headers: self.headers
                )
                message = NIOAny(resHeadPart)
            case .drop:
                message = nil
            }

        case .response:
            self.lastResponseHeaderWasInformational = false
            let resHeadPart = HTTPClientResponsePart.head(
                versionMajor: versionMajor,
                versionMinor: versionMinor,
                statusCode: statusCode,
                keepAliveState: keepAliveState,
                headers: self.headers
            )
            message = NIOAny(resHeadPart)
        }
        self.url = nil
        self.headers.removeAll(keepingCapacity: true)
        if let message = message {
            self.context!.fireChannelRead(message)
        }
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
            if !self.lastResponseHeaderWasInformational {
                self.context!.fireChannelRead(NIOAny(HTTPClientResponsePart.end(trailers.map(HTTPHeaders.init))))
            }
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

    public func decodeLast(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws -> DecodingState {
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

@available(*, unavailable)
extension HTTPDecoder: Sendable {}

/// Strategy to use when a HTTPDecoder is removed from a pipeline after a HTTP upgrade was detected.
public enum RemoveAfterUpgradeStrategy: Sendable {
    /// Forward all the remaining bytes that are currently buffered in the deccoder to the next handler in the pipeline.
    case forwardBytes
    /// Fires a `ByteToMessageDecoder.leftoverDataWhenDone` error through the pipeline
    case fireError
    /// Discard all the remaining bytes that are currently buffered in the decoder.
    case dropBytes
}

/// Strategy to use when a HTTPDecoder receives an informational HTTP response (1xx except 101)
public struct NIOInformationalResponseStrategy: Hashable, Sendable {
    @usableFromInline
    enum Base: Sendable {
        case drop
        case forward
    }

    @usableFromInline
    var base: Base

    @inlinable
    init(_ base: Base) {
        self.base = base
    }

    /// Drop the informational response and only forward the "real" response
    @inlinable
    public static var drop: NIOInformationalResponseStrategy {
        Self(.drop)
    }
    /// Forward the informational response and then forward the "real" response. This will result in
    /// multiple `head` before an `end` is emitted.
    @inlinable
    public static var forward: NIOInformationalResponseStrategy {
        Self(.forward)
    }
}

extension HTTPParserError {
    /// Create a `HTTPParserError` from an error returned by `http_parser`.
    ///
    /// - Parameter fromCHTTPParserErrno: The error from the underlying library.
    /// - Returns: The corresponding `HTTPParserError`, or `nil` if there is no
    ///     corresponding error.
    fileprivate static func httpError(fromCHTTPParserErrno: llhttp_errno_t) -> HTTPParserError? {
        switch fromCHTTPParserErrno {
        case HPE_INTERNAL:
            return .invalidInternalState
        case HPE_STRICT:
            return .strictModeAssertion
        case HPE_LF_EXPECTED:
            return .lfExpected
        case HPE_UNEXPECTED_CONTENT_LENGTH:
            return .unexpectedContentLength
        case HPE_CLOSED_CONNECTION:
            return .closedConnection
        case HPE_INVALID_METHOD:
            return .invalidMethod
        case HPE_INVALID_URL:
            return .invalidURL
        case HPE_INVALID_CONSTANT:
            return .invalidConstant
        case HPE_INVALID_VERSION:
            return .invalidVersion
        case HPE_INVALID_HEADER_TOKEN,
            HPE_UNEXPECTED_SPACE:
            return .invalidHeaderToken
        case HPE_INVALID_CONTENT_LENGTH:
            return .invalidContentLength
        case HPE_INVALID_CHUNK_SIZE:
            return .invalidChunkSize
        case HPE_INVALID_STATUS:
            return .invalidStatus
        case HPE_INVALID_EOF_STATE:
            return .invalidEOFState
        case HPE_PAUSED, HPE_PAUSED_UPGRADE, HPE_PAUSED_H2_UPGRADE:
            return .paused
        case HPE_INVALID_TRANSFER_ENCODING,
            HPE_CR_EXPECTED,
            HPE_CB_MESSAGE_BEGIN,
            HPE_CB_HEADERS_COMPLETE,
            HPE_CB_MESSAGE_COMPLETE,
            HPE_CB_CHUNK_HEADER,
            HPE_CB_CHUNK_COMPLETE,
            HPE_USER,
            HPE_CB_URL_COMPLETE,
            HPE_CB_STATUS_COMPLETE,
            HPE_CB_HEADER_FIELD_COMPLETE,
            HPE_CB_HEADER_VALUE_COMPLETE:
            // The downside of enums here, we don't have a case for these. Map them to .unknown for now.
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
    fileprivate static func from(httpParserMethod: llhttp_method) -> HTTPMethod {
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
        case HTTP_PRI:
            return .RAW(value: "PRI")
        case HTTP_DESCRIBE:
            return .RAW(value: "DESCRIBE")
        case HTTP_ANNOUNCE:
            return .RAW(value: "ANNOUNCE")
        case HTTP_SETUP:
            return .RAW(value: "SETUP")
        case HTTP_PLAY:
            return .RAW(value: "PLAY")
        case HTTP_PAUSE:
            return .RAW(value: "PAUSE")
        case HTTP_TEARDOWN:
            return .RAW(value: "TEARDOWN")
        case HTTP_GET_PARAMETER:
            return .RAW(value: "GET_PARAMETER")
        case HTTP_SET_PARAMETER:
            return .RAW(value: "SET_PARAMETER")
        case HTTP_REDIRECT:
            return .RAW(value: "REDIRECT")
        case HTTP_RECORD:
            return .RAW(value: "RECORD")
        case HTTP_FLUSH:
            return .RAW(value: "FLUSH")
        default:
            return .RAW(value: String(cString: c_nio_llhttp_method_name(httpParserMethod)))
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

extension NIOHTTPDecoderError: Hashable {}

extension NIOHTTPDecoderError: CustomDebugStringConvertible {
    public var debugDescription: String {
        String(describing: self.baseError)
    }
}

extension HTTPClientResponsePart {
    fileprivate static func head(
        versionMajor: Int,
        versionMinor: Int,
        statusCode: Int,
        keepAliveState: KeepAliveState,
        headers: [(String, String)]
    ) -> HTTPClientResponsePart {
        HTTPClientResponsePart.head(
            HTTPResponseHead(
                version: .init(major: versionMajor, minor: versionMinor),
                status: .init(statusCode: statusCode),
                headers: HTTPHeaders(headers, keepAliveState: keepAliveState)
            )
        )
    }
}
