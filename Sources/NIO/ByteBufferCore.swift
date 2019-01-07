@inlinable func _toCapacity(_ value: Int) -> ByteBuffer._Capacity {
    return ByteBuffer._Capacity(truncatingIfNeeded: value)
}

@inlinable func _toIndex(_ value: Int) -> ByteBuffer._Index {
    return ByteBuffer._Index(truncatingIfNeeded: value)
}

public struct ByteBuffer {
    @usableFromInline
    internal var _guts: _ByteBufferGuts
    
    @usableFromInline
    internal var _readerIndex: UInt32
    
    @usableFromInline
    internal var _writerIndex: UInt32
    
    @usableFromInline
    internal var _slice: _ByteBufferSlice
    
    public init(capacity: Int) {
        self._guts = _ByteBufferGuts(.make(capacity))
        self._slice = self._guts.fullSlice
        self._readerIndex = 0
        self._writerIndex = 0
    }
}

extension ByteBuffer {
    @usableFromInline
    internal typealias _Capacity = UInt32
    
    @usableFromInline
    internal typealias _Index = UInt32
}

extension _ByteBufferGuts {
    var fullSlice: _ByteBufferSlice {
        return .init(0..<_toIndex(self._storage.capacity))
    }
}

extension ByteBuffer {
    @inline(never) @usableFromInline
    internal mutating func _slowPath_allocateNewGuts(bytesNeeded: Int) {
        if self._guts.capacity >= bytesNeeded {
            self._guts = _ByteBufferGuts(.make(self._guts.capacity))
        } else {
            self._guts = _ByteBufferGuts(.make(bytesNeeded))
        }
        self._slice = self._guts.fullSlice
    }
    
    @inline(never) @usableFromInline
    internal mutating func _slowPath_reserveMoreCapacity(_ newCapacity: Int) {
        self._guts.reserveCapacity(newCapacity)
        self._slice = self._guts.fullSlice
    }
    
    @inlinable
    internal mutating func _makeStorageUniquelyOwned(bytesAvailable: Int, at index : Int) {
        let bytesNeeded = bytesAvailable + index
        if !self._guts.isUniquelyOwned() {
            self._slowPath_allocateNewGuts(bytesNeeded: bytesNeeded)
        }
        if self._guts.capacity < bytesAvailable + index {
            self._slowPath_reserveMoreCapacity(bytesNeeded)
        }
    }
}

extension ByteBuffer {
    @inlinable
    public var capacity: Int {
        return self._guts.capacity
    }
    
    public mutating func setBytes(_ bytes: UnsafeRawBufferPointer, at indexInSlice: Int) {
        let index = Int(self._slice._begin) + indexInSlice
        self._makeStorageUniquelyOwned(bytesAvailable: bytes.count, at: index)
        self._guts.copyBytes(from: bytes, toIndex: index)
    }
}

extension ByteBuffer {
    @inlinable
    public func withVeryUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        return try self._guts._storage.withUnsafeBytes { ptr in
            try body(.init(rebasing: ptr[Int(self._slice._begin) ..< Int(self._slice.upperBound)]))
        }
    }
    
    @inlinable
    public mutating func withVeryUnsafeMutableBytes<T>(_ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
        self._makeStorageUniquelyOwned(bytesAvailable: 0, at: 0)
        return try self._guts._storage.withUnsafeMutableBytes { ptr in
            try body(.init(rebasing: ptr[Int(self._slice._begin) ..< Int(self._slice.upperBound)]))
        }
    }
    
    /// Yields a mutable buffer pointer containing this `ByteBuffer`'s readable bytes. You may modify those bytes.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the yielded bytes.
    /// - returns: The value returned by `fn`.
    @inlinable
    public mutating func withUnsafeMutableReadableBytes<T>(_ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
        self._makeStorageUniquelyOwned(bytesAvailable: 0, at: 0)
        let readerIndex = self.readerIndex
        let readableBytes = self.readableBytes
        return try self.withVeryUnsafeMutableBytes { ptr in
            try body(.init(rebasing: ptr[readerIndex ..< readerIndex + readableBytes]))
        }
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
        self._makeStorageUniquelyOwned(bytesAvailable: 0, at: 0)
        let writerIndex = self.writerIndex
        return try self.withVeryUnsafeMutableBytes { ptr in
            return try body(.init(rebasing: ptr.dropFirst(writerIndex)))
        }
    }
    
    /// Yields a buffer pointer containing this `ByteBuffer`'s readable bytes.
    ///
    /// - warning: Do not escape the pointer from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the yielded bytes.
    /// - returns: The value returned by `fn`.
    @inlinable
    public func withUnsafeReadableBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        let readerIndex = self.readerIndex
        return try self.withVeryUnsafeBytes { ptr in
            try body(.init(rebasing: ptr[readerIndex ..< readerIndex + self.readableBytes]))
        }
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
    /// - returns: The value returned by `fn`.
    @inlinable
    public func withUnsafeReadableBytesWithStorageManagement<T>(_ body: (UnsafeRawBufferPointer, Unmanaged<AnyObject>) throws -> T) rethrows -> T {
        let storageReference: Unmanaged<AnyObject> = Unmanaged.passUnretained(self._guts._storage)
        let readerIndex = self.readerIndex
        return try self.withVeryUnsafeBytes { ptr in
            try body(.init(rebasing: ptr[readerIndex ..< readerIndex + self.readableBytes]),
                     storageReference)
        }
    }
    
    /// See `withUnsafeReadableBytesWithStorageManagement` and `withVeryUnsafeBytes`.
    @inlinable
    public func withVeryUnsafeBytesWithStorageManagement<T>(_ body: (UnsafeRawBufferPointer, Unmanaged<AnyObject>) throws -> T) rethrows -> T {
        let storageReference: Unmanaged<AnyObject> = Unmanaged.passUnretained(self._guts._storage)
        return try self.withVeryUnsafeBytes { ptr in
            try body(.init(ptr), storageReference)
        }
    }
    
    @discardableResult
    @inlinable
    public mutating func writeWithUnsafeMutableBytes(_ body: (UnsafeMutableRawBufferPointer) throws -> Int) rethrows -> Int {
        let bytesWritten = try withUnsafeMutableWritableBytes(body)
        self._moveWriterIndex(to: self._writerIndex + _toIndex(bytesWritten))
        return bytesWritten
    }
}

extension ByteBuffer {
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
        self._guts.reserveCapacity(minimumCapacity)
    }
}

extension ByteBuffer {
    /// Returns a slice of size `length` bytes, starting at `index`. The `ByteBuffer` this is invoked on and the
    /// `ByteBuffer` returned will share the same underlying storage. However, the byte at `index` in this `ByteBuffer`
    /// will correspond to index `0` in the returned `ByteBuffer`.
    /// The `readerIndex` of the returned `ByteBuffer` will be `0`, the `writerIndex` will be `length`.
    ///
    /// - note: Please consider using `readSlice` which is a safer alternative that automatically maintains the
    ///         `readerIndex` and won't allow you to slice off uninitialized memory.
    /// - warning: This method allows the user to slice out any of the bytes in the `ByteBuffer`'s storage, including
    ///           _uninitialized_ ones. To use this API in a safe way the user needs to make sure all the requested
    ///           bytes have been written before and are therefore initialized. Note that bytes between (including)
    ///           `readerIndex` and (excluding) `writerIndex` are always initialized by contract and therefore must be
    ///           safe to read.
    /// - parameters:
    ///     - index: The index the requested slice starts at.
    ///     - length: The length of the requested slice.
    public func getSlice(at index: Int, length: Int) -> ByteBuffer? {
        precondition(index >= 0, "index must not be negative")
        precondition(length >= 0, "length must not be negative")
        guard index <= self.capacity - length else {
            return nil
        }
        let index = _toIndex(index)
        let length = _toCapacity(length)
        let sliceStartIndex = self._slice.lowerBound + index

        guard sliceStartIndex <= _ByteBufferSlice.maxSupportedLowerBound else {
            // the slice's begin is past the maximum supported slice begin value (16 MiB) so the only option we have
            // is copy the slice into a fresh buffer. The slice begin will then be at index 0.
            var new = self
            new._moveWriterIndex(to: sliceStartIndex + length)
            new._moveReaderIndex(to: sliceStartIndex)
            new._guts = new._guts._slowPath_allocateNewStorage(new._guts, slice: self._slice)
            return new
        }
        var new = self
        new._slice = _ByteBufferSlice(sliceStartIndex ..< self._slice.lowerBound + index+length)
        new._moveReaderIndex(to: 0)
        new._moveWriterIndex(to: length)
        return new
    }
    
    /// Set both reader index and writer index to `0`. This will reset the state of this `ByteBuffer` to the state
    /// of a freshly allocated one, if possible without allocations. This is the cheapest way to recycle a `ByteBuffer`
    /// for a new use-case.
    ///
    /// - note: This method will allocate if the underlying storage is referenced by another `ByteBuffer`. Even if an
    ///         allocation is necessary this will be cheaper as the copy of the storage is elided.
    public mutating func clear() {
        self._makeStorageUniquelyOwned(bytesAvailable: 0, at: 0)
        self._moveWriterIndex(to: 0)
        self._moveReaderIndex(to: 0)
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
        
        if self._guts.isUniquelyOwned() {
            self._guts._storage.withUnsafeBytes { src in
                self._guts.copyBytes(from: src, toIndex: 0)
            }
            let indexShift = self._readerIndex
            self._moveReaderIndex(to: 0)
            self._moveWriterIndex(to: self._writerIndex - indexShift)
        } else {
            self._makeStorageUniquelyOwned(bytesAvailable: 0, at: 0)
        }
        return true
    }
}

extension ByteBuffer {
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
        assert(newIndex >= 0 && newIndex <= _toCapacity(self._slice.count), "\(newIndex) >= 0 && \(newIndex) <= \(self._slice.count)")
        self._writerIndex = newIndex
    }
    
    @inlinable
    mutating func _moveWriterIndex(forwardBy offset: Int) {
        let newIndex = self._writerIndex + _toIndex(offset)
        self._moveWriterIndex(to: newIndex)
    }

    @inlinable
    public var writerIndex: Int {
        return Int(self._writerIndex)
    }

    @inlinable
    public var readerIndex: Int {
        return Int(self._readerIndex)
    }

    @inlinable
    public var readableBytes: Int {
        return self.writerIndex - self.readerIndex
    }
    
    /// The number of bytes writable until `ByteBuffer` will need to grow its underlying storage which will likely
    /// trigger a copy of the bytes.
    @inlinable
    public var writableBytes: Int {
        return Int(_toCapacity(self._slice.count) - self._writerIndex)
    }
}

extension ByteBuffer {
    @inlinable @discardableResult
    public mutating func set<Bytes: Sequence>(bytes: Bytes, at index: Int) -> Int where Bytes.Element == UInt8 {
        return Int(self._set(bytes: bytes, at: _toIndex(index)))
    }
}
