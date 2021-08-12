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

private extension UInt8 {
    func isAnyBitSetInMask(_ mask: UInt8) -> Bool {
        return self & mask != 0
    }

    mutating func changingBitsInMask(_ mask: UInt8, to: Bool) {
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
public struct WebSocketMaskingKey {
    @usableFromInline internal let _key: (UInt8, UInt8, UInt8, UInt8)

    public init?<T: Collection>(_ buffer: T) where T.Element == UInt8 {
        guard buffer.count == 4 else {
            return nil
        }

        self._key = (buffer[buffer.startIndex],
                     buffer[buffer.index(buffer.startIndex, offsetBy: 1)],
                     buffer[buffer.index(buffer.startIndex, offsetBy: 2)],
                     buffer[buffer.index(buffer.startIndex, offsetBy: 3)])
    }

    /// Creates a websocket masking key from the network-encoded
    /// representation.
    ///
    /// - parameters:
    ///     - integer: The encoded network representation of the
    ///         masking key.
    @usableFromInline
    internal init(networkRepresentation integer: UInt32) {
        self._key = (UInt8((integer & 0xFF000000) >> 24),
                     UInt8((integer & 0x00FF0000) >> 16),
                     UInt8((integer & 0x0000FF00) >> 8),
                     UInt8(integer & 0x000000FF))
    }
}

extension WebSocketMaskingKey: ExpressibleByArrayLiteral {
    public typealias ArrayLiteralElement = UInt8

    public init(arrayLiteral elements: UInt8...) {
        precondition(elements.count == 4, "WebSocketMaskingKeys must be exactly 4 bytes long")
        self.init(elements)! // length precondition above
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
        return WebSocketMaskingKey(networkRepresentation: .random(in: UInt32.min...UInt32.max, using: &generator))
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
    public static func ==(lhs: WebSocketMaskingKey, rhs: WebSocketMaskingKey) -> Bool {
        return lhs._key == rhs._key
    }
}

extension WebSocketMaskingKey: Collection {
    public typealias Element = UInt8
    public typealias Index = Int

    public var startIndex: Int { return 0 }
    public var endIndex: Int { return 4 }

    public func index(after: Int) -> Int {
        return after + 1
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
        return try withUnsafeBytes(of: self._key) { ptr in
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
    internal var firstByte: UInt8 = 0

    /// The value of the `fin` bit. If set, this is the last frame in a fragmented frame. If not
    /// set, this frame is one of the intermediate frames in a fragmented frame. Must be set if
    /// a frame is not fragmented at all.
    public var fin: Bool {
        get {
            return self.firstByte.isAnyBitSetInMask(0x80)
        }
        set {
            self.firstByte.changingBitsInMask(0x80, to: newValue)
        }
    }

    /// The value of the first reserved bit. Must be `false` unless using an extension that defines its use.
    public var rsv1: Bool {
        get {
            return self.firstByte.isAnyBitSetInMask(0x40)
        }
        set {
            self.firstByte.changingBitsInMask(0x40, to: newValue)
        }
    }

    /// The value of the second reserved bit. Must be `false` unless using an extension that defines its use.
    public var rsv2: Bool {
        get {
            return self.firstByte.isAnyBitSetInMask(0x20)
        }
        set {
            self.firstByte.changingBitsInMask(0x20, to: newValue)
        }
    }

    /// The value of the third reserved bit. Must be `false` unless using an extension that defines its use.
    public var rsv3: Bool {
        get {
            return self.firstByte.isAnyBitSetInMask(0x10)
        }
        set {
            self.firstByte.changingBitsInMask(0x10, to: newValue)
        }
    }

    /// The opcode for this frame.
    public var opcode: WebSocketOpcode {
        get {
            // this is a public initialiser which only fails if the opcode is invalid. But all opcodes in 0...0xF
            // space are valid so this can never fail.
            return WebSocketOpcode(encodedWebSocketOpcode: firstByte & 0x0F)!
        }
        set {
            self.firstByte = (self.firstByte & 0xF0) + UInt8(webSocketOpcode: newValue)
        }
    }

    /// The total length of the data in the frame.
    public var length: Int {
        return data.readableBytes + (extensionData?.readableBytes ?? 0)
    }

    /// The application data.
    ///
    /// On frames received from the network, this data is not necessarily unmasked. This is to provide as much
    /// information as possible. If unmasked data is desired, either use the computed `unmaskedData` property to
    /// obtain it, or transform this data directly by calling `data.unmask(maskKey)`.
    public var data: ByteBuffer {
        get {
            return self._storage.data
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
            return self._storage.extensionData
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
    /// - parameters:
    ///     - allocator: The `ByteBufferAllocator` to use when editing the empty buffers.
    public init(allocator: ByteBufferAllocator) {
        self._storage = .init(data: allocator.buffer(capacity: 0), extensionData: nil)
    }

    /// Create a `WebSocketFrame` with the given properties.
    ///
    /// - parameters:
    ///     - fin: The value of the `fin` bit. Defaults to `false`.
    ///     - rsv1: The value of the first reserved bit. Defaults to `false`.
    ///     - rsv2: The value of the second reserved bit. Defaults to `false`.
    ///     - rsv3: The value of the third reserved bit. Defaults to `false`.
    ///     - opcode: The opcode for the frame. Defaults to `.continuation`.
    ///     - maskKey: The masking key for the frame, if any. Defaults to `nil`.
    ///     - data: The application data for the frame.
    ///     - extensionData: The extension data for the frame.
    public init(fin: Bool = false, rsv1: Bool = false, rsv2: Bool = false, rsv3: Bool = false,
                opcode: WebSocketOpcode = .continuation, maskKey: WebSocketMaskingKey? = nil,
                data: ByteBuffer, extensionData: ByteBuffer? = nil) {
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

extension WebSocketFrame._Storage: Equatable {
    static func ==(lhs: WebSocketFrame._Storage, rhs: WebSocketFrame._Storage) -> Bool {
        return lhs.data == rhs.data && lhs.extensionData == rhs.extensionData
    }
}
