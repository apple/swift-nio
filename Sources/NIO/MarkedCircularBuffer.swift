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
    private var buffer: CircularBuffer<Element>
    private var markedIndexOffset: Int? = nil /* nil: nothing marked */

    /// Create a new instance.
    ///
    /// - paramaters:
    ///     - initialCapacity: The initial capacity of the internal storage.
    public init(initialCapacity: Int) {
        self.buffer = CircularBuffer(initialCapacity: initialCapacity)
    }

    // MARK: Forwarding

    /// Appends an entry to the buffer, expanding it if needed.
    public mutating func append(_ value: Element) {
        self.buffer.append(value)
    }

    /// Removes the first element from the buffer.
    public mutating func removeFirst() -> Element {
        return self.popFirst()!
    }

    public mutating func popFirst() -> Element? {
        assert(self.buffer.count > 0)
        if let markedIndexOffset = self.markedIndexOffset {
            if markedIndexOffset > 0 {
                self.markedIndexOffset = markedIndexOffset - 1
            } else {
                self.markedIndexOffset = nil
            }
        }
        return self.buffer.popFirst()
    }

    /// The first element in the buffer.
    public var first: Element? {
        return self.buffer.first
    }

    /// If the buffer is empty.
    public var isEmpty: Bool {
        return self.buffer.isEmpty
    }

    /// The number of elements in the buffer.
    public var count: Int {
        return self.buffer.count
    }

    public var description: String {
        return self.buffer.description
    }

    // MARK: Marking

    /// Marks the buffer at the current index, making the last index in the buffer marked.
    public mutating func mark() {
        let count = self.buffer.count
        if count > 0 {
            self.markedIndexOffset = count - 1
        } else {
            assert(self.markedIndexOffset == nil, "marked index is \(self.markedIndexOffset.debugDescription)")
        }
    }

    /// Returns true if the buffer is currently marked at the given index.
    public func isMarked(index: Index) -> Bool {
        assert(index >= self.startIndex, "index must not be negative")
        precondition(index < self.endIndex, "index \(index) out of range (0..<\(self.buffer.count))")
        if let markedIndexOffset = self.markedIndexOffset {
            return self.index(self.startIndex, offsetBy: markedIndexOffset) == index
        } else {
            return false
        }
    }

    /// Returns the index of the marked element.
    public var markedElementIndex: Index? {
        if let markedIndexOffset = self.markedIndexOffset {
            assert(markedIndexOffset >= 0)
            return self.index(self.startIndex, offsetBy: markedIndexOffset)
        } else {
            return nil
        }
    }

    /// Returns the marked element.
    public var markedElement: Element? {
        return self.markedElementIndex.map { self.buffer[$0] }
    }

    /// Returns true if the buffer has been marked at all.
    public var hasMark: Bool {
        return self.markedIndexOffset != nil
    }
}

extension MarkedCircularBuffer: Collection, MutableCollection {
    public typealias RangeType<Bound> = Range<Bound> where Bound: Strideable, Bound.Stride: SignedInteger
    public typealias Index = CircularBuffer<Element>.Index
    public typealias SubSequence = CircularBuffer<Element>

    public func index(after i: Index) -> Index {
        return self.buffer.index(after: i)
    }

    public var startIndex: Index { return self.buffer.startIndex }

    public var endIndex: Index { return self.buffer.endIndex }

    /// Retrieves the element at the given index from the buffer, without removing it.
    public subscript(index: Index) -> Element {
        get {
            return self.buffer[index]
        }
        set {
            self.buffer[index] = newValue
        }
    }

    public subscript(bounds: Range<Index>) -> SubSequence {
        get {
            return self.buffer[bounds]
        }
    }
}

extension MarkedCircularBuffer: RandomAccessCollection {
    public func index(_ i: Index, offsetBy distance: Int) -> Index {
        return self.buffer.index(i, offsetBy: distance)
    }

    public func distance(from start: Index, to end: Index) -> Int {
        return self.buffer.distance(from: start, to: end)
    }

    public func index(before i: Index) -> Index {
        return self.buffer.index(before: i)
    }

}
