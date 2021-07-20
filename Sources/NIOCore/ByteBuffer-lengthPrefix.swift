//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

extension ByteBuffer {
    public struct LengthPrefixError: Swift.Error {
        private enum BaseError {
            case messageLengthDoesNotFitExactlyIntoRequiredIntegerFormat
        }
        private var baseError: BaseError
        
        public static let messageLengthDoesNotFitExactlyIntoRequiredIntegerFormat: LengthPrefixError = .init(baseError: .messageLengthDoesNotFitExactlyIntoRequiredIntegerFormat)
    }
}

extension ByteBuffer {
    /// Prefixes a message written by `writeMessage` with the number of bytes written as an `Integer`.
    /// - Throws: If the number of bytes written during `writeMessage` can not be exactly represented as the given `Integer` i.e. if the number of bytes written is greater than `Integer.max`
    /// - Returns: Number of total bytes written
    @discardableResult
    @inlinable
    public mutating func writeLengthPrefixed<Integer: FixedWidthInteger>(
        endianness: Endianness = .big,
        as integer: Integer.Type,
        message writeMessage: (inout ByteBuffer) throws -> Int
    ) throws -> Int {
        let lengthPrefixIndex = self.writerIndex
        // Write a zero as a placeholder which will later be overwritten by the actual number of bytes written
        self.writeInteger(.zero, endianness: endianness, as: Integer.self)
        
        return try self.setLengthPrefixed(at: lengthPrefixIndex, endianness: endianness, as: Integer.self, message: writeMessage)
    }
    
    /// Prefixes a message with the number returned by `setMessage` as an `Integer`.
    /// - Throws: If the number of bytes returned by `setMessage` can not be exactly represented as the given `Integer` i.e. if the number is greater than `Integer.max`
    /// - Returns: Number of total bytes written i.e. size of the integer plus the number returned by `setMessage`
    @discardableResult
    @inlinable
    public mutating func setLengthPrefixed<Integer: FixedWidthInteger>(
        at index: Int,
        endianness: Endianness = .big,
        as integer: Integer.Type,
        message setMessage: (inout ByteBuffer) throws -> Int
    ) throws -> Int {
        let messageLength = try setMessage(&self)
        
        guard let lengthPrefix = Integer(exactly: messageLength) else {
            throw LengthPrefixError.messageLengthDoesNotFitExactlyIntoRequiredIntegerFormat
        }
        let lengthPrefixByteCount = self.setInteger(lengthPrefix, at: index, endianness: endianness, as: Integer.self)
        
        return messageLength + lengthPrefixByteCount
    }
}
