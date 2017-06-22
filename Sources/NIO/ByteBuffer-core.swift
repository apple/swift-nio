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
//  swift-new-bytebuffer
//
//  Created by Johannes Weiß on 09/06/2017.
//  Copyright © 2017 Apple Inc. All rights reserved.
//

import Foundation

public struct ByteBufferAllocator {
    public let alignment: Int

    public init(alignTo alignment: Int = 1) {
        precondition(alignment > 0, "alignTo must be greater or equal to 1 (is \(alignment))")
        assert(MemoryLayout<ByteBuffer>.size <= 3 * MemoryLayout<Int>.size,
               "ByteBuffer has size \(MemoryLayout<ByteBuffer>.size) which is larger than the built-in storage of the existential containers.")
        self.alignment = alignment
    }

    public func buffer(capacity: Int) throws -> ByteBuffer {
        return ByteBuffer(allocator: self, startingCapacity: capacity)
    }
}

private typealias Index = UInt32
private typealias Capacity = UInt32

private func toCapacity(_ value: Int) -> Capacity {
    return Capacity(extendingOrTruncating: value)
}

private func toIndex(_ value: Int) -> Index {
    return Index(extendingOrTruncating: value)
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
        let capacity: Capacity
        let bytes: UnsafeMutableRawPointer
        let fullSlice: Slice
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

        private static func allocateAndPrepareRawMemory(bytes: Capacity, alignedTo: Int) -> UnsafeMutableRawPointer {
            let bytes = Int(bytes)
            let ptr = UnsafeMutableRawPointer.allocate(bytes: bytes, alignedTo: alignedTo)
            /* bind the memory so we can assume it elsewhere to be bound to UInt8 */
            ptr.bindMemory(to: UInt8.self, capacity: bytes)
            return ptr
        }

        public func duplicate(slice: Slice, capacity: Capacity) -> _Storage {
            assert(slice.count <= capacity)
            let newCapacity = capacity == 0 ? 0 : capacity.nextPowerOf2()
            // TODO: Use realloc if possible
            let new = _Storage(bytesNoCopy: _Storage.allocateAndPrepareRawMemory(bytes: newCapacity, alignedTo: self.allocator.alignment),
                               capacity: newCapacity,
                               allocator: self.allocator)
            new.bytes.copyBytes(from: self.bytes.advanced(by: Int(slice.lowerBound)), count: slice.count)
            return new
        }

        private func deallocate() {
            self.bytes.deallocate(bytes: Int(self.capacity), alignedTo: allocator.alignment)
        }

        public static func reallocated(minimumCapacity: Capacity, allocator: Allocator) -> _Storage {
            let newCapacity = minimumCapacity == 0 ? 0 : minimumCapacity.nextPowerOf2()
            // TODO: Use realloc if possible
            return _Storage(bytesNoCopy: _Storage.allocateAndPrepareRawMemory(bytes: newCapacity, alignedTo: allocator.alignment),
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
            self.copyStorageAndRebase(extraCapacity: self._slice.lowerBound + index + capacity - self._slice.upperBound + 1)
        }
    }

    // MARK: Internal API

    private mutating func moveReaderIndex(forwardBy offset: Index) {
        self.moveReaderIndex(to: self._readerIndex + offset)
    }

    private mutating func moveReaderIndex(to newIndex: Index) {
        assert(newIndex >= 0 && newIndex <= writerIndex)

        self._readerIndex = newIndex
    }

    private mutating func moveWriterIndex(forwardBy offset: Index) {
        self.moveWriterIndex(to: self._writerIndex + offset)
    }

    private mutating func moveWriterIndex(to newIndex: Index) {
        assert(newIndex >= 0 && newIndex <= toCapacity(self._slice.count))

        self._writerIndex = newIndex
    }

    private func data(at index: Index, length: Capacity) -> Data? {
        guard index + length <= self._slice.count else {
            return nil
        }
        let storageRef = Unmanaged.passRetained(self._storage)
        return Data(bytesNoCopy: self._storage.bytes.advanced(by: Int(self._slice.lowerBound + index)),
                    count: Int(length),
                    deallocator: .custom { _, _ in storageRef.release() })
    }

    private mutating func set(bytes: UnsafeRawBufferPointer, at index: Index) -> Capacity {
        let newEndIndex: Index = index + toIndex(bytes.count)
        if !isKnownUniquelyReferenced(&self._storage) {
            let extraCapacity = newEndIndex > self._slice.upperBound ? newEndIndex - self._slice.upperBound : 0
            self.copyStorageAndRebase(extraCapacity: extraCapacity)
        }

        self.ensureAvailableCapacity(Capacity(bytes.count), at: index)
        self._storage.bytes.advanced(by: Int(self._slice.lowerBound + index)).copyBytes(from: bytes.baseAddress!, count: bytes.count)
        return toCapacity(bytes.count)
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
        self.moveWriterIndex(forwardBy: toIndex(bytesWritten))
        return bytesWritten
    }

    public func withUnsafeBytes<T>(_ fn: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
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

    public func slice(at index: Int, length: Int) -> ByteBuffer? {
        let index = toIndex(index)
        let length = toCapacity(length)
        guard index + length <= self._slice.count else {
            return nil
        }
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

/* change types to the user visible `Int` */
extension ByteBuffer {
    public mutating func set(bytes: UnsafeRawBufferPointer, at index: Int) -> Int {
        return Int(self.set(bytes: bytes, at: toIndex(index)))
    }

    public func data(at index: Int, length: Int) -> Data? {
        return self.data(at: toIndex(index), length: toCapacity(length))
    }

    public mutating func moveReaderIndex(forwardBy offset: Int) {
        self.moveReaderIndex(forwardBy: toIndex(offset))
    }

    public mutating func moveReaderIndex(to offset: Int) {
        self.moveReaderIndex(to: toIndex(offset))
    }

    public mutating func moveWriterIndex(forwardBy offset: Int) {
        self.moveWriterIndex(forwardBy: toIndex(offset))
    }

    public mutating func moveWriterIndex(to offset: Int) {
        self.moveWriterIndex(to: toIndex(offset))
    }
}
