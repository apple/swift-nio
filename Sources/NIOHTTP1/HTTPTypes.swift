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

let crlf: StaticString = "\r\n"
let headerSeparator: StaticString = ": "

/// A representation of the request line and header fields of a HTTP request.
public struct HTTPRequestHead: Equatable {
    /// The HTTP method for this request.
    public var method: HTTPMethod

    // Internal representation of the URI.
    private var rawURI: URI

    /// The URI used on this request.
    public var uri: String {
        get { 
            return String(uri: rawURI) 
        }
        set { 
            rawURI = .string(newValue) 
        }
    }

    /// The version for this HTTP request.
    public var version: HTTPVersion

    /// The header fields for this HTTP request.
    public var headers: HTTPHeaders

    /// Create a `HTTPRequestHead`
    ///
    /// - Parameter version: The version for this HTTP request.
    /// - Parameter method: The HTTP method for this request.
    /// - Parameter uri: The URI used on this request.
    public init(version: HTTPVersion, method: HTTPMethod, uri: String) {
        self.init(version: version, method: method, rawURI: .string(uri), headers: HTTPHeaders())
    }

    /// Create a `HTTPRequestHead`
    ///
    /// - Parameter version: The version for this HTTP request.
    /// - Parameter method: The HTTP method for this request.
    /// - Parameter rawURI: The URI used on this request.
    /// - Parameter headers: The headers for this HTTP request.
    init(version: HTTPVersion, method: HTTPMethod, rawURI: URI, headers: HTTPHeaders) {
        self.version = version
        self.method = method
        self.rawURI = rawURI
        self.headers = headers
    }

    public static func ==(lhs: HTTPRequestHead, rhs: HTTPRequestHead) -> Bool {
        return lhs.method == rhs.method && lhs.uri == rhs.uri && lhs.version == rhs.version && lhs.headers == rhs.headers
    }
}

/// Internal representation of a URI
enum URI {
    case string(String)
    case byteBuffer(ByteBuffer)
}

private extension String {
    init(uri: URI) {
        switch uri {
        case .string(let string):
            self = string
        case .byteBuffer(let buffer):
            self = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes)!
        }
    }
}

/// The parts of a complete HTTP message, either request or response.
///
/// A HTTP message is made up of a request or status line with several headers,
/// encoded by `.head`, zero or more body parts, and optionally some trailers. To
/// indicate that a complete HTTP message has been sent or received, we use `.end`,
/// which may also contain any trailers that make up the mssage.
public enum HTTPPart<HeadT: Equatable, BodyT: Equatable> {
    case head(HeadT)
    case body(BodyT)
    case end(HTTPHeaders?)
}

extension HTTPPart: Equatable {
    public static func ==(lhs: HTTPPart, rhs: HTTPPart) -> Bool {
        switch (lhs, rhs) {
        case (.head(let h1), .head(let h2)):
            return h1 == h2
        case (.body(let b1), .body(let b2)):
            return b1 == b2
        case (.end(let h1), .end(let h2)):
            return h1 == h2
        case (.head, _), (.body, _), (.end, _):
            return false
        }
    }
}

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
        guard let connection = headers[.connection].first?.lowercased() else {
            // HTTP 1.1 use keep-alive by default if not otherwise told.
            return version.major == 1 && version.minor == 1
        }

        if connection == "close" {
            return false
        }
        return connection == "keep-alive"
    }
}

/// A representation of the status line and header fields of a HTTP response.
public struct HTTPResponseHead: Equatable {
    /// The HTTP response status.
    public var status: HTTPResponseStatus

    /// The HTTP version that corresponds to this response.
    public var version: HTTPVersion

    /// The HTTP headers on this response.
    public var headers: HTTPHeaders

    /// Create a `HTTPResponseHead`
    ///
    /// - Parameter version: The version for this HTTP response.
    /// - Parameter status: The status for this HTTP response.
    /// - Parameter headers: The headers for this HTTP response.
    public init(version: HTTPVersion, status: HTTPResponseStatus, headers: HTTPHeaders = HTTPHeaders()) {
        self.version = version
        self.status = status
        self.headers = headers
    }

    public static func ==(lhs: HTTPResponseHead, rhs: HTTPResponseHead) -> Bool {
        return lhs.status == rhs.status && lhs.version == rhs.version && lhs.headers == rhs.headers
    }
}

/// The Index for a header name or value that points into the underlying `ByteBuffer`.
struct HTTPHeaderIndex {
    let start: Int
    let length: Int
}

/// Struct which holds name, value pairs.
struct HTTPHeader {
    let name: HTTPHeaderIndex
    let value: HTTPHeaderIndex
}


private extension UInt8 {
    var isASCII: Bool {
        return self <= 127
    }

    var maskedASCIILowercase: UInt8 {
        return self & 0xdf
    }
}


/// Known HTTP header name. These should be created once and re-used as instances are memory intensive and "expensive" to create.
public struct HTTPHeaderName {

    /// Box for different fields to reduce reference count overhead.
    private final class _Storage {
        /// Holds the bytes of the name + ': '
        let bytesWithSeparator: ContiguousArray<UInt8>
        /// Holds the lowercased bases (masked) of the name.
        let lowerCaseBytes: ContiguousArray<UInt8>

        let lowerCaseName: String

        init(_ value: String) {
            precondition(!value.utf8.contains(where: { !$0.isASCII }), "name must be ASCII")
            var array = ContiguousArray(value.utf8)
            array.append(contentsOf: ": ".utf8)
            self.bytesWithSeparator = array
            self.lowerCaseBytes = ContiguousArray(self.bytesWithSeparator.lazy.dropLast(2).map { $0.maskedASCIILowercase })
            self.lowerCaseName = value.lowercased()
        }
    }

    private let storage: _Storage

    /// Holds the bytes of the name + ': '
    fileprivate var bytesWithSeparator: ContiguousArray<UInt8> {
        return storage.bytesWithSeparator
    }

    /// Holds the lowercased bases (masked) of the name.
    fileprivate var lowerCaseBytes: ContiguousArray<UInt8> {
        return storage.lowerCaseBytes
    }

    fileprivate var lowerCaseName: String {
        return storage.lowerCaseName
    }

    /// Create a new `HTTPHeaderName`.
    ///
    /// - Parameter value: The value of the header.
    public init(_ value: String) {
        self.storage = _Storage(value)
    }
}

extension HTTPHeaderName: Equatable {
    public static func ==(lhs: HTTPHeaderName, rhs: HTTPHeaderName) -> Bool {
        return lhs.lowerCaseBytes == rhs.lowerCaseBytes
    }
}

extension HTTPHeaderName: CustomStringConvertible {
    public var description: String {
        return self.lowerCaseName
    }
}

/// Defines commonly used HTTP header names.
public extension HTTPHeaderName {
    public static let aIM = HTTPHeaderName("a-im")
    public static let accept = HTTPHeaderName("Accept")
    public static let acceptAdditions = HTTPHeaderName("accept-additions")
    public static let acceptCharset = HTTPHeaderName("accept-charset")
    public static let acceptDatetime = HTTPHeaderName("accept-datetime")
    public static let acceptEncoding = HTTPHeaderName("accept-encoding")
    public static let acceptFeatures = HTTPHeaderName("accept-features")
    public static let acceptLanguage = HTTPHeaderName("accept-language")
    public static let acceptPatch = HTTPHeaderName("accept-patch")
    public static let acceptPost = HTTPHeaderName("accept-post")
    public static let acceptRanges = HTTPHeaderName("accept-ranges")
    public static let accessControl = HTTPHeaderName("access-control")
    public static let accessControlAllowCredentials = HTTPHeaderName("access-control-allow-credentials")
    public static let accessControlAllowHeaders = HTTPHeaderName("access-control-allow-headers")
    public static let accessControlAllowMethods = HTTPHeaderName("access-control-allow-methods")
    public static let accessControlAllowOrigin = HTTPHeaderName("access-control-allow-origin")
    public static let accessControlExpose = HTTPHeaderName("access-control-expose-headers")
    public static let accessControlMaxAge = HTTPHeaderName("access-control-max-age")
    public static let accessControlRequestMethod = HTTPHeaderName("access-control-request-method")
    public static let accessControlRequestHeaders = HTTPHeaderName("access-control-request-headers")
    public static let age = HTTPHeaderName("age")
    public static let allow = HTTPHeaderName("allow")
    public static let alpn = HTTPHeaderName("alpn")
    public static let alternates = HTTPHeaderName("alternates")
    public static let altSvc = HTTPHeaderName("alt-svc")
    public static let altUsed = HTTPHeaderName("alt-used")
    public static let applyToRedirectRef = HTTPHeaderName("apply-to-redirect-ref")
    public static let authenticationControl = HTTPHeaderName("authentication-control")
    public static let authenticationInfo = HTTPHeaderName("authentication-info")
    public static let authorization = HTTPHeaderName("authorization")
    public static let cacheControl = HTTPHeaderName("cache-control")
    public static let calDAVTimezones = HTTPHeaderName("caldav-timezones")
    public static let cExt = HTTPHeaderName("c-ext")
    public static let close = HTTPHeaderName("close")
    public static let cMan = HTTPHeaderName("c-man")
    public static let cOpt = HTTPHeaderName("c-opt")
    public static let compliance = HTTPHeaderName("compliance")
    public static let connection = HTTPHeaderName("connection")
    public static let contentBase = HTTPHeaderName("content-base")
    public static let contentDisposition = HTTPHeaderName("content-disposition")
    public static let contentEncoding = HTTPHeaderName("content-encoding")
    public static let contentID = HTTPHeaderName("content-id")
    public static let contentLanguage = HTTPHeaderName("content-language")
    public static let contentLength = HTTPHeaderName("content-length")
    public static let contentLocation = HTTPHeaderName("content-location")
    public static let contentMD5 = HTTPHeaderName("content-md5")
    public static let contentRange = HTTPHeaderName("content-range")
    public static let contentScriptType = HTTPHeaderName("content-script-type")
    public static let contentSecurityPolicy = HTTPHeaderName("content-security-policy")
    public static let contentSecurityPolicyReportOnly = HTTPHeaderName("content-security-policy-reporty-only")
    public static let contentStyleType = HTTPHeaderName("content-style-type")
    public static let contentTransferEncoding = HTTPHeaderName("content-transfer-encoding")
    public static let contentType = HTTPHeaderName("content-type")
    public static let contentVersion = HTTPHeaderName("content-version")
    public static let cookie = HTTPHeaderName("cookie")
    public static let cookie2 = HTTPHeaderName("cookie2")
    public static let cost = HTTPHeaderName("cost")
    public static let cPEP = HTTPHeaderName("c-pep")
    public static let cPEPInfo = HTTPHeaderName("c-pep-info")
    public static let dasl = HTTPHeaderName("dasl")
    public static let dav = HTTPHeaderName("dav")
    public static let date = HTTPHeaderName("date")
    public static let defaultStyle = HTTPHeaderName("default-style")
    public static let deltaBase = HTTPHeaderName("delta-base")
    public static let depth = HTTPHeaderName("depth")
    public static let derivedFrom = HTTPHeaderName("derived-from")
    public static let destination = HTTPHeaderName("destination")
    public static let differentialID = HTTPHeaderName("differential-id")
    public static let digest = HTTPHeaderName("digest")
    public static let ediintFeatures = HTTPHeaderName("ediint-features")
    public static let eTag = HTTPHeaderName("etag")
    public static let expect = HTTPHeaderName("expect")
    public static let expires = HTTPHeaderName("expires")
    public static let ext = HTTPHeaderName("ext")
    public static let forwarded = HTTPHeaderName("forwarded")
    public static let from = HTTPHeaderName("from")
    public static let getProfile = HTTPHeaderName("getprofile")
    public static let hobareg = HTTPHeaderName("hobareg")
    public static let host = HTTPHeaderName("host")
    public static let http2Settings = HTTPHeaderName("http2-settings")
    public static let im = HTTPHeaderName("im")
    public static let `if` = HTTPHeaderName("if")
    public static let ifMatch = HTTPHeaderName("if-match")
    public static let ifModifiedSince = HTTPHeaderName("if-modified-since")
    public static let ifNoneMatch = HTTPHeaderName("if-none-match")
    public static let ifRange = HTTPHeaderName("if-range")
    public static let ifScheduleTagMatch = HTTPHeaderName("if-schedule-tag-match")
    public static let ifUnmodifiedSince = HTTPHeaderName("if-unmodified-since")
    public static let keepAlive = HTTPHeaderName("keep-alive")
    public static let label = HTTPHeaderName("label")
    public static let lastModified = HTTPHeaderName("last-modified")
    public static let link = HTTPHeaderName("link")
    public static let location = HTTPHeaderName("location")
    public static let lockToken = HTTPHeaderName("lock-token")
    public static let man = HTTPHeaderName("man")
    public static let maxForwards = HTTPHeaderName("max-forwards")
    public static let mementoDatetime = HTTPHeaderName("memento-datetime")
    public static let messageID = HTTPHeaderName("message-id")
    public static let meter = HTTPHeaderName("meter")
    public static let methodCheck = HTTPHeaderName("method-check")
    public static let methodCheckExpires = HTTPHeaderName("method-check-expires")
    public static let mimeVersion = HTTPHeaderName("mime-version")
    public static let negotiate = HTTPHeaderName("negotiate")
    public static let nonCompliance = HTTPHeaderName("non-compliance")
    public static let opt = HTTPHeaderName("opt")
    public static let optional = HTTPHeaderName("optional")
    public static let optionalWWWAuthenticate = HTTPHeaderName("optional-ww-authenticate")
    public static let orderingType = HTTPHeaderName("ordering-type")
    public static let origin = HTTPHeaderName("origin")
    public static let overwrite = HTTPHeaderName("overwrite")
    public static let p3p = HTTPHeaderName("p3p")
    public static let pep = HTTPHeaderName("pep")
    public static let pepInfo = HTTPHeaderName("pep-info")
    public static let picsLabel = HTTPHeaderName("pics-label")
    public static let position = HTTPHeaderName("position")
    public static let pragma = HTTPHeaderName("pragma")
    public static let prefer = HTTPHeaderName("prefer")
    public static let preferenceApplied = HTTPHeaderName("preference-applied")
    public static let profileObject = HTTPHeaderName("profileobject")
    public static let `protocol` = HTTPHeaderName("protocol")
    public static let protocolInfo = HTTPHeaderName("protocol-info")
    public static let protocolQuery = HTTPHeaderName("protocol-query")
    public static let protocolRequest = HTTPHeaderName("protocol-request")
    public static let proxyAuthenticate = HTTPHeaderName("proxy-authenticate")
    public static let proxyAuthenticationInfo = HTTPHeaderName("proxy-authentication-info")
    public static let proxyAuthorization = HTTPHeaderName("proxy-authorization")
    public static let proxyFeatures = HTTPHeaderName("proxy-features")
    public static let proxyInstruction = HTTPHeaderName("proxy-instruction")
    public static let `public` = HTTPHeaderName("public")
    public static let publicKeyPins = HTTPHeaderName("public-key-pins")
    public static let publicKeyPinsReportOnly = HTTPHeaderName("public-key-pins-report-only")
    public static let range = HTTPHeaderName("range")
    public static let redirectRef = HTTPHeaderName("redirect-ref")
    public static let referer = HTTPHeaderName("referer")
    public static let refererRoot = HTTPHeaderName("referer-root")
    public static let resolutionHint = HTTPHeaderName("resolution-hint")
    public static let resolverLocation = HTTPHeaderName("resolver-location")
    public static let retryAfter = HTTPHeaderName("retry-after")
    public static let safe = HTTPHeaderName("safe")
    public static let scheduleReply = HTTPHeaderName("schedule-reply")
    public static let scheduleTag = HTTPHeaderName("schedule-tag")
    public static let secWebSocketAccept = HTTPHeaderName("sec-websocket-accept")
    public static let secWebSocketExtensions = HTTPHeaderName("sec-webSocket-extensions")
    public static let secWebSocketKey = HTTPHeaderName("sec-websocket-key")
    public static let secWebSocketProtocol = HTTPHeaderName("sec-websocket-protocol")
    public static let secWebSocketVersion = HTTPHeaderName("sec-websocket-version")
    public static let securityScheme = HTTPHeaderName("security-scheme")
    public static let server = HTTPHeaderName("server")
    public static let setCookie = HTTPHeaderName("set-cookie")
    public static let setCookie2 = HTTPHeaderName("set-cookie2")
    public static let setProfile = HTTPHeaderName("setprofile")
    public static let slug = HTTPHeaderName("slug")
    public static let soapAction = HTTPHeaderName("soapaction")
    public static let statusURI = HTTPHeaderName("status-uri")
    public static let strictTransportSecurity = HTTPHeaderName("strict-transport-security")
    public static let subOK = HTTPHeaderName("subok")
    public static let subst = HTTPHeaderName("subst")
    public static let surrogateCapability = HTTPHeaderName("surrogate-capability")
    public static let surrogateControl = HTTPHeaderName("surrogate-control")
    public static let tcn = HTTPHeaderName("tcn")
    public static let te = HTTPHeaderName("te")
    public static let timeout = HTTPHeaderName("timeout")
    public static let title = HTTPHeaderName("title")
    public static let topic = HTTPHeaderName("topic")
    public static let trailer = HTTPHeaderName("trailer")
    public static let transferEncoding = HTTPHeaderName("transfer-encoding")
    public static let ttl = HTTPHeaderName("ttl")
    public static let uaColor = HTTPHeaderName("ua-color")
    public static let uaMedia = HTTPHeaderName("ua-media")
    public static let uaPixels = HTTPHeaderName("ua-pixels")
    public static let uaResolution = HTTPHeaderName("ua-resolution")
    public static let uaWindowpixels = HTTPHeaderName("ua-windowpixels")
    public static let urgency = HTTPHeaderName("urgency")
    public static let uri = HTTPHeaderName("uri")
    public static let upgrade = HTTPHeaderName("upgrade")
    public static let userAgent = HTTPHeaderName("user-agent")
    public static let variantVary = HTTPHeaderName("variant-vary")
    public static let vary = HTTPHeaderName("vary")
    public static let version = HTTPHeaderName("version")
    public static let via = HTTPHeaderName("via")
    public static let wwwAuthenticate = HTTPHeaderName("www-authenticate")
    public static let wantDigest = HTTPHeaderName("want-digest")
    public static let warning = HTTPHeaderName("warning")
    public static let xContentTypeOptions = HTTPHeaderName("x-content-type-options")
    public static let xDeviceAccept = HTTPHeaderName("x-device-accept")
    public static let xDeviceAcceptCharset = HTTPHeaderName("x-device-accept-charset")
    public static let xDeviceAcceptEncoding = HTTPHeaderName("x-device-accept-encoding")
    public static let xDeviceAcceptLanguage = HTTPHeaderName("x-device-accept-language")
    public static let xDeviceUserAgent = HTTPHeaderName("x-device-user-agent")
    public static let xFrameOptions = HTTPHeaderName("x-frame-options")
    public static let xRequestedWith = HTTPHeaderName("x-requested-with")
    public static let xXssProtection = HTTPHeaderName("x-xss-protection")
}

/// Different types representing HTTP header names.
private enum HTTPHeaderNameType {
    /// Header name represented by a `String`.
    case string(String)
    /// Header name represented by a `HTTPHeaderName`.
    case headerName(HTTPHeaderName)
}

private extension HTTPHeaderNameType {

    var isSetCookie: Bool {
        switch self {
        case .headerName(let name):
            return name == .setCookie
        case .string(let string):
            return HTTPHeaderName.setCookie.equalCaseInsensitiveASCII(name: string)
        }
    }
}

private extension HTTPHeaderName {
    func equalCaseInsensitiveASCII(name: String) -> Bool {
        let utf8 = name.utf8
        return utf8.count == self.lowerCaseBytes.count && utf8.lazy.map { $0.maskedASCIILowercase }.starts(with: self.lowerCaseBytes)
    }
}

/// Extensions dealing with `HTTPHeaderNameType`s.
private extension ByteBuffer {
    /// Writes the `HTTPHeaderNameType` and also the separator (`: `). It returns the length of the name (without the separator).
    mutating func writeWithSeparator(nameType: HTTPHeaderNameType) -> Int {
        switch nameType {
        case .headerName(let name):
            return self.write(bytes: name.bytesWithSeparator) - 2
        case .string(let s):
            let len = self.write(string: s)!
            self.write(staticString: headerSeparator)
            return len
        }
    }

    func equalCaseInsensitiveASCII(nameType: HTTPHeaderNameType, at index: HTTPHeaderIndex) -> Bool {
        switch nameType {
        case .headerName(let name):
            return self.equalCaseInsensitiveASCII(collection: name.lowerCaseBytes, at: index)
        case .string(let string):
            return self.equalCaseInsensitiveASCII(collection: string.utf8, at: index)
        }
    }

    private func equalCaseInsensitiveASCII<C: Collection>(collection: C, at index: HTTPHeaderIndex) -> Bool where C.Element == UInt8 {
        guard collection.count == index.length else {
            return false
        }
        return withVeryUnsafeBytes { buffer in
            // This should never happens as we control when this is called. Adding an assert to ensure this.
            assert(index.start <= self.capacity - index.length)
            let address = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for (idx, byte) in collection.enumerated() {
                guard byte.isASCII && address.advanced(by: index.start + idx).pointee.maskedASCIILowercase == byte.maskedASCIILowercase else {
                    return false
                }
            }
            return true
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
public struct HTTPHeaders: CustomStringConvertible {

    // Because we use CoW implementations HTTPHeaders is also CoW
    fileprivate var buffer: ByteBuffer
    fileprivate var headers: [HTTPHeader]
    fileprivate var continuous: Bool = true

    /// Returns the `String` for the given `HTTPHeaderIndex`.
    ///
    /// - parameters:
    ///     - idx: The index into the underlying storage.
    /// - returns: The value.
    private func string(idx: HTTPHeaderIndex) -> String {
        return self.buffer.getString(at: idx.start, length: idx.length)!
    }

    /// Return all names.
    fileprivate var names: [HTTPHeaderIndex] {
        return self.headers.map { $0.name }
    }

    public var description: String {
        var headersArray: [(String, String)] = []
        headersArray.reserveCapacity(self.headers.count)

        for h in self.headers {
            headersArray.append((self.string(idx: h.name), self.string(idx: h.value)))
        }
        return headersArray.description
    }

    /// Constructor used by our decoder to construct headers without the need of converting bytes to string.
    init(buffer: ByteBuffer, headers: [HTTPHeader]) {
        self.buffer = buffer
        self.headers = headers
    }

    /// Construct a `HTTPHeaders` structure.
    ///
    /// - parameters
    ///     - headers: An initial set of headers to use to populate the header block.
    ///     - allocator: The allocator to use to allocate the underlying storage.
    public init(_ headers: [(String, String)] = []) {
        // Note: this initializer exists becuase of https://bugs.swift.org/browse/SR-7415.
        // Otherwise we'd only have the one below with a default argument for `allocator`.
        self.init(headers, allocator: ByteBufferAllocator())
    }

    /// Construct a `HTTPHeaders` structure.
    ///
    /// - parameters
    ///     - headers: An initial set of headers to use to populate the header block.
    ///     - allocator: The allocator to use to allocate the underlying storage.
    public init(_ headers: [(String, String)] = [], allocator: ByteBufferAllocator) {
        // Reserve enough space in the array to hold all indices.
        var array: [HTTPHeader] = []
        array.reserveCapacity(headers.count)

        self.init(buffer: allocator.buffer(capacity: 256), headers: array)

        for (key, value) in headers {
            self.add(name: key, value: value)
        }
    }

    /// Construct a `HTTPHeaders` structure.
    ///
    /// - parameters
    ///     - headers: An initial set of headers to use to populate the header block.
    ///     - allocator: The allocator to use to allocate the underlying storage.
    public init(_ headers: [(HTTPHeaderName, String)]) {
        // Note: this initializer exists because of https://bugs.swift.org/browse/SR-7415.
        // Otherwise we'd only have the one below with a default argument for `allocator`.
        self.init(headers, allocator: ByteBufferAllocator())
    }

    /// Construct a `HTTPHeaders` structure.
    ///
    /// - parameters
    ///     - headers: An initial set of headers to use to populate the header block.
    ///     - allocator: The allocator to use to allocate the underlying storage.
    public init(_ headers: [(HTTPHeaderName, String)], allocator: ByteBufferAllocator) {
        // Reserve enough space in the array to hold all indices.
        var array: [HTTPHeader] = []
        array.reserveCapacity(headers.count)

        self.init(buffer: allocator.buffer(capacity: 256), headers: array)

        for (key, value) in headers {
            self.add(name: key, value: value)
        }
    }

    /// Add a header name/value pair to the block.
    ///
    /// This method is strictly additive: if there are other values for the given header name
    /// already in the block, this will add a new entry. `add` performs case-insensitive
    /// comparisons on the header field name.
    ///
    /// - Parameter name: The header field name. For maximum compatibility this should be an
    ///     ASCII string. For future-proofing with HTTP/2 lowercase header names are strongly
    //      recommended.
    /// - Parameter value: The header field value to add for the given name.
    public mutating func add(name: String, value: String) {
        precondition(!name.utf8.contains(where: { !$0.isASCII }), "name must be ASCII")
        self.add(nameType: .string(name), value: value)
    }

    /// Add a header name/value pair to the block.
    ///
    /// This method is strictly additive: if there are other values for the given header name
    /// already in the block, this will add a new entry. `add` performs case-insensitive
    /// comparisons on the header field name.
    ///
    /// - Parameter name: The header field `HTTPHeaderName`. For maximum compatibility this should be an
    ///     ASCII string. For future-proofing with HTTP/2 lowercase header names are strongly
    //      recommended.
    /// - Parameter value: The header field value to add for the given name.
    public mutating func add(name: HTTPHeaderName, value: String) {
        self.add(nameType: .headerName(name), value: value)
    }

    private mutating func add(nameType: HTTPHeaderNameType, value: String) {
        let nameStart = self.buffer.writerIndex
        let nameLength = self.buffer.writeWithSeparator(nameType: nameType)
        let valueStart = self.buffer.writerIndex
        let valueLength = self.buffer.write(string: value)!
        self.headers.append(HTTPHeader(name: HTTPHeaderIndex(start: nameStart, length: nameLength), value: HTTPHeaderIndex(start: valueStart, length: valueLength)))
        self.buffer.write(staticString: crlf)
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
        self.remove(name: name)
        self.add(name: name, value: value)
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
    /// - Parameter name: The header field `HTTPHeaderName`. For maximum compatibility this should be an
    ///     ASCII string. For future-proofing with HTTP/2 lowercase header names are strongly
    //      recommended.
    /// - Parameter value: The header field value to add for the given name.
    public mutating func replaceOrAdd(name: HTTPHeaderName, value: String) {
        self.remove(name: name)
        self.add(name: name, value: value)
    }

    private mutating func replaceOrAdd(nameType: HTTPHeaderNameType, value: String) {
        self.remove(nameType: nameType)
        self.add(nameType: nameType, value: value)
    }

    /// Remove all values for a given header name from the block.
    ///
    /// This method uses case-insensitive comparisons for the header field name.
    ///
    /// - Parameter name: The name of the header field to remove from the block.
    public mutating func remove(name: String) {
        self.remove(nameType: .string(name))
    }


    /// Remove all values for a given header name from the block.
    ///
    /// This method uses case-insensitive comparisons for the header field name.
    ///
    /// - Parameter name: The `HTTPHeaderName` of the header field to remove from the block.
    public mutating func remove(name: HTTPHeaderName) {
        self.remove(nameType: .headerName(name))
    }

    private mutating func remove(nameType: HTTPHeaderNameType) {
        guard !self.headers.isEmpty else {
            return
        }

        var array: [Int] = []
        // We scan from the back to the front so we can remove the subranges with as less overhead as possible.
        for idx in stride(from: self.headers.count - 1, to: -1, by: -1) {
            let header = self.headers[idx]
            if self.buffer.equalCaseInsensitiveASCII(nameType: nameType, at: header.name) {
                array.append(idx)
            }
        }

        guard !array.isEmpty else {
            return
        }

        array.forEach {
            self.headers.remove(at: $0)
        }
        self.continuous = false
    }

    /// Retrieve all of the values for a give header field name from the block.
    ///
    /// This method uses case-insensitive comparisons for the header field name. It
    /// does not return a maximally-decomposed list of the header fields, but instead
    /// returns them in their original representation: that means that a comma-separated
    /// header field list may contain more than one entry, some of which contain commas
    /// and some do not. If you want a representation of the header fields suitable for
    /// performing computation on, consider `getCanonicalForm`.
    ///
    /// - Parameter name: The header field name whose values are to be retrieved.
    /// - Returns: A list of the values for that header field name.
    public subscript(name: String) -> [String] {
        return self[name: .string(name)]
    }

    /// Retrieve all of the values for a give header field name from the block.
    ///
    /// This method uses case-insensitive comparisons for the header field name. It
    /// does not return a maximally-decomposed list of the header fields, but instead
    /// returns them in their original representation: that means that a comma-separated
    /// header field list may contain more than one entry, some of which contain commas
    /// and some do not. If you want a representation of the header fields suitable for
    /// performing computation on, consider `getCanonicalForm`.
    ///
    /// - Parameter name: The header field `HTTPHeaderName` whose values are to be retrieved.
    /// - Returns: A list of the values for that header field name.
    public subscript(name: HTTPHeaderName) -> [String] {
        return self[name: .headerName(name)]
    }

    private subscript(name nameType: HTTPHeaderNameType) -> [String] {
        guard !self.headers.isEmpty else {
            return []
        }

        var array: [String] = []
        for header in self.headers {
            if self.buffer.equalCaseInsensitiveASCII(nameType: nameType, at: header.name) {
                array.append(self.string(idx: header.value))
            }
        }
        return array
    }

    /// Checks if a header is present
    ///
    /// - parameters:
    ///     - name: The name of the header
    //  - returns: `true` if a header with the name (and value) exists, `false` otherwise.
    public func contains(name: String) -> Bool {
        return self.contains(nameType: .string(name))
    }

    /// Checks if a header is present
    ///
    /// - parameters:
    ///     - name: The `HTTPHeaderName` of the header
    //  - returns: `true` if a header with the name (and value) exists, `false` otherwise.
    public func contains(name: HTTPHeaderName) -> Bool {
        return self.contains(nameType: .headerName(name))
    }

    private func contains(nameType: HTTPHeaderNameType) -> Bool {
        guard !self.headers.isEmpty else {
            return false
        }

        for header in self.headers {
            if self.buffer.equalCaseInsensitiveASCII(nameType: nameType, at: header.name) {
                return true
            }
        }
        return false
    }
    
    @available(*, deprecated, message: "getCanonicalForm has been changed to a subscript: headers[canonicalForm: name]")
    public func getCanonicalForm(_ name: String) -> [String] {
        return self[canonicalForm: name]
    }

    /// Retrieves the header values for the given header field in "canonical form": that is,
    /// splitting them on commas as extensively as possible such that multiple values received on the
    /// one line are returned as separate entries. Also respects the fact that Set-Cookie should not
    /// be split in this way.
    ///
    /// - Parameter name: The header field name whose values are to be retrieved.
    /// - Returns: A list of the values for that header field name.
    public subscript(canonicalForm name: String) -> [String] {
        return self[canonicalForm: .string(name)]
    }

    /// Retrieves the header values for the given header field in "canonical form": that is,
    /// splitting them on commas as extensively as possible such that multiple values received on the
    /// one line are returned as separate entries. Also respects the fact that Set-Cookie should not
    /// be split in this way.
    ///
    /// - Parameter name: The header field `HTTPHeaderName` whose values are to be retrieved.
    /// - Returns: A list of the values for that header field name.
    public subscript(canonicalForm name: HTTPHeaderName) -> [String] {
        return self[canonicalForm: .headerName(name)]
    }

    private subscript(canonicalForm nameType: HTTPHeaderNameType) -> [String] {
        let result = self[name: nameType]

        guard result.count > 0 else {
            return []
        }

        // It's not safe to split Set-Cookie on comma.
        guard !nameType.isSetCookie else {
            return result
        }

        return result.flatMap { $0.split(separator: ",").map { String($0.trimWhitespace()) } }
    }
}

internal extension ByteBuffer {

    /// Serializes this HTTP header block to bytes suitable for writing to the wire.
    ///
    /// - Parameter buffer: A buffer to write the serialized bytes into. Will increment
    ///     the writer index of this buffer.
    mutating func write(headers: HTTPHeaders) {
        if headers.continuous {
            // Declare an extra variable so we not affect the readerIndex of the buffer itself.
            var buf = headers.buffer
            self.write(buffer: &buf)
        } else {
            // slow-path....
            // TODO: This can still be improved to write as many continuous data as possible and just skip over stuff that was removed.
            for header in headers.self.headers {
                let fieldLength = (header.value.start + header.value.length) - header.name.start
                var header = headers.buffer.getSlice(at: header.name.start, length: fieldLength)!
                self.write(buffer: &header)
                self.write(staticString: crlf)
            }
        }
        self.write(staticString: crlf)
    }
}
extension HTTPHeaders: Sequence {
    public typealias Element = (name: String, value: String)
  
    /// An iterator of HTTP header fields.
    ///
    /// This iterator will return each value for a given header name separately. That
    /// means that `name` is not guaranteed to be unique in a given block of headers.
    public struct Iterator: IteratorProtocol {
        private var headerParts: Array<(String, String)>.Iterator

        fileprivate init(headerParts: Array<(String, String)>.Iterator) {
            self.headerParts = headerParts
        }

        public mutating func next() -> Element? {
            return headerParts.next()
        }
    }  

    public func makeIterator() -> Iterator {
        return Iterator(headerParts: headers.map { (self.string(idx: $0.name), self.string(idx: $0.value)) }.makeIterator())
    }
}

// Dance to ensure that this version of makeIterator(), which returns
// an AnyIterator, is only called when forced through type context.
public protocol _DeprecateHTTPHeaderIterator: Sequence { }
extension HTTPHeaders: _DeprecateHTTPHeaderIterator { }
public extension _DeprecateHTTPHeaderIterator {
  @available(*, deprecated, message: "Please use the HTTPHeaders.Iterator type")
  public func makeIterator() -> AnyIterator<Element> {
    return AnyIterator(makeIterator() as Iterator)
  }  
}

/* private but tests */ internal extension Character {
    var isASCIIWhitespace: Bool {
        return self == " " || self == "\t" || self == "\r" || self == "\n" || self == "\r\n"
    }
}

/* private but tests */ internal extension String {
    func trimASCIIWhitespace() -> Substring {
        return self.dropFirst(0).trimWhitespace()
    }
}

private extension Substring {
    func trimWhitespace() -> Substring {
        var me = self
        while me.first?.isASCIIWhitespace == .some(true) {
            me = me.dropFirst()
        }
        while me.last?.isASCIIWhitespace == .some(true) {
            me = me.dropLast()
        }
        return me
    }
}

extension HTTPHeaders: Equatable {
    public static func ==(lhs: HTTPHeaders, rhs: HTTPHeaders) -> Bool {
        guard lhs.headers.count == rhs.headers.count else {
            return false
        }
        let lhsNames = Set(lhs.names.map { lhs.string(idx: $0).lowercased() })
        let rhsNames = Set(rhs.names.map { rhs.string(idx: $0).lowercased() })
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
    public enum HasBody {
        case yes
        case no
        case unlikely
    }

    public static func ==(lhs: HTTPMethod, rhs: HTTPMethod) -> Bool {
        switch (lhs, rhs){
        case (.GET, .GET):
            return true
        case (.PUT, .PUT):
            return true
        case (.ACL, .ACL):
            return true
        case (.HEAD, .HEAD):
            return true
        case (.POST, .POST):
            return true
        case (.COPY, .COPY):
            return true
        case (.LOCK, .LOCK):
            return true
        case (.MOVE, .MOVE):
            return true
        case (.BIND, .BIND):
            return true
        case (.LINK, .LINK):
            return true
        case (.PATCH, .PATCH):
            return true
        case (.TRACE, .TRACE):
            return true
        case (.MKCOL, .MKCOL):
            return true
        case (.MERGE, .MERGE):
            return true
        case (.PURGE, .PURGE):
            return true
        case (.NOTIFY, .NOTIFY):
            return true
        case (.SEARCH, .SEARCH):
            return true
        case (.UNLOCK, .UNLOCK):
            return true
        case (.REBIND, .REBIND):
            return true
        case (.UNBIND, .UNBIND):
            return true
        case (.REPORT, .REPORT):
            return true
        case (.DELETE, .DELETE):
            return true
        case (.UNLINK, .UNLINK):
            return true
        case (.CONNECT, .CONNECT):
            return true
        case (.MSEARCH, .MSEARCH):
            return true
        case (.OPTIONS, .OPTIONS):
            return true
        case (.PROPFIND, .PROPFIND):
            return true
        case (.CHECKOUT, .CHECKOUT):
            return true
        case (.PROPPATCH, .PROPPATCH):
            return true
        case (.SUBSCRIBE, .SUBSCRIBE):
            return true
        case (.MKCALENDAR, .MKCALENDAR):
            return true
        case (.MKACTIVITY, .MKACTIVITY):
            return true
        case (.UNSUBSCRIBE, .UNSUBSCRIBE):
            return true
        case (.RAW(let l), .RAW(let r)):
            return l == r
        default:
            return false
        }
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
    case RAW(value: String)

    /// Whether requests with this verb may have a request body.
    public var hasRequestBody: HasBody {
        switch self {
        case .HEAD, .DELETE, .TRACE:
            return .no
        case .POST, .PUT, .CONNECT, .PATCH:
            return .yes
        case .GET, .OPTIONS:
            fallthrough
        default:
            return .unlikely
        }
    }
}

/// A structure representing a HTTP version.
public struct HTTPVersion: Equatable {
    public static func ==(lhs: HTTPVersion, rhs: HTTPVersion) -> Bool {
        return lhs.major == rhs.major && lhs.minor == rhs.minor
    }

    /// Create a HTTP version.
    ///
    /// - Parameter major: The major version number.
    /// - Parameter minor: The minor version number.
    public init(major: UInt16, minor: UInt16) {
        self.major = major
        self.minor = minor
    }

    /// The major version number.
    public let major: UInt16

    /// The minor version number.
    public let minor: UInt16
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

    // 2xx
    case ok
    case created
    case accepted
    case nonAuthoritativeInformation
    case noContent
    case resetContent
    case partialContent

    // 3xx
    case multiStatus
    case alreadyReported
    case imUsed
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

    // 5xx
    case misdirectedRequest
    case unprocessableEntity
    case locked
    case failedDependency
    case upgradeRequired
    case preconditionRequired
    case tooManyRequests
    case requestHeaderFieldsTooLarge
    case unavailableForLegalReasons
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

extension HTTPResponseStatus: Equatable {
    public static func ==(lhs: HTTPResponseStatus, rhs: HTTPResponseStatus) -> Bool {
        switch (lhs, rhs) {
        case (.custom(let lcode, let lreason), .custom(let rcode, let rreason)):
            return lcode == rcode && lreason == rreason
        case (.continue, .continue):
            return true
        case (.switchingProtocols, .switchingProtocols):
            return true
        case (.processing, .processing):
            return true
        case (.ok, .ok):
            return true
        case (.created, .created):
            return true
        case (.accepted, .accepted):
            return true
        case (.nonAuthoritativeInformation, .nonAuthoritativeInformation):
            return true
        case (.noContent, .noContent):
            return true
        case (.resetContent, .resetContent):
            return true
        case (.partialContent, .partialContent):
            return true
        case (.multiStatus, .multiStatus):
            return true
        case (.alreadyReported, .alreadyReported):
            return true
        case (.imUsed, .imUsed):
            return true
        case (.multipleChoices, .multipleChoices):
            return true
        case (.movedPermanently, .movedPermanently):
            return true
        case (.found, .found):
            return true
        case (.seeOther, .seeOther):
            return true
        case (.notModified, .notModified):
            return true
        case (.useProxy, .useProxy):
            return true
        case (.temporaryRedirect, .temporaryRedirect):
            return true
        case (.permanentRedirect, .permanentRedirect):
            return true
        case (.badRequest, .badRequest):
            return true
        case (.unauthorized, .unauthorized):
            return true
        case (.paymentRequired, .paymentRequired):
            return true
        case (.forbidden, .forbidden):
            return true
        case (.notFound, .notFound):
            return true
        case (.methodNotAllowed, .methodNotAllowed):
            return true
        case (.notAcceptable, .notAcceptable):
            return true
        case (.proxyAuthenticationRequired, .proxyAuthenticationRequired):
            return true
        case (.requestTimeout, .requestTimeout):
            return true
        case (.conflict, .conflict):
            return true
        case (.gone, .gone):
            return true
        case (.lengthRequired, .lengthRequired):
            return true
        case (.preconditionFailed, .preconditionFailed):
            return true
        case (.payloadTooLarge, .payloadTooLarge):
            return true
        case (.uriTooLong, .uriTooLong):
            return true
        case (.unsupportedMediaType, .unsupportedMediaType):
            return true
        case (.rangeNotSatisfiable, .rangeNotSatisfiable):
            return true
        case (.expectationFailed, .expectationFailed):
            return true
        case (.misdirectedRequest, .misdirectedRequest):
            return true
        case (.unprocessableEntity, .unprocessableEntity):
            return true
        case (.locked, .locked):
            return true
        case (.failedDependency, .failedDependency):
            return true
        case (.upgradeRequired, .upgradeRequired):
            return true
        case (.preconditionRequired, .preconditionRequired):
            return true
        case (.tooManyRequests, .tooManyRequests):
            return true
        case (.requestHeaderFieldsTooLarge, .requestHeaderFieldsTooLarge):
            return true
        case (.unavailableForLegalReasons, .unavailableForLegalReasons):
            return true
        case (.internalServerError, .internalServerError):
            return true
        case (.notImplemented, .notImplemented):
            return true
        case (.badGateway, .badGateway):
            return true
        case (.serviceUnavailable, .serviceUnavailable):
            return true
        case (.gatewayTimeout, .gatewayTimeout):
            return true
        case (.httpVersionNotSupported, .httpVersionNotSupported):
            return true
        case (.variantAlsoNegotiates, .variantAlsoNegotiates):
            return true
        case (.insufficientStorage, .insufficientStorage):
            return true
        case (.loopDetected, .loopDetected):
            return true
        case (.notExtended, .notExtended):
            return true
        case (.networkAuthenticationRequired, .networkAuthenticationRequired):
            return true
        default:
            return false
        }
    }
}

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
