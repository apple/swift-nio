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

#if os(Windows)
import ucrt
import func WinSDK.FormatMessageW
import func WinSDK.LocalFree
import let WinSDK.FORMAT_MESSAGE_ALLOCATE_BUFFER
import let WinSDK.FORMAT_MESSAGE_FROM_SYSTEM
import let WinSDK.FORMAT_MESSAGE_IGNORE_INSERTS
import let WinSDK.LANG_NEUTRAL
import let WinSDK.SUBLANG_DEFAULT
import typealias WinSDK.DWORD
import typealias WinSDK.WCHAR
import typealias WinSDK.WORD

import let WinSDK.WSAEACCES
import let WinSDK.WSAEADDRINUSE
import let WinSDK.WSAEADDRNOTAVAIL
import let WinSDK.WSAEAFNOSUPPORT
import let WinSDK.WSAEALREADY
import let WinSDK.WSAEBADF
import let WinSDK.WSAECANCELLED
import let WinSDK.WSAECONNABORTED
import let WinSDK.WSAECONNREFUSED
import let WinSDK.WSAECONNRESET
import let WinSDK.WSAEDESTADDRREQ
import let WinSDK.WSAEFAULT
import let WinSDK.WSAEHOSTUNREACH
import let WinSDK.WSAEINPROGRESS
import let WinSDK.WSAEINTR
import let WinSDK.WSAEINVAL
import let WinSDK.WSAEISCONN
import let WinSDK.WSAELOOP
import let WinSDK.WSAEMFILE
import let WinSDK.WSAEMSGSIZE
import let WinSDK.WSAENAMETOOLONG
import let WinSDK.WSAENETDOWN
import let WinSDK.WSAENETRESET
import let WinSDK.WSAENETUNREACH
import let WinSDK.WSAENOBUFS
import let WinSDK.WSAENOPROTOOPT
import let WinSDK.WSAENOTCONN
import let WinSDK.WSAENOTEMPTY
import let WinSDK.WSAENOTSOCK
import let WinSDK.WSAEOPNOTSUPP
import let WinSDK.WSAEPROTONOSUPPORT
import let WinSDK.WSAEPROTOTYPE
import let WinSDK.WSAETIMEDOUT
import let WinSDK.WSAEWOULDBLOCK

internal func MAKELANGID(_ p: WORD, _ s: WORD) -> DWORD {
    DWORD((s << 10) | p)
}
#elseif canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Bionic)
@preconcurrency import Bionic
#elseif canImport(WASILibc)
@preconcurrency import WASILibc
#elseif canImport(Darwin)
import Darwin
#else
#error("The IO module was unable to identify your C library.")
#endif

/// An `Error` for an IO operation.
public struct IOError: Swift.Error {
    @available(*, deprecated, message: "NIO no longer uses FailureDescription.")
    public enum FailureDescription: Sendable {
        case function(StaticString)
        case reason(String)
    }

    /// The actual reason (in an human-readable form) for this `IOError`.
    private var failureDescription: String

    @available(
        *,
        deprecated,
        message: "NIO no longer uses FailureDescription, use IOError.description for a human-readable error description"
    )
    public var reason: FailureDescription {
        .reason(self.failureDescription)
    }

    package enum Error {
        #if os(Windows)
        case windows(DWORD)
        case winsock(CInt)
        #endif
        case errno(CInt)
    }

    package let error: Error

    /// The `errno` that was set for the operation.
    ///
    /// On Windows, an `IOError` may carry a `winsock`-domain error code instead. Those codes
    /// have the same meanings as their `errno` counterparts -- `WSAEMSGSIZE` means what
    /// `EMSGSIZE` means -- so they are translated here, which keeps error handling written
    /// against `errno` working on Windows. A `winsock` code with no `errno` counterpart, and a
    /// `windows`-domain code, are returned unchanged; Windows CRT `errno` values do not exceed
    /// 140 while Winsock and Win32 codes are far larger, so such a value cannot be mistaken for
    /// an `errno`.
    public var errnoCode: CInt {
        switch self.error {
        case .errno(let code):
            return code
        #if os(Windows)
        case .winsock(let code):
            return Self.errnoForWinsockError(code) ?? code
        case .windows(let code):
            return CInt(bitPattern: code)
        #endif
        }
    }

    #if os(Windows)
    /// The `errno` equivalent of a Winsock error code, if it has one.
    ///
    /// The codes are paired by meaning, which for this range of Winsock errors is the same as
    /// pairing them by name.
    private static func errnoForWinsockError(_ code: CInt) -> CInt? {
        switch code {
        case WSAEINTR: return EINTR
        case WSAEBADF: return EBADF
        case WSAEACCES: return EACCES
        case WSAEFAULT: return EFAULT
        case WSAEINVAL: return EINVAL
        case WSAEMFILE: return EMFILE
        // Note that the Windows CRT, unlike other platforms, gives `EWOULDBLOCK` and `EAGAIN`
        // distinct values. Winsock reports would-block as `WSAEWOULDBLOCK`, so that is the one
        // to pair it with.
        case WSAEWOULDBLOCK: return EWOULDBLOCK
        case WSAEINPROGRESS: return EINPROGRESS
        case WSAEALREADY: return EALREADY
        case WSAENOTSOCK: return ENOTSOCK
        case WSAEDESTADDRREQ: return EDESTADDRREQ
        case WSAEMSGSIZE: return EMSGSIZE
        case WSAEPROTOTYPE: return EPROTOTYPE
        case WSAENOPROTOOPT: return ENOPROTOOPT
        case WSAEPROTONOSUPPORT: return EPROTONOSUPPORT
        case WSAEOPNOTSUPP: return EOPNOTSUPP
        case WSAEAFNOSUPPORT: return EAFNOSUPPORT
        case WSAEADDRINUSE: return EADDRINUSE
        case WSAEADDRNOTAVAIL: return EADDRNOTAVAIL
        case WSAENETDOWN: return ENETDOWN
        case WSAENETUNREACH: return ENETUNREACH
        case WSAENETRESET: return ENETRESET
        case WSAECONNABORTED: return ECONNABORTED
        case WSAECONNRESET: return ECONNRESET
        case WSAENOBUFS: return ENOBUFS
        case WSAEISCONN: return EISCONN
        case WSAENOTCONN: return ENOTCONN
        case WSAETIMEDOUT: return ETIMEDOUT
        case WSAECONNREFUSED: return ECONNREFUSED
        case WSAELOOP: return ELOOP
        case WSAENAMETOOLONG: return ENAMETOOLONG
        case WSAEHOSTUNREACH: return EHOSTUNREACH
        case WSAENOTEMPTY: return ENOTEMPTY
        case WSAECANCELLED: return ECANCELED
        default: return nil
        }
    }
    #endif

    #if os(Windows)
    public init(windows code: DWORD, reason: String) {
        self.error = .windows(code)
        self.failureDescription = reason
    }

    public init(winsock code: CInt, reason: String) {
        self.error = .winsock(code)
        self.failureDescription = reason
    }
    #endif

    /// Creates a new `IOError``
    ///
    /// - Parameters:
    ///   - errnoCode: the `errno` that was set for the operation.
    ///   - reason: the actual reason (in an human-readable form).
    public init(errnoCode: CInt, reason: String) {
        self.error = .errno(errnoCode)
        self.failureDescription = reason
    }

    /// Creates a new `IOError``
    ///
    /// - Parameters:
    ///   - errnoCode: the `errno` that was set for the operation.
    ///   - function: The function the error happened in, the human readable description will be generated automatically when needed.
    @available(*, deprecated, renamed: "init(errnoCode:reason:)")
    public init(errnoCode: CInt, function: StaticString) {
        self.error = .errno(errnoCode)
        self.failureDescription = "\(function)"
    }
}

/// Returns a reason to use when constructing a `IOError`.
///
/// - Parameters:
///   - errnoCode: the `errno` that was set for the operation.
///   - reason: what failed
/// - Returns: the constructed reason.
private func reasonForError(errnoCode: CInt, reason: String) -> String {
    #if os(Windows)
    let errorDesc = Windows.strerror(errnoCode)
    #else
    let errorDesc = strerror(errnoCode).flatMap { String(cString: $0) }
    #endif
    if let errorDesc {
        return "\(reason): \(errorDesc)) (errno: \(errnoCode))"
    } else {
        return "\(reason): Broken strerror, unknown error: \(errnoCode)"
    }
}

#if os(Windows)
private func reasonForWinError(_ code: DWORD) -> String {
    let dwFlags: DWORD =
        DWORD(FORMAT_MESSAGE_ALLOCATE_BUFFER)
        | DWORD(FORMAT_MESSAGE_FROM_SYSTEM)
        | DWORD(FORMAT_MESSAGE_IGNORE_INSERTS)

    var buffer: UnsafeMutablePointer<WCHAR>?
    // We use `FORMAT_MESSAGE_ALLOCATE_BUFFER` in flags which means that the
    // buffer will be allocated by the call to `FormatMessageW`.  The function
    // expects a `LPWSTR` and expects the user to type-pun in this case.
    let dwResult: DWORD = withUnsafeMutablePointer(to: &buffer) {
        $0.withMemoryRebound(to: WCHAR.self, capacity: 2) {
            FormatMessageW(
                dwFlags,
                nil,
                code,
                MAKELANGID(WORD(LANG_NEUTRAL), WORD(SUBLANG_DEFAULT)),
                $0,
                0,
                nil
            )
        }
    }
    guard dwResult > 0, let message = buffer else {
        return "unknown error \(code)"
    }
    defer { LocalFree(buffer) }
    return String(decodingCString: message, as: UTF16.self)
}
#endif

extension IOError: CustomStringConvertible {
    public var description: String {
        self.localizedDescription
    }

    public var localizedDescription: String {
        #if os(Windows)
        switch self.error {
        case .errno(let errno):
            return reasonForError(errnoCode: errno, reason: self.failureDescription)
        case .windows(let code):
            return reasonForWinError(code)
        case .winsock(let code):
            return reasonForWinError(DWORD(code))
        }
        #else
        return reasonForError(errnoCode: self.errnoCode, reason: self.failureDescription)
        #endif
    }
}

// FIXME: Duplicated with NIO.
/// An result for an IO operation that was done on a non-blocking resource.
enum CoreIOResult<T: Equatable>: Equatable {

    /// Signals that the IO operation could not be completed as otherwise we would need to block.
    case wouldBlock(T)

    /// Signals that the IO operation was completed.
    case processed(T)
}

extension CoreIOResult where T: FixedWidthInteger {
    var result: T {
        switch self {
        case .processed(let value):
            return value
        case .wouldBlock(_):
            fatalError("cannot unwrap CoreIOResult")
        }
    }
}
