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

/// A circular buffer that allows one object at a time to be "marked" and easily identified and retrieved later.
///
/// This object is used extensively within SwiftNIO to handle flushable buffers. It can be used to store buffered
/// writes and mark how far through the buffer the user has flushed, and therefore how far through the buffer is
/// safe to write.
public struct MarkedCircularBuffer<Element>: CustomStringConvertible {
    @usableFromInline internal var _buffer: CircularBuffer<Element>
    @usableFromInline internal var _markedIndexOffset: Int? /* nil: nothing marked */

    /// Create a new instance.
    ///
    /// - parameters:
    ///     - initialCapacity: The initial capacity of the internal storage.
    @inlinable
    public init(initialCapacity: Int) {
        self._buffer = CircularBuffer(initialCapacity: initialCapacity)
    }

    // MARK: Forwarding

    /// Appends an entry to the buffer, expanding it if needed.
    @inlinable
    public mutating func append(_ value: Element) {
        self._buffer.append(value)
    }

    /// Removes the first element from the buffer.
    @inlinable
    public mutating func removeFirst() -> Element {
        assert(self._buffer.count > 0)
        return self.popFirst()!
    }

    @inlinable
    public mutating func popFirst() -> Element? {
        if let markedIndexOffset = self._markedIndexOffset {
            if markedIndexOffset > 0 {
                self._markedIndexOffset = markedIndexOffset - 1
            } else {
                self._markedIndexOffset = nil
            }
        }
        return self._buffer.popFirst()
    }

    /// The first element in the buffer.
    @inlinable
    public var first: Element? {
        return self._buffer.first
    }

    /// If the buffer is empty.
    @inlinable
    public var isEmpty: Bool {
        return self._buffer.isEmpty
    }

    /// The number of elements in the buffer.
    @inlinable
    public var count: Int {
        return self._buffer.count
    }

    @inlinable
    public var description: String {
        return self._buffer.description
    }

    // MARK: Marking

    /// Marks the buffer at the current index, making the last index in the buffer marked.
    @inlinable
    public mutating func mark() {
        let count = self._buffer.count
        if count > 0 {
            self._markedIndexOffset = count - 1
        } else {
            assert(self._markedIndexOffset == nil, "marked index is \(self._markedIndexOffset.debugDescription)")
        }
    }

    /// Returns true if the buffer is currently marked at the given index.
    @inlinable
    public func isMarked(index: Index) -> Bool {
        assert(index >= self.startIndex, "index must not be negative")
        precondition(index < self.endIndex, "index \(index) out of range (0..<\(self._buffer.count))")
        if let markedIndexOffset = self._markedIndexOffset {
            return self.index(self.startIndex, offsetBy: markedIndexOffset) == index
        } else {
            return false
        }
    }

    /// Returns the index of the marked element.
    @inlinable
    public var markedElementIndex: Index? {
        if let markedIndexOffset = self._markedIndexOffset {
            assert(markedIndexOffset >= 0)
            return self.index(self.startIndex, offsetBy: markedIndexOffset)
        } else {
            return nil
        }
    }

    /// Returns the marked element.
    @inlinable
    public var markedElement: Element? {
        return self.markedElementIndex.map { self._buffer[$0] }
    }

    /// Returns true if the buffer has been marked at all.
    @inlinable
    public var hasMark: Bool {
        return self._markedIndexOffset != nil
    }
}

extension MarkedCircularBuffer: Collection, MutableCollection {
    public typealias RangeType<Bound> = Range<Bound> where Bound: Strideable, Bound.Stride: SignedInteger
    public typealias Index = CircularBuffer<Element>.Index
    public typealias SubSequence = CircularBuffer<Element>

    @inlinable
    public func index(after i: Index) -> Index {
        return self._buffer.index(after: i)
    }

    @inlinable
    public var startIndex: Index { return self._buffer.startIndex }

    @inlinable
    public var endIndex: Index { return self._buffer.endIndex }

    /// Retrieves the element at the given index from the buffer, without removing it.
    @inlinable
    public subscript(index: Index) -> Element {
        get {
            return self._buffer[index]
        }
        set {
            self._buffer[index] = newValue
        }
    }

    @inlinable
    public subscript(bounds: Range<Index>) -> SubSequence {
        get {
            return self._buffer[bounds]
        }
        set {
            var index = bounds.lowerBound
            var iterator = newValue.makeIterator()
            while let newElement = iterator.next(), index != bounds.upperBound {
                self._buffer[index] = newElement
                formIndex(after: &index)
            }
            precondition(iterator.next() == nil && index == bounds.upperBound)
        }
    }
}

extension MarkedCircularBuffer: RandomAccessCollection {
    @inlinable
    public func index(_ i: Index, offsetBy distance: Int) -> Index {
        return self._buffer.index(i, offsetBy: distance)
    }

    @inlinable
    public func distance(from start: Index, to end: Index) -> Int {
        return self._buffer.distance(from: start, to: end)
    }

    @inlinable
    public func index(before i: Index) -> Index {
        return self._buffer.index(before: i)
    }

}
