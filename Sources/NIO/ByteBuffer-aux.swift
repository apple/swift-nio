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

import Dispatch

extension ByteBuffer {

    // MARK: Bytes ([UInt8]) APIs

    /// Get `length` bytes starting at `index` and return the result as `[UInt8]`. This will not change the reader index.
    /// The selected bytes must be readable or else `nil` will be returned.
    ///
    /// - parameters:
    ///     - index: The starting index of the bytes of interest into the `ByteBuffer`.
    ///     - length: The number of bytes of interest.
    /// - returns: A `[UInt8]` value containing the bytes of interest or `nil` if the bytes `ByteBuffer` are not readable.
    public func getBytes(at index: Int, length: Int) -> [UInt8]? {
        guard let range = self.rangeWithinReadableBytes(index: index, length: length) else {
            return nil
        }

        return self.withUnsafeReadableBytes { ptr in
            // this is not technically correct because we shouldn't just bind
            // the memory to `UInt8` but it's not a real issue either and we
            // need to work around https://bugs.swift.org/browse/SR-9604
            Array<UInt8>(UnsafeRawBufferPointer(rebasing: ptr[range]).bindMemory(to: UInt8.self))
        }
    }

    /// Read `length` bytes off this `ByteBuffer`, move the reader index forward by `length` bytes and return the result
    /// as `[UInt8]`.
    ///
    /// - parameters:
    ///     - length: The number of bytes to be read from this `ByteBuffer`.
    /// - returns: A `[UInt8]` value containing `length` bytes or `nil` if there aren't at least `length` bytes readable.
    public mutating func readBytes(length: Int) -> [UInt8]? {
        return self.getBytes(at: self.readerIndex, length: length).map {
            self._moveReaderIndex(forwardBy: length)
            return $0
        }
    }

    // MARK: StaticString APIs

    /// Write the static `string` into this `ByteBuffer` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - string: The string to write.
    /// - returns: The number of bytes written.
    @discardableResult
    public mutating func writeStaticString(_ string: StaticString) -> Int {
        let written = self.setStaticString(string, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }

    /// Write the static `string` into this `ByteBuffer` at `index` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - string: The string to write.
    ///     - index: The index for the first serialized byte.
    /// - returns: The number of bytes written.
    public mutating func setStaticString(_ string: StaticString, at index: Int) -> Int {
        // please do not replace the code below with code that uses `string.withUTF8Buffer { ... }` (see SR-7541)
        return self.setBytes(UnsafeRawBufferPointer(start: string.utf8Start,
                                                    count: string.utf8CodeUnitCount), at: index)
    }

    // MARK: String APIs
    /// Write `string` into this `ByteBuffer` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - string: The string to write.
    /// - returns: The number of bytes written.
    @discardableResult
    public mutating func writeString(_ string: String) -> Int {
        let written = self.setString(string, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }

    @inline(never)
    @usableFromInline
    mutating func _setStringSlowpath(_ string: String, at index: Int) -> Int {
        // slow path, let's try to force the string to be native
        if let written = (string + "").utf8.withContiguousStorageIfAvailable({ utf8Bytes in
            self.setBytes(utf8Bytes, at: index)
        }) {
            return written
        } else {
            return self.setBytes(string.utf8, at: index)
        }
    }

    /// Write `string` into this `ByteBuffer` at `index` using UTF-8 encoding. Does not move the writer index.
    ///
    /// - parameters:
    ///     - string: The string to write.
    ///     - index: The index for the first serialized byte.
    /// - returns: The number of bytes written.
    @discardableResult
    @inlinable
    public mutating func setString(_ string: String, at index: Int) -> Int {
        // Do not implement setString via setSubstring. As of Swift version 5.1.3,
        // Substring.UTF8View does not implement withContiguousStorageIfAvailable
        // and therefore has no fast access to the backing storage.
        if let written = string.utf8.withContiguousStorageIfAvailable({ utf8Bytes in
            self.setBytes(utf8Bytes, at: index)
        }) {
            // fast path, directly available
            return written
        } else {
            return self._setStringSlowpath(string, at: index)
        }
    }

    /// Get the string at `index` from this `ByteBuffer` decoding using the UTF-8 encoding. Does not move the reader index.
    /// The selected bytes must be readable or else `nil` will be returned.
    ///
    /// - parameters:
    ///     - index: The starting index into `ByteBuffer` containing the string of interest.
    ///     - length: The number of bytes making up the string.
    /// - returns: A `String` value containing the UTF-8 decoded selected bytes from this `ByteBuffer` or `nil` if
    ///            the requested bytes are not readable.
    public func getString(at index: Int, length: Int) -> String? {
        guard let range = self.rangeWithinReadableBytes(index: index, length: length) else {
            return nil
        }
        return self.withUnsafeReadableBytes { pointer in
            assert(range.lowerBound >= 0 && (range.upperBound - range.lowerBound) <= pointer.count)
            return String(decoding: UnsafeRawBufferPointer(rebasing: pointer[range]), as: Unicode.UTF8.self)
        }
    }

    /// Read `length` bytes off this `ByteBuffer`, decoding it as `String` using the UTF-8 encoding. Move the reader index forward by `length`.
    ///
    /// - parameters:
    ///     - length: The number of bytes making up the string.
    /// - returns: A `String` value deserialized from this `ByteBuffer` or `nil` if there aren't at least `length` bytes readable.
    public mutating func readString(length: Int) -> String? {
        return self.getString(at: self.readerIndex, length: length).map {
            self._moveReaderIndex(forwardBy: length)
            return $0
        }
    }

    // MARK: Substring APIs
    /// Write `substring` into this `ByteBuffer` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - substring: The substring to write.
    /// - returns: The number of bytes written.
    @discardableResult
    public mutating func writeSubstring(_ substring: Substring) -> Int {
        let written = self.setSubstring(substring, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }
    
    /// Write `substring` into this `ByteBuffer` at `index` using UTF-8 encoding. Does not move the writer index.
    ///
    /// - parameters:
    ///     - substring: The substring to write.
    ///     - index: The index for the first serilized byte.
    /// - returns: The number of bytes written
    @discardableResult
    @inlinable
    public mutating func setSubstring(_ substring: Substring, at index: Int) -> Int {
        // As of Swift 5.1.3, Substring.UTF8View does not implement
        // withContiguousStorageIfAvailable and therefore has no fast access
        // to the backing storage. For now, convert to a String and call
        // setString instead.
        return self.setString(String(substring), at: index)
    }
    
    // MARK: DispatchData APIs
    /// Write `dispatchData` into this `ByteBuffer`, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - dispatchData: The `DispatchData` instance to write to the `ByteBuffer`.
    /// - returns: The number of bytes written.
    @discardableResult
    public mutating func writeDispatchData(_ dispatchData: DispatchData) -> Int {
        let written = self.setDispatchData(dispatchData, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }

    /// Write `dispatchData` into this `ByteBuffer` at `index`. Does not move the writer index.
    ///
    /// - parameters:
    ///     - dispatchData: The `DispatchData` to write.
    ///     - index: The index for the first serialized byte.
    /// - returns: The number of bytes written.
    @discardableResult
    public mutating func setDispatchData(_ dispatchData: DispatchData, at index: Int) -> Int {
        let allBytesCount = dispatchData.count
        self.reserveCapacity(index + allBytesCount)
        self.withVeryUnsafeMutableBytes { destCompleteStorage in
            assert(destCompleteStorage.count >= index + allBytesCount)
            let dest = destCompleteStorage[index ..< index + allBytesCount]
            dispatchData.copyBytes(to: .init(rebasing: dest), count: dest.count)
        }
        return allBytesCount
    }

    /// Get the bytes at `index` from this `ByteBuffer` as a `DispatchData`. Does not move the reader index.
    /// The selected bytes must be readable or else `nil` will be returned.
    ///
    /// - parameters:
    ///     - index: The starting index into `ByteBuffer` containing the string of interest.
    ///     - length: The number of bytes.
    /// - returns: A `DispatchData` value deserialized from this `ByteBuffer` or `nil` if the requested bytes
    ///            are not readable.
    public func getDispatchData(at index: Int, length: Int) -> DispatchData? {
        guard let range = self.rangeWithinReadableBytes(index: index, length: length) else {
            return nil
        }
        return self.withUnsafeReadableBytes { pointer in
            return DispatchData(bytes: UnsafeRawBufferPointer(rebasing: pointer[range]))
        }
    }

    /// Read `length` bytes off this `ByteBuffer` and return them as a `DispatchData`. Move the reader index forward by `length`.
    ///
    /// - parameters:
    ///     - length: The number of bytes.
    /// - returns: A `DispatchData` value containing the bytes from this `ByteBuffer` or `nil` if there aren't at least `length` bytes readable.
    public mutating func readDispatchData(length: Int) -> DispatchData? {
        return self.getDispatchData(at: self.readerIndex, length: length).map {
            self._moveReaderIndex(forwardBy: length)
            return $0
        }
    }


    // MARK: Other APIs

    /// Yields an immutable buffer pointer containing this `ByteBuffer`'s readable bytes. Will move the reader index
    /// by the number of bytes returned by `body`.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the yielded bytes and returns the number of bytes it processed.
    /// - returns: The number of bytes read.
    @discardableResult
    @inlinable
    public mutating func readWithUnsafeReadableBytes(_ body: (UnsafeRawBufferPointer) throws -> Int) rethrows -> Int {
        let bytesRead = try self.withUnsafeReadableBytes({ try body($0) })
        self._moveReaderIndex(forwardBy: bytesRead)
        return bytesRead
    }

    /// Yields an immutable buffer pointer containing this `ByteBuffer`'s readable bytes. Will move the reader index
    /// by the number of bytes `body` returns in the first tuple component.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the yielded bytes and returns the number of bytes it processed along with some other value.
    /// - returns: The value `body` returned in the second tuple component.
    @inlinable
    public mutating func readWithUnsafeReadableBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> (Int, T)) rethrows -> T {
        let (bytesRead, ret) = try self.withUnsafeReadableBytes({ try body($0) })
        self._moveReaderIndex(forwardBy: bytesRead)
        return ret
    }

    /// Yields a mutable buffer pointer containing this `ByteBuffer`'s readable bytes. You may modify the yielded bytes.
    /// Will move the reader index by the number of bytes returned by `body` but leave writer index as it was.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the yielded bytes and returns the number of bytes it processed.
    /// - returns: The number of bytes read.
    @discardableResult
    @inlinable
    public mutating func readWithUnsafeMutableReadableBytes(_ body: (UnsafeMutableRawBufferPointer) throws -> Int) rethrows -> Int {
        let bytesRead = try self.withUnsafeMutableReadableBytes({ try body($0) })
        self._moveReaderIndex(forwardBy: bytesRead)
        return bytesRead
    }

    /// Yields a mutable buffer pointer containing this `ByteBuffer`'s readable bytes. You may modify the yielded bytes.
    /// Will move the reader index by the number of bytes `body` returns in the first tuple component but leave writer index as it was.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the yielded bytes and returns the number of bytes it processed along with some other value.
    /// - returns: The value `body` returned in the second tuple component.
    @inlinable
    public mutating func readWithUnsafeMutableReadableBytes<T>(_ body: (UnsafeMutableRawBufferPointer) throws -> (Int, T)) rethrows -> T {
        let (bytesRead, ret) = try self.withUnsafeMutableReadableBytes({ try body($0) })
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
    @available(*, deprecated, renamed: "setBuffer(_:at:)")
    public mutating func set(buffer: ByteBuffer, at index: Int) -> Int {
        return self.setBuffer(buffer, at: index)
    }

    /// Copy `buffer`'s readable bytes into this `ByteBuffer` starting at `index`. Does not move any of the reader or writer indices.
    ///
    /// - parameters:
    ///     - buffer: The `ByteBuffer` to copy.
    ///     - index: The index for the first byte.
    /// - returns: The number of bytes written.
    @discardableResult
    public mutating func setBuffer(_ buffer: ByteBuffer, at index: Int) -> Int {
        return buffer.withUnsafeReadableBytes{ p in
            self.setBytes(p, at: index)
        }
    }

    /// Write `buffer`'s readable bytes into this `ByteBuffer` starting at `writerIndex`. This will move both this
    /// `ByteBuffer`'s writer index as well as `buffer`'s reader index by the number of bytes readable in `buffer`.
    ///
    /// - parameters:
    ///     - buffer: The `ByteBuffer` to write.
    /// - returns: The number of bytes written to this `ByteBuffer` which is equal to the number of bytes read from `buffer`.
    @discardableResult
    public mutating func writeBuffer(_ buffer: inout ByteBuffer) -> Int {
        let written = self.setBuffer(buffer, at: writerIndex)
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
    @inlinable
    public mutating func writeBytes<Bytes: Sequence>(_ bytes: Bytes) -> Int where Bytes.Element == UInt8 {
        let written = self.setBytes(bytes, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }

    /// Write `bytes` into this `ByteBuffer`. Moves the writer index forward by the number of bytes written.
    ///
    /// - parameters:
    ///     - bytes: An `UnsafeRawBufferPointer`
    /// - returns: The number of bytes written or `bytes.count`.
    @discardableResult
    @inlinable
    public mutating func writeBytes(_ bytes: UnsafeRawBufferPointer) -> Int {
        let written = self.setBytes(bytes, at: self.writerIndex)
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
        return self.getSlice(at: self.readerIndex, length: self.readableBytes)! // must work, bytes definitely in the buffer
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
        return self.getSlice(at: self.readerIndex, length: length).map {
            self._moveReaderIndex(forwardBy: length)
            return $0
        }
    }
}
