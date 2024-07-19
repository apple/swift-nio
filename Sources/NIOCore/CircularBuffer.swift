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

/// An automatically expanding ring buffer implementation backed by a `ContiguousArray`. Even though this implementation
/// will automatically expand if more elements than `initialCapacity` are stored, it's advantageous to prevent
/// expansions from happening frequently. Expansions will always force an allocation and a copy to happen.
public struct CircularBuffer<Element>: CustomStringConvertible {
    @usableFromInline
    internal private(set) var _buffer: ContiguousArray<Element?>

    @usableFromInline
    internal private(set) var headBackingIndex: Int

    @usableFromInline
    internal private(set) var tailBackingIndex: Int

    @inlinable
    internal var mask: Int {
        self._buffer.count &- 1
    }

    @inlinable
    internal mutating func advanceHeadIdx(by: Int) {
        self.headBackingIndex = indexAdvanced(index: self.headBackingIndex, by: by)
    }

    @inlinable
    internal mutating func advanceTailIdx(by: Int) {
        self.tailBackingIndex = indexAdvanced(index: self.tailBackingIndex, by: by)
    }

    @inlinable
    internal func indexBeforeHeadIdx() -> Int {
        self.indexAdvanced(index: self.headBackingIndex, by: -1)
    }

    @inlinable
    internal func indexBeforeTailIdx() -> Int {
        self.indexAdvanced(index: self.tailBackingIndex, by: -1)
    }

    @inlinable
    internal func indexAdvanced(index: Int, by: Int) -> Int {
        (index &+ by) & self.mask
    }

    /// An opaque `CircularBuffer` index.
    ///
    /// You may get indices offset from other indices by using `CircularBuffer.index(:offsetBy:)`,
    /// `CircularBuffer.index(before:)`, or `CircularBuffer.index(after:)`.
    ///
    /// - note: Every index is invalidated as soon as you perform a length-changing operating on the `CircularBuffer`
    ///         but remains valid when you replace one item by another using the subscript.
    public struct Index: Comparable, Sendable {
        @usableFromInline private(set) var _backingIndex: UInt32
        @usableFromInline private(set) var _backingCheck: _UInt24
        @usableFromInline private(set) var isIndexGEQHeadIndex: Bool

        @inlinable
        internal var backingIndex: Int {
            Int(self._backingIndex)
        }

        @inlinable
        internal init(backingIndex: Int, backingCount: Int, backingIndexOfHead: Int) {
            self.isIndexGEQHeadIndex = backingIndex >= backingIndexOfHead
            self._backingCheck = .max
            self._backingIndex = UInt32(backingIndex)
            debugOnly {
                // if we can, we store the check for the backing here
                self._backingCheck = backingCount < Int(_UInt24.max) ? _UInt24(UInt32(backingCount)) : .max
            }
        }

        @inlinable
        public static func == (lhs: Index, rhs: Index) -> Bool {
            lhs._backingIndex == rhs._backingIndex && lhs._backingCheck == rhs._backingCheck
                && lhs.isIndexGEQHeadIndex == rhs.isIndexGEQHeadIndex
        }

        @inlinable
        public static func < (lhs: Index, rhs: Index) -> Bool {
            if lhs.isIndexGEQHeadIndex && rhs.isIndexGEQHeadIndex {
                return lhs.backingIndex < rhs.backingIndex
            } else if lhs.isIndexGEQHeadIndex && !rhs.isIndexGEQHeadIndex {
                return true
            } else if !lhs.isIndexGEQHeadIndex && rhs.isIndexGEQHeadIndex {
                return false
            } else {
                return lhs.backingIndex < rhs.backingIndex
            }
        }

        @usableFromInline
        internal func isValidIndex(for ring: CircularBuffer<Element>) -> Bool {
            self._backingCheck == _UInt24.max || Int(self._backingCheck) == ring.count
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
        self.index(after, offsetBy: 1)
    }

    /// Returns the index before `index`.
    @inlinable
    public func index(before: Index) -> Index {
        self.index(before, offsetBy: -1)
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
            assert(
                position.isValidIndex(for: self),
                "illegal index used, index was for CircularBuffer with count \(position._backingCheck), "
                    + "but actual count is \(self.count)"
            )
            return self._buffer[position.backingIndex]!
        }
        set {
            assert(
                position.isValidIndex(for: self),
                "illegal index used, index was for CircularBuffer with count \(position._backingCheck), "
                    + "but actual count is \(self.count)"
            )
            self._buffer[position.backingIndex] = newValue
        }
    }

    /// The position of the first element in a nonempty `CircularBuffer`.
    ///
    /// If the `CircularBuffer` is empty, `startIndex` is equal to `endIndex`.
    @inlinable
    public var startIndex: Index {
        .init(
            backingIndex: self.headBackingIndex,
            backingCount: self.count,
            backingIndexOfHead: self.headBackingIndex
        )
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
        .init(
            backingIndex: self.tailBackingIndex,
            backingCount: self.count,
            backingIndexOfHead: self.headBackingIndex
        )
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
        let backingCount = self._buffer.count

        switch (start.isIndexGEQHeadIndex, end.isIndexGEQHeadIndex) {
        case (true, true):
            return end.backingIndex &- start.backingIndex
        case (true, false):
            return backingCount &- (start.backingIndex &- end.backingIndex)
        case (false, true):
            return -(backingCount &- (end.backingIndex &- start.backingIndex))
        case (false, false):
            return end.backingIndex &- start.backingIndex
        }
    }

    @inlinable
    public func _copyContents(
        initializing buffer: UnsafeMutableBufferPointer<Element>
    ) -> (Iterator, UnsafeMutableBufferPointer<Element>.Index) {
        precondition(buffer.count >= self.count)

        guard var ptr = buffer.baseAddress else {
            return (self.makeIterator(), buffer.startIndex)
        }

        if self.tailBackingIndex >= self.headBackingIndex {
            for index in self.headBackingIndex..<self.tailBackingIndex {
                ptr.initialize(to: self._buffer[index]!)
                ptr += 1
            }
        } else {
            for index in self.headBackingIndex..<self._buffer.endIndex {
                ptr.initialize(to: self._buffer[index]!)
                ptr += 1
            }
            for index in 0..<self.tailBackingIndex {
                ptr.initialize(to: self._buffer[index]!)
                ptr += 1
            }
        }

        return (self[self.endIndex..<self.endIndex].makeIterator(), self.count)
    }

    // These are implemented as no-ops for performance reasons.
    @inlinable
    public func _failEarlyRangeCheck(_ index: Index, bounds: Range<Index>) {}

    @inlinable
    public func _failEarlyRangeCheck(_ index: Index, bounds: ClosedRange<Index>) {}

    @inlinable
    public func _failEarlyRangeCheck(_ range: Range<Index>, bounds: Range<Index>) {}
}

// MARK: RandomAccessCollection implementation
extension CircularBuffer: RandomAccessCollection {
    /// Returns the index offset by `distance` from `index`.
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
    public func index(_ i: Index, offsetBy distance: Int) -> Index {
        .init(
            backingIndex: (i.backingIndex &+ distance) & self.mask,
            backingCount: self.count,
            backingIndexOfHead: self.headBackingIndex
        )
    }

    @inlinable
    public subscript(bounds: Range<Index>) -> SubSequence {
        get {
            precondition(self.distance(from: self.startIndex, to: bounds.lowerBound) >= 0)
            precondition(self.distance(from: bounds.upperBound, to: self.endIndex) >= 0)

            var newRing = self
            newRing.headBackingIndex = bounds.lowerBound.backingIndex
            newRing.tailBackingIndex = bounds.upperBound.backingIndex
            return newRing
        }
        set {
            precondition(self.distance(from: self.startIndex, to: bounds.lowerBound) >= 0)
            precondition(self.distance(from: bounds.upperBound, to: self.endIndex) >= 0)

            self.replaceSubrange(bounds, with: newValue)
        }
    }
}

extension CircularBuffer {

    /// Allocates a buffer that can hold up to `initialCapacity` elements and initialise an empty ring backed by
    /// the buffer. When the ring grows to more than `initialCapacity` elements the buffer will be expanded.
    @inlinable
    public init(initialCapacity: Int) {
        let capacity = Int(UInt32(initialCapacity).nextPowerOf2())
        self.headBackingIndex = 0
        self.tailBackingIndex = 0
        self._buffer = ContiguousArray<Element?>(repeating: nil, count: capacity)
        assert(self._buffer.count == capacity)
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
        self._buffer[self.tailBackingIndex] = value
        self.advanceTailIdx(by: 1)

        if self.headBackingIndex == self.tailBackingIndex {
            // No more room left for another append so grow the buffer now.
            self._doubleCapacity()
        }
    }

    /// Prepend an element to the front of the ring buffer.
    ///
    /// Amortized *O(1)*
    @inlinable
    public mutating func prepend(_ value: Element) {
        let idx = self.indexBeforeHeadIdx()
        self._buffer[idx] = value
        self.advanceHeadIdx(by: -1)

        if self.headBackingIndex == self.tailBackingIndex {
            // No more room left for another append so grow the buffer now.
            self._doubleCapacity()
        }
    }

    /// Double the capacity of the buffer and adjust the headIdx and tailIdx.
    ///
    /// Must only be called when buffer is full.
    @inlinable
    internal mutating func _doubleCapacity() {
        // Double the storage. This can't use _resizeAndFlatten because the buffer is
        // full at this stage. That's ok: we have some optimised code paths for this use-case.
        let newCapacity = self.capacity << 1
        assert(self.headBackingIndex == self.tailBackingIndex)

        var newBacking: ContiguousArray<Element?> = []
        precondition(newCapacity > 0, "Can't change capacity to \(newCapacity)")
        assert(newCapacity % 2 == 0)
        assert(newCapacity > self.capacity)

        newBacking.reserveCapacity(newCapacity)
        newBacking.append(contentsOf: self._buffer[self.headBackingIndex...])
        newBacking.append(contentsOf: self._buffer[..<self.tailBackingIndex])

        let newTailIndex = newBacking.count
        let paddingCount = newCapacity &- newTailIndex
        newBacking.append(contentsOf: repeatElement(nil, count: paddingCount))

        self.headBackingIndex = 0
        self.tailBackingIndex = newTailIndex
        self._buffer = newBacking
        assert(self.verifyInvariants())
    }

    /// Resizes and flatten this buffer.
    ///
    /// Capacities are always powers of 2.
    @inlinable
    internal mutating func _resizeAndFlatten(newCapacity: Int) {
        var newBacking: ContiguousArray<Element?> = []
        precondition(newCapacity > 0, "Can't change capacity to \(newCapacity)")
        assert(newCapacity % 2 == 0)
        assert(newCapacity > self.capacity)

        newBacking.reserveCapacity(newCapacity)

        if self.tailBackingIndex >= self.headBackingIndex {
            newBacking.append(contentsOf: self._buffer[self.headBackingIndex..<self.tailBackingIndex])
        } else {
            newBacking.append(contentsOf: self._buffer[self.headBackingIndex...])
            newBacking.append(contentsOf: self._buffer[..<self.tailBackingIndex])
        }

        let newTailIndex = newBacking.count
        let paddingCount = newCapacity &- newTailIndex
        newBacking.append(contentsOf: repeatElement(nil, count: paddingCount))

        self.headBackingIndex = 0
        self.tailBackingIndex = newTailIndex
        self._buffer = newBacking
        assert(self.verifyInvariants())
    }

    /// Return element `offset` from first element.
    ///
    /// *O(1)*
    @inlinable
    public subscript(offset offset: Int) -> Element {
        get {
            self[self.index(self.startIndex, offsetBy: offset)]
        }
        set {
            self[self.index(self.startIndex, offsetBy: offset)] = newValue
        }
    }

    /// Returns whether the ring is empty.
    @inlinable
    public var isEmpty: Bool {
        self.headBackingIndex == self.tailBackingIndex
    }

    /// Returns the number of element in the ring.
    @inlinable
    public var count: Int {
        if self.tailBackingIndex >= self.headBackingIndex {
            return self.tailBackingIndex &- self.headBackingIndex
        } else {
            return self._buffer.count &- (self.headBackingIndex &- self.tailBackingIndex)
        }
    }

    /// The total number of elements that the ring can contain without allocating new storage.
    @inlinable
    public var capacity: Int {
        self._buffer.count
    }

    /// Removes all members from the circular buffer whist keeping the capacity.
    @inlinable
    public mutating func removeAll(keepingCapacity: Bool = false) {
        if keepingCapacity {
            self.removeFirst(self.count)
        } else {
            self._buffer.removeAll(keepingCapacity: false)
            self._buffer.append(nil)
        }
        self.headBackingIndex = 0
        self.tailBackingIndex = 0
        assert(self.verifyInvariants())
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
    public mutating func modify<Result>(
        _ index: Index,
        _ modifyFunc: (inout Element) throws -> Result
    ) rethrows -> Result {
        try modifyFunc(&self._buffer[index.backingIndex]!)
    }

    // MARK: CustomStringConvertible implementation
    /// Returns a human readable description of the ring.
    public var description: String {
        var desc = "[ "
        for el in self._buffer.enumerated() {
            if el.0 == self.headBackingIndex {
                desc += "<"
            } else if el.0 == self.tailBackingIndex {
                desc += ">"
            }
            desc += el.1.map { "\($0) " } ?? "_ "
        }
        desc += "]"
        desc += " (bufferCapacity: \(self._buffer.count), ringLength: \(self.count))"
        return desc
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
        precondition(k <= self.count, "Number of elements to drop bigger than the amount of elements in the buffer.")
        var idx = self.tailBackingIndex
        for _ in 0..<k {
            idx = self.indexAdvanced(index: idx, by: -1)
            self._buffer[idx] = nil
        }
        self.tailBackingIndex = idx
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
        precondition(k <= self.count, "Number of elements to drop bigger than the amount of elements in the buffer.")
        var idx = self.headBackingIndex
        for _ in 0..<k {
            self._buffer[idx] = nil
            idx = self.indexAdvanced(index: idx, by: 1)
        }
        self.headBackingIndex = idx
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
    public mutating func replaceSubrange<C: Collection>(_ subrange: Range<Index>, with newElements: C)
    where Element == C.Element {
        precondition(
            subrange.lowerBound >= self.startIndex && subrange.upperBound <= self.endIndex,
            "Subrange out of bounds"
        )
        assert(
            subrange.lowerBound.isValidIndex(for: self),
            "illegal index used, index was for CircularBuffer with count \(subrange.lowerBound._backingCheck), "
                + "but actual count is \(self.count)"
        )
        assert(
            subrange.upperBound.isValidIndex(for: self),
            "illegal index used, index was for CircularBuffer with count \(subrange.upperBound._backingCheck), "
                + "but actual count is \(self.count)"
        )

        let subrangeCount = self.distance(from: subrange.lowerBound, to: subrange.upperBound)

        if subrangeCount == newElements.count {
            var index = subrange.lowerBound
            for element in newElements {
                self._buffer[index.backingIndex] = element
                index = self.index(after: index)
            }
        } else if subrangeCount == self.count && newElements.isEmpty {
            self.removeSubrange(subrange)
        } else {
            var newBuffer: ContiguousArray<Element?> = []
            let neededNewCapacity = self.count + newElements.count - subrangeCount + 1  // always one spare
            let newCapacity = Swift.max(self.capacity, neededNewCapacity.nextPowerOf2())
            newBuffer.reserveCapacity(newCapacity)

            // This mapping is required due to an inconsistent ability to append sequences of non-optional
            // to optional sequences.
            // https://bugs.swift.org/browse/SR-7921
            newBuffer.append(contentsOf: self[self.startIndex..<subrange.lowerBound].lazy.map { $0 })
            newBuffer.append(contentsOf: newElements.lazy.map { $0 })
            newBuffer.append(contentsOf: self[subrange.upperBound..<self.endIndex].lazy.map { $0 })

            let repetitionCount = newCapacity &- newBuffer.count
            if repetitionCount > 0 {
                newBuffer.append(contentsOf: repeatElement(nil, count: repetitionCount))
            }
            self._buffer = newBuffer
            self.headBackingIndex = 0
            self.tailBackingIndex = newBuffer.count &- repetitionCount
        }
        assert(self.verifyInvariants())
    }

    /// Removes the elements in the specified subrange from the circular buffer.
    ///
    /// - Parameter bounds: The range of the circular buffer to be removed. The bounds of the range must be valid indices of the collection.
    @inlinable
    public mutating func removeSubrange(_ bounds: Range<Index>) {
        precondition(bounds.upperBound >= self.startIndex && bounds.upperBound <= self.endIndex, "Invalid bounds.")

        let boundsCount = self.distance(from: bounds.lowerBound, to: bounds.upperBound)
        switch boundsCount {
        case 1:
            remove(at: bounds.lowerBound)
        case self.count:
            self = .init(initialCapacity: self._buffer.count)
        default:
            replaceSubrange(bounds, with: [])
        }
        assert(self.verifyInvariants())
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
        assert(
            position.isValidIndex(for: self),
            "illegal index used, index was for CircularBuffer with count \(position._backingCheck), "
                + "but actual count is \(self.count)"
        )
        defer {
            assert(self.verifyInvariants())
        }
        precondition(self.indices.contains(position), "Position out of bounds.")
        var bufferIndex = position.backingIndex
        let element = self._buffer[bufferIndex]!

        switch bufferIndex {
        case self.headBackingIndex:
            self.advanceHeadIdx(by: 1)
            self._buffer[bufferIndex] = nil
        case self.indexBeforeTailIdx():
            self.advanceTailIdx(by: -1)
            self._buffer[bufferIndex] = nil
        default:
            self._buffer[bufferIndex] = nil
            var nextIndex = self.indexAdvanced(index: bufferIndex, by: 1)
            while nextIndex != self.tailBackingIndex {
                self._buffer.swapAt(bufferIndex, nextIndex)
                bufferIndex = nextIndex
                nextIndex = self.indexAdvanced(index: bufferIndex, by: 1)
            }
            self.advanceTailIdx(by: -1)
        }

        return element
    }

    /// The first `Element` of the `CircularBuffer` (or `nil` if empty).
    @inlinable
    public var first: Element? {
        // We implement this here to work around https://bugs.swift.org/browse/SR-14516
        guard !self.isEmpty else {
            return nil
        }
        return self[self.startIndex]
    }

    /// Prepares the `CircularBuffer` to store the specified number of elements.
    @inlinable
    public mutating func reserveCapacity(_ minimumCapacity: Int) {
        if self.capacity >= minimumCapacity {
            // Already done, do nothing.
            return
        }

        // We need to allocate a larger buffer. We take this opportunity to make ourselves contiguous
        // again as needed.
        let targetCapacity = minimumCapacity.nextPowerOf2()
        self._resizeAndFlatten(newCapacity: targetCapacity)
    }
}

extension CircularBuffer {
    @usableFromInline
    internal func verifyInvariants() -> Bool {
        var index = self.headBackingIndex
        while index != self.tailBackingIndex {
            if self._buffer[index] == nil {
                return false
            }
            index = self.indexAdvanced(index: index, by: 1)
        }
        return true
    }

    // this is not a general invariant (not true for CircularBuffer that have been sliced)
    private func unreachableAreNil() -> Bool {
        var index = self.tailBackingIndex
        while index != self.headBackingIndex {
            if self._buffer[index] != nil {
                return false
            }
            index = self.indexAdvanced(index: index, by: 1)
        }
        return true
    }

    internal func testOnly_verifyInvariantsForNonSlices() -> Bool {
        self.verifyInvariants() && self.unreachableAreNil()
    }
}

extension CircularBuffer: Equatable where Element: Equatable {
    public static func == (lhs: CircularBuffer, rhs: CircularBuffer) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy(==)
    }
}

extension CircularBuffer: Hashable where Element: Hashable {
    public func hash(into hasher: inout Hasher) {
        for element in self {
            hasher.combine(element)
        }
    }
}

extension CircularBuffer: Sendable where Element: Sendable {}

extension CircularBuffer: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Element...) {
        self.init(elements)
    }
}
