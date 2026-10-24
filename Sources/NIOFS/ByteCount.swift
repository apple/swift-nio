//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// Represents the number of bytes.
public struct ByteCount: Hashable, Sendable {
    /// The number of bytes
    public var bytes: Int64

    /// Returns a ``ByteCount`` with a given number of bytes
    /// - Parameter count: The number of bytes
    public static func bytes(_ count: Int64) -> ByteCount {
        ByteCount(bytes: count)
    }

    /// Returns a ``ByteCount`` with a given number of kilobytes
    ///
    /// One kilobyte is 1000 bytes.
    ///
    /// If the resulting number of bytes does not fit in an `Int64` the value
    /// saturates to `Int64.max` (or `Int64.min` for negative counts) rather
    /// than overflowing.
    ///
    /// - Parameter count: The number of kilobytes
    public static func kilobytes(_ count: Int64) -> ByteCount {
        ByteCount(bytes: count.multipliedSaturating(by: 1000))
    }

    /// Returns a ``ByteCount`` with a given number of megabytes
    ///
    /// One megabyte is 1,000,000 bytes.
    ///
    /// If the resulting number of bytes does not fit in an `Int64` the value
    /// saturates to `Int64.max` (or `Int64.min` for negative counts) rather
    /// than overflowing.
    ///
    /// - Parameter count: The number of megabytes
    public static func megabytes(_ count: Int64) -> ByteCount {
        ByteCount(bytes: count.multipliedSaturating(by: 1000 * 1000))
    }

    /// Returns a ``ByteCount`` with a given number of gigabytes
    ///
    /// One gigabyte is 1,000,000,000 bytes.
    ///
    /// If the resulting number of bytes does not fit in an `Int64` the value
    /// saturates to `Int64.max` (or `Int64.min` for negative counts) rather
    /// than overflowing.
    ///
    /// - Parameter count: The number of gigabytes
    public static func gigabytes(_ count: Int64) -> ByteCount {
        ByteCount(bytes: count.multipliedSaturating(by: 1000 * 1000 * 1000))
    }

    /// Returns a ``ByteCount`` with a given number of kibibytes
    ///
    /// One kibibyte is 1024 bytes.
    ///
    /// If the resulting number of bytes does not fit in an `Int64` the value
    /// saturates to `Int64.max` (or `Int64.min` for negative counts) rather
    /// than overflowing.
    ///
    /// - Parameter count: The number of kibibytes
    public static func kibibytes(_ count: Int64) -> ByteCount {
        ByteCount(bytes: count.multipliedSaturating(by: 1024))
    }

    /// Returns a ``ByteCount`` with a given number of mebibytes
    ///
    /// One mebibyte is 10,485,760 bytes.
    ///
    /// If the resulting number of bytes does not fit in an `Int64` the value
    /// saturates to `Int64.max` (or `Int64.min` for negative counts) rather
    /// than overflowing.
    ///
    /// - Parameter count: The number of mebibytes
    public static func mebibytes(_ count: Int64) -> ByteCount {
        ByteCount(bytes: count.multipliedSaturating(by: 1024 * 1024))
    }

    /// Returns a ``ByteCount`` with a given number of gibibytes
    ///
    /// One gibibyte is 10,737,418,240 bytes.
    ///
    /// If the resulting number of bytes does not fit in an `Int64` the value
    /// saturates to `Int64.max` (or `Int64.min` for negative counts) rather
    /// than overflowing.
    ///
    /// - Parameter count: The number of gibibytes
    public static func gibibytes(_ count: Int64) -> ByteCount {
        ByteCount(bytes: count.multipliedSaturating(by: 1024 * 1024 * 1024))
    }
}

extension Int64 {
    /// Multiplies `self` by `other`, saturating to `Int64.max` or `Int64.min`
    /// on overflow instead of trapping.
    fileprivate func multipliedSaturating(by other: Int64) -> Int64 {
        let (result, overflow) = self.multipliedReportingOverflow(by: other)
        guard overflow else {
            return result
        }
        // The factors are constant positive multipliers, so the sign of the
        // saturated result follows the sign of `self`.
        return self < 0 ? .min : .max
    }
}

extension ByteCount {
    /// A ``ByteCount`` for the maximum amount of bytes that can be written to `ByteBuffer`.
    internal static var byteBufferCapacity: ByteCount {
        #if arch(arm) || arch(i386) || arch(arm64_32) || arch(wasm32)
        // on 32-bit platforms we can't make use of a whole UInt32.max (as it doesn't fit in an Int)
        let byteBufferMaxIndex = UInt32(Int.max)
        #else
        // on 64-bit platforms we're good
        let byteBufferMaxIndex = UInt32.max
        #endif

        return ByteCount(bytes: Int64(byteBufferMaxIndex))
    }

    /// A ``ByteCount`` for an unlimited amount of bytes.
    public static var unlimited: ByteCount {
        ByteCount(bytes: .max)
    }
}

extension ByteCount: AdditiveArithmetic {
    public static var zero: ByteCount { ByteCount(bytes: 0) }

    public static func + (lhs: ByteCount, rhs: ByteCount) -> ByteCount {
        ByteCount(bytes: lhs.bytes + rhs.bytes)
    }

    public static func - (lhs: ByteCount, rhs: ByteCount) -> ByteCount {
        ByteCount(bytes: lhs.bytes - rhs.bytes)
    }
}

extension ByteCount: Comparable {
    public static func < (lhs: ByteCount, rhs: ByteCount) -> Bool {
        lhs.bytes < rhs.bytes
    }
}
