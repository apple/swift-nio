//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore

/// A ChannelHandler to validate that outbound request headers are spec-compliant.
///
/// The HTTP RFCs constrain the bytes that are validly present within a HTTP/1.1 header block.
/// ``NIOHTTPRequestHeadersValidator`` polices this constraint and ensures that only valid header blocks
/// are emitted on the network. If a header block is invalid, then ``NIOHTTPRequestHeadersValidator``
/// will send a ``HTTPParserError/invalidHeaderToken``.
///
/// ``NIOHTTPRequestHeadersValidator`` will also validate that the HTTP trailers are within specification,
/// if they are present.
public final class NIOHTTPRequestHeadersValidator: ChannelOutboundHandler, RemovableChannelHandler {
    public typealias OutboundIn = HTTPClientRequestPart
    public typealias OutboundOut = HTTPClientRequestPart

    public init() {}

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch NIOHTTPRequestHeadersValidator.unwrapOutboundIn(data) {
        case .head(let head):
            guard Self.uriOnlyContainsAllowedCharacters(head.uri), head.method.isValidToSend,
                head.headers.areValidToSend
            else {
                promise?.fail(HTTPParserError.invalidHeaderToken)
                context.fireErrorCaught(HTTPParserError.invalidHeaderToken)
                return
            }
        case .body, .end(.none):
            ()
        case .end(.some(let trailers)):
            guard trailers.areValidToSend else {
                promise?.fail(HTTPParserError.invalidHeaderToken)
                context.fireErrorCaught(HTTPParserError.invalidHeaderToken)
                return
            }
        }

        context.write(data, promise: promise)
    }

    static func uriOnlyContainsAllowedCharacters(_ uri: String) -> Bool {
        // The spec in [RFC 9112](https://datatracker.ietf.org/doc/html/rfc9112#section-3.2) defines the valid
        // characters for the request-target as the following:
        //
        // ```
        // request-target = origin-form / absolute-form / authority-form / asterisk-form
        //
        // origin-form    = absolute-path [ "?" query ]
        // absolute-form  = absolute-URI
        // authority-form = uri-host ":" port              ; CONNECT only
        // asterisk-form  = "*"                            ; OPTIONS only
        // ```
        //
        // The component grammar comes from [RFC 3986](https://datatracker.ietf.org/doc/html/rfc3986#section-3)
        // (updated by [RFC 8820](https://datatracker.ietf.org/doc/html/rfc8820), which adds best-practice
        // guidance for URI design but does not change the syntax):
        //
        // ```
        // absolute-path = 1*( "/" segment )
        // segment       = *pchar
        // query         = *( pchar / "/" / "?" )
        //
        // pchar         = unreserved / pct-encoded / sub-delims / ":" / "@"
        // pct-encoded   = "%" HEXDIG HEXDIG
        //
        // unreserved    = ALPHA / DIGIT / "-" / "." / "_" / "~"
        // reserved      = gen-delims / sub-delims
        // gen-delims    = ":" / "/" / "?" / "#" / "[" / "]" / "@"
        // sub-delims    = "!" / "$" / "&" / "'" / "(" / ")"
        //               / "*" / "+" / "," / ";" / "="
        // ```
        //
        // In other words, the literal byte set allowed on the wire is:
        //
        // ```
        //   ALPHA          %x41-5A / %x61-7A      ; A–Z a–z
        //   DIGIT          %x30-39                ; 0–9
        //   unreserved     "-" "." "_" "~"
        //   gen-delims     ":" "/" "?" "#" "[" "]" "@"
        //   sub-delims     "!" "$" "&" "'" "(" ")" "*" "+" "," ";" "="
        //   pct-encoded    "%" HEXDIG HEXDIG      ; escape for anything else
        // ```
        //
        // Everything outside this set — SP, CTLs (%x00-1F / %x7F), non-ASCII (%x80-FF),
        // and `" < > \ ^ ` { | }` — MUST be percent-encoded. Bare CR, LF, or NUL in
        // the request-target MUST be rejected (request smuggling / response splitting).

        uri.utf8.allSatisfy { byte in
            switch byte {
            case  // unreserved
            //   - ALPHA
            UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                //   - DIGIT
                UInt8(ascii: "0")...UInt8(ascii: "9"),
                //   - extra characters
                UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"),
                // gen-delims
                UInt8(ascii: ":"), UInt8(ascii: "/"), UInt8(ascii: "?"), UInt8(ascii: "#"),
                UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "@"),
                // sub-delims
                UInt8(ascii: "!"), UInt8(ascii: "$"), UInt8(ascii: "&"), UInt8(ascii: "'"),
                UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"),
                UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "="),
                // pct-encoded
                UInt8(ascii: "%"):
                return true
            default:
                return false
            }
        }
    }
}

/// A ChannelHandler to validate that outbound response headers are spec-compliant.
///
/// The HTTP RFCs constrain the bytes that are validly present within a HTTP/1.1 header block.
/// ``NIOHTTPResponseHeadersValidator`` polices this constraint and ensures that only valid header blocks
/// are emitted on the network. If a header block is invalid, then ``NIOHTTPResponseHeadersValidator``
/// will send a ``HTTPParserError/invalidHeaderToken``.
///
/// ``NIOHTTPResponseHeadersValidator`` will also validate that the HTTP trailers are within specification,
/// if they are present.
public final class NIOHTTPResponseHeadersValidator: ChannelOutboundHandler, RemovableChannelHandler {
    public typealias OutboundIn = HTTPServerResponsePart
    public typealias OutboundOut = HTTPServerResponsePart

    private enum State {
        /// Validating response parts.
        case validating
        /// Dropping all response parts. This is a terminal state.
        case dropping
    }

    private var state: State

    public init() {
        self.state = .validating
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch (NIOHTTPResponseHeadersValidator.unwrapOutboundIn(data), self.state) {
        case (.head(let head), .validating):
            if head.headers.areValidToSend, head.status.isValidToSend {
                context.write(data, promise: promise)
            } else {
                self.state = .dropping
                promise?.fail(HTTPParserError.invalidHeaderToken)
                context.fireErrorCaught(HTTPParserError.invalidHeaderToken)
            }

        case (.body, .validating):
            context.write(data, promise: promise)

        case (.end(let trailers), .validating):
            // No trailers are always valid trailers.
            if trailers?.areValidToSend ?? true {
                context.write(data, promise: promise)
            } else {
                self.state = .dropping
                promise?.fail(HTTPParserError.invalidHeaderToken)
                context.fireErrorCaught(HTTPParserError.invalidHeaderToken)
            }

        case (.head, .dropping), (.body, .dropping), (.end, .dropping):
            promise?.fail(HTTPParserError.invalidHeaderToken)
        }
    }
}

@available(*, unavailable)
extension NIOHTTPRequestHeadersValidator: Sendable {}

@available(*, unavailable)
extension NIOHTTPResponseHeadersValidator: Sendable {}

extension HTTPMethod {
    /// Whether these HTTPHeaders are valid to send on the wire.
    var isValidToSend: Bool {
        switch self {
        case .GET,
            .PUT,
            .ACL,
            .HEAD,
            .POST,
            .COPY,
            .LOCK,
            .MOVE,
            .BIND,
            .LINK,
            .PATCH,
            .TRACE,
            .MKCOL,
            .MERGE,
            .PURGE,
            .NOTIFY,
            .SEARCH,
            .UNLOCK,
            .REBIND,
            .UNBIND,
            .REPORT,
            .DELETE,
            .UNLINK,
            .CONNECT,
            .MSEARCH,
            .OPTIONS,
            .PROPFIND,
            .CHECKOUT,
            .PROPPATCH,
            .SUBSCRIBE,
            .MKCALENDAR,
            .MKACTIVITY,
            .UNSUBSCRIBE,
            .SOURCE:
            true

        case .RAW(let value):
            // The spec in [RFC 9110](https://httpwg.org/specs/rfc9110.html#method.overview) defines the valid
            // characters as the following:
            //
            // ```
            // method = token
            //
            // token          = 1*tchar
            //
            // tchar          = "!" / "#" / "$" / "%" / "&" / "'" / "*"
            //                / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~"
            //                / DIGIT / ALPHA
            //                ; any VCHAR, except delimiters

            value.utf8.allSatisfy { byte in
                switch byte {
                case  // ALPHA
                UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                    // DIGIT
                    UInt8(ascii: "0")...UInt8(ascii: "9"),
                    // token
                    UInt8(ascii: "!"), UInt8(ascii: "#"), UInt8(ascii: "$"), UInt8(ascii: "%"),
                    UInt8(ascii: "&"), UInt8(ascii: "'"), UInt8(ascii: "*"), UInt8(ascii: "+"),
                    UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "^"), UInt8(ascii: "_"),
                    UInt8(ascii: "`"), UInt8(ascii: "|"), UInt8(ascii: "~"):
                    true
                default:
                    false
                }
            }
        }
    }
}

extension HTTPResponseStatus {
    var isValidToSend: Bool {
        switch self {
        case .continue,
            .switchingProtocols,
            .processing,
            .ok,
            .created,
            .accepted,
            .nonAuthoritativeInformation,
            .noContent,
            .resetContent,
            .partialContent,
            .multiStatus,
            .alreadyReported,
            .imUsed,
            .multipleChoices,
            .movedPermanently,
            .found,
            .seeOther,
            .notModified,
            .useProxy,
            .temporaryRedirect,
            .permanentRedirect,
            .badRequest,
            .unauthorized,
            .paymentRequired,
            .forbidden,
            .notFound,
            .methodNotAllowed,
            .notAcceptable,
            .proxyAuthenticationRequired,
            .requestTimeout,
            .conflict,
            .gone,
            .lengthRequired,
            .preconditionFailed,
            .payloadTooLarge,
            .uriTooLong,
            .unsupportedMediaType,
            .rangeNotSatisfiable,
            .expectationFailed,
            .imATeapot,
            .misdirectedRequest,
            .unprocessableEntity,
            .locked,
            .failedDependency,
            .upgradeRequired,
            .preconditionRequired,
            .tooManyRequests,
            .requestHeaderFieldsTooLarge,
            .unavailableForLegalReasons,
            .internalServerError,
            .notImplemented,
            .badGateway,
            .serviceUnavailable,
            .gatewayTimeout,
            .httpVersionNotSupported,
            .variantAlsoNegotiates,
            .insufficientStorage,
            .loopDetected,
            .notExtended,
            .networkAuthenticationRequired:
            true

        case .custom(_, let reasonPhrase):
            // The spec in [RFC 9112](https://datatracker.ietf.org/doc/html/rfc9112#section-4) defines the valid
            // characters as the following:
            //
            // ```
            // reason-phrase = 1*( HTAB / SP / VCHAR / obs-text )
            //
            // obs-text      = %x80-FF
            // ```

            reasonPhrase.utf8.allSatisfy { byte in
                switch byte {
                case 9,  // HTAB
                    32,  // SP
                    33...126,  // VCHAR
                    128...255:  // obs-text
                    return true
                default:
                    return false
                }
            }
        }
    }
}
