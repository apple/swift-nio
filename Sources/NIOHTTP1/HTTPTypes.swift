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

let crlf: StaticString = "\r\n"
let headerSeparator: StaticString = ": "

extension HTTPHeaders {
    internal enum ConnectionHeaderValue {
        case keepAlive
        case close
        case unspecified
    }
}

// Keep track of keep alive state.
internal enum KeepAliveState {
    // We know keep alive should be used.
    case keepAlive
    // We know we should close the connection.
    case close
    // We need to scan the headers to find out if keep alive is used or not
    case unknown
}

/// A representation of the request line and header fields of a HTTP request.
public struct HTTPRequestHead: Equatable {
    private final class _Storage {
        var method: HTTPMethod
        var uri: String
        var version: HTTPVersion

        init(method: HTTPMethod, uri: String, version: HTTPVersion) {
            self.method = method
            self.uri = uri
            self.version = version
        }

        func copy() -> _Storage {
            return .init(method: self.method, uri: self.uri, version: self.version)
        }
    }

    private var _storage: _Storage

    /// The header fields for this HTTP request.
    // warning: do not put this in `_Storage` as it'd trigger a CoW on every mutation
    public var headers: HTTPHeaders

    /// The HTTP method for this request.
    public var method: HTTPMethod {
        get {
            return self._storage.method
        }
        set {
            self.copyStorageIfNotUniquelyReferenced()
            self._storage.method = newValue
        }
    }

    // This request's URI.
    public var uri: String {
        get {
            return self._storage.uri
        }
        set {
            self.copyStorageIfNotUniquelyReferenced()
            self._storage.uri = newValue
        }
    }

    /// The version for this HTTP request.
    public var version: HTTPVersion {
        get {
            return self._storage.version
        }
        set {
            self.copyStorageIfNotUniquelyReferenced()
            self._storage.version = newValue
        }
    }

    /// Create a `HTTPRequestHead`
    ///
    /// - parameters:
    ///     - version: The version for this HTTP request.
    ///     - method: The HTTP method for this request.
    ///     - uri: The URI used on this request.
    ///     - headers: This request's HTTP headers.
    public init(version: HTTPVersion, method: HTTPMethod, uri: String, headers: HTTPHeaders) {
        self._storage = .init(method: method, uri: uri, version: version)
        self.headers = headers
    }

    /// Create a `HTTPRequestHead`
    ///
    /// - Parameter version: The version for this HTTP request.
    /// - Parameter method: The HTTP method for this request.
    /// - Parameter uri: The URI used on this request.
    public init(version: HTTPVersion, method: HTTPMethod, uri: String) {
        self.init(version: version, method: method, uri: uri, headers: HTTPHeaders())
    }

    public static func ==(lhs: HTTPRequestHead, rhs: HTTPRequestHead) -> Bool {
        return lhs.method == rhs.method && lhs.uri == rhs.uri && lhs.version == rhs.version && lhs.headers == rhs.headers
    }

    private mutating func copyStorageIfNotUniquelyReferenced () {
        if !isKnownUniquelyReferenced(&self._storage) {
            self._storage = self._storage.copy()
        }
    }
}

/// The parts of a complete HTTP message, either request or response.
///
/// A HTTP message is made up of a request or status line with several headers,
/// encoded by `.head`, zero or more body parts, and optionally some trailers. To
/// indicate that a complete HTTP message has been sent or received, we use `.end`,
/// which may also contain any trailers that make up the message.
public enum HTTPPart<HeadT: Equatable, BodyT: Equatable> {
    case head(HeadT)
    case body(BodyT)
    case end(HTTPHeaders?)
}

extension HTTPPart: Equatable {}

/// The components of a HTTP request from the view of a HTTP client.
public typealias HTTPClientRequestPart = HTTPPart<HTTPRequestHead, IOData>

/// The components of a HTTP request from the view of a HTTP server.
public typealias HTTPServerRequestPart = HTTPPart<HTTPRequestHead, ByteBuffer>

/// The components of a HTTP response from the view of a HTTP client.
public typealias HTTPClientResponsePart = HTTPPart<HTTPResponseHead, ByteBuffer>

/// The components of a HTTP response from the view of a HTTP server.
public typealias HTTPServerResponsePart = HTTPPart<HTTPResponseHead, IOData>

extension HTTPRequestHead {
    /// Whether this HTTP request is a keep-alive request: that is, whether the
    /// connection should remain open after the request is complete.
    public var isKeepAlive: Bool {
        return headers.isKeepAlive(version: version)
    }
}

extension HTTPResponseHead {
    /// Whether this HTTP response is a keep-alive request: that is, whether the
    /// connection should remain open after the request is complete.
    public var isKeepAlive: Bool {
        return self.headers.isKeepAlive(version: self.version)
    }
}

/// A representation of the status line and header fields of a HTTP response.
public struct HTTPResponseHead: Equatable {
    private final class _Storage {
        var status: HTTPResponseStatus
        var version: HTTPVersion
        init(status: HTTPResponseStatus, version: HTTPVersion) {
            self.status = status
            self.version = version
        }
        func copy() -> _Storage {
            return .init(status: self.status, version: self.version)
        }
    }

    private var _storage: _Storage

    /// The HTTP headers on this response.
    // warning: do not put this in `_Storage` as it'd trigger a CoW on every mutation
    public var headers: HTTPHeaders

    /// The HTTP response status.
    public var status: HTTPResponseStatus {
        get {
            return self._storage.status
        }
        set {
            self.copyStorageIfNotUniquelyReferenced()
            self._storage.status = newValue
        }
    }

    /// The HTTP version that corresponds to this response.
    public var version: HTTPVersion {
        get {
            return self._storage.version
        }
        set {
            self.copyStorageIfNotUniquelyReferenced()
            self._storage.version = newValue
        }
    }

    /// Create a `HTTPResponseHead`
    ///
    /// - Parameter version: The version for this HTTP response.
    /// - Parameter status: The status for this HTTP response.
    /// - Parameter headers: The headers for this HTTP response.
    public init(version: HTTPVersion, status: HTTPResponseStatus, headers: HTTPHeaders = HTTPHeaders()) {
        self.headers = headers
        self._storage = _Storage(status: status, version: version)
    }

    public static func ==(lhs: HTTPResponseHead, rhs: HTTPResponseHead) -> Bool {
        return lhs.status == rhs.status && lhs.version == rhs.version && lhs.headers == rhs.headers
    }

    private mutating func copyStorageIfNotUniquelyReferenced () {
        if !isKnownUniquelyReferenced(&self._storage) {
            self._storage = self._storage.copy()
        }
    }
}

extension HTTPResponseHead {
    /// Determines if the head is purely informational. If a head is informational another head will follow this
    /// head eventually.
    var isInformational: Bool {
        100 <= self.status.code && self.status.code < 200 && self.status.code != 101
    }
}

private extension UInt8 {
    var isASCII: Bool {
        return self <= 127
    }
}

extension HTTPHeaders {
    func isKeepAlive(version: HTTPVersion) -> Bool {
        switch self.keepAliveState {
        case .close:
            return false
        case .keepAlive:
            return true
        case .unknown:
            var state = KeepAliveState.unknown
            for word in self[canonicalForm: "connection"] {
                if word.utf8.compareCaseInsensitiveASCIIBytes(to: "close".utf8) {
                    // if we see multiple values, that's clearly bad and we default to 'close'
                    state = state != .unknown ? .close : .close
                } else if word.utf8.compareCaseInsensitiveASCIIBytes(to: "keep-alive".utf8) {
                    // if we see multiple values, that's clearly bad and we default to 'close'
                    state = state != .unknown ? .close : .keepAlive
                }
            }

            switch state {
            case .close:
                return false
            case .keepAlive:
                return true
            case .unknown:
                // HTTP 1.1 use keep-alive by default if not otherwise told.
                return version.major == 1 && version.minor >= 1
            }
        }
    }
}

/// A representation of a block of HTTP header fields.
///
/// HTTP header fields are a complex data structure. The most natural representation
/// for these is a sequence of two-tuples of field name and field value, both as
/// strings. This structure preserves that representation, but provides a number of
/// convenience features in addition to it.
///
/// For example, this structure enables access to header fields based on the
/// case-insensitive form of the field name, but preserves the original case of the
/// field when needed. It also supports recomposing headers to a maximally joined
/// or split representation, such that header fields that are able to be repeated
/// can be represented appropriately.
public struct HTTPHeaders: CustomStringConvertible, ExpressibleByDictionaryLiteral {
    @usableFromInline
    internal var headers: [(String, String)]
    internal var keepAliveState: KeepAliveState = .unknown

    public var description: String {
        return self.headers.description
    }

    internal var names: [String] {
        return self.headers.map { $0.0 }
    }

    internal init(_ headers: [(String, String)], keepAliveState: KeepAliveState) {
        self.headers = headers
        self.keepAliveState = keepAliveState
    }

    internal func isConnectionHeader(_ name: String) -> Bool {
        return name.utf8.compareCaseInsensitiveASCIIBytes(to: "connection".utf8)
    }

    /// Construct a `HTTPHeaders` structure.
    ///
    /// - parameters
    ///     - headers: An initial set of headers to use to populate the header block.
    ///     - allocator: The allocator to use to allocate the underlying storage.
    public init(_ headers: [(String, String)] = []) {
        // Note: this initializer exists because of https://bugs.swift.org/browse/SR-7415.
        // Otherwise we'd only have the one below with a default argument for `allocator`.
        self.init(headers, keepAliveState: .unknown)
    }

    /// Construct a `HTTPHeaders` structure.
    ///
    /// - parameters
    ///     - elements: name, value pairs provided by a dictionary literal.
    public init(dictionaryLiteral elements: (String, String)...) {
        self.init(elements)
    }

    /// Add a header name/value pair to the block.
    ///
    /// This method is strictly additive: if there are other values for the given header name
    /// already in the block, this will add a new entry.
    ///
    /// - Parameter name: The header field name. For maximum compatibility this should be an
    ///     ASCII string. For future-proofing with HTTP/2 lowercase header names are strongly
    ///     recommended.
    /// - Parameter value: The header field value to add for the given name.
    public mutating func add(name: String, value: String) {
        precondition(!name.utf8.contains(where: { !$0.isASCII }), "name must be ASCII")
        self.headers.append((name, value))
        if self.isConnectionHeader(name) {
            self.keepAliveState = .unknown
        }
    }

    /// Add a sequence of header name/value pairs to the block.
    ///
    /// This method is strictly additive: if there are other entries with the same header
    /// name already in the block, this will add new entries.
    ///
    /// - Parameter contentsOf: The sequence of header name/value pairs. For maximum compatibility
    ///     the header should be an ASCII string. For future-proofing with HTTP/2 lowercase header
    ///     names are strongly recommended.
    @inlinable
    public mutating func add<S: Sequence>(contentsOf other: S) where S.Element == (String, String) {
        self.headers.reserveCapacity(self.headers.count + other.underestimatedCount)
        for (name, value) in other {
            self.add(name: name, value: value)
        }
    }

    /// Add another block of headers to the block.
    ///
    /// - Parameter contentsOf: The block of headers to add to these headers.
    public mutating func add(contentsOf other: HTTPHeaders) {
        self.headers.append(contentsOf: other.headers)
        if other.keepAliveState == .unknown {
            self.keepAliveState = .unknown
        }
    }

    /// Add a header name/value pair to the block, replacing any previous values for the
    /// same header name that are already in the block.
    ///
    /// This is a supplemental method to `add` that essentially combines `remove` and `add`
    /// in a single function. It can be used to ensure that a header block is in a
    /// well-defined form without having to check whether the value was previously there.
    /// Like `add`, this method performs case-insensitive comparisons of the header field
    /// names.
    ///
    /// - Parameter name: The header field name. For maximum compatibility this should be an
    ///     ASCII string. For future-proofing with HTTP/2 lowercase header names are strongly
    //      recommended.
    /// - Parameter value: The header field value to add for the given name.
    public mutating func replaceOrAdd(name: String, value: String) {
        if self.isConnectionHeader(name) {
            self.keepAliveState = .unknown
        }
        self.remove(name: name)
        self.add(name: name, value: value)
    }

    /// Remove all values for a given header name from the block.
    ///
    /// This method uses case-insensitive comparisons for the header field name.
    ///
    /// - Parameter name: The name of the header field to remove from the block.
    public mutating func remove(name nameToRemove: String) {
        if self.isConnectionHeader(nameToRemove) {
            self.keepAliveState = .unknown
        }
        self.headers.removeAll { (name, _) in
            if nameToRemove.utf8.count != name.utf8.count {
                return false
            }

            return nameToRemove.utf8.compareCaseInsensitiveASCIIBytes(to: name.utf8)
        }
    }

    /// Retrieve all of the values for a give header field name from the block.
    ///
    /// This method uses case-insensitive comparisons for the header field name. It
    /// does not return a maximally-decomposed list of the header fields, but instead
    /// returns them in their original representation: that means that a comma-separated
    /// header field list may contain more than one entry, some of which contain commas
    /// and some do not. If you want a representation of the header fields suitable for
    /// performing computation on, consider `subscript(canonicalForm:)`.
    ///
    /// - Parameter name: The header field name whose values are to be retrieved.
    /// - Returns: A list of the values for that header field name.
    public subscript(name: String) -> [String] {
        return self.headers.reduce(into: []) { target, lr in
            let (key, value) = lr
            if key.utf8.compareCaseInsensitiveASCIIBytes(to: name.utf8) {
                target.append(value)
            }
        }
    }

    /// Retrieves the first value for a given header field name from the block.
    ///
    /// This method uses case-insensitive comparisons for the header field name. It
    /// does not return the first value from a maximally-decomposed list of the header fields,
    /// but instead returns the first value from the original representation: that means
    /// that a comma-separated header field list may contain more than one entry, some of
    /// which contain commas and some do not. If you want a representation of the header fields
    /// suitable for performing computation on, consider `subscript(canonicalForm:)`.
    ///
    /// - Parameter name: The header field name whose first value should be retrieved.
    /// - Returns: The first value for the header field name.
    public func first(name: String) -> String? {
        guard !self.headers.isEmpty else {
            return nil
        }

        return self.headers.first { header in header.0.isEqualCaseInsensitiveASCIIBytes(to: name) }?.1
    }

    /// Checks if a header is present
    ///
    /// - parameters:
    ///     - name: The name of the header
    //  - returns: `true` if a header with the name (and value) exists, `false` otherwise.
    public func contains(name: String) -> Bool {
        for kv in self.headers {
            if kv.0.utf8.compareCaseInsensitiveASCIIBytes(to: name.utf8) {
                return true
            }
        }
        return false
    }

    /// Retrieves the header values for the given header field in "canonical form": that is,
    /// splitting them on commas as extensively as possible such that multiple values received on the
    /// one line are returned as separate entries. Also respects the fact that Set-Cookie should not
    /// be split in this way.
    ///
    /// - Parameter name: The header field name whose values are to be retrieved.
    /// - Returns: A list of the values for that header field name.
    public subscript(canonicalForm name: String) -> [Substring] {
        let result = self[name]

        guard result.count > 0 else {
            return []
        }

        // It's not safe to split Set-Cookie on comma.
        guard name.lowercased() != "set-cookie" else {
            return result.map { $0[...] }
        }

        return result.flatMap { $0.split(separator: ",").map { $0.trimWhitespace() } }
    }
}

extension HTTPHeaders {

    /// The total number of headers that can be contained without allocating new storage.
    public var capacity: Int {
        return self.headers.capacity
    }

    /// Reserves enough space to store the specified number of headers.
    ///
    /// - Parameter minimumCapacity: The requested number of headers to store.
    public mutating func reserveCapacity(_ minimumCapacity: Int) {
        self.headers.reserveCapacity(minimumCapacity)
    }
}

extension ByteBuffer {

    /// Serializes this HTTP header block to bytes suitable for writing to the wire.
    ///
    /// - Parameter buffer: A buffer to write the serialized bytes into. Will increment
    ///     the writer index of this buffer.
    mutating func write(headers: HTTPHeaders) {
        for header in headers.headers {
            self.writeString(header.0)
            self.writeStaticString(": ")
            self.writeString(header.1)
            self.writeStaticString("\r\n")
        }
        self.writeStaticString(crlf)
    }
}

extension HTTPHeaders: RandomAccessCollection {
    public typealias Element = (name: String, value: String)

    public struct Index: Comparable {
        fileprivate let base: Array<(String, String)>.Index
        public static func < (lhs: Index, rhs: Index) -> Bool {
            return lhs.base < rhs.base
        }
    }

    public var startIndex: HTTPHeaders.Index {
        return .init(base: self.headers.startIndex)
    }

    public var endIndex: HTTPHeaders.Index {
        return .init(base: self.headers.endIndex)
    }

    public func index(before i: HTTPHeaders.Index) -> HTTPHeaders.Index {
        return .init(base: self.headers.index(before: i.base))
    }

    public func index(after i: HTTPHeaders.Index) -> HTTPHeaders.Index {
        return .init(base: self.headers.index(after: i.base))
    }

    public subscript(position: HTTPHeaders.Index) -> Element {
        return self.headers[position.base]
    }
}

extension UTF8.CodeUnit {
    var isASCIIWhitespace: Bool {
        switch self {
        case UInt8(ascii: " "),
             UInt8(ascii: "\t"):
          return true

        default:
          return false
        }
    }
}

extension String {
    func trimASCIIWhitespace() -> Substring {
        return Substring(self).trimWhitespace()
    }
}

extension Substring {
    fileprivate func trimWhitespace() -> Substring {
        guard let firstNonWhitespace = self.utf8.firstIndex(where: { !$0.isASCIIWhitespace }) else {
          // The whole substring is ASCII whitespace.
          return Substring()
        }

        // There must be at least one non-ascii whitespace character, so banging here is safe.
        let lastNonWhitespace = self.utf8.lastIndex(where: { !$0.isASCIIWhitespace })!
        return Substring(self.utf8[firstNonWhitespace...lastNonWhitespace])
    }
}

extension HTTPHeaders: Equatable {
    public static func ==(lhs: HTTPHeaders, rhs: HTTPHeaders) -> Bool {
        guard lhs.headers.count == rhs.headers.count else {
            return false
        }
        let lhsNames = Set(lhs.names.map { $0.lowercased() })
        let rhsNames = Set(rhs.names.map { $0.lowercased() })
        guard lhsNames == rhsNames else {
            return false
        }

        for name in lhsNames {
            guard lhs[name].sorted() == rhs[name].sorted() else {
                return false
            }
        }

        return true
    }
}

public enum HTTPMethod: Equatable {
    internal enum HasBody {
        case yes
        case no
        case unlikely
    }

    case GET
    case PUT
    case ACL
    case HEAD
    case POST
    case COPY
    case LOCK
    case MOVE
    case BIND
    case LINK
    case PATCH
    case TRACE
    case MKCOL
    case MERGE
    case PURGE
    case NOTIFY
    case SEARCH
    case UNLOCK
    case REBIND
    case UNBIND
    case REPORT
    case DELETE
    case UNLINK
    case CONNECT
    case MSEARCH
    case OPTIONS
    case PROPFIND
    case CHECKOUT
    case PROPPATCH
    case SUBSCRIBE
    case MKCALENDAR
    case MKACTIVITY
    case UNSUBSCRIBE
    case SOURCE
    case RAW(value: String)

    /// Whether requests with this verb may have a request body.
    internal var hasRequestBody: HasBody {
        switch self {
        case .TRACE:
            return .no
        case .POST, .PUT, .PATCH:
            return .yes
        case .GET, .CONNECT, .OPTIONS, .HEAD, .DELETE:
            fallthrough
        default:
            return .unlikely
        }
    }
}

/// A structure representing a HTTP version.
public struct HTTPVersion: Equatable {
    /// Create a HTTP version.
    ///
    /// - Parameter major: The major version number.
    /// - Parameter minor: The minor version number.
    public init(major: Int, minor: Int) {
        self._major = UInt16(major)
        self._minor = UInt16(minor)
    }

    private var _minor: UInt16
    private var _major: UInt16

    /// The major version number.
    public var major: Int {
        get {
            return Int(self._major)
        }
        set {
            self._major = UInt16(newValue)
        }
    }

    /// The minor version number.
    public var minor: Int {
        get {
            return Int(self._minor)
        }
        set {
            self._minor = UInt16(newValue)
        }
    }

    /// HTTP/3
    public static let http3 = HTTPVersion(major: 3, minor: 0)

    /// HTTP/2
    public static let http2 = HTTPVersion(major: 2, minor: 0)

    /// HTTP/1.1
    public static let http1_1 = HTTPVersion(major: 1, minor: 1)

    /// HTTP/1.0
    public static let http1_0 = HTTPVersion(major: 1, minor: 0)

    /// HTTP/0.9 (not supported by SwiftNIO)
    public static let http0_9 = HTTPVersion(major: 0, minor: 9)
}

extension HTTPParserError: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .invalidCharactersUsed:
            return "illegal characters used in URL/headers"
        case .trailingGarbage:
            return "trailing garbage bytes"
        case .invalidEOFState:
            return "stream ended at an unexpected time"
        case .headerOverflow:
            return "too many header bytes seen; overflow detected"
        case .closedConnection:
            return "data received after completed connection: close message"
        case .invalidVersion:
            return "invalid HTTP version"
        case .invalidStatus:
            return "invalid HTTP status code"
        case .invalidMethod:
            return "invalid HTTP method"
        case .invalidURL:
            return "invalid URL"
        case .invalidHost:
            return "invalid host"
        case .invalidPort:
            return  "invalid port"
        case .invalidPath:
            return "invalid path"
        case .invalidQueryString:
            return "invalid query string"
        case .invalidFragment:
            return "invalid fragment"
        case .lfExpected:
            return "LF character expected"
        case .invalidHeaderToken:
            return "invalid character in header"
        case .invalidContentLength:
            return "invalid character in content-length header"
        case .unexpectedContentLength:
            return "unexpected content-length header"
        case .invalidChunkSize:
            return "invalid character in chunk size header"
        case .invalidConstant:
            return "invalid constant string"
        case .invalidInternalState:
            return "invalid internal state (swift-http-parser error)"
        case .strictModeAssertion:
            return "strict mode assertion"
        case .paused:
            return "paused (swift-http-parser error)"
        case .unknown:
            return "unknown (http_parser error)"
        }
    }
}

/// Errors that can be raised while parsing HTTP/1.1.
public enum HTTPParserError: Error {
    case invalidCharactersUsed
    case trailingGarbage
    /* from CHTTPParser */
    case invalidEOFState
    case headerOverflow
    case closedConnection
    case invalidVersion
    case invalidStatus
    case invalidMethod
    case invalidURL
    case invalidHost
    case invalidPort
    case invalidPath
    case invalidQueryString
    case invalidFragment
    case lfExpected
    case invalidHeaderToken
    case invalidContentLength
    case unexpectedContentLength
    case invalidChunkSize
    case invalidConstant
    case invalidInternalState
    case strictModeAssertion
    case paused
    case unknown
}

extension HTTPResponseStatus {
    /// The numerical status code for a given HTTP response status.
    public var code: UInt {
        get {
            switch self {
            case .continue:
                return 100
            case .switchingProtocols:
                return 101
            case .processing:
                return 102
            case .ok:
                return 200
            case .created:
                return 201
            case .accepted:
                return 202
            case .nonAuthoritativeInformation:
                return 203
            case .noContent:
                return 204
            case .resetContent:
                return 205
            case .partialContent:
                return 206
            case .multiStatus:
                return 207
            case .alreadyReported:
                return 208
            case .imUsed:
                return 226
            case .multipleChoices:
                return 300
            case .movedPermanently:
                return 301
            case .found:
                return 302
            case .seeOther:
                return 303
            case .notModified:
                return 304
            case .useProxy:
                return 305
            case .temporaryRedirect:
                return 307
            case .permanentRedirect:
                return 308
            case .badRequest:
                return 400
            case .unauthorized:
                return 401
            case .paymentRequired:
                return 402
            case .forbidden:
                return 403
            case .notFound:
                return 404
            case .methodNotAllowed:
                return 405
            case .notAcceptable:
                return 406
            case .proxyAuthenticationRequired:
                return 407
            case .requestTimeout:
                return 408
            case .conflict:
                return 409
            case .gone:
                return 410
            case .lengthRequired:
                return 411
            case .preconditionFailed:
                return 412
            case .payloadTooLarge:
                return 413
            case .uriTooLong:
                return 414
            case .unsupportedMediaType:
                return 415
            case .rangeNotSatisfiable:
                return 416
            case .expectationFailed:
                return 417
            case .imATeapot:
                return 418
            case .misdirectedRequest:
                return 421
            case .unprocessableEntity:
                return 422
            case .locked:
                return 423
            case .failedDependency:
                return 424
            case .upgradeRequired:
                return 426
            case .preconditionRequired:
                return 428
            case .tooManyRequests:
                return 429
            case .requestHeaderFieldsTooLarge:
                return 431
            case .unavailableForLegalReasons:
                return 451
            case .internalServerError:
                return 500
            case .notImplemented:
                return 501
            case .badGateway:
                return 502
            case .serviceUnavailable:
                return 503
            case .gatewayTimeout:
                return 504
            case .httpVersionNotSupported:
                return 505
            case .variantAlsoNegotiates:
                return 506
            case .insufficientStorage:
                return 507
            case .loopDetected:
                return 508
            case .notExtended:
                return 510
            case .networkAuthenticationRequired:
                return 511
            case .custom(code: let code, reasonPhrase: _):
                return code
            }
        }
    }

    /// The string reason phrase for a given HTTP response status.
    public var reasonPhrase: String {
        get {
            switch self {
            case .continue:
                return "Continue"
            case .switchingProtocols:
                return "Switching Protocols"
            case .processing:
                return "Processing"
            case .ok:
                return "OK"
            case .created:
                return "Created"
            case .accepted:
                return "Accepted"
            case .nonAuthoritativeInformation:
                return "Non-Authoritative Information"
            case .noContent:
                return "No Content"
            case .resetContent:
                return "Reset Content"
            case .partialContent:
                return "Partial Content"
            case .multiStatus:
                return "Multi-Status"
            case .alreadyReported:
                return "Already Reported"
            case .imUsed:
                return "IM Used"
            case .multipleChoices:
                return "Multiple Choices"
            case .movedPermanently:
                return "Moved Permanently"
            case .found:
                return "Found"
            case .seeOther:
                return "See Other"
            case .notModified:
                return "Not Modified"
            case .useProxy:
                return "Use Proxy"
            case .temporaryRedirect:
                return "Temporary Redirect"
            case .permanentRedirect:
                return "Permanent Redirect"
            case .badRequest:
                return "Bad Request"
            case .unauthorized:
                return "Unauthorized"
            case .paymentRequired:
                return "Payment Required"
            case .forbidden:
                return "Forbidden"
            case .notFound:
                return "Not Found"
            case .methodNotAllowed:
                return "Method Not Allowed"
            case .notAcceptable:
                return "Not Acceptable"
            case .proxyAuthenticationRequired:
                return "Proxy Authentication Required"
            case .requestTimeout:
                return "Request Timeout"
            case .conflict:
                return "Conflict"
            case .gone:
                return "Gone"
            case .lengthRequired:
                return "Length Required"
            case .preconditionFailed:
                return "Precondition Failed"
            case .payloadTooLarge:
                return "Payload Too Large"
            case .uriTooLong:
                return "URI Too Long"
            case .unsupportedMediaType:
                return "Unsupported Media Type"
            case .rangeNotSatisfiable:
                return "Range Not Satisfiable"
            case .expectationFailed:
                return "Expectation Failed"
            case .imATeapot:
                return "I'm a teapot"
            case .misdirectedRequest:
                return "Misdirected Request"
            case .unprocessableEntity:
                return "Unprocessable Entity"
            case .locked:
                return "Locked"
            case .failedDependency:
                return "Failed Dependency"
            case .upgradeRequired:
                return "Upgrade Required"
            case .preconditionRequired:
                return "Precondition Required"
            case .tooManyRequests:
                return "Too Many Requests"
            case .requestHeaderFieldsTooLarge:
                return "Request Header Fields Too Large"
            case .unavailableForLegalReasons:
                return "Unavailable For Legal Reasons"
            case .internalServerError:
                return "Internal Server Error"
            case .notImplemented:
                return "Not Implemented"
            case .badGateway:
                return "Bad Gateway"
            case .serviceUnavailable:
                return "Service Unavailable"
            case .gatewayTimeout:
                return "Gateway Timeout"
            case .httpVersionNotSupported:
                return "HTTP Version Not Supported"
            case .variantAlsoNegotiates:
                return "Variant Also Negotiates"
            case .insufficientStorage:
                return "Insufficient Storage"
            case .loopDetected:
                return "Loop Detected"
            case .notExtended:
                return "Not Extended"
            case .networkAuthenticationRequired:
                return "Network Authentication Required"
            case .custom(code: _, reasonPhrase: let phrase):
                return phrase
            }
        }
    }
}

/// A HTTP response status code.
public enum HTTPResponseStatus {
    /* use custom if you want to use a non-standard response code or
     have it available in a (UInt, String) pair from a higher-level web framework. */
    case custom(code: UInt, reasonPhrase: String)

    /* all the codes from http://www.iana.org/assignments/http-status-codes */

    // 1xx
    case `continue`
    case switchingProtocols
    case processing
    // TODO: add '103: Early Hints' (requires bumping SemVer major).

    // 2xx
    case ok
    case created
    case accepted
    case nonAuthoritativeInformation
    case noContent
    case resetContent
    case partialContent
    case multiStatus
    case alreadyReported
    case imUsed

    // 3xx
    case multipleChoices
    case movedPermanently
    case found
    case seeOther
    case notModified
    case useProxy
    case temporaryRedirect
    case permanentRedirect

    // 4xx
    case badRequest
    case unauthorized
    case paymentRequired
    case forbidden
    case notFound
    case methodNotAllowed
    case notAcceptable
    case proxyAuthenticationRequired
    case requestTimeout
    case conflict
    case gone
    case lengthRequired
    case preconditionFailed
    case payloadTooLarge
    case uriTooLong
    case unsupportedMediaType
    case rangeNotSatisfiable
    case expectationFailed
    case imATeapot
    case misdirectedRequest
    case unprocessableEntity
    case locked
    case failedDependency
    case upgradeRequired
    case preconditionRequired
    case tooManyRequests
    case requestHeaderFieldsTooLarge
    case unavailableForLegalReasons

    // 5xx
    case internalServerError
    case notImplemented
    case badGateway
    case serviceUnavailable
    case gatewayTimeout
    case httpVersionNotSupported
    case variantAlsoNegotiates
    case insufficientStorage
    case loopDetected
    case notExtended
    case networkAuthenticationRequired

    /// Whether responses with this status code may have a response body.
    public var mayHaveResponseBody: Bool {
        switch self {
        case .`continue`,
             .switchingProtocols,
             .processing,
             .noContent,
             .custom where (code < 200) && (code >= 100):
            return false
        default:
            return true
        }
    }

    /// Initialize a `HTTPResponseStatus` from a given status and reason.
    ///
    /// - Parameter statusCode: The integer value of the HTTP response status code
    /// - Parameter reasonPhrase: The textual reason phrase from the response. This will be
    ///     discarded in favor of the default if the `statusCode` matches one that we know.
    public init(statusCode: Int, reasonPhrase: String = "") {
        switch statusCode {
        case 100:
            self = .`continue`
        case 101:
            self = .switchingProtocols
        case 102:
            self = .processing
        case 200:
            self = .ok
        case 201:
            self = .created
        case 202:
            self = .accepted
        case 203:
            self = .nonAuthoritativeInformation
        case 204:
            self = .noContent
        case 205:
            self = .resetContent
        case 206:
            self = .partialContent
        case 207:
            self = .multiStatus
        case 208:
            self = .alreadyReported
        case 226:
            self = .imUsed
        case 300:
            self = .multipleChoices
        case 301:
            self = .movedPermanently
        case 302:
            self = .found
        case 303:
            self = .seeOther
        case 304:
            self = .notModified
        case 305:
            self = .useProxy
        case 307:
            self = .temporaryRedirect
        case 308:
            self = .permanentRedirect
        case 400:
            self = .badRequest
        case 401:
            self = .unauthorized
        case 402:
            self = .paymentRequired
        case 403:
            self = .forbidden
        case 404:
            self = .notFound
        case 405:
            self = .methodNotAllowed
        case 406:
            self = .notAcceptable
        case 407:
            self = .proxyAuthenticationRequired
        case 408:
            self = .requestTimeout
        case 409:
            self = .conflict
        case 410:
            self = .gone
        case 411:
            self = .lengthRequired
        case 412:
            self = .preconditionFailed
        case 413:
            self = .payloadTooLarge
        case 414:
            self = .uriTooLong
        case 415:
            self = .unsupportedMediaType
        case 416:
            self = .rangeNotSatisfiable
        case 417:
            self = .expectationFailed
        case 418:
            self = .imATeapot
        case 421:
            self = .misdirectedRequest
        case 422:
            self = .unprocessableEntity
        case 423:
            self = .locked
        case 424:
            self = .failedDependency
        case 426:
            self = .upgradeRequired
        case 428:
            self = .preconditionRequired
        case 429:
            self = .tooManyRequests
        case 431:
            self = .requestHeaderFieldsTooLarge
        case 451:
            self = .unavailableForLegalReasons
        case 500:
            self = .internalServerError
        case 501:
            self = .notImplemented
        case 502:
            self = .badGateway
        case 503:
            self = .serviceUnavailable
        case 504:
            self = .gatewayTimeout
        case 505:
            self = .httpVersionNotSupported
        case 506:
            self = .variantAlsoNegotiates
        case 507:
            self = .insufficientStorage
        case 508:
            self = .loopDetected
        case 510:
            self = .notExtended
        case 511:
            self = .networkAuthenticationRequired
        default:
            self = .custom(code: UInt(statusCode), reasonPhrase: reasonPhrase)
        }
    }
}

extension HTTPResponseStatus: Equatable {}

extension HTTPResponseStatus: Hashable {}

extension HTTPRequestHead: CustomStringConvertible {
    public var description: String {
        return "HTTPRequestHead { method: \(self.method), uri: \"\(self.uri)\", version: \(self.version), headers: \(self.headers) }"
    }
}

extension HTTPResponseHead: CustomStringConvertible {
    public var description: String {
        return "HTTPResponseHead { version: \(self.version), status: \(self.status), headers: \(self.headers) }"
    }
}

extension HTTPVersion: CustomStringConvertible {
    public var description: String {
        return "HTTP/\(self.major).\(self.minor)"
    }
}

extension HTTPMethod: RawRepresentable {
    public var rawValue: String {
        switch self {
            case .GET:
                return "GET"
            case .PUT:
                return "PUT"
            case .ACL:
                return "ACL"
            case .HEAD:
                return "HEAD"
            case .POST:
                return "POST"
            case .COPY:
                return "COPY"
            case .LOCK:
                return "LOCK"
            case .MOVE:
                return "MOVE"
            case .BIND:
                return "BIND"
            case .LINK:
                return "LINK"
            case .PATCH:
                return "PATCH"
            case .TRACE:
                return "TRACE"
            case .MKCOL:
                return "MKCOL"
            case .MERGE:
                return "MERGE"
            case .PURGE:
                return "PURGE"
            case .NOTIFY:
                return "NOTIFY"
            case .SEARCH:
                return "SEARCH"
            case .UNLOCK:
                return "UNLOCK"
            case .REBIND:
                return "REBIND"
            case .UNBIND:
                return "UNBIND"
            case .REPORT:
                return "REPORT"
            case .DELETE:
                return "DELETE"
            case .UNLINK:
                return "UNLINK"
            case .CONNECT:
                return "CONNECT"
            case .MSEARCH:
                return "MSEARCH"
            case .OPTIONS:
                return "OPTIONS"
            case .PROPFIND:
                return "PROPFIND"
            case .CHECKOUT:
                return "CHECKOUT"
            case .PROPPATCH:
                return "PROPPATCH"
            case .SUBSCRIBE:
                return "SUBSCRIBE"
            case .MKCALENDAR:
                return "MKCALENDAR"
            case .MKACTIVITY:
                return "MKACTIVITY"
            case .UNSUBSCRIBE:
                return "UNSUBSCRIBE"
            case .SOURCE:
                return "SOURCE"
            case let .RAW(value):
                return value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
            case "GET":
                self = .GET
            case "PUT":
                self = .PUT
            case "ACL":
                self = .ACL
            case "HEAD":
                self = .HEAD
            case "POST":
                self = .POST
            case "COPY":
                self = .COPY
            case "LOCK":
                self = .LOCK
            case "MOVE":
                self = .MOVE
            case "BIND":
                self = .BIND
            case "LINK":
                self = .LINK
            case "PATCH":
                self = .PATCH
            case "TRACE":
                self = .TRACE
            case "MKCOL":
                self = .MKCOL
            case "MERGE":
                self = .MERGE
            case "PURGE":
                self = .PURGE
            case "NOTIFY":
                self = .NOTIFY
            case "SEARCH":
                self = .SEARCH
            case "UNLOCK":
                self = .UNLOCK
            case "REBIND":
                self = .REBIND
            case "UNBIND":
                self = .UNBIND
            case "REPORT":
                self = .REPORT
            case "DELETE":
                self = .DELETE
            case "UNLINK":
                self = .UNLINK
            case "CONNECT":
                self = .CONNECT
            case "MSEARCH":
                self = .MSEARCH
            case "OPTIONS":
                self = .OPTIONS
            case "PROPFIND":
                self = .PROPFIND
            case "CHECKOUT":
                self = .CHECKOUT
            case "PROPPATCH":
                self = .PROPPATCH
            case "SUBSCRIBE":
                self = .SUBSCRIBE
            case "MKCALENDAR":
                self = .MKCALENDAR
            case "MKACTIVITY":
                self = .MKACTIVITY
            case "UNSUBSCRIBE":
                self = .UNSUBSCRIBE
            case "SOURCE":
                self = .SOURCE
            default:
                self = .RAW(value: rawValue)
        }
    }
}

extension HTTPResponseHead {
    internal var contentLength: Int? {
        return headers.contentLength
    }
}

extension HTTPRequestHead {
    internal var contentLength: Int? {
        return headers.contentLength
    }
}

extension HTTPHeaders {
    internal var contentLength: Int? {
        return self.first(name: "content-length").flatMap { Int($0) }
    }
}
