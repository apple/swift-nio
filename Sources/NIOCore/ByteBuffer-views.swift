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

/// A view into a portion of a `ByteBuffer`.
///
/// A `ByteBufferView` is useful whenever a `Collection where Element == UInt8` representing a portion of a
/// `ByteBuffer` is needed.
public struct ByteBufferView: RandomAccessCollection, Sendable {
    public typealias Element = UInt8
    public typealias Index = Int
    public typealias SubSequence = ByteBufferView

    @usableFromInline var _buffer: ByteBuffer
    @usableFromInline var _range: Range<Index>

    @inlinable
    internal init(buffer: ByteBuffer, range: Range<Index>) {
        precondition(range.lowerBound >= 0 && range.upperBound <= buffer.capacity)
        self._buffer = buffer
        self._range = range
    }

    /// Creates a `ByteBufferView` from the readable bytes of the given `buffer`.
    @inlinable
    public init(_ buffer: ByteBuffer) {
        self = ByteBufferView(buffer: buffer, range: buffer.readerIndex..<buffer.writerIndex)
    }

    @inlinable
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try self._buffer.withVeryUnsafeBytes { ptr in
            try body(
                UnsafeRawBufferPointer(
                    start: ptr.baseAddress!.advanced(by: self._range.lowerBound),
                    count: self._range.count
                )
            )
        }
    }

    @inlinable
    public var startIndex: Index {
        self._range.lowerBound
    }

    @inlinable
    public var endIndex: Index {
        self._range.upperBound
    }

    @inlinable
    public func index(after i: Index) -> Index {
        i + 1
    }

    @inlinable
    public var count: Int {
        // Unchecked is safe here: Range enforces that upperBound is strictly greater than
        // lower bound, and we guarantee that _range.lowerBound >= 0.
        self._range.upperBound &- self._range.lowerBound
    }

    @inlinable
    public subscript(position: Index) -> UInt8 {
        get {
            guard position >= self._range.lowerBound && position < self._range.upperBound else {
                preconditionFailure("index \(position) out of range")
            }
            return self._buffer.getInteger(at: position)!  // range check above
        }
        set {
            guard position >= self._range.lowerBound && position < self._range.upperBound else {
                preconditionFailure("index \(position) out of range")
            }
            self._buffer.setInteger(newValue, at: position)
        }
    }

    @inlinable
    public subscript(range: Range<Index>) -> ByteBufferView {
        get {
            ByteBufferView(buffer: self._buffer, range: range)
        }
        set {
            self.replaceSubrange(range, with: newValue)
        }
    }

    @inlinable
    public func withContiguousStorageIfAvailable<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R? {
        try self.withUnsafeBytes { bytes in
            try body(bytes.bindMemory(to: UInt8.self))
        }
    }

    @inlinable
    public func _customIndexOfEquatableElement(_ element: Element) -> Index?? {
        .some(
            self.withUnsafeBytes { ptr -> Index? in
                ptr.firstIndex(of: element).map { $0 + self._range.lowerBound }
            }
        )
    }

    @inlinable
    public func _customLastIndexOfEquatableElement(_ element: Element) -> Index?? {
        .some(
            self.withUnsafeBytes { ptr -> Index? in
                ptr.lastIndex(of: element).map { $0 + self._range.lowerBound }
            }
        )
    }

    @inlinable
    public func _customContainsEquatableElement(_ element: Element) -> Bool? {
        .some(
            self.withUnsafeBytes { ptr -> Bool in
                ptr.contains(element)
            }
        )
    }

    @inlinable
    public func _copyContents(
        initializing ptr: UnsafeMutableBufferPointer<UInt8>
    ) -> (Iterator, UnsafeMutableBufferPointer<UInt8>.Index) {
        precondition(ptr.count >= self.count)

        let bytesToWrite = self.count

        let endIndex = self.withContiguousStorageIfAvailable { ourBytes in
            ptr.initialize(from: ourBytes).1
        }
        precondition(endIndex == bytesToWrite)

        let iterator = self[self.endIndex..<self.endIndex].makeIterator()
        return (iterator, bytesToWrite)
    }

    // These are implemented as no-ops for performance reasons.
    @inlinable
    public func _failEarlyRangeCheck(_ index: Index, bounds: Range<Index>) {}

    @inlinable
    public func _failEarlyRangeCheck(_ index: Index, bounds: ClosedRange<Index>) {}

    @inlinable
    public func _failEarlyRangeCheck(_ range: Range<Index>, bounds: Range<Index>) {}
}

extension ByteBufferView: MutableCollection {}

extension ByteBufferView: RangeReplaceableCollection {
    // required by `RangeReplaceableCollection`
    @inlinable
    public init() {
        self = ByteBufferView(ByteBuffer())
    }

    /// Reserves enough space in the underlying `ByteBuffer` such that this view can
    /// store the specified number of bytes without reallocation.
    ///
    /// See the documentation for ``ByteBuffer/reserveCapacity(_:)`` for more details.
    @inlinable
    public mutating func reserveCapacity(_ minimumCapacity: Int) {
        let additionalCapacity = minimumCapacity - self.count
        if additionalCapacity > 0 {
            self._buffer.reserveCapacity(self._buffer.capacity + additionalCapacity)
        }
    }

    /// Writes a single byte to the underlying `ByteBuffer`.
    @inlinable
    public mutating func append(_ byte: UInt8) {
        // ``CollectionOfOne`` has no witness for
        // ``Sequence.withContiguousStorageIfAvailable(_:)``. so we do this instead:
        self._buffer.setInteger(byte, at: self._range.upperBound)
        self._range = self._range.lowerBound..<self._range.upperBound.advanced(by: 1)
        self._buffer.moveWriterIndex(to: self._range.upperBound)
    }

    /// Writes a sequence of bytes to the underlying `ByteBuffer`.
    @inlinable
    public mutating func append<Bytes: Sequence>(contentsOf bytes: Bytes) where Bytes.Element == UInt8 {
        let written = self._buffer.setBytes(bytes, at: self._range.upperBound)
        self._range = self._range.lowerBound..<self._range.upperBound.advanced(by: written)
        self._buffer.moveWriterIndex(to: self._range.upperBound)
    }

    @inlinable
    public mutating func replaceSubrange<C: Collection>(_ subrange: Range<Index>, with newElements: C)
    where ByteBufferView.Element == C.Element {
        precondition(
            subrange.startIndex >= self.startIndex && subrange.endIndex <= self.endIndex,
            "subrange out of bounds"
        )

        if newElements.count == subrange.count {
            self._buffer.setBytes(newElements, at: subrange.startIndex)
        } else if newElements.count < subrange.count {
            // Replace the subrange.
            self._buffer.setBytes(newElements, at: subrange.startIndex)

            // Remove the unwanted bytes between the newly copied bytes and the end of the subrange.
            // try! is fine here: the copied range is within the view and the length can't be negative.
            try! self._buffer.copyBytes(
                at: subrange.endIndex,
                to: subrange.startIndex.advanced(by: newElements.count),
                length: subrange.endIndex.distance(to: self._buffer.writerIndex)
            )

            // Shorten the range.
            let removedBytes = subrange.count - newElements.count
            self._buffer.moveWriterIndex(to: self._buffer.writerIndex - removedBytes)
            self._range = self._range.dropLast(removedBytes)
        } else {
            // Make space for the new elements.
            // try! is fine here: the copied range is within the view and the length can't be negative.
            try! self._buffer.copyBytes(
                at: subrange.endIndex,
                to: subrange.startIndex.advanced(by: newElements.count),
                length: subrange.endIndex.distance(to: self._buffer.writerIndex)
            )

            // Replace the bytes.
            self._buffer.setBytes(newElements, at: subrange.startIndex)

            // Widen the range.
            let additionalByteCount = newElements.count - subrange.count
            self._buffer.moveWriterIndex(forwardBy: additionalByteCount)
            self._range = self._range.startIndex..<self._range.endIndex.advanced(by: additionalByteCount)
        }
    }
}

extension ByteBuffer {
    /// A view into the readable bytes of the `ByteBuffer`.
    @inlinable
    public var readableBytesView: ByteBufferView {
        ByteBufferView(self)
    }

    /// Returns a view into some portion of the readable bytes of a `ByteBuffer`.
    ///
    /// - parameters:
    ///   - index: The index the view should start at
    ///   - length: The length of the view (in bytes)
    /// - returns: A view into a portion of a `ByteBuffer` or `nil` if the requested bytes were not readable.
    @inlinable
    public func viewBytes(at index: Int, length: Int) -> ByteBufferView? {
        guard length >= 0 && index >= self.readerIndex && index <= self.writerIndex - length else {
            return nil
        }

        return ByteBufferView(buffer: self, range: index..<(index + length))
    }

    /// Create a `ByteBuffer` from the given `ByteBufferView`s range.
    ///
    /// - parameter view: The `ByteBufferView` which you want to get a `ByteBuffer` from.
    @inlinable
    public init(_ view: ByteBufferView) {
        self = view._buffer.getSlice(at: view.startIndex, length: view.count)!
    }
}

extension ByteBufferView: Equatable {
    /// required by `Equatable`
    @inlinable
    public static func == (lhs: ByteBufferView, rhs: ByteBufferView) -> Bool {

        guard lhs._range.count == rhs._range.count else {
            return false
        }

        // A well-formed ByteBufferView can never have a range that is out-of-bounds of the backing ByteBuffer.
        // As a result, these getSlice calls can never fail, and we'd like to know it if they do.
        let leftBufferSlice = lhs._buffer.getSlice(at: lhs._range.startIndex, length: lhs._range.count)!
        let rightBufferSlice = rhs._buffer.getSlice(at: rhs._range.startIndex, length: rhs._range.count)!

        return leftBufferSlice == rightBufferSlice
    }
}

extension ByteBufferView: Hashable {
    /// required by `Hashable`
    @inlinable
    public func hash(into hasher: inout Hasher) {
        // A well-formed ByteBufferView can never have a range that is out-of-bounds of the backing ByteBuffer.
        // As a result, this getSlice call can never fail, and we'd like to know it if it does.
        hasher.combine(self._buffer.getSlice(at: self._range.startIndex, length: self._range.count)!)
    }
}

extension ByteBufferView: ExpressibleByArrayLiteral {
    /// required by `ExpressibleByArrayLiteral`
    @inlinable
    public init(arrayLiteral elements: Element...) {
        self.init(elements)
    }
}
