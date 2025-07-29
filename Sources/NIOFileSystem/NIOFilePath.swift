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
    let underlying: SystemPackage.FilePath

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
    @available(macOS 12.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
    init(_ underlying: System.FilePath) {
        self = underlying.withPlatformString(NIOFilePath.init(platformString:))
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

    /// Creates an instance by copying bytes from a null-terminated platform string.
    ///
    /// - Warning: It is a precondition that `platformString` must be null-terminated. The absence of a null byte will trigger a runtime error.
    ///
    /// - Parameter platformString: A null-terminated platform string.
    public init(platformString: [CInterop.PlatformChar]) {
        self.underlying = .init(platformString: platformString)
    }

    /// Creates an instance by copying bytes from a null-terminated platform string.
    ///
    /// - Parameter platformString: A pointer to a null-terminated platform string.
    public init(platformString: UnsafePointer<CInterop.PlatformChar>) {
        self.underlying = .init(platformString: platformString)
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

extension String {
    /// Creates a string by interpreting the file path's content as UTF-8 on Unix and UTF-16 on Windows.
    ///
    /// - Parameter path: The file path to be interpreted as `CInterop.PlatformUnicodeEncoding`.
    ///
    /// If the content of the file path isn't a well-formed Unicode string, this initializer replaces invalid bytes with U+FFFD.
    /// This means that, depending on the semantics of the specific file system, conversion to a string and back to a path might result in a value that's different from
    /// the original path.
    public init(decoding path: NIOFilePath) {
        self.init(decoding: path.underlying)
    }

    /// Creates a string from a file path, validating its contents as UTF-8 on Unix and UTF-16 on Windows.
    ///
    /// - Parameter path: The file path to be interpreted as `CInterop.PlatformUnicodeEncoding`.
    ///
    /// If the contents of the file path isn't a well-formed Unicode string, this initializer returns `nil`.
    public init?(validating path: NIOFilePath) {
        self.init(validating: path.underlying)
    }
}

extension String {
    /// On Unix, creates the string `"/"`
    ///
    /// On Windows, creates a string by interpreting the path root's content as UTF-16.
    ///
    /// - Parameter root: The path root to be interpreted as `CInterop.PlatformUnicodeEncoding`.
    ///
    /// If the content of the path root isn't a well-formed Unicode string, this initializer replaces invalid bytes with U+FFFD.
    /// This means that on Windows, conversion to a string and back to a path root might result in a value that's different from the original path root.
    public init(decoding root: NIOFilePath.Root) {
        self.init(decoding: root.underlying)
    }

    /// On Unix, creates the string `"/"`
    ///
    /// On Windows, creates a string from a path root, validating its contents as UTF-16 on Windows.
    ///
    /// - Parameter root: The path root to be interpreted as `CInterop.PlatformUnicodeEncoding`.
    ///
    /// On Windows, if the contents of the path root isn't a well-formed Unicode string, this initializer returns `nil`.
    public init?(validating root: NIOFilePath.Root) {
        self.init(validating: root.underlying)
    }
}

extension String {
    /// Creates a string by interpreting the path component's content as UTF-8 on Unix and UTF-16 on Windows.
    ///
    /// - Parameter component: The path component to be interpreted as `CInterop.PlatformUnicodeEncoding`.
    ///
    /// If the content of the path component isn't a well-formed Unicode string, this initializer replaces invalid bytes with U+FFFD.
    /// This means that, depending on the semantics of the specific file system, conversion to a string and back to a path component might result in a value
    /// that's different from the original path component.
    public init(decoding component: NIOFilePath.Component) {
        self.init(decoding: component.underlying)
    }

    /// Creates a string from a path component, validating its contents as UTF-8 on Unix and UTF-16 on Windows.
    ///
    /// - Parameter component: The path component to be interpreted as `CInterop.PlatformUnicodeEncoding`.
    ///
    /// If the contents of the path component isn't a well-formed Unicode string, this initializer returns `nil`.
    public init?(validating component: NIOFilePath.Component) {
        self.init(validating: component.underlying)
    }
}

extension SystemPackage.FilePath {
    /// Creates a `SystemPackage.FilePath` from a ``NIOFilePath`` instance.
    public init(_ filePath: NIOFilePath) {
        self = filePath.underlying
    }
}

#if canImport(System)
@available(macOS 12.0, *)
extension System.FilePath {
    /// Creates a `System.FilePath` from a ``NIOFilePath`` instance.
    init(_ filePath: NIOFilePath) {
        self = filePath.underlying.withPlatformString(System.FilePath.init(platformString:))
    }
}
#endif
