//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import SystemPackage

/// Information about an item within a directory.
public struct DirectoryEntry: Sendable, Hashable, Equatable {
    /// The path of the directory entry.
    ///
    /// - Precondition: The path must have at least one component.
    public let filePath: NIOFilePath

    /// The path of the directory entry.
    ///
    /// - Note: This property returns the underlying `SystemPackage.FilePath` instance of ``filePath``.
    public var path: FilePath {
        self.filePath.underlying
    }

    /// The name of the entry; the final component of the ``path``.
    ///
    /// If `path` is "/Users/tim/path-to-4T.key" then `name` will be "path-to-4T.key".
    public var name: FilePath.Component {
        self.path.lastComponent!
    }

    /// The type of entry.
    public var type: FileType

    /// Creates a directory entry; returns `nil` if `path` has no components.
    ///
    /// - Parameters:
    ///   - path: The path of the directory entry which must contain at least one component.
    ///   - type: The type of entry.
    public init?(path: NIOFilePath, type: FileType) {
        if path.underlying.components.isEmpty {
            return nil
        }

        self.filePath = path
        self.type = type
    }

    /// Creates a directory entry; returns `nil` if `path` has no components.
    ///
    /// - Parameters:
    ///   - path: The path of the directory entry which must contain at least one component.
    ///   - type: The type of entry.
    @_disfavoredOverload
    public init?(path: FilePath, type: FileType) {
        self.init(path: .init(path), type: type)
    }
}
