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

import _NIOBase64

#if canImport(Dispatch)
import Dispatch
#endif

extension ByteBuffer {

    // MARK: Bytes ([UInt8]) APIs

    /// Get `length` bytes starting at `index` and return the result as `[UInt8]`. This will not change the reader index.
    /// The selected bytes must be readable or else `nil` will be returned.
    ///
    /// - Parameters:
    ///   - index: The starting index of the bytes of interest into the `ByteBuffer`.
    ///   - length: The number of bytes of interest.
    /// - Returns: A `[UInt8]` value containing the bytes of interest or `nil` if the bytes `ByteBuffer` are not readable.
    @inlinable
    public func getBytes(at index: Int, length: Int) -> [UInt8]? {
        guard let range = self.rangeWithinReadableBytes(index: index, length: length) else {
            return nil
        }

        return self.withUnsafeReadableBytes { ptr in
            // this is not technically correct because we shouldn't just bind
            // the memory to `UInt8` but it's not a real issue either and we
            // need to work around https://bugs.swift.org/browse/SR-9604
            [UInt8](UnsafeRawBufferPointer(rebasing: ptr[range]).bindMemory(to: UInt8.self))
        }
    }

    /// Read `length` bytes off this `ByteBuffer`, move the reader index forward by `length` bytes and return the result
    /// as `[UInt8]`.
    ///
    /// - Parameters:
    ///   - length: The number of bytes to be read from this `ByteBuffer`.
    /// - Returns: A `[UInt8]` value containing `length` bytes or `nil` if there aren't at least `length` bytes readable.
    @inlinable
    public mutating func readBytes(length: Int) -> [UInt8]? {
        guard let result = self.getBytes(at: self.readerIndex, length: length) else {
            return nil
        }
        self._moveReaderIndex(forwardBy: length)
        return result
    }

    #if compiler(>=6.2)
    @inlinable
    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    public mutating func readInlineArray<
        let count: Int,
        IntegerType: FixedWidthInteger
    >(
        endianness: Endianness = .big,
        as: InlineArray<count, IntegerType>.Type = InlineArray<count, IntegerType>.self
    ) -> InlineArray<count, IntegerType>? {
        // use stride to account for padding bytes
        let stride = MemoryLayout<IntegerType>.stride
        let bytesRequired = stride * count

        guard self.readableBytes >= bytesRequired else {
            return nil
        }

        let inlineArray = InlineArray<count, IntegerType> { (outputSpan: inout OutputSpan<IntegerType>) in
            for index in 0..<count {
                // already made sure of 'self.readableBytes >= bytesRequired' above,
                // so this is safe to force-unwrap as it's guaranteed to exist
                let integer = self.getInteger(
                    // this is less than 'bytesRequired' so is safe to multiply
                    at: stride &* index,
                    endianness: endianness,
                    as: IntegerType.self
                )!
                outputSpan.append(integer)
            }
        }
        // already made sure of 'self.readableBytes >= bytesRequired' above
        self._moveReaderIndex(forwardBy: bytesRequired)
        return inlineArray
    }
    #endif

    /// Returns the Bytes at the current reader index without advancing it.
    ///
    /// This method is equivalent to calling `getBytes(at: readerIndex, ...)`
    ///
    /// - Parameters:
    ///   - length: The number of bytes of interest.
    /// - Returns: A `[UInt8]` value containing the bytes of interest or `nil` if the bytes `ByteBuffer` are not readable.
    @inlinable
    public func peekBytes(length: Int) -> [UInt8]? {
        self.getBytes(at: self.readerIndex, length: length)
    }

    // MARK: StaticString APIs

    /// Write the static `string` into this `ByteBuffer` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - Parameters:
    ///   - string: The string to write.
    /// - Returns: The number of bytes written.
    @discardableResult
    @inlinable
    public mutating func writeStaticString(_ string: StaticString) -> Int {
        let written = self.setStaticString(string, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }

    /// Write the static `string` into this `ByteBuffer` at `index` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - Parameters:
    ///   - string: The string to write.
    ///   - index: The index for the first serialized byte.
    /// - Returns: The number of bytes written.
    @inlinable
    public mutating func setStaticString(_ string: StaticString, at index: Int) -> Int {
        // please do not replace the code below with code that uses `string.withUTF8Buffer { ... }` (see SR-7541)
        self.setBytes(
            UnsafeRawBufferPointer(
                start: string.utf8Start,
                count: string.utf8CodeUnitCount
            ),
            at: index
        )
    }

    // MARK: Hex encoded string APIs
    /// Write ASCII hexadecimal `string` into this `ByteBuffer` as raw bytes, decoding the hexadecimal & moving the writer index forward appropriately.
    /// This method will throw if the string input is not of the "plain" hex encoded format.
    /// - Parameters:
    ///   - plainHexEncodedBytes: The hex encoded string to write. Plain hex dump format is hex bytes optionally separated by spaces, i.e. `48 65 6c 6c 6f` or `48656c6c6f` for `Hello`.
    ///     This format is compatible with `xxd` CLI utility.
    /// - Returns: The number of bytes written.
    @discardableResult
    @inlinable
    public mutating func writePlainHexEncodedBytes(_ plainHexEncodedBytes: String) throws -> Int {
        var slice = plainHexEncodedBytes.utf8[...]
        let initialWriterIndex = self.writerIndex

        do {
            while let nextByte = try slice.popNextHexByte() {
                self.writeInteger(nextByte)
            }
            return self.writerIndex - initialWriterIndex
        } catch {
            self.moveWriterIndex(to: initialWriterIndex)
            throw error
        }
    }

    // MARK: String APIs
    /// Write `string` into this `ByteBuffer` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - Parameters:
    ///   - string: The string to write.
    /// - Returns: The number of bytes written.
    @discardableResult
    @inlinable
    public mutating func writeString(_ string: String) -> Int {
        let written = self.setString(string, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }

    /// Write `string` into this `ByteBuffer` null terminated using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - Parameters:
    ///   - string: The string to write.
    /// - Returns: The number of bytes written.
    @discardableResult
    @inlinable
    public mutating func writeNullTerminatedString(_ string: String) -> Int {
        let written = self.setNullTerminatedString(string, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }

    @inline(never)
    @inlinable
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
    /// - Parameters:
    ///   - string: The string to write.
    ///   - index: The index for the first serialized byte.
    /// - Returns: The number of bytes written.
    @discardableResult
    @inlinable
    public mutating func setString(_ string: String, at index: Int) -> Int {
        // Do not implement setString via setSubstring. Before Swift version 5.3,
        // Substring.UTF8View did not implement withContiguousStorageIfAvailable
        // and therefore had no fast access to the backing storage.
        if let written = string.utf8.withContiguousStorageIfAvailable({ utf8Bytes in
            self.setBytes(utf8Bytes, at: index)
        }) {
            // fast path, directly available
            return written
        } else {
            return self._setStringSlowpath(string, at: index)
        }
    }

    /// Write `string` null terminated into this `ByteBuffer` at `index` using UTF-8 encoding. Does not move the writer index.
    ///
    /// - Parameters:
    ///   - string: The string to write.
    ///   - index: The index for the first serialized byte.
    /// - Returns: The number of bytes written.
    @inlinable
    public mutating func setNullTerminatedString(_ string: String, at index: Int) -> Int {
        let length = self.setString(string, at: index)
        self.setInteger(UInt8(0), at: index &+ length)
        return length &+ 1
    }

    /// Get the string at `index` from this `ByteBuffer` decoding using the UTF-8 encoding. Does not move the reader index.
    /// The selected bytes must be readable or else `nil` will be returned.
    ///
    /// - Parameters:
    ///   - index: The starting index into `ByteBuffer` containing the string of interest.
    ///   - length: The number of bytes making up the string.
    /// - Returns: A `String` value containing the UTF-8 decoded selected bytes from this `ByteBuffer` or `nil` if
    ///            the requested bytes are not readable.
    @inlinable
    public func getString(at index: Int, length: Int) -> String? {
        guard let range = self.rangeWithinReadableBytes(index: index, length: length) else {
            return nil
        }
        return self.withUnsafeReadableBytes { pointer in
            assert(range.lowerBound >= 0 && (range.upperBound - range.lowerBound) <= pointer.count)
            return String(
                decoding: UnsafeRawBufferPointer(rebasing: pointer[range]),
                as: Unicode.UTF8.self
            )
        }
    }

    /// Get the string at `index` from this `ByteBuffer` decoding using the UTF-8 encoding. Does not move the reader index.
    /// The selected bytes must be readable or else `nil` will be returned.
    ///
    /// - Parameters:
    ///   - index: The starting index into `ByteBuffer` containing the null terminated string of interest.
    /// - Returns: A `String` value deserialized from this `ByteBuffer` or `nil` if there isn't a complete null-terminated string,
    ///            including null-terminator, in the readable bytes after `index` in the buffer
    @inlinable
    public func getNullTerminatedString(at index: Int) -> String? {
        guard let stringLength = self._getNullTerminatedStringLength(at: index) else {
            return nil
        }
        return self.getString(at: index, length: stringLength)
    }

    @inlinable
    func _getNullTerminatedStringLength(at index: Int) -> Int? {
        guard self.readerIndex <= index && index < self.writerIndex else {
            return nil
        }
        guard let endIndex = self.readableBytesView[index...].firstIndex(of: 0) else {
            return nil
        }
        return endIndex &- index
    }

    /// Read `length` bytes off this `ByteBuffer`, decoding it as `String` using the UTF-8 encoding. Move the reader index forward by `length`.
    ///
    /// - Parameters:
    ///   - length: The number of bytes making up the string.
    /// - Returns: A `String` value deserialized from this `ByteBuffer` or `nil` if there aren't at least `length` bytes readable.
    @inlinable
    public mutating func readString(length: Int) -> String? {
        guard let result = self.getString(at: self.readerIndex, length: length) else {
            return nil
        }
        self._moveReaderIndex(forwardBy: length)
        return result
    }

    /// Read a null terminated string off this `ByteBuffer`, decoding it as `String` using the UTF-8 encoding. Move the reader index
    /// forward by the string's length and its null terminator.
    ///
    /// - Returns: A `String` value deserialized from this `ByteBuffer` or `nil` if there isn't a complete null-terminated string,
    ///            including null-terminator, in the readable bytes of the buffer
    @inlinable
    public mutating func readNullTerminatedString() -> String? {
        guard let stringLength = self._getNullTerminatedStringLength(at: self.readerIndex) else {
            return nil
        }
        let result = self.readString(length: stringLength)
        self.moveReaderIndex(forwardBy: 1)  // move forward by null terminator
        return result
    }

    // MARK: Substring APIs
    /// Write `substring` into this `ByteBuffer` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - Parameters:
    ///   - substring: The substring to write.
    /// - Returns: The number of bytes written.
    @discardableResult
    @inlinable
    public mutating func writeSubstring(_ substring: Substring) -> Int {
        let written = self.setSubstring(substring, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }

    /// Write `substring` into this `ByteBuffer` at `index` using UTF-8 encoding. Does not move the writer index.
    ///
    /// - Parameters:
    ///   - substring: The substring to write.
    ///   - index: The index for the first serialized byte.
    /// - Returns: The number of bytes written
    @discardableResult
    @inlinable
    public mutating func setSubstring(_ substring: Substring, at index: Int) -> Int {
        // Substring.UTF8View implements withContiguousStorageIfAvailable starting with
        // Swift version 5.3.
        if let written = substring.utf8.withContiguousStorageIfAvailable({ utf8Bytes in
            self.setBytes(utf8Bytes, at: index)
        }) {
            // fast path, directly available
            return written
        } else {
            // slow path, convert to string
            return self.setString(String(substring), at: index)
        }
    }

    /// Return a String decoded from the bytes at the current reader index using UTF-8 encoding.
    ///
    /// This is equivalent to calling `getString(at: readerIndex, length: ...)` and does not advance the reader index.
    ///
    /// - Parameter length: The number of bytes making up the string.
    /// - Returns: A String containing the decoded bytes, or `nil` if the requested bytes are not readable.
    @inlinable
    public func peekString(length: Int) -> String? {
        self.getString(at: self.readerIndex, length: length)
    }

    /// Return a null-terminated String starting at the current reader index.
    ///
    /// This is equivalent to calling `getNullTerminatedString(at: readerIndex)` and does not advance the reader index.
    ///
    /// - Returns: A String decoded from the null-terminated bytes, or `nil` if a complete null-terminated string is not available.
    @inlinable
    public func peekNullTerminatedString() -> String? {
        self.getNullTerminatedString(at: self.readerIndex)
    }

    #if canImport(Dispatch)
    // MARK: DispatchData APIs
    /// Write `dispatchData` into this `ByteBuffer`, moving the writer index forward appropriately.
    ///
    /// - Parameters:
    ///   - dispatchData: The `DispatchData` instance to write to the `ByteBuffer`.
    /// - Returns: The number of bytes written.
    @discardableResult
    @inlinable
    public mutating func writeDispatchData(_ dispatchData: DispatchData) -> Int {
        let written = self.setDispatchData(dispatchData, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }

    /// Write `dispatchData` into this `ByteBuffer` at `index`. Does not move the writer index.
    ///
    /// - Parameters:
    ///   - dispatchData: The `DispatchData` to write.
    ///   - index: The index for the first serialized byte.
    /// - Returns: The number of bytes written.
    @discardableResult
    @inlinable
    public mutating func setDispatchData(_ dispatchData: DispatchData, at index: Int) -> Int {
        let allBytesCount = dispatchData.count
        self.reserveCapacity(index + allBytesCount)
        self.withVeryUnsafeMutableBytes { destCompleteStorage in
            assert(destCompleteStorage.count >= index + allBytesCount)
            let dest = destCompleteStorage[index..<index + allBytesCount]
            dispatchData.copyBytes(to: .init(rebasing: dest), count: dest.count)
        }
        return allBytesCount
    }

    /// Get the bytes at `index` from this `ByteBuffer` as a `DispatchData`. Does not move the reader index.
    /// The selected bytes must be readable or else `nil` will be returned.
    ///
    /// - Parameters:
    ///   - index: The starting index into `ByteBuffer` containing the string of interest.
    ///   - length: The number of bytes.
    /// - Returns: A `DispatchData` value deserialized from this `ByteBuffer` or `nil` if the requested bytes
    ///            are not readable.
    @inlinable
    public func getDispatchData(at index: Int, length: Int) -> DispatchData? {
        guard let range = self.rangeWithinReadableBytes(index: index, length: length) else {
            return nil
        }
        return self.withUnsafeReadableBytes { pointer in
            DispatchData(bytes: UnsafeRawBufferPointer(rebasing: pointer[range]))
        }
    }

    /// Read `length` bytes off this `ByteBuffer` and return them as a `DispatchData`. Move the reader index forward by `length`.
    ///
    /// - Parameters:
    ///   - length: The number of bytes.
    /// - Returns: A `DispatchData` value containing the bytes from this `ByteBuffer` or `nil` if there aren't at least `length` bytes readable.
    @inlinable
    public mutating func readDispatchData(length: Int) -> DispatchData? {
        guard let result = self.getDispatchData(at: self.readerIndex, length: length) else {
            return nil
        }
        self._moveReaderIndex(forwardBy: length)
        return result
    }

    /// Return a DispatchData object containing the bytes at the current reader index.
    ///
    /// This is equivalent to calling `getDispatchData(at: readerIndex, length: ...)` and does not advance the reader index.
    ///
    /// - Parameter length: The number of bytes to be retrieved.
    /// - Returns: A DispatchData object, or `nil` if the requested bytes are not readable.
    @inlinable
    public func peekDispatchData(length: Int) -> DispatchData? {
        self.getDispatchData(at: self.readerIndex, length: length)
    }
    #endif

    // MARK: Other APIs

    /// Yields an immutable buffer pointer containing this `ByteBuffer`'s readable bytes. Will move the reader index
    /// by the number of bytes returned by `body`.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - Parameters:
    ///   - body: The closure that will accept the yielded bytes and returns the number of bytes it processed.
    /// - Returns: The number of bytes read.
    @discardableResult
    @inlinable
    public mutating func readWithUnsafeReadableBytes<ErrorType: Error>(
        _ body: (UnsafeRawBufferPointer) throws(ErrorType) -> Int
    ) throws(ErrorType) -> Int {
        let bytesRead = try self.withUnsafeReadableBytes({ (ptr: UnsafeRawBufferPointer) throws(ErrorType) -> Int in
            try body(ptr)
        })
        self._moveReaderIndex(forwardBy: bytesRead)
        return bytesRead
    }

    /// Yields a mutable buffer pointer containing this `ByteBuffer`'s readable bytes. You may modify the yielded bytes.
    /// Will move the reader index by the number of bytes returned by `body` but leave writer index as it was.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - Parameters:
    ///   - body: The closure that will accept the yielded bytes and returns the number of bytes it processed.
    /// - Returns: The number of bytes read.
    @discardableResult
    @inlinable
    public mutating func readWithUnsafeMutableReadableBytes<ErrorType: Error>(
        _ body: (UnsafeMutableRawBufferPointer) throws(ErrorType) -> Int
    ) throws(ErrorType) -> Int {
        let bytesRead = try self.withUnsafeMutableReadableBytes({
            (ptr: UnsafeMutableRawBufferPointer) throws(ErrorType) -> Int in try body(ptr)
        })
        self._moveReaderIndex(forwardBy: bytesRead)
        return bytesRead
    }

    /// Copy `buffer`'s readable bytes into this `ByteBuffer` starting at `index`. Does not move any of the reader or writer indices.
    ///
    /// - Parameters:
    ///   - buffer: The `ByteBuffer` to copy.
    ///   - index: The index for the first byte.
    /// - Returns: The number of bytes written.
    @discardableResult
    @available(*, deprecated, renamed: "setBuffer(_:at:)")
    public mutating func set(buffer: ByteBuffer, at index: Int) -> Int {
        self.setBuffer(buffer, at: index)
    }

    /// Copy `buffer`'s readable bytes into this `ByteBuffer` starting at `index`. Does not move any of the reader or writer indices.
    ///
    /// - Parameters:
    ///   - buffer: The `ByteBuffer` to copy.
    ///   - index: The index for the first byte.
    /// - Returns: The number of bytes written.
    @discardableResult
    @inlinable
    public mutating func setBuffer(_ buffer: ByteBuffer, at index: Int) -> Int {
        buffer.withUnsafeReadableBytes { p in
            self.setBytes(p, at: index)
        }
    }

    /// Write `buffer`'s readable bytes into this `ByteBuffer` starting at `writerIndex`. This will move both this
    /// `ByteBuffer`'s writer index as well as `buffer`'s reader index by the number of bytes readable in `buffer`.
    ///
    /// - Parameters:
    ///   - buffer: The `ByteBuffer` to write.
    /// - Returns: The number of bytes written to this `ByteBuffer` which is equal to the number of bytes read from `buffer`.
    @discardableResult
    @inlinable
    public mutating func writeBuffer(_ buffer: inout ByteBuffer) -> Int {
        let written = self.setBuffer(buffer, at: writerIndex)
        self._moveWriterIndex(forwardBy: written)
        buffer._moveReaderIndex(forwardBy: written)
        return written
    }

    /// Write `bytes`, a `Sequence` of `UInt8` into this `ByteBuffer`. Moves the writer index forward by the number of bytes written.
    ///
    /// - Parameters:
    ///   - bytes: A `Collection` of `UInt8` to be written.
    /// - Returns: The number of bytes written or `bytes.count`.
    @discardableResult
    @inlinable
    public mutating func writeBytes<Bytes: Sequence>(_ bytes: Bytes) -> Int where Bytes.Element == UInt8 {
        let written = self.setBytes(bytes, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }

    /// Write `bytes` into this `ByteBuffer`. Moves the writer index forward by the number of bytes written.
    ///
    /// - Parameters:
    ///   - bytes: An `UnsafeRawBufferPointer`
    /// - Returns: The number of bytes written or `bytes.count`.
    @discardableResult
    @inlinable
    public mutating func writeBytes(_ bytes: UnsafeRawBufferPointer) -> Int {
        let written = self.setBytes(bytes, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }

    #if compiler(>=6.2)
    /// Write `bytes` into this `ByteBuffer`. Moves the writer index forward by the number of bytes written.
    ///
    /// - Parameters:
    ///   - bytes: A `RawSpan`
    /// - Returns: The number of bytes written or `bytes.byteCount`.
    @discardableResult
    @inlinable
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    public mutating func writeBytes(_ bytes: RawSpan) -> Int {
        let written = self.setBytes(bytes, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }
    #endif

    /// Writes `byte` `count` times. Moves the writer index forward by the number of bytes written.
    ///
    /// - Parameters:
    ///   - byte: The `UInt8` byte to repeat.
    ///   - count: How many times to repeat the given `byte`
    /// - Returns: How many bytes were written.
    @discardableResult
    @inlinable
    public mutating func writeRepeatingByte(_ byte: UInt8, count: Int) -> Int {
        let written = self.setRepeatingByte(byte, count: count, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }

    /// Sets the given `byte` `count` times at the given `index`. Will reserve more memory if necessary. Does not move the writer index.
    ///
    /// - Parameters:
    ///   - byte: The `UInt8` byte to repeat.
    ///   - count: How many times to repeat the given `byte`
    ///   - index: The starting index of the bytes into the `ByteBuffer`.
    /// - Returns: How many bytes were written.
    @discardableResult
    @inlinable
    public mutating func setRepeatingByte(_ byte: UInt8, count: Int, at index: Int) -> Int {
        precondition(count >= 0, "Can't write fewer than 0 bytes")
        self.reserveCapacity(index + count)
        self.withVeryUnsafeMutableBytes { pointer in
            let dest = UnsafeMutableRawBufferPointer(rebasing: pointer[index..<index + count])
            _ = dest.initializeMemory(as: UInt8.self, repeating: byte)
        }
        return count
    }

    /// Slice the readable bytes off this `ByteBuffer` without modifying the reader index. This method will return a
    /// `ByteBuffer` sharing the underlying storage with the `ByteBuffer` the method was invoked on. The returned
    /// `ByteBuffer` will contain the bytes in the range `readerIndex..<writerIndex` of the original `ByteBuffer`.
    ///
    /// - Note: Because `ByteBuffer` implements copy-on-write a copy of the storage will be automatically triggered when either of the `ByteBuffer`s sharing storage is written to.
    ///
    /// - Returns: A `ByteBuffer` sharing storage containing the readable bytes only.
    @inlinable
    public func slice() -> ByteBuffer {
        // must work, bytes definitely in the buffer// must work, bytes definitely in the buffer
        self.getSlice(at: self.readerIndex, length: self.readableBytes)!
    }

    /// Slice `length` bytes off this `ByteBuffer` and move the reader index forward by `length`.
    /// If enough bytes are readable the `ByteBuffer` returned by this method will share the underlying storage with
    /// the `ByteBuffer` the method was invoked on.
    /// The returned `ByteBuffer` will contain the bytes in the range `readerIndex..<(readerIndex + length)` of the
    /// original `ByteBuffer`.
    /// The `readerIndex` of the returned `ByteBuffer` will be `0`, the `writerIndex` will be `length`.
    ///
    /// - Note: Because `ByteBuffer` implements copy-on-write a copy of the storage will be automatically triggered when either of the `ByteBuffer`s sharing storage is written to.
    ///
    /// - Parameters:
    ///   - length: The number of bytes to slice off.
    /// - Returns: A `ByteBuffer` sharing storage containing `length` bytes or `nil` if the not enough bytes were readable.
    @inlinable
    public mutating func readSlice(length: Int) -> ByteBuffer? {
        guard let result = self.getSlice_inlineAlways(at: self.readerIndex, length: length) else {
            return nil
        }
        self._moveReaderIndex(forwardBy: length)
        return result
    }

    @discardableResult
    @inlinable
    public mutating func writeImmutableBuffer(_ buffer: ByteBuffer) -> Int {
        var mutable = buffer
        return self.writeBuffer(&mutable)
    }
}

// swift-format-ignore: AmbiguousTrailingClosureOverload
extension ByteBuffer {
    /// Yields a mutable buffer pointer containing this `ByteBuffer`'s readable bytes. You may modify the yielded bytes.
    /// Will move the reader index by the number of bytes `body` returns in the first tuple component but leave writer index as it was.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - Parameters:
    ///   - body: The closure that will accept the yielded bytes and returns the number of bytes it processed along with some other value.
    /// - Returns: The value `body` returned in the second tuple component.
    @inlinable
    public mutating func readWithUnsafeMutableReadableBytes<T, ErrorType: Error>(
        _ body: (UnsafeMutableRawBufferPointer) throws(ErrorType) -> (Int, T)
    ) throws(ErrorType) -> T {
        let (bytesRead, ret) = try self.withUnsafeMutableReadableBytes({
            (ptr: UnsafeMutableRawBufferPointer) throws(ErrorType) -> (Int, T) in try body(ptr)
        })
        self._moveReaderIndex(forwardBy: bytesRead)
        return ret
    }

    /// Yields an immutable buffer pointer containing this `ByteBuffer`'s readable bytes. Will move the reader index
    /// by the number of bytes `body` returns in the first tuple component.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - Parameters:
    ///   - body: The closure that will accept the yielded bytes and returns the number of bytes it processed along with some other value.
    /// - Returns: The value `body` returned in the second tuple component.
    @inlinable
    public mutating func readWithUnsafeReadableBytes<T, ErrorType: Error>(
        _ body: (UnsafeRawBufferPointer) throws(ErrorType) -> (Int, T)
    ) throws(ErrorType) -> T {
        let (bytesRead, ret) = try self.withUnsafeReadableBytes({
            (ptr: UnsafeRawBufferPointer) throws(ErrorType) -> (Int, T) in try body(ptr)
        })
        self._moveReaderIndex(forwardBy: bytesRead)
        return ret
    }
}

extension ByteBuffer {
    /// Return an empty `ByteBuffer` allocated with `ByteBufferAllocator()`.
    ///
    /// Calling this constructor will not allocate because it will return a `ByteBuffer` that wraps a shared storage
    /// object. As soon as you write to the constructed buffer however, you will incur an allocation because a
    /// copy-on-write will happen.
    ///
    /// - info: If you have access to a `Channel`, `ChannelHandlerContext`, or `ByteBufferAllocator` it is
    ///         recommended using `channel.allocator.buffer(capacity: 0)`. This allows SwiftNIO to do
    ///         accounting and optimisations of resources acquired for operations on a given `Channel` in the future.
    @inlinable
    public init() {
        self = ByteBufferAllocator.zeroCapacityWithDefaultAllocator
    }

    /// Create a fresh `ByteBuffer` containing the bytes of the `string` encoded as UTF-8.
    ///
    /// This will allocate a new `ByteBuffer` with enough space to fit `string` and potentially some extra space using
    /// the default allocator.
    ///
    /// - info: If you have access to a `Channel`, `ChannelHandlerContext`, or `ByteBufferAllocator` we
    ///         recommend using `channel.allocator.buffer(string:)`. Or if you want to write multiple items into the
    ///         buffer use `channel.allocator.buffer(capacity: ...)` to allocate a `ByteBuffer` of the right
    ///         size followed by a `writeString` instead of using this method. This allows SwiftNIO to do
    ///         accounting and optimisations of resources acquired for operations on a given `Channel` in the future.
    @inlinable
    public init(string: String) {
        self = ByteBufferAllocator().buffer(string: string)
    }

    /// Create a fresh `ByteBuffer` containing the bytes of the `string` encoded as UTF-8.
    ///
    /// This will allocate a new `ByteBuffer` with enough space to fit `string` and potentially some extra space using
    /// the default allocator.
    ///
    /// - info: If you have access to a `Channel`, `ChannelHandlerContext`, or `ByteBufferAllocator` we
    ///         recommend using `channel.allocator.buffer(substring:)`. Or if you want to write multiple items into
    ///         the buffer use `channel.allocator.buffer(capacity: ...)` to allocate a `ByteBuffer` of the right
    ///         size followed by a `writeSubstring` instead of using this method. This allows SwiftNIO to do
    ///         accounting and optimisations of resources acquired for operations on a given `Channel` in the future.
    @inlinable
    public init(substring string: Substring) {
        self = ByteBufferAllocator().buffer(substring: string)
    }

    /// Create a fresh `ByteBuffer` containing the bytes of the `string` encoded as UTF-8.
    ///
    /// This will allocate a new `ByteBuffer` with enough space to fit `string` and potentially some extra space using
    /// the default allocator.
    ///
    /// - info: If you have access to a `Channel`, `ChannelHandlerContext`, or `ByteBufferAllocator` we
    ///         recommend using `channel.allocator.buffer(staticString:)`. Or if you want to write multiple items into
    ///         the buffer use `channel.allocator.buffer(capacity: ...)` to allocate a `ByteBuffer` of the right
    ///         size followed by a `writeStaticString` instead of using this method. This allows SwiftNIO to do
    ///         accounting and optimisations of resources acquired for operations on a given `Channel` in the future.
    @inlinable
    public init(staticString string: StaticString) {
        self = ByteBufferAllocator().buffer(staticString: string)
    }

    /// Create a fresh `ByteBuffer` containing the `bytes`.
    ///
    /// This will allocate a new `ByteBuffer` with enough space to fit `bytes` and potentially some extra space using
    /// the default allocator.
    ///
    /// - info: If you have access to a `Channel`, `ChannelHandlerContext`, or `ByteBufferAllocator` we
    ///         recommend using `channel.allocator.buffer(bytes:)`. Or if you want to write multiple items into the
    ///         buffer use `channel.allocator.buffer(capacity: ...)` to allocate a `ByteBuffer` of the right
    ///         size followed by a `writeBytes` instead of using this method. This allows SwiftNIO to do
    ///         accounting and optimisations of resources acquired for operations on a given `Channel` in the future.
    @inlinable
    public init<Bytes: Sequence>(bytes: Bytes) where Bytes.Element == UInt8 {
        self = ByteBufferAllocator().buffer(bytes: bytes)
    }

    /// Create a fresh `ByteBuffer` containing the bytes of the byte representation in the given `endianness` of
    /// `integer`.
    ///
    /// This will allocate a new `ByteBuffer` with enough space to fit `integer` and potentially some extra space using
    /// the default allocator.
    ///
    /// - info: If you have access to a `Channel`, `ChannelHandlerContext`, or `ByteBufferAllocator` we
    ///         recommend using `channel.allocator.buffer(integer:)`. Or if you want to write multiple items into the
    ///         buffer use `channel.allocator.buffer(capacity: ...)` to allocate a `ByteBuffer` of the right
    ///         size followed by a `writeInteger` instead of using this method. This allows SwiftNIO to do
    ///         accounting and optimisations of resources acquired for operations on a given `Channel` in the future.
    @inlinable
    public init<I: FixedWidthInteger>(integer: I, endianness: Endianness = .big, as: I.Type = I.self) {
        self = ByteBufferAllocator().buffer(integer: integer, endianness: endianness, as: `as`)
    }

    /// Create a fresh `ByteBuffer` containing `count` repetitions of `byte`.
    ///
    /// This will allocate a new `ByteBuffer` with at least `count` bytes.
    ///
    /// - info: If you have access to a `Channel`, `ChannelHandlerContext`, or `ByteBufferAllocator` we
    ///         recommend using `channel.allocator.buffer(repeating:count:)`. Or if you want to write multiple items
    ///         into the buffer use `channel.allocator.buffer(capacity: ...)` to allocate a `ByteBuffer` of the right
    ///         size followed by a `writeRepeatingByte` instead of using this method. This allows SwiftNIO to do
    ///         accounting and optimisations of resources acquired for operations on a given `Channel` in the future.
    @inlinable
    public init(repeating byte: UInt8, count: Int) {
        self = ByteBufferAllocator().buffer(repeating: byte, count: count)
    }

    /// Create a fresh `ByteBuffer` containing the readable bytes of `buffer`.
    ///
    /// This may allocate a new `ByteBuffer` with enough space to fit `buffer` and potentially some extra space using
    /// the default allocator.
    ///
    /// - Note: Use this method only if you deliberately want to reallocate a potentially smaller `ByteBuffer` than the
    ///         one you already have. Given that `ByteBuffer` is a value type, defensive copies are not necessary. If
    ///         you have a `ByteBuffer` but would like the `readerIndex` to start at `0`, consider `readSlice` instead.
    ///
    /// - info: If you have access to a `Channel`, `ChannelHandlerContext`, or `ByteBufferAllocator` we
    ///         recommend using `channel.allocator.buffer(buffer:)`. Or if you want to write multiple items into the
    ///         buffer use `channel.allocator.buffer(capacity: ...)` to allocate a `ByteBuffer` of the right
    ///         size followed by a `writeImmutableBuffer` instead of using this method. This allows SwiftNIO to do
    ///         accounting and optimisations of resources acquired for operations on a given `Channel` in the future.
    @inlinable
    public init(buffer: ByteBuffer) {
        self = ByteBufferAllocator().buffer(buffer: buffer)
    }

    #if canImport(Dispatch)
    /// Create a fresh `ByteBuffer` containing the bytes contained in the given `DispatchData`.
    ///
    /// This will allocate a new `ByteBuffer` with enough space to fit the bytes of the `DispatchData` and potentially
    /// some extra space using the default allocator.
    ///
    /// - info: If you have access to a `Channel`, `ChannelHandlerContext`, or `ByteBufferAllocator` we
    ///         recommend using `channel.allocator.buffer(dispatchData:)`. Or if you want to write multiple items into
    ///         the buffer use `channel.allocator.buffer(capacity: ...)` to allocate a `ByteBuffer` of the right
    ///         size followed by a `writeDispatchData` instead of using this method. This allows SwiftNIO to do
    ///         accounting and optimisations of resources acquired for operations on a given `Channel` in the future.
    @inlinable
    public init(dispatchData: DispatchData) {
        self = ByteBufferAllocator().buffer(dispatchData: dispatchData)
    }
    #endif

    #if compiler(>=6.2)
    /// Create a fresh ``ByteBuffer`` with a minimum size, and initializing it safely via an `OutputSpan`.
    ///
    /// This will allocate a new ``ByteBuffer`` with at least `capacity` bytes of storage, and then calls
    /// `initializer` with an `OutputSpan` over the entire allocated storage. This is a convenient method
    /// to initialize a buffer directly and safely in a single allocation, including from C code.
    ///
    /// Once this call returns, the buffer will have its ``ByteBuffer/writerIndex`` appropriately advanced to encompass
    /// any memory initialized by the `initializer`. Uninitialized memory will be after the ``ByteBuffer/writerIndex``,
    /// available for subsequent use.
    ///
    /// - info: If you have access to a `Channel`, `ChannelHandlerContext`, or `ByteBufferAllocator` we
    ///         recommend using `channel.allocator.buffer(capacity:initializingWith:)`. Or if you want to write multiple items into
    ///         the buffer use `channel.allocator.buffer(capacity: ...)` to allocate a `ByteBuffer` of the right
    ///         size followed by a `write(minimumWritableBytes:initializingWith:)` instead of using this method. This allows SwiftNIO to do
    ///         accounting and optimisations of resources acquired for operations on a given `Channel` in the future.
    ///
    /// - parameters:
    ///     - capacity: The minimum initial space to allocate for the buffer.
    ///     - initializer: The initializer that will be invoked to initialize the allocated memory.
    @inlinable
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    public init<ErrorType: Error>(
        initialCapacity capacity: Int,
        initializingWith initializer: (_ span: inout OutputRawSpan) throws(ErrorType) -> Void
    ) throws(ErrorType) {
        self = try ByteBufferAllocator().buffer(capacity: capacity, initializingWith: initializer)
    }
    #endif
}

extension ByteBuffer: Codable {

    /// Creates a ByteByffer by decoding from a Base64 encoded single value container.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let base64String = try container.decode(String.self)
        self = try ByteBuffer(bytes: base64String._base64Decoded())
    }

    /// Encodes this buffer as a base64 string in a single value container.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let base64String = String(_base64Encoding: self.readableBytesView)
        try container.encode(base64String)
    }
}

extension ByteBufferAllocator {
    /// Create a fresh `ByteBuffer` containing the bytes of the `string` encoded as UTF-8.
    ///
    /// This will allocate a new `ByteBuffer` with enough space to fit `string` and potentially some extra space.
    ///
    /// - Returns: The `ByteBuffer` containing the written bytes.
    @inlinable
    public func buffer(string: String) -> ByteBuffer {
        var buffer = self.buffer(capacity: string.utf8.count)
        buffer.writeString(string)
        return buffer
    }

    /// Create a fresh `ByteBuffer` containing the bytes of the `string` encoded as UTF-8.
    ///
    /// This will allocate a new `ByteBuffer` with enough space to fit `string` and potentially some extra space.
    ///
    /// - Returns: The `ByteBuffer` containing the written bytes.
    @inlinable
    public func buffer(substring string: Substring) -> ByteBuffer {
        var buffer = self.buffer(capacity: string.utf8.count)
        buffer.writeSubstring(string)
        return buffer
    }

    /// Create a fresh `ByteBuffer` containing the bytes of the `string` encoded as UTF-8.
    ///
    /// This will allocate a new `ByteBuffer` with enough space to fit `string` and potentially some extra space.
    ///
    /// - Returns: The `ByteBuffer` containing the written bytes.
    @inlinable
    public func buffer(staticString string: StaticString) -> ByteBuffer {
        var buffer = self.buffer(capacity: string.utf8CodeUnitCount)
        buffer.writeStaticString(string)
        return buffer
    }

    /// Create a fresh `ByteBuffer` containing the `bytes`.
    ///
    /// This will allocate a new `ByteBuffer` with enough space to fit `bytes` and potentially some extra space.
    ///
    /// - Returns: The `ByteBuffer` containing the written bytes.
    @inlinable
    public func buffer<Bytes: Sequence>(bytes: Bytes) -> ByteBuffer where Bytes.Element == UInt8 {
        var buffer = self.buffer(capacity: bytes.underestimatedCount)
        buffer.writeBytes(bytes)
        return buffer
    }

    /// Create a fresh `ByteBuffer` containing the `bytes` decoded from the ASCII `plainHexEncodedBytes` string .
    ///
    /// This will allocate a new `ByteBuffer` with enough space to fit `bytes` and potentially some extra space.
    ///
    /// - Returns: The `ByteBuffer` containing the written bytes.
    @inlinable
    public func buffer(plainHexEncodedBytes string: String) throws -> ByteBuffer {
        var buffer = self.buffer(capacity: string.utf8.count / 2)
        try buffer.writePlainHexEncodedBytes(string)
        return buffer
    }

    /// Create a fresh `ByteBuffer` containing the bytes of the byte representation in the given `endianness` of
    /// `integer`.
    ///
    /// This will allocate a new `ByteBuffer` with enough space to fit `integer` and potentially some extra space.
    ///
    /// - Returns: The `ByteBuffer` containing the written bytes.
    @inlinable
    public func buffer<I: FixedWidthInteger>(
        integer: I,
        endianness: Endianness = .big,
        as: I.Type = I.self
    ) -> ByteBuffer {
        var buffer = self.buffer(capacity: MemoryLayout<I>.size)
        buffer.writeInteger(integer, endianness: endianness, as: `as`)
        return buffer
    }

    /// Create a fresh `ByteBuffer` containing `count` repetitions of `byte`.
    ///
    /// This will allocate a new `ByteBuffer` with at least `count` bytes.
    ///
    /// - Returns: The `ByteBuffer` containing the written bytes.
    @inlinable
    public func buffer(repeating byte: UInt8, count: Int) -> ByteBuffer {
        var buffer = self.buffer(capacity: count)
        buffer.writeRepeatingByte(byte, count: count)
        return buffer
    }

    /// Create a fresh `ByteBuffer` containing the readable bytes of `buffer`.
    ///
    /// This may allocate a new `ByteBuffer` with enough space to fit `buffer` and potentially some extra space.
    ///
    /// - Note: Use this method only if you deliberately want to reallocate a potentially smaller `ByteBuffer` than the
    ///         one you already have. Given that `ByteBuffer` is a value type, defensive copies are not necessary. If
    ///         you have a `ByteBuffer` but would like the `readerIndex` to start at `0`, consider `readSlice` instead.
    ///
    /// - Returns: The `ByteBuffer` containing the written bytes.
    @inlinable
    public func buffer(buffer: ByteBuffer) -> ByteBuffer {
        var newBuffer = self.buffer(capacity: buffer.readableBytes)
        newBuffer.writeImmutableBuffer(buffer)
        return newBuffer
    }

    #if canImport(Dispatch)
    /// Create a fresh `ByteBuffer` containing the bytes contained in the given `DispatchData`.
    ///
    /// This will allocate a new `ByteBuffer` with enough space to fit the bytes of the `DispatchData` and potentially
    /// some extra space.
    ///
    /// - Returns: The `ByteBuffer` containing the written bytes.
    @inlinable
    public func buffer(dispatchData: DispatchData) -> ByteBuffer {
        var buffer = self.buffer(capacity: dispatchData.count)
        buffer.writeDispatchData(dispatchData)
        return buffer
    }
    #endif

    #if compiler(>=6.2)
    /// Create a fresh ``ByteBuffer`` with a minimum size, and initializing it safely via an `OutputSpan`.
    ///
    /// This will allocate a new ``ByteBuffer`` with at least `capacity` bytes of storage, and then calls
    /// `initializer` with an `OutputSpan` over the entire allocated storage. This is a convenient method
    /// to initialize a buffer directly and safely in a single allocation, including from C code.
    ///
    /// Once this call returns, the buffer will have its ``ByteBuffer/writerIndex`` appropriately advanced to encompass
    /// any memory initialized by the `initializer`. Uninitialized memory will be after the ``ByteBuffer/writerIndex``,
    /// available for subsequent use.
    ///
    /// - parameters:
    ///     - capacity: The minimum initial space to allocate for the buffer.
    ///     - initializer: The initializer that will be invoked to initialize the allocated memory.
    @inlinable
    @available(macOS 10.14.4, iOS 12.2, watchOS 5.2, tvOS 12.2, visionOS 1.0, *)
    public func buffer<ErrorType: Error>(
        capacity: Int,
        initializingWith initializer: (_ span: inout OutputRawSpan) throws(ErrorType) -> Void
    ) throws(ErrorType) -> ByteBuffer {
        var buffer = self.buffer(capacity: capacity)
        try buffer.writeWithOutputRawSpan(minimumWritableBytes: capacity, initializingWith: initializer)
        return buffer
    }
    #endif
}

extension Optional where Wrapped == ByteBuffer {
    /// If `nil`, replace `self` with `.some(buffer)`. If non-`nil`, write `buffer`'s readable bytes into the
    /// `ByteBuffer` starting at `writerIndex`.
    ///
    ///  This method will not modify `buffer`, meaning its `readerIndex` and `writerIndex` stays intact.
    ///
    /// - Parameters:
    ///   - buffer: The `ByteBuffer` to write.
    /// - Returns: The number of bytes written to this `ByteBuffer` which is equal to the number of `readableBytes` in
    ///            `buffer`.
    @discardableResult
    @inlinable
    public mutating func setOrWriteImmutableBuffer(_ buffer: ByteBuffer) -> Int {
        var mutable = buffer
        return self.setOrWriteBuffer(&mutable)
    }

    /// If `nil`, replace `self` with `.some(buffer)`. If non-`nil`, write `buffer`'s readable bytes into the
    /// `ByteBuffer` starting at `writerIndex`.
    ///
    /// This will move both this `ByteBuffer`'s writer index as well as `buffer`'s reader index by the number of bytes
    /// readable in `buffer`.
    ///
    /// - Parameters:
    ///   - buffer: The `ByteBuffer` to write.
    /// - Returns: The number of bytes written to this `ByteBuffer` which is equal to the number of bytes read from `buffer`.
    @discardableResult
    @inlinable
    public mutating func setOrWriteBuffer(_ buffer: inout ByteBuffer) -> Int {
        if self == nil {
            let readableBytes = buffer.readableBytes
            self = buffer
            buffer.moveReaderIndex(to: buffer.writerIndex)
            return readableBytes
        } else {
            return self!.writeBuffer(&buffer)
        }
    }
}

extension ByteBuffer {
    /// Get the string at `index` from this `ByteBuffer` decoding using the UTF-8 encoding. Does not move the reader index.
    /// The selected bytes must be readable or else `nil` will be returned.
    ///
    /// This is an alternative to `ByteBuffer.getString(at:length:)` which ensures the returned string is valid UTF8. If the
    /// string is not valid UTF8 then a `ReadUTF8ValidationError` error is thrown.
    ///
    /// - Parameters:
    ///   - index: The starting index into `ByteBuffer` containing the string of interest.
    ///   - length: The number of bytes making up the string.
    /// - Returns: A `String` value containing the UTF-8 decoded selected bytes from this `ByteBuffer` or `nil` if
    ///            the requested bytes are not readable.
    @inlinable
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    public func getUTF8ValidatedString(at index: Int, length: Int) throws -> String? {
        guard let slice = self.getSlice(at: index, length: length) else {
            return nil
        }
        guard
            let string = String(
                validating: slice.readableBytesView,
                as: Unicode.UTF8.self
            )
        else {
            throw ReadUTF8ValidationError.invalidUTF8
        }
        return string
    }

    /// Read `length` bytes off this `ByteBuffer`, decoding it as `String` using the UTF-8 encoding. Move the reader index
    /// forward by `length`.
    ///
    /// This is an alternative to `ByteBuffer.readString(length:)` which ensures the returned string is valid UTF8. If the
    /// string is not valid UTF8 then a `ReadUTF8ValidationError` error is thrown and the reader index is not advanced.
    ///
    /// - Parameters:
    ///   - length: The number of bytes making up the string.
    /// - Returns: A `String` value deserialized from this `ByteBuffer` or `nil` if there aren't at least `length` bytes readable.
    @inlinable
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    public mutating func readUTF8ValidatedString(length: Int) throws -> String? {
        guard let result = try self.getUTF8ValidatedString(at: self.readerIndex, length: length) else {
            return nil
        }
        self.moveReaderIndex(forwardBy: length)
        return result
    }

    /// Errors thrown when calling `readUTF8ValidatedString` or `getUTF8ValidatedString`.
    public struct ReadUTF8ValidationError: Error, Equatable {
        private enum BaseError: Hashable {
            case invalidUTF8
        }

        private var baseError: BaseError

        /// The length of the bytes to copy was negative.
        public static let invalidUTF8: ReadUTF8ValidationError = .init(baseError: .invalidUTF8)
    }

    /// Return a UTF-8 validated String decoded from the bytes at the current reader index.
    ///
    /// This is equivalent to calling `getUTF8ValidatedString(at: readerIndex, length: ...)` and does not advance the reader index.
    ///
    /// - Parameter length: The number of bytes making up the string.
    /// - Returns: A validated String, or `nil` if the requested bytes are not readable.
    /// - Throws: `ReadUTF8ValidationError.invalidUTF8` if the bytes are not valid UTF8.
    @inlinable
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    public func peekUTF8ValidatedString(length: Int) throws -> String? {
        try self.getUTF8ValidatedString(at: self.readerIndex, length: length)
    }
}
