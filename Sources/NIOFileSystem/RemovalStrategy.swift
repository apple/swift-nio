//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// How to perform removal of directories.
public struct RemovalStrategy: Hashable, Sendable {
    // Avoid exposing to prevent breaking changes
    internal enum Wrapped: Hashable, Sendable {
        case sequential
        case parallel(_ maxDescriptors: Int)
    }

    internal let wrapped: Wrapped
    private init(_ wrapped: Wrapped) {
        self.wrapped = wrapped
    }

    /// Operate in whatever manner is deemed a reasonable default for the platform. This will limit
    /// the maximum file descriptors usage based on reasonable defaults.
    internal static func determinePlatformDefault() -> Wrapped {
        #if os(macOS) || os(Linux) || os(Windows)
        return .parallel(8)
        #elseif os(iOS) || os(tvOS) || os(watchOS) || os(Android)
        return .parallel(4)
        #else
        return .sequential
        #endif
    }
}

extension RemovalStrategy {
    // A deletion requires no file descriptors. We consume a file descriptor
    // while scanning the contents of a directory.
    private static let minRequiredDescriptors = 1

    /// Operate in whatever manner is deemed a reasonable default for the platform. This will limit
    /// the maximum file descriptors usage based on reasonable defaults.
    ///
    /// Current assumptions (which are subject to change):
    /// - Only one delete operation would be performed at once
    /// - The delete operation is not intended to be the primary activity on the device
    public static let platformDefault: Self = Self(Self.determinePlatformDefault())

    /// The delete is done asynchronously, but only one operation will occur at a time.
    public static let sequential: Self = Self(.sequential)

    /// Allow multiple I/O operations to run concurrently, including
    /// subdirectory scanning.
    public static func parallel(maxDescriptors: Int) throws -> Self {
        guard maxDescriptors >= Self.minRequiredDescriptors else {
            throw FileSystemError(
                code: .invalidArgument,
                message:
                    "Can't do a remove operation without at least one file descriptor '\(maxDescriptors)' is illegal",
                cause: nil,
                location: .here()
            )
        }
        return .init(.parallel(maxDescriptors))
    }
}

extension RemovalStrategy: CustomStringConvertible {
    public var description: String {
        switch self.wrapped {
        case .sequential:
            return "sequential"
        case let .parallel(maxDescriptors):
            return "parallel with max \(maxDescriptors) descriptors"
        }
    }
}
