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

#if os(Windows)
import ucrt
#endif

let sysMalloc: @convention(c) (size_t) -> UnsafeMutableRawPointer? = malloc
let sysRealloc: @convention(c) (UnsafeMutableRawPointer?, size_t) -> UnsafeMutableRawPointer? = realloc
let sysFree: @convention(c) (UnsafeMutableRawPointer?) -> Void = free

extension _ByteBufferSlice: Equatable {}

/// The slice of a `ByteBuffer`, it's different from `Range<UInt32>` because the lower bound is actually only
/// 24 bits (the upper bound is still 32). Before constructing, you need to make sure the lower bound actually
/// fits within 24 bits, otherwise the behaviour is undefined.
@usableFromInline
struct _ByteBufferSlice {
    @usableFromInline var upperBound: ByteBuffer._Index
    @usableFromInline var _begin: _UInt24
    @inlinable var lowerBound: ByteBuffer._Index {
        return UInt32(self._begin)
    }
    @inlinable var count: Int {
        return Int(self.upperBound - self.lowerBound)
    }
    init() {
        self._begin = .init(integerLiteral: 0)
        self.upperBound = .init(integerLiteral: 0)
    }
    static var maxSupportedLowerBound: ByteBuffer._Index {
        return ByteBuffer._Index(_UInt24.max)
    }
}

extension _ByteBufferSlice {
    init(_ range: Range<UInt32>) {
        self = _ByteBufferSlice()

        self._begin = _UInt24(range.lowerBound)
        self.upperBound = range.upperBound
    }
}

extension _ByteBufferSlice: CustomStringConvertible {
    @usableFromInline
    var description: String {
        return "_ByteBufferSlice { \(self.lowerBound)..<\(self.upperBound) }"
    }
}

/// The preferred allocator for `ByteBuffer` values. The allocation strategy is opaque but is currently libc's
/// `malloc`, `realloc` and `free`.
///
/// - note: `ByteBufferAllocator` is thread-safe.
public struct ByteBufferAllocator {

    /// Create a fresh `ByteBufferAllocator`. In the future the allocator might use for example allocation pools and
    /// therefore it's recommended to reuse `ByteBufferAllocators` where possible instead of creating fresh ones in
    /// many places.
    public init() {
        self.init(hookedMalloc: { sysMalloc($0) },
                  hookedRealloc: { sysRealloc($0, $1) },
                  hookedFree: { sysFree($0) },
                  hookedMemcpy: { $0.copyMemory(from: $1, byteCount: $2) })
    }

    internal init(hookedMalloc: @escaping @convention(c) (size_t) -> UnsafeMutableRawPointer?,
                  hookedRealloc: @escaping @convention(c) (UnsafeMutableRawPointer?, size_t) -> UnsafeMutableRawPointer?,
                  hookedFree: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void,
                  hookedMemcpy: @escaping @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer, size_t) -> Void) {
        self.malloc = hookedMalloc
        self.realloc = hookedRealloc
        self.free = hookedFree
        self.memcpy = hookedMemcpy
    }

    /// Request a freshly allocated `ByteBuffer` of size `capacity` or larger.
    ///
    /// - note: The passed `capacity` is the `ByteBuffer`'s initial capacity, it will grow automatically if necessary.
    ///
    /// - note: If `capacity` is `0`, this function will not allocate. If you want to trigger an allocation immediately,
    ///         also call `.clear()`.
    ///
    /// - parameters:
    ///     - capacity: The initial capacity of the returned `ByteBuffer`.
    public func buffer(capacity: Int) -> ByteBuffer {
        precondition(capacity >= 0, "ByteBuffer capacity must be positive.")
        guard capacity > 0 else {
            return ByteBufferAllocator.zeroCapacityWithDefaultAllocator
        }
        return ByteBuffer(allocator: self, startingCapacity: capacity)
    }

    @usableFromInline
    internal static let zeroCapacityWithDefaultAllocator = ByteBuffer(allocator: ByteBufferAllocator(), startingCapacity: 0)

    internal let malloc: @convention(c) (size_t) -> UnsafeMutableRawPointer?
    internal let realloc: @convention(c) (UnsafeMutableRawPointer?, size_t) -> UnsafeMutableRawPointer?
    internal let free: @convention(c) (UnsafeMutableRawPointer?) -> Void
    internal let memcpy: @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer, size_t) -> Void
}

@inlinable func _toCapacity(_ value: Int) -> ByteBuffer._Capacity {
    return ByteBuffer._Capacity(truncatingIfNeeded: value)
}

@inlinable func _toIndex(_ value: Int) -> ByteBuffer._Index {
    return ByteBuffer._Index(truncatingIfNeeded: value)
}

/// `ByteBuffer` stores contiguously allocated raw bytes. It is a random and sequential accessible sequence of zero or
/// more bytes (octets).
///
/// ### Allocation
/// Use `allocator.buffer(capacity: desiredCapacity)` to allocate a new `ByteBuffer`.
///
/// ### Supported types
/// A variety of types can be read/written from/to a `ByteBuffer`. Using Swift's `extension` mechanism you can easily
/// create `ByteBuffer` support for your own data types. Out of the box, `ByteBuffer` supports for example the following
/// types (non-exhaustive list):
///
///  - `String`/`StaticString`
///  - Swift's various (unsigned) integer types
///  - `Foundation`'s `Data`
///  - `[UInt8]` and generally any `Collection` of `UInt8`
///
/// ### Random Access
/// For every supported type `ByteBuffer` usually contains two methods for random access:
///
///  1. `get<Type>(at: Int, length: Int)` where `<type>` is for example `String`, `Data`, `Bytes` (for `[UInt8]`)
///  2. `set<Type>(at: Int)`
///
/// Example:
///
///     var buf = ...
///     buf.setString("Hello World", at: 0)
///     buf.moveWriterIndex(to: 11)
///     let helloWorld = buf.getString(at: 0, length: 11)
///
///     let written = buf.setInteger(17 as Int, at: 11)
///     buf.moveWriterIndex(forwardBy: written)
///     let seventeen: Int? = buf.getInteger(at: 11)
///
/// If needed, `ByteBuffer` will automatically resize its storage to accommodate your `set` request.
///
/// ### Sequential Access
/// `ByteBuffer` provides two properties which are indices into the `ByteBuffer` to support sequential access:
///  - `readerIndex`, the index of the next readable byte
///  - `writerIndex`, the index of the next byte to write
///
/// For every supported type `ByteBuffer` usually contains two methods for sequential access:
///
///  1. `read<Type>(length: Int)` to read `length` bytes from the current `readerIndex` (and then advance the reader
///     index by `length` bytes)
///  2. `write<Type>(Type)` to write, advancing the `writerIndex` by the appropriate amount
///
/// Example:
///
///      var buf = ...
///      buf.writeString("Hello World")
///      buf.writeInteger(17 as Int)
///      let helloWorld = buf.readString(length: 11)
///      let seventeen: Int = buf.readInteger()
///
/// ### Layout
///     +-------------------+------------------+------------------+
///     | discardable bytes |  readable bytes  |  writable bytes  |
///     |                   |     (CONTENT)    |                  |
///     +-------------------+------------------+------------------+
///     |                   |                  |                  |
///     0      <=      readerIndex   <=   writerIndex    <=    capacity
///
/// The 'discardable bytes' are usually bytes that have already been read, they can however still be accessed using
/// the random access methods. 'Readable bytes' are the bytes currently available to be read using the sequential
/// access interface (`read<Type>`/`write<Type>`). Getting `writableBytes` (bytes beyond the writer index) is undefined
/// behaviour and might yield arbitrary bytes (_not_ `0` initialised).
///
/// ### Slicing
/// `ByteBuffer` supports slicing a `ByteBuffer` without copying the underlying storage.
///
/// Example:
///
///     var buf = ...
///     let dataBytes: [UInt8] = [0xca, 0xfe, 0xba, 0xbe]
///     let dataBytesLength = UInt32(dataBytes.count)
///     buf.writeInteger(dataBytesLength) /* the header */
///     buf.writeBytes(dataBytes) /* the data */
///     let bufDataBytesOnly = buf.getSlice(at: 4, length: dataBytes.count)
///     /* `bufDataByteOnly` and `buf` will share their storage */
///
/// ### Notes
/// All `ByteBuffer` methods that don't contain the word 'unsafe' will only allow you to access the 'readable bytes'.
///
public struct ByteBuffer {
    @usableFromInline typealias Slice = _ByteBufferSlice
    @usableFromInline typealias Allocator = ByteBufferAllocator
    // these two type aliases should be made `@usableFromInline internal` for
    // the 2.0 release when we can drop Swift 4.0 & 4.1 support. The reason they
    // must be public is because Swift 4.0 and 4.1 don't support attributes for
    // typealiases and Swift 4.2 warns if those attributes aren't present and
    // the type is internal.
    public typealias _Index = UInt32
    public typealias _Capacity = UInt32

    @usableFromInline var _storage: _Storage
    @usableFromInline var _readerIndex: _Index
    @usableFromInline var _writerIndex: _Index
    @usableFromInline var _slice: Slice

    // MARK: Internal _Storage for CoW
    @usableFromInline final class _Storage {
        private(set) var capacity: _Capacity
        @usableFromInline private(set) var bytes: UnsafeMutableRawPointer
        private let allocator: ByteBufferAllocator

        public init(bytesNoCopy: UnsafeMutableRawPointer, capacity: _Capacity, allocator: ByteBufferAllocator) {
            self.bytes = bytesNoCopy
            self.capacity = capacity
            self.allocator = allocator
        }

        deinit {
            self.deallocate()
        }

        internal var fullSlice: _ByteBufferSlice {
            return _ByteBufferSlice(0..<self.capacity)
        }

        private static func allocateAndPrepareRawMemory(bytes: _Capacity, allocator: Allocator) -> UnsafeMutableRawPointer {
            let ptr = allocator.malloc(size_t(bytes))!
            /* bind the memory so we can assume it elsewhere to be bound to UInt8 */
            ptr.bindMemory(to: UInt8.self, capacity: Int(bytes))
            return ptr
        }

        public func allocateStorage() -> _Storage {
            return self.allocateStorage(capacity: self.capacity)
        }

        fileprivate func allocateStorage(capacity: _Capacity) -> _Storage {
            let newCapacity = capacity == 0 ? 0 : capacity.nextPowerOf2ClampedToMax()
            return _Storage(bytesNoCopy: _Storage.allocateAndPrepareRawMemory(bytes: newCapacity, allocator: self.allocator),
                            capacity: newCapacity,
                            allocator: self.allocator)
        }

        public func reallocSlice(_ slice: Range<ByteBuffer._Index>, capacity: _Capacity) -> _Storage {
            assert(slice.count <= capacity)
            let new = self.allocateStorage(capacity: capacity)
            self.allocator.memcpy(new.bytes, self.bytes.advanced(by: Int(slice.lowerBound)), size_t(slice.count))
            return new
        }

        public func reallocStorage(capacity minimumNeededCapacity: _Capacity) {
            let newCapacity = minimumNeededCapacity.nextPowerOf2ClampedToMax()
            let ptr = self.allocator.realloc(self.bytes, size_t(newCapacity))!
            /* bind the memory so we can assume it elsewhere to be bound to UInt8 */
            ptr.bindMemory(to: UInt8.self, capacity: Int(newCapacity))
            self.bytes = ptr
            self.capacity = newCapacity
        }

        private func deallocate() {
            self.allocator.free(self.bytes)
        }

        public static func reallocated(minimumCapacity: _Capacity, allocator: Allocator) -> _Storage {
            let newCapacity = minimumCapacity == 0 ? 0 : minimumCapacity.nextPowerOf2ClampedToMax()
            // TODO: Use realloc if possible
            return _Storage(bytesNoCopy: _Storage.allocateAndPrepareRawMemory(bytes: newCapacity, allocator: allocator),
                            capacity: newCapacity,
                            allocator: allocator)
        }

        public func dumpBytes(slice: Slice, offset: Int, length: Int) -> String {
            var desc = "["
            let bytes = UnsafeRawBufferPointer(start: self.bytes, count: Int(self.capacity))
            for byte in bytes[Int(slice.lowerBound) + offset ..< Int(slice.lowerBound) + offset + length] {
                let hexByte = String(byte, radix: 16)
                desc += " \(hexByte.count == 1 ? "0" : "")\(hexByte)"
            }
            desc += " ]"
            return desc
        }
    }

    @usableFromInline mutating func _copyStorageAndRebase(capacity: _Capacity, resetIndices: Bool = false) {
        let indexRebaseAmount = resetIndices ? self._readerIndex : 0
        let storageRebaseAmount = self._slice.lowerBound + indexRebaseAmount
        let newSlice = storageRebaseAmount ..< min(storageRebaseAmount + _toCapacity(self._slice.count), self._slice.upperBound, storageRebaseAmount + capacity)
        self._storage = self._storage.reallocSlice(newSlice, capacity: capacity)
        self._moveReaderIndex(to: self._readerIndex - indexRebaseAmount)
        self._moveWriterIndex(to: self._writerIndex - indexRebaseAmount)
        self._slice = self._storage.fullSlice
    }

    @usableFromInline mutating func _copyStorageAndRebase(extraCapacity: _Capacity = 0, resetIndices: Bool = false) {
        self._copyStorageAndRebase(capacity: _toCapacity(self._slice.count) + extraCapacity, resetIndices: resetIndices)
    }

    @usableFromInline mutating func _ensureAvailableCapacity(_ capacity: _Capacity, at index: _Index) {
        assert(isKnownUniquelyReferenced(&self._storage))

        let totalNeededCapacityWhenKeepingSlice = self._slice.lowerBound + index + capacity
        if totalNeededCapacityWhenKeepingSlice > self._slice.upperBound {
            // we need to at least adjust the slice's upper bound which we can do as we're the unique owner of the storage,
            // let's see if adjusting the slice's upper bound buys us enough storage
            if totalNeededCapacityWhenKeepingSlice > self._storage.capacity {
                let newStorageMinCapacity = index + capacity
                // nope, we need to actually re-allocate again. If our slice does not start at 0, let's also rebase
                if self._slice.lowerBound == 0 {
                    self._storage.reallocStorage(capacity: newStorageMinCapacity)
                } else {
                    self._storage = self._storage.reallocSlice(self._slice.lowerBound ..< self._slice.upperBound,
                                                               capacity: newStorageMinCapacity)
                }
                self._slice = self._storage.fullSlice
            } else {
                // yes, let's just extend the slice until the end of the buffer
                self._slice = _ByteBufferSlice(_slice.lowerBound ..< self._storage.capacity)
            }
        }
        assert(self._slice.lowerBound + index + capacity <= self._slice.upperBound)
        assert(self._slice.lowerBound >= 0, "illegal slice: negative lower bound: \(self._slice.lowerBound)")
        assert(self._slice.upperBound <= self._storage.capacity, "illegal slice: upper bound (\(self._slice.upperBound)) exceeds capacity: \(self._storage.capacity)")
    }

    // MARK: Internal API

    @inlinable
    mutating func _moveReaderIndex(to newIndex: _Index) {
        assert(newIndex >= 0 && newIndex <= writerIndex)
        self._readerIndex = newIndex
    }

    @inlinable
    mutating func _moveReaderIndex(forwardBy offset: Int) {
        let newIndex = self._readerIndex + _toIndex(offset)
        self._moveReaderIndex(to: newIndex)
    }

    @inlinable
    mutating func _moveWriterIndex(to newIndex: _Index) {
        assert(newIndex >= 0 && newIndex <= _toCapacity(self._slice.count))
        self._writerIndex = newIndex
    }

    @inlinable
    mutating func _moveWriterIndex(forwardBy offset: Int) {
        let newIndex = self._writerIndex + _toIndex(offset)
        self._moveWriterIndex(to: newIndex)
    }

    @inlinable
    mutating func _setBytes(_ bytes: UnsafeRawBufferPointer, at index: _Index) -> _Capacity {
        let bytesCount = bytes.count
        let newEndIndex: _Index = index + _toIndex(bytesCount)
        if !isKnownUniquelyReferenced(&self._storage) {
            let extraCapacity = newEndIndex > self._slice.upperBound ? newEndIndex - self._slice.upperBound : 0
            self._copyStorageAndRebase(extraCapacity: extraCapacity)
        }
        self._ensureAvailableCapacity(_Capacity(bytesCount), at: index)
        self._setBytesAssumingUniqueBufferAccess(bytes, at: index)
        return _toCapacity(bytesCount)
    }

    @inlinable
    mutating func _setBytesAssumingUniqueBufferAccess(_ bytes: UnsafeRawBufferPointer, at index: _Index) {
        let targetPtr = UnsafeMutableRawBufferPointer(fastRebase: self._slicedStorageBuffer.dropFirst(Int(index)))
        targetPtr.copyMemory(from: bytes)
    }

    @inline(never)
    @inlinable
    @_specialize(where Bytes == CircularBuffer<UInt8>)
    mutating func _setSlowPath<Bytes: Sequence>(bytes: Bytes, at index: _Index) -> _Capacity where Bytes.Element == UInt8 {
        func ensureCapacityAndReturnStorageBase(capacity: Int) -> UnsafeMutablePointer<UInt8> {
            self._ensureAvailableCapacity(_Capacity(capacity), at: index)
            let newBytesPtr = UnsafeMutableRawBufferPointer(fastRebase: self._slicedStorageBuffer[Int(index) ..< Int(index) + Int(capacity)])
            return newBytesPtr.bindMemory(to: UInt8.self).baseAddress!
        }
        let underestimatedByteCount = bytes.underestimatedCount
        let newPastEndIndex: _Index = index + _toIndex(underestimatedByteCount)
        if !isKnownUniquelyReferenced(&self._storage) {
            let extraCapacity = newPastEndIndex > self._slice.upperBound ? newPastEndIndex - self._slice.upperBound : 0
            self._copyStorageAndRebase(extraCapacity: extraCapacity)
        }

        var base = ensureCapacityAndReturnStorageBase(capacity: underestimatedByteCount)
        var (iterator, idx) = UnsafeMutableBufferPointer(start: base, count: underestimatedByteCount).initialize(from: bytes)
        assert(idx == underestimatedByteCount)
        while let b = iterator.next() {
            base = ensureCapacityAndReturnStorageBase(capacity: idx + 1)
            base[idx] = b
            idx += 1
        }
        return _toCapacity(idx)
    }

    @inlinable
    mutating func _setBytes<Bytes: Sequence>(_ bytes: Bytes, at index: _Index) -> _Capacity where Bytes.Element == UInt8 {
        if let written = bytes.withContiguousStorageIfAvailable({ bytes in
            self._setBytes(UnsafeRawBufferPointer(bytes), at: index)
        }) {
            // fast path, we've got access to the contiguous bytes
            return written
        } else {
            return self._setSlowPath(bytes: bytes, at: index)
        }
    }

    // MARK: Public Core API

    fileprivate init(allocator: ByteBufferAllocator, startingCapacity: Int) {
        let startingCapacity = _toCapacity(startingCapacity)
        self._readerIndex = 0
        self._writerIndex = 0
        self._storage = _Storage.reallocated(minimumCapacity: startingCapacity, allocator: allocator)
        self._slice = self._storage.fullSlice
    }

    /// The number of bytes writable until `ByteBuffer` will need to grow its underlying storage which will likely
    /// trigger a copy of the bytes.
    @inlinable public var writableBytes: Int { return Int(_toCapacity(self._slice.count) - self._writerIndex) }

    /// The number of bytes readable (`readableBytes` = `writerIndex` - `readerIndex`).
    @inlinable public var readableBytes: Int { return Int(self._writerIndex - self._readerIndex) }

    /// The current capacity of the storage of this `ByteBuffer`, this is not constant and does _not_ signify the number
    /// of bytes that have been written to this `ByteBuffer`.
    public var capacity: Int {
        return self._slice.count
    }

    /// The current capacity of the underlying storage of this `ByteBuffer`.
    /// A COW slice of the buffer (e.g. readSlice(length: x)) will posses the same storageCapacity as the original
    /// buffer until new data is written.
    public var storageCapacity: Int {
        return self._storage.fullSlice.count
    }

    /// Reserves enough space to store the specified number of bytes.
    ///
    /// This method will ensure that the buffer has space for at least as many bytes as requested.
    /// This includes any bytes already stored, and completely disregards the reader/writer indices.
    /// If the buffer already has space to store the requested number of bytes, this method will be
    /// a no-op.
    ///
    /// - parameters:
    ///     - minimumCapacity: The minimum number of bytes this buffer must be able to store.
    public mutating func reserveCapacity(_ minimumCapacity: Int) {
        guard minimumCapacity > self.capacity else {
            return
        }
        let targetCapacity = _toCapacity(minimumCapacity)

        if isKnownUniquelyReferenced(&self._storage) {
            // We have the unique reference. If we have the full slice, we can realloc. Otherwise
            // we have to copy memory anyway.
            self._ensureAvailableCapacity(targetCapacity, at: 0)
        } else {
            // We don't have a unique reference here, so we need to allocate and copy, no
            // optimisations available.
            self._copyStorageAndRebase(capacity: targetCapacity)
        }
    }

    /// Reserves enough space to write at least the specified number of bytes.
    ///
    /// This method will ensure that the buffer has enough writable space for at least as many bytes
    /// as requested. If the buffer already has space to write the requested number of bytes, this
    /// method will be a no-op.
    ///
    /// - Parameter minimumWritableBytes: The minimum number of writable bytes this buffer must have.
    public mutating func reserveCapacity(minimumWritableBytes: Int) {
        return self.reserveCapacity(self.writerIndex + minimumWritableBytes)
    }

    @usableFromInline
    mutating func _copyStorageAndRebaseIfNeeded() {
        if !isKnownUniquelyReferenced(&self._storage) {
            self._copyStorageAndRebase()
        }
    }

    @inlinable
    var _slicedStorageBuffer: UnsafeMutableRawBufferPointer {
        return UnsafeMutableRawBufferPointer(start: self._storage.bytes.advanced(by: Int(self._slice.lowerBound)),
                                             count: self._slice.count)
    }

    /// Yields a mutable buffer pointer containing this `ByteBuffer`'s readable bytes. You may modify those bytes.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the yielded bytes.
    /// - returns: The value returned by `body`.
    @inlinable
    public mutating func withUnsafeMutableReadableBytes<T>(_ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
        self._copyStorageAndRebaseIfNeeded()
        let readerIndex = self.readerIndex
        return try body(.init(fastRebase: self._slicedStorageBuffer[readerIndex ..< readerIndex + self.readableBytes]))
    }

    /// Yields the bytes currently writable (`bytesWritable` = `capacity` - `writerIndex`). Before reading those bytes you must first
    /// write to them otherwise you will trigger undefined behaviour. The writer index will remain unchanged.
    ///
    /// - note: In almost all cases you should use `writeWithUnsafeMutableBytes` which will move the write pointer instead of this method
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the yielded bytes and return the number of bytes written.
    /// - returns: The number of bytes written.
    @inlinable
    public mutating func withUnsafeMutableWritableBytes<T>(_ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
        self._copyStorageAndRebaseIfNeeded()
        return try body(.init(fastRebase: self._slicedStorageBuffer.dropFirst(self.writerIndex)))
    }

    /// This vends a pointer of the `ByteBuffer` at the `writerIndex` after ensuring that the buffer has at least `minimumWritableBytes` of writable bytes available.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - parameters:
    ///     - minimumWritableBytes: The number of writable bytes to reserve capacity for before vending the `ByteBuffer` pointer to `body`.
    ///     - body: The closure that will accept the yielded bytes and return the number of bytes written.
    /// - returns: The number of bytes written.
    @discardableResult
    @inlinable
    public mutating func writeWithUnsafeMutableBytes(minimumWritableBytes: Int, _ body: (UnsafeMutableRawBufferPointer) throws -> Int) rethrows -> Int {
        if minimumWritableBytes > 0 {
            self.reserveCapacity(minimumWritableBytes: minimumWritableBytes)
        }
        let bytesWritten = try self.withUnsafeMutableWritableBytes({ try body($0) })
        self._moveWriterIndex(to: self._writerIndex + _toIndex(bytesWritten))
        return bytesWritten
    }

    @available(*, deprecated, message: "please use writeWithUnsafeMutableBytes(minimumWritableBytes:_:) instead to ensure sufficient write capacity.")
    @discardableResult
    @inlinable
    public mutating func writeWithUnsafeMutableBytes(_ body: (UnsafeMutableRawBufferPointer) throws -> Int) rethrows -> Int {
        return try self.writeWithUnsafeMutableBytes(minimumWritableBytes: 0, { try body($0) })
    }

    /// This vends a pointer to the storage of the `ByteBuffer`. It's marked as _very unsafe_ because it might contain
    /// uninitialised memory and it's undefined behaviour to read it. In most cases you should use `withUnsafeReadableBytes`.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    @inlinable
    public func withVeryUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        return try body(.init(self._slicedStorageBuffer))
    }

    /// This vends a pointer to the storage of the `ByteBuffer`. It's marked as _very unsafe_ because it might contain
    /// uninitialised memory and it's undefined behaviour to read it. In most cases you should use `withUnsafeMutableWritableBytes`.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    @inlinable
    public mutating func withVeryUnsafeMutableBytes<T>(_ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
        self._copyStorageAndRebaseIfNeeded() // this will trigger a CoW if necessary
        return try body(.init(self._slicedStorageBuffer))
    }

    /// Yields a buffer pointer containing this `ByteBuffer`'s readable bytes.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the yielded bytes.
    /// - returns: The value returned by `body`.
    @inlinable
    public func withUnsafeReadableBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        let readerIndex = self.readerIndex
        return try body(.init(fastRebase: self._slicedStorageBuffer[readerIndex ..< readerIndex + self.readableBytes]))
    }

    /// Yields a buffer pointer containing this `ByteBuffer`'s readable bytes. You may hold a pointer to those bytes
    /// even after the closure returned iff you model the lifetime of those bytes correctly using the `Unmanaged`
    /// instance. If you don't require the pointer after the closure returns, use `withUnsafeReadableBytes`.
    ///
    /// If you escape the pointer from the closure, you _must_ call `storageManagement.retain()` to get ownership to
    /// the bytes and you also must call `storageManagement.release()` if you no longer require those bytes. Calls to
    /// `retain` and `release` must be balanced.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the yielded bytes and the `storageManagement`.
    /// - returns: The value returned by `body`.
    @inlinable
    public func withUnsafeReadableBytesWithStorageManagement<T>(_ body: (UnsafeRawBufferPointer, Unmanaged<AnyObject>) throws -> T) rethrows -> T {
        let storageReference: Unmanaged<AnyObject> = Unmanaged.passUnretained(self._storage)
        let readerIndex = self.readerIndex
        return try body(.init(fastRebase: self._slicedStorageBuffer[readerIndex ..< readerIndex + self.readableBytes]),
                        storageReference)
    }

    /// See `withUnsafeReadableBytesWithStorageManagement` and `withVeryUnsafeBytes`.
    @inlinable
    public func withVeryUnsafeBytesWithStorageManagement<T>(_ body: (UnsafeRawBufferPointer, Unmanaged<AnyObject>) throws -> T) rethrows -> T {
        let storageReference: Unmanaged<AnyObject> = Unmanaged.passUnretained(self._storage)
        return try body(.init(self._slicedStorageBuffer), storageReference)
    }

    /// Returns a slice of size `length` bytes, starting at `index`. The `ByteBuffer` this is invoked on and the
    /// `ByteBuffer` returned will share the same underlying storage. However, the byte at `index` in this `ByteBuffer`
    /// will correspond to index `0` in the returned `ByteBuffer`.
    /// The `readerIndex` of the returned `ByteBuffer` will be `0`, the `writerIndex` will be `length`.
    ///
    /// The selected bytes must be readable or else `nil` will be returned.
    ///
    /// - parameters:
    ///     - index: The index the requested slice starts at.
    ///     - length: The length of the requested slice.
    /// - returns: A `ByteBuffer` containing the selected bytes as readable bytes or `nil` if the selected bytes were
    ///            not readable in the initial `ByteBuffer`.
    public func getSlice(at index: Int, length: Int) -> ByteBuffer? {
        guard index >= 0 && length >= 0 && index >= self.readerIndex && index <= self.writerIndex - length else {
            return nil
        }
        let index = _toIndex(index)
        let length = _toCapacity(length)
        let sliceStartIndex = self._slice.lowerBound + index

        guard sliceStartIndex <= ByteBuffer.Slice.maxSupportedLowerBound else {
            // the slice's begin is past the maximum supported slice begin value (16 MiB) so the only option we have
            // is copy the slice into a fresh buffer. The slice begin will then be at index 0.
            var new = self
            new._moveWriterIndex(to: sliceStartIndex + length)
            new._moveReaderIndex(to: sliceStartIndex)
            new._copyStorageAndRebase(capacity: length, resetIndices: true)
            return new
        }
        var new = self
        new._slice = _ByteBufferSlice(sliceStartIndex ..< self._slice.lowerBound + index+length)
        new._moveReaderIndex(to: 0)
        new._moveWriterIndex(to: length)
        return new
    }

    /// Discard the bytes before the reader index. The byte at index `readerIndex` before calling this method will be
    /// at index `0` after the call returns.
    ///
    /// - returns: `true` if one or more bytes have been discarded, `false` if there are no bytes to discard.
    @discardableResult public mutating func discardReadBytes() -> Bool {
        guard self._readerIndex > 0 else {
            return false
        }

        if self._readerIndex == self._writerIndex {
            // If the whole buffer was consumed we can just reset the readerIndex and writerIndex to 0 and move on.
            self._moveWriterIndex(to: 0)
            self._moveReaderIndex(to: 0)
            return true
        }

        if isKnownUniquelyReferenced(&self._storage) {
            self._storage.bytes.advanced(by: Int(self._slice.lowerBound))
                .copyMemory(from: self._storage.bytes.advanced(by: Int(self._slice.lowerBound + self._readerIndex)),
                            byteCount: self.readableBytes)
            let indexShift = self._readerIndex
            self._moveReaderIndex(to: 0)
            self._moveWriterIndex(to: self._writerIndex - indexShift)
        } else {
            self._copyStorageAndRebase(extraCapacity: 0, resetIndices: true)
        }
        return true
    }

    /// The reader index or the number of bytes previously read from this `ByteBuffer`. `readerIndex` is `0` for a
    /// newly allocated `ByteBuffer`.
    @inlinable
    public var readerIndex: Int {
        return Int(self._readerIndex)
    }

    /// The write index or the number of bytes previously written to this `ByteBuffer`. `writerIndex` is `0` for a
    /// newly allocated `ByteBuffer`.
    @inlinable
    public var writerIndex: Int {
        return Int(self._writerIndex)
    }

    /// Set both reader index and writer index to `0`. This will reset the state of this `ByteBuffer` to the state
    /// of a freshly allocated one, if possible without allocations. This is the cheapest way to recycle a `ByteBuffer`
    /// for a new use-case.
    ///
    /// - note: This method will allocate if the underlying storage is referenced by another `ByteBuffer`. Even if an
    ///         allocation is necessary this will be cheaper as the copy of the storage is elided.
    public mutating func clear() {
        if !isKnownUniquelyReferenced(&self._storage) {
            self._storage = self._storage.allocateStorage()
        }
        self._slice = self._storage.fullSlice
        self._moveWriterIndex(to: 0)
        self._moveReaderIndex(to: 0)
    }

    /// Set both reader index and writer index to `0`. This will reset the state of this `ByteBuffer` to the state
    /// of a freshly allocated one, if possible without allocations. This is the cheapest way to recycle a `ByteBuffer`
    /// for a new use-case.
    ///
    /// - note: This method will allocate if the underlying storage is referenced by another `ByteBuffer`. Even if an
    ///         allocation is necessary this will be cheaper as the copy of the storage is elided.
    ///
    /// - parameters:
    ///     - minimumCapacity: The minimum capacity that will be (re)allocated for this buffer
    @available(*, deprecated, message: "Use an `Int` as the argument")
    public mutating func clear(minimumCapacity: UInt32) {
        self.clear(minimumCapacity: Int(minimumCapacity))
    }
    
    /// Set both reader index and writer index to `0`. This will reset the state of this `ByteBuffer` to the state
    /// of a freshly allocated one, if possible without allocations. This is the cheapest way to recycle a `ByteBuffer`
    /// for a new use-case.
    ///
    /// - note: This method will allocate if the underlying storage is referenced by another `ByteBuffer`. Even if an
    ///         allocation is necessary this will be cheaper as the copy of the storage is elided.
    ///
    /// - parameters:
    ///     - minimumCapacity: The minimum capacity that will be (re)allocated for this buffer
    public mutating func clear(minimumCapacity: Int) {
        precondition(minimumCapacity >= 0, "Cannot have a minimum capacity < 0")
        precondition(minimumCapacity <= _Capacity.max, "Minimum capacity must be <= \(_Capacity.max)")
        
        let minimumCapacity = _Capacity(minimumCapacity)
        if !isKnownUniquelyReferenced(&self._storage) {
            self._storage = self._storage.allocateStorage(capacity: minimumCapacity)
        } else if minimumCapacity > self._storage.capacity {
            self._storage.reallocStorage(capacity: minimumCapacity)
        }
        self._slice = self._storage.fullSlice

        self._moveWriterIndex(to: 0)
        self._moveReaderIndex(to: 0)
    }
}

extension ByteBuffer: CustomStringConvertible {
    /// A `String` describing this `ByteBuffer`. Example:
    ///
    ///     ByteBuffer { readerIndex: 0, writerIndex: 4, readableBytes: 4, capacity: 512, storageCapacity: 1024, slice: 256..<768, storage: 0x0000000103001000 (1024 bytes)}
    ///
    /// The format of the description is not API.
    ///
    /// - returns: A description of this `ByteBuffer`.
    public var description: String {
        return """
        ByteBuffer { \
        readerIndex: \(self.readerIndex), \
        writerIndex: \(self.writerIndex), \
        readableBytes: \(self.readableBytes), \
        capacity: \(self.capacity), \
        storageCapacity: \(self.storageCapacity), \
        slice: \(self._slice), \
        storage: \(self._storage.bytes) (\(self._storage.capacity) bytes) \
        }
        """
    }

    /// A `String` describing this `ByteBuffer` with some portion of the readable bytes dumped too. Example:
    ///
    ///     ByteBuffer { readerIndex: 0, writerIndex: 4, readableBytes: 4, capacity: 512, slice: 256..<768, storage: 0x0000000103001000 (1024 bytes)}
    ///     readable bytes (max 1k): [ 00 01 02 03 ]
    ///
    /// The format of the description is not API.
    ///
    /// - returns: A description of this `ByteBuffer` useful for debugging.
    public var debugDescription: String {
        return "\(self.description)\nreadable bytes (max 1k): \(self._storage.dumpBytes(slice: self._slice, offset: self.readerIndex, length: min(1024, self.readableBytes)))"
    }
}

/* change types to the user visible `Int` */
extension ByteBuffer {
    /// Copy the collection of `bytes` into the `ByteBuffer` at `index`. Does not move the writer index.
    @discardableResult
    @inlinable
    public mutating func setBytes<Bytes: Sequence>(_ bytes: Bytes, at index: Int) -> Int where Bytes.Element == UInt8 {
        return Int(self._setBytes(bytes, at: _toIndex(index)))
    }

    /// Copy `bytes` into the `ByteBuffer` at `index`. Does not move the writer index.
    @discardableResult
    @inlinable
    public mutating func setBytes(_ bytes: UnsafeRawBufferPointer, at index: Int) -> Int {
        return Int(self._setBytes(bytes, at: _toIndex(index)))
    }

    /// Move the reader index forward by `offset` bytes.
    ///
    /// - warning: By contract the bytes between (including) `readerIndex` and (excluding) `writerIndex` must be
    ///            initialised, ie. have been written before. Also the `readerIndex` must always be less than or equal
    ///            to the `writerIndex`. Failing to meet either of these requirements leads to undefined behaviour.
    /// - parameters:
    ///   - offset: The number of bytes to move the reader index forward by.
    public mutating func moveReaderIndex(forwardBy offset: Int) {
        let newIndex = self._readerIndex + _toIndex(offset)
        precondition(newIndex >= 0 && newIndex <= writerIndex, "new readerIndex: \(newIndex), expected: range(0, \(writerIndex))")
        self._moveReaderIndex(to: newIndex)
    }

    /// Set the reader index to `offset`.
    ///
    /// - warning: By contract the bytes between (including) `readerIndex` and (excluding) `writerIndex` must be
    ///            initialised, ie. have been written before. Also the `readerIndex` must always be less than or equal
    ///            to the `writerIndex`. Failing to meet either of these requirements leads to undefined behaviour.
    /// - parameters:
    ///   - offset: The offset in bytes to set the reader index to.
    public mutating func moveReaderIndex(to offset: Int) {
        let newIndex = _toIndex(offset)
        precondition(newIndex >= 0 && newIndex <= writerIndex, "new readerIndex: \(newIndex), expected: range(0, \(writerIndex))")
        self._moveReaderIndex(to: newIndex)
    }

    /// Move the writer index forward by `offset` bytes.
    ///
    /// - warning: By contract the bytes between (including) `readerIndex` and (excluding) `writerIndex` must be
    ///            initialised, ie. have been written before. Also the `readerIndex` must always be less than or equal
    ///            to the `writerIndex`. Failing to meet either of these requirements leads to undefined behaviour.
    /// - parameters:
    ///   - offset: The number of bytes to move the writer index forward by.
    public mutating func moveWriterIndex(forwardBy offset: Int) {
        let newIndex = self._writerIndex + _toIndex(offset)
        precondition(newIndex >= 0 && newIndex <= _toCapacity(self._slice.count),"new writerIndex: \(newIndex), expected: range(0, \(_toCapacity(self._slice.count)))")
        self._moveWriterIndex(to: newIndex)
    }

    /// Set the writer index to `offset`.
    ///
    /// - warning: By contract the bytes between (including) `readerIndex` and (excluding) `writerIndex` must be
    ///            initialised, ie. have been written before. Also the `readerIndex` must always be less than or equal
    ///            to the `writerIndex`. Failing to meet either of these requirements leads to undefined behaviour.
    /// - parameters:
    ///   - offset: The offset in bytes to set the reader index to.
    public mutating func moveWriterIndex(to offset: Int) {
        let newIndex = _toIndex(offset)
        precondition(newIndex >= 0 && newIndex <= _toCapacity(self._slice.count),"new writerIndex: \(newIndex), expected: range(0, \(_toCapacity(self._slice.count)))")
        self._moveWriterIndex(to: newIndex)
    }
}

extension ByteBuffer {
    /// Copies `length` `bytes` starting at the `fromIndex` to `toIndex`. Does not move the writer index.
    ///
    /// - Note: Overlapping ranges, for example `copyBytes(at: 1, to: 2, length: 5)` are allowed.
    /// - Precondition: The range represented by `fromIndex` and `length` must be readable bytes,
    ///     that is: `fromIndex >= readerIndex` and `fromIndex + length <= writerIndex`.
    /// - Parameter fromIndex: The index of the first byte to copy.
    /// - Parameter toIndex: The index into to which the first byte will be copied.
    /// - Parameter length: The number of bytes which should be copied.
    @discardableResult
    @inlinable
    public mutating func copyBytes(at fromIndex: Int, to toIndex: Int, length: Int) throws -> Int {
        switch length {
        case ..<0:
            throw CopyBytesError.negativeLength
        case 0:
            return 0
        default:
            ()
        }
        guard self.readerIndex <= fromIndex && fromIndex + length <= self.writerIndex else {
            throw CopyBytesError.unreadableSourceBytes
        }

        if !isKnownUniquelyReferenced(&self._storage) {
            let newEndIndex = max(self._writerIndex, _toIndex(toIndex + length))
            self._copyStorageAndRebase(capacity: newEndIndex)
        }

        self._ensureAvailableCapacity(_Capacity(length), at: _toIndex(toIndex))
        self.withVeryUnsafeBytes { ptr in
            let srcPtr = UnsafeRawBufferPointer(start: ptr.baseAddress!.advanced(by: fromIndex), count: length)
            self._setBytesAssumingUniqueBufferAccess(srcPtr, at: _toIndex(toIndex))
        }

        return length
    }

    /// Errors thrown when calling `copyBytes`.
    public struct CopyBytesError: Error {
        private enum BaseError: Hashable {
            case negativeLength
            case unreadableSourceBytes
        }

        private var baseError: BaseError

        /// The length of the bytes to copy was negative.
        public static let negativeLength: CopyBytesError = .init(baseError: .negativeLength)

        /// The bytes to copy are not readable.
        public static let unreadableSourceBytes: CopyBytesError = .init(baseError: .unreadableSourceBytes)
    }
}

extension ByteBuffer.CopyBytesError: Hashable { }

extension ByteBuffer.CopyBytesError: CustomDebugStringConvertible {
    public var debugDescription: String {
        return String(describing: self.baseError)
    }
}

extension ByteBuffer: Equatable {
    // TODO: I don't think this makes sense. This should compare bytes 0..<writerIndex instead.

    /// Compare two `ByteBuffer` values. Two `ByteBuffer` values are considered equal if the readable bytes are equal.
    public static func ==(lhs: ByteBuffer, rhs: ByteBuffer) -> Bool {
        guard lhs.readableBytes == rhs.readableBytes else {
            return false
        }

        if lhs._slice == rhs._slice && lhs._storage === rhs._storage {
            return true
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

extension ByteBuffer: Hashable {
    /// The hash value for the readable bytes.
    public func hash(into hasher: inout Hasher) {
        self.withUnsafeReadableBytes { ptr in
            hasher.combine(bytes: ptr)
        }
    }
}

extension ByteBuffer {
    /// Modify this `ByteBuffer` if this `ByteBuffer` is known to uniquely own its storage.
    ///
    /// In some cases it is possible that code is holding a `ByteBuffer` that has been shared with other
    /// parts of the code, and may want to mutate that `ByteBuffer`. In some cases it may be worth modifying
    /// a `ByteBuffer` only if that `ByteBuffer` is guaranteed to not perform a copy-on-write operation to do
    /// so, for example when a different buffer could be used or more cheaply allocated instead.
    ///
    /// This function will execute the provided block only if it is guaranteed to be able to avoid a copy-on-write
    /// operation. If it cannot execute the block the returned value will be `nil`.
    ///
    /// - parameters:
    ///     - body: The modification operation to execute, with this `ByteBuffer` passed `inout` as an argument.
    /// - returns: The return value of `body`.
    @inlinable
    public mutating func modifyIfUniquelyOwned<T>(_ body: (inout ByteBuffer) throws -> T) rethrows -> T? {
        if isKnownUniquelyReferenced(&self._storage) {
            return try body(&self)
        } else {
            return nil
        }
    }
}

extension ByteBuffer {
    @inlinable
    func rangeWithinReadableBytes(index: Int, length: Int) -> Range<Int>? {
        let indexFromReaderIndex = index - self.readerIndex
        guard indexFromReaderIndex >= 0 && length >= 0 && indexFromReaderIndex <= self.readableBytes - length else {
            return nil
        }
        return indexFromReaderIndex ..< (indexFromReaderIndex+length)
    }
}
