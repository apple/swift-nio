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
    @inlinable
    public func getBytes(at index: Int, length: Int) -> [UInt8]? {
        guard let range = self.rangeWithinReadableBytes(index: index, length: length) else {
            return nil
        }

        return self.withUnsafeReadableBytes { ptr in
            // this is not technically correct because we shouldn't just bind
            // the memory to `UInt8` but it's not a real issue either and we
            // need to work around https://bugs.swift.org/browse/SR-9604
            Array<UInt8>(UnsafeRawBufferPointer(fastRebase: ptr[range]).bindMemory(to: UInt8.self))
        }
    }

    /// Read `length` bytes off this `ByteBuffer`, move the reader index forward by `length` bytes and return the result
    /// as `[UInt8]`.
    ///
    /// - parameters:
    ///     - length: The number of bytes to be read from this `ByteBuffer`.
    /// - returns: A `[UInt8]` value containing `length` bytes or `nil` if there aren't at least `length` bytes readable.
    @inlinable
    public mutating func readBytes(length: Int) -> [UInt8]? {
        guard let result = self.getBytes(at: self.readerIndex, length: length) else {
            return nil
        }
        self._moveReaderIndex(forwardBy: length)
        return result
    }

    // MARK: StaticString APIs

    /// Write the static `string` into this `ByteBuffer` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - string: The string to write.
    /// - returns: The number of bytes written.
    @discardableResult
    @inlinable
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
    @inlinable
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
    @inlinable
    public mutating func writeString(_ string: String) -> Int {
        let written = self.setString(string, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }
    
    /// Write `string` into this `ByteBuffer` null terminated using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - string: The string to write.
    /// - returns: The number of bytes written.
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
    /// - parameters:
    ///     - string: The string to write.
    ///     - index: The index for the first serialized byte.
    /// - returns: The number of bytes written.
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
    /// - parameters:
    ///     - string: The string to write.
    ///     - index: The index for the first serialized byte.
    /// - returns: The number of bytes written.
    @inlinable
    public mutating func setNullTerminatedString(_ string: String, at index: Int) -> Int {
        let length = self.setString(string, at: index)
        self.setInteger(UInt8(0), at: index &+ length)
        return length &+ 1
    }

    /// Get the string at `index` from this `ByteBuffer` decoding using the UTF-8 encoding. Does not move the reader index.
    /// The selected bytes must be readable or else `nil` will be returned.
    ///
    /// - parameters:
    ///     - index: The starting index into `ByteBuffer` containing the string of interest.
    ///     - length: The number of bytes making up the string.
    /// - returns: A `String` value containing the UTF-8 decoded selected bytes from this `ByteBuffer` or `nil` if
    ///            the requested bytes are not readable.
    @inlinable
    public func getString(at index: Int, length: Int) -> String? {
        guard let range = self.rangeWithinReadableBytes(index: index, length: length) else {
            return nil
        }
        return self.withUnsafeReadableBytes { pointer in
            assert(range.lowerBound >= 0 && (range.upperBound - range.lowerBound) <= pointer.count)
            return String(decoding: UnsafeRawBufferPointer(fastRebase: pointer[range]), as: Unicode.UTF8.self)
        }
    }
    
    /// Get the string at `index` from this `ByteBuffer` decoding using the UTF-8 encoding. Does not move the reader index.
    /// The selected bytes must be readable or else `nil` will be returned.
    ///
    /// - parameters:
    ///     - index: The starting index into `ByteBuffer` containing the null terminated string of interest.
    /// - returns: A `String` value deserialized from this `ByteBuffer` or `nil` if there isn't a complete null-terminated string,
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
    /// - parameters:
    ///     - length: The number of bytes making up the string.
    /// - returns: A `String` value deserialized from this `ByteBuffer` or `nil` if there aren't at least `length` bytes readable.
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
    /// - returns: A `String` value deserialized from this `ByteBuffer` or `nil` if there isn't a complete null-terminated string,
    ///            including null-terminator, in the readable bytes of the buffer
    @inlinable
    public mutating func readNullTerminatedString() -> String? {
        guard let stringLength = self._getNullTerminatedStringLength(at: self.readerIndex) else {
            return nil
        }
        let result = self.readString(length: stringLength)
        self.moveReaderIndex(forwardBy: 1) // move forward by null terminator
        return result
    }

    // MARK: Substring APIs
    /// Write `substring` into this `ByteBuffer` using UTF-8 encoding, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - substring: The substring to write.
    /// - returns: The number of bytes written.
    @discardableResult
    @inlinable
    public mutating func writeSubstring(_ substring: Substring) -> Int {
        let written = self.setSubstring(substring, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }
    
    /// Write `substring` into this `ByteBuffer` at `index` using UTF-8 encoding. Does not move the writer index.
    ///
    /// - parameters:
    ///     - substring: The substring to write.
    ///     - index: The index for the first serialized byte.
    /// - returns: The number of bytes written
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
    
    // MARK: DispatchData APIs
    /// Write `dispatchData` into this `ByteBuffer`, moving the writer index forward appropriately.
    ///
    /// - parameters:
    ///     - dispatchData: The `DispatchData` instance to write to the `ByteBuffer`.
    /// - returns: The number of bytes written.
    @discardableResult
    @inlinable
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
    @inlinable
    public mutating func setDispatchData(_ dispatchData: DispatchData, at index: Int) -> Int {
        let allBytesCount = dispatchData.count
        self.reserveCapacity(index + allBytesCount)
        self.withVeryUnsafeMutableBytes { destCompleteStorage in
            assert(destCompleteStorage.count >= index + allBytesCount)
            let dest = destCompleteStorage[index ..< index + allBytesCount]
            dispatchData.copyBytes(to: .init(fastRebase: dest), count: dest.count)
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
    @inlinable
    public func getDispatchData(at index: Int, length: Int) -> DispatchData? {
        guard let range = self.rangeWithinReadableBytes(index: index, length: length) else {
            return nil
        }
        return self.withUnsafeReadableBytes { pointer in
            return DispatchData(bytes: UnsafeRawBufferPointer(fastRebase: pointer[range]))
        }
    }

    /// Read `length` bytes off this `ByteBuffer` and return them as a `DispatchData`. Move the reader index forward by `length`.
    ///
    /// - parameters:
    ///     - length: The number of bytes.
    /// - returns: A `DispatchData` value containing the bytes from this `ByteBuffer` or `nil` if there aren't at least `length` bytes readable.
    @inlinable
    public mutating func readDispatchData(length: Int) -> DispatchData? {
        guard let result = self.getDispatchData(at: self.readerIndex, length: length) else {
            return nil
        }
        self._moveReaderIndex(forwardBy: length)
        return result
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
    @inlinable
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
    @inlinable
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
    
    /// Writes `byte` `count` times. Moves the writer index forward by the number of bytes written.
    ///
    /// - parameter byte: The `UInt8` byte to repeat.
    /// - parameter count: How many times to repeat the given `byte`
    /// - returns: How many bytes were written.
    @discardableResult
    @inlinable
    public mutating func writeRepeatingByte(_ byte: UInt8, count: Int) -> Int {
        let written = self.setRepeatingByte(byte, count: count, at: self.writerIndex)
        self._moveWriterIndex(forwardBy: written)
        return written
    }
    
    /// Sets the given `byte` `count` times at the given `index`. Will reserve more memory if necessary. Does not move the writer index.
    ///
    /// - parameter byte: The `UInt8` byte to repeat.
    /// - parameter count: How many times to repeat the given `byte`
    /// - returns: How many bytes were written.
    @discardableResult
    @inlinable
    public mutating func setRepeatingByte(_ byte: UInt8, count: Int, at index: Int) -> Int {
        precondition(count >= 0, "Can't write fewer than 0 bytes")
        self.reserveCapacity(index + count)
        self.withVeryUnsafeMutableBytes { pointer in
            let dest = UnsafeMutableRawBufferPointer(fastRebase: pointer[index ..< index+count])
            _ = dest.initializeMemory(as: UInt8.self, repeating: byte)
        }
        return count
    }

    /// Slice the readable bytes off this `ByteBuffer` without modifying the reader index. This method will return a
    /// `ByteBuffer` sharing the underlying storage with the `ByteBuffer` the method was invoked on. The returned
    /// `ByteBuffer` will contain the bytes in the range `readerIndex..<writerIndex` of the original `ByteBuffer`.
    ///
    /// - note: Because `ByteBuffer` implements copy-on-write a copy of the storage will be automatically triggered when either of the `ByteBuffer`s sharing storage is written to.
    ///
    /// - returns: A `ByteBuffer` sharing storage containing the readable bytes only.
    @inlinable
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
    /// - note: Use this method only if you deliberately want to reallocate a potentially smaller `ByteBuffer` than the
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
}

extension ByteBufferAllocator {
    /// Create a fresh `ByteBuffer` containing the bytes of the `string` encoded as UTF-8.
    ///
    /// This will allocate a new `ByteBuffer` with enough space to fit `string` and potentially some extra space.
    ///
    /// - returns: The `ByteBuffer` containing the written bytes.
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
    /// - returns: The `ByteBuffer` containing the written bytes.
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
    /// - returns: The `ByteBuffer` containing the written bytes.
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
    /// - returns: The `ByteBuffer` containing the written bytes.
    @inlinable
    public func buffer<Bytes: Sequence>(bytes: Bytes) -> ByteBuffer where Bytes.Element == UInt8 {
        var buffer = self.buffer(capacity: bytes.underestimatedCount)
        buffer.writeBytes(bytes)
        return buffer
    }

    /// Create a fresh `ByteBuffer` containing the bytes of the byte representation in the given `endianness` of
    /// `integer`.
    ///
    /// This will allocate a new `ByteBuffer` with enough space to fit `integer` and potentially some extra space.
    ///
    /// - returns: The `ByteBuffer` containing the written bytes.
    @inlinable
    public func buffer<I: FixedWidthInteger>(integer: I,
                                             endianness: Endianness = .big,
                                             as: I.Type = I.self) -> ByteBuffer {
        var buffer = self.buffer(capacity: MemoryLayout<I>.size)
        buffer.writeInteger(integer, endianness: endianness, as: `as`)
        return buffer
    }

    /// Create a fresh `ByteBuffer` containing `count` repetitions of `byte`.
    ///
    /// This will allocate a new `ByteBuffer` with at least `count` bytes.
    ///
    /// - returns: The `ByteBuffer` containing the written bytes.
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
    /// - note: Use this method only if you deliberately want to reallocate a potentially smaller `ByteBuffer` than the
    ///         one you already have. Given that `ByteBuffer` is a value type, defensive copies are not necessary. If
    ///         you have a `ByteBuffer` but would like the `readerIndex` to start at `0`, consider `readSlice` instead.
    ///
    /// - returns: The `ByteBuffer` containing the written bytes.
    @inlinable
    public func buffer(buffer: ByteBuffer) -> ByteBuffer {
        var newBuffer = self.buffer(capacity: buffer.readableBytes)
        newBuffer.writeImmutableBuffer(buffer)
        return newBuffer
    }

    /// Create a fresh `ByteBuffer` containing the bytes contained in the given `DispatchData`.
    ///
    /// This will allocate a new `ByteBuffer` with enough space to fit the bytes of the `DispatchData` and potentially
    /// some extra space.
    ///
    /// - returns: The `ByteBuffer` containing the written bytes.
    @inlinable
    public func buffer(dispatchData: DispatchData) -> ByteBuffer {
        var buffer = self.buffer(capacity: dispatchData.count)
        buffer.writeDispatchData(dispatchData)
        return buffer
    }
}


extension Optional where Wrapped == ByteBuffer {
    /// If `nil`, replace `self` with `.some(buffer)`. If non-`nil`, write `buffer`'s readable bytes into the
    /// `ByteBuffer` starting at `writerIndex`.
    ///
    ///  This method will not modify `buffer`, meaning its `readerIndex` and `writerIndex` stays intact.
    ///
    /// - parameters:
    ///     - buffer: The `ByteBuffer` to write.
    /// - returns: The number of bytes written to this `ByteBuffer` which is equal to the number of `readableBytes` in
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
    /// - parameters:
    ///     - buffer: The `ByteBuffer` to write.
    /// - returns: The number of bytes written to this `ByteBuffer` which is equal to the number of bytes read from `buffer`.
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
