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

public struct ByteBufferAllocator {
    
    public init() {
        assert(MemoryLayout<ByteBuffer>.size <= 3 * MemoryLayout<Int>.size,
               "ByteBuffer has size \(MemoryLayout<ByteBuffer>.size) which is larger than the built-in storage of the existential containers.")
    }

    public func buffer(capacity: Int) -> ByteBuffer {
        return ByteBuffer(allocator: self, startingCapacity: capacity)
    }
}

private typealias Index = UInt32
private typealias Capacity = UInt32

private func toCapacity(_ value: Int) -> Capacity {
    return Capacity(truncatingIfNeeded: value)
}

private func toIndex(_ value: Int) -> Index {
    return Index(truncatingIfNeeded: value)
}

public struct ByteBuffer {
    private typealias Slice = Range<Index>
    private typealias Allocator = ByteBufferAllocator

    private var _readerIndex: Index = 0
    private var _writerIndex: Index = 0
    private var _slice: Slice
    private var _storage: _Storage

    // MARK: Internal _Storage for CoW
    private final class _Storage {
        private(set) var capacity: Capacity
        private(set) var bytes: UnsafeMutableRawPointer
        private(set) var fullSlice: Slice
        private let allocator: ByteBufferAllocator

        public init(bytesNoCopy: UnsafeMutableRawPointer, capacity: Capacity, allocator: ByteBufferAllocator) {
            self.bytes = bytesNoCopy
            self.capacity = capacity
            self.allocator = allocator
            self.fullSlice = 0..<self.capacity
        }

        deinit {
            self.deallocate()
        }

        private static func allocateAndPrepareRawMemory(bytes: Capacity) -> UnsafeMutableRawPointer {
            let bytes = Int(bytes)
            let ptr = malloc(bytes)!
            /* bind the memory so we can assume it elsewhere to be bound to UInt8 */
            ptr.bindMemory(to: UInt8.self, capacity: bytes)
            return ptr
        }

        public func duplicate(slice: Slice, capacity: Capacity) -> _Storage {
            assert(slice.count <= capacity)
            let newCapacity = capacity == 0 ? 0 : capacity.nextPowerOf2()
            let new = _Storage(bytesNoCopy: _Storage.allocateAndPrepareRawMemory(bytes: newCapacity),
                               capacity: newCapacity,
                               allocator: self.allocator)
            new.bytes.copyBytes(from: self.bytes.advanced(by: Int(slice.lowerBound)), count: slice.count)
            return new
        }
        
        public func reallocStorage(capacity: Capacity) {
            let ptr = realloc(self.bytes, Int(capacity))!
            /* bind the memory so we can assume it elsewhere to be bound to UInt8 */
            ptr.bindMemory(to: UInt8.self, capacity: Int(capacity))
            self.bytes = ptr
            self.capacity = capacity
            self.fullSlice = 0..<self.capacity
        }
        
        private func deallocate() {
            free(self.bytes)
        }

        public static func reallocated(minimumCapacity: Capacity, allocator: Allocator) -> _Storage {
            let newCapacity = minimumCapacity == 0 ? 0 : minimumCapacity.nextPowerOf2()
            // TODO: Use realloc if possible
            return _Storage(bytesNoCopy: _Storage.allocateAndPrepareRawMemory(bytes: newCapacity),
                            capacity: newCapacity,
                            allocator: allocator)
        }

        public func dumpBytes(slice: Slice) -> String {
            var desc = "["
            for i in slice.lowerBound ..< min(slice.lowerBound + 32, slice.upperBound) {
                desc += String(format: " %02x", self.bytes.advanced(by: Int(i)).assumingMemoryBound(to: UInt8.self).pointee)
            }
            desc += " ]"
            return desc
        }
    }

    private mutating func copyStorageAndRebase(capacity: Capacity, resetIndices: Bool = false) {
        let indexRebaseAmount = resetIndices ? self._readerIndex : 0
        let storageRebaseAmount = self._slice.lowerBound + indexRebaseAmount
        let newSlice = Range(storageRebaseAmount ..< min(storageRebaseAmount + toCapacity(self._slice.count), self._slice.upperBound, storageRebaseAmount + capacity))
        self._storage = self._storage.duplicate(slice: newSlice, capacity: capacity)
        self.moveReaderIndex(to: self._readerIndex - indexRebaseAmount)
        self.moveWriterIndex(to: self._writerIndex - indexRebaseAmount)
        self._slice = self._storage.fullSlice
    }

    private mutating func copyStorageAndRebase(extraCapacity: Capacity = 0, resetIndices: Bool = false) {
        self.copyStorageAndRebase(capacity: toCapacity(self._slice.count) + extraCapacity, resetIndices: resetIndices)
    }

    private mutating func ensureAvailableCapacity(_ capacity: Capacity, at index: Index) {
        assert(isKnownUniquelyReferenced(&self._storage))

        if self._slice.lowerBound + index + capacity > self._slice.upperBound {
            // double the capacity, we may want to use different strategies depending on the actual current capacity later on.
            var newCapacity = toCapacity(self.capacity)
            
            // double the capacity until the requested capacity can be full-filled
            repeat {
                newCapacity = newCapacity << 1
            } while newCapacity - index < capacity
            
            self._storage.reallocStorage(capacity: newCapacity)
            self._slice = _slice.lowerBound..<_slice.lowerBound + newCapacity
        }
    }

    // MARK: Internal API

    private mutating func moveReaderIndex(to newIndex: Index) {
        assert(newIndex >= 0 && newIndex <= writerIndex)
        self._readerIndex = newIndex
    }
    
    private mutating func moveWriterIndex(to newIndex: Index) {
        assert(newIndex >= 0 && newIndex <= toCapacity(self._slice.count))
        self._writerIndex = newIndex
    }

    private mutating func set<S: ContiguousCollection>(bytes: S, at index: Index) -> Capacity where S.Element == UInt8 {
        let newEndIndex: Index = index + toIndex(Int(bytes.count))
        if !isKnownUniquelyReferenced(&self._storage) {
            let extraCapacity = newEndIndex > self._slice.upperBound ? newEndIndex - self._slice.upperBound : 0
            self.copyStorageAndRebase(extraCapacity: extraCapacity)
        }

        self.ensureAvailableCapacity(Capacity(bytes.count), at: index)
        let base = self._storage.bytes.advanced(by: Int(self._slice.lowerBound + index)).assumingMemoryBound(to: UInt8.self)
        bytes.withUnsafeBytes { srcPtr in
            base.assign(from: srcPtr.baseAddress!.assumingMemoryBound(to: S.Element.self), count: srcPtr.count)
        }
        return toCapacity(Int(bytes.count))
    }

    private mutating func set<S: Collection>(bytes: S, at index: Index) -> Capacity where S.Element == UInt8 {
        assert(!([Array<S.Element>.self, StaticString.self, ContiguousArray<S.Element>.self, UnsafeRawBufferPointer.self, UnsafeBufferPointer<UInt8>.self].contains(where: { (t: Any.Type) -> Bool in t == type(of: bytes) })),
               "called the slower set<S: Collection> function even though \(S.self) is a ContiguousCollection")
        let newEndIndex: Index = index + toIndex(Int(bytes.count))
        if !isKnownUniquelyReferenced(&self._storage) {
            let extraCapacity = newEndIndex > self._slice.upperBound ? newEndIndex - self._slice.upperBound : 0
            self.copyStorageAndRebase(extraCapacity: extraCapacity)
        }

        self.ensureAvailableCapacity(Capacity(bytes.count), at: index)
        let base = self._storage.bytes.advanced(by: Int(self._slice.lowerBound + index)).assumingMemoryBound(to: UInt8.self)
        var idx = 0
        for b in bytes {
            base[idx] = b
            idx += 1
        }
        return toCapacity(Int(bytes.count))
    }

    // MARK: Public Core API

    fileprivate init(allocator: ByteBufferAllocator, startingCapacity: Int) {
        let startingCapacity = toCapacity(startingCapacity)
        self._storage = _Storage.reallocated(minimumCapacity: startingCapacity, allocator: allocator)
        self._slice = self._storage.fullSlice
    }

    public var writableBytes: Int { return Int(self._storage.capacity - self._writerIndex) }
    public var readableBytes: Int { return Int(self._writerIndex - self._readerIndex) }

    public var capacity: Int {
        return self._slice.count
    }

    public mutating func changeCapacity(to newCapacity: Int) {
        precondition(newCapacity >= self.writerIndex,
                     "new capacity \(newCapacity) less than the writer index (\(self.writerIndex))")

        if newCapacity == self._storage.capacity && self._slice == self._storage.fullSlice {
            return
        }

        self.copyStorageAndRebase(capacity: toCapacity(newCapacity))
    }

    private mutating func copyStorageAndRebaseIfNeeded() {
        if !isKnownUniquelyReferenced(&self._storage) {
            self.copyStorageAndRebase()
        }
    }

    public mutating func withUnsafeMutableReadableBytes<T>(_ fn: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
        self.copyStorageAndRebaseIfNeeded()
        return try fn(UnsafeMutableRawBufferPointer(start: self._storage.bytes.advanced(by: Int(self._slice.lowerBound + self._readerIndex)),
                                                    count: self.readableBytes))
    }

    @discardableResult
    public mutating func writeWithUnsafeMutableBytes(_ fn: (UnsafeMutableRawBufferPointer) throws -> Int) rethrows -> Int {
        self.copyStorageAndRebaseIfNeeded()
        let bytesWritten = try fn(UnsafeMutableRawBufferPointer(start: self._storage.bytes.advanced(by: Int(self._slice.lowerBound + self._writerIndex)),
                                                                count: self.writableBytes))
        self.moveWriterIndex(to: self._writerIndex + toIndex(bytesWritten))
        return bytesWritten
    }

    /// This vends a pointer to the storage of the `ByteBuffer`. It's marked as _very unsafe_ because it might contain
    /// uninitialised memory and it's undefined behaviour to read it. In most cases you should use `withUnsafeReadableBytes`.
    public func withVeryUnsafeBytes<T>(_ fn: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        return try fn(UnsafeRawBufferPointer(start: self._storage.bytes.advanced(by: Int(self._slice.lowerBound)),
                                             count: self._slice.count))
    }

    public func withUnsafeReadableBytes<T>(_ fn: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        return try fn(UnsafeRawBufferPointer(start: self._storage.bytes.advanced(by: Int(self._slice.lowerBound + self._readerIndex)),
                                             count: self.readableBytes))
    }

    public func withUnsafeReadableBytesWithStorageManagement<T>(_ fn: (UnsafeRawBufferPointer, Unmanaged<AnyObject>) throws -> T) rethrows -> T {
        let storageReference: Unmanaged<AnyObject> = Unmanaged.passUnretained(self._storage)
        return try fn(UnsafeRawBufferPointer(start: self._storage.bytes.advanced(by: Int(self._slice.lowerBound + self._readerIndex)),
                                             count: self.readableBytes), storageReference)
    }

    public func withVeryUnsafeBytesWithStorageManagement<T>(_ fn: (UnsafeRawBufferPointer, Unmanaged<AnyObject>) throws -> T) rethrows -> T {
        let storageReference: Unmanaged<AnyObject> = Unmanaged.passUnretained(self._storage)
        return try fn(UnsafeRawBufferPointer(start: self._storage.bytes.advanced(by: Int(self._slice.lowerBound)),
                                             count: self._slice.count), storageReference)
    }

    public func slice(at index: Int, length: Int) -> ByteBuffer? {
        precondition(index >= 0, "index must not be negative")
        precondition(length >= 0, "length must not be negative")
        guard index <= self.capacity - length else {
            return nil
        }
        let index = toIndex(index)
        let length = toCapacity(length)
        var new = self
        new._slice = self._slice.lowerBound + index ..< self._slice.lowerBound + index+length
        new.moveReaderIndex(to: 0)
        new.moveWriterIndex(to: length)
        return new
    }

    @discardableResult public mutating func discardReadBytes() -> Bool {
        guard self._readerIndex > 0 else {
            return false
        }

        if isKnownUniquelyReferenced(&self._storage) {
            self._storage.bytes.advanced(by: Int(self._slice.lowerBound))
                .copyBytes(from: self._storage.bytes.advanced(by: Int(self._slice.lowerBound + self._readerIndex)),
                           count: self.readableBytes)
            let indexShift = self._readerIndex
            self.moveReaderIndex(to: 0)
            self.moveWriterIndex(to: self._writerIndex - indexShift)
        } else {
            self.copyStorageAndRebase(extraCapacity: 0, resetIndices: true)
        }
        return true
    }


    public var readerIndex: Int {
        return Int(self._readerIndex)
    }

    public var writerIndex: Int {
        return Int(self._writerIndex)
    }
}

extension ByteBuffer: CustomStringConvertible {
    public var description: String {
        return "ByteBuffer { readerIndex: \(self.readerIndex), writerIndex: \(self.writerIndex), bytes: \(self._storage.dumpBytes(slice: self._slice)) }"
    }
}

public protocol ContiguousCollection: Collection {
    func withUnsafeBytes<R>(_ fn: (UnsafeRawBufferPointer) throws -> R) rethrows -> R
}

extension StaticString: Collection {
    public func _customIndexOfEquatableElement(_ element: UInt8) -> Int?? {
        return Int(element)
    }

    public typealias Element = UInt8
    public typealias SubSequence = ArraySlice<UInt8>

    public typealias Index = Int

    public var startIndex: Index { return 0 }
    public var endIndex: Index { return self.utf8CodeUnitCount }
    public func index(after i: Index) -> Index { return i + 1 }
    public func index(before i: Index) -> Index { return i - 1 }

    public subscript(position: Int) -> StaticString.Element {
        get {
            return self[position]
        }
    }
}

extension Array: ContiguousCollection {}
extension ContiguousArray: ContiguousCollection {}
extension StaticString: ContiguousCollection {
    public func withUnsafeBytes<R>(_ fn: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try fn(UnsafeRawBufferPointer(start: self.utf8Start, count: self.utf8CodeUnitCount))
    }
}
extension UnsafeRawBufferPointer: ContiguousCollection {
    public func withUnsafeBytes<R>(_ fn: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try fn(self)
    }
}
extension UnsafeBufferPointer: ContiguousCollection {
    public func withUnsafeBytes<R>(_ fn: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try fn(UnsafeRawBufferPointer(self))
    }
}

/* change types to the user visible `Int` */
extension ByteBuffer {
    @discardableResult
    public mutating func set<S: Collection>(bytes: S, at index: Int) -> Int where S.Element == UInt8 {
        return Int(self.set(bytes: bytes, at: toIndex(index)))
    }

    @discardableResult
    public mutating func set<S: ContiguousCollection>(bytes: S, at index: Int) -> Int where S.Element == UInt8 {
        return Int(self.set(bytes: bytes, at: toIndex(index)))
    }

    public mutating func moveReaderIndex(forwardBy offset: Int) {
        let newIndex = self._readerIndex + toIndex(offset)
        precondition(newIndex >= 0 && newIndex <= writerIndex, "new readerIndex: \(newIndex), expected: range(0, \(writerIndex))")
        self.moveReaderIndex(to: newIndex)
    }

    public mutating func moveReaderIndex(to offset: Int) {
        let newIndex = toIndex(offset)
        precondition(newIndex >= 0 && newIndex <= writerIndex, "new readerIndex: \(newIndex), expected: range(0, \(writerIndex))")
        self.moveReaderIndex(to: newIndex)
    }

    public mutating func moveWriterIndex(forwardBy offset: Int) {
        let newIndex = self._writerIndex + toIndex(offset)
        precondition(newIndex >= 0 && newIndex <= toCapacity(self._slice.count),"new writerIndex: \(newIndex), expected: range(0, \(toCapacity(self._slice.count)))")
        self.moveWriterIndex(to: newIndex)
    }

    public mutating func moveWriterIndex(to offset: Int) {
        let newIndex = toIndex(offset)
        precondition(newIndex >= 0 && newIndex <= toCapacity(self._slice.count),"new writerIndex: \(newIndex), expected: range(0, \(toCapacity(self._slice.count)))")
        self.moveWriterIndex(to: newIndex)
    }
}
