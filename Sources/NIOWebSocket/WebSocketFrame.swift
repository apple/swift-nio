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

extension UInt8 {
    @usableFromInline
    internal func isAnyBitSetInMask(_ mask: UInt8) -> Bool {
        self & mask != 0
    }

    @usableFromInline
    internal mutating func changingBitsInMask(_ mask: UInt8, to: Bool) {
        if to {
            self |= mask
        } else {
            self &= ~mask
        }
    }
}

/// A single 4-byte websocket masking key.
///
/// WebSockets uses a masking key to prevent malicious users from injecting
/// predictable binary sequences into websocket data streams. This structure provides
/// a more convenient method of interacting with a masking key than simply by passing
/// around a four-tuple.
public struct WebSocketMaskingKey: Sendable {
    @usableFromInline internal let _key: (UInt8, UInt8, UInt8, UInt8)

    public init?<T: Collection>(_ buffer: T) where T.Element == UInt8 {
        guard buffer.count == 4 else {
            return nil
        }

        self._key = (
            buffer[buffer.startIndex],
            buffer[buffer.index(buffer.startIndex, offsetBy: 1)],
            buffer[buffer.index(buffer.startIndex, offsetBy: 2)],
            buffer[buffer.index(buffer.startIndex, offsetBy: 3)]
        )
    }

    /// Creates a websocket masking key from the network-encoded
    /// representation.
    ///
    /// - Parameters:
    ///   - integer: The encoded network representation of the
    ///         masking key.
    @usableFromInline
    internal init(networkRepresentation integer: UInt32) {
        self._key = (
            UInt8((integer & 0xFF00_0000) >> 24),
            UInt8((integer & 0x00FF_0000) >> 16),
            UInt8((integer & 0x0000_FF00) >> 8),
            UInt8(integer & 0x0000_00FF)
        )
    }
}

extension WebSocketMaskingKey: ExpressibleByArrayLiteral {
    public typealias ArrayLiteralElement = UInt8

    public init(arrayLiteral elements: UInt8...) {
        precondition(elements.count == 4, "WebSocketMaskingKeys must be exactly 4 bytes long")
        self.init(elements)!  // length precondition above
    }
}

extension WebSocketMaskingKey {
    /// Returns a random masking key, using the given generator as a source for randomness.
    /// - Parameter generator: The random number generator to use when creating the
    ///     new random masking key.
    /// - Returns: A random masking key
    @inlinable
    public static func random<Generator>(
        using generator: inout Generator
    ) -> WebSocketMaskingKey where Generator: RandomNumberGenerator {
        WebSocketMaskingKey(networkRepresentation: .random(in: UInt32.min...UInt32.max, using: &generator))
    }

    /// Returns a random masking key, using the `SystemRandomNumberGenerator` as a source for randomness.
    /// - Returns: A random masking key
    @inlinable
    public static func random() -> WebSocketMaskingKey {
        var generator = SystemRandomNumberGenerator()
        return .random(using: &generator)
    }
}

extension WebSocketMaskingKey: Equatable {
    public static func == (lhs: WebSocketMaskingKey, rhs: WebSocketMaskingKey) -> Bool {
        lhs._key == rhs._key
    }
}

extension WebSocketMaskingKey: Collection {
    public typealias Element = UInt8
    public typealias Index = Int

    public var startIndex: Int { 0 }
    public var endIndex: Int { 4 }

    public func index(after: Int) -> Int {
        after + 1
    }

    public subscript(index: Int) -> UInt8 {
        switch index {
        case 0:
            return self._key.0
        case 1:
            return self._key.1
        case 2:
            return self._key.2
        case 3:
            return self._key.3
        default:
            fatalError("Invalid index on WebSocketMaskingKey: \(index)")
        }
    }

    @inlinable
    public func withContiguousStorageIfAvailable<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R? {
        try withUnsafeBytes(of: self._key) { ptr in
            // this is boilerplate necessary to convert from UnsafeRawBufferPointer to UnsafeBufferPointer<UInt8>
            // we know ptr is bound since we defined self._key as let
            let typedPointer = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self)
            let typedBufferPointer = UnsafeBufferPointer(start: typedPointer, count: ptr.count)
            return try body(typedBufferPointer)
        }
    }
}

/// A structured representation of a single WebSocket frame.
public struct WebSocketFrame {
    private var _storage: WebSocketFrame._Storage

    /// The masking key, if any.
    ///
    /// A masking key is used to prevent specific byte sequences from appearing in the network
    /// stream. This is primarily used by entities like browsers, but should be used any time it
    /// is possible for a malicious user to control the data that appears in a websocket stream.
    ///
    /// If this value is `nil`, and this frame was *received from* the network, the data in `data`
    /// is not masked. If this value is `nil`, and this frame is being *sent to* the network, the
    /// data in `data` will not be masked.
    public var maskKey: WebSocketMaskingKey? = nil

    /// Rather than unpack all the fields from the first byte, and thus take up loads
    /// of storage in the structure, we keep them in their packed form in this byte and
    /// use computed properties to unpack them.
    @usableFromInline
    internal var firstByte: UInt8 = 0

    /// The value of the `fin` bit. If set, this is the last frame in a fragmented frame. If not
    /// set, this frame is one of the intermediate frames in a fragmented frame. Must be set if
    /// a frame is not fragmented at all.
    @inlinable
    public var fin: Bool {
        get {
            self.firstByte.isAnyBitSetInMask(0x80)
        }
        set {
            self.firstByte.changingBitsInMask(0x80, to: newValue)
        }
    }

    /// The value of the first reserved bit. Must be `false` unless using an extension that defines its use.
    @inlinable
    public var rsv1: Bool {
        get {
            self.firstByte.isAnyBitSetInMask(0x40)
        }
        set {
            self.firstByte.changingBitsInMask(0x40, to: newValue)
        }
    }

    /// The value of the second reserved bit. Must be `false` unless using an extension that defines its use.
    @inlinable
    public var rsv2: Bool {
        get {
            self.firstByte.isAnyBitSetInMask(0x20)
        }
        set {
            self.firstByte.changingBitsInMask(0x20, to: newValue)
        }
    }

    /// The value of the third reserved bit. Must be `false` unless using an extension that defines its use.
    @inlinable
    public var rsv3: Bool {
        get {
            self.firstByte.isAnyBitSetInMask(0x10)
        }
        set {
            self.firstByte.changingBitsInMask(0x10, to: newValue)
        }
    }

    /// The opcode for this frame.
    @inlinable
    public var opcode: WebSocketOpcode {
        get {
            // this is a public initialiser which only fails if the opcode is invalid. But all opcodes in 0...0xF
            // space are valid so this can never fail.
            WebSocketOpcode(encodedWebSocketOpcode: firstByte & 0x0F)!
        }
        set {
            self.firstByte = (self.firstByte & 0xF0) + UInt8(webSocketOpcode: newValue)
        }
    }

    /// The total length of the data in the frame.
    @inlinable
    public var length: Int {
        data.readableBytes + (extensionData?.readableBytes ?? 0)
    }

    /// The application data.
    ///
    /// On frames received from the network, this data is not necessarily unmasked. This is to provide as much
    /// information as possible. If unmasked data is desired, either use the computed `unmaskedData` property to
    /// obtain it, or transform this data directly by calling `data.unmask(maskKey)`.
    public var data: ByteBuffer {
        get {
            self._storage.data
        }
        set {
            if !isKnownUniquelyReferenced(&self._storage) {
                self._storage = _Storage(copying: self._storage)
            }
            self._storage.data = newValue
        }
    }

    /// The extension data, if any.
    ///
    /// On frames received from the network, this data is not necessarily unmasked. This is to provide as much
    /// information as possible. If unmasked data is desired, either use the computed `unmaskedExtensionData` property to
    /// obtain it, or transform this data directly by calling `extensionData.unmask(maskKey)`.
    public var extensionData: ByteBuffer? {
        get {
            self._storage.extensionData
        }
        set {
            if !isKnownUniquelyReferenced(&self._storage) {
                self._storage = _Storage(copying: self._storage)
            }
            self._storage.extensionData = newValue
        }
    }

    /// The unmasked application data.
    ///
    /// If a masking key is present on the frame, this property will automatically unmask the underlying data
    /// and return the unmasked data to the user. This is a convenience method that should only be used when
    /// persisting the underlying masked data is worthwhile: otherwise, performance will often be better to
    /// manually unmask the data with `data.unmask(maskKey)`.
    public var unmaskedData: ByteBuffer {
        get {
            guard let maskKey = self.maskKey else {
                return self.data
            }
            var data = self.data
            data.webSocketUnmask(maskKey, indexOffset: (self.extensionData?.readableBytes ?? 0) % 4)
            return data
        }
    }

    /// The unmasked extension data.
    ///
    /// If a masking key is present on the frame, this property will automatically unmask the underlying data
    /// and return the unmasked data to the user. This is a convenience method that should only be used when
    /// persisting the underlying masked data is worthwhile: otherwise, performance will often be better to
    /// manually unmask the data with `data.unmask(maskKey)`.
    public var unmaskedExtensionData: ByteBuffer? {
        get {
            guard let maskKey = self.maskKey else {
                return self.extensionData
            }
            var extensionData = self.extensionData
            extensionData?.webSocketUnmask(maskKey)
            return extensionData
        }
    }

    /// Creates an empty `WebSocketFrame`.
    ///
    /// - Parameters:
    ///   - allocator: The `ByteBufferAllocator` to use when editing the empty buffers.
    public init(allocator: ByteBufferAllocator) {
        self._storage = .init(data: allocator.buffer(capacity: 0), extensionData: nil)
    }

    /// Create a `WebSocketFrame` with the given properties.
    ///
    /// - Parameters:
    ///   - fin: The value of the `fin` bit. Defaults to `false`.
    ///   - rsv1: The value of the first reserved bit. Defaults to `false`.
    ///   - rsv2: The value of the second reserved bit. Defaults to `false`.
    ///   - rsv3: The value of the third reserved bit. Defaults to `false`.
    ///   - opcode: The opcode for the frame. Defaults to `.continuation`.
    ///   - maskKey: The masking key for the frame, if any. Defaults to `nil`.
    ///   - data: The application data for the frame.
    ///   - extensionData: The extension data for the frame.
    public init(
        fin: Bool = false,
        rsv1: Bool = false,
        rsv2: Bool = false,
        rsv3: Bool = false,
        opcode: WebSocketOpcode = .continuation,
        maskKey: WebSocketMaskingKey? = nil,
        data: ByteBuffer,
        extensionData: ByteBuffer? = nil
    ) {
        self._storage = .init(data: data, extensionData: extensionData)
        self.fin = fin
        self.rsv1 = rsv1
        self.rsv2 = rsv2
        self.rsv3 = rsv3
        self.opcode = opcode
        self.maskKey = maskKey
    }

    /// Create a `WebSocketFrame` from the underlying data representation.
    internal init(firstByte: UInt8, maskKey: WebSocketMaskingKey?, applicationData: ByteBuffer) {
        self._storage = .init(data: applicationData, extensionData: nil)
        self.firstByte = firstByte
        self.maskKey = maskKey
    }
}

extension WebSocketFrame: @unchecked Sendable {}

extension WebSocketFrame: Equatable {}

extension WebSocketFrame {
    fileprivate class _Storage {
        var data: ByteBuffer
        var extensionData: Optional<ByteBuffer>

        fileprivate init(data: ByteBuffer, extensionData: ByteBuffer?) {
            self.data = data
            self.extensionData = extensionData
        }

        fileprivate init(copying original: WebSocketFrame._Storage) {
            self.data = original.data
            self.extensionData = original.extensionData
        }
    }
}

@available(*, unavailable)
extension WebSocketFrame._Storage: Sendable {}

extension WebSocketFrame._Storage: Equatable {
    static func == (lhs: WebSocketFrame._Storage, rhs: WebSocketFrame._Storage) -> Bool {
        lhs.data == rhs.data && lhs.extensionData == rhs.extensionData
    }
}

extension WebSocketFrame: CustomStringConvertible {
    /// A `String` describing this `WebSocketFrame`. Example:
    ///
    ///     WebSocketFrame {
    ///     maskKey: Optional(NIOWebSocket.WebSocketMaskingKey(_key: (187, 28, 185, 79))),
    ///     fin: true,
    ///     rsv1: true,
    ///     rsv2: true,
    ///     rsv3: true,
    ///     opcode: WebSocketOpcode.binary,
    ///     length: 0,
    ///     data: ByteBuffer { readerIndex: 0, writerIndex: 0, readableBytes: 0, capacity: 0, storageCapacity: 0, slice: _ByteBufferSlice { 0..<0 }, storage: 0x00006000028246b0 (0 bytes) },
    ///     extensionData: nil,
    ///     unmaskedData: ByteBuffer { readerIndex: 0, writerIndex: 0, readableBytes: 0, capacity: 0, storageCapacity: 0, slice: _ByteBufferSlice { 0..<0 }, storage: 0x0000600002824800 (0 bytes) },
    ///     unmaskedDataExtension: nil
    ///     }
    ///
    /// The format of the description is not API.
    ///
    /// - Returns: A description of this `WebSocketFrame`.
    public var description: String {
        """
        maskKey: \(String(describing: self.maskKey)), \
        fin: \(self.fin), \
        rsv1: \(self.rsv1), \
        rsv2: \(self.rsv2), \
        rsv3: \(self.rsv3), \
        opcode: \(self.opcode), \
        length: \(self.length), \
        data: \(String(describing: self.data)), \
        extensionData: \(String(describing: self.extensionData)), \
        unmaskedData: \(String(describing: self.unmaskedData)), \
        unmaskedDataExtension: \(String(describing: self.unmaskedExtensionData))
        """
    }
}

extension WebSocketFrame: CustomDebugStringConvertible {
    public var debugDescription: String {
        "(\(self.description))"
    }
}

extension WebSocketFrame {
    /// WebSocketFrame reserved bits option set
    public struct ReservedBits: OptionSet, Sendable {
        public var rawValue: UInt8

        @inlinable
        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        @inlinable
        public static var rsv1: Self { .init(rawValue: 0x40) }
        @inlinable
        public static var rsv2: Self { .init(rawValue: 0x20) }
        @inlinable
        public static var rsv3: Self { .init(rawValue: 0x10) }
        @inlinable
        public static var all: Self { .init(rawValue: 0x70) }
    }

    /// The value of all the reserved bits. Must be `empty` unless using an extension that defines their use.
    @inlinable
    public var reservedBits: ReservedBits {
        get {
            .init(rawValue: self.firstByte & 0x70)
        }
        set {
            self.firstByte = (self.firstByte & 0x8F) + newValue.rawValue
        }
    }
}
