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
    /// - paramaters:
    ///     - initialCapacity: The initial capacity of the internal storage.
    @inlinable
    public init(initialCapacity: Int) {
        _buffer = CircularBuffer(initialCapacity: initialCapacity)
    }

    // MARK: Forwarding

    /// Appends an entry to the buffer, expanding it if needed.
    @inlinable
    public mutating func append(_ value: Element) {
        _buffer.append(value)
    }

    /// Removes the first element from the buffer.
    @inlinable
    public mutating func removeFirst() -> Element {
        assert(_buffer.count > 0)
        return popFirst()!
    }

    @inlinable
    public mutating func popFirst() -> Element? {
        if let markedIndexOffset = _markedIndexOffset {
            if markedIndexOffset > 0 {
                _markedIndexOffset = markedIndexOffset - 1
            } else {
                _markedIndexOffset = nil
            }
        }
        return _buffer.popFirst()
    }

    /// The first element in the buffer.
    @inlinable
    public var first: Element? {
        _buffer.first
    }

    /// If the buffer is empty.
    @inlinable
    public var isEmpty: Bool {
        _buffer.isEmpty
    }

    /// The number of elements in the buffer.
    @inlinable
    public var count: Int {
        _buffer.count
    }

    @inlinable
    public var description: String {
        _buffer.description
    }

    // MARK: Marking

    /// Marks the buffer at the current index, making the last index in the buffer marked.
    @inlinable
    public mutating func mark() {
        let count = _buffer.count
        if count > 0 {
            _markedIndexOffset = count - 1
        } else {
            assert(_markedIndexOffset == nil, "marked index is \(_markedIndexOffset.debugDescription)")
        }
    }

    /// Returns true if the buffer is currently marked at the given index.
    @inlinable
    public func isMarked(index: Index) -> Bool {
        assert(index >= startIndex, "index must not be negative")
        precondition(index < endIndex, "index \(index) out of range (0..<\(_buffer.count))")
        if let markedIndexOffset = _markedIndexOffset {
            return self.index(startIndex, offsetBy: markedIndexOffset) == index
        } else {
            return false
        }
    }

    /// Returns the index of the marked element.
    @inlinable
    public var markedElementIndex: Index? {
        if let markedIndexOffset = _markedIndexOffset {
            assert(markedIndexOffset >= 0)
            return index(startIndex, offsetBy: markedIndexOffset)
        } else {
            return nil
        }
    }

    /// Returns the marked element.
    @inlinable
    public var markedElement: Element? {
        markedElementIndex.map { self._buffer[$0] }
    }

    /// Returns true if the buffer has been marked at all.
    @inlinable
    public var hasMark: Bool {
        _markedIndexOffset != nil
    }
}

extension MarkedCircularBuffer: Collection, MutableCollection {
    public typealias RangeType<Bound> = Range<Bound> where Bound: Strideable, Bound.Stride: SignedInteger
    public typealias Index = CircularBuffer<Element>.Index
    public typealias SubSequence = CircularBuffer<Element>

    @inlinable
    public func index(after i: Index) -> Index {
        _buffer.index(after: i)
    }

    @inlinable
    public var startIndex: Index { _buffer.startIndex }

    @inlinable
    public var endIndex: Index { _buffer.endIndex }

    /// Retrieves the element at the given index from the buffer, without removing it.
    @inlinable
    public subscript(index: Index) -> Element {
        get {
            _buffer[index]
        }
        set {
            _buffer[index] = newValue
        }
    }

    @inlinable
    public subscript(bounds: Range<Index>) -> SubSequence {
        _buffer[bounds]
    }
}

extension MarkedCircularBuffer: RandomAccessCollection {
    @inlinable
    public func index(_ i: Index, offsetBy distance: Int) -> Index {
        _buffer.index(i, offsetBy: distance)
    }

    @inlinable
    public func distance(from start: Index, to end: Index) -> Int {
        _buffer.distance(from: start, to: end)
    }

    @inlinable
    public func index(before i: Index) -> Index {
        _buffer.index(before: i)
    }
}
