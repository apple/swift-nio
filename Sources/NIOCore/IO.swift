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

internal func MAKELANGID(_ p: WORD, _ s: WORD) -> DWORD {
  return DWORD((s << 10) | p)
}
#elseif os(Linux) || os(Android)
import Glibc
#elseif os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#endif

/// An `Error` for an IO operation.
public struct IOError: Swift.Error {
    @available(*, deprecated, message: "NIO no longer uses FailureDescription.")
    public enum FailureDescription {
        case function(StaticString)
        case reason(String)
    }

    /// The actual reason (in an human-readable form) for this `IOError`.
    private var failureDescription: String

    @available(*, deprecated, message: "NIO no longer uses FailureDescription, use IOError.description for a human-readable error description")
    public var reason: FailureDescription {
        return .reason(self.failureDescription)
    }

    private enum Error {
        #if os(Windows)
            case windows(DWORD)
            case winsock(CInt)
        #endif
        case errno(CInt)
    }

    private let error: Error

    /// The `errno` that was set for the operation.
    public var errnoCode: CInt {
        switch self.error {
        case .errno(let code):
            return code
        #if os(Windows)
            default:
                fatalError("IOError domain is not `errno`")
        #endif
        }
    }

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
    /// - parameters:
    ///     - errorCode: the `errno` that was set for the operation.
    ///     - reason: the actual reason (in an human-readable form).
    public init(errnoCode code: CInt, reason: String) {
        self.error = .errno(code)
        self.failureDescription = reason
    }

    /// Creates a new `IOError``
    ///
    /// - parameters:
    ///     - errorCode: the `errno` that was set for the operation.
    ///     - function: The function the error happened in, the human readable description will be generated automatically when needed.
    @available(*, deprecated, renamed: "init(errnoCode:reason:)")
    public init(errnoCode code: CInt, function: StaticString) {
        self.error = .errno(code)
        self.failureDescription = "\(function)"
    }
}

/// Returns a reason to use when constructing a `IOError`.
///
/// - parameters:
///     - errorCode: the `errno` that was set for the operation.
///     - reason: what failed
/// - returns: the constructed reason.
private func reasonForError(errnoCode: CInt, reason: String) -> String {
    if let errorDescC = strerror(errnoCode) {
        return "\(reason): \(String(cString: errorDescC)) (errno: \(errnoCode))"
    } else {
        return "\(reason): Broken strerror, unknown error: \(errnoCode)"
    }
}

#if os(Windows)
private func reasonForWinError(_ code: DWORD) -> String {
    let dwFlags: DWORD = DWORD(FORMAT_MESSAGE_ALLOCATE_BUFFER)
                       | DWORD(FORMAT_MESSAGE_FROM_SYSTEM)
                       | DWORD(FORMAT_MESSAGE_IGNORE_INSERTS)

    var buffer: UnsafeMutablePointer<WCHAR>?
    // We use `FORMAT_MESSAGE_ALLOCATE_BUFFER` in flags which means that the
    // buffer will be allocated by the call to `FormatMessageW`.  The function
    // expects a `LPWSTR` and expects the user to type-pun in this case.
    let dwResult: DWORD = withUnsafeMutablePointer(to: &buffer) {
        $0.withMemoryRebound(to: WCHAR.self, capacity: 2) {
            FormatMessageW(dwFlags, nil, code,
                           MAKELANGID(WORD(LANG_NEUTRAL), WORD(SUBLANG_DEFAULT)),
                           $0, 0, nil)
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
        return self.localizedDescription
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

internal extension CoreIOResult where T: FixedWidthInteger {
    var result: T {
        switch self {
        case .processed(let value):
            return value
        case .wouldBlock(_):
            fatalError("cannot unwrap CoreIOResult")
        }
    }
}

