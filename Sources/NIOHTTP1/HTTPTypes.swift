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

/// An `IteratorProtocol` that can iterate through comma separated list of values for a certain
/// header.
///
/// **Example:**
///
/// Suppose you have these headers:
///
///      Connection: keep-alive, x-server
///      Content-Type: text/html
///      Connection: other
///
/// You can iterate using this struct on those headers, for values of `Connection`, to get
/// `keep-alive`, then `x-server`, then `other`
public struct HTTPListHeaderIterator: Sequence, IteratorProtocol {
    
    public typealias Element = ByteBufferView
    
    private var currentHeaderIndex: Int = -1
    private var singleValueViewIterator: Array<ByteBufferView>.Iterator?
    private let headerName: String.UTF8View
    private let headers: HTTPHeaders
    
    private let comma = ",".utf8.first!
    
    /// Returns next index in headers
    ///
    /// - Parameter current: The index to begin iteration at
    /// - Returns: The next index of the header in header array, or `nil` if not found
    private func headerIndex(after current: Int) -> Int? {
        for (idx, currentHeader) in headers.headers.enumerated().dropFirst(current + 1) {
            let view = headers.buffer.viewBytes(at: currentHeader.name.start,
                                                length: currentHeader.name.length)
            if view.compareCaseInsensitiveASCIIBytes(to: headerName) {
                return idx
            }
        }
        return nil
    }

    mutating public func next() -> ByteBufferView? {
        if let next = self.singleValueViewIterator?.next() {
            return next.trimSpaces()
        } else {
            // End of this buffer. Let's try to grab the next one.
            guard let index = self.headerIndex(after: currentHeaderIndex) else {
                // No more buffers left.
                return nil
            }
            self.currentHeaderIndex = index
            self.singleValueViewIterator = headers.buffer
                .viewBytes(at: headers.headers[currentHeaderIndex].value.start,
                           length: headers.headers[currentHeaderIndex].value.length)
                .split(separator: comma)
                .makeIterator()
            return self.next()
        }
        
    }
    
    public func makeIterator() -> HTTPListHeaderIterator {
        return self
    }
    
    @_versioned
    internal init(headerName: String.UTF8View,
                  headers: HTTPHeaders) {
        self.headers = headers
        self.headerName = headerName
    }
    
    @_inlineable
    public init(headerName: String,
                headers: HTTPHeaders) {
        self.init(headerName: headerName.utf8,
                  headers: headers)
    }

}

extension HTTPHeaders {
    private static let connectionString = "connection".utf8
    private static let keepAliveString = "keep-alive".utf8
    private static let closeString = "close".utf8
    
    internal enum ConnectionHeaderValue {
        case keepAlive
        case close
        case unspecified
    }
    
    internal var keepAliveFromHeaders: ConnectionHeaderValue {
        get {
            let tokenizer = HTTPListHeaderIterator(headerName: HTTPHeaders.connectionString,
                                                   headers: self)
            
            // TODO: Handle the case where both keep-alive and close are used
            for token in tokenizer {
                if token.compareCaseInsensitiveASCIIBytes(to: HTTPHeaders.keepAliveString) {
                    return .keepAlive
                } else if token.compareCaseInsensitiveASCIIBytes(to: HTTPHeaders.closeString) {
                    return .close
                }
            }
            
            return .unspecified
        }
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
        var rawURI: URI
        var version: HTTPVersion

        init(method: HTTPMethod, rawURI: URI, version: HTTPVersion) {
            self.method = method
            self.rawURI = rawURI
            self.version = version
        }

        func copy() -> _Storage {
            return .init(method: self.method, rawURI: self.rawURI, version: self.version)
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
            if !isKnownUniquelyReferenced(&self._storage) {
                self._storage = self._storage.copy()
            }
            self._storage.method = newValue
        }
    }

    // Internal representation of the URI.
    private var rawURI: URI {
        get {
            return self._storage.rawURI
        }
        set {
            if !isKnownUniquelyReferenced(&self._storage) {
                self._storage = self._storage.copy()
            }
            self._storage.rawURI = newValue
        }
    }

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
    public var version: HTTPVersion {
        get {
            return self._storage.version
        }
        set {
            if !isKnownUniquelyReferenced(&self._storage) {
                self._storage = self._storage.copy()
            }
            self._storage.version = newValue
        }
    }

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
        self.headers = headers
        self._storage = _Storage(method: method, rawURI: rawURI, version: version)
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
            if !isKnownUniquelyReferenced(&self._storage) {
                self._storage = self._storage.copy()
            }
            self._storage.status = newValue
        }
    }

    /// The HTTP version that corresponds to this response.
    public var version: HTTPVersion {
        get {
            return self._storage.version
        }
        set {
            if !isKnownUniquelyReferenced(&self._storage) {
                self._storage = self._storage.copy()
            }
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
}

/// The Index for a header name or value that points into the underlying `ByteBuffer`.
///
/// - note: This is public to aid in the creation of supplemental HTTP libraries, e.g.
///         NIOHTTP2 and NIOHPACK. It is not intended for general use.
public struct HTTPHeaderIndex {
    let start: Int
    let length: Int
}

/// Struct which holds name, value pairs.
///
/// - note: This is public to aid in the creation of supplemental HTTP libraries, e.g.
///         NIOHTTP2 and NIOHPACK. It is not intended for general use.
public struct HTTPHeader {
    let name: HTTPHeaderIndex
    let value: HTTPHeaderIndex
}

private extension ByteBuffer {
    func equalCaseInsensitiveASCII(view: String.UTF8View, at index: HTTPHeaderIndex) -> Bool {
        guard view.count == index.length else {
            return false
        }
        return withVeryUnsafeBytes { buffer in
            // This should never happens as we control when this is called. Adding an assert to ensure this.
            assert(index.start <= self.capacity - index.length)
            for (idx, byte) in view.enumerated() {
                guard byte.isASCII && buffer[index.start + idx] & 0xdf == byte & 0xdf else {
                    return false
                }
            }
            return true
        }
    }
}


private extension UInt8 {
    var isASCII: Bool {
        return self <= 127
    }
}

/* private but tests */ internal extension HTTPHeaders {
    func isKeepAlive(version: HTTPVersion) -> Bool {
        switch self._storage.keepAliveState {
        case .close:
            return false
        case .keepAlive:
            return true
        case .unknown:
            switch self.keepAliveFromHeaders {
            case .keepAlive:
                return true
            case .close:
                return false
            case .unspecified:
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
public struct HTTPHeaders: CustomStringConvertible {

    private final class _Storage {
        var buffer: ByteBuffer
        var headers: [HTTPHeader]
        var continuous: Bool
        var keepAliveState: KeepAliveState

        init(buffer: ByteBuffer, headers: [HTTPHeader], continuous: Bool, keepAliveState: KeepAliveState) {
            self.buffer = buffer
            self.headers = headers
            self.continuous = continuous
            self.keepAliveState = keepAliveState
        }

        func copy() -> _Storage {
            return .init(buffer: self.buffer, headers: self.headers, continuous: self.continuous, keepAliveState: self.keepAliveState)
        }
    }
    private var _storage: _Storage

    // Because we use CoW implementations HTTPHeaders is also CoW
    fileprivate var buffer: ByteBuffer {
        return self._storage.buffer
    }

    fileprivate var headers: [HTTPHeader] {
        return self._storage.headers
    }

    fileprivate var continuous: Bool {
        return self._storage.continuous
    }

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
    
    /// Creates a header block from a pre-filled contiguous string buffer containing a
    /// UTF-8 encoded HTTP header block, along with a list of the locations of each
    /// name/value pair within the block.
    ///
    /// - note: This is public to aid in the creation of supplemental HTTP libraries, e.g.
    ///         NIOHTTP2 and NIOHPACK. It is not intended for general use.
    ///
    /// - Parameters:
    ///   - buffer: A buffer containing UTF-8 encoded HTTP headers.
    ///   - headers: The locations within `buffer` of the name and value of each header.
    /// - Returns: A new `HTTPHeaders` using the provided buffer as storage.
    public static func createHeaderBlock(buffer: ByteBuffer, headers: [HTTPHeader]) -> HTTPHeaders {
        return HTTPHeaders(buffer: buffer, headers: headers, keepAliveState: KeepAliveState.unknown)
    }
    
    
    /// Provides access to raw UTF-8 storage of the headers in this header block, along with
    /// a list of the header strings' indices.
    ///
    /// - note: This is public to aid in the creation of supplemental HTTP libraries, e.g.
    /// NIOHTTP2 and NIOHPACK. It is not intended for general use.
    ///
    /// - parameters:
    ///   - block:      A block that will be provided UTF-8 header block information.
    ///   - buf:        A raw `ByteBuffer` containing potentially-contiguous sequences of UTF-8 encoded
    ///                 characters.
    ///   - locations:  An array of `HTTPHeader`s, each of which contains information on the location in
    ///                 the buffer of both a header's name and value.
    ///   - contiguous: A `Bool` indicating whether the headers are stored contiguously, with no padding
    ///                 or orphaned data within the block. If this is `true`, then the buffer represents
    ///                 a HTTP/1 header block appropriately encoded for the wire.
    public func withUnsafeBufferAndIndices<R>(_ block: (_ buf: ByteBuffer, _ locations: [HTTPHeader], _ contiguous: Bool) throws -> R) rethrows -> R {
        return try block(self.buffer, self.headers, self.continuous)
    }

    /// Constructor used by our decoder to construct headers without the need of converting bytes to string.
    init(buffer: ByteBuffer, headers: [HTTPHeader], keepAliveState: KeepAliveState) {
        self._storage = _Storage(buffer: buffer, headers: headers, continuous: true, keepAliveState: keepAliveState)
    }

    /// Construct a `HTTPHeaders` structure.
    ///
    /// - parameters
    ///     - headers: An initial set of headers to use to populate the header block.
    ///     - allocator: The allocator to use to allocate the underlying storage.
    public init(_ headers: [(String, String)] = []) {
        // Note: this initializer exists because of https://bugs.swift.org/browse/SR-7415.
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

        self.init(buffer: allocator.buffer(capacity: 256), headers: array, keepAliveState: .unknown)

        for (key, value) in headers {
            self.add(name: key, value: value)
        }
    }
    
    private func isConnectionHeader(_ header: HTTPHeaderIndex) -> Bool {
         return self.buffer.equalCaseInsensitiveASCII(view: "connection".utf8, at: header)
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
        if !isKnownUniquelyReferenced(&self._storage) {
            self._storage = self._storage.copy()
        }
        let nameStart = self.buffer.writerIndex
        let nameLength = self._storage.buffer.write(string: name)!
        self._storage.buffer.write(staticString: headerSeparator)
        let valueStart = self.buffer.writerIndex
        let valueLength = self._storage.buffer.write(string: value)!
        
        let nameIdx = HTTPHeaderIndex(start: nameStart, length: nameLength)
        self._storage.headers.append(HTTPHeader(name: nameIdx, value: HTTPHeaderIndex(start: valueStart, length: valueLength)))
        self._storage.buffer.write(staticString: crlf)
        
        if self.isConnectionHeader(nameIdx) {
            self._storage.keepAliveState = .unknown
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
        self.remove(name: name)
        self.add(name: name, value: value)
    }

    /// Remove all values for a given header name from the block.
    ///
    /// This method uses case-insensitive comparisons for the header field name.
    ///
    /// - Parameter name: The name of the header field to remove from the block.
    public mutating func remove(name: String) {
        guard !self.headers.isEmpty else {
            return
        }

        let utf8 = name.utf8
        var array: [Int] = []
        // We scan from the back to the front so we can remove the subranges with as less overhead as possible.
        for idx in stride(from: self.headers.count - 1, to: -1, by: -1) {
            let header = self.headers[idx]
            if self.buffer.equalCaseInsensitiveASCII(view: utf8, at: header.name) {
                array.append(idx)
                
                if self.isConnectionHeader(header.name) {
                    self._storage.keepAliveState = .unknown
                }
            }
        }

        guard !array.isEmpty else {
            return
        }

        if !isKnownUniquelyReferenced(&self._storage) {
            self._storage = self._storage.copy()
        }

        array.forEach {
            self._storage.headers.remove(at: $0)
        }
        self._storage.continuous = false
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
        guard !self.headers.isEmpty else {
            return []
        }

        let utf8 = name.utf8
        var array: [String] = []
        for header in self.headers {
            if self.buffer.equalCaseInsensitiveASCII(view: utf8, at: header.name) {
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
        guard !self.headers.isEmpty else {
            return false
        }

        let utf8 = name.utf8
        for header in self.headers {
            if self.buffer.equalCaseInsensitiveASCII(view: utf8, at: header.name) {
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
        let result = self[name]

        guard result.count > 0 else {
            return []
        }

        // It's not safe to split Set-Cookie on comma.
        guard name.lowercased() != "set-cookie" else {
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
        case (.custom, _), (_, .custom):
            return false
        default:
            return lhs.code == rhs.code
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
