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
        forReadingAt path: FilePath,
        options: OpenOptions.Read
    ) async throws -> ReadFileHandle

    /// Opens the file at `path` for writing and returns a handle to it.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open relative to the open file.
    ///   - options: How the file should be opened.
    /// - Returns: A writable handle to the opened file.
    func openFile(
        forWritingAt path: FilePath,
        options: OpenOptions.Write
    ) async throws -> WriteFileHandle

    /// Opens the file at `path` for reading and writing and returns a handle to it.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open relative to the open file.
    ///   - options: How the file should be opened.
    func openFile(
        forReadingAndWritingAt path: FilePath,
        options: OpenOptions.Write
    ) async throws -> ReadWriteFileHandle

    /// Opens the directory at `path` and returns a handle to it.
    ///
    /// The directory being opened must already exist otherwise this function will throw an error.
    /// Use ``createDirectory(at:withIntermediateDirectories:permissions:)`` to create directories.
    ///
    /// - Parameters:
    ///   - path: The path of the directory to open.
    /// - Returns: A handle to the opened directory.
    func openDirectory(
        atPath path: FilePath,
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
        at path: FilePath,
        withIntermediateDirectories createIntermediateDirectories: Bool,
        permissions: FilePermissions?
    ) async throws

    // MARK: - Common directories

    /// Returns the current working directory.
    var currentWorkingDirectory: FilePath { get async throws }

    /// Returns the path of the temporary directory.
    var temporaryDirectory: FilePath { get async throws }

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
        template: FilePath
    ) async throws -> FilePath

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
        forFileAt path: FilePath,
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
        at path: FilePath,
        withDestination destinationPath: FilePath
    ) async throws

    /// Returns the path of the item pointed to by a symbolic link.
    ///
    /// - Parameter path: The path of a file or directory.
    /// - Returns: The path of the file or directory to which the symbolic link points to.
    func destinationOfSymbolicLink(
        at path: FilePath
    ) async throws -> FilePath

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
    /// If the file at `sourcePath` is a symbolic link then only the link is copied to the new path.
    ///
    /// - Parameters:
    ///   - sourcePath: The path to the item to copy.
    ///   - destinationPath: The path at which to place the copy.
    ///   - shouldProceedAfterError: A closure which is executed to determine whether to continue
    ///       copying files if an error is encountered during the operation.
    ///   - shouldCopyFile: A closure which is executed before each copy to determine whether each
    ///       file should be copied.
    func copyItem(
        at sourcePath: FilePath,
        to destinationPath: FilePath,
        shouldProceedAfterError: @escaping @Sendable (
            _ path: DirectoryEntry,
            _ error: Error
        ) async throws -> Void,
        shouldCopyFile: @escaping @Sendable (
            _ source: FilePath,
            _ destination: FilePath
        ) async -> Bool
    ) async throws

    /// Deletes the file or directory (and its contents) at `path`.
    ///
    /// The item to be removed must be a regular file, symbolic link or directory. If no file exists
    /// at the given path then this function returns zero.
    ///
    /// If the item at the `path` is a directory and `removeItemRecursively` is `true` then the
    /// contents of all of its subdirectories will be removed recursively before the directory
    /// at `path`. Symbolic links are removed (but their targets are not deleted).
    ///
    /// - Parameters:
    ///   - path: The path to delete.
    ///   - removeItemRecursively: If the item being removed is a directory, remove it by
    ///       recursively removing its children. Setting this to `true` is synonymous with
    ///       calling `rm -r`, setting this false is synonymous to calling `rmdir`. Ignored if
    ///       the item being removed isn't a directory.
    /// - Returns: The number of deleted items which may be zero if `path` did not exist.
    @discardableResult
    func removeItem(
        at path: FilePath,
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
    func moveItem(at sourcePath: FilePath, to destinationPath: FilePath) async throws

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
    func replaceItem(at destinationPath: FilePath, withItemAt existingPath: FilePath) async throws
}

// MARK: - Open existing files/directories

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FileSystemProtocol {
    /// Opens the file at the given path and provides scoped read-only access to it.
    ///
    /// The file remains open during lifetime of the `execute` block and will be closed
    /// automatically before the call returns. Files may also be opened in read-write or write-only
    /// mode by calling ``withFileHandle(forReadingAndWritingAt:options:execute:)`` and
    /// ``withFileHandle(forWritingAt:options:execute:)``.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open for reading.
    ///   - options: How the file should be opened.
    ///   - execute: A closure which provides read-only access to the open file. The file is closed
    ///       automatically after the closure exits.
    /// - Important: The handle passed to `execute` must not escape the closure.
    /// - Returns: The result of the `execute` closure.
    public func withFileHandle<R: Sendable>(
        forReadingAt path: FilePath,
        options: OpenOptions.Read = OpenOptions.Read(),
        execute: (_ read: ReadFileHandle) async throws -> R
    ) async throws -> R {
        let handle = try await self.openFile(forReadingAt: path, options: options)
        return try await withUncancellableTearDown {
            return try await execute(handle)
        } tearDown: { _ in
            try await handle.close()
        }
    }

    /// Opens the file at the given path and provides scoped write-only access to it.
    ///
    /// The file remains open during lifetime of the `execute` block and will be closed
    /// automatically before the call returns. Files may also be opened in read-write or read-only
    /// mode by calling ``withFileHandle(forReadingAndWritingAt:options:execute:)`` and
    /// ``withFileHandle(forReadingAt:options:execute:)``.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open for reading.
    ///   - options: How the file should be opened.
    ///   - execute: A closure which provides write-only access to the open file. The file is closed
    ///       automatically after the closure exits.
    /// - Important: The handle passed to `execute` must not escape the closure.
    /// - Returns: The result of the `execute` closure.
    public func withFileHandle<R: Sendable>(
        forWritingAt path: FilePath,
        options: OpenOptions.Write = .newFile(replaceExisting: false),
        execute: (_ write: WriteFileHandle) async throws -> R
    ) async throws -> R {
        let handle = try await self.openFile(forWritingAt: path, options: options)
        return try await withUncancellableTearDown {
            return try await execute(handle)
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
    /// write-only mode by with ``withFileHandle(forReadingAt:options:execute:)`` and
    /// ``withFileHandle(forWritingAt:options:execute:)``.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open for reading and writing.
    ///   - options: How the file should be opened.
    ///   - execute: A closure which provides access to the open file. The file is closed
    ///       automatically after the closure exits.
    /// - Important: The handle passed to `execute` must not escape the closure.
    /// - Returns: The result of the `execute` closure.
    public func withFileHandle<R: Sendable>(
        forReadingAndWritingAt path: FilePath,
        options: OpenOptions.Write = .newFile(replaceExisting: false),
        execute: (_ readWrite: ReadWriteFileHandle) async throws -> R
    ) async throws -> R {
        let handle = try await self.openFile(forReadingAndWritingAt: path, options: options)
        return try await withUncancellableTearDown {
            return try await execute(handle)
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
    public func withDirectoryHandle<R: Sendable>(
        atPath path: FilePath,
        options: OpenOptions.Directory = OpenOptions.Directory(),
        execute: (_ directory: DirectoryFileHandle) async throws -> R
    ) async throws -> R {
        let handle = try await self.openDirectory(atPath: path, options: options)
        return try await withUncancellableTearDown {
            return try await execute(handle)
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
        forReadingAt path: FilePath
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
        atPath path: FilePath
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
    public func info(forFileAt path: FilePath) async throws -> FileInfo? {
        return try await self.info(forFileAt: path, infoAboutSymbolicLink: false)
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
    /// parameter of ``copyItem(at:to:shouldProceedAfterError:shouldCopyFile:)``.
    ///
    /// If the file at `sourcePath` is a symbolic link then only the link is copied to the new path.
    ///
    /// - Parameters:
    ///   - sourcePath: The path to the item to copy.
    ///   - destinationPath: The path at which to place the copy.
    public func copyItem(at sourcePath: FilePath, to destinationPath: FilePath) async throws {
        try await self.copyItem(at: sourcePath, to: destinationPath) { entry, error in
            throw error
        } shouldCopyFile: { source, destination in
            return true
        }
    }

    /// Deletes the file or directory (and its contents) at `path`.
    ///
    /// The item to be removed must be a regular file, symbolic link or directory. If no file exists
    /// at the given path then this function returns zero.
    ///
    /// If the item at the `path` is a directory then the contents of all of its subdirectories
    /// will be removed recursively before the directory at `path`. Symbolic links are removed (but
    /// their targets are not deleted).
    ///
    /// - Parameters:
    ///   - path: The path to delete.
    /// - Returns: The number of deleted items which may be zero if `path` did not exist.
    @discardableResult
    public func removeItem(
        at path: FilePath
    ) async throws -> Int {
        try await self.removeItem(at: path, recursively: true)
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
        at path: FilePath,
        withIntermediateDirectories createIntermediateDirectories: Bool
    ) async throws {
        try await self.createDirectory(
            at: path,
            withIntermediateDirectories: createIntermediateDirectories,
            permissions: .defaultsForDirectory
        )
    }
}

#endif
