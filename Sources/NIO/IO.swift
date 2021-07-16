//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(Windows)
    import typealias WinSDK.DWORD
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
        .reason(failureDescription)
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
        switch error {
        case let .errno(code):
            return code
        #if os(Windows)
            default:
                fatalError("IOError domain is not `errno`")
        #endif
        }
    }

    #if os(Windows)
        public init(windows code: DWORD, reason: String) {
            error = .windows(code)
            failureDescription = reason
        }

        public init(winsock code: CInt, reason: String) {
            error = .winsock(code)
            failureDescription = reason
        }
    #endif

    /// Creates a new `IOError``
    ///
    /// - parameters:
    ///     - errorCode: the `errno` that was set for the operation.
    ///     - reason: the actual reason (in an human-readable form).
    public init(errnoCode code: CInt, reason: String) {
        error = .errno(code)
        failureDescription = reason
    }

    /// Creates a new `IOError``
    ///
    /// - parameters:
    ///     - errorCode: the `errno` that was set for the operation.
    ///     - function: The function the error happened in, the human readable description will be generated automatically when needed.
    @available(*, deprecated, renamed: "init(errnoCode:reason:)")
    public init(errnoCode code: CInt, function: StaticString) {
        error = .errno(code)
        failureDescription = "\(function)"
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

internal extension IOResult where T: FixedWidthInteger {
    var result: T {
        switch self {
        case let .processed(value):
            return value
        case .wouldBlock:
            fatalError("cannot unwrap IOResult")
        }
    }
}

extension IOError: CustomStringConvertible {
    public var description: String {
        localizedDescription
    }

    public var localizedDescription: String {
        reasonForError(errnoCode: errnoCode, reason: failureDescription)
    }
}

/// An result for an IO operation that was done on a non-blocking resource.
enum IOResult<T: Equatable>: Equatable {
    /// Signals that the IO operation could not be completed as otherwise we would need to block.
    case wouldBlock(T)

    /// Signals that the IO operation was completed.
    case processed(T)
}
