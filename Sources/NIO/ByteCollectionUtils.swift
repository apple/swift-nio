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

extension Sequence where Self.Element: Equatable {
    public func dropLast(while: (Self.Element) throws -> (Bool)) rethrows -> Self.SubSequence {
        let numLastTrimmedElements = try self.reversed().enumerated().first(where: {try !`while`($0.element)})?.offset ?? 0
        return self.dropLast(numLastTrimmedElements)
    }
    
    public func trim(limitingElements: [Self.Element]) -> Self.SubSequence {
        return dropLast(while: {limitingElements.contains($0)})
                  .drop(while: {limitingElements.contains($0)})
    }
}

extension Sequence where Self.Element == UInt8 {
    public var trimSpaces: Self.SubSequence {
        return trim(limitingElements: defaultWhitespaces)
    }
}

extension Sequence where Self.Element == UInt8 {
    /// Compares the collection of `UInt8`s to a case insensitive collection.
    ///
    /// This collection could be get from applying the `UTF8View`
    ///   property on the string protocol.
    ///
    /// - Parameter bytes: The string constant in the form of a collection of `UInt8` _IN
    ///                     UPPER CASE_.
    /// - Returns: Whether the collection contains **EXACTLY** this array or no, but by ignoring case.
    public func compareReadableBytes<T: Collection>(to bytes: T) -> Bool
        where T.Element == UInt8 {
            return self.elementsEqual(bytes, by: {return ($0 & 0xdf) == ($1 & 0xdf)})
    }
}
