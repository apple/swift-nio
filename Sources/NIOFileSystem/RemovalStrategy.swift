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

/// How to perform removal of directories. Only relevant to directory level
/// copies when using
/// ``FileSystemProtocol/removeItem(at:strategy:recursively:)`` or other
/// overloads that use the default behaviour.
///
/// TODO: This is pretty much a verbatim copy of CopyStrategy.swift
public struct RemovalStrategy: Hashable, Sendable {
    // Avoid exposing to prevent breaking changes
    internal enum Wrapped: Hashable, Sendable {
        case sequential
        case parallel
    }

    internal let wrapped: Wrapped
    private init(_ wrapped: Wrapped) {
        self.wrapped = wrapped
    }

    /// Operate in whatever manner is deemed a reasonable default for the platform. This will limit
    /// the maximum file descriptors usage based on reasonable defaults.
    internal static func determinePlatformDefault() -> Wrapped {
        #if os(macOS) || os(Linux) || os(Windows)
        return .parallel
        #elseif os(iOS) || os(tvOS) || os(watchOS) || os(Android)
        return .parallel
        #else
        return .sequential
        #endif
    }
}

extension RemovalStrategy {
    /// Operate in whatever manner is deemed a reasonable default for the platform. This will limit
    /// the maximum file descriptors usage based on reasonable defaults.
    ///
    /// Current assumptions (which are subject to change):
    /// - Only one copy operation would be performed at once
    /// - The copy operation is not intended to be the primary activity on the device
    public static let platformDefault: Self = Self(Self.determinePlatformDefault())

    /// The copy is done asynchronously, but only one operation will occur at a time. This is the
    /// only way to guarantee only one callback to the `shouldCopyItem` will happen at a time.
    public static let sequential: Self = Self(.sequential)

    /// Allow multiple I/O operations to run concurrently, including file copies/directory creation
    /// and scanning.
    public static let parallel: Self = Self(.parallel)
}

extension RemovalStrategy: CustomStringConvertible {
    public var description: String {
        switch self.wrapped {
        case .sequential:
            return "sequential"
        case .parallel:
            return "parallel"
        }
    }
}
