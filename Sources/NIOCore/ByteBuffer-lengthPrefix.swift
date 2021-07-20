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
            case readMoreBytesThanSpecifiedInLengthPrefix
            case readLessBytesThanSpecifiedInLengthPrefix
        }
        private var baseError: BaseError
        
        public static let messageLengthDoesNotFitExactlyIntoRequiredIntegerFormat: LengthPrefixError = .init(baseError: .messageLengthDoesNotFitExactlyIntoRequiredIntegerFormat)
        public static let readMoreBytesThanSpecifiedInLengthPrefix: LengthPrefixError = .init(baseError: .readMoreBytesThanSpecifiedInLengthPrefix)
        public static let readLessBytesThanSpecifiedInLengthPrefix: LengthPrefixError = .init(baseError: .readLessBytesThanSpecifiedInLengthPrefix)
    }
}

extension ByteBuffer {
    /// Prefixes a message written by `writeMessage` with the number of bytes written as an `Integer`.
    /// - Parameters:
    ///     - endianness: The endianness of the length prefix `Integer` in this `ByteBuffer` (defaults to big endian).
    ///     - integer: the desired `Integer` type used to write the length prefix
    ///     - writeMessage:
    /// - Throws: If the number of bytes written during `writeMessage` can not be exactly represented as the given `Integer` i.e. if the number of bytes written is greater than `Integer.max`
    /// - Returns: Number of total bytes written
    @discardableResult
    @inlinable
    public mutating func writeLengthPrefixed<Integer>(
        endianness: Endianness = .big,
        as integer: Integer.Type,
        writeMessage: (inout ByteBuffer) throws -> Int
    ) throws -> Int  where Integer: FixedWidthInteger {
        var totalBytesWritten = 0
        
        let lengthPrefixIndex = self.writerIndex
        // Write a zero as a placeholder which will later be overwritten by the actual number of bytes written
        totalBytesWritten += self.writeInteger(.zero, endianness: endianness, as: Integer.self)
        
        let messageLength = try writeMessage(&self)
        totalBytesWritten += messageLength
        
        guard let lengthPrefix = Integer(exactly: messageLength) else {
            throw LengthPrefixError.messageLengthDoesNotFitExactlyIntoRequiredIntegerFormat
        }
        
        self.setInteger(lengthPrefix, at: lengthPrefixIndex, endianness: endianness, as: Integer.self)
        
        return totalBytesWritten
    }
}

extension ByteBuffer {
    /// Reads an `integer` from `self` and passes it to `readMessage`. 
    /// It is checked that exactly the number of bytes specified in the length prefix is read during the call to `readMessage`.
    /// - Parameters:
    ///     - endianness: The endianness of the length prefix `Integer` in this `ByteBuffer` (defaults to big endian).
    ///     - integer: the desired `Integer` type used to read the length prefix
    ///     - readMessage: A closure that takes the length prefix, reads exactly that number of bytes from the given `ByteBuffer` and returns the result.
    /// - Throws: if `readMessage` returns a non-nil value and does not read exactly the number of bytes passed to it.
    /// - Returns: `nil` if the length prefix could not be read, 
    ///            the length prefix is negative or
    ///            the buffer does not contain enough bytes to read a message of this length.
    ///            Otherwise the result of `readMessage`.
    @inlinable
    public mutating func readLengthPrefixed<Integer, Result>(
        endianness: Endianness = .big,
        as integer: Integer.Type,
        readMessage: (Integer, inout ByteBuffer) throws -> Result?
    ) throws -> Result? where Integer: FixedWidthInteger {
        guard let messageLength = self.readInteger(endianness: endianness, as: Integer.self) else {
            return nil
        }
        guard messageLength >= 0,
              messageLength <= readableBytes else {
            return nil
        }
        
        let readStartIndex = self.readerIndex
        guard let result = try readMessage(messageLength, &self) else {
            return nil
        }
        let readEndIndex = self.readerIndex
        
        let readBytes = readEndIndex - readStartIndex
        let expectedReadBytes = Int(messageLength)
        if readBytes < expectedReadBytes {
            throw LengthPrefixError.readLessBytesThanSpecifiedInLengthPrefix
        }
        if readBytes > expectedReadBytes {
            throw LengthPrefixError.readMoreBytesThanSpecifiedInLengthPrefix
        }
        
        return result
    }
}
