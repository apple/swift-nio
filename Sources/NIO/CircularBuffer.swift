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
    private var buffer: ContiguousArray<E?>

    /// The capacity of the underlying buffer
    private var bufferCapacity: Int

    /// The index into the buffer of the first item
    private var startIdx = 0

    /// The index into the buffer of the next free slot
    private var endIdx = 0

    /// The number of items in the ring part of this buffer
    private var ringLength = 0

    /// Allocates a buffer that can hold up to `initialRingCapacity` elements and initialise an empty ring backed by
    /// the buffer. When the ring grows to more than `initialRingCapacity` elements the buffer will be expanded.
    public init(initialRingCapacity: Int) {
        self.bufferCapacity = initialRingCapacity
        self.buffer = ContiguousArray<E?>(repeating: nil, count: Int(initialRingCapacity))
    }

    /// Append an element to the end of the ring buffer.
    ///
    /// Amortized *O(1)*
    public mutating func append(_ value: E) {
        let expandBuf: Bool = self.bufferCapacity == self.ringLength

        if expandBuf {
            var newBacking: ContiguousArray<E?> = []
            let newCapacity = Swift.max(1, 2 * self.bufferCapacity)
            newBacking.reserveCapacity(newCapacity)
            newBacking.append(contentsOf: self.buffer[self.startIdx..<self.bufferCapacity])
            if startIdx > 0 {
                newBacking.append(contentsOf: self.buffer[0..<self.startIdx])
            }
            newBacking.append(contentsOf: repeatElement(nil, count: newCapacity - newBacking.count))
            self.buffer = newBacking
            self.startIdx = 0
            self.endIdx = self.ringLength
            self.bufferCapacity = newCapacity
            precondition(self.bufferCapacity == self.buffer.count)
        }

        self.buffer[self.endIdx] = value
        self.ringLength += 1
        self.endIdx = (self.endIdx + 1) % self.bufferCapacity
    }

    /// Remove the front element of the ring buffer.
    ///
    /// *O(1)*
    public mutating func removeFirst() -> E {
        precondition(self.ringLength != 0)

        let value = self.buffer[self.startIdx]
        self.buffer[startIdx] = nil
        self.ringLength -= 1
        self.startIdx = (self.startIdx + 1) % self.bufferCapacity

        return value!
    }

    /// Return the first element of the ring.
    ///
    /// *O(1)*
    public var first: E? {
        if self.isEmpty {
            return nil
        } else {
            return self.buffer[self.startIdx]
        }
    }

    private func bufferIndex(ofIndex index: Int) -> Int {
        if index < self.ringLength {
            return (self.startIdx + index) % self.bufferCapacity
        } else {
            fatalError("index out of range")
        }
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
    public var indices: CountableRange<Int> {
        return 0..<self.ringLength
    }

    /// Returns whether the ring is empty.
    public var isEmpty: Bool {
        return self.ringLength == 0
    }

    /// Returns the number of element in the ring.
    public var count: Int {
        return self.ringLength
    }

    /// Returns the index of the first element of the ring.
    public var startIndex: Int {
        return 0
    }

    /// Returns the ring's "past the end" position -- that is, the position one greater than the last valid subscript argument.
    public var endIndex: Int {
        return self.ringLength
    }

    /// Returns the next index after `index`.
    public func index(after: Int) -> Int {
        let nextIndex = after + 1
        precondition(nextIndex <= endIndex)
        return nextIndex
    }

    // MARK: CustomStringConvertible implementation
    /// Returns a human readable description of the ring.
    public var description: String {
        var desc = "[ "
        for el in self.buffer.enumerated() {
            if el.0 == self.startIdx {
                desc += "<"
            } else if el.0 == self.endIdx {
                desc += ">"
            }
            desc += el.1.map { "\($0) " } ?? "_ "
        }
        desc += "]"
        desc += " (bufferCapacity: \(self.bufferCapacity), ringLength: \(self.ringLength))"
        return desc
    }
}
