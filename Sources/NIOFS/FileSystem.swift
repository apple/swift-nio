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

import Atomics
import NIOCore
import NIOPosix
import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Bionic)
@preconcurrency import Bionic
#endif

/// A file system which interacts with the local system. The file system uses a thread pool to
/// perform system calls.
///
/// ### Creating a `FileSystem`
///
/// You should prefer using the `shared` instance of the file system. The `shared` instance uses two
/// threads unless the `SWIFT_FILE_SYSTEM_THREAD_COUNT` environment variable is set.
///
/// If you require more granular control you can create a ``FileSystem`` with the required number of
/// threads by calling ``withFileSystem(numberOfThreads:_:)`` or by using ``init(threadPool:)``.
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
    /// threads. This can be modified by `blockingPoolThreadCountSuggestion` or by setting the
    /// `NIO_SINGLETON_BLOCKING_POOL_THREAD_COUNT` environment variable.
    public static var shared: FileSystem { globalFileSystem }

    private let threadPool: NIOThreadPool
    private let ownsThreadPool: Bool

    fileprivate func shutdown() async {
        if self.ownsThreadPool {
            try? await self.threadPool.shutdownGracefully()
        }
    }

    /// Creates a new ``FileSystem`` using the provided thread pool.
    ///
    /// - Parameter threadPool: A started thread pool to execute blocking system calls on. The
    ///     ``FileSystem`` doesn't take ownership of the thread pool and you remain responsible for
    ///     shutting it down when necessary.
    public init(threadPool: NIOThreadPool) {
        self.init(threadPool: threadPool, ownsThreadPool: false)
    }

    fileprivate init(threadPool: NIOThreadPool, ownsThreadPool: Bool) {
        self.threadPool = threadPool
        self.ownsThreadPool = ownsThreadPool
    }

    fileprivate init(numberOfThreads: Int) async {
        let threadPool = NIOThreadPool(numberOfThreads: numberOfThreads)
        threadPool.start()
        // Wait for the thread pool to start.
        try? await threadPool.runIfActive {}
        self.init(threadPool: threadPool, ownsThreadPool: true)
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
        forReadingAt path: NIOFilePath,
        options: OpenOptions.Read
    ) async throws -> ReadFileHandle {
        let handle = try await self.threadPool.runIfActive {
            let handle = try self._openFile(forReadingAt: path.underlying, options: options).get()
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
        forWritingAt path: NIOFilePath,
        options: OpenOptions.Write
    ) async throws -> WriteFileHandle {
        let handle = try await self.threadPool.runIfActive {
            let handle = try self._openFile(forWritingAt: path.underlying, options: options).get()
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
        forReadingAndWritingAt path: NIOFilePath,
        options: OpenOptions.Write
    ) async throws -> ReadWriteFileHandle {
        let handle = try await self.threadPool.runIfActive {
            let handle = try self._openFile(forReadingAndWritingAt: path.underlying, options: options).get()
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
    ///   - options: How the directory should be opened.
    /// - Returns: A handle to the opened directory.
    public func openDirectory(
        atPath path: NIOFilePath,
        options: OpenOptions.Directory
    ) async throws -> DirectoryFileHandle {
        let handle = try await self.threadPool.runIfActive {
            let handle = try self._openDirectory(at: path.underlying, options: options).get()
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
    /// - ``FileSystemError/Code-swift.struct/invalidArgument`` if a component in the `path` prefix
    ///   does not exist and `createIntermediateDirectories` is `false`.
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
        at path: NIOFilePath,
        withIntermediateDirectories createIntermediateDirectories: Bool,
        permissions: FilePermissions?
    ) async throws {
        try await self.createDirectory(
            at: path,
            withIntermediateDirectories: createIntermediateDirectories,
            permissions: permissions,
            idempotent: true
        )
    }

    private func createDirectory(
        at path: NIOFilePath,
        withIntermediateDirectories createIntermediateDirectories: Bool,
        permissions: FilePermissions?,
        idempotent: Bool
    ) async throws {
        try await self.threadPool.runIfActive {
            try self._createDirectory(
                at: path.underlying,
                withIntermediateDirectories: createIntermediateDirectories,
                permissions: permissions ?? .defaultsForDirectory,
                idempotent: idempotent
            ).get()
        }
    }

    /// Create a temporary directory at the given path, using a template.
    ///
    /// #### Errors
    ///
    /// Error codes thrown include:
    /// - ``FileSystemError/Code-swift.struct/invalidArgument`` if the template doesn't end in at
    ///   least 3 'X's.
    /// - ``FileSystemError/Code-swift.struct/permissionDenied`` if the user doesn't have permission
    ///  to create a directory at the path specified in the template.
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
        template: NIOFilePath
    ) async throws -> NIOFilePath {
        try await self.threadPool.runIfActive {
            NIOFilePath(try self._createTemporaryDirectory(template: template.underlying).get())
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
    ///    - infoAboutSymbolicLink: If the file is a symbolic link and this parameter is `true`,
    ///        then information about the link will be returned. Otherwise, information about the
    ///        destination of the symbolic link is returned.
    /// - Returns: Information about the file at the given path or `nil` if no file exists.
    public func info(
        forFileAt path: NIOFilePath,
        infoAboutSymbolicLink: Bool
    ) async throws -> FileInfo? {
        try await self.threadPool.runIfActive {
            try self._info(forFileAt: path.underlying, infoAboutSymbolicLink: infoAboutSymbolicLink).get()
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
    /// `shouldCopyItem` can be used to ignore objects not part of this set.
    ///
    /// #### Errors
    ///
    /// In addition to the already documented errors these may be thrown
    /// - ``FileSystemError/Code-swift.struct/unsupported`` if an item to be copied is not a regular
    ///   file, symbolic link or directory.
    ///
    /// #### Implementation details
    ///
    /// This function is platform dependent. On Darwin the `copyfile(2)` system call is used and
    /// items are cloned where possible. On Linux the `sendfile(2)` system call is used.
    public func copyItem(
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

        // By doing this before looking at the type, we allow callers to decide whether
        // unanticipated kinds of entries can be safely ignored without needing changes upstream.
        if await shouldCopyItem(.init(path: sourcePath, type: info.type)!, destinationPath) {
            switch info.type {
            case .regular:
                try await self.copyRegularFile(from: sourcePath.underlying, to: destinationPath.underlying)

            case .symlink:
                try await self.copySymbolicLink(from: sourcePath.underlying, to: destinationPath.underlying)

            case .directory:
                try await self.copyDirectory(
                    from: sourcePath.underlying,
                    to: destinationPath.underlying,
                    strategy: copyStrategy,
                    shouldProceedAfterError: shouldProceedAfterError
                ) { source, destination in
                    await shouldCopyItem(source, .init(destination))
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
    }

    /// See ``FileSystemProtocol/removeItem(at:strategy:recursively:)``
    ///
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
    ///   - removalStrategy: Whether to delete files sequentially (one-by-one), or perform a
    ///       concurrent scan of the tree at `path` and delete files when they are found.
    ///   - removeItemRecursively: Whether or not to remove items recursively.
    /// - Returns: The number of deleted items which may be zero if `path` did not exist.
    @discardableResult
    public func removeItem(
        at path: NIOFilePath,
        strategy removalStrategy: RemovalStrategy,
        recursively removeItemRecursively: Bool
    ) async throws -> Int {
        // Try to remove the item: we might just get lucky.
        let result = try await self.threadPool.runIfActive { Libc.remove(path.underlying) }

        switch result {
        case .success:
            // Great; we removed an entire item.
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
                        'removeItemRecursively' is false. Remove items from the directory first or \
                        set 'removeItemRecursively' to true when calling \
                        'removeItem(at:recursively:)'.
                        """,
                    cause: nil,
                    location: .here()
                )
            }

            switch removalStrategy.wrapped {
            case .sequential:
                return try await self.removeItemSequentially(at: path.underlying)
            case let .parallel(maxDescriptors):
                return try await self.removeConcurrently(at: path.underlying, maxDescriptors)
            }

        case let .failure(errno):
            throw FileSystemError.remove(errno: errno, path: path.underlying, location: .here())
        }
    }

    @discardableResult
    private func removeItemSequentially(
        at path: FilePath
    ) async throws -> Int {
        var (subdirectories, filesRemoved) = try await self.withDirectoryHandle(
            atPath: NIOFilePath(path)
        ) { directory in
            var subdirectories = [FilePath]()
            var filesRemoved = 0

            for try await batch in directory.listContents().batched() {
                for entry in batch {
                    switch entry.type {
                    case .directory:
                        subdirectories.append(entry.path.underlying)

                    default:
                        filesRemoved += try await self.removeOneItem(at: entry.path.underlying)
                    }
                }
            }

            return (subdirectories, filesRemoved)
        }

        for subdirectory in subdirectories {
            filesRemoved += try await self.removeItemSequentially(at: subdirectory)
        }

        // The directory should be empty now. Remove ourself.
        filesRemoved += try await self.removeOneItem(at: path)

        return filesRemoved

    }

    private func removeConcurrently(
        at path: FilePath,
        _ maxDescriptors: Int
    ) async throws -> Int {
        let bucket: TokenBucket = .init(tokens: maxDescriptors)
        return try await self.discoverAndRemoveItemsInTree(at: path, bucket)
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
    public func moveItem(at sourcePath: NIOFilePath, to destinationPath: NIOFilePath) async throws {
        let result = try await self.threadPool.runIfActive {
            try self._moveItem(at: sourcePath.underlying, to: destinationPath.underlying).get()
        }

        switch result {
        case .moved:
            ()
        case .differentLogicalDevices:
            // Fall back to copy and remove.
            try await self.copyItem(at: sourcePath, to: destinationPath)
            try await self.removeItem(at: sourcePath, strategy: .platformDefault)
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
        at destinationPath: NIOFilePath,
        withItemAt existingPath: NIOFilePath
    ) async throws {
        do {
            try await self.removeItem(at: destinationPath, strategy: .platformDefault)
            try await self.moveItem(at: existingPath, to: destinationPath)
            try await self.removeItem(at: existingPath, strategy: .platformDefault)
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
    ///   - linkPath: The path at which to create the symbolic link.
    ///   - destinationPath: The path that contains the item that the symbolic link points to.`
    public func createSymbolicLink(
        at linkPath: NIOFilePath,
        withDestination destinationPath: NIOFilePath
    ) async throws {
        try await self.threadPool.runIfActive {
            try self._createSymbolicLink(at: linkPath.underlying, withDestination: destinationPath.underlying).get()
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
        at path: NIOFilePath
    ) async throws -> NIOFilePath {
        try await self.threadPool.runIfActive {
            NIOFilePath(try self._destinationOfSymbolicLink(at: path.underlying).get())
        }
    }

    /// Returns the path of the current working directory.
    ///
    /// #### Implementation details
    ///
    /// Uses the `getcwd(2)` system call.
    ///
    /// - Returns: The path to the current working directory.
    public var currentWorkingDirectory: NIOFilePath {
        get async throws {
            let result = try await self.threadPool.runIfActive {
                try Libc.getcwd().mapError { errno in
                    FileSystemError.getcwd(errno: errno, location: .here())
                }.get()
            }
            return .init(result)
        }
    }

    /// Returns a path to a temporary directory.
    ///
    /// #### Implementation details
    ///
    /// On all platforms, this function first attempts to read the `TMPDIR` environment variable and returns that path, omitting trailing slashes.
    /// If that fails:
    /// - On Darwin this function uses `confstr(3)` and gets the value of `_CS_DARWIN_USER_TEMP_DIR`;
    ///   the users temporary directory. Typically items are removed after three days if they are not
    ///   accessed.
    /// - On Android this returns "/data/local/tmp".
    /// - On other platforms this returns "/tmp".
    ///
    /// - Returns: The path to a temporary directory.
    public var temporaryDirectory: NIOFilePath {
        get async throws {
            if let tmpdir = getenv("TMPDIR") {
                return NIOFilePath(String(cString: tmpdir))
            }

            #if canImport(Darwin)
            return try await self.threadPool.runIfActive {
                let result = Libc.constr(_CS_DARWIN_USER_TEMP_DIR)
                switch result {
                case .success(let path):
                    return NIOFilePath(path)
                case .failure(_):
                    return NIOFilePath("/tmp")
                }
            }
            #elseif os(Android)
            return NIOFilePath("/data/local/tmp")
            #else
            return NIOFilePath("/tmp")
            #endif
        }
    }
}

// MARK: - Creating FileSystems

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
    return FileSystem(threadPool: NIOSingletons.posixBlockingThreadPool, ownsThreadPool: false)
}()

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension NIOSingletons {
    /// Returns a shared global instance of the ``FileSystem``.
    ///
    /// The file system executes blocking work in a thread pool. See
    /// `blockingPoolThreadCountSuggestion` for the default behaviour and ways to control it.
    public static var fileSystem: FileSystem { globalFileSystem }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FileSystemProtocol where Self == FileSystem {
    /// A global shared instance of ``FileSystem``.
    public static var shared: FileSystem {
        FileSystem.shared
    }
}

/// Provides temporary scoped access to a ``FileSystem`` with the given number of threads.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public func withFileSystem<Result>(
    numberOfThreads: Int,
    _ body: (FileSystem) async throws -> Result
) async throws -> Result {
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
        SystemFileHandle.syncOpen(
            atPath: path,
            mode: .readOnly,
            options: options.descriptorOptions,
            permissions: nil,
            transactionalIfPossible: false,
            threadPool: self.threadPool
        ).map {
            ReadFileHandle(wrapping: $0)
        }
    }

    /// Opens `path` for writing and returns ``WriteFileHandle`` or ``FileSystemError``.
    private func _openFile(
        forWritingAt path: FilePath,
        options: OpenOptions.Write
    ) -> Result<WriteFileHandle, FileSystemError> {
        SystemFileHandle.syncOpen(
            atPath: path,
            mode: .writeOnly,
            options: options.descriptorOptions,
            permissions: options.permissionsForRegularFile,
            transactionalIfPossible: options.newFile?.transactionalCreation ?? false,
            threadPool: self.threadPool
        ).map {
            WriteFileHandle(wrapping: $0)
        }
    }

    /// Opens `path` for reading and writing and returns ``ReadWriteFileHandle`` or
    /// ``FileSystemError``.
    private func _openFile(
        forReadingAndWritingAt path: FilePath,
        options: OpenOptions.Write
    ) -> Result<ReadWriteFileHandle, FileSystemError> {
        SystemFileHandle.syncOpen(
            atPath: path,
            mode: .readWrite,
            options: options.descriptorOptions,
            permissions: options.permissionsForRegularFile,
            transactionalIfPossible: options.newFile?.transactionalCreation ?? false,
            threadPool: self.threadPool
        ).map {
            ReadWriteFileHandle(wrapping: $0)
        }
    }

    /// Opens the directory at `path` and returns ``DirectoryFileHandle`` or ``FileSystemError``.
    private func _openDirectory(
        at path: FilePath,
        options: OpenOptions.Directory
    ) -> Result<DirectoryFileHandle, FileSystemError> {
        SystemFileHandle.syncOpen(
            atPath: path,
            mode: .readOnly,
            options: options.descriptorOptions,
            permissions: nil,
            transactionalIfPossible: false,
            threadPool: self.threadPool
        ).map {
            DirectoryFileHandle(wrapping: $0)
        }
    }

    /// Creates a directory at `fullPath`, potentially creating other directories along the way.
    private func _createDirectory(
        at fullPath: FilePath,
        withIntermediateDirectories createIntermediateDirectories: Bool,
        permissions: FilePermissions,
        idempotent: Bool = true
    ) -> Result<Void, FileSystemError> {
        // We assume that we will be creating intermediate directories:
        // - Try creating the directory. If it fails with ENOENT (no such file or directory), then
        //   drop the last component and append it to a buffer.
        // - Repeat until the path is empty. This means we cannot create the directory or we
        //   succeed, in which case we can build up our original path and create directories one at
        //   a time.
        var droppedComponents: [FilePath.Component] = []
        var path = fullPath

        // Normalize the path to remove any superflous '..'.
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
                if errno == .fileExists {
                    if idempotent {
                        switch self._info(forFileAt: path, infoAboutSymbolicLink: false) {
                        case let .success(maybeInfo):
                            if let info = maybeInfo, info.type == .directory {
                                break loop
                            } else {
                                // A file exists at this path.
                                return .failure(.mkdir(errno: errno, path: path, location: .here()))
                            }
                        case .failure:
                            // Unable to determine what exists at this path.
                            return .failure(.mkdir(errno: errno, path: path, location: .here()))
                        }
                    } else {
                        return .failure(.mkdir(errno: errno, path: path, location: .here()))
                    }
                }
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

    /// Represents an item in a directory that needs copying, or an explicit indication of the end
    /// of items. The provision of the ``endOfDir`` case significantly simplifies the parallel code
    enum DirCopyItem: Hashable, Sendable {
        case endOfDir
        case toCopy(from: DirectoryEntry, to: FilePath)
    }

    /// Creates the directory ``destinationPath`` based on the directory at ``sourcePath`` including
    /// any permissions/attributes. It does not copy the contents but indicates the items within
    /// ``sourcePath`` which should be copied.
    ///
    /// This is a little cumbersome, because it is used by ``copyDirectorySequential`` and
    /// ``copyDirectoryParallel``. It is desirable to use the directories' file descriptor for as
    /// little time as possible, and certainly not across asynchronous invocations. The downstream
    /// paths in the parallel and sequential paths are very different
    /// - Returns: An array of `DirCopyItem` which have passed the ``shouldCopyItem``` filter. The
    ///     target file paths will all be in ``destinationPath``. The array will always finish with
    ///     an ``DirCopyItem.endOfDir``.
    private func prepareDirectoryForRecusiveCopy(
        from sourcePath: FilePath,
        to destinationPath: FilePath,
        shouldProceedAfterError:
            @escaping @Sendable (
                _ entry: DirectoryEntry,
                _ error: Error
            ) async throws -> Void,
        shouldCopyItem:
            @escaping @Sendable (
                _ source: DirectoryEntry,
                _ destination: FilePath
            ) async -> Bool
    ) async throws -> [DirCopyItem] {
        try await self.withDirectoryHandle(atPath: NIOFilePath(sourcePath)) { dir in
            // Grab the directory info to copy permissions.
            let info = try await dir.info()
            try await self.createDirectory(
                at: NIOFilePath(destinationPath),
                withIntermediateDirectories: false,
                permissions: info.permissions,
                idempotent: false  // Fail if the destination dir already exists.
            )

            #if !os(Android)
            // Copy over extended attributes, if any exist.
            do {
                let attributes = try await dir.attributeNames()

                if !attributes.isEmpty {
                    try await self.withDirectoryHandle(
                        atPath: NIOFilePath(destinationPath)
                    ) { destinationDir in
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
                // Not all file systems support extended attributes. Swallow errors indicating this.
                ()
            }
            #endif
            // Build a list of items the caller needs to deal with, then do any further work after
            // closing the current directory.
            var contentsToCopy = [DirCopyItem]()

            for try await batch in dir.listContents().batched() {
                for entry in batch {
                    // Any further work is pointless. We are under no obligation to cleanup. Exit as
                    // fast and cleanly as possible.
                    try Task.checkCancellation()
                    let entryDestination = destinationPath.appending(entry.name)

                    if await shouldCopyItem(entry, entryDestination) {
                        // Assume there's a good chance of everything in the batch being included in
                        // the common case. Let geometric growth go from this point though.
                        if contentsToCopy.isEmpty {
                            // Reserve space for the endOfDir entry too.
                            contentsToCopy.reserveCapacity(batch.count + 1)
                        }
                        switch entry.type {
                        case .regular, .symlink, .directory:
                            contentsToCopy.append(.toCopy(from: entry, to: entryDestination))

                        default:
                            let error = FileSystemError(
                                code: .unsupported,
                                message: """
                                    Can't copy '\(entry.path)' of type '\(entry.type)'; only regular \
                                    files, symbolic links and directories can be copied.
                                    """,
                                cause: nil,
                                location: .here()
                            )

                            try await shouldProceedAfterError(entry, error)
                        }
                    }
                }
            }

            contentsToCopy.append(.endOfDir)
            return contentsToCopy
        }
    }

    /// This could be achieved through quite complicated special casing of the parallel copy. The
    /// resulting code is far harder to read and debug, so this is kept as a special case.
    private func copyDirectorySequential(
        from sourcePath: FilePath,
        to destinationPath: FilePath,
        shouldProceedAfterError:
            @escaping @Sendable (
                _ entry: DirectoryEntry,
                _ error: Error
            ) async throws -> Void,
        shouldCopyItem:
            @escaping @Sendable (
                _ source: DirectoryEntry,
                _ destination: FilePath
            ) async -> Bool
    ) async throws {
        // Strategy: find all needed items to copy/recurse into while the directory is open; defer
        // actual copying and recursion until after the source directory has been closed to avoid
        // consuming too many file descriptors.
        let toCopy = try await self.prepareDirectoryForRecusiveCopy(
            from: sourcePath,
            to: destinationPath,
            shouldProceedAfterError: shouldProceedAfterError,
            shouldCopyItem: shouldCopyItem
        )

        for entry in toCopy {
            switch entry {
            case .endOfDir:
                // Sequential cases doesn't need to worry about this, it uses simple recursion.
                continue
            case let .toCopy(source, destination):
                // Note: The entry type could have changed between finding it and acting on it. This
                // is inherent in file systems, just more likely in an asynchronous environment. We
                // just accept those coming through as regular errors.
                switch source.type {
                case .regular:
                    do {
                        try await self.copyRegularFile(
                            from: source.path.underlying,
                            to: destination
                        )
                    } catch {
                        try await shouldProceedAfterError(source, error)
                    }

                case .symlink:
                    do {
                        try await self.copySymbolicLink(
                            from: source.path.underlying,
                            to: destination
                        )
                    } catch {
                        try await shouldProceedAfterError(source, error)
                    }

                case .directory:
                    try await self.copyDirectorySequential(
                        from: source.path.underlying,
                        to: destination,
                        shouldProceedAfterError: shouldProceedAfterError,
                        shouldCopyItem: shouldCopyItem
                    )

                default:
                    let error = FileSystemError(
                        code: .unsupported,
                        message: """
                            Can't copy '\(source.path)' of type '\(source.type)'; only regular \
                            files, symbolic links and directories can be copied.
                            """,
                        cause: nil,
                        location: .here()
                    )

                    try await shouldProceedAfterError(source, error)
                }
            }
        }
    }

    /// Copies the directory from `sourcePath` to `destinationPath`.
    private func copyDirectory(
        from sourcePath: FilePath,
        to destinationPath: FilePath,
        strategy copyStrategy: CopyStrategy,
        shouldProceedAfterError:
            @escaping @Sendable (
                _ entry: DirectoryEntry,
                _ error: Error
            ) async throws -> Void,
        shouldCopyItem:
            @escaping @Sendable (
                _ source: DirectoryEntry,
                _ destination: FilePath
            ) async -> Bool
    ) async throws {
        switch copyStrategy.wrapped {
        case .sequential:
            return try await self.copyDirectorySequential(
                from: sourcePath,
                to: destinationPath,
                shouldProceedAfterError: shouldProceedAfterError,
                shouldCopyItem: shouldCopyItem
            )
        case let .parallel(maxDescriptors):
            // Note that maxDescriptors was validated on construction of CopyStrategy. See notes on
            // CopyStrategy about assumptions on descriptor use. For now, we take the worst case
            // peak for every operation, which is two file descriptors. This keeps the downstream
            // limiting code simple.
            //
            // We do not preclude the use of more granular limiting in the future (e.g. a directory
            // scan requires only a single file descriptor). For now we just drop any excess
            // remainder entirely.
            let limitValue = maxDescriptors / 2
            return try await self.copyDirectoryParallel(
                from: sourcePath,
                to: destinationPath,
                maxConcurrentOperations: limitValue,
                shouldProceedAfterError: shouldProceedAfterError,
                shouldCopyItem: shouldCopyItem
            )
        }
    }

    /// Building block of the parallel directory copy implementation. Each invocation of this is
    /// allowed to consume two file descriptors. Any further work (if any) should be sent to `yield`
    /// for future processing.
    func copySelfAndEnqueueChildren(
        from: DirectoryEntry,
        to: FilePath,
        yield: @Sendable ([DirCopyItem]) -> Void,
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
        switch from.type {
        case .regular:
            do {
                try await self.copyRegularFile(
                    from: from.path.underlying,
                    to: to
                )
            } catch {
                try await shouldProceedAfterError(from, error)
            }

        case .symlink:
            do {
                try await self.copySymbolicLink(
                    from: from.path.underlying,
                    to: to
                )
            } catch {
                try await shouldProceedAfterError(from, error)
            }

        case .directory:
            do {
                let addToQueue = try await self.prepareDirectoryForRecusiveCopy(
                    from: from.path.underlying,
                    to: to,
                    shouldProceedAfterError: shouldProceedAfterError,
                    shouldCopyItem: shouldCopyItem
                )
                yield(addToQueue)
            } catch {
                // The caller expects an end-of-dir regardless of whether there was an error or not.
                yield([.endOfDir])
                try await shouldProceedAfterError(from, error)
            }

        default:
            let error = FileSystemError(
                code: .unsupported,
                message: """
                    Can't copy '\(from.path)' of type '\(from.type)'; only regular \
                    files, symbolic links and directories can be copied.
                    """,
                cause: nil,
                location: .here()
            )

            try await shouldProceedAfterError(from, error)
        }
    }

    private func copyRegularFile(
        from sourcePath: FilePath,
        to destinationPath: FilePath
    ) async throws {
        try await self.threadPool.runIfActive {
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
            FileSystemError(
                code: .closed,
                message: "Can't copy '\(sourcePath)' to '\(destinationPath)', '\(path)' is closed.",
                cause: nil,
                location: location
            )
        }

        #if canImport(Darwin)
        // COPYFILE_CLONE clones the file if possible and will fallback to doing a copy.
        // COPYFILE_ALL is shorthand for:
        //    COPYFILE_STAT | COPYFILE_ACL | COPYFILE_XATTR | COPYFILE_DATA
        let flags = copyfile_flags_t(COPYFILE_CLONE) | copyfile_flags_t(COPYFILE_ALL)
        return Libc.copyfile(
            from: sourcePath,
            to: destinationPath,
            state: nil,
            flags: flags
        ).mapError { errno in
            FileSystemError.copyfile(
                errno: errno,
                from: sourcePath,
                to: destinationPath,
                location: .here()
            )
        }

        #elseif canImport(Glibc) || canImport(Musl) || canImport(Bionic)

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
            } onUnavailable: {
                makeOnUnavailableError(path: destinationPath, location: .here())
            }
        } onUnavailable: {
            makeOnUnavailableError(path: sourcePath, location: .here())
        }

        let closeResult = destination.fileHandle.systemFileHandle.sendableView._close(materialize: true)
        return copyResult.flatMap { closeResult }
        #endif
    }

    private func copySymbolicLink(
        from sourcePath: FilePath,
        to destinationPath: FilePath
    ) async throws {
        try await self.threadPool.runIfActive {
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
        try await self.threadPool.runIfActive {
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
            // Doesn't exist: continue
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
            // The two paths are on different logical devices; copy and then remove the original.
            return .success(.differentLogicalDevices)

        case let .failure(errno):
            let error = FileSystemError.rename(
                "rename",
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

        // Finding the index of the last non-'X' character in `lastComponent.string` and advancing
        // it by one.
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
                    // If the file at the generated path already exists, we generate a new file
                    // path.
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
        Syscall.symlink(to: destinationPath, from: linkPath).mapError { errno in
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
