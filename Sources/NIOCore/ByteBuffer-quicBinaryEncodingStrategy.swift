//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

extension ByteBuffer {
    /// A ``NIOBinaryIntegerEncodingStrategy`` which encodes bytes as defined in RFC 9000 § 16
    public struct QUICBinaryEncodingStrategy: NIOBinaryIntegerEncodingStrategy, Sendable {
        /// All possible values for how many bytes a QUIC encoded integer can be
        public enum IntegerLength: Int, Sendable {
            case one = 1
            case two = 2
            case four = 4
            case eight = 8
        }
        /// An estimate of the bytes required to write integers using this strategy
        public var requiredBytesHint: Int

        /// Note: Prefer to use the APIs directly on ByteBuffer such as ``ByteBuffer/writeEncodedInteger(_:strategy:)`` and pass `.quic` rather than directly initialising an instance of this strategy
        /// - Parameter requiredBytesHint: An estimate of the bytes required to write integers using this strategy. This parameter is only relevant if calling ``ByteBuffer/writeLengthPrefixed(strategy:writeData:)``
        @inlinable
        public init(requiredBytesHint: IntegerLength) {
            self.requiredBytesHint = requiredBytesHint.rawValue
        }

        @inlinable
        public func readInteger<IntegerType: FixedWidthInteger>(
            as: IntegerType.Type,
            from buffer: inout ByteBuffer
        ) -> IntegerType? {
            guard let firstByte = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) else {
                return nil
            }

            // Look at the first two bits to work out the length, then read that, mask off the top two bits, and
            // extend to integer.
            switch firstByte & 0xC0 {
            case 0x00:
                // Easy case.
                buffer.moveReaderIndex(forwardBy: 1)
                return IntegerType(firstByte & ~0xC0)
            case 0x40:
                // Length is two bytes long, read the next one.
                return buffer.readInteger(as: UInt16.self).map { IntegerType($0 & ~(0xC0 << 8)) }
            case 0x80:
                // Length is 4 bytes long.
                return buffer.readInteger(as: UInt32.self).map { IntegerType($0 & ~(0xC0 << 24)) }
            case 0xC0:
                // Length is 8 bytes long.
                return buffer.readInteger(as: UInt64.self).map { IntegerType($0 & ~(0xC0 << 56)) }
            default:
                fatalError("Unreachable")
            }
        }

        /// Calculates the minimum number of bytes needed to encode an integer using this strategy
        /// - Parameter integer: The integer to be encoded
        /// - Returns: The number of bytes needed to encode it
        public static func bytesNeededForInteger<IntegerType: FixedWidthInteger>(_ integer: IntegerType) -> Int {
            // We must cast the integer to UInt64 here
            // Otherwise, an integer can fall through to the default case
            // E.g., if someone calls this function with UInt8.max (which is 255), they would not hit the first case (0..<63)
            // The second case cannot be represented at all in UInt8, because 16383 is too big
            // Swift will end up creating the 16383 literal as 0, and thus we will fall all the way through to the default
            switch UInt64(integer) {
            case 0..<63:
                return 1
            case 0..<16383:
                return 2
            case 0..<1_073_741_823:
                return 4
            case 0..<4_611_686_018_427_387_903:
                return 8
            default:
                fatalError("QUIC variable-length integer outside of valid range")
            }
        }

        @inlinable
        public func writeInteger<IntegerType: FixedWidthInteger>(
            _ integer: IntegerType,
            to buffer: inout ByteBuffer
        ) -> Int {
            self.writeInteger(integer, reservedCapacity: 0, to: &buffer)
        }

        @inlinable
        public func writeInteger<IntegerType: FixedWidthInteger>(
            _ integer: IntegerType,
            reservedCapacity: Int,
            to buffer: inout ByteBuffer
        ) -> Int {
            if reservedCapacity > 8 {
                fatalError("Reserved space for QUIC encoded integer must be at most 8 bytes")
            }
            // Use more space than necessary in order to fill the reserved space
            // This will avoid a memmove
            // If the needed space is more than the reserved, we can't avoid the move
            switch max(reservedCapacity, Self.bytesNeededForInteger(integer)) {
            case 1:
                // Easy, store the value. The top two bits are 0 so we don't need to do any masking.
                return buffer.writeInteger(UInt8(truncatingIfNeeded: integer))
            case 2:
                // Set the top two bit mask, then write the value.
                let value = UInt16(truncatingIfNeeded: integer) | (0x40 << 8)
                return buffer.writeInteger(value)
            case 4:
                // Set the top two bit mask, then write the value.
                let value = UInt32(truncatingIfNeeded: integer) | (0x80 << 24)
                return buffer.writeInteger(value)
            case 8:
                // Set the top two bit mask, then write the value.
                let value = UInt64(truncatingIfNeeded: integer) | (0xC0 << 56)
                return buffer.writeInteger(value)
            default:
                fatalError("Unreachable")
            }
        }
    }
}

extension NIOBinaryIntegerEncodingStrategy where Self == ByteBuffer.QUICBinaryEncodingStrategy {
    @inlinable
    /// Encodes bytes as defined in RFC 9000 § 16
    /// - Parameter requiredBytesHint: An estimate of the bytes required to write integers using this strategy. This parameter is only relevant if calling ``ByteBuffer/writeLengthPrefixed(strategy:writeData:)``
    /// - Returns: An instance of ``ByteBuffer/QUICBinaryEncodingStrategy``
    public static func quic(
        requiredBytesHint: ByteBuffer.QUICBinaryEncodingStrategy.IntegerLength
    ) -> ByteBuffer.QUICBinaryEncodingStrategy {
        ByteBuffer.QUICBinaryEncodingStrategy(requiredBytesHint: requiredBytesHint)
    }

    @inlinable
    /// Encodes bytes as defined in RFC 9000 § 16
    public static var quic: ByteBuffer.QUICBinaryEncodingStrategy { .quic(requiredBytesHint: .four) }
}
