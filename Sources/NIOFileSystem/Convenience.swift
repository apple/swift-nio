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

extension String {
    /// Writes the UTF8 encoded `String` to a file.
    ///
    /// - Parameters:
    ///   - path: The path of the file to write the `String` to.
    ///   - offset: The offset into the file to write to, defaults to zero.
    ///   - options: Options for opening the file, defaults to creating a new file.
    ///   - fileSystem: The ``FileSystemProtocol`` instance to use.
    /// - Returns: The number of bytes written to the file.
    @discardableResult
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public func write(
        toFileAt path: NIOFilePath,
        absoluteOffset offset: Int64 = 0,
        options: OpenOptions.Write = .newFile(replaceExisting: false),
        fileSystem: some FileSystemProtocol
    ) async throws -> Int64 {
        try await self.utf8.write(
            toFileAt: path,
            absoluteOffset: offset,
            options: options,
            fileSystem: fileSystem
        )
    }

    /// Writes the UTF8 encoded `String` to a file.
    ///
    /// - Parameters:
    ///   - path: The path of the file to write the `String` to.
    ///   - offset: The offset into the file to write to, defaults to zero.
    ///   - options: Options for opening the file, defaults to creating a new file.
    /// - Returns: The number of bytes written to the file.
    @discardableResult
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public func write(
        toFileAt path: NIOFilePath,
        absoluteOffset offset: Int64 = 0,
        options: OpenOptions.Write = .newFile(replaceExisting: false)
    ) async throws -> Int64 {
        try await self.write(
            toFileAt: path,
            absoluteOffset: offset,
            options: options,
            fileSystem: .shared
        )
    }
}

extension Sequence<UInt8> where Self: Sendable {
    /// Writes the contents of the `Sequence` to a file.
    ///
    /// - Parameters:
    ///   - path: The path of the file to write the contents of the sequence to.
    ///   - offset: The offset into the file to write to, defaults to zero.
    ///   - options: Options for opening the file, defaults to creating a new file.
    ///   - fileSystem: The ``FileSystemProtocol`` instance to use.
    /// - Returns: The number of bytes written to the file.
    @discardableResult
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public func write(
        toFileAt path: NIOFilePath,
        absoluteOffset offset: Int64 = 0,
        options: OpenOptions.Write = .newFile(replaceExisting: false),
        fileSystem: some FileSystemProtocol
    ) async throws -> Int64 {
        try await fileSystem.withFileHandle(forWritingAt: path, options: options) { handle in
            try await handle.write(contentsOf: self, toAbsoluteOffset: offset)
        }
    }

    /// Writes the contents of the `Sequence` to a file.
    ///
    /// - Parameters:
    ///   - path: The path of the file to write the contents of the sequence to.
    ///   - offset: The offset into the file to write to, defaults to zero.
    ///   - options: Options for opening the file, defaults to creating a new file.
    /// - Returns: The number of bytes written to the file.
    @discardableResult
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public func write(
        toFileAt path: NIOFilePath,
        absoluteOffset offset: Int64 = 0,
        options: OpenOptions.Write = .newFile(replaceExisting: false)
    ) async throws -> Int64 {
        try await self.write(
            toFileAt: path,
            absoluteOffset: offset,
            options: options,
            fileSystem: .shared
        )
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AsyncSequence where Self.Element: Sequence<UInt8>, Self: Sendable {
    /// Writes the contents of the `AsyncSequence` to a file.
    ///
    /// - Parameters:
    ///   - path: The path of the file to write the contents of the sequence to.
    ///   - offset: The offset into the file to write to, defaults to zero.
    ///   - options: Options for opening the file, defaults to creating a new file.
    ///   - fileSystem: The ``FileSystemProtocol`` instance to use.
    /// - Returns: The number of bytes written to the file.
    @discardableResult
    public func write(
        toFileAt path: NIOFilePath,
        absoluteOffset offset: Int64 = 0,
        options: OpenOptions.Write = .newFile(replaceExisting: false),
        fileSystem: some FileSystemProtocol
    ) async throws -> Int64 {
        try await fileSystem.withFileHandle(forWritingAt: path, options: options) { handle in
            var writer = handle.bufferedWriter(startingAtAbsoluteOffset: offset)
            let bytesWritten = try await writer.write(contentsOf: self)
            try await writer.flush()
            return bytesWritten
        }
    }

    /// Writes the contents of the `AsyncSequence` to a file.
    ///
    /// - Parameters:
    ///   - path: The path of the file to write the contents of the sequence to.
    ///   - offset: The offset into the file to write to, defaults to zero.
    ///   - options: Options for opening the file, defaults to creating a new file.
    /// - Returns: The number of bytes written to the file.
    @discardableResult
    public func write(
        toFileAt path: NIOFilePath,
        absoluteOffset offset: Int64 = 0,
        options: OpenOptions.Write = .newFile(replaceExisting: false)
    ) async throws -> Int64 {
        try await self.write(
            toFileAt: path,
            absoluteOffset: offset,
            options: options,
            fileSystem: .shared
        )
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AsyncSequence where Self.Element == UInt8, Self: Sendable {
    /// Writes the contents of the `AsyncSequence` to a file.
    ///
    /// - Parameters:
    ///   - path: The path of the file to write the contents of the sequence to.
    ///   - offset: The offset into the file to write to, defaults to zero.
    ///   - options: Options for opening the file, defaults to creating a new file.
    ///   - fileSystem: The ``FileSystemProtocol`` instance to use.
    /// - Returns: The number of bytes written to the file.
    @discardableResult
    public func write(
        toFileAt path: NIOFilePath,
        absoluteOffset offset: Int64 = 0,
        options: OpenOptions.Write = .newFile(replaceExisting: false),
        fileSystem: some FileSystemProtocol
    ) async throws -> Int64 {
        try await fileSystem.withFileHandle(forWritingAt: path, options: options) { handle in
            var writer = handle.bufferedWriter(startingAtAbsoluteOffset: offset)
            let bytesWritten = try await writer.write(contentsOf: self)
            try await writer.flush()
            return bytesWritten
        }
    }

    /// Writes the contents of the `AsyncSequence` to a file.
    ///
    /// - Parameters:
    ///   - path: The path of the file to write the contents of the sequence to.
    ///   - offset: The offset into the file to write to, defaults to zero.
    ///   - options: Options for opening the file, defaults to creating a new file.
    /// - Returns: The number of bytes written to the file.
    @discardableResult
    public func write(
        toFileAt path: NIOFilePath,
        absoluteOffset offset: Int64 = 0,
        options: OpenOptions.Write = .newFile(replaceExisting: false)
    ) async throws -> Int64 {
        try await self.write(
            toFileAt: path,
            absoluteOffset: offset,
            options: options,
            fileSystem: .shared
        )
    }
}
