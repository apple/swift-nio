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

/// A `Collection` that is contiguously laid out in memory and can therefore be duplicated using `memcpy`.
public protocol ContiguousCollection: Collection {
    @_inlineable
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R
}

extension StaticString: Collection {
    public typealias Element = UInt8
    public typealias SubSequence = ArraySlice<UInt8>
    
    public typealias _Index = Int
    
    public var startIndex: _Index { return 0 }
    public var endIndex: _Index { return self.utf8CodeUnitCount }
    public func index(after i: _Index) -> _Index { return i + 1 }
    
    public subscript(position: Int) -> UInt8 {
        precondition(position < self.utf8CodeUnitCount, "index \(position) out of bounds")
        return self.utf8Start.advanced(by: position).pointee
    }
}
extension UnsafeRawBufferPointer: ContiguousCollection {
    @_inlineable
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try body(self)
    }
}
extension UnsafeMutableRawBufferPointer: ContiguousCollection {
    @_inlineable
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try body(UnsafeRawBufferPointer(self))
    }
}

#if swift(>=4.1)
extension Slice: ContiguousCollection where Base: ContiguousCollection {
    @_inlineable
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        // this is rather compicated because of SR-8580 (can't have two Slice extensions, even if non-overlapping)
        let byteDistanceFromBaseToSelf = self.base.distance(from: self.base.startIndex,
                                                            to: self.startIndex) * MemoryLayout<Base.Element>.stride
        let numberOfBytesInSelf = self.count * MemoryLayout<Base.Element>.stride
        return try self.base.withUnsafeBytes { (pointerToBaseCollection: UnsafeRawBufferPointer) -> R in
            let start = pointerToBaseCollection.startIndex + byteDistanceFromBaseToSelf
            let end   = start + numberOfBytesInSelf
            let range = start..<end
            // the next asserts that `range` is contained in the indices of pointerToBaseCollection
            precondition((pointerToBaseCollection.indices).clamped(to: range) == range)
            return try body(UnsafeRawBufferPointer(rebasing: pointerToBaseCollection[range]))
        }
    }
}
#endif

extension Array: ContiguousCollection {}
extension ArraySlice: ContiguousCollection {}
extension ContiguousArray: ContiguousCollection {}
// ContiguousArray's slice is ArraySlice

extension StaticString: ContiguousCollection {
    @_inlineable
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try body(UnsafeRawBufferPointer(start: self.utf8Start, count: self.utf8CodeUnitCount))
    }
}

extension UnsafeBufferPointer: ContiguousCollection {
    @_inlineable
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try body(UnsafeRawBufferPointer(self))
    }
}
extension UnsafeMutableBufferPointer: ContiguousCollection {
    @_inlineable
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try body(UnsafeRawBufferPointer(self))
    }
}
