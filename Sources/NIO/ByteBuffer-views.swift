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
public struct ByteBufferView: RandomAccessCollection {
    public typealias Element = UInt8
    public typealias Index = Int
    public typealias SubSequence = ByteBufferView

    /* private but usableFromInline */ @usableFromInline var _buffer: ByteBuffer
    /* private but usableFromInline */ @usableFromInline var _range: Range<Index>

    @inlinable
    internal init(buffer: ByteBuffer, range: Range<Index>) {
        precondition(range.lowerBound >= 0 && range.upperBound <= buffer.capacity)
        self._buffer = buffer
        self._range = range
    }

    /// Creates a `ByteBufferView` from the readable bytes of the given `buffer`.
    @inlinable
    public init(_ buffer: ByteBuffer) {
        self = ByteBufferView(buffer: buffer, range: buffer.readerIndex ..< buffer.writerIndex)
    }

    @inlinable
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try self._buffer.withVeryUnsafeBytes { ptr in
            try body(UnsafeRawBufferPointer(start: ptr.baseAddress!.advanced(by: self._range.lowerBound),
                                            count: self._range.count))
        }
    }

    @inlinable
    public var startIndex: Index {
        return self._range.lowerBound
    }

    @inlinable
    public var endIndex: Index {
        return self._range.upperBound
    }

    @inlinable
    public func index(after i: Index) -> Index {
        return i + 1
    }

    @inlinable
    public subscript(position: Index) -> UInt8 {
        get {
            guard position >= self._range.lowerBound && position < self._range.upperBound else {
                preconditionFailure("index \(position) out of range")
            }
            return self._buffer.getInteger(at: position)! // range check above
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
            return ByteBufferView(buffer: self._buffer, range: range)
        }
        set {
            self.replaceSubrange(range, with: newValue)
        }
    }

    @inlinable
    public func withContiguousStorageIfAvailable<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R? {
        return try self.withUnsafeBytes { bytes in
            return try body(bytes.bindMemory(to: UInt8.self))
        }
    }

    @inlinable
    public func _customIndexOfEquatableElement(_ element : Element) -> Index?? {
        return .some(self.withUnsafeBytes { ptr -> Index? in
            return ptr.firstIndex(of: element).map { $0 + self._range.lowerBound }
        })
    }

    @inlinable
    public func _customLastIndexOfEquatableElement(_ element: Element) -> Index?? {
        return .some(self.withUnsafeBytes { ptr -> Index? in
            return ptr.lastIndex(of: element).map { $0 + self._range.lowerBound }
        })
    }
}

extension ByteBufferView: MutableCollection {}

extension ByteBufferView: RangeReplaceableCollection {
    // required by `RangeReplaceableCollection`
    @inlinable
    public init() {
        self = ByteBufferView(ByteBuffer())
    }

    @inlinable
    public mutating func replaceSubrange<C: Collection>(_ subrange: Range<Index>, with newElements: C) where ByteBufferView.Element == C.Element {
        precondition(subrange.startIndex >= self.startIndex && subrange.endIndex <= self.endIndex,
                     "subrange out of bounds")

        if newElements.count == subrange.count {
            self._buffer.setBytes(newElements, at: subrange.startIndex)
        } else if newElements.count < subrange.count {
            // Replace the subrange.
            self._buffer.setBytes(newElements, at: subrange.startIndex)

            // Remove the unwanted bytes between the newly copied bytes and the end of the subrange.
            // try! is fine here: the copied range is within the view and the length can't be negative.
            try! self._buffer.copyBytes(at: subrange.endIndex,
                                        to: subrange.startIndex.advanced(by: newElements.count),
                                        length: subrange.endIndex.distance(to: self._buffer.writerIndex))

            // Shorten the range.
            let removedBytes = subrange.count - newElements.count
            self._buffer.moveWriterIndex(to: self._buffer.writerIndex - removedBytes)
            self._range = self._range.dropLast(removedBytes)
        } else {
            // Make space for the new elements.
            // try! is fine here: the copied range is within the view and the length can't be negative.
            try! self._buffer.copyBytes(at: subrange.endIndex,
                                        to: subrange.startIndex.advanced(by: newElements.count),
                                        length: subrange.endIndex.distance(to: self._buffer.writerIndex))

            // Replace the bytes.
            self._buffer.setBytes(newElements, at: subrange.startIndex)

            // Widen the range.
            let additionalByteCount = newElements.count - subrange.count
            self._buffer.moveWriterIndex(forwardBy: additionalByteCount)
            self._range = self._range.startIndex ..< self._range.endIndex.advanced(by: additionalByteCount)

        }
    }
}

extension ByteBuffer {
    /// A view into the readable bytes of the `ByteBuffer`.
    @inlinable
    public var readableBytesView: ByteBufferView {
        return ByteBufferView(self)
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

        return ByteBufferView(buffer: self, range: index ..< (index + length))
    }

    /// Create a `ByteBuffer` from the given `ByteBufferView`s range.
    ///
    /// - parameter view: The `ByteBufferView` which you want to get a `ByteBuffer` from.
    @inlinable
    public init(_ view: ByteBufferView) {
        self = view._buffer.getSlice(at: view.startIndex, length: view.count)!
    }
}
