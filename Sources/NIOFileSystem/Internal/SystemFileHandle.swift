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

import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
@preconcurrency import Glibc
import CNIOLinux
#elseif canImport(Musl)
@preconcurrency import Musl
import CNIOLinux
#elseif canImport(Bionic)
@preconcurrency import Bionic
#endif

/// An implementation of ``FileHandleProtocol`` which is backed by system calls and a file
/// descriptor.
@_spi(Testing)
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public final class SystemFileHandle: Sendable {
    /// The executor on which to execute system calls.
    internal var threadPool: NIOThreadPool { self.sendableView.threadPool }

    /// The path used to open this handle.
    internal var path: FilePath { self.sendableView.path }

    @_spi(Testing)
    public struct Materialization: Sendable {
        /// The path of the file which was created.
        var created: FilePath
        /// The desired path of the file.
        var desired: FilePath
        /// Whether the ``desired`` file must be created exclusively. If `true` then if a file
        /// already exists at the ``desired`` path then an error is thrown, otherwise any existing
        /// file will be replaced.`
        var exclusive: Bool
        /// The mode used to materialize the file.
        var mode: Mode

        enum Mode {
            /// Rename the created file to become the desired file.
            case rename
            #if canImport(Glibc) || canImport(Musl) || canImport(Bionic)
            /// Link the unnamed file to the desired file using 'linkat(2)'.
            case link
            #endif
        }
    }

    fileprivate enum Lifecycle {
        case open(FileDescriptor)
        case detached
        case closed
    }

    @_spi(Testing)
    public let sendableView: SendableView

    /// The file handle may be for a non-seekable file, so it shouldn't be 'Sendable', however, most
    /// of the work performed on behalf of the handle is executed in a thread pool which means that
    /// its state must be 'Sendable'.
    @_spi(Testing)
    public struct SendableView: Sendable {
        /// The lifecycle of the file handle.
        fileprivate let lifecycle: NIOLockedValueBox<Lifecycle>

        /// The executor on which to execute system calls.
        internal let threadPool: NIOThreadPool

        /// The path used to open this handle.
        internal let path: FilePath

        /// An action to take when closing the file handle.
        fileprivate let materialization: Materialization?

        fileprivate init(
            lifecycle: Lifecycle,
            threadPool: NIOThreadPool,
            path: FilePath,
            materialization: Materialization?
        ) {
            self.lifecycle = NIOLockedValueBox(lifecycle)
            self.threadPool = threadPool
            self.path = path
            self.materialization = materialization
        }
    }

    /// Creates a handle which takes ownership of the provided descriptor.
    ///
    /// - Precondition: The descriptor must be open.
    /// - Parameters:
    ///   - descriptor: The open file descriptor.
    ///   - path: The path to the file used to open the descriptor.
    ///   - executor: The executor which system calls will be performed on.
    @_spi(Testing)
    public init(
        takingOwnershipOf descriptor: FileDescriptor,
        path: FilePath,
        materialization: Materialization? = nil,
        threadPool: NIOThreadPool
    ) {
        self.sendableView = SendableView(
            lifecycle: .open(descriptor),
            threadPool: threadPool,
            path: path,
            materialization: materialization
        )
    }

    deinit {
        self.sendableView.lifecycle.withLockedValue { lifecycle -> Void in
            switch lifecycle {
            case .open:
                fatalError(
                    """
                    Leaking file descriptor: the handle for '\(self.sendableView.path)' MUST be closed or \
                    detached with 'close()' or 'detachUnsafeFileDescriptor()' before the final \
                    reference to the handle is dropped.
                    """
                )
            case .detached, .closed:
                ()
            }
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension SystemFileHandle.SendableView {
    /// Returns the file descriptor if it's available; `nil` otherwise.
    internal func descriptorIfAvailable() -> FileDescriptor? {
        self.lifecycle.withLockedValue {
            switch $0 {
            case let .open(descriptor):
                return descriptor
            case .detached, .closed:
                return nil
            }
        }
    }

    /// Executes a closure with the file descriptor if it's available otherwise throws the result
    /// of `onUnavailable`.
    internal func _withUnsafeDescriptor<R>(
        _ execute: (FileDescriptor) throws -> R,
        onUnavailable: () -> FileSystemError
    ) throws -> R {
        if let descriptor = self.descriptorIfAvailable() {
            return try execute(descriptor)
        } else {
            throw onUnavailable()
        }
    }

    /// Executes a closure with the file descriptor if it's available otherwise returns the result
    /// of `onUnavailable` as a `Result` Error.
    internal func _withUnsafeDescriptorResult<R>(
        _ execute: (FileDescriptor) -> Result<R, FileSystemError>,
        onUnavailable: () -> FileSystemError
    ) -> Result<R, FileSystemError> {
        if let descriptor = self.descriptorIfAvailable() {
            return execute(descriptor)
        } else {
            return .failure(onUnavailable())
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension SystemFileHandle: FileHandleProtocol {
    // Notes which apply to the following block of functions:
    //
    // 1. Documentation is inherited from ``FileHandleProtocol`` and is not repeated here.
    // 2. The functions should be annotated with @_spi(Testing); this is not possible with the
    //    conformance to FileHandleProtocol which requires them to be only marked public. However
    //    this is not an issue: the implementing type is annotated with @_spi(Testing) so the
    //    functions are not actually public.
    // 3. Most of these functions call through to a synchronous version prefixed with an underscore,
    //    this is to make testing possible with the system call mocking infrastructure we are
    //    currently using.

    public func info() async throws -> FileInfo {
        try await self.threadPool.runIfActive { [sendableView] in
            try sendableView._info().get()
        }
    }

    public func replacePermissions(_ permissions: FilePermissions) async throws {
        try await self.threadPool.runIfActive { [sendableView] in
            try sendableView._replacePermissions(permissions)
        }
    }

    public func addPermissions(_ permissions: FilePermissions) async throws -> FilePermissions {
        try await self.threadPool.runIfActive { [sendableView] in
            try sendableView._addPermissions(permissions)
        }
    }

    public func removePermissions(_ permissions: FilePermissions) async throws -> FilePermissions {
        try await self.threadPool.runIfActive { [sendableView] in
            try sendableView._removePermissions(permissions)
        }
    }

    public func attributeNames() async throws -> [String] {
        try await self.threadPool.runIfActive { [sendableView] in
            try sendableView._attributeNames()
        }
    }

    public func valueForAttribute(_ name: String) async throws -> [UInt8] {
        try await self.threadPool.runIfActive { [sendableView] in
            try sendableView._valueForAttribute(name)
        }
    }

    public func updateValueForAttribute(
        _ bytes: some (Sendable & RandomAccessCollection<UInt8>),
        attribute name: String
    ) async throws {
        try await self.threadPool.runIfActive { [sendableView] in
            try sendableView._updateValueForAttribute(bytes, attribute: name)
        }
    }

    public func removeValueForAttribute(_ name: String) async throws {
        try await self.threadPool.runIfActive { [sendableView] in
            try sendableView._removeValueForAttribute(name)
        }
    }

    public func synchronize() async throws {
        try await self.threadPool.runIfActive { [sendableView] in
            try sendableView._synchronize()
        }
    }

    public func withUnsafeDescriptor<R: Sendable>(
        _ execute: @Sendable @escaping (FileDescriptor) throws -> R
    ) async throws -> R {
        try await self.threadPool.runIfActive { [sendableView] in
            try sendableView._withUnsafeDescriptor {
                try execute($0)
            } onUnavailable: {
                FileSystemError(
                    code: .closed,
                    message: "File is closed ('\(sendableView.path)').",
                    cause: nil,
                    location: .here()
                )
            }
        }
    }

    public func detachUnsafeFileDescriptor() throws -> FileDescriptor {
        try self.sendableView.lifecycle.withLockedValue { lifecycle in
            switch lifecycle {
            case let .open(descriptor):
                lifecycle = .detached

                // We need to be careful handling files which have delayed materialization to avoid
                // leftover temporary files.
                //
                // Where we use the 'link' mode we simply call materialize and return the
                // descriptor as it will be materialized when closed.
                //
                // For the 'rename' mode we create a hard link to the desired file and unlink the
                // created file.
                guard let materialization = self.sendableView.materialization else {
                    // File opened 'normally', just detach and return.
                    return descriptor
                }

                switch materialization.mode {
                #if canImport(Glibc) || canImport(Musl) || canImport(Bionic)
                case .link:
                    let result = self.sendableView._materializeLink(
                        descriptor: descriptor,
                        from: materialization.created,
                        to: materialization.desired,
                        exclusive: materialization.exclusive
                    )
                    return try result.map { descriptor }.get()
                #endif

                case .rename:
                    let result = Syscall.link(
                        from: materialization.created,
                        to: materialization.desired
                    ).mapError { errno in
                        FileSystemError.link(
                            errno: errno,
                            from: materialization.created,
                            to: materialization.desired,
                            location: .here()
                        )
                    }.flatMap {
                        Syscall.unlink(path: materialization.created).mapError { errno in
                            .unlink(errno: errno, path: materialization.created, location: .here())
                        }
                    }

                    return try result.map { descriptor }.get()
                }

            case .detached:
                throw FileSystemError(
                    code: .closed,
                    message: """
                        File descriptor has already been detached ('\(self.path)'). Handles may \
                        only be detached once.
                        """,
                    cause: nil,
                    location: .here()
                )

            case .closed:
                throw FileSystemError(
                    code: .closed,
                    message: """
                        Cannot detach descriptor for closed file ('\(self.path)'). Handles may \
                        only be detached while they are open.
                        """,
                    cause: nil,
                    location: .here()
                )
            }
        }
    }

    public func close() async throws {
        try await self.threadPool.runIfActive { [sendableView] in
            try sendableView._close(materialize: true).get()
        }
    }

    public func close(makeChangesVisible: Bool) async throws {
        try await self.threadPool.runIfActive { [sendableView] in
            try sendableView._close(materialize: makeChangesVisible).get()
        }
    }

    public func setTimes(
        lastAccess: FileInfo.Timespec?,
        lastDataModification: FileInfo.Timespec?
    ) async throws {
        try await self.threadPool.runIfActive { [sendableView] in
            try sendableView._setTimes(
                lastAccess: lastAccess,
                lastDataModification: lastDataModification
            )
        }
    }

    @_spi(Testing)
    public enum UpdatePermissionsOperation: Sendable { case set, add, remove }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension SystemFileHandle.SendableView {
    /// Returns a string in the format: "{message}, the file '{path}' is closed."
    private func fileIsClosed(_ message: String) -> String {
        "\(message), the file '\(self.path)' is closed."
    }

    /// Returns a string in the format: "{message} for '{path}'."
    private func unknown(_ message: String) -> String {
        "\(message) for '\(self.path)'."
    }

    @_spi(Testing)
    public func _info() -> Result<FileInfo, FileSystemError> {
        self._withUnsafeDescriptorResult { descriptor in
            descriptor.status().map { stat in
                FileInfo(platformSpecificStatus: stat)
            }.mapError { errno in
                .stat("fstat", errno: errno, path: self.path, location: .here())
            }
        } onUnavailable: {
            FileSystemError(
                code: .closed,
                message: self.fileIsClosed("Unable to get information"),
                cause: nil,
                location: .here()
            )
        }
    }

    @_spi(Testing)
    public func _replacePermissions(_ permissions: FilePermissions) throws {
        try self._withUnsafeDescriptor { descriptor in
            try self.updatePermissions(
                permissions,
                operation: .set,
                operand: permissions,
                descriptor: descriptor
            )
        } onUnavailable: {
            FileSystemError(
                code: .closed,
                message: self.fileIsClosed("Unable to replace permissions"),
                cause: nil,
                location: .here()
            )
        }
    }

    @_spi(Testing)
    public func _addPermissions(_ permissions: FilePermissions) throws -> FilePermissions {
        try self._withUnsafeDescriptor { descriptor in
            switch descriptor.status() {
            case let .success(status):
                let info = FileInfo(platformSpecificStatus: status)
                let merged = info.permissions.union(permissions)

                // Check if we need to make any changes.
                if merged == info.permissions {
                    return merged
                }

                // Apply the new permissions.
                try self.updatePermissions(
                    merged,
                    operation: .add,
                    operand: permissions,
                    descriptor: descriptor
                )

                return merged

            case let .failure(errno):
                throw FileSystemError(
                    message: "Unable to add permissions.",
                    wrapping: .stat("fstat", errno: errno, path: self.path, location: .here())
                )
            }
        } onUnavailable: {
            FileSystemError(
                code: .closed,
                message: self.fileIsClosed("Unable to add permissions"),
                cause: nil,
                location: .here()
            )
        }
    }

    @_spi(Testing)
    public func _removePermissions(_ permissions: FilePermissions) throws -> FilePermissions {
        try self._withUnsafeDescriptor { descriptor in
            switch descriptor.status() {
            case let .success(status):
                let info = FileInfo(platformSpecificStatus: status)
                let merged = info.permissions.subtracting(permissions)

                // Check if we need to make any changes.
                if merged == info.permissions {
                    return merged
                }

                // Apply the new permissions.
                try self.updatePermissions(
                    merged,
                    operation: .remove,
                    operand: permissions,
                    descriptor: descriptor
                )

                return merged

            case let .failure(errno):
                throw FileSystemError(
                    message: "Unable to remove permissions.",
                    wrapping: .stat("fstat", errno: errno, path: self.path, location: .here())
                )

            }
        } onUnavailable: {
            FileSystemError(
                code: .closed,
                message: self.fileIsClosed("Unable to remove permissions"),
                cause: nil,
                location: .here()
            )
        }
    }

    private func updatePermissions(
        _ permissions: FilePermissions,
        operation: SystemFileHandle.UpdatePermissionsOperation,
        operand: FilePermissions,
        descriptor: FileDescriptor
    ) throws {
        try descriptor.changeMode(permissions).mapError { errno in
            FileSystemError.fchmod(
                operation: operation,
                operand: operand,
                permissions: permissions,
                errno: errno,
                path: self.path,
                location: .here()
            )
        }.get()
    }

    @_spi(Testing)
    public func _attributeNames() throws -> [String] {
        try self._withUnsafeDescriptor { descriptor in
            try descriptor.listExtendedAttributes().mapError { errno in
                FileSystemError.flistxattr(errno: errno, path: self.path, location: .here())
            }.get()
        } onUnavailable: {
            FileSystemError(
                code: .closed,
                message: self.fileIsClosed("Could not list extended attributes"),
                cause: nil,
                location: .here()
            )
        }
    }

    @_spi(Testing)
    public func _valueForAttribute(_ name: String) throws -> [UInt8] {
        try self._withUnsafeDescriptor { descriptor in
            try descriptor.readExtendedAttribute(
                named: name
            ).flatMapError { errno -> Result<[UInt8], FileSystemError> in
                switch errno {
                #if canImport(Darwin)
                case .attributeNotFound:
                    // Okay, return empty value.
                    return .success([])
                #endif
                case .noData:
                    // Okay, return empty value.
                    return .success([])
                default:
                    let error = FileSystemError.fgetxattr(
                        attribute: name,
                        errno: errno,
                        path: self.path,
                        location: .here()
                    )
                    return .failure(error)
                }
            }.get()
        } onUnavailable: {
            FileSystemError(
                code: .closed,
                message: self.fileIsClosed(
                    "Could not get value for extended attribute ('\(name)')"
                ),
                cause: nil,
                location: .here()
            )
        }
    }

    @_spi(Testing)
    public func _updateValueForAttribute(
        _ bytes: some RandomAccessCollection<UInt8>,
        attribute name: String
    ) throws {
        try self._withUnsafeDescriptor { descriptor in
            func withUnsafeBufferPointer(_ body: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
                try bytes.withContiguousStorageIfAvailable(body)
                    ?? Array(bytes).withUnsafeBufferPointer(body)
            }

            try withUnsafeBufferPointer { pointer in
                let rawBufferPointer = UnsafeRawBufferPointer(pointer)
                return try descriptor.setExtendedAttribute(
                    named: name,
                    to: rawBufferPointer
                ).mapError { errno in
                    FileSystemError.fsetxattr(
                        attribute: name,
                        errno: errno,
                        path: self.path,
                        location: .here()
                    )
                }.get()
            }
        } onUnavailable: {
            FileSystemError(
                code: .closed,
                message: self.fileIsClosed(
                    "Could not set value for extended attribute ('\(name)')"
                ),
                cause: nil,
                location: .here()
            )
        }
    }

    @_spi(Testing)
    public func _removeValueForAttribute(_ name: String) throws {
        try self._withUnsafeDescriptor { descriptor in
            try descriptor.removeExtendedAttribute(name).mapError { errno in
                FileSystemError.fremovexattr(
                    attribute: name,
                    errno: errno,
                    path: self.path,
                    location: .here()
                )
            }.get()
        } onUnavailable: {
            FileSystemError(
                code: .closed,
                message: self.fileIsClosed("Could not remove extended attribute ('\(name)')"),
                cause: nil,
                location: .here()
            )
        }
    }

    @_spi(Testing)
    public func _synchronize() throws {
        try self._withUnsafeDescriptor { descriptor in
            try descriptor.synchronize().mapError { errno in
                FileSystemError.fsync(errno: errno, path: self.path, location: .here())
            }.get()
        } onUnavailable: {
            FileSystemError(
                code: .closed,
                message: self.fileIsClosed("Could not synchronize"),
                cause: nil,
                location: .here()
            )
        }
    }

    internal func _duplicate() -> Result<FileDescriptor, FileSystemError> {
        self._withUnsafeDescriptorResult { descriptor in
            Result {
                try descriptor.duplicate()
            }.mapError { error in
                FileSystemError.dup(error: error, path: self.path, location: .here())
            }
        } onUnavailable: {
            FileSystemError(
                code: .closed,
                message: "Unable to duplicate descriptor of closed handle for '\(self.path)'.",
                cause: nil,
                location: .here()
            )
        }
    }

    @_spi(Testing)
    public func _close(materialize: Bool, failRenameat2WithEINVAL: Bool = false) -> Result<Void, FileSystemError> {
        let descriptor: FileDescriptor? = self.lifecycle.withLockedValue { lifecycle in
            switch lifecycle {
            case let .open(descriptor):
                lifecycle = .closed
                return descriptor
            case .detached, .closed:
                return nil
            }
        }

        guard let descriptor = descriptor else {
            return .success(())
        }

        // Materialize then close.
        let materializeResult = self._materialize(
            materialize,
            descriptor: descriptor,
            failRenameat2WithEINVAL: failRenameat2WithEINVAL
        )

        return Result {
            try descriptor.close()
        }.mapError { error in
            .close(error: error, path: self.path, location: .here())
        }.flatMap {
            materializeResult
        }
    }

    #if canImport(Glibc) || canImport(Musl) || canImport(Bionic)
    fileprivate func _materializeLink(
        descriptor: FileDescriptor,
        from createdPath: FilePath,
        to desiredPath: FilePath,
        exclusive: Bool
    ) -> Result<Void, FileSystemError> {
        func linkAtEmptyPath() -> Result<Void, Errno> {
            Syscall.linkAt(
                from: "",
                relativeTo: descriptor,
                to: desiredPath,
                relativeTo: .currentWorkingDirectory,
                flags: [.emptyPath]
            )
        }

        func linkAtProcFS() -> Result<Void, Errno> {
            Syscall.linkAt(
                from: FilePath("/proc/self/fd/\(descriptor.rawValue)"),
                relativeTo: .currentWorkingDirectory,
                to: desiredPath,
                relativeTo: .currentWorkingDirectory,
                flags: [.followSymbolicLinks]
            )
        }

        let result: Result<Void, FileSystemError>

        switch linkAtEmptyPath() {
        case .success:
            result = .success(())

        case .failure(.fileExists) where !exclusive:
            // File exists and materialization _isn't_ exclusive. Remove the existing
            // file and try again.
            let removeResult = Libc.remove(desiredPath).mapError { errno in
                FileSystemError.remove(errno: errno, path: desiredPath, location: .here())
            }

            let linkAtResult = linkAtEmptyPath().flatMapError { errno in
                // ENOENT means we likely didn't have the 'CAP_DAC_READ_SEARCH' capability
                // so try again by linking to the descriptor via procfs.
                if errno == .noSuchFileOrDirectory {
                    return linkAtProcFS()
                } else {
                    return .failure(errno)
                }
            }.mapError { errno in
                FileSystemError.link(
                    errno: errno,
                    from: createdPath,
                    to: desiredPath,
                    location: .here()
                )
            }

            result = removeResult.flatMap { linkAtResult }

        case .failure(.noSuchFileOrDirectory):
            result = linkAtProcFS().flatMapError { errno in
                if errno == .fileExists, !exclusive {
                    return Libc.remove(desiredPath).mapError { errno in
                        FileSystemError.remove(
                            errno: errno,
                            path: desiredPath,
                            location: .here()
                        )
                    }.flatMap {
                        linkAtProcFS().mapError { errno in
                            FileSystemError.link(
                                errno: errno,
                                from: createdPath,
                                to: desiredPath,
                                location: .here()
                            )
                        }
                    }
                } else {
                    let error = FileSystemError.link(
                        errno: errno,
                        from: createdPath,
                        to: desiredPath,
                        location: .here()
                    )
                    return .failure(error)
                }
            }

        case .failure(let errno):
            result = .failure(
                .link(errno: errno, from: createdPath, to: desiredPath, location: .here())
            )
        }

        return result
    }
    #endif

    func _materialize(
        _ materialize: Bool,
        descriptor: FileDescriptor,
        failRenameat2WithEINVAL: Bool
    ) -> Result<Void, FileSystemError> {
        guard let materialization = self.materialization else { return .success(()) }

        let createdPath = materialization.created
        let desiredPath = materialization.desired

        let result: Result<Void, FileSystemError>
        switch materialization.mode {
        #if canImport(Glibc) || canImport(Musl) || canImport(Bionic)
        case .link:
            if materialize {
                result = self._materializeLink(
                    descriptor: descriptor,
                    from: createdPath,
                    to: desiredPath,
                    exclusive: materialization.exclusive
                )
            } else {
                result = .success(())
            }
        #endif

        case .rename:
            if materialize {
                var renameResult: Result<Void, Errno>
                let renameFunction: String
                #if canImport(Darwin)
                renameFunction = "renamex_np"
                renameResult = Syscall.rename(
                    from: createdPath,
                    to: desiredPath,
                    options: materialization.exclusive ? [.exclusive] : []
                )
                #elseif canImport(Glibc) || canImport(Musl) || canImport(Bionic)
                // The created and desired paths are absolute, so the relative descriptors are
                // ignored. However, they must still be provided to 'rename' in order to pass
                // flags.
                renameFunction = "renameat2"
                if materialization.exclusive, failRenameat2WithEINVAL {
                    renameResult = .failure(.invalidArgument)
                } else {
                    renameResult = Syscall.rename(
                        from: createdPath,
                        relativeTo: .currentWorkingDirectory,
                        to: desiredPath,
                        relativeTo: .currentWorkingDirectory,
                        flags: materialization.exclusive ? [.exclusive] : []
                    )
                }
                #endif

                if materialization.exclusive {
                    switch renameResult {
                    case .failure(.fileExists):
                        // A file exists at the desired path and the user specified exclusive
                        // creation, clear up by removing the file that we did create.
                        _ = Libc.remove(createdPath)

                    case .failure(.invalidArgument):
                        // If 'renameat2' failed on Linux with EINVAL then in all likelihood the
                        // 'RENAME_NOREPLACE' option isn't supported. As we're doing an exclusive
                        // create, check the desired path doesn't exist then do a regular rename.
                        #if canImport(Glibc) || canImport(Musl) || canImport(Bionic)
                        switch Syscall.stat(path: desiredPath) {
                        case .failure(.noSuchFileOrDirectory):
                            // File doesn't exist, do a 'regular' rename.
                            renameResult = Syscall.rename(from: createdPath, to: desiredPath)

                        case .success:
                            // File exists so exclusive create isn't possible. Remove the file
                            // we did create then throw.
                            _ = Libc.remove(createdPath)
                            let error = FileSystemError(
                                code: .fileAlreadyExists,
                                message: """
                                    Couldn't open '\(desiredPath)', it already exists and the \
                                    file was opened with the 'existingFile' option set to 'none'.
                                    """,
                                cause: nil,
                                location: .here()
                            )
                            return .failure(error)

                        case .failure:
                            // Failed to stat the desired file for reasons unknown. Remove the file
                            // we did create then throw.
                            _ = Libc.remove(createdPath)
                            let error = FileSystemError(
                                code: .unknown,
                                message: "Couldn't open '\(desiredPath)'.",
                                cause: FileSystemError.rename(
                                    "renameat2",
                                    errno: .invalidArgument,
                                    oldName: createdPath,
                                    newName: desiredPath,
                                    location: .here()
                                ),
                                location: .here()
                            )
                            return .failure(error)
                        }
                        #else
                        ()  // Not Linux, use the normal error flow.
                        #endif

                    case .success, .failure:
                        ()
                    }
                }

                result = renameResult.mapError { errno in
                    .rename(
                        renameFunction,
                        errno: errno,
                        oldName: createdPath,
                        newName: desiredPath,
                        location: .here()
                    )
                }
            } else {
                // Don't materialize the source, remove it
                result = Libc.remove(createdPath).mapError {
                    .remove(errno: $0, path: createdPath, location: .here())
                }
            }
        }

        return result
    }

    func _setTimes(
        lastAccess: FileInfo.Timespec?,
        lastDataModification: FileInfo.Timespec?
    ) throws {
        try self._withUnsafeDescriptor { descriptor in
            let syscallResult: Result<Void, Errno>
            switch (lastAccess, lastDataModification) {
            case (.none, .none):
                // If the timespec array is nil, as per the `futimens` docs,
                // both the last accessed and last modification times
                // will be set to now.
                syscallResult = Syscall.futimens(
                    fileDescriptor: descriptor,
                    times: nil
                )

            case (.some(let lastAccess), .none):
                // Don't modify the last modification time.
                syscallResult = Syscall.futimens(
                    fileDescriptor: descriptor,
                    times: [timespec(lastAccess), timespec(.omit)]
                )

            case (.none, .some(let lastDataModification)):
                // Don't modify the last access time.
                syscallResult = Syscall.futimens(
                    fileDescriptor: descriptor,
                    times: [timespec(.omit), timespec(lastDataModification)]
                )

            case (.some(let lastAccess), .some(let lastDataModification)):
                syscallResult = Syscall.futimens(
                    fileDescriptor: descriptor,
                    times: [timespec(lastAccess), timespec(lastDataModification)]
                )
            }

            try syscallResult.mapError { errno in
                FileSystemError.futimens(
                    errno: errno,
                    path: self.path,
                    lastAccessTime: lastAccess,
                    lastDataModificationTime: lastDataModification,
                    location: .here()
                )
            }.get()
        } onUnavailable: {
            FileSystemError(
                code: .closed,
                message: "Couldn't modify file dates, the file '\(self.path)' is closed.",
                cause: nil,
                location: .here()
            )
        }
    }
}

extension timespec {
    fileprivate init(_ fileinfoTimespec: FileInfo.Timespec) {
        // Clamp seconds to be positive
        let seconds = max(0, fileinfoTimespec.seconds)

        // If nanoseconds are not UTIME_NOW or UTIME_OMIT, clamp to be between
        // 0 and 1,000 million.
        let nanoseconds: Int
        switch fileinfoTimespec {
        case .now, .omit:
            nanoseconds = fileinfoTimespec.nanoseconds
        default:
            nanoseconds = min(1_000_000_000, max(0, fileinfoTimespec.nanoseconds))
        }

        self.init(
            tv_sec: seconds,
            tv_nsec: nanoseconds
        )
    }
}

// MARK: - Readable File Handle

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension SystemFileHandle: ReadableFileHandleProtocol {
    // Notes which apply to the following block of functions:
    //
    // 1. Documentation is inherited from ``FileHandleProtocol`` and is not repeated here.
    // 2. The functions should be annotated with @_spi(Testing); this is not possible with the
    //    conformance to FileHandleProtocol which requires them to be only marked public. However
    //    this is not an issue: the implementing type is annotated with @_spi(Testing) so the
    //    functions are not actually public.

    public func readChunk(
        fromAbsoluteOffset offset: Int64,
        length: ByteCount
    ) async throws -> ByteBuffer {
        try await self.threadPool.runIfActive { [sendableView] in
            try sendableView._withUnsafeDescriptor { descriptor in
                try descriptor.readChunk(
                    fromAbsoluteOffset: offset,
                    length: length.bytes
                ).flatMapError { error in
                    if let errno = error as? Errno, errno == .illegalSeek {
                        guard offset == 0 else {
                            return .failure(
                                FileSystemError(
                                    code: .unsupported,
                                    message: "File is unseekable.",
                                    cause: nil,
                                    location: .here()
                                )
                            )
                        }

                        return descriptor.readChunk(length: length.bytes).mapError { error in
                            FileSystemError.read(
                                usingSyscall: .read,
                                error: error,
                                path: sendableView.path,
                                location: .here()
                            )
                        }
                    } else {
                        return .failure(
                            FileSystemError.read(
                                usingSyscall: .pread,
                                error: error,
                                path: sendableView.path,
                                location: .here()
                            )
                        )
                    }
                }
                .get()
            } onUnavailable: {
                FileSystemError(
                    code: .closed,
                    message: "Couldn't read chunk, the file '\(sendableView.path)' is closed.",
                    cause: nil,
                    location: .here()
                )
            }
        }
    }

    public func readChunks(
        in range: Range<Int64>,
        chunkLength size: ByteCount
    ) -> FileChunks {
        FileChunks(handle: self, chunkLength: size, range: range)
    }
}

// MARK: - Writable File Handle

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension SystemFileHandle: WritableFileHandleProtocol {
    @discardableResult
    public func write(
        contentsOf bytes: some (Sequence<UInt8> & Sendable),
        toAbsoluteOffset offset: Int64
    ) async throws -> Int64 {
        try await self.threadPool.runIfActive { [sendableView] in
            try sendableView._withUnsafeDescriptor { descriptor in
                try descriptor.write(contentsOf: bytes, toAbsoluteOffset: offset)
                    .flatMapError { error in
                        if let errno = error as? Errno, errno == .illegalSeek {
                            guard offset == 0 else {
                                return .failure(
                                    FileSystemError(
                                        code: .unsupported,
                                        message: "File is unseekable.",
                                        cause: nil,
                                        location: .here()
                                    )
                                )
                            }

                            return descriptor.write(contentsOf: bytes)
                                .mapError { error in
                                    FileSystemError.write(
                                        usingSyscall: .write,
                                        error: error,
                                        path: sendableView.path,
                                        location: .here()
                                    )
                                }
                        } else {
                            return .failure(
                                FileSystemError.write(
                                    usingSyscall: .pwrite,
                                    error: error,
                                    path: sendableView.path,
                                    location: .here()
                                )
                            )
                        }
                    }
                    .get()
            } onUnavailable: {
                FileSystemError(
                    code: .closed,
                    message: "Couldn't write bytes, the file '\(sendableView.path)' is closed.",
                    cause: nil,
                    location: .here()
                )
            }
        }
    }

    public func resize(to size: ByteCount) async throws {
        try await self.threadPool.runIfActive { [sendableView] in
            try sendableView._resize(to: size).get()
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension SystemFileHandle.SendableView {
    func _resize(to size: ByteCount) -> Result<(), FileSystemError> {
        self._withUnsafeDescriptorResult { descriptor in
            Result {
                try descriptor.resize(to: size.bytes, retryOnInterrupt: true)
            }.mapError { error in
                FileSystemError.ftruncate(error: error, path: self.path, location: .here())
            }
        } onUnavailable: {
            FileSystemError(
                code: .closed,
                message: "Unable to resize file '\(self.path)'.",
                cause: nil,
                location: .here()
            )
        }
    }
}

// MARK: - Directory File Handle

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension SystemFileHandle: DirectoryFileHandleProtocol {
    public typealias ReadFileHandle = SystemFileHandle
    public typealias WriteFileHandle = SystemFileHandle
    public typealias ReadWriteFileHandle = SystemFileHandle

    public func listContents(recursive: Bool) -> DirectoryEntries {
        DirectoryEntries(handle: self, recursive: recursive)
    }

    public func openFile(
        forReadingAt path: NIOFilePath,
        options: OpenOptions.Read
    ) async throws -> SystemFileHandle {
        let opts = options.descriptorOptions.union(.nonBlocking)
        let handle = try await self.threadPool.runIfActive { [sendableView] in
            let handle = try sendableView._open(
                atPath: path.underlying,
                mode: .readOnly,
                options: opts,
                transactionalIfPossible: false
            ).get()
            // Okay to transfer: we just created it and are now moving back to the callers task.
            return UnsafeTransfer(handle)
        }
        return handle.wrappedValue
    }

    public func openFile(
        forReadingAndWritingAt path: NIOFilePath,
        options: OpenOptions.Write
    ) async throws -> SystemFileHandle {
        let perms = options.permissionsForRegularFile
        let opts = options.descriptorOptions.union(.nonBlocking)
        let handle = try await self.threadPool.runIfActive { [sendableView] in
            let handle = try sendableView._open(
                atPath: path.underlying,
                mode: .readWrite,
                options: opts,
                permissions: perms,
                transactionalIfPossible: options.newFile?.transactionalCreation ?? false
            ).get()
            // Okay to transfer: we just created it and are now moving back to the callers task.
            return UnsafeTransfer(handle)
        }
        return handle.wrappedValue
    }

    public func openFile(
        forWritingAt path: NIOFilePath,
        options: OpenOptions.Write
    ) async throws -> SystemFileHandle {
        let perms = options.permissionsForRegularFile
        let opts = options.descriptorOptions.union(.nonBlocking)
        let handle = try await self.threadPool.runIfActive { [sendableView] in
            let handle = try sendableView._open(
                atPath: path.underlying,
                mode: .writeOnly,
                options: opts,
                permissions: perms,
                transactionalIfPossible: options.newFile?.transactionalCreation ?? false
            ).get()
            // Okay to transfer: we just created it and are now moving back to the callers task.
            return UnsafeTransfer(handle)
        }
        return handle.wrappedValue
    }

    public func openDirectory(
        atPath path: NIOFilePath,
        options: OpenOptions.Directory
    ) async throws -> SystemFileHandle {
        let opts = options.descriptorOptions.union(.nonBlocking)
        let handle = try await self.threadPool.runIfActive { [sendableView] in
            let handle = try sendableView._open(
                atPath: path.underlying,
                mode: .readOnly,
                options: opts,
                transactionalIfPossible: false
            ).get()
            // Okay to transfer: we just created it and are now moving back to the callers task.
            return UnsafeTransfer(handle)
        }
        return handle.wrappedValue
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension SystemFileHandle.SendableView {
    func _open(
        atPath path: FilePath,
        mode: FileDescriptor.AccessMode,
        options: FileDescriptor.OpenOptions,
        permissions: FilePermissions? = nil,
        transactionalIfPossible transactional: Bool
    ) -> Result<SystemFileHandle, FileSystemError> {
        if transactional {
            if path.isAbsolute {
                // The provided path is absolute: just open the handle normally.
                return SystemFileHandle.syncOpen(
                    atPath: path,
                    mode: mode,
                    options: options,
                    permissions: permissions,
                    transactionalIfPossible: transactional,
                    threadPool: self.threadPool
                )
            } else if self.path.isAbsolute {
                // The parent path is absolute and the provided path is relative; combine them.
                return SystemFileHandle.syncOpen(
                    atPath: self.path.appending(path.components),
                    mode: mode,
                    options: options,
                    permissions: permissions,
                    transactionalIfPossible: transactional,
                    threadPool: self.threadPool
                )
            }

            // At this point transactional file creation isn't possible. Fallback to
            // non-transactional.
        }

        // Provided and parent paths are relative. There's no way we can safely delay
        // materialization as we don't know if the parent descriptor will be available when
        // closing the opened file.
        return self._withUnsafeDescriptorResult { descriptor in
            descriptor.open(
                atPath: path,
                mode: mode,
                options: options,
                permissions: permissions
            ).map { newDescriptor in
                SystemFileHandle(
                    takingOwnershipOf: newDescriptor,
                    path: self.path.appending(path.components).lexicallyNormalized(),
                    threadPool: self.threadPool
                )
            }.mapError { errno in
                .open("openat", error: errno, path: self.path, location: .here())
            }
        } onUnavailable: {
            FileSystemError(
                code: .closed,
                message: """
                    Unable to open file at path '\(path)' relative to '\(self.path)', the file \
                    is closed.
                    """,
                cause: nil,
                location: .here()
            )
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension SystemFileHandle {
    static func syncOpen(
        atPath path: FilePath,
        mode: FileDescriptor.AccessMode,
        options: FileDescriptor.OpenOptions,
        permissions: FilePermissions?,
        transactionalIfPossible transactional: Bool,
        threadPool: NIOThreadPool
    ) -> Result<SystemFileHandle, FileSystemError> {
        let isWritable = (mode == .writeOnly || mode == .readWrite)
        let exclusiveCreate = options.contains(.exclusiveCreate)
        let truncate = options.contains(.truncate)
        let delayMaterialization = transactional && isWritable && (exclusiveCreate || truncate)

        if delayMaterialization {
            // When opening in this mode we can more "atomically" create the file, that is, by not
            // leaving the user with a half written file should e.g. the system crash or throw an
            // error while writing. On non-Android Linux we do this by opening the directory for
            // the path with `O_TMPFILE` and creating a hard link when closing the file. On other
            // platforms we generate a dot file with a randomised suffix name and rename it to the
            // destination.
            #if os(Android)
            let temporaryHardLink = false
            #else
            let temporaryHardLink = true
            #endif
            return Self.syncOpenWithMaterialization(
                atPath: path,
                mode: mode,
                options: options,
                permissions: permissions,
                threadPool: threadPool,
                useTemporaryFileIfPossible: temporaryHardLink
            )
        } else {
            return Self.syncOpen(
                atPath: path,
                mode: mode,
                options: options,
                permissions: permissions,
                threadPool: threadPool
            )
        }
    }

    static func syncOpen(
        atPath path: FilePath,
        mode: FileDescriptor.AccessMode,
        options: FileDescriptor.OpenOptions,
        permissions: FilePermissions?,
        threadPool: NIOThreadPool
    ) -> Result<SystemFileHandle, FileSystemError> {
        Result {
            try FileDescriptor.open(
                path,
                mode,
                options: options,
                permissions: permissions
            )
        }.map { descriptor in
            SystemFileHandle(
                takingOwnershipOf: descriptor,
                path: path,
                threadPool: threadPool
            )
        }.mapError { errno in
            FileSystemError.open("open", error: errno, path: path, location: .here())
        }
    }

    @_spi(Testing)
    public static func syncOpenWithMaterialization(
        atPath path: FilePath,
        mode: FileDescriptor.AccessMode,
        options originalOptions: FileDescriptor.OpenOptions,
        permissions: FilePermissions?,
        threadPool: NIOThreadPool,
        useTemporaryFileIfPossible: Bool = true
    ) -> Result<SystemFileHandle, FileSystemError> {
        let openedPath: FilePath
        let desiredPath: FilePath

        // There are two different approaches to materializing the file. On Linux, and where
        // supported, we can open the file with the 'O_TMPFILE' flag which creates a temporary
        // unnamed file. If we later decide the make the file visible we use 'linkat(2)' with
        // the appropriate flags to link the unnamed temporary file to the desired file path.
        //
        // On other platforms, and when not supported on Linux, we create a regular file as we
        // normally would and when we decide to materialize it we simply rename it to the desired
        // name (or remove it if we aren't materializing it).
        //
        // There are, however, some wrinkles.
        //
        // Normally when a file is opened the system will open files specified with relative paths
        // relative to the current working directory. However, when we delay making a file visible
        // the current working directory could change which introduces an awkward race. Consider
        // the following sequence of events:
        //
        // 1. User opens a file with delay materialization using a relative path
        // 2. A temporary file is opened relative to the current working directory
        // 3. The current working directory is changed
        // 4. The file is closed.
        //
        // Where is the file created? It *should* be relative to the working directory at the time
        // the user opened the file. However, if materializing the file relative to the new
        // working directory would be very surprising behaviour for the user.
        //
        // To work around this we will get the current working directory only if the provided path
        // is relative. That way all operations can be done on a path relative to a fixed point
        // (i.e. the current working directory at this point in time).
        if path.isRelative {
            let currentWorkingDirectory: FilePath

            switch Libc.getcwd() {
            case .success(let path):
                currentWorkingDirectory = path
            case .failure(let errno):
                let error = FileSystemError(
                    message: """
                        Can't open relative '\(path)' as the current working directory couldn't \
                        be determined.
                        """,
                    wrapping: .getcwd(errno: errno, location: .here())
                )
                return .failure(error)
            }

            func makePath() -> FilePath {
                #if canImport(Glibc) || canImport(Musl) || canImport(Bionic)
                if useTemporaryFileIfPossible {
                    return currentWorkingDirectory.appending(path.components.dropLast())
                }
                #endif
                return currentWorkingDirectory.appending(path.components.dropLast())
                    .appending(".tmp-" + String(randomAlphaNumericOfLength: 6))
            }

            openedPath = makePath()
            desiredPath = currentWorkingDirectory.appending(path.components)
        } else {
            func makePath() -> FilePath {
                #if canImport(Glibc) || canImport(Musl) || canImport(Bionic)
                if useTemporaryFileIfPossible {
                    return path.removingLastComponent()
                }
                #endif
                return path.removingLastComponent()
                    .appending(".tmp-" + String(randomAlphaNumericOfLength: 6))
            }

            openedPath = makePath()
            desiredPath = path
        }

        let materializationMode: Materialization.Mode
        let options: FileDescriptor.OpenOptions

        #if canImport(Glibc) || canImport(Musl) || canImport(Bionic)
        if useTemporaryFileIfPossible {
            options = [.temporaryFile]
            materializationMode = .link
        } else {
            options = originalOptions
            materializationMode = .rename
        }
        #else
        options = originalOptions
        materializationMode = .rename
        #endif

        let materialization = Materialization(
            created: openedPath,
            desired: desiredPath,
            exclusive: originalOptions.contains(.exclusiveCreate),
            mode: materializationMode
        )

        do {
            let descriptor = try FileDescriptor.open(
                openedPath,
                mode,
                options: options,
                permissions: permissions
            )

            let handle = SystemFileHandle(
                takingOwnershipOf: descriptor,
                path: openedPath,
                materialization: materialization,
                threadPool: threadPool
            )

            return .success(handle)
        } catch {
            #if canImport(Glibc) || canImport(Musl) || canImport(Bionic)
            // 'O_TMPFILE' isn't supported for the current file system, try again but using
            // rename instead.
            if useTemporaryFileIfPossible, let errno = error as? Errno, errno == .notSupported {
                return Self.syncOpenWithMaterialization(
                    atPath: path,
                    mode: mode,
                    options: originalOptions,
                    permissions: permissions,
                    threadPool: threadPool,
                    useTemporaryFileIfPossible: false
                )
            }
            #endif
            return .failure(.open("open", error: error, path: path, location: .here()))
        }
    }
}
