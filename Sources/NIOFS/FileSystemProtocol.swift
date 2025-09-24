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

/// The interface for interacting with a file system.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public protocol FileSystemProtocol: Sendable {
    /// The type of ``ReadableFileHandleProtocol`` to return when opening files for reading.
    associatedtype ReadFileHandle: ReadableFileHandleProtocol

    /// The type of ``WritableFileHandleProtocol`` to return when opening files for writing.
    associatedtype WriteFileHandle: WritableFileHandleProtocol

    /// The type of ``ReadableAndWritableFileHandleProtocol`` to return when opening files for reading and writing.
    associatedtype ReadWriteFileHandle: ReadableAndWritableFileHandleProtocol

    /// The type of ``DirectoryFileHandleProtocol`` to return when opening directories.
    associatedtype DirectoryFileHandle: DirectoryFileHandleProtocol
    where
        DirectoryFileHandle.ReadFileHandle == ReadFileHandle,
        DirectoryFileHandle.ReadWriteFileHandle == ReadWriteFileHandle,
        DirectoryFileHandle.WriteFileHandle == WriteFileHandle

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
    func openFile(
        forReadingAt path: NIOFilePath,
        options: OpenOptions.Read
    ) async throws -> ReadFileHandle

    /// Opens the file at `path` for writing and returns a handle to it.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open relative to the open file.
    ///   - options: How the file should be opened.
    /// - Returns: A writable handle to the opened file.
    func openFile(
        forWritingAt path: NIOFilePath,
        options: OpenOptions.Write
    ) async throws -> WriteFileHandle

    /// Opens the file at `path` for reading and writing and returns a handle to it.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open relative to the open file.
    ///   - options: How the file should be opened.
    func openFile(
        forReadingAndWritingAt path: NIOFilePath,
        options: OpenOptions.Write
    ) async throws -> ReadWriteFileHandle

    /// Opens the directory at `path` and returns a handle to it.
    ///
    /// The directory being opened must already exist otherwise this function will throw an error.
    /// Use ``createDirectory(at:withIntermediateDirectories:permissions:)`` to create directories.
    ///
    /// - Parameters:
    ///   - path: The path of the directory to open.
    ///   - options: How the directory should be opened.
    /// - Returns: A handle to the opened directory.
    func openDirectory(
        atPath path: NIOFilePath,
        options: OpenOptions.Directory
    ) async throws -> DirectoryFileHandle

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
    func createDirectory(
        at path: NIOFilePath,
        withIntermediateDirectories createIntermediateDirectories: Bool,
        permissions: FilePermissions?
    ) async throws

    // MARK: - Common directories

    /// Returns the current working directory.
    var currentWorkingDirectory: NIOFilePath { get async throws }

    /// Returns the path of the temporary directory.
    var temporaryDirectory: NIOFilePath { get async throws }

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
    func createTemporaryDirectory(
        template: NIOFilePath
    ) async throws -> NIOFilePath

    // MARK: - File information

    /// Returns information about the file at the given path, if it exists; nil otherwise.
    ///
    /// - Parameters:
    ///    - path: The path to get information about.
    ///    - infoAboutSymbolicLink: If the file is a symbolic link and this parameter is `true` then
    ///        information about the link will be returned, otherwise information about the
    ///        destination of the symbolic link is returned.
    /// - Returns: Information about the file at the given path or `nil` if no file exists.
    func info(
        forFileAt path: NIOFilePath,
        infoAboutSymbolicLink: Bool
    ) async throws -> FileInfo?

    // MARK: - Symbolic links

    /// Creates a symbolic link that points to the destination.
    ///
    /// If a file or directory exists at `path` then an error is thrown.
    ///
    /// - Parameters:
    ///   - path: The path at which to create the symbolic link.
    ///   - destinationPath: The path that contains the item that the symbolic link points to.`
    func createSymbolicLink(
        at path: NIOFilePath,
        withDestination destinationPath: NIOFilePath
    ) async throws

    /// Returns the path of the item pointed to by a symbolic link.
    ///
    /// - Parameter path: The path of a file or directory.
    /// - Returns: The path of the file or directory to which the symbolic link points to.
    func destinationOfSymbolicLink(
        at path: NIOFilePath
    ) async throws -> NIOFilePath

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
    func copyItem(
        at sourcePath: NIOFilePath,
        to destinationPath: NIOFilePath,
        strategy copyStrategy: CopyStrategy,
        shouldProceedAfterError:
            @escaping @Sendable (
                _ source: DirectoryEntry,
                _ error: Error
            ) async throws -> Void,
        shouldCopyItem:
            @escaping @Sendable (
                _ source: DirectoryEntry,
                _ destination: NIOFilePath
            ) async -> Bool
    ) async throws

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
    func removeItem(
        at path: NIOFilePath,
        strategy removalStrategy: RemovalStrategy,
        recursively removeItemRecursively: Bool
    ) async throws -> Int

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
    func moveItem(at sourcePath: NIOFilePath, to destinationPath: NIOFilePath) async throws

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
    func replaceItem(at destinationPath: NIOFilePath, withItemAt existingPath: NIOFilePath) async throws
}

// MARK: - Open existing files/directories

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FileSystemProtocol {
    /// Opens the file at the given path and provides scoped read-only access to it.
    ///
    /// The file remains open during lifetime of the `execute` block and will be closed
    /// automatically before the call returns. Files may also be opened in read-write or write-only
    /// mode by calling ``FileSystemProtocol/withFileHandle(forReadingAndWritingAt:options:execute:)`` and
    /// ``FileSystemProtocol/withFileHandle(forWritingAt:options:execute:)``.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open for reading.
    ///   - options: How the file should be opened.
    ///   - execute: A closure which provides read-only access to the open file. The file is closed
    ///       automatically after the closure exits.
    /// - Important: The handle passed to `execute` must not escape the closure.
    /// - Returns: The result of the `execute` closure.
    public func withFileHandle<Result>(
        forReadingAt path: NIOFilePath,
        options: OpenOptions.Read = OpenOptions.Read(),
        execute: (_ read: ReadFileHandle) async throws -> Result
    ) async throws -> Result {
        let handle = try await self.openFile(forReadingAt: path, options: options)
        return try await withUncancellableTearDown {
            try await execute(handle)
        } tearDown: { _ in
            try await handle.close()
        }
    }

    /// Opens the file at the given path and provides scoped write-only access to it.
    ///
    /// The file remains open during lifetime of the `execute` block and will be closed
    /// automatically before the call returns. Files may also be opened in read-write or read-only
    /// mode by calling ``FileSystemProtocol/withFileHandle(forReadingAndWritingAt:options:execute:)`` and
    /// ``FileSystemProtocol/withFileHandle(forReadingAt:options:execute:)``.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open for reading.
    ///   - options: How the file should be opened.
    ///   - execute: A closure which provides write-only access to the open file. The file is closed
    ///       automatically after the closure exits.
    /// - Important: The handle passed to `execute` must not escape the closure.
    /// - Returns: The result of the `execute` closure.
    public func withFileHandle<Result>(
        forWritingAt path: NIOFilePath,
        options: OpenOptions.Write = .newFile(replaceExisting: false),
        execute: (_ write: WriteFileHandle) async throws -> Result
    ) async throws -> Result {
        let handle = try await self.openFile(forWritingAt: path, options: options)
        return try await withUncancellableTearDown {
            try await execute(handle)
        } tearDown: { result in
            switch result {
            case .success:
                try await handle.close()
            case .failure:
                try await handle.close(makeChangesVisible: false)
            }
        }
    }

    /// Opens the file at the given path and provides scoped read-write access to it.
    ///
    /// The file remains open during lifetime of the `execute` block and will be closed
    /// automatically before the function returns. Files may also be opened in read-only or
    /// write-only mode by with ``FileSystemProtocol/withFileHandle(forReadingAt:options:execute:)`` and
    /// ``FileSystemProtocol/withFileHandle(forWritingAt:options:execute:)``.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open for reading and writing.
    ///   - options: How the file should be opened.
    ///   - execute: A closure which provides access to the open file. The file is closed
    ///       automatically after the closure exits.
    /// - Important: The handle passed to `execute` must not escape the closure.
    /// - Returns: The result of the `execute` closure.
    public func withFileHandle<Result>(
        forReadingAndWritingAt path: NIOFilePath,
        options: OpenOptions.Write = .newFile(replaceExisting: false),
        execute: (_ readWrite: ReadWriteFileHandle) async throws -> Result
    ) async throws -> Result {
        let handle = try await self.openFile(forReadingAndWritingAt: path, options: options)
        return try await withUncancellableTearDown {
            try await execute(handle)
        } tearDown: { _ in
            try await handle.close()
        }
    }

    /// Opens the directory at the given path and provides scoped access to it.
    ///
    /// - Parameters:
    ///   - path: The path of the directory to open.
    ///   - options: How the file should be opened.
    ///   - execute: A closure which provides access to the directory.
    /// - Important: The handle passed to `execute` must not escape the closure.
    /// - Returns: The result of the `execute` closure.
    public func withDirectoryHandle<Result>(
        atPath path: NIOFilePath,
        options: OpenOptions.Directory = OpenOptions.Directory(),
        execute: (_ directory: DirectoryFileHandle) async throws -> Result
    ) async throws -> Result {
        let handle = try await self.openDirectory(atPath: path, options: options)
        return try await withUncancellableTearDown {
            try await execute(handle)
        } tearDown: { _ in
            try await handle.close()
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FileSystemProtocol {
    /// Opens the file at `path` for reading and returns a handle to it.
    ///
    /// The file being opened must exist otherwise this function will throw a ``FileSystemError``
    /// with code ``FileSystemError/Code-swift.struct/notFound``.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open.
    /// - Returns: A readable handle to the opened file.
    public func openFile(
        forReadingAt path: NIOFilePath
    ) async throws -> ReadFileHandle {
        try await self.openFile(forReadingAt: path, options: OpenOptions.Read())
    }

    /// Opens the directory at `path` and returns a handle to it.
    ///
    /// The directory being opened must already exist otherwise this function will throw an error.
    /// Use ``createDirectory(at:withIntermediateDirectories:permissions:)`` to create directories.
    ///
    /// - Parameters:
    ///   - path: The path of the directory to open.
    /// - Returns: A handle to the opened directory.
    public func openDirectory(
        atPath path: NIOFilePath
    ) async throws -> DirectoryFileHandle {
        try await self.openDirectory(atPath: path, options: OpenOptions.Directory())
    }

    /// Returns information about the file at the given path, if it exists; nil otherwise.
    ///
    /// Calls ``info(forFileAt:infoAboutSymbolicLink:)`` setting `infoAboutSymbolicLink` to `false`.
    ///
    /// - Parameters:
    ///    - path: The path to get information about.
    /// - Returns: Information about the file at the given path or `nil` if no file exists.
    public func info(forFileAt path: NIOFilePath) async throws -> FileInfo? {
        try await self.info(forFileAt: path, infoAboutSymbolicLink: false)
    }

    /// Copies the item at the specified path to a new location.
    ///
    /// The following error codes may be thrown:
    /// - ``FileSystemError/Code-swift.struct/notFound`` if the item at `sourcePath` does not exist,
    /// - ``FileSystemError/Code-swift.struct/invalidArgument`` if an item at `destinationPath`
    ///   exists prior to the copy or its parent directory does not exist.
    ///
    /// Note that other errors may also be thrown. If any error is encountered during the copy
    /// then the copy is aborted. You can modify the behaviour with the `shouldProceedAfterError`
    /// parameter of ``FileSystemProtocol/copyItem(at:to:strategy:shouldProceedAfterError:shouldCopyItem:)``.
    ///
    /// If the file at `sourcePath` is a symbolic link then only the link is copied to the new path.
    ///
    /// - Parameters:
    ///   - sourcePath: The path to the item to copy.
    ///   - destinationPath: The path at which to place the copy.
    ///   - copyStrategy: This controls the concurrency used if the file at `sourcePath` is a directory.
    public func copyItem(
        at sourcePath: NIOFilePath,
        to destinationPath: NIOFilePath,
        strategy copyStrategy: CopyStrategy = .platformDefault
    ) async throws {
        try await self.copyItem(at: sourcePath, to: destinationPath, strategy: copyStrategy) { path, error in
            throw error
        } shouldCopyItem: { source, destination in
            true
        }
    }

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
    ///   - shouldProceedAfterError: A closure which is executed to determine whether to continue
    ///       copying files if an error is encountered during the operation. See Errors section for full details.
    ///   - shouldCopyItem: A closure which is executed before each copy to determine whether each
    ///       item should be copied. See Filtering section for full details
    ///
    /// #### Parallelism
    ///
    /// This overload uses ``CopyStrategy/platformDefault`` which is likely to result in multiple concurrency domains being used
    /// in the event of copying a directory.
    /// See the detailed description on ``copyItem(at:to:strategy:shouldProceedAfterError:shouldCopyItem:)``
    /// for the implications of this with respect to the `shouldProceedAfterError` and `shouldCopyItem` callbacks
    public func copyItem(
        at sourcePath: NIOFilePath,
        to destinationPath: NIOFilePath,
        shouldProceedAfterError:
            @escaping @Sendable (
                _ source: DirectoryEntry,
                _ error: Error
            ) async throws -> Void,
        shouldCopyItem:
            @escaping @Sendable (
                _ source: DirectoryEntry,
                _ destination: NIOFilePath
            ) async -> Bool
    ) async throws {
        try await self.copyItem(
            at: sourcePath,
            to: destinationPath,
            strategy: .platformDefault,
            shouldProceedAfterError: shouldProceedAfterError,
            shouldCopyItem: shouldCopyItem
        )
    }

    /// Deletes the file or directory (and its contents) at `path`.
    ///
    /// The item to be removed must be a regular file, symbolic link or directory. If no file exists
    /// at the given path then this function returns zero.
    ///
    /// If the item at the `path` is a directory then the contents of all of its subdirectories will
    /// be removed recursively before the directory at `path`. Symbolic links are removed (but their
    /// targets are not deleted).
    ///
    /// The strategy for deletion will be determined automatically depending on the discovered
    /// platform.
    ///
    /// - Parameters:
    ///   - path: The path to delete.
    /// - Returns: The number of deleted items which may be zero if `path` did not exist.
    @discardableResult
    public func removeItem(
        at path: NIOFilePath
    ) async throws -> Int {
        try await self.removeItem(at: path, strategy: .platformDefault, recursively: true)
    }

    /// Deletes the file or directory (and its contents) at `path`.
    ///
    /// The item to be removed must be a regular file, symbolic link or directory. If no file exists
    /// at the given path then this function returns zero.
    ///
    /// If the item at the `path` is a directory then the contents of all of its subdirectories will
    /// be removed recursively before the directory at `path`. Symbolic links are removed (but their
    /// targets are not deleted).
    ///
    /// The strategy for deletion will be determined automatically depending on the discovered
    /// platform.
    ///
    /// - Parameters:
    ///   - path: The path to delete.
    ///   - removeItemRecursively: If the item being removed is a directory, remove it by
    ///       recursively removing its children. Setting this to `true` is synonymous with calling
    ///       `rm -r`, setting this false is synonymous to calling `rmdir`. Ignored if the item
    ///       being removed isn't a directory.
    /// - Returns: The number of deleted items which may be zero if `path` did not exist.
    @discardableResult
    public func removeItem(
        at path: NIOFilePath,
        recursively removeItemRecursively: Bool
    ) async throws -> Int {
        try await self.removeItem(at: path, strategy: .platformDefault, recursively: removeItemRecursively)
    }

    /// Deletes the file or directory (and its contents) at `path`.
    ///
    /// The item to be removed must be a regular file, symbolic link or directory. If no file exists
    /// at the given path then this function returns zero.
    ///
    /// If the item at the `path` is a directory then the contents of all of its subdirectories will
    /// be removed recursively before the directory at `path`. Symbolic links are removed (but their
    /// targets are not deleted).
    ///
    /// - Parameters:
    ///   - path: The path to delete.
    ///   - removalStrategy: Whether to delete files sequentially (one-by-one), or perform a
    ///       concurrent scan of the tree at `path` and delete files when they are found.
    /// - Returns: The number of deleted items which may be zero if `path` did not exist.
    @discardableResult
    public func removeItem(
        at path: NIOFilePath,
        strategy removalStrategy: RemovalStrategy
    ) async throws -> Int {
        try await self.removeItem(at: path, strategy: removalStrategy, recursively: true)
    }

    /// Create a directory at the given path.
    ///
    /// If a directory (or file) already exists at `path` then an error will be thrown. If
    /// `createIntermediateDirectories` is `false` then the full prefix of `path` must already
    /// exist. If set to `true` then all intermediate directories will be created.
    ///
    /// New directories will be given read-write-execute owner permissions and read-execute group
    /// and other permissions.
    ///
    /// Related system calls: `mkdir(2)`.
    ///
    /// - Parameters:
    ///   - path: The directory to create.
    ///   - createIntermediateDirectories: Whether intermediate directories should be created.
    public func createDirectory(
        at path: NIOFilePath,
        withIntermediateDirectories createIntermediateDirectories: Bool
    ) async throws {
        try await self.createDirectory(
            at: path,
            withIntermediateDirectories: createIntermediateDirectories,
            permissions: .defaultsForDirectory
        )
    }

    /// Create a temporary directory and removes it once the function returns.
    ///
    /// You can use `prefix` to specify the directory in which the temporary directory should
    /// be created. If `prefix` is `nil` then the value of ``temporaryDirectory`` is used as
    /// the prefix.
    ///
    /// The temporary directory, and all of its contents, is removed once `execute` returns.
    ///
    /// - Parameters:
    ///   - prefix: The prefix to use for the path of the temporary directory.
    ///   - options: Options used to create the directory.
    ///   - execute: A closure which provides access to the directory and its path.
    /// - Returns: The result of `execute`.
    public func withTemporaryDirectory<Result>(
        prefix: NIOFilePath? = nil,
        options: OpenOptions.Directory = OpenOptions.Directory(),
        execute: (_ directory: DirectoryFileHandle, _ path: NIOFilePath) async throws -> Result
    ) async throws -> Result {
        let template: FilePath

        if let prefix = prefix {
            template = prefix.underlying.appending("XXXXXXXX")
        } else {
            template = try await self.temporaryDirectory.underlying.appending("XXXXXXXX")
        }

        let directory = try await self.createTemporaryDirectory(template: NIOFilePath(template))
        return try await withUncancellableTearDown {
            try await withDirectoryHandle(atPath: directory, options: options) { handle in
                try await execute(handle, directory)
            }
        } tearDown: { _ in
            try await self.removeItem(at: directory, strategy: .platformDefault, recursively: true)
        }
    }
}
