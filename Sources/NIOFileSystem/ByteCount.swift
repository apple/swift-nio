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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux) || os(Android)

/// Represents the number of bytes.
public struct ByteCount: Hashable, Sendable {
    /// The number of bytes
    public var bytes: Int64

    /// Returns a ``ByteCount`` with a given number of bytes
    /// - Parameter count: The number of bytes
    public static func bytes(_ count: Int64) -> ByteCount {
        return ByteCount(bytes: count)
    }

    /// Returns a ``ByteCount`` with a given number of kilobytes
    ///
    /// One kilobyte is 1000 bytes.
    ///
    /// - Parameter count: The number of kilobytes
    public static func kilobytes(_ count: Int64) -> ByteCount {
        return ByteCount(bytes: 1000 * count)
    }

    /// Returns a ``ByteCount`` with a given number of megabytes
    ///
    /// One megabyte is 1,000,000 bytes.
    ///
    /// - Parameter count: The number of megabytes
    public static func megabytes(_ count: Int64) -> ByteCount {
        return ByteCount(bytes: 1000 * 1000 * count)
    }

    /// Returns a ``ByteCount`` with a given number of gigabytes
    ///
    /// One gigabyte is 1,000,000,000 bytes.
    ///
    /// - Parameter count: The number of gigabytes
    public static func gigabytes(_ count: Int64) -> ByteCount {
        return ByteCount(bytes: 1000 * 1000 * 1000 * count)
    }

    /// Returns a ``ByteCount`` with a given number of kibibytes
    ///
    /// One kibibyte is 1024 bytes.
    ///
    /// - Parameter count: The number of kibibytes
    public static func kibibytes(_ count: Int64) -> ByteCount {
        return ByteCount(bytes: 1024 * count)
    }

    /// Returns a ``ByteCount`` with a given number of mebibytes
    ///
    /// One mebibyte is 10,485,760 bytes.
    ///
    /// - Parameter count: The number of mebibytes
    public static func mebibytes(_ count: Int64) -> ByteCount {
        return ByteCount(bytes: 1024 * 1024 * count)
    }

    /// Returns a ``ByteCount`` with a given number of gibibytes
    ///
    /// One gibibyte is 10,737,418,240 bytes.
    ///
    /// - Parameter count: The number of gibibytes
    public static func gibibytes(_ count: Int64) -> ByteCount {
        return ByteCount(bytes: 1024 * 1024 * 1024 * count)
    }
}

#endif
