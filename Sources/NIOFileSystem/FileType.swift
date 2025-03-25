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
#elseif canImport(Android)
@preconcurrency import Android
#endif

/// The type of a file system object.
public struct FileType: Hashable, Sendable {
    internal enum Wrapped: Hashable, Sendable, CaseIterable {
        case regular
        case block
        case character
        case fifo
        case directory
        case symlink
        case socket
        case whiteout
        case unknown
    }

    internal let wrapped: Wrapped
    private init(_ wrapped: Wrapped) {
        self.wrapped = wrapped
    }
}

extension FileType {
    /// Regular file.
    public static var regular: Self { Self(.regular) }

    /// Directory.
    public static var directory: Self { Self(.directory) }

    /// Symbolic link.
    public static var symlink: Self { Self(.symlink) }

    /// Hardware block device.
    public static var block: Self { Self(.block) }

    /// Hardware character device.
    public static var character: Self { Self(.character) }

    /// FIFO (or named pipe).
    public static var fifo: Self { Self(.fifo) }

    /// Socket.
    public static var socket: Self { Self(.socket) }

    /// Whiteout file.
    public static var whiteout: Self { Self(.whiteout) }

    /// A file of unknown type.
    public static var unknown: Self { Self(.unknown) }
}

extension FileType: CustomStringConvertible {
    public var description: String {
        switch self.wrapped {
        case .regular:
            return "regular"
        case .block:
            return "block"
        case .character:
            return "character"
        case .fifo:
            return "fifo"
        case .directory:
            return "directory"
        case .symlink:
            return "symlink"
        case .socket:
            return "socket"
        case .whiteout:
            return "whiteout"
        case .unknown:
            return "unknown"
        }
    }
}

extension FileType: CaseIterable {
    public static var allCases: [FileType] {
        Self.Wrapped.allCases.map { FileType($0) }
    }
}

extension FileType {
    /// Initializes a file type from a `CInterop.Mode`.
    ///
    /// Note: an appropriate mask is applied to `mode`.
    public init(platformSpecificMode: CInterop.Mode) {
        // See: `man 2 stat`
        switch platformSpecificMode & S_IFMT {
        case S_IFIFO:
            self = .fifo
        case S_IFCHR:
            self = .character
        case S_IFDIR:
            self = .directory
        case S_IFBLK:
            self = .block
        case S_IFREG:
            self = .regular
        case S_IFLNK:
            self = .symlink
        case S_IFSOCK:
            self = .socket
        #if canImport(Darwin)
        case S_IFWHT:
            self = .whiteout
        #endif
        default:
            self = .unknown
        }
    }

    /// Initializes a file type from the `d_type` from `dirent`.
    @_spi(Testing)
    public init(direntType: UInt8) {
        #if canImport(Darwin) || canImport(Musl) || os(Android)
        let value = Int32(direntType)
        #elseif canImport(Glibc)
        let value = Int(direntType)
        #endif

        switch value {
        case DT_FIFO:
            self = .fifo
        case DT_CHR:
            self = .character
        case DT_DIR:
            self = .directory
        case DT_BLK:
            self = .block
        case DT_REG:
            self = .regular
        case DT_LNK:
            self = .symlink
        case DT_SOCK:
            self = .socket
        #if canImport(Darwin)
        case DT_WHT:
            self = .whiteout
        #endif
        case DT_UNKNOWN:
            self = .unknown
        default:
            self = .unknown
        }
    }
}
