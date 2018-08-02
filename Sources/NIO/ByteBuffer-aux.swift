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

extension ByteBuffer {

    // MARK: Bytes ([UInt8]) APIs

    /// Get `length` bytes starting at `index` and return the result as `[UInt8]`. This will not change the reader index.
    ///
    /// - note: Please consider using `readBytes` which is a safer alternative that automatically maintains the
    ///         `readerIndex` and won't allow you to read uninitialized memory.
    /// - warning: This method allows the user to read any of the bytes in the `ByteBuffer`'s storage, including
    ///           _uninitialized_ ones. To use this API in a safe way the user needs to make sure all the requested
    ///           bytes have been written before and are therefore initialized. Note that bytes between (including)
    ///           `readerIndex` and (excluding) `writerIndex` are always initialized by contract and therefore must be
    ///           safe to read.
    /// - parameters:
    ///     - index: The starting index of the bytes of interest into the `ByteBuffer`.
    ///     - length: The number of bytes of interest.
    /// - returns: A `[UInt8]` value containing the bytes of interest or `nil` if the `ByteBuffer` doesn't contain those bytes.
    public func getBytes(at index: Int, length: Int) -> [UInt8]? {
        precondition(index >= 0, "index must not be negative")
        precondition(length >= 0, "length must not be negative")
        guard index <= self.capacity - length else {
            return nil
        }

        return self.withVeryUnsafeBytes { ptr in
            Array<UInt8>(ptr[index..<(index+length)])
        }
    }

    /// Read `length` bytes off this `ByteBuffer`, move the reader index forward by `length` bytes and return the result
    /// as `[UInt8]`.
    ///
    /// - parameters:
    ///     - length: The number of bytes to be read from this `ByteBuffer`.
    /// - returns: A `[UInt8]` value containing `length` bytes or `nil` if there aren't at least `length` bytes readable.
    public mutating func readBytes(length: Int) -> [UInt8]? {
        precondition(length >= 0, "length must not be negative")
        guard self.readableBytes >= length else {
            return nil
        }
        defer {
            self._moveReaderIndex(forwardBy: length)
        }
        return self.getBytes(at: self.readerIndex, length: length)! /* must work, enough readable bytes */
    }

    // MARK: StaticString APIs

    /// Write the static `string` into this `ByteBuffer` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - string: The string to write.
    /// - returns: The number of bytes written.
    @discardableResult
    public mutating func write(staticString string: StaticString) -> Int {
        let written = self.set(staticString: string, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }

    /// Write the static `string` into this `ByteBuffer` at `index` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - string: The string to write.
    ///     - index: The index for the first serialized byte.
    /// - returns: The number of bytes written.
    public mutating func set(staticString string: StaticString, at index: Int) -> Int {
        // please do not replace the code below with code that uses `string.withUTF8Buffer { ... }` (see SR-7541)
        return self.set(bytes: UnsafeRawBufferPointer(start: string.utf8Start,
                                                      count: string.utf8CodeUnitCount), at: index)
    }

    // MARK: String APIs
    /// Write `string` into this `ByteBuffer` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - string: The string to write.
    /// - returns: The number of bytes written.
    @discardableResult
    public mutating func write(string: String) -> Int? {
        if let written = self.set(string: string, at: self.writerIndex) {
            self._moveWriterIndex(forwardBy: written)
            return written
        } else {
            return nil
        }
    }

    /// Write `string` into this `ByteBuffer` at `index` using UTF-8 encoding. Does not move the writer index.
    ///
    /// - parameters:
    ///     - string: The string to write.
    ///     - index: The index for the first serialized byte.
    /// - returns: The number of bytes written.
    @discardableResult
    public mutating func set(string: String, at index: Int) -> Int? {
        return self.set(bytes: string.utf8, at: index)
    }

    /// Get the string at `index` from this `ByteBuffer` decoding using the UTF-8 encoding. Does not move the reader index.
    ///
    /// - note: Please consider using `readString` which is a safer alternative that automatically maintains the
    ///         `readerIndex` and won't allow you to read uninitialized memory.
    /// - warning: This method allows the user to read any of the bytes in the `ByteBuffer`'s storage, including
    ///           _uninitialized_ ones. To use this API in a safe way the user needs to make sure all the requested
    ///           bytes have been written before and are therefore initialized. Note that bytes between (including)
    ///           `readerIndex` and (excluding) `writerIndex` are always initialized by contract and therefore must be
    ///           safe to read.
    /// - parameters:
    ///     - index: The starting index into `ByteBuffer` containing the string of interest.
    ///     - length: The number of bytes making up the string.
    /// - returns: A `String` value deserialized from this `ByteBuffer` or `nil` if the requested bytes aren't contained in this `ByteBuffer`.
    public func getString(at index: Int, length: Int) -> String? {
        precondition(index >= 0, "index must not be negative")
        precondition(length >= 0, "length must not be negative")
        return withVeryUnsafeBytes { pointer in
            guard index <= pointer.count - length else {
                return nil
            }
            return String(decoding: pointer[index..<(index+length)], as: UTF8.self)
        }
    }

    /// Read `length` bytes off this `ByteBuffer`, decoding it as `String` using the UTF-8 encoding. Move the reader index forward by `length`.
    ///
    /// - parameters:
    ///     - length: The number of bytes making up the string.
    /// - returns: A `String` value deserialized from this `ByteBuffer` or `nil` if there aren't at least `length` bytes readable.
    public mutating func readString(length: Int) -> String? {
        precondition(length >= 0, "length must not be negative")
        guard self.readableBytes >= length else {
            return nil
        }
        defer {
            self._moveReaderIndex(forwardBy: length)
        }
        return self.getString(at: self.readerIndex, length: length)! /* must work, enough readable bytes */
    }

    // MARK: Other APIs

    /// Yields an immutable buffer pointer containing this `ByteBuffer`'s readable bytes. Will move the reader index
    /// by the number of bytes returned by `fn`.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the yielded bytes and returns the number of bytes it processed.
    /// - returns: The number of bytes read.
    @discardableResult
    @_inlineable
    public mutating func readWithUnsafeReadableBytes(_ body: (UnsafeRawBufferPointer) throws -> Int) rethrows -> Int {
        let bytesRead = try self.withUnsafeReadableBytes(body)
        self._moveReaderIndex(forwardBy: bytesRead)
        return bytesRead
    }

    /// Yields an immutable buffer pointer containing this `ByteBuffer`'s readable bytes. Will move the reader index
    /// by the number of bytes `fn` returns in the first tuple component.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the yielded bytes and returns the number of bytes it processed along with some other value.
    /// - returns: The value `fn` returned in the second tuple component.
    @_inlineable
    public mutating func readWithUnsafeReadableBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> (Int, T)) rethrows -> T {
        let (bytesRead, ret) = try self.withUnsafeReadableBytes(body)
        self._moveReaderIndex(forwardBy: bytesRead)
        return ret
    }

    /// Yields a mutable buffer pointer containing this `ByteBuffer`'s readable bytes. You may modify the yielded bytes.
    /// Will move the reader index by the number of bytes returned by `fn` but leave writer index as it was.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the yielded bytes and returns the number of bytes it processed.
    /// - returns: The number of bytes read.
    @discardableResult
    @_inlineable
    public mutating func readWithUnsafeMutableReadableBytes(_ body: (UnsafeMutableRawBufferPointer) throws -> Int) rethrows -> Int {
        let bytesRead = try self.withUnsafeMutableReadableBytes(body)
        self._moveReaderIndex(forwardBy: bytesRead)
        return bytesRead
    }

    /// Yields a mutable buffer pointer containing this `ByteBuffer`'s readable bytes. You may modify the yielded bytes.
    /// Will move the reader index by the number of bytes `fn` returns in the first tuple component but leave writer index as it was.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the yielded bytes and returns the number of bytes it processed along with some other value.
    /// - returns: The value `fn` returned in the second tuple component.
    @_inlineable
    public mutating func readWithUnsafeMutableReadableBytes<T>(_ body: (UnsafeMutableRawBufferPointer) throws -> (Int, T)) rethrows -> T {
        let (bytesRead, ret) = try self.withUnsafeMutableReadableBytes(body)
        self._moveReaderIndex(forwardBy: bytesRead)
        return ret
    }

    /// Copy `buffer`'s readable bytes into this `ByteBuffer` starting at `index`. Does not move any of the reader or writer indices.
    ///
    /// - parameters:
    ///     - buffer: The `ByteBuffer` to copy.
    ///     - index: The index for the first byte.
    /// - returns: The number of bytes written.
    @discardableResult
    public mutating func set(buffer: ByteBuffer, at index: Int) -> Int {
        return buffer.withUnsafeReadableBytes{ p in
            self.set(bytes: p, at: index)
        }
    }

    /// Write `buffer`'s readable bytes into this `ByteBuffer` starting at `writerIndex`. This will move both this
    /// `ByteBuffer`'s writer index as well as `buffer`'s reader index by the number of bytes readable in `buffer`.
    ///
    /// - parameters:
    ///     - buffer: The `ByteBuffer` to write.
    /// - returns: The number of bytes written to this `ByteBuffer` which is equal to the number of bytes read from `buffer`.
    @discardableResult
    public mutating func write(buffer: inout ByteBuffer) -> Int {
        let written = set(buffer: buffer, at: writerIndex)
        self._moveWriterIndex(forwardBy: written)
        buffer._moveReaderIndex(forwardBy: written)
        return written
    }

    /// Write `bytes`, a `Sequence` of `UInt8` into this `ByteBuffer`. Moves the writer index forward by the number of bytes written.
    ///
    /// - parameters:
    ///     - bytes: A `Collection` of `UInt8` to be written.
    /// - returns: The number of bytes written or `bytes.count`.
    @discardableResult
    @_inlineable
    public mutating func write<S: Sequence>(bytes: S) -> Int where S.Element == UInt8 {
        let written = set(bytes: bytes, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }

    /// Write `bytes`, a `ContiguousCollection` of `UInt8` into this `ByteBuffer`. Moves the writer index forward by the number of bytes written.
    /// This method is likely more efficient than the one operating on plain `Collection` as it will use `memcpy` to copy all the bytes in one go.
    ///
    /// - parameters:
    ///     - bytes: A `ContiguousCollection` of `UInt8` to be written.
    /// - returns: The number of bytes written or `bytes.count`.
    @discardableResult
    @_inlineable
    public mutating func write<S: ContiguousCollection>(bytes: S) -> Int where S.Element == UInt8 {
        let written = set(bytes: bytes, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }

    /// Slice the readable bytes off this `ByteBuffer` without modifying the reader index. This method will return a
    /// `ByteBuffer` sharing the underlying storage with the `ByteBuffer` the method was invoked on. The returned
    /// `ByteBuffer` will contain the bytes in the range `readerIndex..<writerIndex` of the original `ByteBuffer`.
    ///
    /// - note: Because `ByteBuffer` implements copy-on-write a copy of the storage will be automatically triggered when either of the `ByteBuffer`s sharing storage is written to.
    ///
    /// - returns: A `ByteBuffer` sharing storage containing the readable bytes only.
    public func slice() -> ByteBuffer {
        return getSlice(at: self.readerIndex, length: self.readableBytes)!
    }

    /// Slice `length` bytes off this `ByteBuffer` and move the reader index forward by `length`.
    /// If enough bytes are readable the `ByteBuffer` returned by this method will share the underlying storage with
    /// the `ByteBuffer` the method was invoked on.
    /// The returned `ByteBuffer` will contain the bytes in the range `readerIndex..<(readerIndex + length)` of the
    /// original `ByteBuffer`.
    /// The `readerIndex` of the returned `ByteBuffer` will be `0`, the `writerIndex` will be `length`.
    ///
    /// - note: Because `ByteBuffer` implements copy-on-write a copy of the storage will be automatically triggered when either of the `ByteBuffer`s sharing storage is written to.
    ///
    /// - parameters:
    ///     - length: The number of bytes to slice off.
    /// - returns: A `ByteBuffer` sharing storage containing `length` bytes or `nil` if the not enough bytes were readable.
    public mutating func readSlice(length: Int) -> ByteBuffer? {
        precondition(length >= 0, "length must not be negative")
        guard self.readableBytes >= length else {
            return nil
        }

        let buffer = self.getSlice(at: readerIndex, length: length)! /* must work, enough readable bytes */
        self._moveReaderIndex(forwardBy: length)
        return buffer
    }
}
