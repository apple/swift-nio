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

import NIO

fileprivate let defaultWhitespaces = [" ", "\t"].map({$0.utf8.first!})

// Backport of Collection.firstIndex and BidirectionalCollection.lastIndex
#if !swift(>=4.2)
extension Collection {
    /// Returns the first index in which an element of the collection satisfies
    /// the given predicate.
    ///
    /// You can use the predicate to find an element of a type that doesn't
    /// conform to the `Equatable` protocol or to find an element that matches
    /// particular criteria. Here's an example that finds a student name that
    /// begins with the letter "A":
    ///
    ///     let students = ["Kofi", "Abena", "Peter", "Kweku", "Akosua"]
    ///     if let i = students.firstIndex(where: { $0.hasPrefix("A") }) {
    ///         print("\(students[i]) starts with 'A'!")
    ///     }
    ///     // Prints "Abena starts with 'A'!"
    ///
    /// - Parameter predicate: A closure that takes an element as its argument
    ///   and returns a Boolean value that indicates whether the passed element
    ///   represents a match.
    /// - Returns: The index of the first element for which `predicate` returns
    ///   `true`. If no elements in the collection satisfy the given predicate,
    ///   returns `nil`.
    ///
    /// - Complexity: O(*n*), where *n* is the length of the collection.
    @_inlineable @_versioned
    internal func firstIndex(where predicate: (Element) throws -> Bool) rethrows -> Index? {
        var i = self.startIndex
        while i != self.endIndex {
            if try predicate(self[i]) {
                return i
            }
            self.formIndex(after: &i)
        }
        return nil
    }
}

extension BidirectionalCollection {
    /// Returns the index of the last element in the collection that matches the
    /// given predicate.
    ///
    /// You can use the predicate to find an element of a type that doesn't
    /// conform to the `Equatable` protocol or to find an element that matches
    /// particular criteria. This example finds the index of the last name that
    /// begins with the letter "A":
    ///
    ///     let students = ["Kofi", "Abena", "Peter", "Kweku", "Akosua"]
    ///     if let i = students.lastIndex(where: { $0.hasPrefix("A") }) {
    ///         print("\(students[i]) starts with 'A'!")
    ///     }
    ///     // Prints "Akosua starts with 'A'!"
    ///
    /// - Parameter predicate: A closure that takes an element as its argument
    ///   and returns a Boolean value that indicates whether the passed element
    ///   represents a match.
    /// - Returns: The index of the last element in the collection that matches
    ///   `predicate`, or `nil` if no elements match.
    ///
    /// - Complexity: O(*n*), where *n* is the length of the collection.
    @_inlineable @_versioned
    internal func lastIndex(where predicate: (Element) throws -> Bool) rethrows -> Index? {
        var i = endIndex
        while i != startIndex {
            self.formIndex(before: &i)
            if try predicate(self[i]) {
                return i
            }
        }
        return nil
    }
}
#endif

extension ByteBufferView {
    internal func trim(limitingElements: [UInt8]) -> ByteBufferView {
        guard let lastNonWhitespaceIndex = self.lastIndex(where: { !limitingElements.contains($0) }),
              let firstNonWhitespaceIndex = self.firstIndex(where: { !limitingElements.contains($0) }) else {
                // This buffer is entirely trimmed elements, so trim it to nothing.
                return self[self.startIndex..<self.startIndex]
        }
        return self[firstNonWhitespaceIndex..<index(after: lastNonWhitespaceIndex)]
    }
    
    internal func trimSpaces() -> ByteBufferView {
        return trim(limitingElements: defaultWhitespaces)
    }
}

extension Sequence where Self.Element == UInt8 {
    /// Compares the collection of `UInt8`s to a case insensitive collection.
    ///
    /// This collection could be get from applying the `UTF8View`
    ///   property on the string protocol.
    ///
    /// - Parameter bytes: The string constant in the form of a collection of `UInt8`
    /// - Returns: Whether the collection contains **EXACTLY** this array or no, but by ignoring case.
    internal func compareCaseInsensitiveASCIIBytes<T: Sequence>(to bytes: T) -> Bool
        where T.Element == UInt8 {
            return self.elementsEqual(bytes, by: {return ($0 & 0xdf) == ($1 & 0xdf)})
    }
}
