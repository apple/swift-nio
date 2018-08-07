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

/// A read-only view into a portion of a `ByteBuffer`.
///
/// A `ByteBufferView` is useful whenever a `Collection where Element == UInt8` representing a portion of a
/// `ByteBuffer` is needed.
public struct ByteBufferView: ContiguousCollection, RandomAccessCollection {
    public typealias Element = UInt8
    public typealias Index = Int
    public typealias SubSequence = ByteBufferView

    private let buffer: ByteBuffer
    private let range: Range<Index>

    internal init(buffer: ByteBuffer, range: Range<Index>) {
        precondition(range.lowerBound >= 0 && range.upperBound <= buffer.capacity)
        self.buffer = buffer
        self.range = range
    }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try self.buffer.withVeryUnsafeBytes { ptr in
            try body(UnsafeRawBufferPointer.init(start: ptr.baseAddress!.advanced(by: self.range.lowerBound),
                                                 count: self.range.count))
        }
    }

    public var startIndex: Index {
        return self.range.lowerBound
    }

    public var endIndex: Index {
        return self.range.upperBound
    }

    public func index(after i: Index) -> Index {
        return i + 1
    }

    public subscript(position: Index) -> UInt8 {
        guard position >= self.range.lowerBound && position < self.range.upperBound else {
            preconditionFailure("index \(position) out of range")
        }
        return self.buffer.getInteger(at: position)!
    }

    public subscript(range: Range<Index>) -> ByteBufferView {
        return ByteBufferView(buffer: self.buffer, range: range)
    }
}

public extension ByteBuffer {
    /// A view into the readable bytes of the `ByteBuffer`.
    public var readableBytesView: ByteBufferView {
        return ByteBufferView(buffer: self, range: self.readerIndex ..< self.readerIndex + self.readableBytes)
    }

    /// Returns a view into some portion of a `ByteBuffer`.
    ///
    /// - parameters:
    ///   - index: The index the view should start at
    ///   - length: The length of the view (in bytes)
    /// - returns A view into a portion of a `ByteBuffer`.
    public func viewBytes(at index: Int, length: Int) -> ByteBufferView {
        return ByteBufferView(buffer: self, range: index ..< index+length)
    }
}
