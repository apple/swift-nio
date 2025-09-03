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

import _NIOFileSystem

import struct Foundation.Date

@available(
    *,
    deprecated,
    message: """
        The '_NIOFileSystemFoundationCompat' module has been deprecated and will be removed from \
        SwiftNIO on or after April 1st 2026.

        You should switch to using the 'NIOFileSystemFoundationCompat' module which replaces \
        '_NIOFileSystemFoundationCompat' and is both API stable and supported by the SwiftNIO \
        maintainers.

        The most notable change between '_NIOFileSystemFoundationCompat' and \
        'NIOFileSystemFoundationCompat' is that 'FilePath' has been replaced with \
        'NIOFilePath'. Each type offers an init to convert from the other.
        """
)
extension Date {
    public init(timespec: FileInfo.Timespec) {
        let timeInterval = Double(timespec.seconds) + Double(timespec.nanoseconds) / 1_000_000_000
        self = Date(timeIntervalSince1970: timeInterval)
    }
}

@available(
    *,
    deprecated,
    message: """
        The '_NIOFileSystemFoundationCompat' module has been deprecated and will be removed from \
        SwiftNIO on or after April 1st 2026.

        You should switch to using the 'NIOFileSystemFoundationCompat' module which replaces \
        '_NIOFileSystemFoundationCompat' and is both API stable and supported by the SwiftNIO \
        maintainers.

        The most notable change between '_NIOFileSystemFoundationCompat' and \
        'NIOFileSystemFoundationCompat' is that 'FilePath' has been replaced with \
        'NIOFilePath'. Each type offers an init to convert from the other.
        """
)
extension FileInfo.Timespec {
    /// The UTC time of the timestamp.
    public var date: Date {
        Date(timespec: self)
    }
}
