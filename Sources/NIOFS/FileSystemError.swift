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

/// An error thrown as a result of interaction with the file system.
///
/// All errors have a high-level ``FileSystemError/Code-swift.struct`` which identifies the domain
/// of the error. For example an operation performed on a ``FileHandleProtocol`` which has already been
/// closed will result in a ``FileSystemError/Code-swift.struct/closed`` error code. Errors also
/// include a message describing what went wrong and how to remedy it (if applicable). The
/// ``FileSystemError/message`` is not static and may include dynamic information such as the path
/// of the file for which the operation failed, for example.
///
/// Errors may have a ``FileSystemError/cause``, an underlying error which caused the operation to
/// fail which may be platform specific.
public struct FileSystemError: Error, Sendable {
    /// A high-level error code to provide broad a classification.
    public var code: Code

    /// A message describing what went wrong and how it may be remedied.
    public var message: String

    /// An underlying error which caused the operation to fail. This may include additional details
    /// about the root cause of the failure.
    public var cause: Error?

    /// The location from which this error was thrown.
    public var location: SourceLocation

    public init(
        code: Code,
        message: String,
        cause: Error?,
        location: SourceLocation
    ) {
        self.code = code
        self.message = message
        self.cause = cause
        self.location = location
    }

    /// Creates a ``FileSystemError`` by wrapping the given `cause` and its location and code.
    internal init(message: String, wrapping cause: FileSystemError) {
        self.init(code: cause.code, message: message, cause: cause, location: cause.location)
    }
}

extension FileSystemError: CustomStringConvertible {
    public var description: String {
        if let cause = self.cause {
            return "\(self.code): \(self.message) (\(cause))"
        } else {
            return "\(self.code): \(self.message)"
        }
    }
}

extension FileSystemError: CustomDebugStringConvertible {
    public var debugDescription: String {
        if let cause = self.cause {
            return """
                \(String(reflecting: self.code)): \(String(reflecting: self.message)) \
                (\(String(reflecting: cause)))
                """
        } else {
            return "\(String(reflecting: self.code)): \(String(reflecting: self.message))"
        }
    }
}

extension FileSystemError {
    private func detailedDescriptionLines() -> [String] {
        // Build up a tree-like description of the error. This allows nested causes to be formatted
        // correctly, especially when they are also FileSystemErrors.
        //
        // An example is:
        //
        //  FileSystemError: Closed
        //  ├─ Reason: Unable to open file at path 'foo.swift', the descriptor is closed.
        //  ├─ Cause: 'openat' system call failed with '(9) Bad file descriptor'.
        //  └─ Source location: openFile(forReadingAt:_:) (FileSystem.swift:314)
        var lines = [
            "FileSystemError: \(self.code)",
            "├─ Reason: \(self.message)",
        ]

        if let error = self.cause as? FileSystemError {
            lines.append("├─ Cause:")
            let causeLines = error.detailedDescriptionLines()
            // We know this will never be empty.
            lines.append("│  └─ \(causeLines.first!)")
            lines.append(contentsOf: causeLines.dropFirst().map { "│     \($0)" })
        } else if let error = self.cause {
            lines.append("├─ Cause: \(String(reflecting: error))")
        }

        lines.append(
            "└─ Source location: \(self.location.function) (\(self.location.file):\(self.location.line))"
        )

        return lines
    }

    /// A detailed multi-line description of the error.
    ///
    /// - Returns: A multi-line description of the error.
    public func detailedDescription() -> String {
        self.detailedDescriptionLines().joined(separator: "\n")
    }
}

extension FileSystemError {
    /// A high level indication of the kind of error being thrown.
    public struct Code: Hashable, Sendable, CustomStringConvertible {
        private enum Wrapped: Hashable, Sendable, CustomStringConvertible {
            case closed
            case invalidArgument
            case io
            case permissionDenied
            case notEmpty
            case notFound
            case resourceExhausted
            case unavailable
            case unknown
            case unsupported
            case fileAlreadyExists

            var description: String {
                switch self {
                case .closed:
                    return "Closed"
                case .invalidArgument:
                    return "Invalid argument"
                case .io:
                    return "I/O error"
                case .permissionDenied:
                    return "Permission denied"
                case .resourceExhausted:
                    return "Resource exhausted"
                case .notEmpty:
                    return "Not empty"
                case .notFound:
                    return "Not found"
                case .unavailable:
                    return "Unavailable"
                case .unknown:
                    return "Unknown"
                case .unsupported:
                    return "Unsupported"
                case .fileAlreadyExists:
                    return "File already exists"
                }
            }
        }

        public var description: String {
            String(describing: self.code)
        }

        private var code: Wrapped
        private init(_ code: Wrapped) {
            self.code = code
        }

        /// An operation on the file could not be performed because the file is closed
        /// (or detached).
        public static var closed: Self {
            Self(.closed)
        }

        /// A provided argument was not valid for the operation.
        public static var invalidArgument: Self {
            Self(.invalidArgument)
        }

        /// An I/O error occurred.
        public static var io: Self {
            Self(.io)
        }

        /// The caller did not have sufficient permission to perform the operation.
        public static var permissionDenied: Self {
            Self(.permissionDenied)
        }

        /// A required resource was exhausted.
        public static var resourceExhausted: Self {
            Self(.resourceExhausted)
        }

        /// The directory wasn't empty.
        public static var notEmpty: Self {
            Self(.notEmpty)
        }

        /// The file could not be found.
        public static var notFound: Self {
            Self(.notFound)
        }

        /// The file system is not currently available, for example if the underlying executor
        /// is not running.
        public static var unavailable: Self {
            Self(.unavailable)
        }

        /// The error is not known or may not have an appropriate classification. See
        /// ``FileSystemError/cause`` for more information about the error.
        public static var unknown: Self {
            Self(.unknown)
        }

        /// The operation is not supported or is not enabled.
        public static var unsupported: Self {
            Self(.unsupported)
        }

        /// The file already exists.
        public static var fileAlreadyExists: Self {
            Self(.fileAlreadyExists)
        }
    }

    /// A location within source code.
    public struct SourceLocation: Sendable, Hashable {
        /// The function in which the error was thrown.
        public var function: String

        /// The file in which the error was thrown.
        public var file: String

        /// The line on which the error was thrown.
        public var line: Int

        public init(function: String, file: String, line: Int) {
            self.function = function
            self.file = file
            self.line = line
        }

        internal static func here(
            function: String = #function,
            file: String = #fileID,
            line: Int = #line
        ) -> Self {
            SourceLocation(function: function, file: file, line: line)
        }
    }
}

extension FileSystemError {
    /// An error resulting from a system call.
    public struct SystemCallError: Error, Hashable, CustomStringConvertible {
        /// The name of the system call which produced the error.
        public var systemCall: String
        /// The errno set by the system call.
        public var errno: Errno

        public init(systemCall: String, errno: Errno) {
            self.systemCall = systemCall
            self.errno = errno
        }

        public var description: String {
            "'\(self.systemCall)' system call failed with '(\(self.errno.rawValue)) \(self.errno)'."
        }
    }
}
