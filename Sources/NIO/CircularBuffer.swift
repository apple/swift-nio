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

/// AppendableCollection is a protocol partway between Collection and
/// RangeReplaceableCollection. It defines the append method that is present
/// on RangeReplaceableCollection, which makes all RangeReplaceableCollections
/// trivially able to implement this protocol.
public protocol AppendableCollection: Collection {
    mutating func append(_ newElement: Self.Iterator.Element)
}

/// An automatically expanding ring buffer implementation backed by a `ContiguousArray`. Even though this implementation
/// will automatically expand if more elements than `initialRingCapacity` are stored, it's advantageous to prevent
/// expansions from happening frequently. Expansions will always force an allocation and a copy to happen.
public struct CircularBuffer<E>: CustomStringConvertible, AppendableCollection {
    // this typealias is so complicated because of SR-6963, when that's fixed we can drop the generic parameters and the where clause
    #if swift(>=4.2)
    public typealias RangeType<Bound> = Range<Bound> where Bound: Strideable, Bound.Stride: SignedInteger
    #else
    public typealias RangeType<Bound> = CountableRange<Bound> where Bound: Strideable, Bound.Stride: SignedInteger
    #endif
    private var buffer: ContiguousArray<E?>

    /// The index into the buffer of the first item
    private(set) /* private but tests */ internal var headIdx = 0

    /// The index into the buffer of the next free slot
    private(set) /* private but tests */ internal var tailIdx = 0

    /// Bitmask used for calculating the tailIdx / headIdx based on the fact that the underlying storage
    /// has always a size of power of two.
    private var mask: Int {
        return self.buffer.count - 1
    }

    /// Allocates a buffer that can hold up to `initialRingCapacity` elements and initialise an empty ring backed by
    /// the buffer. When the ring grows to more than `initialRingCapacity` elements the buffer will be expanded.
    public init(initialRingCapacity: Int) {
        let capacity = Int(UInt32(initialRingCapacity).nextPowerOf2())
        self.buffer = ContiguousArray<E?>(repeating: nil, count: capacity)
        assert(self.buffer.count == capacity)
    }

    /// Append an element to the end of the ring buffer.
    ///
    /// Amortized *O(1)*
    public mutating func append(_ value: E) {
        self.buffer[self.tailIdx] = value
        self.tailIdx = (self.tailIdx + 1) & self.mask

        if self.headIdx == self.tailIdx {
            // No more room left for another append so grow the buffer now.
            self.doubleCapacity()
        }
    }

    /// Prepend an element to the front of the ring buffer.
    ///
    /// Amortized *O(1)*
    public mutating func prepend(_ value: E) {
        let idx = (self.headIdx - 1) & mask
        self.buffer[idx] = value
        self.headIdx = idx

        if self.headIdx == self.tailIdx {
            // No more room left for another append so grow the buffer now.
            self.doubleCapacity()
        }
    }

    /// Double the capacity of the buffer and adjust the headIdx and tailIdx.
    private mutating func doubleCapacity() {
        var newBacking: ContiguousArray<E?> = []
        let newCapacity = self.buffer.count << 1 // Double the storage.
        precondition(newCapacity > 0, "Can't double capacity of \(self.buffer.count)")
        assert(newCapacity % 2 == 0)

        newBacking.reserveCapacity(newCapacity)
        newBacking.append(contentsOf: self.buffer[self.headIdx..<self.buffer.count])
        if self.headIdx > 0 {
            newBacking.append(contentsOf: self.buffer[0..<self.headIdx])
        }
        newBacking.append(contentsOf: repeatElement(nil, count: newCapacity - newBacking.count))
        self.tailIdx = self.buffer.count
        self.headIdx = 0
        self.buffer = newBacking
    }

    /// Remove the front element of the ring buffer.
    ///
    /// *O(1)*
    public mutating func removeFirst() -> E {
        guard let value = self.buffer[self.headIdx] else {
            preconditionFailure("CircularBuffer is empty")
        }
        self.buffer[self.headIdx] = nil
        self.headIdx = (self.headIdx + 1) & self.mask

        return value
    }

    /// Return the first element of the ring.
    ///
    /// *O(1)*
    public var first: E? {
        if self.isEmpty {
            return nil
        } else {
            return self.buffer[self.headIdx]
        }
    }

    /// Remove the last element of the ring buffer.
    ///
    /// *O(1)*
    public mutating func removeLast() -> E {
        let idx = (self.tailIdx - 1) & self.mask
        guard let value = self.buffer[idx] else {
            preconditionFailure("CircularBuffer is empty")
        }
        self.buffer[idx] = nil
        self.tailIdx = idx

        return value
    }

    /// Return the last element of the ring.
    ///
    /// *O(1)*
    public var last: E? {
        if self.isEmpty {
            return nil
        } else {
            return self.buffer[(self.tailIdx - 1) & self.mask]
        }
    }

    private func bufferIndex(ofIndex index: Int) -> Int {
        precondition(index < self.count, "index out of range")
        return (self.headIdx + index) & self.mask
    }

    // MARK: Collection implementation
    /// Return element `index` of the ring.
    ///
    /// *O(1)*
    public subscript(index: Int) -> E {
        get {
            return self.buffer[self.bufferIndex(ofIndex: index)]!
        }
        set {
            self.buffer[self.bufferIndex(ofIndex: index)] = newValue
        }
    }

    /// Slice out a range of the ring.
    ///
    /// *O(1)*
    public subscript(bounds: Range<Int>) -> Slice<CircularBuffer<E>> {
        get {
            return Slice(base: self, bounds: bounds)
        }
    }

    /// Return all valid indices of the ring.
    public var indices: RangeType<Int> {
        return 0..<self.count
    }

    /// Returns whether the ring is empty.
    public var isEmpty: Bool {
        return self.headIdx == self.tailIdx
    }

    /// Returns the number of element in the ring.
    public var count: Int {
        return (self.tailIdx - self.headIdx) & self.mask
    }

    /// The total number of elements that the ring can contain without allocating new storage.
    public var capacity: Int {
        return self.buffer.count
    }

    /// Returns the index of the first element of the ring.
    public var startIndex: Int {
        return 0
    }

    /// Returns the ring's "past the end" position -- that is, the position one greater than the last valid subscript argument.
    public var endIndex: Int {
        return self.count
    }

    /// Returns the next index after `index`.
    public func index(after: Int) -> Int {
        let nextIndex = after + 1
        precondition(nextIndex <= self.endIndex)
        return nextIndex
    }

    /// Removes all members from the circular buffer whist keeping the capacity.
    public mutating func removeAll(keepingCapacity: Bool = false) {
        self.headIdx = 0
        self.tailIdx = 0
        self.buffer = ContiguousArray<E?>(repeating: nil, count: keepingCapacity ? self.buffer.count : 1)
    }

    // MARK: CustomStringConvertible implementation
    /// Returns a human readable description of the ring.
    public var description: String {
        var desc = "[ "
        for el in self.buffer.enumerated() {
            if el.0 == self.headIdx {
                desc += "<"
            } else if el.0 == self.tailIdx {
                desc += ">"
            }
            desc += el.1.map { "\($0) " } ?? "_ "
        }
        desc += "]"
        desc += " (bufferCapacity: \(self.buffer.count), ringLength: \(self.count))"
        return desc
    }
}
