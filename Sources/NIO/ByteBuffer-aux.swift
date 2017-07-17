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

import Foundation

extension ByteBuffer {

    // MARK: Data APIs
    public mutating func readData(length: Int) -> Data? {
        guard self.readableBytes >= length else {
            return nil
        }
        let data = self.data(at: self.readerIndex, length: length)! /* must work, enough readable bytes */
        self.moveReaderIndex(forwardBy: length)
        return data
    }

    @discardableResult
    public mutating func write(data: Data) -> Int {
        let bytesWritten = self.set(data: data, at: self.writerIndex)
        self.moveWriterIndex(forwardBy: bytesWritten)
        return bytesWritten
    }

    @discardableResult
    public mutating func set(data: Data, at index: Int) -> Int {
        return data.withUnsafeBytes { ptr in
            self.set(bytes: UnsafeRawBufferPointer(start: ptr, count: data.count), at: index)
        }
    }

    // MARK: StaticString APIs
    @discardableResult
    public mutating func write(staticString string: StaticString) -> Int {
        let written = self.set(staticString: string, at: self.writerIndex)
        self.moveWriterIndex(forwardBy: written)
        return written
    }

    public mutating func set(staticString string: StaticString, at index: Int) -> Int {
        return string.withUTF8Buffer { ptr -> Int in
            return self.set(bytes: UnsafeRawBufferPointer(ptr), at: index)
        }
    }

    // MARK: String APIs
    @discardableResult
    public mutating func write(string: String, encoding: String.Encoding = .utf8) -> Int? {
        if let written = self.set(string: string, at: self.writerIndex, encoding: encoding) {
            self.moveWriterIndex(forwardBy: written)
            return written
        } else {
            return nil
        }
    }

    @discardableResult
    public mutating func set(string: String, at index: Int, encoding: String.Encoding = .utf8) -> Int? {
        if encoding == .utf8 {
            let bytes = Array(string.utf8)
            return self.set(bytes: UnsafeRawBufferPointer(start: bytes, count: bytes.count), at: index)
        } else {
            if let data = string.data(using: encoding) {
                return self.set(data: data, at: index)
            } else {
                return nil
            }
        }
    }

    
    public func string(at index: Int, length: Int, encoding: String.Encoding = .utf8) -> String? {
        return withUnsafeBytes { pointer in
            if index + length > pointer.count {
                return nil
            }
            return String(bytes: UnsafeBufferPointer(start: pointer.baseAddress?.assumingMemoryBound(to: UInt8.self).advanced(by: index), count: length), encoding: encoding)
        }
    }

    // MARK: Other APIs
    public mutating func readWithUnsafeMutableBytes(_ fn: (UnsafeMutableRawBufferPointer) throws -> Int) rethrows -> Int {
        let bytesRead = try self.withUnsafeMutableReadableBytes(fn)
        self.moveReaderIndex(forwardBy: bytesRead)
        return bytesRead
    }

    @discardableResult
    public mutating func set(buffer: ByteBuffer, at index: Int) -> Int {
        return buffer.withUnsafeReadableBytes{ p in
            self.set(bytes: p, at: index)
        }
    }

    @discardableResult
    public mutating func write(buffer: inout ByteBuffer) -> Int {
        let written = set(buffer: buffer, at: writerIndex)
        self.moveWriterIndex(forwardBy: written)
        buffer.moveReaderIndex(forwardBy: written)
        return written
    }

    @discardableResult
    public mutating func write(bytes: UnsafeRawBufferPointer) -> Int {
        let written = set(bytes: bytes, at: self.writerIndex)
        self.moveWriterIndex(forwardBy: written)
        return written
    }

    public func slice() -> ByteBuffer {
        return slice(at: self.readerIndex, length: self.readableBytes)!
    }

    public mutating func readSlice(length: Int) -> ByteBuffer? {
        guard self.readableBytes >= length else {
            return nil
        }

        let buffer = self.slice(at: readerIndex, length: length)! /* must work, enough readable bytes */
        self.moveReaderIndex(forwardBy: length)
        return buffer
    }


    public mutating func clear() {
        self.moveWriterIndex(to: 0)
        self.moveReaderIndex(to: 0)
    }
}

extension ByteBuffer: Equatable {
    public static func ==(lhs: ByteBuffer, rhs: ByteBuffer) -> Bool {
        guard lhs.readableBytes == rhs.readableBytes else {
            return false
        }

        return lhs.withUnsafeReadableBytes { lPtr in
            rhs.withUnsafeReadableBytes { rPtr in
                // Shouldn't get here otherwise because of readableBytes check
                assert(lPtr.count == rPtr.count)
                return memcmp(lPtr.baseAddress!, rPtr.baseAddress!, lPtr.count) == 0
            }
        }
    }
}
