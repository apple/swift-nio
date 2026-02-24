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

/// Options for opening file handles.
public enum OpenOptions: Sendable {
    /// Options for opening a file for reading.
    public struct Read: Hashable, Sendable {
        /// If the last path component is a symbolic link then this flag determines whether the
        /// link is followed. If `false` and the last path component is a symbolic link then an
        /// error is thrown.
        public var followSymbolicLinks: Bool

        /// Marks the descriptor of the opened file as 'close-on-exec'.
        public var closeOnExec: Bool

        /// Creates a new set of options for opening a file for reading.
        ///
        /// - Parameters:
        ///   - followSymbolicLinks: Whether symbolic links should be followed, defaults to `true`.
        ///   - closeOnExec: Whether the descriptor should be marked as closed-on-exec, defaults
        ///     to `false`.
        public init(
            followSymbolicLinks: Bool = true,
            closeOnExec: Bool = false
        ) {
            self.followSymbolicLinks = followSymbolicLinks
            self.closeOnExec = closeOnExec
        }
    }

    /// Options for opening a directory.
    public struct Directory: Hashable, Sendable {
        /// If the last path component is a symbolic link then this flag determines whether the
        /// link is followed. If `false` and the last path component is a symbolic link then an
        /// error is thrown.
        public var followSymbolicLinks: Bool

        /// Marks the descriptor of the opened file as 'close-on-exec'.
        public var closeOnExec: Bool

        /// Creates a new set of options for opening a directory.
        ///
        /// - Parameters:
        ///   - followSymbolicLinks: Whether symbolic links should be followed, defaults to `true`.
        ///   - closeOnExec: Whether the descriptor should be marked as closed-on-exec, defaults
        ///     to `false`.
        public init(
            followSymbolicLinks: Bool = true,
            closeOnExec: Bool = false
        ) {
            self.followSymbolicLinks = followSymbolicLinks
            self.closeOnExec = closeOnExec
        }
    }

    /// Options for opening a file for writing (or reading and writing).
    ///
    /// You can use the following methods to create commonly used sets of options:
    /// - ``newFile(replaceExisting:permissions:)`` to create a new file, optionally replacing
    ///   one which already exists.
    /// - ``modifyFile(createIfNecessary:permissions:)`` to modify an existing file, optionally
    ///   creating it if it doesn't exist.
    public struct Write: Hashable, Sendable {
        /// The behavior for opening an existing file.
        public var existingFile: OpenOptions.ExistingFile

        /// The creation options for a new file, if one should be created. `nil` means that no
        /// file should be created.
        public var newFile: OpenOptions.NewFile?

        /// If the last path component is a symbolic link then this flag determines whether the
        /// link is followed. If `false` and the last path component is a symbolic link then an
        /// error is thrown.
        public var followSymbolicLinks: Bool

        /// Marks the descriptor of the opened file as 'close-on-exec'.
        public var closeOnExec: Bool

        /// Creates a new set of options for opening a directory.
        ///
        /// - Parameters:
        ///   - existingFile: Options for handling an existing file.
        ///   - newFile: Options for creating a new file.
        ///   - followSymbolicLinks: Whether symbolic links should be followed, defaults to `true`.
        ///   - closeOnExec: Whether the descriptor should be marked as closed-on-exec, defaults
        ///     to `false`.
        public init(
            existingFile: OpenOptions.ExistingFile,
            newFile: OpenOptions.NewFile?,
            followSymbolicLinks: Bool = true,
            closeOnExec: Bool = false
        ) {
            self.existingFile = existingFile
            self.newFile = newFile
            self.followSymbolicLinks = followSymbolicLinks
            self.closeOnExec = closeOnExec
        }

        /// Create a new file for writing to.
        ///
        /// - Parameters:
        ///   - replaceExisting: Whether any existing file of the same name is replaced. If
        ///       this is `true` then any existing file of the same name will be replaced with the
        ///       new file. If this is `false` and a file already exists an error is thrown.
        ///   - permissions: The permissions to apply to the newly created file. Default permissions
        ///       (read-write owner permissions and read permissions for everyone else) are applied
        ///       if `nil`.
        /// - Returns: Options for creating a new file for writing.
        public static func newFile(
            replaceExisting: Bool,
            permissions: FilePermissions? = nil
        ) -> Self {
            Write(
                existingFile: replaceExisting ? .truncate : .none,
                newFile: NewFile(permissions: permissions)
            )
        }

        /// Opens a file for modifying.
        ///
        /// - Parameters:
        ///   - createIfNecessary: Whether a file should be created if one doesn't exist. If
        ///     `false` and a file doesn't exist then an error is thrown.
        ///   - permissions: The permissions to apply to the newly created file. Default permissions
        ///       (read-write owner permissions and read permissions for everyone else) are applied
        ///       if `nil`. Ignored if `createIfNonExistent` is `false`.
        /// - Returns: Options for modifying an existing file for writing.
        public static func modifyFile(
            createIfNecessary: Bool,
            permissions: FilePermissions? = nil
        ) -> Self {
            Write(
                existingFile: .open,
                newFile: createIfNecessary ? NewFile(permissions: permissions) : nil
            )
        }
    }
}

extension OpenOptions {
    /// Options for opening an existing file.
    public enum ExistingFile: Sendable, Hashable {
        /// Indicates that no file exists. If a file does exist then an error is thrown when
        /// opening the file.
        case none

        /// Any existing file should be opened without modification.
        case open

        /// Truncate the existing file.
        ///
        /// Setting this is equivalent to opening a file with `O_TRUNC`.
        case truncate
    }

    /// Options for creating a new file.
    public struct NewFile: Sendable, Hashable {
        /// The permissions to apply to the new file. `nil` implies default permissions
        /// should be applied.
        public var permissions: FilePermissions?

        /// Whether the file should be created and updated as a single transaction, if
        /// applicable.
        ///
        /// When this option is set and applied the newly created file will only materialize
        /// on the file system when the file is closed. When used in conjunction with
        /// ``FileSystemProtocol/withFileHandle(forWritingAt:options:execute:)`` and
        /// ``FileSystemProtocol/withFileHandle(forReadingAndWritingAt:options:execute:)`` the
        /// file will only materialize when the file is closed and no errors have been thrown.
        ///
        /// - Important: This flag is only applied if ``OpenOptions/Write/existingFile`` is
        ///   ``OpenOptions/ExistingFile/none``.
        public var transactionalCreation: Bool

        public init(
            permissions: FilePermissions? = nil,
            transactionalCreation: Bool = true
        ) {
            self.permissions = permissions
            self.transactionalCreation = transactionalCreation
        }
    }
}

extension OpenOptions.Write {
    @_spi(Testing)
    public var permissionsForRegularFile: FilePermissions? {
        if let newFile = self.newFile {
            return newFile.permissions ?? .defaultsForRegularFile
        } else {
            return nil
        }
    }

    var descriptorOptions: FileDescriptor.OpenOptions {
        var options = FileDescriptor.OpenOptions()

        if !self.followSymbolicLinks {
            options.insert(.noFollow)
        }

        if self.closeOnExec {
            options.insert(.closeOnExec)
        }

        if self.newFile != nil {
            options.insert(.create)
        }

        switch self.existingFile {
        case .none:
            options.insert(.exclusiveCreate)
        case .open:
            ()
        case .truncate:
            options.insert(.truncate)
        }

        return options
    }
}

extension OpenOptions.Read {
    var descriptorOptions: FileDescriptor.OpenOptions {
        var options = FileDescriptor.OpenOptions()

        if !self.followSymbolicLinks {
            options.insert(.noFollow)
        }

        if self.closeOnExec {
            options.insert(.closeOnExec)
        }

        return options
    }
}

extension OpenOptions.Directory {
    var descriptorOptions: FileDescriptor.OpenOptions {
        var options = FileDescriptor.OpenOptions([.directory])

        if !self.followSymbolicLinks {
            options.insert(.noFollow)
        }

        if self.closeOnExec {
            options.insert(.closeOnExec)
        }

        return options
    }
}

extension FileDescriptor.OpenOptions {
    public init(_ options: OpenOptions.Read) {
        self = options.descriptorOptions
    }

    public init(_ options: OpenOptions.Write) {
        self = options.descriptorOptions
    }

    public init(_ options: OpenOptions.Directory) {
        self = options.descriptorOptions
    }
}

extension FilePermissions {
    /// Default permissions for regular files; owner read-write, group read, other read.
    internal static let defaultsForRegularFile: FilePermissions = [
        .ownerReadWrite,
        .groupRead,
        .otherRead,
    ]

    /// Default permissions for directories; owner read-write-execute, group read-execute, other
    /// read-execute.
    internal static let defaultsForDirectory: FilePermissions = [
        .ownerReadWriteExecute,
        .groupReadExecute,
        .otherReadExecute,
    ]
}
