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
    public struct QUICBinaryEncodingStrategy: NIOBinaryIntegerEncodingStrategy {
        public var reservedCapacityForInteger: Int

        @inlinable
        public init(reservedCapacity: Int) {
            precondition(
                reservedCapacity == 0
                    || reservedCapacity == 1
                    || reservedCapacity == 2
                    || reservedCapacity == 4
                    || reservedCapacity == 8
            )
            self.reservedCapacityForInteger = reservedCapacity
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

        private enum NumBytes {
            case one, two, four, eight
        }

        @usableFromInline
        func bytesNeededForInteger<IntegerType: FixedWidthInteger>(_ integer: IntegerType) -> Int {
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
                fatalError("Could not write QUIC variable-length integer: outside of valid range")
            }
        }

        @inlinable
        public func writeInteger<IntegerType: FixedWidthInteger>(
            _ integer: IntegerType,
            to buffer: inout ByteBuffer
        ) -> Int {
            self.writeIntegerWithReservedCapacity(integer, reservedCapacity: 0, to: &buffer)
        }

        @inlinable
        public func writeIntegerWithReservedCapacity<IntegerType: FixedWidthInteger>(
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
            switch max(reservedCapacity, self.bytesNeededForInteger(integer)) {
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
    public static func quic(reservedCapacity: Int) -> ByteBuffer.QUICBinaryEncodingStrategy {
        ByteBuffer.QUICBinaryEncodingStrategy(reservedCapacity: reservedCapacity)
    }

    @inlinable
    public static var quic: ByteBuffer.QUICBinaryEncodingStrategy { .quic(reservedCapacity: 4) }
}
