//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
//  This file contains code that ensures errno is captured correctly when doing syscalls and no ARC traffic can happen inbetween that *could* change the errno
//  value before we were able to read it.
//  It's important that all static methods are declared with `@inline(never)` so it's not possible any ARC traffic happens while we need to read errno.
//
//  Created by Norman Maurer on 11/10/17.
//
// This file arguably shouldn't be here in NIOCore, but due to early design decisions we accidentally exposed a few types that
// know about system calls into the core API (looking at you, FileHandle). As a result we need support for a small number of system calls.
#if canImport(Darwin)
import Darwin.C
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Windows)
import CNIOWindows
#elseif canImport(Android)
import Android
#else
#error("The system call helpers module was unable to identify your C library.")
#endif

#if os(Windows)
private let sysDup: @convention(c) (CInt) -> CInt = _dup
private let sysClose: @convention(c) (CInt) -> CInt = _close
private let sysLseek: @convention(c) (CInt, off_t, CInt) -> off_t = _lseek
private let sysRead: @convention(c) (CInt, UnsafeMutableRawPointer?, CUnsignedInt) -> CInt = _read
#else
private let sysDup: @convention(c) (CInt) -> CInt = dup
private let sysClose: @convention(c) (CInt) -> CInt = close
private let sysOpenWithMode: @convention(c) (UnsafePointer<CChar>, CInt, NIOPOSIXFileMode) -> CInt = open
private let sysLseek: @convention(c) (CInt, off_t, CInt) -> off_t = lseek
private let sysRead: @convention(c) (CInt, UnsafeMutableRawPointer?, size_t) -> size_t = read
#endif

#if os(Android)
private let sysIfNameToIndex: @convention(c) (UnsafePointer<CChar>) -> CUnsignedInt = if_nametoindex
private let sysGetifaddrs: @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<ifaddrs>?>) -> CInt = getifaddrs
#else
private let sysIfNameToIndex: @convention(c) (UnsafePointer<CChar>?) -> CUnsignedInt = if_nametoindex
#if !os(Windows)
private let sysGetifaddrs: @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<ifaddrs>?>?) -> CInt = getifaddrs
#endif
#endif

private func isUnacceptableErrno(_ code: Int32) -> Bool {
    switch code {
    case EFAULT, EBADF:
        return true
    default:
        return false
    }
}

private func preconditionIsNotUnacceptableErrno(err: CInt, where function: String) {
    // strerror is documented to return "Unknown error: ..." for illegal value so it won't ever fail
    precondition(
        !isUnacceptableErrno(err),
        "unacceptable errno \(err) \(String(cString: strerror(err)!)) in \(function))"
    )
}

// Sorry, we really try hard to not use underscored attributes. In this case
// however we seem to break the inlining threshold which makes a system call
// take twice the time, ie. we need this exception.
@inline(__always)
@discardableResult
internal func syscall<T: FixedWidthInteger>(
    blocking: Bool,
    where function: String = #function,
    _ body: () throws -> T
)
    throws -> CoreIOResult<T>
{
    while true {
        let res = try body()
        if res == -1 {
            #if os(Windows)
            var err: CInt = 0
            ucrt._get_errno(&err)
            #else
            let err = errno
            #endif
            switch (err, blocking) {
            case (EINTR, _):
                continue
            case (EWOULDBLOCK, true):
                return .wouldBlock(0)
            default:
                preconditionIsNotUnacceptableErrno(err: err, where: function)
                throw IOError(errnoCode: err, reason: function)
            }
        }
        return .processed(res)
    }
}

enum SystemCalls {
    @discardableResult
    @inline(never)
    internal static func dup(descriptor: CInt) throws -> CInt {
        try syscall(blocking: false) {
            sysDup(descriptor)
        }.result
    }

    @inline(never)
    internal static func close(descriptor: CInt) throws {
        let res = sysClose(descriptor)
        if res == -1 {
            #if os(Windows)
            var err: CInt = 0
            ucrt._get_errno(&err)
            #else
            let err = errno
            #endif

            // There is really nothing "good" we can do when EINTR was reported on close.
            // So just ignore it and "assume" everything is fine == we closed the file descriptor.
            //
            // For more details see:
            //     - https://bugs.chromium.org/p/chromium/issues/detail?id=269623
            //     - https://lwn.net/Articles/576478/
            if err != EINTR {
                preconditionIsNotUnacceptableErrno(err: err, where: #function)
                throw IOError(errnoCode: err, reason: "close")
            }
        }
    }

    @inline(never)
    internal static func open(
        file: UnsafePointer<CChar>,
        oFlag: CInt,
        mode: NIOPOSIXFileMode
    ) throws -> CInt {
        #if os(Windows)
        return try syscall(blocking: false) {
            var fh: CInt = -1
            let _ = ucrt._sopen_s(&fh, file, oFlag, _SH_DENYNO, mode)
            return fh
        }.result
        #else
        return try syscall(blocking: false) {
            sysOpenWithMode(file, oFlag, mode)
        }.result
        #endif
    }

    @discardableResult
    @inline(never)
    internal static func lseek(descriptor: CInt, offset: off_t, whence: CInt) throws -> off_t {
        try syscall(blocking: false) {
            sysLseek(descriptor, offset, whence)
        }.result
    }

    #if os(Windows)
    @inline(never)
    internal static func read(
        descriptor: CInt,
        pointer: UnsafeMutableRawPointer,
        size: CUnsignedInt
    ) throws -> CoreIOResult<CInt> {
        try syscall(blocking: true) {
            sysRead(descriptor, pointer, size)
        }
    }
    #else
    @inline(never)
    internal static func read(
        descriptor: CInt,
        pointer: UnsafeMutableRawPointer,
        size: size_t
    ) throws -> CoreIOResult<ssize_t> {
        try syscall(blocking: true) {
            sysRead(descriptor, pointer, size)
        }
    }
    #endif

    @inline(never)
    internal static func if_nametoindex(_ name: UnsafePointer<CChar>?) throws -> CUnsignedInt {
        try syscall(blocking: false) {
            sysIfNameToIndex(name!)
        }.result
    }

    #if !os(Windows)
    @inline(never)
    internal static func getifaddrs(_ addrs: UnsafeMutablePointer<UnsafeMutablePointer<ifaddrs>?>) throws {
        _ = try syscall(blocking: false) {
            sysGetifaddrs(addrs)
        }
    }
    #endif
}
