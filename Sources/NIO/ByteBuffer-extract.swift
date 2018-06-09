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

/// A base ByteBuffer "Slicer", this base one just splits by a separator.
public struct ByteBufferSliceSplitIterator: IteratorProtocol {
    
    private(set) var currentIndex: Int
    
    let endIndex: Int
    let byteBufferView: ByteBufferView
    let separator: UInt8
    
    var length: Int {
        get {
            return endIndex - currentIndex
        }
    }
    
    public typealias Element = ByteBufferView
    mutating public func next() -> ByteBufferView? {
        
        let remaining = self.byteBufferView
            .prefix(self.endIndex)
            .dropFirst(self.currentIndex)
        
        var index: Int = remaining.count
        
        for pointee in remaining.enumerated() {
            if pointee.element == separator {
                index = pointee.offset
                break
            }
        }
        
        let start = currentIndex
        // For the next time, with skipping the separator
        currentIndex += index + 1
        
        return byteBufferView[start..<(start+length)]

    }
    
    public init(byteBufferView: ByteBufferView, separator: UInt8, start: Int, length: Int) {
        precondition(start <= byteBufferView.count - length)
        
        self.byteBufferView = byteBufferView
        self.separator = separator
        self.currentIndex = start
        self.endIndex = start + length
    }

    public init(byteBuffer: ByteBuffer,
                separator: UInt8) {
        
        self.init(byteBufferView: byteBuffer.readableBytesView, separator: separator,
                  start: 0, length: byteBuffer.readableBytes)
    }

    public init(byteBuffer: ByteBuffer, separator: UInt8, start: Int, length: Int) {
        self.init(byteBufferView: byteBuffer.readableBytesView, separator: separator,
                  start: start, length: length)
    }
    
    public init(byteBufferView: ByteBufferView,
                separator: UInt8) {
        
        self.init(byteBufferView: byteBufferView, separator: separator,
                  start: 0, length: byteBufferView.count)
    }
}

extension ByteBuffer {
    
    static var defaultWhitespaces = [" ", "\t"].map({UInt8($0.utf8CString[0])})
    
    public func sliceByTrimming(whiteSpaces: [UInt8], start: Int, length: Int) -> ByteBuffer? {
        precondition(start <= self.capacity - length)
        
        let buffer = self.readableBytesView
                         .dropFirst(start)
                         .prefix(length)

        // Assume that all are whitespaces in the beginning
        var startIndex = buffer.count
        // Advance from the start until not a whiteSpace
        for pointee in buffer.enumerated() {
            if pointee.element == 0 || !(whiteSpaces.contains(pointee.element)) {
                startIndex = pointee.offset
                break
            }
        }
        
        let leadingTrimmedBuffer = buffer.dropFirst(startIndex)
        
        // Assume that all are whitespaces
        var endIndex = leadingTrimmedBuffer.count
        // Retreat the ending until not a whiteSpace, null is considered a whiteSpace
        for pointee in leadingTrimmedBuffer.reversed().enumerated() {
            if !(whiteSpaces.contains(pointee.element) || pointee.element == 0) {
                endIndex = buffer.count - pointee.offset
                break
            }
        }
        // Validate, i.e. end >= start, then return null if invalid
        return endIndex >= startIndex ?
                    self.getSlice(at: startIndex + start, length: endIndex - startIndex) :
                    nil
    }
    
    public func sliceByTrimmingWhitespaces() -> ByteBuffer? {
        return sliceByTrimming(whiteSpaces: ByteBuffer.defaultWhitespaces,
                               start: 0, length: self.readableBytes)
    }
    
    /// Compares the buffer to a case insensitive collection.
    ///
    /// This array could be get from applying the `asUpperCaseContiguousUTF8UIntArray`
    ///   property on the string protocol.
    ///
    /// **WARNING:** MAKE SURE THAT THE STRING YOU PASS IS UPPERCASE
    ///
    /// This function doesn't change the indices of the buffer
    ///
    /// - Parameter bytes: The string constant in the form of a collection of `UInt8` _IN
    ///                     UPPER CASE_.
    /// - Returns: Whether the ByteBuffer contains **EXACTLY** this array or no, but by ignoring case.
    public func compareReadableBytes<T: Collection>(to bytes: T) -> Bool
        where T.Element == UInt8 {
            
        return self.readableBytesView.map({$0 & 0xdf}) == bytes
    }
    
}

public extension StringProtocol {
    /// Gets the string as a contiguous array to be used with comparator methods.
    /// Useful ONLY for constants or long lived strings.
    public var asContiguousUTF8UIntArray: ContiguousArray<UInt8> {
        return ContiguousArray.init(self.utf8)
    }
    
    /// Gets the string as a contiguous array to be used with comparator methods.
    /// But in Upper Case, so could use in case sensitive comparison, it already uppercases the
    /// buffer.
    public var asUpperCaseContiguousUTF8UIntArray: ContiguousArray<UInt8> {
        return ContiguousArray.init(self.utf8.map({$0 & 0xdf}))
    }

}

// Collection comparator extension
// Could be used on any collection to compare their contents with any other one
extension Collection where Element: Equatable {
    func compare<T: Collection>(rhs: T) -> Bool where T.Element == Self.Element {
        // If lengths are not equal, it can't be equal
        if self.count != rhs.count { return false }
        
        // Create an iterator for the right hand side, so that both are iterated, no need for indices
        var rightIterator = rhs.makeIterator()
        
        for leftByte in self {
            if (rightIterator.next()) != leftByte {
                return false
            }
        }
        return true
    }
    
    public static func ==<T: Collection>(lhs: Self, rhs: T) -> Bool where T.Element == Self.Element {
        return lhs.compare(rhs: rhs)
    }
    
    public static func !=<T: Collection>(lhs: Self, rhs: T) -> Bool where T.Element == Self.Element {
        return !lhs.compare(rhs: rhs)
    }
}
