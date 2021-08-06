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
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin.C
#elseif os(Linux) || os(FreeBSD) || os(Android)
import Glibc
#elseif os(Windows)
import CNIOWindows
#else
#error("bad os")
#endif

private let sysDup: @convention(c) (CInt) -> CInt = dup
private let sysClose: @convention(c) (CInt) -> CInt = close
private let sysOpenWithMode: @convention(c) (UnsafePointer<CChar>, CInt, mode_t) -> CInt = open
private let sysLseek: @convention(c) (CInt, off_t, CInt) -> off_t = lseek
private let sysRead: @convention(c) (CInt, UnsafeMutableRawPointer?, size_t) -> size_t = read
private let sysIfNameToIndex: @convention(c) (UnsafePointer<CChar>?) -> CUnsignedInt = if_nametoindex

#if !os(Windows)
private let sysGetifaddrs: @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<ifaddrs>?>?) -> CInt = getifaddrs
#endif

private func isUnacceptableErrno(_ code: Int32) -> Bool {
    switch code {
    case EFAULT, EBADF:
        return true
    default:
        return false
    }
}

private func preconditionIsNotUnacceptableErrno(err: CInt, where function: String) -> Void {
    // strerror is documented to return "Unknown error: ..." for illegal value so it won't ever fail
    precondition(!isUnacceptableErrno(err), "unacceptable errno \(err) \(String(cString: strerror(err)!)) in \(function))")
}

/*
 * Sorry, we really try hard to not use underscored attributes. In this case
 * however we seem to break the inlining threshold which makes a system call
 * take twice the time, ie. we need this exception.
 */
@inline(__always)
@discardableResult
internal func syscall<T: FixedWidthInteger>(blocking: Bool,
                                            where function: String = #function,
                                            _ body: () throws -> T)
        throws -> CoreIOResult<T> {
    while true {
        let res = try body()
        if res == -1 {
            let err = errno
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
        return try syscall(blocking: false) {
            sysDup(descriptor)
        }.result
    }

    @inline(never)
    internal static func close(descriptor: CInt) throws {
        let res = sysClose(descriptor)
        if res == -1 {
            let err = errno

            // There is really nothing "sane" we can do when EINTR was reported on close.
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
    internal static func open(file: UnsafePointer<CChar>, oFlag: CInt, mode: mode_t) throws -> CInt {
        return try syscall(blocking: false) {
            sysOpenWithMode(file, oFlag, mode)
        }.result
    }

    @discardableResult
    @inline(never)
    internal static func lseek(descriptor: CInt, offset: off_t, whence: CInt) throws -> off_t {
        return try syscall(blocking: false) {
            sysLseek(descriptor, offset, whence)
        }.result
    }

    @inline(never)
    internal static func read(descriptor: CInt, pointer: UnsafeMutableRawPointer, size: size_t) throws -> CoreIOResult<ssize_t> {
        return try syscall(blocking: true) {
            sysRead(descriptor, pointer, size)
        }
    }

    @inline(never)
    internal static func if_nametoindex(_ name: UnsafePointer<CChar>?) throws -> CUnsignedInt {
        return try syscall(blocking: false) {
            sysIfNameToIndex(name)
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
