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
import CNIODarwin
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

// MARK: - system

/// openat(2): Open or create a file for reading or writing
func system_fdopenat(
    _ fd: FileDescriptor.RawValue,
    _ path: UnsafePointer<CInterop.PlatformChar>,
    _ oflag: Int32
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(fd, path, oflag)
    }
    #endif
    return openat(fd, path, oflag)
}

/// openat(2): Open or create a file for reading or writing
func system_fdopenat(
    _ fd: FileDescriptor.RawValue,
    _ path: UnsafePointer<CInterop.PlatformChar>,
    _ oflag: Int32,
    _ mode: CInterop.Mode
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(fd, path, oflag, mode)
    }
    #endif
    return openat(fd, path, oflag, mode)
}

/// stat(2): Get file status
func system_stat(
    _ path: UnsafePointer<CInterop.PlatformChar>,
    _ info: inout CInterop.Stat
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(path)
    }
    #endif
    return stat(path, &info)
}

/// lstat(2): Get file status
internal func system_lstat(
    _ path: UnsafePointer<CInterop.PlatformChar>,
    _ info: inout CInterop.Stat
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(path)
    }
    #endif
    return lstat(path, &info)
}

/// fstat(2): Get file status
internal func system_fstat(
    _ fd: FileDescriptor.RawValue,
    _ info: inout CInterop.Stat
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(fd)
    }
    #endif
    return fstat(fd, &info)
}

/// fchmod(2): Change mode of file
internal func system_fchmod(
    _ fd: FileDescriptor.RawValue,
    _ mode: CInterop.Mode
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(fd, mode)
    }
    #endif
    return fchmod(fd, mode)
}

/// fsync(2): Synchronize modifications to a file to permanent storage
internal func system_fsync(
    _ fd: FileDescriptor.RawValue
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(fd)
    }
    #endif
    return fsync(fd)
}

/// mkdir(2): Make a directory file
internal func system_mkdir(
    _ path: UnsafePointer<CInterop.PlatformChar>,
    _ mode: CInterop.Mode
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(path, mode)
    }
    #endif
    return mkdir(path, mode)
}

/// symlink(2): Make symolic link to a file
internal func system_symlink(
    _ destination: UnsafePointer<CInterop.PlatformChar>,
    _ source: UnsafePointer<CInterop.PlatformChar>
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(destination, source)
    }
    #endif
    return symlink(destination, source)
}

/// readlink(2): Read value of a symolic link
internal func system_readlink(
    _ path: UnsafePointer<CInterop.PlatformChar>,
    _ buffer: UnsafeMutablePointer<CInterop.PlatformChar>,
    _ bufferSize: Int
) -> Int {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mockInt(path, buffer, bufferSize)
    }
    #endif
    return readlink(path, buffer, bufferSize)
}

/// flistxattr(2): List extended attribute names
internal func system_flistxattr(
    _ fd: FileDescriptor.RawValue,
    _ namebuf: UnsafeMutablePointer<CChar>?,
    _ size: Int
) -> Int {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mockInt(fd, namebuf, size)
    }
    #endif
    #if canImport(Darwin)
    // The final parameter is 'options'; there is no equivalent on Linux.
    return flistxattr(fd, namebuf, size, 0)
    #elseif canImport(Glibc) || canImport(Musl) || canImport(Android)
    return flistxattr(fd, namebuf, size)
    #endif
}

/// fgetxattr(2): Get an extended attribute value
internal func system_fgetxattr(
    _ fd: FileDescriptor.RawValue,
    _ name: UnsafePointer<CChar>,
    _ value: UnsafeMutableRawPointer?,
    _ size: Int
) -> Int {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mockInt(fd, name, value, size)
    }
    #endif

    #if canImport(Darwin)
    // Penultimate parameter is position which is reserved and should be zero.
    // The final parameter is 'options'; there is no equivalent on Linux.
    return fgetxattr(fd, name, value, size, 0, 0)
    #elseif canImport(Glibc) || canImport(Musl) || canImport(Android)
    return fgetxattr(fd, name, value, size)
    #endif
}

/// fsetxattr(2): Set an extended attribute value
internal func system_fsetxattr(
    _ fd: FileDescriptor.RawValue,
    _ name: UnsafePointer<CChar>,
    _ value: UnsafeRawPointer?,
    _ size: Int
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(fd, name, value, size)
    }
    #endif

    // The final parameter is 'options'/'flags' on Darwin/Linux respectively.
    #if canImport(Darwin)
    // Penultimate parameter is position which is reserved and should be zero.
    return fsetxattr(fd, name, value, size, 0, 0)
    #elseif canImport(Glibc) || canImport(Musl) || canImport(Android)
    return fsetxattr(fd, name, value, size, 0)
    #endif
}

/// fremovexattr(2): Remove an extended attribute value
internal func system_fremovexattr(
    _ fd: FileDescriptor.RawValue,
    _ name: UnsafePointer<CChar>
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(fd, name)
    }
    #endif

    #if canImport(Darwin)
    // The final parameter is 'options'; there is no equivalent on Linux.
    return fremovexattr(fd, name, 0)
    #elseif canImport(Glibc) || canImport(Musl) || canImport(Android)
    return fremovexattr(fd, name)
    #endif
}

/// rename(2): Change the name of a file
internal func system_rename(
    _ old: UnsafePointer<CInterop.PlatformChar>,
    _ new: UnsafePointer<CInterop.PlatformChar>
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(old, new)
    }
    #endif
    return rename(old, new)
}

#if canImport(Darwin)
internal func system_renamex_np(
    _ old: UnsafePointer<CInterop.PlatformChar>,
    _ new: UnsafePointer<CInterop.PlatformChar>,
    _ flags: CUnsignedInt
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(old, new, flags)
    }
    #endif
    return renamex_np(old, new, flags)
}
#endif

#if canImport(Glibc) || canImport(Musl) || canImport(Android)
internal func system_renameat2(
    _ oldFD: FileDescriptor.RawValue,
    _ old: UnsafePointer<CInterop.PlatformChar>,
    _ newFD: FileDescriptor.RawValue,
    _ new: UnsafePointer<CInterop.PlatformChar>,
    _ flags: CUnsignedInt
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(oldFD, old, newFD, new, flags)
    }
    #endif
    return CNIOLinux_renameat2(oldFD, old, newFD, new, flags)
}
#endif

/// link(2): Creates a new link for a file.
#if canImport(Glibc) || canImport(Musl) || canImport(Android)
internal func system_linkat(
    _ oldFD: FileDescriptor.RawValue,
    _ old: UnsafePointer<CInterop.PlatformChar>,
    _ newFD: FileDescriptor.RawValue,
    _ new: UnsafePointer<CInterop.PlatformChar>,
    _ flags: CInt
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(oldFD, old, newFD, new, flags)
    }
    #endif
    return linkat(oldFD, old, newFD, new, flags)
}
#endif

/// link(2): Creates a new link for a file.
internal func system_link(
    _ old: UnsafePointer<CInterop.PlatformChar>,
    _ new: UnsafePointer<CInterop.PlatformChar>
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(old, new)
    }
    #endif
    return link(old, new)
}

/// unlink(2): Remove a directory entry.
internal func system_unlink(
    _ path: UnsafePointer<CInterop.PlatformChar>
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(path)
    }
    #endif
    return unlink(path)
}

#if canImport(Glibc) || canImport(Musl) || canImport(Android)
/// sendfile(2): Transfer data between descriptors
internal func system_sendfile(
    _ outFD: CInt,
    _ inFD: CInt,
    _ offset: off_t,
    _ count: Int
) -> Int {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mockInt(outFD, inFD, offset, count)
    }
    #endif
    var offset = offset
    return sendfile(outFD, inFD, &offset, count)
}
#endif

internal func system_futimens(
    _ fd: CInt,
    _ times: UnsafePointer<timespec>?
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(fd, times)
    }
    #endif
    return futimens(fd, times)
}

// MARK: - libc

/// fdopendir(3): Opens a directory stream for the file descriptor
internal func libc_fdopendir(
    _ fd: FileDescriptor.RawValue
) -> CInterop.DirPointer {
    fdopendir(fd)!
}

/// readdir(3): Returns a pointer to the next directory entry
internal func libc_readdir(
    _ dir: CInterop.DirPointer
) -> UnsafeMutablePointer<CInterop.DirEnt>? {
    readdir(dir)
}

/// readdir(3): Closes the directory stream and frees associated structures
internal func libc_closedir(
    _ dir: CInterop.DirPointer
) -> CInt {
    closedir(dir)
}

/// remove(3): Remove directory entry
internal func libc_remove(
    _ path: UnsafePointer<CInterop.PlatformChar>
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(path)
    }
    #endif
    return remove(path)
}

#if canImport(Darwin)
/// fcopyfile(3): Copy a file from one file to another.
internal func libc_fcopyfile(
    _ from: CInt,
    _ to: CInt,
    _ state: copyfile_state_t?,
    _ flags: copyfile_flags_t
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(from, to, state, flags)
    }
    #endif
    return fcopyfile(from, to, state, flags)
}
#endif

#if canImport(Darwin)
/// copyfile(3): Copy a file from one file to another.
internal func libc_copyfile(
    _ from: UnsafePointer<CInterop.PlatformChar>,
    _ to: UnsafePointer<CInterop.PlatformChar>,
    _ state: copyfile_state_t?,
    _ flags: copyfile_flags_t
) -> CInt {
    #if ENABLE_MOCKING
    if mockingEnabled {
        return mock(from, to, state, flags)
    }
    #endif
    return copyfile(from, to, state, flags)
}
#endif

/// getcwd(3): Get working directory pathname
internal func libc_getcwd(
    _ buffer: UnsafeMutablePointer<CInterop.PlatformChar>,
    _ size: Int
) -> UnsafeMutablePointer<CInterop.PlatformChar>? {
    getcwd(buffer, size)
}

/// confstr(3)
#if !os(Android)
internal func libc_confstr(
    _ name: CInt,
    _ buffer: UnsafeMutablePointer<CInterop.PlatformChar>,
    _ size: Int
) -> Int {
    confstr(name, buffer, size)
}
#endif

/// fts(3)
internal func libc_fts_open(
    _ path: [UnsafeMutablePointer<CInterop.PlatformChar>?],
    _ options: CInt
) -> UnsafeMutablePointer<CInterop.FTS> {
    #if os(Android)
    // This branch is a workaround for incorrect nullability annotations in the Android SDK.
    // They were added in https://android.googlesource.com/platform/bionic/+/dec8efd72a6ad8b807a15a614ae1519487cfa456,
    // and lasted for more than a year: https://android.googlesource.com/platform/bionic/+/da81ec4d1cbd0279014feb60535bf38defcd9346.
    CNIOLinux_fts_open(path, options, nil)!
    #else
    fts_open(path, options, nil)!
    #endif
}

/// fts(3)
internal func libc_fts_read(
    _ fts: UnsafeMutablePointer<CInterop.FTS>
) -> UnsafeMutablePointer<CInterop.FTSEnt>? {
    fts_read(fts)
}

/// fts(3)
internal func libc_fts_close(
    _ fts: UnsafeMutablePointer<CInterop.FTS>
) -> CInt {
    fts_close(fts)
}
