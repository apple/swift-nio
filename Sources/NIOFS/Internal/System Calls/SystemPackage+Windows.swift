//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(Windows)

// Windows-only compatibility shim for the NIOFileSystem family.
//
// This is a *compile-only* port: it supplies the POSIX-shaped types, constants
// and free functions the rest of the target expects on Windows so the file
// system targets build. The functions that map onto Win32 are stubbed with
// `fatalError(...)` here; real implementations land in follow-up PRs. The stubs
// deliberately match the bare-libc signatures the `system_*` / `libc_*`
// wrappers call, so those wrappers (and their non-Windows call sites) need no
// changes.
//
// Everything here is defined at module scope so, thanks to same-module
// visibility, the rest of the target can use these types, constants and
// free-functions without importing anything.

import CNIOWindows
import SystemPackage

// MARK: - Scalar types

/// POSIX `off_t`.
typealias off_t = Int64

/// POSIX `timespec`.
///
/// Defined locally rather than reused from ucrt. ucrt does declare a
/// `struct timespec`, but its `tv_nsec` is a C `long` (32-bit under Windows'
/// LLP64 model), whereas the shared `FileInfo.Timespec` initializer assigns
/// `tv_sec`/`tv_nsec` straight into `Int` fields. Declaring a POSIX-shaped
/// `timespec` with `Int` fields lets the cross-platform `FileInfo` and
/// `futimens` code compile unchanged, and lets the struct be `Sendable`
/// (the imported C type is not).
public struct timespec: Sendable {
    public var tv_sec: Int
    public var tv_nsec: Int

    public init(tv_sec: Int = 0, tv_nsec: Int = 0) {
        self.tv_sec = tv_sec
        self.tv_nsec = tv_nsec
    }
}

/// POSIX `pthread_key_t`.
typealias pthread_key_t = UInt32

// MARK: - `CInterop.Stat` and friends
//
// `CInterop.Stat` itself is `BY_HANDLE_FILE_INFORMATION`, aliased in
// `CInterop.swift` alongside the other platforms. The bridging that turns it
// into the POSIX-shaped values the shared `FileInfo` code reads lives at the
// bottom of this file.

extension CInterop {
    /// Directory-stream handle. Matches the Linux representation (opaque).
    typealias DirPointer = OpaquePointer

    /// Windows stand-in for `struct dirent`. `d_name` is a fixed-size tuple of
    /// `CChar` so the existing `.0/.1/.2` "is this '.' or '..'" check compiles.
    struct WindowsDirEnt {
        var d_type: UInt8 = 0
        var d_name:
            (
                CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar
            ) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

        init() {}
    }

    typealias DirEnt = WindowsDirEnt

    /// Opaque FTS handle.
    typealias FTS = OpaquePointer

    /// Windows stand-in for `FTSENT`. Only the fields NIOFS reads.
    struct WindowsFTSEnt {
        var fts_info: UInt16 = 0
        var fts_errno: CInt = 0
        var fts_path: UnsafeMutablePointer<CInterop.PlatformChar>? = nil

        init() {}
    }

    typealias FTSEnt = WindowsFTSEnt
}

// MARK: - swift-system gap extensions

extension FileDescriptor.OpenOptions {
    // Distinct high bits we own. These are placeholders for a real Win32
    // mapping in the future implementation. They are `@_spi(Testing) public` to
    // match the accessibility of the swift-system equivalents on other
    // platforms (which NIOFS's tests reach via an SPI import).
    @_spi(Testing) public static var noFollow: FileDescriptor.OpenOptions {
        FileDescriptor.OpenOptions(rawValue: 0x4000_0000)
    }
    @_spi(Testing) public static var closeOnExec: FileDescriptor.OpenOptions {
        FileDescriptor.OpenOptions(rawValue: 0x2000_0000)
    }
    @_spi(Testing) public static var nonBlocking: FileDescriptor.OpenOptions {
        FileDescriptor.OpenOptions(rawValue: 0x1000_0000)
    }
    @_spi(Testing) public static var directory: FileDescriptor.OpenOptions {
        FileDescriptor.OpenOptions(rawValue: 0x0800_0000)
    }
}

extension Errno {
    /// No direct equivalent on Windows; alias to `EINVAL` so switches stay
    /// exhaustive. `@_spi(Testing) public` to match the swift-system equivalent
    /// on other platforms (which NIOFS's tests reach via an SPI import).
    @_spi(Testing) public static var noData: Errno { Errno.invalidArgument }
}

// MARK: - `stat` mode constants (typed to `CInterop.Mode`)

let S_IFMT: CInterop.Mode = 0o170000
let S_IFSOCK: CInterop.Mode = 0o140000
let S_IFLNK: CInterop.Mode = 0o120000
let S_IFREG: CInterop.Mode = 0o100000
let S_IFBLK: CInterop.Mode = 0o060000
let S_IFDIR: CInterop.Mode = 0o040000
let S_IFCHR: CInterop.Mode = 0o020000
let S_IFIFO: CInterop.Mode = 0o010000

// MARK: - `dirent` `d_type` constants (typed to `CInt`)

let DT_UNKNOWN: CInt = 0
let DT_FIFO: CInt = 1
let DT_CHR: CInt = 2
let DT_DIR: CInt = 4
let DT_BLK: CInt = 6
let DT_REG: CInt = 8
let DT_LNK: CInt = 10
let DT_SOCK: CInt = 12

// MARK: - FTS constants (typed to `CInt`)

let FTS_D: CInt = 1
let FTS_DC: CInt = 2
let FTS_DEFAULT: CInt = 3
let FTS_DNR: CInt = 4
let FTS_DOT: CInt = 5
let FTS_DP: CInt = 6
let FTS_ERR: CInt = 7
let FTS_F: CInt = 8
let FTS_NS: CInt = 10
let FTS_NSOK: CInt = 11
let FTS_SL: CInt = 12
let FTS_SLNONE: CInt = 13

let FTS_PHYSICAL: CInt = 0x0010
let FTS_LOGICAL: CInt = 0x0002
let FTS_NOCHDIR: CInt = 0x0004

// MARK: - `UTIME_*` sentinels

let UTIME_NOW: CInt = (1 << 30) - 1
let UTIME_OMIT: CInt = (1 << 30) - 2

// MARK: - errno access

// `errno` is a macro on the Windows CRT that Swift cannot read or assign
// directly, so bridge through the `CNIOWindows` C shim, which expands the macro
// in C. This is the real thread-local `errno` backing the CRT calls the higher
// level file-system code inspects.
var _nio_fs_errno: CInt {
    get { CNIOWindows_errno() }
    set { CNIOWindows_set_errno(newValue) }
}

// MARK: - libc string helpers (stubs / trivial)

func strlen(_ s: UnsafePointer<CChar>) -> Int {
    var length = 0
    while s[length] != 0 { length += 1 }
    return length
}

func strlen(_ s: UnsafeMutablePointer<CChar>) -> Int {
    strlen(UnsafePointer(s))
}

func strlen(_ s: UnsafePointer<CInterop.PlatformChar>) -> Int {
    var length = 0
    while s[length] != 0 { length += 1 }
    return length
}

func strerror(_ code: CInt) -> UnsafeMutablePointer<CChar>? {
    fatalError("strerror is unavailable on Windows")
}

func memset(_ b: UnsafeMutableRawPointer, _ c: CInt, _ len: Int) -> UnsafeMutableRawPointer {
    b.initializeMemory(as: UInt8.self, repeating: UInt8(truncatingIfNeeded: c), count: len)
    return b
}

func getenv(_ name: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>? {
    fatalError("getenv is unavailable on Windows")
}

// MARK: - POSIX file-system syscall stubs
//
// These match the bare-libc call signatures used by the `system_*` / `libc_*`
// wrappers, so those wrappers need no edits. All are stubs.

func openat(
    _ fd: FileDescriptor.RawValue,
    _ path: UnsafePointer<CInterop.PlatformChar>,
    _ oflag: CInt
) -> CInt {
    fatalError("openat is unavailable on Windows")
}

func openat(
    _ fd: FileDescriptor.RawValue,
    _ path: UnsafePointer<CInterop.PlatformChar>,
    _ oflag: CInt,
    _ mode: CInterop.Mode
) -> CInt {
    fatalError("openat is unavailable on Windows")
}

func stat(
    _ path: UnsafePointer<CInterop.PlatformChar>,
    _ info: UnsafeMutablePointer<CInterop.Stat>
) -> CInt {
    fatalError("stat is unavailable on Windows")
}

func lstat(
    _ path: UnsafePointer<CInterop.PlatformChar>,
    _ info: UnsafeMutablePointer<CInterop.Stat>
) -> CInt {
    fatalError("lstat is unavailable on Windows")
}

func fstat(
    _ fd: FileDescriptor.RawValue,
    _ info: UnsafeMutablePointer<CInterop.Stat>
) -> CInt {
    fatalError("fstat is unavailable on Windows")
}

func fchmod(_ fd: FileDescriptor.RawValue, _ mode: CInterop.Mode) -> CInt {
    fatalError("fchmod is unavailable on Windows")
}

func fsync(_ fd: FileDescriptor.RawValue) -> CInt {
    fatalError("fsync is unavailable on Windows")
}

func mkdir(_ path: UnsafePointer<CInterop.PlatformChar>, _ mode: CInterop.Mode) -> CInt {
    fatalError("mkdir is unavailable on Windows")
}

func symlink(
    _ destination: UnsafePointer<CInterop.PlatformChar>,
    _ source: UnsafePointer<CInterop.PlatformChar>
) -> CInt {
    fatalError("symlink is unavailable on Windows")
}

func symlinkat(
    _ destination: UnsafePointer<CInterop.PlatformChar>,
    _ dirfd: FileDescriptor.RawValue,
    _ source: UnsafePointer<CInterop.PlatformChar>
) -> CInt {
    fatalError("symlinkat is unavailable on Windows")
}

func readlink(
    _ path: UnsafePointer<CInterop.PlatformChar>,
    _ buffer: UnsafeMutablePointer<CInterop.PlatformChar>,
    _ size: Int
) -> Int {
    fatalError("readlink is unavailable on Windows")
}

func rename(
    _ old: UnsafePointer<CInterop.PlatformChar>,
    _ new: UnsafePointer<CInterop.PlatformChar>
) -> CInt {
    fatalError("rename is unavailable on Windows")
}

func link(
    _ old: UnsafePointer<CInterop.PlatformChar>,
    _ new: UnsafePointer<CInterop.PlatformChar>
) -> CInt {
    fatalError("link is unavailable on Windows")
}

func unlink(_ path: UnsafePointer<CInterop.PlatformChar>) -> CInt {
    fatalError("unlink is unavailable on Windows")
}

func unlinkat(
    _ fd: FileDescriptor.RawValue,
    _ path: UnsafePointer<CInterop.PlatformChar>,
    _ flags: CInt
) -> CInt {
    fatalError("unlinkat is unavailable on Windows")
}

func futimens(
    _ fd: FileDescriptor.RawValue,
    _ times: UnsafePointer<timespec>?
) -> CInt {
    fatalError("futimens is unavailable on Windows")
}

func remove(_ path: UnsafePointer<CInterop.PlatformChar>) -> CInt {
    fatalError("remove is unavailable on Windows")
}

func getcwd(
    _ buffer: UnsafeMutablePointer<CInterop.PlatformChar>,
    _ size: Int
) -> UnsafeMutablePointer<CInterop.PlatformChar>? {
    fatalError("getcwd is unavailable on Windows")
}

func confstr(
    _ name: CInt,
    _ buffer: UnsafeMutablePointer<CInterop.PlatformChar>,
    _ size: Int
) -> Int {
    fatalError("confstr is unavailable on Windows")
}

func fdopendir(_ fd: FileDescriptor.RawValue) -> CInterop.DirPointer? {
    fatalError("fdopendir is unavailable on Windows")
}

func readdir(_ dir: CInterop.DirPointer) -> UnsafeMutablePointer<CInterop.DirEnt>? {
    fatalError("readdir is unavailable on Windows")
}

func closedir(_ dir: CInterop.DirPointer) -> CInt {
    fatalError("closedir is unavailable on Windows")
}

// MARK: - FTS stubs

func fts_open(
    _ path: [UnsafeMutablePointer<CInterop.PlatformChar>?],
    _ options: CInt,
    _ compare: UnsafeRawPointer?
) -> UnsafeMutablePointer<CInterop.FTS>? {
    fatalError("fts_open is unavailable on Windows")
}

func fts_read(
    _ fts: UnsafeMutablePointer<CInterop.FTS>
) -> UnsafeMutablePointer<CInterop.FTSEnt>? {
    fatalError("fts_read is unavailable on Windows")
}

func fts_close(_ fts: UnsafeMutablePointer<CInterop.FTS>) -> CInt {
    fatalError("fts_close is unavailable on Windows")
}

// MARK: - dirent name accessor

/// Windows equivalent of `CNIOLinux_dirent_dname` / `CNIODarwin_dirent_dname`.
func CNIOWindows_dirent_dname(
    _ entry: UnsafeMutablePointer<CInterop.DirEnt>
) -> UnsafePointer<CInterop.PlatformChar> {
    fatalError("CNIOWindows_dirent_dname is unavailable on Windows")
}

// MARK: - pthread TLS stubs

func pthread_key_create(
    _ key: UnsafeMutablePointer<pthread_key_t>,
    _ destructor: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?
) -> CInt {
    fatalError("pthread_key_create is unavailable on Windows")
}

func pthread_setspecific(_ key: pthread_key_t, _ value: UnsafeRawPointer?) -> CInt {
    fatalError("pthread_setspecific is unavailable on Windows")
}

func pthread_getspecific(_ key: pthread_key_t) -> UnsafeMutableRawPointer? {
    fatalError("pthread_getspecific is unavailable on Windows")
}

// MARK: - `BY_HANDLE_FILE_INFORMATION` -> `FileInfo` bridging
//
// `CInterop.Stat` is `BY_HANDLE_FILE_INFORMATION` on Windows. These helpers
// translate it into the POSIX-shaped values the shared `FileInfo` code reads,
// keeping the Win32 specifics (and the `CNIOWindows`/WinSDK dependency) out of
// `FileInfo.swift`.

extension CInterop.Stat {
    /// A POSIX-style `st_mode` synthesised from `dwFileAttributes`.
    ///
    /// This mirrors the Windows CRT's `stat` (`convert_to_stat_mode`): a
    /// directory maps to `S_IFDIR` and gains the execute bits, anything else is
    /// a regular file, and the read/write bits follow `FILE_ATTRIBUTE_READONLY`,
    /// replicated across owner/group/other. The CRT's executable-by-extension
    /// heuristic is intentionally dropped: it needs the path, which isn't part
    /// of `BY_HANDLE_FILE_INFORMATION`.
    var nioMode: CInterop.Mode {
        var mode: CInterop.Mode =
            (self.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY)) != 0
            ? S_IFDIR | 0o100
            : S_IFREG
        mode |=
            (self.dwFileAttributes & DWORD(FILE_ATTRIBUTE_READONLY)) != 0
            ? 0o400
            : 0o600
        mode |= (mode & 0o700) >> 3
        mode |= (mode & 0o700) >> 6
        return mode
    }

    /// The file size assembled from its high and low halves.
    var nioSize: Int64 {
        Int64(self.nFileSizeHigh) << 32 | Int64(self.nFileSizeLow)
    }

    var nioLastAccessTime: FileInfo.Timespec {
        FileInfo.Timespec(self.ftLastAccessTime)
    }

    var nioLastDataModificationTime: FileInfo.Timespec {
        FileInfo.Timespec(self.ftLastWriteTime)
    }

    /// Windows has no POSIX status-change time; the creation time is the closest
    /// analogue.
    var nioLastStatusChangeTime: FileInfo.Timespec {
        FileInfo.Timespec(self.ftCreationTime)
    }

    func nioHash(into hasher: inout Hasher) {
        hasher.combine(self.dwFileAttributes)
        hasher.combine(self.dwVolumeSerialNumber)
        hasher.combine(self.nFileSizeHigh)
        hasher.combine(self.nFileSizeLow)
        hasher.combine(self.nNumberOfLinks)
        hasher.combine(self.nFileIndexHigh)
        hasher.combine(self.nFileIndexLow)
        hasher.combine(self.ftCreationTime.dwLowDateTime)
        hasher.combine(self.ftCreationTime.dwHighDateTime)
        hasher.combine(self.ftLastAccessTime.dwLowDateTime)
        hasher.combine(self.ftLastAccessTime.dwHighDateTime)
        hasher.combine(self.ftLastWriteTime.dwLowDateTime)
        hasher.combine(self.ftLastWriteTime.dwHighDateTime)
    }

    static func nioIsEqual(_ lhs: CInterop.Stat, _ rhs: CInterop.Stat) -> Bool {
        lhs.dwFileAttributes == rhs.dwFileAttributes
            && lhs.dwVolumeSerialNumber == rhs.dwVolumeSerialNumber
            && lhs.nFileSizeHigh == rhs.nFileSizeHigh
            && lhs.nFileSizeLow == rhs.nFileSizeLow
            && lhs.nNumberOfLinks == rhs.nNumberOfLinks
            && lhs.nFileIndexHigh == rhs.nFileIndexHigh
            && lhs.nFileIndexLow == rhs.nFileIndexLow
            && lhs.ftCreationTime.dwLowDateTime == rhs.ftCreationTime.dwLowDateTime
            && lhs.ftCreationTime.dwHighDateTime == rhs.ftCreationTime.dwHighDateTime
            && lhs.ftLastAccessTime.dwLowDateTime == rhs.ftLastAccessTime.dwLowDateTime
            && lhs.ftLastAccessTime.dwHighDateTime == rhs.ftLastAccessTime.dwHighDateTime
            && lhs.ftLastWriteTime.dwLowDateTime == rhs.ftLastWriteTime.dwLowDateTime
            && lhs.ftLastWriteTime.dwHighDateTime == rhs.ftLastWriteTime.dwHighDateTime
    }
}

extension FileInfo.Timespec {
    /// Converts a Win32 `FILETIME` (100 ns ticks since 1601-01-01 UTC) into a
    /// POSIX timespec (seconds and nanoseconds since 1970-01-01 UTC).
    init(_ filetime: FILETIME) {
        // The number of 100 ns ticks between 1601-01-01 and 1970-01-01.
        let epochDelta: Int64 = 116_444_736_000_000_000
        let ticks =
            Int64(bitPattern: UInt64(filetime.dwHighDateTime) << 32 | UInt64(filetime.dwLowDateTime))
            - epochDelta
        self.init(
            seconds: Int(ticks / 10_000_000),
            nanoseconds: Int(ticks % 10_000_000) * 100
        )
    }
}

#endif  // os(Windows)
