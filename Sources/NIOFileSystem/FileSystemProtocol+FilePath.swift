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

/// This extension provides implementations of ``FileSystemProtocol`` methods that accept/return ``FilePath`` instead of
/// ``NIOFilePath``.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FileSystemProtocol {
    // MARK: - File access

    /// Opens the file at `path` for reading and returns a handle to it.
    ///
    /// The file being opened must exist otherwise this function will throw a ``FileSystemError``
    /// with code ``FileSystemError/Code-swift.struct/notFound``.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open.
    ///   - options: How the file should be opened.
    /// - Returns: A readable handle to the opened file.
    @_disfavoredOverload
    public func openFile(
        forReadingAt path: FilePath,
        options: OpenOptions.Read
    ) async throws -> ReadFileHandle {
        try await self.openFile(forReadingAt: .init(path), options: options)
    }

    /// Opens the file at `path` for writing and returns a handle to it.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open relative to the open file.
    ///   - options: How the file should be opened.
    /// - Returns: A writable handle to the opened file.
    @_disfavoredOverload
    public func openFile(
        forWritingAt path: FilePath,
        options: OpenOptions.Write
    ) async throws -> WriteFileHandle {
        try await self.openFile(forWritingAt: .init(path), options: options)
    }

    /// Opens the file at `path` for reading and writing and returns a handle to it.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open relative to the open file.
    ///   - options: How the file should be opened.
    @_disfavoredOverload
    public func openFile(
        forReadingAndWritingAt path: FilePath,
        options: OpenOptions.Write
    ) async throws -> ReadWriteFileHandle {
        try await self.openFile(forReadingAndWritingAt: .init(path), options: options)
    }

    /// Opens the directory at `path` and returns a handle to it.
    ///
    /// The directory being opened must already exist otherwise this function will throw an error.
    /// Use ``createDirectory(at:withIntermediateDirectories:permissions:)`` to create directories.
    ///
    /// - Parameters:
    ///   - path: The path of the directory to open.
    ///   - options: How the directory should be opened.
    /// - Returns: A handle to the opened directory.
    @_disfavoredOverload
    public func openDirectory(
        atPath path: FilePath,
        options: OpenOptions.Directory
    ) async throws -> DirectoryFileHandle {
        try await self.openDirectory(atPath: .init(path), options: options)
    }

    /// Create a directory at the given path.
    ///
    /// If a directory (or file) already exists at `path` then an error will be thrown. If
    /// `createIntermediateDirectories` is `false` then the full prefix of `path` must already
    /// exist. If set to `true` then all intermediate directories will be created.
    ///
    /// Related system calls: `mkdir(2)`.
    ///
    /// - Parameters:
    ///   - path: The directory to create.
    ///   - createIntermediateDirectories: Whether intermediate directories should be created.
    ///   - permissions: The permissions to set on the new directory; default permissions will be
    ///       used if not specified.
    @_disfavoredOverload
    public func createDirectory(
        at path: FilePath,
        withIntermediateDirectories createIntermediateDirectories: Bool,
        permissions: FilePermissions?
    ) async throws {
        try await self.createDirectory(
            at: .init(path),
            withIntermediateDirectories: createIntermediateDirectories,
            permissions: permissions
        )
    }

    // MARK: - Common directories

    /// Returns the current working directory.
    var currentWorkingDirectory: FilePath {
        get async throws {
            try await self.currentWorkingDirectory
        }
    }

    /// Returns the path of the temporary directory.
    var temporaryDirectory: FilePath {
        get async throws {
            try await self.temporaryDirectory
        }
    }

    /// Create a temporary directory at the given path, from a template.
    ///
    /// The template for the path of the temporary directory must end in at least
    /// three 'X's, which will be replaced with a unique alphanumeric combination.
    /// The template can contain intermediary directories which will be created
    /// if they do not exist already.
    ///
    /// Related system calls: `mkdir(2)`.
    ///
    /// - Parameters:
    ///   - template: The template for the path of the temporary directory.
    /// - Returns:
    ///   - The path to the new temporary directory.
    @_disfavoredOverload
    public func createTemporaryDirectory(
        template: FilePath
    ) async throws -> FilePath {
        let result = try await self.createTemporaryDirectory(template: .init(template))
        return .init(result)
    }

    // MARK: - File information

    /// Returns information about the file at the given path, if it exists; nil otherwise.
    ///
    /// - Parameters:
    ///    - path: The path to get information about.
    ///    - infoAboutSymbolicLink: If the file is a symbolic link and this parameter is `true` then
    ///        information about the link will be returned, otherwise information about the
    ///        destination of the symbolic link is returned.
    /// - Returns: Information about the file at the given path or `nil` if no file exists.
    @_disfavoredOverload
    public func info(
        forFileAt path: FilePath,
        infoAboutSymbolicLink: Bool
    ) async throws -> FileInfo? {
        try await self.info(forFileAt: .init(path), infoAboutSymbolicLink: infoAboutSymbolicLink)
    }

    // MARK: - Symbolic links

    /// Creates a symbolic link that points to the destination.
    ///
    /// If a file or directory exists at `path` then an error is thrown.
    ///
    /// - Parameters:
    ///   - path: The path at which to create the symbolic link.
    ///   - destinationPath: The path that contains the item that the symbolic link points to.`
    @_disfavoredOverload
    public func createSymbolicLink(
        at path: FilePath,
        withDestination destinationPath: FilePath
    ) async throws {
        try await self.createSymbolicLink(at: .init(path), withDestination: .init(destinationPath))
    }

    /// Returns the path of the item pointed to by a symbolic link.
    ///
    /// - Parameter path: The path of a file or directory.
    /// - Returns: The path of the file or directory to which the symbolic link points to.
    @_disfavoredOverload
    public func destinationOfSymbolicLink(
        at path: FilePath
    ) async throws -> FilePath {
        let result = try await self.destinationOfSymbolicLink(at: .init(path))
        return .init(result)
    }

    // MARK: - File copying, removal, and moving

    /// Copies the item at the specified path to a new location.
    ///
    /// The following error codes may be thrown:
    /// - ``FileSystemError/Code-swift.struct/notFound`` if the item at `sourcePath` does not exist,
    /// - ``FileSystemError/Code-swift.struct/invalidArgument`` if an item at `destinationPath`
    ///   exists prior to the copy or its parent directory does not exist.
    ///
    /// Note that other errors may also be thrown.
    ///
    /// If `sourcePath` is a symbolic link then only the link is copied. The copied file will
    /// preserve permissions and any extended attributes (if supported by the file system).
    ///
    /// - Parameters:
    ///   - sourcePath: The path to the item to copy.
    ///   - destinationPath: The path at which to place the copy.
    ///   - copyStrategy: How to deal with concurrent aspects of the copy, only relevant to directories.
    ///   - shouldProceedAfterError: A closure which is executed to determine whether to continue
    ///       copying files if an error is encountered during the operation. See Errors section for full details.
    ///   - shouldCopyItem: A closure which is executed before each copy to determine whether each
    ///       item should be copied. See Filtering section for full details
    ///
    /// #### Errors
    ///
    /// No errors should be throw by implementors without first calling `shouldProceedAfterError`,
    /// if that returns without throwing this is taken as permission to continue and the error is swallowed.
    /// If instead the closure throws then ``copyItem(at:to:strategy:shouldProceedAfterError:shouldCopyItem:)``
    ///  will throw and copying will stop, though the precise semantics of this can depend on the `strategy`.
    ///
    /// if using ``CopyStrategy/parallel(maxDescriptors:)``
    /// Already started work may continue for an indefinite period of time. In particular, after throwing an error
    /// it is possible that invocations of `shouldCopyItem` may continue to occur!
    ///
    /// If using ``CopyStrategy/sequential`` only one invocation of any of the `should*` closures will occur at a time,
    /// and an error will immediately stop further activity.
    ///
    /// The specific error thrown from copyItem is undefined, it does not have to be the same error thrown from
    /// `shouldProceedAfterError`.
    /// In the event of any errors (ignored or otherwise) implementations are under no obbligation to
    /// attempt to 'tidy up' after themselves. The state of the file system within `destinationPath`
    /// after an aborted copy should is undefined.
    ///
    /// When calling `shouldProceedAfterError` implementations of this method
    /// MUST:
    ///  - Do so once and only once per item.
    ///  - Not hold any locks when doing so.
    /// MAY:
    ///  - invoke the function multiple times concurrently (except when using ``CopyStrategy/sequential``)
    ///
    /// #### Filtering
    ///
    /// When invoking `shouldCopyItem` implementations of this method
    /// MUST:
    ///  - Do so once and only once per item.
    ///  - Do so before attempting any operations related to the copy (including determining if they can do so).
    ///  - Not hold any locks when doing so.
    ///  - Check parent directories *before* items within them,
    ///     * if a parent is ignored no items within it should be considered or checked
    ///  - Skip all contents of a directory which is filtered out.
    ///  - Invoke it for the `sourcePath` itself.
    /// MAY:
    ///  - invoke the function multiple times concurrently (except when using ``CopyStrategy/sequential``)
    ///  - invoke the function an arbitrary point before actually trying to copy the file
    @_disfavoredOverload
    public func copyItem(
        at sourcePath: FilePath,
        to destinationPath: FilePath,
        strategy copyStrategy: CopyStrategy,
        shouldProceedAfterError:
            @escaping @Sendable (
                _ source: DirectoryEntry,
                _ error: Error
            ) async throws -> Void,
        shouldCopyItem:
            @escaping @Sendable (
                _ source: DirectoryEntry,
                _ destination: FilePath
            ) async -> Bool
    ) async throws {
        try await self.copyItem(
            at: .init(sourcePath),
            to: .init(destinationPath),
            strategy: copyStrategy,
            shouldProceedAfterError: shouldProceedAfterError
        ) { (source: DirectoryEntry, destination: NIOFilePath) in
            await shouldCopyItem(source, .init(destination))
        }
    }

    /// Deletes the file or directory (and its contents) at `path`.
    ///
    /// The item to be removed must be a regular file, symbolic link or directory. If no file exists
    /// at the given path then this function returns zero.
    ///
    /// If the item at the `path` is a directory and `removeItemRecursively` is `true` then the
    /// contents of all of its subdirectories will be removed recursively before the directory at
    /// `path`. Symbolic links are removed (but their targets are not deleted).
    ///
    /// - Parameters:
    ///   - path: The path to delete.
    ///   - removalStrategy: Whether to delete files sequentially (one-by-one), or perform a
    ///       concurrent scan of the tree at `path` and delete files when they are found. Ignored if
    ///       the item being removed isn't a directory.
    ///   - removeItemRecursively: If the item being removed is a directory, remove it by
    ///       recursively removing its children. Setting this to `true` is synonymous with calling
    ///       `rm -r`, setting this false is synonymous to calling `rmdir`. Ignored if the item
    ///       being removed isn't a directory.
    /// - Returns: The number of deleted items which may be zero if `path` did not exist.
    @discardableResult
    @_disfavoredOverload
    public func removeItem(
        at path: FilePath,
        strategy removalStrategy: RemovalStrategy,
        recursively removeItemRecursively: Bool
    ) async throws -> Int {
        try await self.removeItem(at: .init(path), strategy: removalStrategy, recursively: removeItemRecursively)
    }

    /// Moves the file or directory at the specified path to a new location.
    ///
    /// The following error codes may be thrown:
    /// - ``FileSystemError/Code-swift.struct/notFound`` if the item at `sourcePath` does not exist,
    /// - ``FileSystemError/Code-swift.struct/invalidArgument`` if an item at `destinationPath`
    ///   exists prior to the copy or its parent directory does not exist.
    ///
    /// Note that other errors may also be thrown.
    ///
    /// If the file at `sourcePath` is a symbolic link then only the link is moved to the new path.
    ///
    /// - Parameters:
    ///   - sourcePath: The path to the item to move.
    ///   - destinationPath: The path at which to place the item.
    @_disfavoredOverload
    public func moveItem(at sourcePath: FilePath, to destinationPath: FilePath) async throws {
        try await self.moveItem(at: .init(sourcePath), to: .init(destinationPath))
    }

    /// Replaces the item at `destinationPath` with the item at `existingPath`.
    ///
    /// The following error codes may be thrown:
    /// - ``FileSystemError/Code-swift.struct/notFound`` if the item at `existingPath` does
    ///    not exist,
    /// - ``FileSystemError/Code-swift.struct/io`` if the file at `existingPath` was successfully
    ///    copied to `destinationPath` but an error occurred while removing it from `existingPath.`
    ///
    /// Note that other errors may also be thrown.
    ///
    /// The item at `destinationPath` is not required to exist. Note that it is possible to replace
    /// a file with a directory and vice versa. After the file or directory at `destinationPath`
    /// has been replaced, the item at `existingPath` will be removed.
    ///
    /// - Parameters:
    ///   - destinationPath: The path of the file or directory to replace.
    ///   - existingPath: The path of the existing file or directory.
    @_disfavoredOverload
    public func replaceItem(at destinationPath: FilePath, withItemAt existingPath: FilePath) async throws {
        try await self.replaceItem(at: .init(destinationPath), withItemAt: .init(existingPath))
    }
}
