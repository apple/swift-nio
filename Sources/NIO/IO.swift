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

    /// The `errno` that was set for the operation.
    public let errnoCode: CInt

    /// Creates a new `IOError``
    ///
    /// - parameters:
    ///     - errorCode: the `errno` that was set for the operation.
    ///     - reason: the actual reason (in an human-readable form).
    public init(errnoCode: CInt, reason: String) {
        self.errnoCode = errnoCode
        self.failureDescription = reason
    }

    /// Creates a new `IOError``
    ///
    /// - parameters:
    ///     - errorCode: the `errno` that was set for the operation.
    ///     - function: The function the error happened in, the human readable description will be generated automatically when needed.
    @available(*, deprecated, renamed: "init(errnoCode:reason:)")
    public init(errnoCode: CInt, function: StaticString) {
        self.errnoCode = errnoCode
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

extension IOError: CustomStringConvertible {
    public var description: String {
        return self.localizedDescription
    }

    public var localizedDescription: String {
        return reasonForError(errnoCode: self.errnoCode, reason: self.failureDescription)
    }
}

/// An result for an IO operation that was done on a non-blocking resource.
enum IOResult<T: Equatable>: Equatable {

    /// Signals that the IO operation could not be completed as otherwise we would need to block.
    case wouldBlock(T)

    /// Signals that the IO operation was completed.
    case processed(T)
}
