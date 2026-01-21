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

import SystemPackage

#if canImport(System)
import System
#endif

/// `NIOFilePath` is a type for representing a file path. It is backed by `SystemPackage`'s `FilePath` type.
///
/// You can create a `NIOFilePath` from a string literal:
///
/// ```swift
/// let path: NIOFilePath = "/home/user/report.txt"
/// ```
///
/// To interact with the underlying filepath using `SystemPackage.FilePath`'s API, you can initialize a `SystemPackage.FilePath` instance from a
/// `NIOFilePath` instance (and vice-versa).
public struct NIOFilePath: Equatable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible,
    CustomDebugStringConvertible
{
    /// The underlying `SystemPackage.FilePath` instance that ``NIOFilePath`` uses.
    var underlying: SystemPackage.FilePath

    /// Creates a ``NIOFilePath`` given an underlying `SystemPackage.FilePath` instance.
    ///
    /// - Parameter underlying: The `SystemPackage.FilePath` to use as the underlying backing for ``NIOFilePath``.
    public init(_ underlying: SystemPackage.FilePath) {
        self.underlying = underlying
    }

    #if canImport(System)
    /// Creates a ``NIOFilePath`` given an underlying `System.FilePath` instance.
    ///
    /// - Parameter underlying: The `System.FilePath` instance to use to create this ``NIOFilePath`` instance.
    @available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
    public init(_ underlying: System.FilePath) {
        self.underlying = underlying.withPlatformString {
            SystemPackage.FilePath(platformString: $0)
        }
    }
    #endif

    /// Creates an instance representing an empty and null-terminated filepath.
    public init() {
        self.underlying = .init()
    }

    /// Creates an instance corresponding to the file path represented by the provided string.
    ///
    /// - Parameter string: A string whose Unicode encoded contents to use as the contents of the path
    public init(_ string: String) {
        self.underlying = .init(string)
    }

    /// Creates an instance from a string literal.
    ///
    /// - Parameter stringLiteral: A string literal whose Unicode encoded contents to use as the contents of the path.
    public init(stringLiteral: String) {
        self.init(stringLiteral)
    }

    /// A textual representation of the file path.
    ///
    /// If the content of the path isn't a well-formed Unicode string, this replaces invalid bytes with U+FFFD. See `String.init(decoding:)`
    public var description: String {
        self.underlying.description
    }

    /// A textual representation of the file path, suitable for debugging.
    ///
    /// If the content of the path isn't a well-formed Unicode string, this replaces invalid bytes with U+FFFD. See `String.init(decoding:)`
    public var debugDescription: String {
        self.underlying.debugDescription
    }
}

extension SystemPackage.FilePath {
    /// Creates a `SystemPackage.FilePath` from a ``NIOFilePath`` instance.
    public init(_ filePath: NIOFilePath) {
        self = filePath.underlying
    }
}

#if canImport(System)
@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension System.FilePath {
    /// Creates a `System.FilePath` from a ``NIOFilePath`` instance.
    public init(_ filePath: NIOFilePath) {
        self = filePath.underlying.withPlatformString {
            System.FilePath(platformString: $0)
        }
    }
}
#endif
