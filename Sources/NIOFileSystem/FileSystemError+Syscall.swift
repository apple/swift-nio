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

import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#endif

extension FileSystemError {
    /// Creates a ``FileSystemError`` by constructing a ``SystemCallError`` as the cause.
    internal init(
        code: Code,
        message: String,
        systemCall: String,
        errno: Errno,
        location: SourceLocation
    ) {
        self.init(
            code: code,
            message: message,
            cause: SystemCallError(systemCall: systemCall, errno: errno),
            location: location
        )
    }
}

extension FileSystemError {
    /// Create a file system error appropriate for the `stat`/`lstat`/`fstat` system calls.
    @_spi(Testing)
    public static func stat(
        _ name: String,
        errno: Errno,
        path: FilePath,
        location: SourceLocation
    ) -> Self {
        let code: FileSystemError.Code
        let message: String

        // See: 'man 2 fstat'
        switch errno {
        case .badFileDescriptor:
            code = .closed
            message = "Unable to get information about '\(path)', the file is closed."
        default:
            code = .unknown
            message = "Unable to get information about '\(path)'."
        }

        return FileSystemError(
            code: code,
            message: message,
            systemCall: name,
            errno: errno,
            location: location
        )
    }

    @_spi(Testing)
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    public static func fchmod(
        operation: SystemFileHandle.UpdatePermissionsOperation,
        operand: FilePermissions,
        permissions: FilePermissions,
        errno: Errno,
        path: FilePath,
        location: SourceLocation
    ) -> Self {
        let message: String
        let code: FileSystemError.Code

        // See: 'man 2 fchmod'
        switch errno {
        case .badFileDescriptor:
            code = .closed
            message = "Could not \(operation) permissions '\(operand)', '\(path)' is closed."

        case .invalidArgument:
            // Permissions are invalid so display the raw value in octal.
            let rawPermissions = String(permissions.rawValue, radix: 0o10)
            let op: String
            switch operation {
            case .set:
                op = "set"
            case .add:
                op = "added"
            case .remove:
                op = "removed"
            }
            code = .invalidArgument
            message = """
                Invalid permissions ('\(rawPermissions)') could not be \(op) for file '\(path)'.
                """

        case .notPermitted:
            code = .permissionDenied
            message = """
                Not permitted to \(operation) permissions '\(operand)' for file '\(path)', \
                the effective user ID does not match the owner of the file and the effective \
                user ID is not the super-user.
                """

        default:
            code = .unknown
            message = "Could not \(operation) permissions '\(operand)' to '\(path)'."
        }

        return FileSystemError(
            code: code,
            message: message,
            systemCall: "fchmod",
            errno: errno,
            location: location
        )
    }

    @_spi(Testing)
    public static func flistxattr(errno: Errno, path: FilePath, location: SourceLocation) -> Self {
        let code: FileSystemError.Code
        let message: String

        switch errno {
        case .badFileDescriptor:
            code = .closed
            message = "Could not list extended attributes, '\(path)' is closed."

        case .notSupported:
            code = .unsupported
            message = "Extended attributes are disabled or not supported by the filesystem."

        case .notPermitted:
            code = .unsupported
            message = "Extended attributes are not supported by '\(path)'."

        case .permissionDenied:
            code = .permissionDenied
            message = "Not permitted to list extended attributes for '\(path)'."

        default:
            code = .unknown
            message = "Could not to list extended attributes for '\(path)'."
        }

        return FileSystemError(
            code: code,
            message: message,
            systemCall: "flistxattr",
            errno: errno,
            location: location
        )
    }

    @_spi(Testing)
    public static func fgetxattr(
        attribute name: String,
        errno: Errno,
        path: FilePath,
        location: SourceLocation
    ) -> Self {
        let code: FileSystemError.Code
        let message: String

        switch errno {
        case .badFileDescriptor:
            code = .closed
            message = """
                Could not get value for extended attribute ('\(name)'), '\(path)' is closed.
                """
        case .notSupported:
            code = .unsupported
            message = "Extended attributes are disabled or not supported by the filesystem."
        #if canImport(Darwin)
        case .fileNameTooLong:
            code = .invalidArgument
            message = """
                Length of UTF-8 extended attribute name (\(name.utf8.count)) is greater \
                than the limit (\(XATTR_MAXNAMELEN)). Use a shorter attribute name.
                """
        #endif
        default:
            code = .unknown
            message = "Could not get value for extended attribute ('\(name)') for '\(path)'."
        }

        return FileSystemError(
            code: code,
            message: message,
            systemCall: "fgetxattr",
            errno: errno,
            location: location
        )
    }

    @_spi(Testing)
    public static func fsetxattr(
        attribute name: String,
        errno: Errno,
        path: FilePath,
        location: SourceLocation
    ) -> Self {
        let code: FileSystemError.Code
        let message: String

        // See: 'man 2 fsetxattr'
        switch errno {
        case .badFileDescriptor:
            code = .closed
            message = """
                Could not set value for extended attribute ('\(name)'), '\(path)' is closed.
                """

        case .notSupported:
            code = .unsupported
            message = """
                Extended attributes are disabled or not supported by the filesystem.
                """

        #if canImport(Darwin)
        case .fileNameTooLong:
            code = .invalidArgument
            message = """
                Length of UTF-8 extended attribute name (\(name.utf8.count)) is greater \
                than the limit limit (\(XATTR_MAXNAMELEN)). Use a shorter attribute \
                name.
                """
        #endif

        case .invalidArgument:
            code = .invalidArgument
            message = """
                Extended attribute name ('\(name)') must be a valid UTF-8 string.
                """
        default:
            code = .unknown
            message = """
                Could not set value for extended attribute ('\(name)') for '\(path)'.
                """
        }

        return FileSystemError(
            code: code,
            message: message,
            systemCall: "fsetxattr",
            errno: errno,
            location: location
        )
    }

    @_spi(Testing)
    public static func fremovexattr(
        attribute name: String,
        errno: Errno,
        path: FilePath,
        location: SourceLocation
    ) -> Self {
        let code: FileSystemError.Code
        let message: String

        // See: 'man 2 fremovexattr'
        switch errno {
        case .badFileDescriptor:
            code = .closed
            message = "Could not remove extended attribute ('\(name)'), '\(path)' is closed."

        case .notSupported:
            code = .unsupported
            message = "Extended attributes are disabled or not supported by the filesystem."

        #if canImport(Darwin)
        case .fileNameTooLong:
            code = .invalidArgument
            message = """
                Length of UTF-8 extended attribute name (\(name.utf8.count)) is greater \
                than the limit (\(XATTR_MAXNAMELEN)). Use a shorter attribute name.
                """
        #endif

        default:
            code = .unknown
            message = "Could not remove extended attribute ('\(name)') from '\(path)'"
        }

        return FileSystemError(
            code: code,
            message: message,
            systemCall: "fremovexattr",
            errno: errno,
            location: location
        )
    }

    @_spi(Testing)
    public static func fsync(
        errno: Errno,
        path: FilePath,
        location: SourceLocation
    ) -> Self {
        let code: FileSystemError.Code
        let message: String

        switch errno {
        case .badFileDescriptor:
            code = .closed
            message = "Could not synchronize file, '\(path)' is closed."
        case .ioError:
            code = .io
            message = "An I/O error occurred while synchronizing '\(path)'."
        default:
            code = .unknown
            message = "Could not synchronize file '\(path)'."
        }

        return FileSystemError(
            code: code,
            message: message,
            systemCall: "fsync",
            errno: errno,
            location: location
        )
    }

    @_spi(Testing)
    public static func dup(error: Error, path: FilePath, location: SourceLocation) -> Self {
        let code: FileSystemError.Code
        let message: String
        let cause: Error

        if let errno = error as? Errno {
            switch errno {
            case .badFileDescriptor:
                code = .closed
                message = "Unable to duplicate descriptor of closed handle for '\(path)'."
            default:
                code = .unknown
                message = "Unable to duplicate descriptor of handle for '\(path)'."
            }
            cause = SystemCallError(systemCall: "dup", errno: errno)
        } else {
            code = .unknown
            message = "Unable to duplicate descriptor of handle for '\(path)'."
            cause = error
        }

        return FileSystemError(
            code: code,
            message: message,
            cause: cause,
            location: location
        )
    }

    @_spi(Testing)
    public static func ftruncate(error: Error, path: FilePath, location: SourceLocation) -> Self {
        let code: FileSystemError.Code
        let message: String
        let cause: Error

        if let errno = error as? Errno {
            switch errno {
            case .badFileDescriptor:
                code = .closed
                message = "Can't resize '\(path)', it's closed."
            case .fileTooLarge:
                code = .invalidArgument
                message = "The requested size for '\(path)' is too large."
            case .invalidArgument:
                code = .invalidArgument
                message = "The requested size for '\(path)' is negative, therefore invalid."
            default:
                code = .unknown
                message = "Unable to resize '\(path)'."
            }
            cause = SystemCallError(systemCall: "ftruncate", errno: errno)
        } else {
            code = .unknown
            message = "Unable to resize '\(path)'."
            cause = error
        }

        return FileSystemError(
            code: code,
            message: message,
            cause: cause,
            location: location
        )
    }

    @_spi(Testing)
    public static func close(error: Error, path: FilePath, location: SourceLocation) -> Self {
        let code: FileSystemError.Code
        let message: String
        let cause: Error

        // See: 'man 2 close'
        if let errno = error as? Errno {
            switch errno {
            case .badFileDescriptor:
                code = .closed
                message = "File already closed or file descriptor was invalid ('\(path)')."
            case .ioError:
                code = .io
                message = "I/O error during close, some writes to '\(path)' may have failed."
            default:
                code = .unknown
                message = "Error closing file '\(path)'."
            }
            cause = SystemCallError(systemCall: "close", errno: errno)
        } else {
            code = .unknown
            message = "Error closing file '\(path)'."
            cause = error
        }

        return FileSystemError(
            code: code,
            message: message,
            cause: cause,
            location: location
        )
    }

    @_spi(Testing)
    public enum ReadSyscall: String, Sendable {
        case read
        case pread
    }

    @_spi(Testing)
    public static func read(
        usingSyscall syscall: ReadSyscall,
        error: Error,
        path: FilePath,
        location: SourceLocation
    ) -> Self {
        let code: FileSystemError.Code
        let message: String
        let cause: Error

        // We expect an Errno as 'swift-system' uses result types under-the-hood,
        // but don't require that in case something changes.
        if let errno = error as? Errno {
            switch errno {
            case .badFileDescriptor:
                code = .closed
                message = "Could not read from closed file '\(path)'."
            case .ioError:
                code = .io
                message = """
                    Could not read from file ('\(path)'); an I/O error occurred while reading \
                    from the file system.
                    """
            case .illegalSeek:
                code = .unsupported
                message = "File is not seekable: '\(path)'."
            default:
                code = .unknown
                message = "Could not read from file '\(path)'."
            }
            cause = SystemCallError(systemCall: syscall.rawValue, errno: errno)
        } else {
            code = .unknown
            message = "Could not read from file '\(path)'."
            cause = error
        }

        return FileSystemError(
            code: code,
            message: message,
            cause: cause,
            location: location
        )
    }

    @_spi(Testing)
    public enum WriteSyscall: String, Sendable {
        case write
        case pwrite
    }

    @_spi(Testing)
    public static func write(
        usingSyscall syscall: WriteSyscall,
        error: Error,
        path: FilePath,
        location: SourceLocation
    ) -> Self {
        let code: FileSystemError.Code
        let message: String
        let cause: Error

        // We expect an Errno as 'swift-system' uses result types under-the-hood,
        // but don't require that in case something changes.
        if let errno = error as? Errno {
            switch errno {
            case .badFileDescriptor:
                code = .closed
                message = "Could not write to closed file '\(path)'."
            case .ioError:
                code = .io
                message = """
                    Could not write to file ('\(path)'); an I/O error occurred while writing to \
                    the file system.
                    """
            case .illegalSeek:
                code = .unsupported
                message = "File is not seekable: '\(path)'."
            default:
                code = .unknown
                message = "Could not write to file."
            }
            cause = SystemCallError(systemCall: syscall.rawValue, errno: errno)
        } else {
            code = .unknown
            message = "Could not write to file."
            cause = error
        }

        return FileSystemError(
            code: code,
            message: message,
            cause: cause,
            location: location
        )
    }

    @_spi(Testing)
    public static func fdopendir(errno: Errno, path: FilePath, location: SourceLocation) -> Self {
        FileSystemError(
            code: .unknown,
            message: "Unable to open directory stream for '\(path)'.",
            systemCall: "fdopendir",
            errno: errno,
            location: location
        )
    }

    @_spi(Testing)
    public static func readdir(errno: Errno, path: FilePath, location: SourceLocation) -> Self {
        FileSystemError(
            code: .unknown,
            message: "Unable to read directory stream for '\(path)'.",
            systemCall: "readdir",
            errno: errno,
            location: location
        )
    }

    @_spi(Testing)
    public static func ftsRead(errno: Errno, path: FilePath, location: SourceLocation) -> Self {
        FileSystemError(
            code: .unknown,
            message: "Unable to read FTS stream for '\(path)'.",
            systemCall: "fts_read",
            errno: errno,
            location: location
        )
    }

    @_spi(Testing)
    public static func open(
        _ name: String,
        error: Error,
        path: FilePath,
        location: SourceLocation
    ) -> Self {
        let code: FileSystemError.Code
        let message: String
        let cause: Error

        if let errno = error as? Errno {
            switch errno {
            case .badFileDescriptor:
                code = .closed
                message = "Unable to open file at path '\(path)', the descriptor is closed."
            case .permissionDenied:
                code = .permissionDenied
                message = "Unable to open file at path '\(path)', permissions denied."
            case .fileExists:
                code = .fileAlreadyExists
                message = """
                    Unable to create file at path '\(path)', no existing file options were set \
                    which implies that no file should exist but a file already exists at the \
                    specified path.
                    """
            case .ioError:
                code = .io
                message = """
                    Unable to create file at path '\(path)', an I/O error occurred while \
                    creating the file.
                    """
            case .tooManyOpenFiles:
                code = .unavailable
                message = """
                    Unable to open file at path '\(path)', too many file descriptors are open.
                    """
            case .noSuchFileOrDirectory:
                code = .notFound
                message = """
                    Unable to open or create file at path '\(path)', either a component of the \
                    path did not exist or the named file to be opened did not exist.
                    """
            case .notDirectory:
                code = .notFound
                message = """
                    Unable to open or create file at path '\(path)', an intermediate component of \
                    the path was not a directory.
                    """
            case .tooManySymbolicLinkLevels:
                code = .invalidArgument
                message = """
                    Can't open file at path '\(path)', the target is a symbolic link and \
                    'followSymbolicLinks' was set to 'false'.
                    """
            default:
                code = .unknown
                message = "Unable to open file at path '\(path)'."
            }
            cause = SystemCallError(systemCall: name, errno: errno)
        } else {
            code = .unknown
            message = "Unable to open file at path '\(path)'."
            cause = error
        }

        return FileSystemError(code: code, message: message, cause: cause, location: location)
    }

    @_spi(Testing)
    public static func mkdir(errno: Errno, path: FilePath, location: SourceLocation) -> Self {
        let code: Code
        let message: String

        switch errno {
        case .permissionDenied:
            code = .permissionDenied
            message = """
                Insufficient permissions to create a directory at '\(path)'. Search permissions \
                denied for a component of the path or write permission denied for the parent \
                directory.
                """
        case .isDirectory:
            code = .invalidArgument
            message = "Can't create directory, '\(path)' is the root directory."
        case .fileExists:
            code = .fileAlreadyExists
            message = "Can't create directory, the pathname '\(path)' already exists."
        case .notDirectory:
            code = .invalidArgument
            message = "Can't create directory, a component of '\(path)' is not a directory."
        case .noSuchFileOrDirectory:
            code = .invalidArgument
            message = """
                Can't create directory, a component of '\(path)' does not exist. Ensure all \
                parent directories exist or set 'withIntermediateDirectories' to 'true' when \
                calling 'createDirectory(at:withIntermediateDirectories:permissions)'.
                """
        case .ioError:
            code = .io
            message = "An I/O error occurred when the directory at '\(path)'."
        default:
            code = .unknown
            message = ""
        }

        return FileSystemError(
            code: code,
            message: message,
            systemCall: "mkdir",
            errno: errno,
            location: location
        )
    }

    @_spi(Testing)
    public static func rename(
        _ name: String,
        errno: Errno,
        oldName: FilePath,
        newName: FilePath,
        location: SourceLocation
    ) -> Self {
        let code: Code
        let message: String

        switch errno {
        case .permissionDenied:
            code = .permissionDenied
            message = """
                Insufficient permissions to rename '\(oldName)' to '\(newName)'. Search \
                permissions were denied on a component of either path, or write permissions were \
                denied on the parent directory of either path.
                """
        case .fileExists:
            code = .fileAlreadyExists
            message = "Can't rename '\(oldName)' to '\(newName)' as it already exists."
        case .invalidArgument:
            code = .invalidArgument
            if oldName == "." || oldName == ".." {
                message = """
                    Can't rename '\(oldName)' to '\(newName)', '.' and '..' can't be renamed.
                    """
            } else {
                message = """
                    Can't rename '\(oldName)', it may be a parent directory of '\(newName)'.
                    """
            }
        case .noSuchFileOrDirectory:
            code = .notFound
            message = """
                Can't rename '\(oldName)' to '\(newName)', a component of '\(oldName)' does \
                not exist.
                """
        case .ioError:
            code = .io
            message = """
                Can't rename '\(oldName)' to '\(newName)', an I/O error occurred while making \
                or updating a directory entry.
                """
        default:
            code = .unknown
            message = "Can't rename '\(oldName)' to '\(newName)'."
        }

        return FileSystemError(
            code: code,
            message: message,
            systemCall: name,
            errno: errno,
            location: location
        )
    }

    @_spi(Testing)
    public static func remove(errno: Errno, path: FilePath, location: SourceLocation) -> Self {
        let code: Code
        let message: String

        switch errno {
        case .permissionDenied:
            code = .permissionDenied
            message = """
                Insufficient permissions to remove '\(path)'. Search permissions denied \
                on a component of the path or write permission denied on the directory \
                containing the item to be removed.
                """
        case .notPermitted:
            code = .permissionDenied
            message = """
                Insufficient permission to remove '\(path)', the effective user ID of the \
                process is not permitted to remove the file.
                """
        case .resourceBusy:
            code = .unavailable
            message = """
                Can't remove '\(path)', it may be being used by another process or is the mount \
                point for a mounted file system.
                """
        case .ioError:
            code = .io
            message = """
                Can't remove '\(path)', an I/O error occurred while deleting its directory entry.
                """
        default:
            code = .unknown
            message = "Can't remove '\(path)'."
        }

        return FileSystemError(
            code: code,
            message: message,
            systemCall: "remove",
            errno: errno,
            location: location
        )
    }

    @_spi(Testing)
    public static func symlink(
        errno: Errno,
        link: FilePath,
        target: FilePath,
        location: SourceLocation
    ) -> Self {
        let code: Code
        let message: String

        switch errno {
        case .permissionDenied:
            code = .permissionDenied
            message = """
                Can't create symbolic link '\(link)' to '\(target)', write access to the \
                directory containing the link was denied or one of the directories in its path \
                denied search permissions.
                """
        case .notPermitted:
            code = .permissionDenied
            message = """
                Can't create symbolic link '\(link)' to '\(target)', the file system \
                containing '\(link)' doesn't support the creation of symbolic links.
                """
        case .fileExists:
            code = .fileAlreadyExists
            message = """
                Can't create symbolic link '\(link)' to '\(target)', '\(link)' already exists.
                """
        case .noSuchFileOrDirectory:
            code = .invalidArgument
            message = """
                Can't create symbolic link '\(link)' to '\(target)', a component of '\(link)' \
                does not exist or is a dangling symbolic link.
                """
        case .notDirectory:
            code = .invalidArgument
            message = """
                Can't create symbolic link '\(link)' to '\(target)', a component of '\(link)' \
                is not a directory.
                """
        case .ioError:
            code = .io
            message = """
                Can't create symbolic link '\(link)' to '\(target)', an I/O error occurred.
                """
        default:
            code = .unknown
            message = "Can't create symbolic link '\(link)' to '\(target)'."
        }

        return FileSystemError(
            code: code,
            message: message,
            systemCall: "symlink",
            errno: errno,
            location: location
        )
    }

    @_spi(Testing)
    public static func readlink(errno: Errno, path: FilePath, location: SourceLocation) -> Self {
        let code: Code
        let message: String

        switch errno {
        case .permissionDenied:
            code = .permissionDenied
            message = """
                Can't read symbolic link at '\(path)'; search permission was denied for a \
                component in its prefix.
                """
        case .invalidArgument:
            code = .invalidArgument
            message = """
                Can't read '\(path)'; it is not a symbolic link.
                """
        case .ioError:
            code = .io
            message = """
                Can't read symbolic link at '\(path)'; an I/O error occurred.
                """
        case .noSuchFileOrDirectory:
            code = .notFound
            message = """
                Can't read symbolic link, no file exists at '\(path)'.
                """
        default:
            code = .unknown
            message = "Can't read symbolic link at '\(path)'."
        }

        return FileSystemError(
            code: code,
            message: message,
            systemCall: "readlink",
            errno: errno,
            location: location
        )
    }

    @_spi(Testing)
    public static func link(
        errno: Errno,
        from sourcePath: FilePath,
        to destinationPath: FilePath,
        location: SourceLocation
    ) -> Self {
        let code: FileSystemError.Code
        let message: String

        // See: 'man 2 link'
        switch errno {
        case .fileExists:
            code = .fileAlreadyExists
            message = """
                Can't link '\(sourcePath)' to '\(destinationPath)', a file already exists \
                at '\(destinationPath)'.
                """
        case .ioError:
            code = .io
            message = "I/O error while linking '\(sourcePath)' to '\(destinationPath)'."
        default:
            code = .unknown
            message = "Error linking '\(sourcePath)' to '\(destinationPath)'."
        }

        return FileSystemError(
            code: code,
            message: message,
            cause: SystemCallError(systemCall: "linkat", errno: errno),
            location: location
        )
    }

    @_spi(Testing)
    public static func unlink(
        errno: Errno,
        path: FilePath,
        location: SourceLocation
    ) -> Self {
        let code: FileSystemError.Code
        let message: String

        // See: 'man 2 unlink'
        switch errno {
        case .permissionDenied:
            code = .permissionDenied
            message = """
                Search permission denied for a component of the path ('\(path)') or write \
                permission denied on the directory containing the link to be removed.
                """
        case .ioError:
            code = .io
            message = "I/O error while unlinking '\(path)'."
        case .noSuchFileOrDirectory:
            code = .notFound
            message = "The named file ('\(path)') doesn't exist."
        case .notPermitted:
            code = .permissionDenied
            message = "Insufficient permissions to unlink '\(path)'."
        default:
            code = .unknown
            message = "Error unlinking '\(path)'."
        }

        return FileSystemError(
            code: code,
            message: message,
            cause: SystemCallError(systemCall: "unlink", errno: errno),
            location: location
        )
    }

    @_spi(Testing)
    public static func getcwd(errno: Errno, location: SourceLocation) -> Self {
        FileSystemError(
            code: .unavailable,
            message: "Can't get current working directory.",
            systemCall: "getcwd",
            errno: errno,
            location: location
        )
    }

    @_spi(Testing)
    public static func confstr(name: String, errno: Errno, location: SourceLocation) -> Self {
        FileSystemError(
            code: .unavailable,
            message: "Can't get configuration value for '\(name)'.",
            systemCall: "confstr",
            errno: errno,
            location: location
        )
    }

    @_spi(Testing)
    public static func fcopyfile(
        errno: Errno,
        from sourcePath: FilePath,
        to destinationPath: FilePath,
        location: SourceLocation
    ) -> Self {
        Self._copyfile(
            "fcopyfile",
            errno: errno,
            from: sourcePath,
            to: destinationPath,
            location: location
        )
    }

    @_spi(Testing)
    public static func copyfile(
        errno: Errno,
        from sourcePath: FilePath,
        to destinationPath: FilePath,
        location: SourceLocation
    ) -> Self {
        Self._copyfile(
            "copyfile",
            errno: errno,
            from: sourcePath,
            to: destinationPath,
            location: location
        )
    }

    private static func _copyfile(
        _ name: String,
        errno: Errno,
        from sourcePath: FilePath,
        to destinationPath: FilePath,
        location: SourceLocation
    ) -> Self {
        let code: Code
        let message: String

        switch errno {
        case .notSupported:
            code = .invalidArgument
            message = """
                Can't copy file from '\(sourcePath)' to '\(destinationPath)', the item to copy is \
                not a directory, symbolic link or regular file.
                """
        case .permissionDenied:
            code = .permissionDenied
            message = """
                Can't copy file, search permission was denied for a component of the path \
                prefix for the source ('\(sourcePath)') or destination ('\(destinationPath)'), \
                or write permission was denied for a component of the path prefix for the source.
                """
        case .invalidArgument:
            code = .invalidArgument
            message = """
                Can't copy file from '\(sourcePath)' to '\(destinationPath)', the destination \
                path already exists.
                """
        case .fileExists:
            code = .fileAlreadyExists
            message = """
                Unable to create file at path '\(destinationPath)', no existing file options were set \
                which implies that no file should exist but a file already exists at the \
                specified path.
                """
        case .tooManyOpenFiles:
            code = .unavailable
            message = """
                Unable to open the source ('\(sourcePath)') or destination ('\(destinationPath)') files, \
                too many file descriptors are open.
                """
        case .noSuchFileOrDirectory:
            code = .notFound
            message = """
                Unable to open or create file at path '\(sourcePath)', either a component of the \
                path did not exist or the named file to be opened did not exist.
                """
        default:
            code = .unknown
            message = "Can't copy file from '\(sourcePath)' to '\(destinationPath)'."
        }

        return FileSystemError(
            code: code,
            message: message,
            systemCall: name,
            errno: errno,
            location: location
        )
    }

    @_spi(Testing)
    public static func sendfile(
        errno: Errno,
        from sourcePath: FilePath,
        to destinationPath: FilePath,
        location: SourceLocation
    ) -> FileSystemError {
        let code: FileSystemError.Code
        let message: String

        switch errno {
        case .ioError:
            code = .io
            message = """
                An I/O error occurred while reading from '\(sourcePath)', can't copy to \
                '\(destinationPath)'.
                """
        case .noMemory:
            code = .io
            message = """
                Insufficient memory to read from '\(sourcePath)', can't copy to \
                '\(destinationPath)'.
                """
        default:
            code = .unknown
            message = "Can't copy file from '\(sourcePath)' to '\(destinationPath)'."
        }

        return FileSystemError(
            code: code,
            message: message,
            systemCall: "sendfile",
            errno: errno,
            location: location
        )
    }

    @_spi(Testing)
    public static func futimens(
        errno: Errno,
        path: FilePath,
        lastAccessTime: FileInfo.Timespec?,
        lastDataModificationTime: FileInfo.Timespec?,
        location: SourceLocation
    ) -> FileSystemError {
        let code: FileSystemError.Code
        let message: String

        switch errno {
        case .permissionDenied, .notPermitted:
            code = .permissionDenied
            message = "Not permitted to change last access or last data modification times for \(path)."

        case .readOnlyFileSystem:
            code = .unsupported
            message =
                "Not permitted to change last access or last data modification times for \(path): this is a read-only file system."

        case .badFileDescriptor:
            code = .closed
            message = "Could not change last access or last data modification dates for \(path): file is closed."

        default:
            code = .unknown
            message = "Could not change last access or last data modification dates for \(path)."
        }

        return FileSystemError(
            code: code,
            message: message,
            systemCall: "futimens",
            errno: errno,
            location: location
        )
    }
}
