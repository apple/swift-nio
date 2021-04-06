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

/// An automatically expanding ring buffer implementation backed by a `Deque` (from Swift Collections).
///
/// Even though this implementation
/// will automatically expand if more elements than `initialCapacity` are stored, it's advantageous to prevent
/// expansions from happening frequently. Expansions will always force an allocation and a copy to happen.
public struct CircularBuffer<Element>: CustomStringConvertible {
    @usableFromInline
    internal var _buffer: NIODeque<Element>

    /// An opaque `CircularBuffer` index.
    ///
    /// You may get indices offset from other indices by using `CircularBuffer.index(:offsetBy:)`,
    /// `CircularBuffer.index(before:)`, or `CircularBuffer.index(after:)`.
    ///
    /// - note: Every index is invalidated as soon as you perform a length-changing operating on the `CircularBuffer`
    ///         but remains valid when you replace one item by another using the subscript.
    public struct Index: Comparable {
        @usableFromInline var index: NIODeque<Element>.Index

        @inlinable
        init(_ index: NIODeque<Element>.Index) {
            self.index = index
        }

        @inlinable
        public static func == (lhs: Index, rhs: Index) -> Bool {
            return lhs.index == rhs.index
        }

        @inlinable
        public static func < (lhs: Index, rhs: Index) -> Bool {
            return lhs.index < rhs.index
        }
    }
}

// MARK: Collection/MutableCollection implementation
extension CircularBuffer: Collection, MutableCollection {
    public typealias Element = Element
    public typealias Indices = DefaultIndices<CircularBuffer<Element>>
    public typealias RangeType<Bound> = Range<Bound> where Bound: Strideable, Bound.Stride: SignedInteger
    public typealias SubSequence = CircularBuffer<Element>

    /// Returns the position immediately after the given index.
    ///
    /// The successor of an index must be well defined. For an index `i` into a
    /// collection `c`, calling `c.index(after: i)` returns the same index every
    /// time.
    ///
    /// - Parameter i: A valid index of the collection. `i` must be less than
    ///   `endIndex`.
    /// - Returns: The index value immediately after `i`.
    @inlinable
    public func index(after: Index) -> Index {
        return self.index(after, offsetBy: 1)
    }

    /// Returns the index before `index`.
    @inlinable
    public func index(before: Index) -> Index {
        return self.index(before, offsetBy: -1)
    }

    /// Accesses the element at the specified index.
    ///
    /// You can subscript `CircularBuffer` with any valid index other than the
    /// `CircularBuffer`'s end index. The end index refers to the position one
    /// past the last element of a collection, so it doesn't correspond with an
    /// element.
    ///
    /// - Parameter position: The position of the element to access. `position`
    ///   must be a valid index of the collection that is not equal to the
    ///   `endIndex` property.
    ///
    /// - Complexity: O(1)
    @inlinable
    public subscript(position: Index) -> Element {
        get {
            return self._buffer[position.index]
        }
        set {
            self._buffer[position.index] = newValue
        }
    }

    /// The position of the first element in a nonempty `CircularBuffer`.
    ///
    /// If the `CircularBuffer` is empty, `startIndex` is equal to `endIndex`.
    @inlinable
    public var startIndex: Index {
        return Index(self._buffer.startIndex)
    }

    /// The `CircularBuffer`'s "past the end" position---that is, the position one
    /// greater than the last valid subscript argument.
    ///
    /// When you need a range that includes the last element of a collection, use
    /// the half-open range operator (`..<`) with `endIndex`. The `..<` operator
    /// creates a range that doesn't include the upper bound, so it's always
    /// safe to use with `endIndex`.
    ///
    /// If the `CircularBuffer` is empty, `endIndex` is equal to `startIndex`.
    @inlinable
    public var endIndex: Index {
        return Index(self._buffer.endIndex)
    }

    /// Returns the distance between two indices.
    ///
    /// Unless the collection conforms to the `BidirectionalCollection` protocol,
    /// `start` must be less than or equal to `end`.
    ///
    /// - Parameters:
    ///   - start: A valid index of the collection.
    ///   - end: Another valid index of the collection. If `end` is equal to
    ///     `start`, the result is zero.
    /// - Returns: The distance between `start` and `end`. The result can be
    ///   negative only if the collection conforms to the
    ///   `BidirectionalCollection` protocol.
    ///
    /// - Complexity: O(1) if the collection conforms to
    ///   `RandomAccessCollection`; otherwise, O(*k*), where *k* is the
    ///   resulting distance.
    @inlinable
    public func distance(from start: CircularBuffer<Element>.Index, to end: CircularBuffer<Element>.Index) -> Int {
        return self._buffer.distance(from: start.index, to: end.index)
    }
}

// MARK: RandomAccessCollection implementation
extension CircularBuffer: RandomAccessCollection {
    /// Returns the index offset by `distance` from `index`.
    @inlinable
    public func index(_ i: Index, offsetBy distance: Int) -> Index {
        return Index(self._buffer.index(i.index, offsetBy: distance))
    }

    /// Returns an index that is the specified distance from the given index.
    ///
    /// The following example obtains an index advanced four positions from a
    /// string's starting index and then prints the character at that position.
    ///
    ///     let s = "Swift"
    ///     let i = s.index(s.startIndex, offsetBy: 4)
    ///     print(s[i])
    ///     // Prints "t"
    ///
    /// The value passed as `distance` must not offset `i` beyond the bounds of
    /// the collection.
    ///
    /// - Parameters:
    ///   - i: A valid index of the collection.
    ///   - distance: The distance to offset `i`. `distance` must not be negative
    ///     unless the collection conforms to the `BidirectionalCollection`
    ///     protocol.
    /// - Returns: An index offset by `distance` from the index `i`. If
    ///   `distance` is positive, this is the same value as the result of
    ///   `distance` calls to `index(after:)`. If `distance` is negative, this
    ///   is the same value as the result of `abs(distance)` calls to
    ///   `index(before:)`.
    ///
    /// - Complexity: O(1) if the collection conforms to
    ///   `RandomAccessCollection`; otherwise, O(*k*), where *k* is the absolute
    ///   value of `distance`.
    @inlinable
    public subscript(bounds: Range<Index>) -> SubSequence {
        /* NOT CORRECT */
        return CircularBuffer(self._buffer[Range(uncheckedBounds: (bounds.lowerBound.index, bounds.upperBound.index))])
    }
}

extension CircularBuffer {

    /// Allocates a buffer that can hold up to `initialCapacity` elements and initialise an empty ring backed by
    /// the buffer. When the ring grows to more than `initialCapacity` elements the buffer will be expanded.
    @inlinable
    public init(initialCapacity: Int) {
        self._buffer = NIODeque(minimumCapacity: initialCapacity)
    }

    /// Allocates an empty buffer.
    @inlinable
    public init() {
        self = .init(initialCapacity: 16)
    }

    /// Append an element to the end of the ring buffer.
    ///
    /// Amortized *O(1)*
    @inlinable
    public mutating func append(_ value: Element) {
        self._buffer.append(value)
    }

    /// Prepend an element to the front of the ring buffer.
    ///
    /// Amortized *O(1)*
    @inlinable
    public mutating func prepend(_ value: Element) {
        self._buffer.prepend(value)
    }

    /// Return element `offset` from first element.
    ///
    /// *O(1)*
    @inlinable
    public subscript(offset offset: Int) -> Element {
        get {
            return self[self.index(self.startIndex, offsetBy: offset)]
        }
        set {
            self[self.index(self.startIndex, offsetBy: offset)] = newValue
        }
    }
    
    /// Returns whether the ring is empty.
    @inlinable
    public var isEmpty: Bool {
        return self._buffer.isEmpty
    }

    /// Returns the number of element in the ring.
    @inlinable
    public var count: Int {
        return self._buffer.count
    }

    /// The total number of elements that the ring can contain without allocating new storage.
    @inlinable
    @available(*, deprecated, message: "capacity now deprecated")
    public var capacity: Int {
        return self._buffer.count
    }

    /// Removes all members from the circular buffer whist keeping the capacity.
    @inlinable
    public mutating func removeAll(keepingCapacity: Bool = false) {
        self._buffer.removeAll(keepingCapacity: keepingCapacity)
    }


    /// Modify the element at `index`.
    ///
    /// This function exists to provide a method of modifying the element in its underlying backing storage, instead
    /// of copying it out, modifying it, and copying it back in. This emulates the behaviour of the `_modify` accessor
    /// that is part of the generalized accessors work. That accessor is currently underscored and not safe to use, so
    /// this is the next best thing.
    ///
    /// Note that this function is not guaranteed to be fast. In particular, as it is both generic and accepts a closure
    /// it is possible that it will be slower than using the get/modify/set path that occurs with the subscript. If you
    /// are interested in using this function for performance you *must* test and verify that the optimisation applies
    /// correctly in your situation.
    ///
    /// - parameters:
    ///     - index: The index of the object that should be modified. If this index is invalid this function will trap.
    ///     - modifyFunc: The function to apply to the modified object.
    @inlinable
    public mutating func modify<Result>(_ index: Index, _ modifyFunc: (inout Element) throws -> Result) rethrows -> Result {
        return try modifyFunc(&self._buffer[index.index])
    }
    
    // MARK: CustomStringConvertible implementation
    /// Returns a human readable description of the ring.
    public var description: String {
        return self._buffer.description
    }
}

// MARK: - RangeReplaceableCollection
extension CircularBuffer: RangeReplaceableCollection {
    /// Removes and returns the first element of the `CircularBuffer`.
    ///
    /// Calling this method may invalidate all saved indices of this
    /// `CircularBuffer`. Do not rely on a previously stored index value after
    /// altering a `CircularBuffer` with any operation that can change its length.
    ///
    /// - Returns: The first element of the `CircularBuffer` if the `CircularBuffer` is not
    ///            empty; otherwise, `nil`.
    ///
    /// - Complexity: O(1)
    @inlinable
    public mutating func popFirst() -> Element? {
        if count > 0 {
            return self.removeFirst()
        } else {
            return nil
        }
    }

    /// Removes and returns the last element of the `CircularBuffer`.
    ///
    /// Calling this method may invalidate all saved indices of this
    /// `CircularBuffer`. Do not rely on a previously stored index value after
    /// altering a `CircularBuffer` with any operation that can change its length.
    ///
    /// - Returns: The last element of the `CircularBuffer` if the `CircularBuffer` is not
    ///            empty; otherwise, `nil`.
    ///
    /// - Complexity: O(1)
    @inlinable
    public mutating func popLast() -> Element? {
        if count > 0 {
            return self.removeLast()
        } else {
            return nil
        }
    }

    /// Removes the specified number of elements from the end of the
    /// `CircularBuffer`.
    ///
    /// Attempting to remove more elements than exist in the `CircularBuffer`
    /// triggers a runtime error.
    ///
    /// Calling this method may invalidate all saved indices of this
    /// `CircularBuffer`. Do not rely on a previously stored index value after
    /// altering a `CircularBuffer` with any operation that can change its length.
    ///
    /// - Parameter k: The number of elements to remove from the `CircularBuffer`.
    ///   `k` must be greater than or equal to zero and must not exceed the
    ///   number of elements in the `CircularBuffer`.
    ///
    /// - Complexity: O(*k*), where *k* is the specified number of elements.
    @inlinable
    public mutating func removeLast(_ k: Int) {
        self._buffer.removeLast(k)
    }


    /// Removes the specified number of elements from the beginning of the
    /// `CircularBuffer`.
    ///
    /// Calling this method may invalidate any existing indices for use with this
    /// `CircularBuffer`.
    ///
    /// - Parameter k: The number of elements to remove.
    ///   `k` must be greater than or equal to zero and must not exceed the
    ///   number of elements in the `CircularBuffer`.
    ///
    /// - Complexity: O(*k*), where *k* is the specified number of elements.
    @inlinable
    public mutating func removeFirst(_ k: Int) {
        return self._buffer.removeFirst(k)
    }

    /// Removes and returns the first element of the `CircularBuffer`.
    ///
    /// The `CircularBuffer` must not be empty.
    ///
    /// Calling this method may invalidate any existing indices for use with this
    /// `CircularBuffer`.
    ///
    /// - Returns: The removed element.
    ///
    /// - Complexity: O(*1*)
    @discardableResult
    @inlinable
    public mutating func removeFirst() -> Element {
        defer {
            self.removeFirst(1)
        }
        return self.first!
    }
    
    /// Removes and returns the last element of the `CircularBuffer`.
    ///
    /// The `CircularBuffer` must not be empty.
    ///
    /// Calling this method may invalidate all saved indices of this
    /// `CircularBuffer`. Do not rely on a previously stored index value after
    /// altering the `CircularBuffer` with any operation that can change its length.
    ///
    /// - Returns: The last element of the `CircularBuffer`.
    ///
    /// - Complexity: O(*1*)
    @discardableResult
    @inlinable
    public mutating func removeLast() -> Element {
        defer {
            self.removeLast(1)
        }
        return self.last!
    }

    /// Replaces the specified subrange of elements with the given `CircularBuffer`.
    ///
    /// - Parameter subrange: The subrange of the collection to replace. The bounds of the range must be valid indices
    ///                       of the `CircularBuffer`.
    ///
    /// - Parameter newElements: The new elements to add to the `CircularBuffer`.
    ///
    /// *O(n)* where _n_ is the length of the new elements collection if the subrange equals to _n_
    ///
    /// *O(m)* where _m_ is the combined length of the collection and _newElements_
    @inlinable
    public mutating func replaceSubrange<C: Collection>(_ subrange: Range<Index>, with newElements: C) where Element == C.Element {
        self._buffer.replaceSubrange(Range(uncheckedBounds: (subrange.lowerBound.index, subrange.upperBound.index)),
                                     with: newElements)
    }

    /// Removes the elements in the specified subrange from the circular buffer.
    ///
    /// - Parameter bounds: The range of the circular buffer to be removed. The bounds of the range must be valid indices of the collection.
    @inlinable
    public mutating func removeSubrange(_ bounds: Range<Index>) {
        self._buffer.removeSubrange(Range(uncheckedBounds: (bounds.lowerBound.index, bounds.upperBound.index)))
    }

    /// Removes & returns the item at `position` from the buffer
    ///
    /// - Parameter position: The index of the item to be removed from the buffer.
    ///
    /// *O(1)* if the position is `headIdx` or `tailIdx`.
    /// otherwise
    /// *O(n)* where *n* is the number of elements between `position` and `tailIdx`.
    @discardableResult
    @inlinable
    public mutating func remove(at position: Index) -> Element {
        self._buffer.remove(at: position.index)
    }
}

extension CircularBuffer: Equatable where Element: Equatable {
    public static func ==(lhs: CircularBuffer, rhs: CircularBuffer) -> Bool {
        return lhs._buffer == rhs._buffer
    }
}

extension CircularBuffer: Hashable where Element: Hashable {
    public func hash(into hasher: inout Hasher) {
        self._buffer.hash(into: &hasher)
    }
}

extension CircularBuffer: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Element...) {
        self.init(elements)
    }
}
