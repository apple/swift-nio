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
            case messageCouldNotBeReadSuccessfully
        }
        private var baseError: BaseError
        
        public static let messageLengthDoesNotFitExactlyIntoRequiredIntegerFormat: LengthPrefixError = .init(baseError: .messageLengthDoesNotFitExactlyIntoRequiredIntegerFormat)
        public static let messageCouldNotBeReadSuccessfully: LengthPrefixError = .init(baseError: .messageCouldNotBeReadSuccessfully)
    }
}

extension ByteBuffer {
    /// Prefixes a message written by `writeMessage` with the number of bytes written as an `Integer`.
    /// - Parameters:
    ///     - endianness: The endianness of the length prefix `Integer` in this `ByteBuffer` (defaults to big endian).
    ///     - integer: the desired `Integer` type used to write the length prefix
    ///     - writeMessage: A closure that takes a buffer, writes a message to it and returns the number of bytes written
    /// - Throws: If the number of bytes written during `writeMessage` can not be exactly represented as the given `Integer` i.e. if the number of bytes written is greater than `Integer.max`
    /// - Returns: Number of total bytes written
    @discardableResult
    @inlinable
    public mutating func writeLengthPrefixed<Integer>(
        endianness: Endianness = .big,
        as integer: Integer.Type,
        writeMessage: (inout ByteBuffer) throws -> Int
    ) throws -> Int where Integer: FixedWidthInteger {
        var totalBytesWritten = 0
        
        let lengthPrefixIndex = self.writerIndex
        // Write a zero as a placeholder which will later be overwritten by the actual number of bytes written
        totalBytesWritten += self.writeInteger(.zero, endianness: endianness, as: Integer.self)
        
        let startWriterIndex = self.writerIndex
        let messageLength = try writeMessage(&self)
        let endWriterIndex = self.writerIndex
        
        totalBytesWritten += messageLength
        
        let actualBytesWritten = endWriterIndex - startWriterIndex
        assert(
            actualBytesWritten == messageLength, 
            "writeMessage returned \(messageLength) bytes, but actually \(actualBytesWritten) bytes were written, but they should be the same"
        )
        
        guard let lengthPrefix = Integer(exactly: messageLength) else {
            throw LengthPrefixError.messageLengthDoesNotFitExactlyIntoRequiredIntegerFormat
        }
        
        self.setInteger(lengthPrefix, at: lengthPrefixIndex, endianness: endianness, as: Integer.self)
        
        return totalBytesWritten
    }
}

extension ByteBuffer {
    /// Reads an `Integer` from `self`, reads a slice of that length and passes it to `readMessage`. 
    /// It is checked that `readMessage` returns a non-nil value.
    /// 
    /// The `readerIndex` is **not** moved forward if the length prefix could not be read or `self` does not contain enough bytes. Otherwise `readerIndex` is moved forward even if `readMessage` throws or returns nil.
    /// - Parameters:
    ///     - endianness: The endianness of the length prefix `Integer` in this `ByteBuffer` (defaults to big endian).
    ///     - integer: the desired `Integer` type used to read the length prefix
    ///     - readMessage: A closure that takes a `ByteBuffer` slice which contains the message after the length prefix
    /// - Throws: if `readMessage` returns nil
    /// - Returns: `nil` if the length prefix could not be read, 
    ///            the length prefix is negative or
    ///            the buffer does not contain enough bytes to read a message of this length.
    ///            Otherwise the result of `readMessage`.
    @inlinable
    public mutating func readLengthPrefixed<Integer, Result>(
        endianness: Endianness = .big,
        as integer: Integer.Type,
        readMessage: (ByteBuffer) throws -> Result?
    ) throws -> Result? where Integer: FixedWidthInteger {
        guard let buffer = self.readLengthPrefixedSlice(endianness: endianness, as: Integer.self) else {
            return nil
        }
        guard let result = try readMessage(buffer) else {
            throw LengthPrefixError.messageCouldNotBeReadSuccessfully
        }
        return result
    }
    
    /// Reads an `Integer` from `self` and reads a slice of that length from `self` and returns it.
    /// 
    /// If nil is returned, `readerIndex` is **not** moved forward.
    /// - Parameters:
    ///     - endianness: The endianness of the length prefix `Integer` in this `ByteBuffer` (defaults to big endian).
    ///     - integer: the desired `Integer` type used to read the length prefix
    /// - Returns: `nil` if the length prefix could not be read, 
    ///            the length prefix is negative or
    ///            the buffer does not contain enough bytes to read a message of this length.
    ///            Otherwise the message after the length prefix.
    @inlinable
    public mutating func readLengthPrefixedSlice<Integer>(
        endianness: Endianness = .big,
        as integer: Integer.Type
    ) -> ByteBuffer? where Integer: FixedWidthInteger {
        guard let result = self.getLengthPrefixedSlice(at: self.readerIndex, endianness: endianness, as: Integer.self) else {
            return nil
        }
        self._moveReaderIndex(forwardBy: MemoryLayout<Integer>.size + result.readableBytes)
        return result
    }
    
    /// Gets an `Integer` from `self` and gets a slice of that length from `self` and returns it.
    /// 
    /// - Parameters:
    ///     - endianness: The endianness of the length prefix `Integer` in this `ByteBuffer` (defaults to big endian).
    ///     - integer: the desired `Integer` type used to get the length prefix
    /// - Returns: `nil` if the length prefix could not be read, 
    ///            the length prefix is negative or
    ///            the buffer does not contain enough bytes to read a message of this length.
    ///            Otherwise the message after the length prefix.
    @inlinable
    public func getLengthPrefixedSlice<Integer>(
        at index: Int,
        endianness: Endianness = .big,
        as integer: Integer.Type
    ) -> ByteBuffer? where Integer: FixedWidthInteger {
        guard let lengthPrefix = self.getInteger(at: index, endianness: endianness, as: Integer.self),
              let messageLength = Int(exactly: lengthPrefix),
              let messageBuffer = self.getSlice(at: index + MemoryLayout<Integer>.size, length: messageLength)
        else {
            return nil
        }
        
        return messageBuffer
    }
}
