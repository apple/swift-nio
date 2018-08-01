//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
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
    public enum FailureDescription {
        case function(StaticString)
        case reason(String)
    }
    /// The `errno` that was set for the operation.
    public let errnoCode: Int32

    /// The actual reason (in an human-readable form) for this `IOError`.
    public let reason: FailureDescription

    /// Creates a new `IOError``
    ///
    /// - note: At the moment, this constructor is more expensive than `IOError(errnoCode:function:)` as the `String` will incur reference counting
    ///
    /// - parameters:
    ///       - errorCode: the `errno` that was set for the operation.
    ///       - reason: the actual reason (in an human-readable form).
    public init(errnoCode: Int32, reason: String) {
        self.errnoCode = errnoCode
        self.reason = .reason(reason)
    }

    /// Creates a new `IOError``
    ///
    /// - note: This constructor is the cheapest way to create an `IOError`.
    ///
    /// - parameters:
    ///       - errorCode: the `errno` that was set for the operation.
    ///       - function: The function the error happened in, the human readable description will be generated automatically when needed.
    public init(errnoCode: Int32, function: StaticString) {
        self.errnoCode = errnoCode
        self.reason = .function(function)
    }
}

/// Returns a reason to use when constructing a `IOError`.
///
/// - parameters:
///       - errorCode: the `errno` that was set for the operation.
///       - reason: what failed
/// - returns: the constructed reason.
private func reasonForError(errnoCode: Int32, reason: String) -> String {
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
        switch self.reason {
        case .reason(let reason):
            return reasonForError(errnoCode: self.errnoCode, reason: reason)
        case .function(let function):
            return reasonForError(errnoCode: self.errnoCode, reason: "\(function) failed")
        }
    }
}

/// An result for an IO operation that was done on a non-blocking resource.
public enum IOResult<T: Equatable> {

    /// Signals that the IO operation could not be completed as otherwise we would need to block.
    case wouldBlock(T)

    /// Signals that the IO operation was completed.
    case processed(T)
}

extension IOResult: Equatable {
    public static func ==(lhs: IOResult<T>, rhs: IOResult<T>) -> Bool {
        switch (lhs, rhs) {
        case (.wouldBlock(let lhs), .wouldBlock(let rhs)):
            return lhs == rhs
        case (.processed(let lhs), .processed(let rhs)):
            return lhs == rhs
        case (.wouldBlock, _), (.processed, _):
            return false
        }
    }
}

