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

#if os(Windows)
import NIOCore
import WinSDK
import CNIOWindows

typealias ssize_t = SSIZE_T

let missingPipeSupportWindows = "Unimplemented: NIOPosix does not support PipeChannel on Windows"

// overwrite the windows write method, as the one without underscore is deprecated.
// also we can use this to downcast the count Int to UInt32
func write(_ fd: Int32, _ ptr: UnsafeRawPointer?, _ count: Int) -> Int32 {
    _write(fd, ptr, UInt32(clamping: count))
}

var errno: Int32 {
    CNIOWindows_errno()
}

extension NIOCore.Windows {
    /// Call this to get a string representation from an error code that was returned from `GetLastError`.
    static func makeErrorMessageFromCode(_ errorCode: DWORD) -> String? {
        var errorMsg = UnsafeMutablePointer<CHAR>?.none
        CNIOWindows_FormatGetLastError(errorCode, &errorMsg)

        if let errorMsg {
            let result = String(cString: errorMsg)
            LocalFree(errorMsg)
            return result
        } else {
            // we could check GetLastError here again. But that feels quite recursive.
            return nil
        }
    }

    static func recv(
        socket: SOCKET,
        pointer: UnsafeMutableRawPointer,
        size: Int32,
        flags: Int32
    ) throws -> IOResult<Int> {
        let result = WinSDK.recv(socket, pointer.assumingMemoryBound(to: CChar.self), size, flags)
        if result == WinSDK.SOCKET_ERROR {
            throw IOError(winsock: WSAGetLastError(), reason: "accept")
        }
        return .processed(Int(result))
    }

    static func pread(
        descriptor: CInt,
        pointer: UnsafeMutableRawPointer,
        size: size_t,
        offset: off_t
    ) throws -> IOResult<ssize_t> {
        var overlapped = OVERLAPPED()
        // off_t is Int32 anyway. Therefore high is always zero.
        precondition(off_t.self == Int32.self)
        overlapped.OffsetHigh = 0
        overlapped.Offset = UInt32(offset)

        let file = HANDLE(bitPattern: _get_osfhandle(descriptor))
        SetLastError(0)
        var readBytes: DWORD = 0
        let clampedSize = UInt32(clamping: size)
        let rf = ReadFile(file, pointer, clampedSize, &readBytes, &overlapped)
        let lastError = GetLastError()
        if rf == false && lastError != ERROR_HANDLE_EOF {
            throw IOError(errnoCode: Self.windowsErrorToPosixErrno(lastError), reason: "pread")
        }
        return .processed(Int64(readBytes))
    }

    static func pwrite(
        descriptor: CInt,
        pointer: UnsafeRawPointer,
        size: size_t,
        offset: off_t
    ) throws -> IOResult<ssize_t> {
        var overlapped = OVERLAPPED()
        // off_t is Int32 anyway. Therefore high is always zero.
        precondition(off_t.self == Int32.self)
        overlapped.OffsetHigh = 0
        overlapped.Offset = UInt32(offset)

        let file = HANDLE(bitPattern: _get_osfhandle(descriptor))
        SetLastError(0)
        var writtenBytes: DWORD = 0
        let clampedSize = UInt32(clamping: size)
        if !WriteFile(file, pointer, clampedSize, &writtenBytes, &overlapped) {
            throw IOError(errnoCode: Self.windowsErrorToPosixErrno(GetLastError()), reason: "pwrite")
        }
        return .processed(Int64(writtenBytes))
    }

    private static func windowsErrorToPosixErrno(_ dwError: DWORD) -> Int32 {
        switch Int32(dwError) {
        case ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND:
            return ENOENT
        case ERROR_TOO_MANY_OPEN_FILES:
            return EMFILE
        case ERROR_ACCESS_DENIED:
            return EACCES
        case ERROR_INVALID_HANDLE:
            return EBADF
        case ERROR_NOT_ENOUGH_MEMORY, ERROR_OUTOFMEMORY:
            return ENOMEM
        case ERROR_NOT_READY, ERROR_CRC:
            return EIO
        case ERROR_SHARING_VIOLATION, ERROR_LOCK_VIOLATION:
            return EBUSY
        case ERROR_HANDLE_EOF:
            return 0
        case ERROR_BROKEN_PIPE:
            return EPIPE
        default:
            return EINVAL
        }
    }
}

#endif
