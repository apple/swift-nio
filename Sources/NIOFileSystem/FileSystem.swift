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

import Atomics
import NIOCore
@preconcurrency import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A file system which interacts with the local system. The file system uses a thread pool to
/// perform system calls.
///
/// ### Creating a `FileSystem`
///
/// You should prefer using the `shared` instance of the file system. The
/// `shared` instance uses two threads unless the `SWIFT_FILE_SYSTEM_THREAD_COUNT`
/// environment variable is set.
///
/// If you require more granular control you can create a ``FileSystem`` with the required number
/// of threads by calling ``withFileSystem(numberOfThreads:_:)``.
///
/// ### Errors
///
/// Errors thrown by ``FileSystem`` will be of type:
/// - ``FileSystemError`` if it wasn't possible to complete the operation, or
/// - `CancellationError` if the `Task` was cancelled.
///
/// ``FileSystemError`` implements `CustomStringConvertible`. The output from the `description`
/// contains basic information including the error code, message and underlying error. You can get
/// more information about the error by calling ``FileSystemError/detailedDescription()`` which
/// returns a structured multi-line string containing information about the error.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct FileSystem: Sendable, FileSystemProtocol {
    /// Returns a shared global instance of the ``FileSystem``.
    ///
    /// The file system executes blocking work in a thread pool which defaults to having two
    /// threads. This can be modified by `fileSystemThreadCountSuggestion` or by
    /// setting the `NIO_SINGLETON_FILESYSTEM_THREAD_COUNT` environment variable.
    public static var shared: FileSystem { globalFileSystem }

    private let executor: IOExecutor

    fileprivate func shutdown() async {
        await self.executor.drain()
    }

    fileprivate init(executor: IOExecutor) {
        self.executor = executor
    }

    fileprivate init(numberOfThreads: Int) async {
        let executor = await IOExecutor.running(numberOfThreads: numberOfThreads)
        self.init(executor: executor)
    }

    /// Open the file at `path` for reading.
    ///
    /// #### Errors
    ///
    /// Error codes thrown include:
    /// - ``FileSystemError/Code-swift.struct/notFound`` if `path` doesn't exist.
    ///
    /// #### Implementation details
    ///
    /// Uses the `open(2)` system call.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open.
    ///   - options: How the file should be opened.
    /// - Returns: A readable handle to the opened file.
    public func openFile(
        forReadingAt path: FilePath,
        options: OpenOptions.Read
    ) async throws -> ReadFileHandle {
        let handle = try await self.executor.execute {
            let handle = try self._openFile(forReadingAt: path, options: options).get()
            // Okay to transfer: we just created it and are now moving back to the callers task.
            return UnsafeTransfer(handle)
        }
        return handle.wrappedValue
    }

    /// Open the file at `path` for writing.
    ///
    /// #### Errors
    ///
    /// Error codes thrown include:
    /// - ``FileSystemError/Code-swift.struct/permissionDenied`` if you have insufficient
    ///   permissions to create the file.
    /// - ``FileSystemError/Code-swift.struct/notFound`` if `path` doesn't exist and `options`
    ///   weren't set to create a file.
    ///
    /// #### Implementation details
    ///
    /// Uses the `open(2)` system call.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open.
    ///   - options: How the file should be opened.
    /// - Returns: A writable handle to the opened file.
    public func openFile(
        forWritingAt path: FilePath,
        options: OpenOptions.Write
    ) async throws -> WriteFileHandle {
        let handle = try await self.executor.execute {
            let handle = try self._openFile(forWritingAt: path, options: options).get()
            // Okay to transfer: we just created it and are now moving back to the callers task.
            return UnsafeTransfer(handle)
        }
        return handle.wrappedValue
    }

    /// Open the file at `path` for reading and writing.
    ///
    /// #### Errors
    ///
    /// Error codes thrown include:
    /// - ``FileSystemError/Code-swift.struct/permissionDenied`` if you have insufficient
    ///   permissions to create the file.
    /// - ``FileSystemError/Code-swift.struct/notFound`` if `path` doesn't exist and `options`
    ///   weren't set to create a file.
    ///
    /// #### Implementation details
    ///
    /// Uses the `open(2)` system call.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open.
    ///   - options: How the file should be opened.
    /// - Returns: A readable and writable handle to the opened file.
    public func openFile(
        forReadingAndWritingAt path: FilePath,
        options: OpenOptions.Write
    ) async throws -> ReadWriteFileHandle {
        let handle = try await self.executor.execute {
            let handle = try self._openFile(forReadingAndWritingAt: path, options: options).get()
            // Okay to transfer: we just created it and are now moving back to the callers task.
            return UnsafeTransfer(handle)
        }
        return handle.wrappedValue
    }

    /// Open the directory at `path`.
    ///
    /// #### Errors
    ///
    /// Error codes thrown include:
    /// - ``FileSystemError/Code-swift.struct/notFound`` if `path` doesn't exist.
    ///
    /// #### Implementation details
    ///
    /// Uses the `open(2)` system call.
    ///
    /// - Parameters:
    ///   - path: The path of the directory to open.
    /// - Returns: A handle to the opened directory.
    public func openDirectory(
        atPath path: FilePath,
        options: OpenOptions.Directory
    ) async throws -> DirectoryFileHandle {
        let handle = try await self.executor.execute {
            let handle = try self._openDirectory(at: path, options: options).get()
            // Okay to transfer: we just created it and are now moving back to the callers task.
            return UnsafeTransfer(handle)
        }
        return handle.wrappedValue
    }

    /// Create a directory at the given path.
    ///
    /// If a directory (or file) already exists at `path` a ``FileSystemError`` with code
    /// ``FileSystemError/Code-swift.struct/fileAlreadyExists`` is thrown.
    ///
    /// If the parent directory of the directory to created does not exist a ``FileSystemError``
    /// with ``FileSystemError/Code-swift.struct/invalidArgument`` is thrown. Missing directories
    /// can be created by passing `true` to `createIntermediateDirectories`.
    ///
    /// #### Errors
    ///
    /// Error codes thrown include:
    /// - ``FileSystemError/Code-swift.struct/fileAlreadyExists`` if a file or directory already
    ///   exists .
    /// - ``FileSystemError/Code-swift.struct/invalidArgument`` if a component in the `path`
    ///   prefix does not exist and `createIntermediateDirectories` is `false`.
    ///
    /// #### Implementation details
    ///
    /// Uses the `mkdir(2)` system call.
    ///
    /// - Parameters:
    ///   - path: The directory to create.
    ///   - createIntermediateDirectories: Whether intermediate directories should be created.
    ///   - permissions: The permissions to set on the new directory; default permissions will be
    ///       used if not specified.
    public func createDirectory(
        at path: FilePath,
        withIntermediateDirectories createIntermediateDirectories: Bool,
        permissions: FilePermissions?
    ) async throws {
        try await self.executor.execute {
            try self._createDirectory(
                at: path,
                withIntermediateDirectories: createIntermediateDirectories,
                permissions: permissions ?? .defaultsForDirectory
            ).get()
        }
    }

    /// Create a temporary directory at the given path, using a template.
    ///
    /// #### Errors
    ///
    /// Error codes thrown include:
    /// - ``FileSystemError/Code-swift.struct/invalidArgument`` if the template doesn't end
    ///   in at least 3 'X's.
    /// - ``FileSystemError/Code-swift.struct/permissionDenied`` if the user doesn't have
    ///  permission to create a directory at the path specified in the template.
    ///
    /// #### Implementation details
    ///
    /// Uses the `mkdir(2)` system call.
    ///
    /// - Parameters:
    ///   - template: The template for the path of the temporary directory.
    /// - Returns:
    ///   - The path to the new temporary directory.
    public func createTemporaryDirectory(
        template: FilePath
    ) async throws -> FilePath {
        return try await self.executor.execute {
            try self._createTemporaryDirectory(template: template).get()
        }
    }

    /// Returns information about the file at `path` if it exists; nil otherwise.
    ///
    /// #### Implementation details
    ///
    /// Uses `lstat(2)` if `infoAboutSymbolicLink` is `true`, `stat(2)` otherwise.
    ///
    /// - Parameters:
    ///    - path: The path of the file.
    ///    - infoAboutSymbolicLink: If the file is a symbolic link and this parameter is `true` then information
    ///        about the link will be returned, otherwise information about the destination of the
    ///        symbolic link is returned.
    /// - Returns: Information about the file at the given path or `nil` if no file exists.
    public func info(
        forFileAt path: FilePath,
        infoAboutSymbolicLink: Bool
    ) async throws -> FileInfo? {
        return try await self.executor.execute {
            try self._info(forFileAt: path, infoAboutSymbolicLink: infoAboutSymbolicLink).get()
        }
    }

    // MARK: - File copying, removal, and moving

    /// Copies the item at the specified path to a new location.
    ///
    /// The item to be copied must be a:
    /// - regular file,
    /// - symbolic link, or
    /// - directory.
    ///
    /// If `sourcePath` is a symbolic link then only the link is copied. The copied file will
    /// preserve permissions and any extended attributes (if supported by the file system).
    ///
    /// #### Errors
    ///
    /// Error codes thrown include:
    /// - ``FileSystemError/Code-swift.struct/notFound`` if `sourcePath` doesn't exist.
    /// - ``FileSystemError/Code-swift.struct/fileAlreadyExists`` if `destinationPath` exists.
    /// - ``FileSystemError/Code-swift.struct/unsupported`` if an item to be copied is not a
    ///   regular file, symbolic link or directory.
    ///
    /// #### Implementation details
    ///
    /// This function is platform dependent. On Darwin the `copyfile(2)` system call is
    /// used and items are cloned where possible. On Linux the `sendfile(2)` system call is used.
    ///
    /// - Parameters:
    ///   - sourcePath: The path to the item to copy.
    ///   - destinationPath: The path at which to place the copy.
    ///   - shouldProceedAfterError: Determines whether to continue copying files if an error is
    ///       thrown during the operation. This error does not have to match the error passed
    ///       to the closure.
    ///   - shouldCopyFile: A closure which is executed before each file to determine whether the
    ///       file should be copied.
    public func copyItem(
        at sourcePath: FilePath,
        to destinationPath: FilePath,
        shouldProceedAfterError: @escaping @Sendable (
            _ entry: DirectoryEntry,
            _ error: Error
        ) async throws -> Void,
        shouldCopyFile: @escaping @Sendable (
            _ source: FilePath,
            _ destination: FilePath
        ) async -> Bool
    ) async throws {
        guard let info = try await self.info(forFileAt: sourcePath, infoAboutSymbolicLink: true)
        else {
            throw FileSystemError(
                code: .notFound,
                message: "Unable to copy '\(sourcePath)', it does not exist.",
                cause: nil,
                location: .here()
            )
        }

        switch info.type {
        case .regular:
            if await shouldCopyFile(sourcePath, destinationPath) {
                try await self.copyRegularFile(from: sourcePath, to: destinationPath)
            }

        case .symlink:
            if await shouldCopyFile(sourcePath, destinationPath) {
                try await self.copySymbolicLink(from: sourcePath, to: destinationPath)
            }

        case .directory:
            if await shouldCopyFile(sourcePath, destinationPath) {
                try await self.copyDirectory(
                    from: sourcePath,
                    to: destinationPath,
                    shouldProceedAfterError: shouldProceedAfterError,
                    shouldCopyFile: shouldCopyFile
                )
            }

        default:
            throw FileSystemError(
                code: .unsupported,
                message: """
                    Can't copy '\(sourcePath)' of type '\(info.type)'; only regular files, \
                    symbolic links and directories can be copied.
                    """,
                cause: nil,
                location: .here()
            )
        }
    }

    /// Deletes the file or directory (and its contents) at `path`.
    ///
    /// Only regular files, symbolic links and directories may be removed. If the file at `path` is
    /// a directory then its contents and all of its subdirectories will be removed recursively.
    /// Symbolic links are also removed (but their targets are not deleted). If no file exists at
    /// `path` this function returns zero.
    ///
    /// #### Errors
    ///
    /// Errors codes thrown by this function include:
    /// - ``FileSystemError/Code-swift.struct/invalidArgument`` if the item is not a regular file,
    ///   symbolic link or directory. This also applies to items within the directory being removed.
    /// - ``FileSystemError/Code-swift.struct/notFound`` if the item being removed is a directory
    ///   which isn't empty and `removeItemRecursively` is false.
    ///
    /// #### Implementation details
    ///
    /// Uses the `remove(3)` system call.
    ///
    /// - Parameters:
    ///   - path: The path to delete.
    /// - Returns: The number of deleted items which may be zero if `path` did not exist.
    @discardableResult
    public func removeItem(
        at path: FilePath,
        recursively removeItemRecursively: Bool
    ) async throws -> Int {
        // Try to remove the item: we might just get lucky.
        let result = try await self.executor.execute { Libc.remove(path) }

        switch result {
        case .success:
            // Great; we removed 1 whole item.
            return 1

        case .failure(.noSuchFileOrDirectory):
            // Nothing to delete.
            return 0

        case .failure(.directoryNotEmpty):
            guard removeItemRecursively else {
                throw FileSystemError(
                    code: .notEmpty,
                    message: """
                        Can't remove directory at path '\(path)', it isn't empty and \
                        'removeItemRecursively' is false. Remove items from the directory first \
                        or set 'removeItemRecursively' to true when calling \
                        'removeItem(at:recursively:)'.
                        """,
                    cause: nil,
                    location: .here()
                )
            }

            var (subdirectories, filesRemoved) = try await self.withDirectoryHandle(
                atPath: path
            ) { directory in
                var subdirectories = [FilePath]()
                var filesRemoved = 0

                for try await batch in directory.listContents().batched() {
                    for entry in batch {
                        switch entry.type {
                        case .directory:
                            subdirectories.append(entry.path)

                        default:
                            filesRemoved += try await self.removeOneItem(at: entry.path)
                        }
                    }
                }

                return (subdirectories, filesRemoved)
            }

            for subdirectory in subdirectories {
                filesRemoved += try await self.removeItem(at: subdirectory)
            }

            // The directory should be empty now. Remove ourself.
            filesRemoved += try await self.removeOneItem(at: path)

            return filesRemoved

        case let .failure(errno):
            throw FileSystemError.remove(errno: errno, path: path, location: .here())
        }
    }

    /// Moves the named file or directory to a new location.
    ///
    /// Only regular files, symbolic links and directories may be moved. If the item to be is a
    /// symbolic link then only the link is moved; the target of the link is not moved.
    ///
    /// If the file is moved within to a different logical partition then the file is copied to the
    /// new partition before being removed from old partition. If removing the item fails the copied
    /// file will not be removed.
    ///
    /// #### Errors
    ///
    /// Error codes thrown include:
    /// - ``FileSystemError/Code-swift.struct/notFound`` if the item at `sourcePath` does not exist,
    /// - ``FileSystemError/Code-swift.struct/fileAlreadyExists`` if an item at `destinationPath`
    ///   already exists.
    ///
    /// #### Implementation details
    ///
    /// Uses the `rename(2)` system call.
    ///
    /// - Parameters:
    ///   - sourcePath: The path to the item to move.
    ///   - destinationPath: The path at which to place the item.
    public func moveItem(at sourcePath: FilePath, to destinationPath: FilePath) async throws {
        let result = try await self.executor.execute {
            try self._moveItem(at: sourcePath, to: destinationPath).get()
        }

        switch result {
        case .moved:
            ()
        case .differentLogicalDevices:
            // Fall back to copy and remove.
            try await self.copyItem(at: sourcePath, to: destinationPath)
            try await self.removeItem(at: sourcePath)
        }
    }

    /// Replaces the item at `destinationPath` with the item at `existingPath`.
    ///
    /// Only regular files, symbolic links and directories may replace the item at the existing
    /// path. The file at the destination path isn't required to exist. If it does exist it does not
    /// have to match the type of the file it is being replaced with.
    ///
    /// #### Errors
    ///
    /// Error codes thrown include:
    /// - ``FileSystemError/Code-swift.struct/notFound`` if the item at `existingPath` does not
    ///   exist.
    ///
    /// #### Implementation details
    ///
    /// Uses the `rename(2)` system call.
    ///
    /// - Parameters:
    ///   - destinationPath: The path of the file or directory to replace.
    ///   - existingPath: The path of the existing file or directory.
    public func replaceItem(
        at destinationPath: FilePath,
        withItemAt existingPath: FilePath
    ) async throws {
        do {
            try await self.removeItem(at: destinationPath)
            try await self.moveItem(at: existingPath, to: destinationPath)
            try await self.removeItem(at: existingPath)
        } catch let error as FileSystemError {
            throw FileSystemError(
                message: "Can't replace '\(destinationPath)' with '\(existingPath)'.",
                wrapping: error
            )
        }
    }

    // MARK: - Symbolic links

    /// Creates a symbolic link between two files.
    ///
    /// A link is created at `linkPath` which points to `destinationPath`. The destination of a
    /// symbolic link can be read with ``destinationOfSymbolicLink(at:)``.
    ///
    /// #### Errors
    ///
    /// Error codes thrown include:
    /// - ``FileSystemError/Code-swift.struct/fileAlreadyExists`` if a file exists at
    ///   `destinationPath`.
    ///
    /// #### Implementation details
    ///
    /// Uses the `link(2)` system call.
    ///
    /// - Parameters:
    ///   - path: The path at which to create the symbolic link.
    ///   - destinationPath: The path that contains the item that the symbolic link points to.`
    public func createSymbolicLink(
        at linkPath: FilePath,
        withDestination destinationPath: FilePath
    ) async throws {
        return try await self.executor.execute {
            try self._createSymbolicLink(at: linkPath, withDestination: destinationPath).get()
        }
    }

    /// Returns the path of the item pointed to by a symbolic link.
    ///
    /// The destination of the symbolic link is not guaranteed to be a valid path, nor is it
    /// guaranteed to be an absolute path. If you need to open a file which is the destination of a
    /// symbolic link then the appropriate `open` function:
    /// - ``openFile(forReadingAt:)``
    /// - ``openFile(forWritingAt:options:)``
    /// - ``openFile(forReadingAndWritingAt:options:)``
    /// - ``openDirectory(atPath:options:)``
    ///
    /// #### Errors
    ///
    /// Error codes thrown include:
    /// - ``FileSystemError/Code-swift.struct/notFound`` if `path` does not exist.
    /// - ``FileSystemError/Code-swift.struct/invalidArgument`` if the file at `path` is not a
    ///   symbolic link.
    ///
    /// #### Implementation details
    ///
    /// Uses the `readlink(2)` system call.
    ///
    /// - Parameter path: The path of a file or directory.
    /// - Returns: The path of the file or directory to which the symbolic link points to.
    public func destinationOfSymbolicLink(
        at path: FilePath
    ) async throws -> FilePath {
        return try await self.executor.execute {
            try self._destinationOfSymbolicLink(at: path).get()
        }
    }

    /// Returns the path of the current working directory.
    ///
    /// #### Implementation details
    ///
    /// Uses the `getcwd(2)` system call.
    ///
    /// - Returns: The path to the current working directory.
    public var currentWorkingDirectory: FilePath {
        get async throws {
            try await self.executor.execute {
                try Libc.getcwd().mapError { errno in
                    FileSystemError.getcwd(errno: errno, location: .here())
                }.get()
            }
        }
    }

    /// Returns a path to a temporary directory.
    ///
    /// #### Implementation details
    ///
    /// On Darwin this function uses `confstr(3)` and gets the value of `_CS_DARWIN_USER_TEMP_DIR`;
    /// the users temporary directory. Typically items are removed after three days if they are not
    /// accessed.
    ///
    /// On Linux this returns "/tmp".
    ///
    /// - Returns: The path to a temporary directory.
    public var temporaryDirectory: FilePath {
        get async throws {
            #if canImport(Darwin)
            return try await self.executor.execute {
                return try Libc.constr(_CS_DARWIN_USER_TEMP_DIR).map { path in
                    FilePath(path)
                }.mapError { errno in
                    FileSystemError.confstr(
                        name: "_CS_DARWIN_USER_TEMP_DIR",
                        errno: errno,
                        location: .here()
                    )
                }.get()
            }
            #else
            return "/tmp"
            #endif
        }
    }
}

// MARK: - Creating FileSystems

extension NIOSingletons {
    /// A suggestion of how many threads the global singleton ``FileSystem`` uses for blocking I/O.
    ///
    /// The thread count is ``System/coreCount`` unless the environment variable
    /// `NIO_SINGLETON_FILESYSTEM_THREAD_COUNT` is set or this value was set manually by the user.
    ///
    /// - note: This value must be set _before_ any singletons are used and must only be set once.
    public static var fileSystemThreadCountSuggestion: Int {
        set {
            Self.userSetSingletonThreadCount(rawStorage: globalRawSuggestedFileSystemThreadCount, userValue: newValue)
        }

        get {
            return Self.getTrustworthyThreadCount(
                rawStorage: globalRawSuggestedFileSystemThreadCount,
                environmentVariable: "NIO_SINGLETON_FILESYSTEM_THREAD_COUNT"
            )
        }
    }

    // Copied from NIOCore/GlobalSingletons.swift
    private static func userSetSingletonThreadCount(rawStorage: ManagedAtomic<Int>, userValue: Int) {
        precondition(userValue > 0, "illegal value: needs to be strictly positive")

        // The user is trying to set it. We can only do this if the value is at 0 and we will set the
        // negative value. So if the user wants `5`, we will set `-5`. Once it's used (set getter), it'll be upped
        // to 5.
        let (exchanged, _) = rawStorage.compareExchange(expected: 0, desired: -userValue, ordering: .relaxed)
        guard exchanged else {
            fatalError(
                """
                Bug in user code: Global singleton suggested loop/thread count has been changed after \
                user or has been changed more than once. Either is an error, you must set this value very early \
                and only once.
                """
            )
        }
    }

    // Copied from NIOCore/GlobalSingletons.swift
    private static func validateTrustedThreadCount(_ threadCount: Int) {
        assert(
            threadCount > 0,
            "BUG IN NIO, please report: negative suggested loop/thread count: \(threadCount)"
        )
        assert(
            threadCount <= 1024,
            "BUG IN NIO, please report: overly big suggested loop/thread count: \(threadCount)"
        )
    }

    // Copied from NIOCore/GlobalSingletons.swift
    private static func getTrustworthyThreadCount(rawStorage: ManagedAtomic<Int>, environmentVariable: String) -> Int {
        let returnedValueUnchecked: Int

        let rawSuggestion = rawStorage.load(ordering: .relaxed)
        switch rawSuggestion {
        case 0:  // == 0
            // Not set by user, not yet finalised, let's try to get it from the env var and fall back to
            // `System.coreCount`.
            let envVarString = getenv(environmentVariable).map { String(cString: $0) }
            returnedValueUnchecked = envVarString.flatMap(Int.init) ?? System.coreCount
        case .min..<0:  // < 0
            // Untrusted and unchecked user value. Let's invert and then sanitise/check.
            returnedValueUnchecked = -rawSuggestion
        case 1 ... .max:  // > 0
            // Trustworthy value that has been evaluated and sanitised before.
            let returnValue = rawSuggestion
            Self.validateTrustedThreadCount(returnValue)
            return returnValue
        default:
            // Unreachable
            preconditionFailure()
        }

        // Can't have fewer than 1, don't want more than 1024.
        let returnValue = max(1, min(1024, returnedValueUnchecked))
        Self.validateTrustedThreadCount(returnValue)

        // Store it for next time.
        let (exchanged, _) = rawStorage.compareExchange(
            expected: rawSuggestion,
            desired: returnValue,
            ordering: .relaxed
        )
        if !exchanged {
            // We lost the race, this must mean it has been concurrently set correctly so we can safely recurse
            // and try again.
            return Self.getTrustworthyThreadCount(rawStorage: rawStorage, environmentVariable: environmentVariable)
        }
        return returnValue
    }
}

// DO NOT TOUCH THIS DIRECTLY, use `userSetSingletonThreadCount` and `getTrustworthyThreadCount`.
private let globalRawSuggestedFileSystemThreadCount = ManagedAtomic(0)

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private let globalFileSystem: FileSystem = {
    guard NIOSingletons.singletonsEnabledSuggestion else {
        fatalError(
            """
            Cannot create global singleton FileSystem thread pool because the global singletons \
            have been disabled by setting `NIOSingletons.singletonsEnabledSuggestion = false`
            """
        )
    }

    let threadCount = NIOSingletons.fileSystemThreadCountSuggestion
    return FileSystem(executor: .runningAsync(numberOfThreads: threadCount))
}()

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension NIOSingletons {
    /// Returns a shared global instance of the ``FileSystem``.
    ///
    /// The file system executes blocking work in a thread pool which defaults to having two
    /// threads. This can be modified by `fileSystemThreadCountSuggestion` or by
    /// setting the `NIO_SINGLETON_FILESYSTEM_THREAD_COUNT` environment variable.
    public static var fileSystem: FileSystem { globalFileSystem }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FileSystemProtocol where Self == FileSystem {
    /// A global shared instance of ``FileSystem``.
    public static var shared: FileSystem {
        return FileSystem.shared
    }
}

/// Provides temporary scoped access to a ``FileSystem`` with the given number of threads.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public func withFileSystem<R: Sendable>(
    numberOfThreads: Int,
    _ body: (FileSystem) async throws -> R
) async throws -> R {
    let fileSystem = await FileSystem(numberOfThreads: numberOfThreads)
    return try await withUncancellableTearDown {
        try await body(fileSystem)
    } tearDown: { _ in
        await fileSystem.shutdown()
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FileSystem {
    /// Opens `path` for reading and returns ``ReadFileHandle`` or ``FileSystemError``.
    private func _openFile(
        forReadingAt path: FilePath,
        options: OpenOptions.Read
    ) -> Result<ReadFileHandle, FileSystemError> {
        return SystemFileHandle.syncOpen(
            atPath: path,
            mode: .readOnly,
            options: options.descriptorOptions,
            permissions: nil,
            transactionalIfPossible: false,
            executor: self.executor
        ).map {
            ReadFileHandle(wrapping: $0)
        }
    }

    /// Opens `path` for writing and returns ``WriteFileHandle`` or ``FileSystemError``.
    private func _openFile(
        forWritingAt path: FilePath,
        options: OpenOptions.Write
    ) -> Result<WriteFileHandle, FileSystemError> {
        return SystemFileHandle.syncOpen(
            atPath: path,
            mode: .writeOnly,
            options: options.descriptorOptions,
            permissions: options.permissionsForRegularFile,
            transactionalIfPossible: options.newFile?.transactionalCreation ?? false,
            executor: self.executor
        ).map {
            WriteFileHandle(wrapping: $0)
        }
    }

    /// Opens `path` for reading and writing and returns ``ReadWriteFileHandle`` or ``FileSystemError``.
    private func _openFile(
        forReadingAndWritingAt path: FilePath,
        options: OpenOptions.Write
    ) -> Result<ReadWriteFileHandle, FileSystemError> {
        return SystemFileHandle.syncOpen(
            atPath: path,
            mode: .readWrite,
            options: options.descriptorOptions,
            permissions: options.permissionsForRegularFile,
            transactionalIfPossible: options.newFile?.transactionalCreation ?? false,
            executor: self.executor
        ).map {
            ReadWriteFileHandle(wrapping: $0)
        }
    }

    /// Opens the directory at `path` and returns ``DirectoryFileHandle`` or ``FileSystemError``.
    private func _openDirectory(
        at path: FilePath,
        options: OpenOptions.Directory
    ) -> Result<DirectoryFileHandle, FileSystemError> {
        return SystemFileHandle.syncOpen(
            atPath: path,
            mode: .readOnly,
            options: options.descriptorOptions,
            permissions: nil,
            transactionalIfPossible: false,
            executor: self.executor
        ).map {
            DirectoryFileHandle(wrapping: $0)
        }
    }

    /// Creates a directory at `fullPath`, potentially creating other directories along the way.
    private func _createDirectory(
        at fullPath: FilePath,
        withIntermediateDirectories createIntermediateDirectories: Bool,
        permissions: FilePermissions
    ) -> Result<Void, FileSystemError> {
        // Logic, assuming we are creating intermediate directories: try creating the directory,
        // if it fails with ENOENT (no such file or directory) then drop the last component and
        // append it to a buffer. Repeat until the path is empty meaning we cannot create the
        // directory, or we succeed in which case we can append build up our original path
        // creating directories one at a time.
        var droppedComponents: [FilePath.Component] = []
        var path = fullPath

        // Normalize the path to remove any '..' which may not be necessary.
        path.lexicallyNormalize()

        if path.isEmpty {
            let error = FileSystemError(
                code: .invalidArgument,
                message: "Path of directory to create must not be empty.",
                cause: nil,
                location: .here()
            )
            return .failure(error)
        }

        loop: while true {
            switch Syscall.mkdir(at: path, permissions: permissions) {
            case .success:
                break loop

            case let .failure(errno):
                guard createIntermediateDirectories, errno == .noSuchFileOrDirectory else {
                    return .failure(.mkdir(errno: errno, path: path, location: .here()))
                }

                // Drop the last component and loop around.
                if let component = path.lastComponent {
                    path.removeLastComponent()
                    droppedComponents.append(component)
                } else {
                    // Should only happen if the path is empty or contains just the root.
                    return .failure(.mkdir(errno: errno, path: path, location: .here()))
                }
            }
        }

        // Successfully made a directory, construct its children.
        while let subdirectory = droppedComponents.popLast() {
            path.append(subdirectory)
            switch Syscall.mkdir(at: path, permissions: permissions) {
            case .success:
                continue
            case let .failure(errno):
                return .failure(.mkdir(errno: errno, path: path, location: .here()))
            }
        }

        return .success(())
    }

    /// Returns info about the file at `path`.
    private func _info(
        forFileAt path: FilePath,
        infoAboutSymbolicLink: Bool
    ) -> Result<FileInfo?, FileSystemError> {
        let result: Result<CInterop.Stat, Errno>
        if infoAboutSymbolicLink {
            result = Syscall.lstat(path: path)
        } else {
            result = Syscall.stat(path: path)
        }

        return result.map {
            FileInfo(platformSpecificStatus: $0)
        }.flatMapError { errno in
            if errno == .noSuchFileOrDirectory {
                return .success(nil)
            } else {
                let name = infoAboutSymbolicLink ? "lstat" : "stat"
                return .failure(.stat(name, errno: errno, path: path, location: .here()))
            }
        }
    }

    /// Copies the directory from `sourcePath` to `destinationPath`.
    private func copyDirectory(
        from sourcePath: FilePath,
        to destinationPath: FilePath,
        shouldProceedAfterError: @escaping @Sendable (
            _ entry: DirectoryEntry,
            _ error: Error
        ) async throws -> Void,
        shouldCopyFile: @escaping @Sendable (
            _ source: FilePath,
            _ destination: FilePath
        ) async -> Bool
    ) async throws {
        // Strategy: copy regular files and symbolic links while the directory is open; defer
        // copying directories until after the source directory has been closed to avoid consuming
        // too many file descriptors.
        let directoriesToCopy = try await self.withDirectoryHandle(atPath: sourcePath) { dir in
            // Grab the directory info to copy permissions.
            let info = try await dir.info()
            try await self.createDirectory(
                at: destinationPath,
                withIntermediateDirectories: false,
                permissions: info.permissions
            )

            // Copy over extended attributes, if any exist.
            do {
                let attributes = try await dir.attributeNames()

                if !attributes.isEmpty {
                    try await self.withDirectoryHandle(atPath: destinationPath) { destinationDir in
                        for attribute in attributes {
                            let value = try await dir.valueForAttribute(attribute)
                            try await destinationDir.updateValueForAttribute(
                                value,
                                attribute: attribute
                            )
                        }
                    }
                }
            } catch let error as FileSystemError where error.code == .unsupported {
                // Not all file systems support extended attributes. Swallow errors which indicate
                // that is the case.
                ()
            }

            // Build a list of directories to copy over. Do this after closing the current
            // directory to avoid using too many descriptors.
            var directoriesToCopy = [(from: FilePath, to: FilePath)]()

            for try await batch in dir.listContents().batched() {
                for entry in batch {
                    let entrySource = entry.path
                    let entryDestination = destinationPath.appending(entry.name)

                    switch entry.type {
                    case .regular:
                        if await shouldCopyFile(entrySource, entryDestination) {
                            do {
                                try await self.copyRegularFile(
                                    from: entry.path,
                                    to: destinationPath.appending(entry.name)
                                )
                            } catch {
                                try await shouldProceedAfterError(entry, error)
                            }
                        }

                    case .symlink:
                        if await shouldCopyFile(entrySource, entryDestination) {
                            do {
                                try await self.copySymbolicLink(
                                    from: entry.path,
                                    to: destinationPath.appending(entry.name)
                                )
                            } catch {
                                try await shouldProceedAfterError(entry, error)
                            }
                        }

                    case .directory:
                        directoriesToCopy.append((entrySource, entryDestination))

                    default:
                        let error = FileSystemError(
                            code: .unsupported,
                            message: """
                                Can't copy '\(entrySource)' of type '\(entry.type)'; only regular \
                                files, symbolic links and directories can be copied.
                                """,
                            cause: nil,
                            location: .here()
                        )

                        try await shouldProceedAfterError(entry, error)
                    }
                }
            }

            return directoriesToCopy
        }

        for entry in directoriesToCopy {
            if await shouldCopyFile(entry.from, entry.to) {
                try await self.copyDirectory(
                    from: entry.from,
                    to: entry.to,
                    shouldProceedAfterError: shouldProceedAfterError,
                    shouldCopyFile: shouldCopyFile
                )
            }
        }
    }

    private func copyRegularFile(
        from sourcePath: FilePath,
        to destinationPath: FilePath
    ) async throws {
        try await self.executor.execute {
            try self._copyRegularFile(from: sourcePath, to: destinationPath).get()
        }
    }

    private func _copyRegularFile(
        from sourcePath: FilePath,
        to destinationPath: FilePath
    ) -> Result<Void, FileSystemError> {
        func makeOnUnavailableError(
            path: FilePath,
            location: FileSystemError.SourceLocation
        ) -> FileSystemError {
            return FileSystemError(
                code: .closed,
                message: "Can't copy '\(sourcePath)' to '\(destinationPath)', '\(path)' is closed.",
                cause: nil,
                location: location
            )
        }

        let openSourceResult = self._openFile(
            forReadingAt: sourcePath,
            options: OpenOptions.Read(followSymbolicLinks: true)
        ).mapError {
            FileSystemError(
                message: "Can't copy '\(sourcePath)', it couldn't be opened.",
                wrapping: $0
            )
        }

        let source: ReadFileHandle
        switch openSourceResult {
        case let .success(handle):
            source = handle
        case let .failure(error):
            return .failure(error)
        }

        defer {
            _ = source.fileHandle.systemFileHandle.sendableView._close(materialize: true)
        }

        let sourceInfo: FileInfo
        switch source.fileHandle.systemFileHandle.sendableView._info() {
        case let .success(info):
            sourceInfo = info
        case let .failure(error):
            return .failure(error)
        }

        let options = OpenOptions.Write(
            existingFile: .none,
            newFile: OpenOptions.NewFile(
                permissions: sourceInfo.permissions,
                transactionalCreation: false
            )
        )

        let openDestinationResult = self._openFile(
            forWritingAt: destinationPath,
            options: options
        ).mapError {
            FileSystemError(
                message: "Can't copy '\(sourcePath)' as '\(destinationPath)' couldn't be opened.",
                wrapping: $0
            )
        }

        let destination: WriteFileHandle
        switch openDestinationResult {
        case let .success(handle):
            destination = handle
        case let .failure(error):
            return .failure(error)
        }

        let copyResult: Result<Void, FileSystemError>
        copyResult = source.fileHandle.systemFileHandle.sendableView._withUnsafeDescriptorResult { sourceFD in
            destination.fileHandle.systemFileHandle.sendableView._withUnsafeDescriptorResult { destinationFD in
                #if canImport(Darwin)
                // COPYFILE_CLONE clones the file if possible and will fallback to doing a copy.
                // COPYFILE_ALL is shorthand for:
                //    COPYFILE_STAT | COPYFILE_ACL | COPYFILE_XATTR | COPYFILE_DATA
                let flags = copyfile_flags_t(COPYFILE_CLONE) | copyfile_flags_t(COPYFILE_ALL)
                return Libc.fcopyfile(
                    from: sourceFD,
                    to: destinationFD,
                    state: nil,
                    flags: flags
                ).mapError { errno in
                    FileSystemError.fcopyfile(
                        errno: errno,
                        from: sourcePath,
                        to: destinationPath,
                        location: .here()
                    )
                }
                #elseif canImport(Glibc) || canImport(Musl)
                var offset = 0

                while offset < sourceInfo.size {
                    // sendfile(2) limits writes to 0x7ffff000 in size
                    let size = min(Int(sourceInfo.size) - offset, 0x7fff_f000)
                    let result = Syscall.sendfile(
                        to: destinationFD,
                        from: sourceFD,
                        offset: offset,
                        size: size
                    ).mapError { errno in
                        FileSystemError.sendfile(
                            errno: errno,
                            from: sourcePath,
                            to: destinationPath,
                            location: .here()
                        )
                    }

                    switch result {
                    case let .success(bytesCopied):
                        offset += bytesCopied
                    case let .failure(error):
                        return .failure(error)
                    }
                }
                return .success(())
                #endif
            } onUnavailable: {
                makeOnUnavailableError(path: destinationPath, location: .here())
            }
        } onUnavailable: {
            makeOnUnavailableError(path: sourcePath, location: .here())
        }

        let closeResult = destination.fileHandle.systemFileHandle.sendableView._close(materialize: true)
        return copyResult.flatMap { closeResult }
    }

    private func copySymbolicLink(
        from sourcePath: FilePath,
        to destinationPath: FilePath
    ) async throws {
        try await self.executor.execute {
            try self._copySymbolicLink(from: sourcePath, to: destinationPath).get()
        }
    }

    private func _copySymbolicLink(
        from sourcePath: FilePath,
        to destinationPath: FilePath
    ) -> Result<Void, FileSystemError> {
        self._destinationOfSymbolicLink(at: sourcePath).flatMap { linkDestination in
            self._createSymbolicLink(at: destinationPath, withDestination: linkDestination)
        }
    }

    @_spi(Testing)
    public func removeOneItem(
        at path: FilePath,
        function: String = #function,
        file: String = #fileID,
        line: Int = #line
    ) async throws -> Int {
        try await self.executor.execute {
            switch Libc.remove(path) {
            case .success:
                return 1
            case .failure(.noSuchFileOrDirectory):
                return 0
            case .failure(let errno):
                throw FileSystemError.remove(
                    errno: errno,
                    path: path,
                    location: .init(function: function, file: file, line: line)
                )
            }
        }
    }

    private enum MoveResult {
        case moved
        case differentLogicalDevices
    }

    private func _moveItem(
        at sourcePath: FilePath,
        to destinationPath: FilePath
    ) -> Result<MoveResult, FileSystemError> {
        // Check that the destination doesn't exist. 'rename' will remove it otherwise!
        switch self._info(forFileAt: destinationPath, infoAboutSymbolicLink: true) {
        case .success(.none):
            // Doens't exist: continue
            ()

        case .success(.some):
            let fileSystemError = FileSystemError(
                code: .fileAlreadyExists,
                message: """
                    Unable to move '\(sourcePath)' to '\(destinationPath)', the destination path \
                    already exists.
                    """,
                cause: nil,
                location: .here()
            )
            return .failure(fileSystemError)

        case let .failure(error):
            let fileSystemError = FileSystemError(
                message: """
                    Unable to move '\(sourcePath)' to '\(destinationPath)', could not determine \
                    whether the destination path exists or not.
                    """,
                wrapping: error
            )
            return .failure(fileSystemError)
        }

        switch Syscall.rename(from: sourcePath, to: destinationPath) {
        case .success:
            return .success(.moved)

        case .failure(.improperLink):
            // The two paths are on different logical devices; copy and then remove the
            // original.
            return .success(.differentLogicalDevices)

        case let .failure(errno):
            let error = FileSystemError.rename(
                errno: errno,
                oldName: sourcePath,
                newName: destinationPath,
                location: .here()
            )
            return .failure(error)
        }
    }

    private func parseTemporaryDirectoryTemplate(
        _ template: FilePath
    ) -> Result<(FilePath, String, Int), FileSystemError> {
        // Check whether template is valid (i.e. has a `lastComponent`).
        guard let lastComponentPath = template.lastComponent else {
            let fileSystemError = FileSystemError(
                code: .invalidArgument,
                message: """
                    Can't create temporary directory, the template ('\(template)') is invalid. \
                    The template should be a file path ending in at least three 'X's.
                    """,
                cause: nil,
                location: .here()
            )
            return .failure(fileSystemError)
        }

        let lastComponent = lastComponentPath.string

        // Finding the index of the last non-'X' character in `lastComponent.string` and advancing it by one.
        let prefix: String
        var index = lastComponent.lastIndex(where: { $0 != "X" })
        if index != nil {
            lastComponent.formIndex(after: &(index!))
            prefix = String(lastComponent[..<index!])
        } else if lastComponent.first == "X" {
            // The directory name from the template contains only 'X's.
            prefix = ""
            index = lastComponent.startIndex
        } else {
            let fileSystemError = FileSystemError(
                code: .invalidArgument,
                message: """
                    Can't create temporary directory, the template ('\(template)') is invalid. \
                    The template must end in at least three 'X's.
                    """,
                cause: nil,
                location: .here()
            )
            return .failure(fileSystemError)
        }

        // Computing the number of 'X's.
        let suffixLength = lastComponent.distance(from: index!, to: lastComponent.endIndex)
        guard suffixLength >= 3 else {
            let fileSystemError = FileSystemError(
                code: .invalidArgument,
                message: """
                    Can't create temporary directory, the template ('\(template)') is invalid. \
                    The template must end in at least three 'X's.
                    """,
                cause: nil,
                location: .here()
            )
            return .failure(fileSystemError)
        }

        return .success((template.removingLastComponent(), prefix, suffixLength))
    }

    private func _createTemporaryDirectory(
        template: FilePath
    ) -> Result<FilePath, FileSystemError> {
        let prefix: String
        let root: FilePath
        let suffixLength: Int

        let parseResult = self.parseTemporaryDirectoryTemplate(template)
        switch parseResult {
        case let .success((parseRoot, parsePrefix, parseSuffixLength)):
            root = parseRoot
            prefix = parsePrefix
            suffixLength = parseSuffixLength
        case let .failure(error):
            return .failure(error)
        }

        for _ in 1...16 {
            let name = prefix + String(randomAlphaNumericOfLength: suffixLength)

            // Trying to create the directory.
            let finalPath = root.appending(name)
            let createDirectoriesResult = self._createDirectory(
                at: finalPath,
                withIntermediateDirectories: true,
                permissions: FilePermissions.defaultsForDirectory
            )
            switch createDirectoriesResult {
            case .success:
                return .success(finalPath)
            case let .failure(error):
                if let systemCallError = error.cause as? FileSystemError.SystemCallError {
                    switch systemCallError.errno {
                    // If the file at the generated path already exists, we generate a new file path.
                    case .fileExists, .isDirectory:
                        break
                    default:
                        let fileSystemError = FileSystemError(
                            message: "Unable to create temporary directory '\(template)'.",
                            wrapping: error
                        )
                        return .failure(fileSystemError)
                    }
                } else {
                    let fileSystemError = FileSystemError(
                        message: "Unable to create temporary directory '\(template)'.",
                        wrapping: error
                    )
                    return .failure(fileSystemError)
                }
            }
        }
        let fileSystemError = FileSystemError(
            code: .unknown,
            message: """
                Could not create a temporary directory from the provided template ('\(template)'). \
                Try adding more 'X's at the end of the template.
                """,
            cause: nil,
            location: .here()
        )
        return .failure(fileSystemError)
    }

    func _createSymbolicLink(
        at linkPath: FilePath,
        withDestination destinationPath: FilePath
    ) -> Result<Void, FileSystemError> {
        return Syscall.symlink(to: destinationPath, from: linkPath).mapError { errno in
            FileSystemError.symlink(
                errno: errno,
                link: linkPath,
                target: destinationPath,
                location: .here()
            )
        }
    }

    func _destinationOfSymbolicLink(at path: FilePath) -> Result<FilePath, FileSystemError> {
        Syscall.readlink(at: path).mapError { errno in
            FileSystemError.readlink(
                errno: errno,
                path: path,
                location: .here()
            )
        }
    }
}

#endif
