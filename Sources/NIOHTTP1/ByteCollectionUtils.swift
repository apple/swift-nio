//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

private let defaultWhitespaces = [" ", "\t"].map({ $0.utf8.first! })

/// Uppercases `byte` if, and only if, it is an ASCII lowercase letter (`a`...`z`).
///
/// A naive `byte & 0xdf` mask clears bit `0x20` unconditionally, which also folds
/// several *distinct* punctuation bytes into the same value because they only
/// differ from one another in that bit: `^`(0x5e)/`~`(0x7e), `[`(0x5b)/`{`(0x7b),
/// `]`(0x5d)/`}`(0x7d), `\`(0x5c)/`|`(0x7c), and `@`(0x40)/`` ` ``(0x60). All of
/// these are legal `tchar` bytes in HTTP header field names (RFC 7230 §3.2.6), so
/// masking them collapses otherwise-distinct header names into the same identity.
@inline(__always)
private func uppercaseASCIILetter(_ byte: UInt8) -> UInt8 {
    switch byte {
    case UInt8(ascii: "a")...UInt8(ascii: "z"):
        return byte & 0xdf
    default:
        return byte
    }
}

extension ByteBufferView {
    internal func trim(limitingElements: [UInt8]) -> ByteBufferView {
        guard let lastNonWhitespaceIndex = self.lastIndex(where: { !limitingElements.contains($0) }),
            let firstNonWhitespaceIndex = self.firstIndex(where: { !limitingElements.contains($0) })
        else {
            // This buffer is entirely trimmed elements, so trim it to nothing.
            return self[self.startIndex..<self.startIndex]
        }
        return self[firstNonWhitespaceIndex..<index(after: lastNonWhitespaceIndex)]
    }

    internal func trimSpaces() -> ByteBufferView {
        trim(limitingElements: defaultWhitespaces)
    }
}

extension Sequence where Self.Element == UInt8 {
    /// Compares the collection of `UInt8`s to a case insensitive collection.
    ///
    /// This collection could be get from applying the `UTF8View`
    ///   property on the string protocol.
    ///
    /// - Parameter to: The string constant in the form of a collection of `UInt8`
    /// - Returns: Whether the collection contains **EXACTLY** this array or no, but by ignoring case.
    internal func compareCaseInsensitiveASCIIBytes<T: Sequence>(to: T) -> Bool
    where T.Element == UInt8 {
        // fast path: we can get the underlying bytes of both
        let maybeMaybeResult = self.withContiguousStorageIfAvailable { lhsBuffer -> Bool? in
            to.withContiguousStorageIfAvailable { rhsBuffer in
                if lhsBuffer.count != rhsBuffer.count {
                    return false
                }

                for idx in 0..<lhsBuffer.count {
                    // let's hope this gets vectorised ;)
                    if uppercaseASCIILetter(lhsBuffer[idx]) != uppercaseASCIILetter(rhsBuffer[idx]) {
                        return false
                    }
                }
                return true
            }
        }

        if let maybeResult = maybeMaybeResult, let result = maybeResult {
            return result
        } else {
            return self.elementsEqual(to, by: { uppercaseASCIILetter($0) == uppercaseASCIILetter($1) })
        }
    }
}

extension String {
    internal func isEqualCaseInsensitiveASCIIBytes(to: String) -> Bool {
        self.utf8.compareCaseInsensitiveASCIIBytes(to: to.utf8)
    }
}
