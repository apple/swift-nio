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

#if os(macOS) || os(tvOS) || os(iOS)
    import Darwin
#else
    import Glibc
#endif

extension ByteBuffer {

    // MARK: Bytes ([UInt8]) APIs
    public func bytes(at index: Int, length: Int) -> [UInt8]? {
        precondition(index >= 0, "index must not be negative")
        precondition(length >= 0, "length must not be negative")
        guard index <= self.capacity - length else {
            return nil
        }

        return self.withVeryUnsafeBytes { ptr in
            Array.init(UnsafeBufferPointer<UInt8>(start: ptr.baseAddress?.advanced(by: index).assumingMemoryBound(to: UInt8.self),
                                                  count: length))
        }
    }

    public mutating func readBytes(length: Int) -> [UInt8]? {
        precondition(length >= 0, "length must not be negative")
        guard self.readableBytes >= length else {
            return nil
        }
        defer {
            self.moveReaderIndex(forwardBy: length)
        }
        return self.bytes(at: self.readerIndex, length: length)! /* must work, enough readable bytes */
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
    public mutating func write(string: String) -> Int? {
        if let written = self.set(string: string, at: self.writerIndex) {
            self.moveWriterIndex(forwardBy: written)
            return written
        } else {
            return nil
        }
    }

    @discardableResult
    public mutating func set(string: String, at index: Int) -> Int? {
        return self.set(bytes: string.utf8, at: index)
    }

    public func string(at index: Int, length: Int) -> String? {
        precondition(index >= 0, "index must not be negative")
        precondition(length >= 0, "length must not be negative")
        return withVeryUnsafeBytes { pointer in
            guard index <= pointer.count - length else {
                return nil
            }
            return String(decoding: UnsafeBufferPointer(start: pointer.baseAddress?.assumingMemoryBound(to: UInt8.self).advanced(by: index), count: length),
                          as: UTF8.self)
        }
    }

    public mutating func readString(length: Int) -> String? {
        precondition(length >= 0, "length must not be negative")
        guard self.readableBytes >= length else {
            return nil
        }
        defer {
            self.moveReaderIndex(forwardBy: length)
        }
        return self.string(at: self.readerIndex, length: length)! /* must work, enough readable bytes */
    }

    // MARK: Other APIs
    public mutating func readWithUnsafeReadableBytes(_ fn: (UnsafeRawBufferPointer) throws -> Int) rethrows -> Int {
        let bytesRead = try self.withUnsafeReadableBytes(fn)
        self.moveReaderIndex(forwardBy: bytesRead)
        return bytesRead
    }

    public mutating func readWithUnsafeReadableBytes<T>(_ fn: (UnsafeRawBufferPointer) throws -> (Int, T)) rethrows -> T {
        let (bytesRead, ret) = try self.withUnsafeReadableBytes(fn)
        self.moveReaderIndex(forwardBy: bytesRead)
        return ret
    }

    public mutating func readWithUnsafeMutableReadableBytes(_ fn: (UnsafeMutableRawBufferPointer) throws -> Int) rethrows -> Int {
        let bytesRead = try self.withUnsafeMutableReadableBytes(fn)
        self.moveReaderIndex(forwardBy: bytesRead)
        return bytesRead
    }

    public mutating func readWithUnsafeMutableReadableBytes<T>(_ fn: (UnsafeMutableRawBufferPointer) throws -> (Int, T)) rethrows -> T {
        let (bytesRead, ret) = try self.withUnsafeMutableReadableBytes(fn)
        self.moveReaderIndex(forwardBy: bytesRead)
        return ret
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
    public mutating func write<S: Collection>(bytes: S) -> Int where S.Element == UInt8 {
        let written = set(bytes: bytes, at: self.writerIndex)
        self.moveWriterIndex(forwardBy: written)
        return written
    }

    @discardableResult
    public mutating func write<S: ContiguousCollection>(bytes: S) -> Int where S.Element == UInt8 {
        let written = set(bytes: bytes, at: self.writerIndex)
        self.moveWriterIndex(forwardBy: written)
        return written
    }

    public func slice() -> ByteBuffer {
        return slice(at: self.readerIndex, length: self.readableBytes)!
    }

    public mutating func readSlice(length: Int) -> ByteBuffer? {
        precondition(length >= 0, "length must not be negative")
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
