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
public struct MarkedCircularBuffer<E>: CustomStringConvertible, AppendableCollection {
    // this typealias is so complicated because of SR-6963, when that's fixed we can drop the generic parameters and the where clause
    #if swift(>=4.2)
    public typealias RangeType<Bound> = Range<Bound> where Bound: Strideable, Bound.Stride: SignedInteger
    #else
    public typealias RangeType<Bound> = CountableRange<Bound> where Bound: Strideable, Bound.Stride: SignedInteger
    #endif

    private var buffer: CircularBuffer<E>
    private var markedIndex: Int = -1 /* negative: nothing marked */

    /// Create a new instance.
    ///
    /// - paramaters:
    ///     - initialRingCapacity: The initial capacity of the internal storage.
    public init(initialRingCapacity: Int) {
        self.buffer = CircularBuffer(initialRingCapacity: initialRingCapacity)
    }

    // MARK: Forwarding

    /// Appends an entry to the buffer, expanding it if needed.
    public mutating func append(_ value: E) {
        self.buffer.append(value)
    }

    /// Removes the first element from the buffer.
    public mutating func removeFirst() -> E {
        assert(self.buffer.count > 0)
        if self.markedIndex != -1 {
            self.markedIndex -= 1
        }
        return self.buffer.removeFirst()
    }

    /// The first element in the buffer.
    public var first: E? {
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

    /// Retrieves the element at the given index from the buffer, without removing it.
    public subscript(index: Int) -> E {
        get {
            return self.buffer[index]
        }
        set {
            self.buffer[index] = newValue
        }
    }

    /// The valid indices into the buffer.
    public var indices: RangeType<Int> {
        return self.buffer.indices
    }

    public var startIndex: Int { return self.buffer.startIndex }

    public var endIndex: Int { return self.buffer.endIndex }

    public func index(after i: Int) -> Int {
        return self.buffer.index(after: i)
    }

    public var description: String {
        return self.buffer.description
    }

    // MARK: Marking

    /// Marks the buffer at the current index, making the last index in the buffer marked.
    public mutating func mark() {
        let count = self.buffer.count
        if count > 0 {
            self.markedIndex = count - 1
        } else {
            assert(self.markedIndex == -1, "marked index is \(self.markedIndex)")
        }
    }

    /// Returns true if the buffer is currently marked at the given index.
    public func isMarked(index: Int) -> Bool {
        precondition(index >= 0, "index must not be negative")
        precondition(index < self.buffer.count, "index \(index) out of range (0..<\(self.buffer.count))")
        return self.markedIndex == index
    }

    /// Returns the index of the marked element.
    public func markedElementIndex() -> Int? {
        let markedIndex = self.markedIndex
        if markedIndex >= 0 {
            return markedIndex
        } else {
            assert(markedIndex == -1, "marked index is \(markedIndex)")
            return nil
        }
    }

    /// Returns the marked element.
    public func markedElement() -> E? {
        return self.markedElementIndex().map { self.buffer[$0] }
    }

    /// Returns tre if the buffer has been marked at all.
    public func hasMark() -> Bool {
        if self.markedIndex < 0 {
            assert(self.markedIndex == -1, "marked index is \(self.markedIndex)")
            return false
        } else {
            return true
        }
    }
}
