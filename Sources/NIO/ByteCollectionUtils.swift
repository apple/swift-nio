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

fileprivate let defaultWhitespaces = [" ", "\t"].map({UInt8($0.utf8CString[0])})

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
    func compare<T: Collection>(rhs: T, selfTransform: (T.Element) -> (T.Element) = { return $0 }) -> Bool where T.Element == Self.Element {
        
        // If lengths are not equal, it can't be equal
        if self.count != rhs.count { return false }
        
        // Create an iterator for the right hand side, so that both are iterated, no need for indices
        var rightIterator = rhs.makeIterator()
        
        for leftByte in self {
            if (rightIterator.next()) != selfTransform(leftByte) {
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

extension Collection where Self.Element: Equatable {
    
    public func trim(limitingElements: [Self.Element]) -> Self.SubSequence {
        let trimmingLast = self.dropLast(self.reversed().enumerated().first(where: {!limitingElements.contains($0.element)})?.offset ?? 0)
        return trimmingLast.dropFirst(trimmingLast.enumerated().first(where: {!limitingElements.contains($0.element)})?.offset ?? 0)
    }
    
}

extension Collection where Self.Element == UInt8 {
    public var trimSpaces: Self.SubSequence {
        return trim(limitingElements: defaultWhitespaces)
    }

    /// Compares the collection of `UInt8`s to a case insensitive collection.
    ///
    /// This collection could be get from applying the `asUpperCaseContiguousUTF8UIntArray`
    ///   property on the string protocol.
    ///
    /// **WARNING:** MAKE SURE THAT THE STRING YOU PASS IS UPPERCASE
    ///
    /// - Parameter bytes: The string constant in the form of a collection of `UInt8` _IN
    ///                     UPPER CASE_.
    /// - Returns: Whether the collection contains **EXACTLY** this array or no, but by ignoring case.
    public func compareReadableBytes<T: Collection>(to bytes: T) -> Bool
        where T.Element == UInt8 {
            
            return self.compare(rhs: bytes, selfTransform: {$0 & 0xdf})
    }
}
