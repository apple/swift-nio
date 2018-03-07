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
    private let key: (UInt8, UInt8, UInt8, UInt8)

    public init?<T: Collection>(_ buffer: T) where T.Element == UInt8 {
        guard buffer.count == 4 else {
            return nil
        }

        self.key = (buffer[buffer.startIndex],
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
    internal init(networkRepresentation integer: UInt32) {
        self.key = (UInt8((integer & 0xFF000000) >> 24),
                    UInt8((integer & 0x00FF0000) >> 16),
                    UInt8((integer & 0x0000FF00) >> 8),
                    UInt8(integer & 0x000000FF))
    }
}

extension WebSocketMaskingKey: ExpressibleByArrayLiteral {
    public typealias ArrayLiteralElement = UInt8

    public init(arrayLiteral elements: UInt8...) {
        self.init(elements)!
    }
}

extension WebSocketMaskingKey: Equatable {
    public static func ==(lhs: WebSocketMaskingKey, rhs: WebSocketMaskingKey) -> Bool {
        return lhs.key == rhs.key
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
            return self.key.0
        case 1:
            return self.key.1
        case 2:
            return self.key.2
        case 3:
            return self.key.3
        default:
            fatalError("Invalid index on WebSocketMaskingKey: \(index)")
        }
    }
}

/// A structured representation of a single WebSocket frame.
public struct WebSocketFrame {
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
            return WebSocketOpcode(encodedWebSocketOpcode: firstByte & 0x0F)!
        }
        set {
            self.firstByte = (self.firstByte & 0xF0) + UInt8(webSocketOpcode: newValue)!
        }
    }

    /// The total length of the data in the frame.
    public var length: Int {
        return data.readableBytes + (extensionData?.readableBytes ?? 0)
    }

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

    /// The application data.
    ///
    /// On frames received from the network, this data is not necessarily unmasked. This is to provide as much
    /// information as possible. If unmasked data is desired, either use the computed `unmaskedData` property to
    /// obtain it, or transform this data directly by calling `data.unmask(maskKey)`.
    public var data: ByteBuffer

    /// The extension data, if any.
    ///
    /// On frames received from the network, this data is not necessarily unmasked. This is to provide as much
    /// information as possible. If unmasked data is desired, either use the computed `unmaskedExtensionData` property to
    /// obtain it, or transform this data directly by calling `extensionData.unmask(maskKey)`.
    public var extensionData: ByteBuffer? = nil

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
        self.data = allocator.buffer(capacity: 0)
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
        self.data = data
        self.extensionData = extensionData
        self.fin = fin
        self.rsv1 = rsv1
        self.rsv2 = rsv2
        self.rsv3 = rsv3
        self.opcode = opcode
        self.maskKey = maskKey
    }

    /// Create a `WebSocketFrame` from the underlying data representation.
    internal init(firstByte: UInt8, maskKey: WebSocketMaskingKey?, applicationData: ByteBuffer) {
        self.firstByte = firstByte
        self.maskKey = maskKey
        self.data = applicationData
    }
}

extension WebSocketFrame: Equatable {
    public static func ==(lhs: WebSocketFrame, rhs: WebSocketFrame) -> Bool {
        return lhs.firstByte == rhs.firstByte &&
               lhs.maskKey == rhs.maskKey &&
               lhs.data == rhs.data &&
               lhs.extensionData == rhs.extensionData
    }
}
