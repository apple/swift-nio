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

private let defaultWhitespaces = [" ", "\t"].map { $0.utf8.first! }

extension ByteBufferView {
    func trim(limitingElements: [UInt8]) -> ByteBufferView {
        guard let lastNonWhitespaceIndex = lastIndex(where: { !limitingElements.contains($0) }),
              let firstNonWhitespaceIndex = firstIndex(where: { !limitingElements.contains($0) })
        else {
            // This buffer is entirely trimmed elements, so trim it to nothing.
            return self[startIndex ..< startIndex]
        }
        return self[firstNonWhitespaceIndex ..< index(after: lastNonWhitespaceIndex)]
    }

    func trimSpaces() -> ByteBufferView {
        trim(limitingElements: defaultWhitespaces)
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
    func compareCaseInsensitiveASCIIBytes<T: Sequence>(to: T) -> Bool
        where T.Element == UInt8
    {
        // fast path: we can get the underlying bytes of both
        let maybeMaybeResult = withContiguousStorageIfAvailable { lhsBuffer -> Bool? in
            to.withContiguousStorageIfAvailable { rhsBuffer in
                if lhsBuffer.count != rhsBuffer.count {
                    return false
                }

                for idx in 0 ..< lhsBuffer.count {
                    // let's hope this gets vectorised ;)
                    if lhsBuffer[idx] & 0xDF != rhsBuffer[idx] & 0xDF {
                        return false
                    }
                }
                return true
            }
        }

        if let maybeResult = maybeMaybeResult, let result = maybeResult {
            return result
        } else {
            return elementsEqual(to, by: { ($0 & 0xDF) == ($1 & 0xDF) })
        }
    }
}

extension String {
    func isEqualCaseInsensitiveASCIIBytes(to: String) -> Bool {
        utf8.compareCaseInsensitiveASCIIBytes(to: to.utf8)
    }
}
