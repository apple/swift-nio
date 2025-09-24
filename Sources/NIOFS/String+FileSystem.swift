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

import NIOCore

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension String {
    /// Reads the contents of the file at the path into a String.
    ///
    /// - Parameters:
    ///   - path: The path of the file to read.
    ///   - maximumSizeAllowed: The maximum size of file which can be read, in bytes, as a ``ByteCount``. If the file is larger than this, an error is thrown.
    ///   - fileSystem: The ``FileSystemProtocol`` instance to use to read the file.
    ///
    /// - Throws: If the file is larger than `maximumSizeAllowed`, an ``FileSystemError/Code-swift.struct/resourceExhausted`` error will be thrown.
    public init(
        contentsOf path: NIOFilePath,
        maximumSizeAllowed: ByteCount,
        fileSystem: some FileSystemProtocol
    ) async throws {
        let byteBuffer = try await fileSystem.withFileHandle(forReadingAt: path) { handle in
            try await handle.readToEnd(maximumSizeAllowed: maximumSizeAllowed)
        }

        self = Self(buffer: byteBuffer)
    }

    /// Reads the contents of the file at the path using ``FileSystem``.
    ///
    /// - Parameters:
    ///   - path: The path of the file to read.
    ///   - maximumSizeAllowed: The maximum size of file which can be read, in bytes, as a ``ByteCount``. If the file is larger than this, an error is thrown.
    ///
    /// - Throws: If the file is larger than `maximumSizeAllowed`, an ``FileSystemError/Code-swift.struct/resourceExhausted`` error will be thrown.
    public init(
        contentsOf path: NIOFilePath,
        maximumSizeAllowed: ByteCount
    ) async throws {
        self = try await Self(
            contentsOf: path,
            maximumSizeAllowed: maximumSizeAllowed,
            fileSystem: .shared
        )
    }
}
