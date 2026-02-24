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
import CNIOLinux
#elseif canImport(Musl)
@preconcurrency import Musl
import CNIOLinux
#elseif canImport(Android)
@preconcurrency import Android
import CNIOLinux
#endif

/// Information about a file system object.
///
/// The information available for a file depends on the platform, ``FileInfo`` provides
/// convenient access to a common subset of properties. Using these properties ensures that
/// code is portable. If available, the platform specific information is made available via
/// ``FileInfo/platformSpecificStatus``. However users should take care to ensure their
/// code uses the correct platform checks when using it to ensure their code is portable.
public struct FileInfo: Hashable, Sendable {
    /// Wraps `CInterop.Stat` providing `Hashable` and `Equatable` conformance.
    private var _platformSpecificStatus: Stat?

    /// The information about the file returned from the filesystem, if available.
    ///
    /// This value is platform specific: you should be careful when using
    /// it as some of its fields vary across platforms. In most cases prefer
    /// using other properties on this type instead.
    ///
    /// See also: the manual pages for 'stat' (`man 2 stat`)
    public var platformSpecificStatus: CInterop.Stat? {
        get { self._platformSpecificStatus?.stat }
        set { self._platformSpecificStatus = newValue.map { Stat($0) } }
    }

    /// The type of the file.
    public var type: FileType

    /// Permissions currently set on the file.
    public var permissions: FilePermissions

    /// The size of the file in bytes.
    public var size: Int64

    /// User ID of the file.
    public var userID: UserID

    /// Group ID of the file.
    public var groupID: GroupID

    /// The last time the file was accessed.
    public var lastAccessTime: Timespec

    /// The last time the files data was last changed.
    public var lastDataModificationTime: Timespec

    /// The last time the status of the file was changed.
    public var lastStatusChangeTime: Timespec

    /// Creates a ``FileInfo`` by deriving values from a platform-specific value.
    public init(platformSpecificStatus: CInterop.Stat) {
        self._platformSpecificStatus = Stat(platformSpecificStatus)
        self.type = FileType(platformSpecificMode: CInterop.Mode(platformSpecificStatus.st_mode))
        self.permissions = FilePermissions(masking: CInterop.Mode(platformSpecificStatus.st_mode))
        self.size = Int64(platformSpecificStatus.st_size)
        self.userID = UserID(rawValue: platformSpecificStatus.st_uid)
        self.groupID = GroupID(rawValue: platformSpecificStatus.st_gid)

        #if canImport(Darwin)
        self.lastAccessTime = Timespec(platformSpecificStatus.st_atimespec)
        self.lastDataModificationTime = Timespec(platformSpecificStatus.st_mtimespec)
        self.lastStatusChangeTime = Timespec(platformSpecificStatus.st_ctimespec)
        #elseif canImport(Glibc) || canImport(Musl) || canImport(Android)
        self.lastAccessTime = Timespec(platformSpecificStatus.st_atim)
        self.lastDataModificationTime = Timespec(platformSpecificStatus.st_mtim)
        self.lastStatusChangeTime = Timespec(platformSpecificStatus.st_ctim)
        #endif
    }

    /// Creates a ``FileInfo`` from the provided values.
    ///
    /// If you have a platform specific status value prefer calling
    /// ``init(platformSpecificStatus:)``.
    public init(
        type: FileType,
        permissions: FilePermissions,
        size: Int64,
        userID: UserID,
        groupID: GroupID,
        lastAccessTime: Timespec,
        lastDataModificationTime: Timespec,
        lastStatusChangeTime: Timespec
    ) {
        self._platformSpecificStatus = nil
        self.type = type
        self.permissions = permissions
        self.size = size
        self.userID = userID
        self.groupID = groupID
        self.lastAccessTime = lastAccessTime
        self.lastDataModificationTime = lastDataModificationTime
        self.lastStatusChangeTime = lastStatusChangeTime
    }
}

extension FileInfo {
    /// The numeric ID of a user.
    public struct UserID: Hashable, Sendable, CustomStringConvertible {
        public var rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public var description: String {
            String(describing: self.rawValue)
        }
    }

    /// The numeric ID of a group.
    public struct GroupID: Hashable, Sendable, CustomStringConvertible {
        public var rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public var description: String {
            String(describing: self.rawValue)
        }
    }

    /// A time interval consisting of whole seconds and nanoseconds.
    public struct Timespec: Hashable, Sendable {
        #if canImport(Darwin)
        private static let utimeOmit = Int(UTIME_OMIT)
        private static let utimeNow = Int(UTIME_NOW)
        #elseif canImport(Glibc) || canImport(Musl) || canImport(Android)
        private static let utimeOmit = Int(CNIOLinux_UTIME_OMIT)
        private static let utimeNow = Int(CNIOLinux_UTIME_NOW)
        #endif

        /// A timespec where the seconds are set to zero and the nanoseconds set to `UTIME_OMIT`.
        /// In syscalls such as `futimens`, this means the time component set to this value will be ignored.
        public static let omit = Self(
            seconds: 0,
            nanoseconds: Self.utimeOmit
        )

        /// A timespec where the seconds are set to zero and the nanoseconds set to `UTIME_NOW`.
        /// In syscalls such as `futimens`, this means the time component set to this value will be
        /// be set to the current time or the largest value supported by the platform, whichever is smaller.
        public static let now = Self(
            seconds: 0,
            nanoseconds: Self.utimeNow
        )

        /// The number of seconds.
        public var seconds: Int

        /// The number of nanoseconds.
        public var nanoseconds: Int

        init(_ timespec: timespec) {
            self.seconds = timespec.tv_sec
            self.nanoseconds = timespec.tv_nsec
        }

        public init(seconds: Int, nanoseconds: Int) {
            self.seconds = seconds
            self.nanoseconds = nanoseconds
        }
    }
}

/// A wrapper providing `Hashable` and `Equatable` conformance for `CInterop.Stat`.
private struct Stat: Hashable {
    var stat: CInterop.Stat

    init(_ stat: CInterop.Stat) {
        self.stat = stat
    }

    func hash(into hasher: inout Hasher) {
        let stat = self.stat
        // Different platforms have different underlying values; these are
        // common between Darwin and Glibc.
        hasher.combine(stat.st_dev)
        hasher.combine(stat.st_mode)
        hasher.combine(stat.st_nlink)
        hasher.combine(stat.st_ino)
        hasher.combine(stat.st_uid)
        hasher.combine(stat.st_gid)
        hasher.combine(stat.st_rdev)
        hasher.combine(stat.st_size)
        hasher.combine(stat.st_blocks)
        hasher.combine(stat.st_blksize)

        #if canImport(Darwin)
        hasher.combine(FileInfo.Timespec(stat.st_atimespec))
        hasher.combine(FileInfo.Timespec(stat.st_mtimespec))
        hasher.combine(FileInfo.Timespec(stat.st_ctimespec))
        hasher.combine(FileInfo.Timespec(stat.st_birthtimespec))
        hasher.combine(stat.st_flags)
        hasher.combine(stat.st_gen)
        #elseif canImport(Glibc) || canImport(Musl) || canImport(Android)
        hasher.combine(FileInfo.Timespec(stat.st_atim))
        hasher.combine(FileInfo.Timespec(stat.st_mtim))
        hasher.combine(FileInfo.Timespec(stat.st_ctim))
        #endif

    }

    static func == (lhs: Stat, rhs: Stat) -> Bool {
        let lStat = lhs.stat
        let rStat = rhs.stat

        // Different platforms have different underlying values; these are
        // common between Darwin and Glibc.
        var isEqual = lStat.st_dev == rStat.st_dev
        isEqual = isEqual && lStat.st_mode == rStat.st_mode
        isEqual = isEqual && lStat.st_nlink == rStat.st_nlink
        isEqual = isEqual && lStat.st_ino == rStat.st_ino
        isEqual = isEqual && lStat.st_uid == rStat.st_uid
        isEqual = isEqual && lStat.st_gid == rStat.st_gid
        isEqual = isEqual && lStat.st_rdev == rStat.st_rdev
        isEqual = isEqual && lStat.st_size == rStat.st_size
        isEqual = isEqual && lStat.st_blocks == rStat.st_blocks
        isEqual = isEqual && lStat.st_blksize == rStat.st_blksize

        #if canImport(Darwin)
        isEqual =
            isEqual
            && FileInfo.Timespec(lStat.st_atimespec) == FileInfo.Timespec(rStat.st_atimespec)
        isEqual =
            isEqual
            && FileInfo.Timespec(lStat.st_mtimespec) == FileInfo.Timespec(rStat.st_mtimespec)
        isEqual =
            isEqual
            && FileInfo.Timespec(lStat.st_ctimespec) == FileInfo.Timespec(rStat.st_ctimespec)
        isEqual =
            isEqual
            && FileInfo.Timespec(lStat.st_birthtimespec)
                == FileInfo.Timespec(rStat.st_birthtimespec)
        isEqual = isEqual && lStat.st_flags == rStat.st_flags
        isEqual = isEqual && lStat.st_gen == rStat.st_gen
        #elseif canImport(Glibc) || canImport(Musl) || canImport(Android)
        isEqual = isEqual && FileInfo.Timespec(lStat.st_atim) == FileInfo.Timespec(rStat.st_atim)
        isEqual = isEqual && FileInfo.Timespec(lStat.st_mtim) == FileInfo.Timespec(rStat.st_mtim)
        isEqual = isEqual && FileInfo.Timespec(lStat.st_ctim) == FileInfo.Timespec(rStat.st_ctim)
        #endif

        return isEqual
    }
}

extension FilePermissions {
    internal init(masking rawValue: CInterop.Mode) {
        self = .init(rawValue: rawValue & ~S_IFMT)
    }
}
