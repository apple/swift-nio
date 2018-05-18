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
    
    var byteBuffer: ByteBuffer
    var separator: UInt8
    let start: Int
    let length: Int
    
    private var currentIndex: Int
    
    public typealias Element = ByteBuffer
    mutating public func next() -> ByteBuffer? {
        
        return byteBuffer.withVeryUnsafeBytes { pointer -> ByteBuffer? in
            
            let startPoint   = pointer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            
            var address      = startPoint.advanced(by: currentIndex)
            let finalAddress =    address.advanced(by: length)
            
            let initialPointer = address

            while address < finalAddress && address.pointee != 0 {
                
                if address.pointee == separator {
                    break
                }
                address = address.advanced(by: 1)
            }
            
            let tokenLength = address - initialPointer
            let ret = byteBuffer.getSlice(at: currentIndex, length: tokenLength)
            // For the next time, with skipping the separator
            currentIndex += tokenLength + 1
            
            return ret
        }

    }
    
    public init(byteBuffer: ByteBuffer, separator: UInt8, start: Int, length: Int) {
        // This should never happens as we control when this is called. Adding an assert to ensure this.
        assert(start <= byteBuffer.capacity - length)
        
        self.byteBuffer = byteBuffer
        self.separator = separator
        self.start = start
        self.length = length
        self.currentIndex = self.start
    }

    public init(byteBuffer: ByteBuffer,
                separator: UInt8) {
        
        self.init(byteBuffer: byteBuffer, separator: separator,
                  start: byteBuffer.readerIndex, length: byteBuffer.readableBytes)
    }
}

extension ByteBuffer {
    
    public func sliceByTrimming(whiteSpaces: [UInt8], start: Int, length: Int) -> ByteBuffer? {
        return withVeryUnsafeBytes { pointer -> ByteBuffer? in
            assert(start <= self.capacity - length)
            
            let firstPtr = pointer.baseAddress!.assumingMemoryBound(to: UInt8.self)

            var startPtr = firstPtr.advanced(by: start)
            var endPtr   = startPtr.advanced(by: length - 1)
            
            // Advance startPtr until not a whiteSpace
            while startPtr < endPtr && startPtr.pointee != 0 && whiteSpaces.contains(startPtr.pointee) {
                startPtr = startPtr.advanced(by: 1)
            }
            
            // Retreat endPtr until not a whiteSpace, null is considered a whiteSpace
            while endPtr >= startPtr && (whiteSpaces.contains(endPtr.pointee) || endPtr.pointee == 0) {
                endPtr = endPtr.advanced(by: -1)
            }
            return self.getSlice(at: startPtr - firstPtr, length: endPtr - startPtr + 1)
        }
    }
    
    public func sliceByTrimmingWhitespaces() -> ByteBuffer? {
        return sliceByTrimming(whiteSpaces: [" ", "\t"].map({UInt8($0.utf8CString[0])}),
                               start: 0, length: self.readableBytes)
    }
    
    public func sliceByTrimmingWhitespaces(from start: Int = 0, length: Int) -> ByteBuffer? {
        return sliceByTrimming(whiteSpaces: [" ", "\t"].map({UInt8($0.utf8CString[0])}),
                               start: start, length: length)
    }
    
    public func sliceByTrimmingWhitespaces(from start: Int) -> ByteBuffer? {
        return sliceByTrimming(whiteSpaces: [" ", "\t"].map({UInt8($0.utf8CString[0])}),
                               start: start, length: self.readableBytes - start)
    }
    
    /// Compares the buffer to a case insensitive `ContiguousArray<UInt8>`.
    ///
    /// This `ContiguousArray` could be get from applying the `asUpperCaseContiguousUTF8UIntArray`
    ///   property on the string protocol.
    ///
    /// **WARNING:** MAKE SURE THAT THE STRING YOU PASS IS UPPERCASE
    ///
    /// This function doesn't change the indices of the buffer
    ///
    /// - Parameter constant: The string constant in the form of contiguous array _IN UPPER CASE_.
    /// - Returns: Whether the ByteBuffer contains **EXACTLY** this array or no, but by ignoring case.
    public func compareReadingToCaseInsensitiveCString(_ constant: ContiguousArray<UInt8>) -> Bool {
        
        let length = self.readableBytes
        // If available is not equal the string length itself, it can't be equal
        if self.readableBytes != constant.count { return false }

        return withVeryUnsafeBytes { pointer -> Bool in
            var pointer = pointer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            
            for (idx, char) in constant.enumerated() {
                
                guard idx < length else { return true }
                if (pointer.pointee & 0xdf) != char { return false }
                pointer = pointer.advanced(by: 1)

            }
            return true
        }
        
    }
    
    /// Compares the buffer to a case sensitive `ContiguousArray<UInt8>`.
    ///
    /// This `ContiguousArray` could be get from applying the `asContiguousUTF8UIntArray` property
    /// on a string protocol.
    ///
    /// This function doesn't change the indices of the buffer
    ///
    /// - Parameter constant: The string constant in the form of contiguous array.
    /// - Returns: Whether the ByteBuffer contains **EXACTLY** this array or no.
    public func compareReadingToCaseSensitiveCString(_ constant: ContiguousArray<UInt8>) -> Bool {
        
        let length = self.readableBytes
        // If available is not equal the string length itself, it can't be equal
        if self.readableBytes != constant.count { return false }
        
        return withVeryUnsafeBytes { pointer -> Bool in
            var pointer = pointer.baseAddress!.assumingMemoryBound(to: UInt8.self)

            for (idx, char) in constant.enumerated() {
            
                guard idx < length else { return true }
                if (pointer.pointee) != char { return false }
                pointer = pointer.advanced(by: 1)
                
            }
            return true
        }
        
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
