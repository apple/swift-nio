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

/// `NIOFilePath` is backed by `SystemPackage`'s `FilePath` type, and it mirrors its API.
///
/// ### Creating a File Path
///
/// You can create a `NIOFilePath` from a string literal:
///
/// ```swift
/// let path: NIOFilePath = "/home/user/report.txt"
/// ```
///
/// ### Path Components
///
/// You can access the different components of the path, such as its root and each of its components :
///
/// ```swift
/// let path: NIOFilePath = "/home/user/report.txt"
/// print(path.root) // Optional("/")
///
/// print(path.components) // ["home", "user", "report.txt"]
/// print(path.lastComponent) // Optional("report.txt")
/// print(path.extension) // Optional("txt")
/// ```
///
/// ### Manipulating Paths
///
/// A `NIOFilePath` can be modified by adding/removing path components, or lexically normalizing the path:
///
/// ```swift
/// var path: NIOFilePath = "/home/user"
/// path.append("documents")
/// print(path) // "/home/user/documents"
///
/// // Non-mutating variant of `append`:
/// let newPath = path.appending("report.txt")
/// print(newPath) // "/home/user/documents/report.txt"
///
/// var unnormalizedPath: NIOFilePath = "/home/user/../user/./documents"
/// // Normalize the path
/// unnormalizedPath.lexicallyNormalize()
/// print(unnormalizedPath) // "/home/user/documents"
/// ```
public struct NIOFilePath: Equatable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible,
    CustomDebugStringConvertible
{
    /// The underlying `SystemPackage.FilePath` instance that ``NIOFilePath`` uses.
    package var underlying: SystemPackage.FilePath

    /// Creates a ``NIOFilePath`` given an underlying `SystemPackage.FilePath` instance.
    ///
    /// - Parameter underlying: The `SystemPackage.FilePath` to use as the underlying backing for ``NIOFilePath``.
    public init(_ underlying: SystemPackage.FilePath) {
        self.underlying = underlying
    }

    #if canImport(System)
    /// Creates a  ``NIOFilePath`` given an underlying `System.FilePath` instance.
    ///
    /// - Parameter underlying: The `System.FilePath` instance to use to create this ``NIOFilePath`` instance.
    @available(macOS 12.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
    public init(_ underlying: System.FilePath) {
        self.underlying = .init(underlying.string)
    }
    #endif

    /// Represents a root of a file path.
    ///
    /// On Unix, a root is simply the directory separator `/`.
    ///
    /// On Windows, a root contains the entire path prefix up to and including the final separator.
    ///
    /// Examples:
    /// * Unix:
    ///   * `/`
    /// * Windows:
    ///   * `C:\`
    ///   * `C:`
    ///   * `\`
    ///   * `\\server\share\`
    ///   * `\\?\UNC\server\share\`
    ///   * `\\?\Volume{12345678-abcd-1111-2222-123445789abc}\`
    public struct Root: Equatable, Hashable, Sendable {
        let underlying: SystemPackage.FilePath.Root

        /// Creates a ``NIOFilePath/Root`` given an underlying `SystemPackage.FilePath.Root` instance.
        ///
        /// - Parameter underlying: The `SystemPackage.FilePath.Root` to use as the underlying backing for ``NIOFilePath/Root``.
        public init(_ underlying: SystemPackage.FilePath.Root) {
            self.underlying = underlying
        }

        #if canImport(System)
        /// Creates a ``NIOFilePath/Root`` given an underlying `System.FilePath.Root` instance.
        ///
        /// - Parameter underlying: The `System.FilePath.Root` instance to use to create this ``NIOFilePath/Root`` instance.
        @available(macOS 12.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
        public init?(_ underlying: System.FilePath.Root) {
            self.init(underlying.string)
        }
        #endif
    }

    /// Represents an individual, non-root component of a file path.
    ///
    /// Components can be one of the special directory components (`.` or `..`) or a file or directory name. Components are never empty and never contain
    /// the directory separator.
    ///
    /// Example:
    ///
    ///     var path: NIOFilePath = "/tmp"
    ///     let file: NIOFilePath.Component = "foo.txt"
    ///     file.kind == .regular           // true
    ///     file.extension                  // "txt"
    ///     path.append(file)               // path is "/tmp/foo.txt"
    public struct Component: Equatable, Hashable, Sendable {
        let underlying: SystemPackage.FilePath.Component

        /// Creates a ``NIOFilePath/Component`` given an underlying `SystemPackage.FilePath.Component` instance.
        ///
        /// - Parameter underlying: The `SystemPackage.FilePath.Component` to use as the underlying backing for ``NIOFilePath/Component``.
        public init(_ underlying: SystemPackage.FilePath.Component) {
            self.underlying = underlying
        }

        #if canImport(System)
        /// Creates a ``NIOFilePath/Component`` given an underlying `System.FilePath.Component` instance.
        ///
        /// - Parameter underlying: The `System.FilePath.Component` instance to use to create this ``NIOFilePath/Component`` instance.
        @available(macOS 12.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
        public init?(_ underlying: System.FilePath.Component) {
            self.init(underlying.string)
        }
        #endif
    }

    /// A bidirectional, range replaceable collection of the non-root components that make up a file path.
    ///
    /// `ComponentView` provides access to standard `BidirectionalCollection` algorithms for accessing components from the front or back, as well
    /// as standard `RangeReplaceableCollection` algorithms for modifying the file path using component or range of components granularity.
    ///
    /// Example:
    ///
    ///     var path: NIOFilePath = "/./home/./username/scripts/./tree"
    ///     let scriptIdx = path.components.lastIndex(of: "scripts")!
    ///     path.components.insert("bin", at: scriptIdx)
    ///     // path is "/./home/./username/bin/scripts/./tree"
    ///
    ///     path.components.removeAll { $0.kind == .currentDirectory }
    ///     // path is "/home/username/bin/scripts/tree"
    public struct ComponentView: Equatable, Hashable, Sendable {
        var underlying: SystemPackage.FilePath.ComponentView

        /// Creates a ``NIOFilePath/ComponentView`` given an underlying `SystemPackage.FilePath.ComponentView` instance.
        ///
        /// - Parameter underlying: The `SystemPackage.FilePath.ComponentView` to use as the underlying backing
        /// for ``NIOFilePath/ComponentView``.
        public init(_ underlying: SystemPackage.FilePath.ComponentView) {
            self.underlying = underlying
        }

        #if canImport(System)
        /// Creates a ``NIOFilePath/ComponentView`` given an underlying `System.FilePath.ComponentView` instance.
        ///
        /// - Parameter underlying: The `System.FilePath.ComponentView` instance to use to create this
        /// ``NIOFilePath/ComponentView`` instance.
        @available(macOS 12.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *)
        public init?(_ underlying: System.FilePath.ComponentView) {
            let components = underlying.compactMap(NIOFilePath.Component.init)
            self.init(components)
        }
        #endif
    }

    /// Returns the root of a path if there is one, otherwise `nil`.
    ///
    /// On Unix, this will return the leading `/` if the path is absolute and `nil` if the path is relative.
    ///
    /// On Windows, for traditional DOS paths, this will return the path prefix up to and including a root directory or a supplied drive or volume. Otherwise, if the
    /// path is relative to both the current directory and current drive, returns `nil`.
    ///
    /// On Windows, for UNC or device paths, this will return the path prefix up to and including the host and share for UNC paths or the volume for device paths
    /// followed by any subsequent separator.
    ///
    /// Examples:
    /// * Unix:
    ///   * `/foo/bar => /`
    ///   * `foo/bar  => nil`
    /// * Windows:
    ///   * `C:\foo\bar                => C:\`
    ///   * `C:foo\bar                 => C:`
    ///   * `\foo\bar                  => \ `
    ///   * `foo\bar                   => nil`
    ///   * `\\server\share\file       => \\server\share\`
    ///   * `\\?\UNC\server\share\file => \\?\UNC\server\share\`
    ///   * `\\.\device\folder         => \\.\device\`
    ///
    /// Setting the root to `nil` will remove the root and setting a new root will replace the root.
    ///
    /// Example:
    ///
    ///     var path: NIOFilePath = "/foo/bar"
    ///     path.root = nil // path is "foo/bar"
    ///     path.root = "/" // path is "/foo/bar"
    ///
    /// Example (Windows):
    ///
    ///     var path: NIOFilePath = #"\foo\bar"#
    ///     path.root = nil         // path is #"foo\bar"#
    ///     path.root = "C:"        // path is #"C:foo\bar"#
    ///     path.root = #"C:\"#     // path is #"C:\foo\bar"#
    public var root: Root? {
        self.underlying.root.map(Root.init)
    }

    /// A bidirectional, range replaceable collection of the non-root components that make up a file path.
    ///
    /// `ComponentView` provides access to standard `BidirectionalCollection` algorithms for accessing components from the front or back, as well
    /// as standard `RangeReplaceableCollection` algorithms for modifying the file path using component or range of components granularity.
    ///
    /// Example:
    ///
    ///     var path: NIOFilePath = "/./home/./username/scripts/./tree"
    ///     let scriptIdx = path.components.lastIndex(of: "scripts")!
    ///     path.components.insert("bin", at: scriptIdx)
    ///     // path is "/./home/./username/bin/scripts/./tree"
    ///
    ///     path.components.removeAll { $0.kind == .currentDirectory }
    ///     // path is "/home/username/bin/scripts/tree"
    public var components: ComponentView {
        .init(self.underlying.components)
    }

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

    /// Create an instance from an optional root and a collection of components.
    public init(root: Root?, _ components: ComponentView.SubSequence) {
        self.underlying = .init(root: root?.underlying, components.map(\.underlying))
    }

    /// Creates an instance from an optional root and a variable number of components.
    public init<C: Collection>(root: Root?, _ components: C) where C.Element == Component {
        self.underlying = .init(root: root?.underlying, components.map(\.underlying))
    }

    /// Create an instance from an optional root and a slice of another path's components.
    public init(root: Root?, components: Component...) {
        self.init(root: root, components)
    }

    /// The extension of the file or directory's last component.
    ///
    /// If `lastComponent` is `nil` or one of the special path components `.` or `..`, `get` returns `nil` and `set` does nothing.
    ///
    /// If `lastComponent` does not contain a `.` anywhere, or only at the start, `get` returns `nil` and `set` will append a `.` and `newValue` to
    /// `lastComponent`.
    ///
    /// Otherwise `get` returns everything after the last `.` and `set` will replace the extension.
    ///
    /// Getting the extension:
    ///   * `/tmp/foo.txt                  => txt`
    ///   * `/Applications/Foo.app/        => app`
    ///   * `/Applications/Foo.app/bar.txt => txt`
    ///   * `/tmp/foo.tar.gz               => gz`
    ///   * `/tmp/.hidden                  => nil`
    ///   * `/tmp/.hidden.                 => ""`
    ///   * `/tmp/..                       => nil`
    ///
    /// Setting the extension:
    ///
    ///     var path = "/tmp/file"
    ///     path.extension = "txt"  // path is "/tmp/file.txt"
    ///     path.extension = "o"    // path is "/tmp/file.o"
    ///     path.extension = nil    // path is "/tmp/file"
    ///     path.extension = ""     // path is "/tmp/file."
    public var `extension`: String? {
        get {
            self.underlying.`extension`
        }
        set {
            self.underlying.`extension` = newValue
        }
    }

    /// Returns true if this path uniquely identifies the location of a file without reference to an additional starting location.
    ///
    /// On Unix platforms, absolute paths begin with a `/`. `isAbsolute` is equivalent to `root != nil`.
    ///
    /// On Windows, absolute paths are fully qualified paths. `isAbsolute` is _not_ equivalent to `root != nil` for traditional DOS paths (e.g. `C:foo`
    /// and `\bar` have roots but are not absolute). UNC paths and device paths are always absolute. Traditional DOS paths are absolute only if they begin with
    /// a volume or drive followed by a `:` and a separator.
    ///
    /// - Note: This does not perform shell expansion or substitute environment variables; paths beginning with `~` are considered relative.
    ///
    /// Examples:
    /// * Unix:
    ///   * `/usr/local/bin`
    ///   * `/tmp/foo.txt`
    ///   * `/`
    /// * Windows:
    ///   * `C:\Users\`
    ///   * `\\?\UNC\server\share\bar.exe`
    ///   * `\\server\share\bar.exe`
    public var isAbsolute: Bool {
        self.underlying.isAbsolute
    }

    /// Returns true if the path is empty. False otherwise.
    public var isEmpty: Bool {
        self.underlying.isEmpty
    }

    /// Whether the path is in lexical-normal form, that is `.` and `..` components have been collapsed lexically (i.e. without following symlinks).
    ///
    /// Examples:
    /// * `"/usr/local/bin".isLexicallyNormal == true`
    /// * `"../local/bin".isLexicallyNormal   == true`
    /// * `"local/bin/..".isLexicallyNormal   == false`
    public var isLexicallyNormal: Bool {
        self.underlying.isLexicallyNormal
    }

    /// Returns true if this path is not absolute (see ``NIOFilePath/isAbsolute``).
    ///
    /// Examples of relative file paths:
    /// * Unix:
    ///   * `~/bar`
    ///   * `tmp/foo.txt`
    /// * Windows:
    ///   * `bar\baz`
    ///   * `C:Users\`
    ///   * `\Users`
    public var isRelative: Bool {
        self.underlying.isRelative
    }

    /// Returns the final component of the path.
    /// Returns `nil` if the path is empty or only contains a root.
    ///
    /// - Note: Even if the final component is a special directory (`.` or `..`), it will still be returned. See ``NIOFilePath/lexicallyNormalize()``.
    ///
    /// Examples:
    /// * Unix:
    ///   * `/usr/local/bin/ => bin`
    ///   * `/tmp/foo.txt    => foo.txt`
    ///   * `/tmp/foo.txt/.. => ..`
    ///   * `/tmp/foo.txt/.  => .`
    ///   * `/               => nil`
    /// * Windows:
    ///   * `C:\Users\                    => Users`
    ///   * `C:Users\                     => Users`
    ///   * `C:\                          => nil`
    ///   * `\Users\                      => Users`
    ///   * `\\?\UNC\server\share\bar.exe => bar.exe`
    ///   * `\\server\share               => nil`
    ///   * `\\?\UNC\server\share\        => nil`
    public var lastComponent: Component? {
        self.underlying.lastComponent.flatMap(Component.init)
    }

    /// The length of the file path, excluding the null terminator.
    public var length: Int {
        self.underlying.length
    }

    /// The non-extension portion of the file or directory last component.
    ///
    /// Returns `nil` if `lastComponent` is `nil`
    ///
    ///   * `/tmp/foo.txt                 => foo`
    ///   * `/Applications/Foo.app/        => Foo`
    ///   * `/Applications/Foo.app/bar.txt => bar`
    ///   * `/tmp/.hidden                 => .hidden`
    ///   * `/tmp/..                      => ..`
    ///   * `/                            => nil`
    public var stem: String? {
        self.underlying.stem
    }

    /// Creates a string by interpreting the path's content as UTF-8 on Unix and UTF-16 on Windows.
    ///
    /// This property is equivalent to calling `String(decoding: path)`
    public var string: String {
        self.underlying.string
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

    /// Append `components` on to the end of this path.
    ///
    /// Example:
    ///
    ///     var path: NIOFilePath = "/"
    ///     path.append(["usr", "local"])     // path is "/usr/local"
    ///     let otherPath: NIOFilePath = "/bin/ls"
    ///     path.append(otherPath.components) // path is "/usr/local/bin/ls"
    public mutating func append<C>(components: C) where C: Collection, C.Element == Component {
        self.underlying.append(components.map(\.underlying))
    }

    /// Append a `component` on to the end of this path.
    ///
    /// Example:
    ///
    ///     var path: NIOFilePath = "/tmp"
    ///     let sub: NIOFilePath = "foo/./bar/../baz/."
    ///     for comp in sub.components.filter({ $0.kind != .currentDirectory }) {
    ///       path.append(comp)
    ///     }
    ///     // path is "/tmp/foo/bar/../baz"
    public mutating func append(_ component: Component) {
        self.underlying.append(component.underlying)
    }

    /// Append the contents of `other`, ignoring any spurious leading separators.
    ///
    /// A leading separator is spurious if `self` is non-empty.
    ///
    /// Example:
    ///
    ///     var path: NIOFilePath = ""
    ///     path.append("/var/www/website") // "/var/www/website"
    ///     path.append("static/assets") // "/var/www/website/static/assets"
    ///     path.append("/main.css") // "/var/www/website/static/assets/main.css"
    public mutating func append(_ other: String) {
        self.underlying.append(other)
    }

    /// Non-mutating version of ``append(components:)``.
    public func appending<C: Collection>(_ components: C) -> NIOFilePath where C.Element == Component {
        NIOFilePath(self.underlying.appending(components.map(\.underlying)))
    }

    /// Non-mutating version of ``append(_:)-(Component)``.
    public func appending(_ other: Component) -> NIOFilePath {
        NIOFilePath(self.underlying.appending(other.underlying))
    }

    /// Non-mutating version of ``append(_:)-(String)``.
    public func appending(_ other: String) -> NIOFilePath {
        NIOFilePath(self.underlying.appending(other))
    }

    /// Returns whether `other` is a suffix of `self`, only considering whole path components.
    ///
    /// Example:
    ///
    ///     let path: NIOFilePath = "/usr/bin/ls"
    ///     path.ends(with: "ls")             // true
    ///     path.ends(with: "bin/ls")         // true
    ///     path.ends(with: "usr/bin/ls")     // true
    ///     path.ends(with: "/usr/bin/ls///") // true
    ///     path.ends(with: "/ls")            // false
    public func ends(with other: NIOFilePath) -> Bool {
        self.underlying.ends(with: other.underlying)
    }

    /// Collapse `.` and `..` components lexically (i.e. without following symlinks).
    ///
    /// Examples:
    /// * `/usr/./local/bin/.. => /usr/local`
    /// * `/../usr/local/bin   => /usr/local/bin`
    /// * `../usr/local/../bin => ../usr/bin`
    public mutating func lexicallyNormalize() {
        self.underlying.lexicallyNormalize()
    }

    /// Returns a copy of `self` in lexical-normal form, that is `.` and `..` components have been collapsed lexically (i.e. without following symlinks).
    /// See ``lexicallyNormalize()``.
    public func lexicallyNormalized() -> NIOFilePath {
        NIOFilePath(self.underlying.lexicallyNormalized())
    }

    /// Creates a new instance by resolving `subpath` relative to `self`, ensuring that the result is lexically contained within `self`.
    ///
    /// `subpath` will be lexically normalized (see ``lexicallyNormalize()``) as part of resolution, meaning any contained `.` and `..` components
    /// will be collapsed without resolving symlinks. Any root in `subpath` will be ignored.
    ///
    /// Returns `nil` if the result would "escape" from `self` through use of the special directory component `..`.
    ///
    /// This is useful for protecting against arbitrary path traversal from an untrusted subpath: the result is guaranteed to be lexically contained within `self`.
    /// Since this operation does not consult the file system to resolve symlinks, any escaping symlinks nested inside of `self` can still be targeted by the result.
    ///
    /// Example:
    ///
    ///     let staticContent: NIOFilePath = "/var/www/my-website/static"
    ///     let links: [NIOFilePath] =
    ///       ["index.html", "/assets/main.css", "../../../../etc/passwd"]
    ///     links.map { staticContent.lexicallyResolving($0) }
    ///       // ["/var/www/my-website/static/index.html",
    ///       //  "/var/www/my-website/static/assets/main.css",
    ///       //  nil]
    public func lexicallyResolving(_ subpath: NIOFilePath) -> NIOFilePath? {
        let result = self.underlying.lexicallyResolving(subpath.underlying)
        return result.flatMap(NIOFilePath.init)
    }

    /// If `other` does not have a root, append each component of `other`. If `other` has a root, replaces `self` with other.
    ///
    /// This operation mimics traversing a directory structure (similar to the `cd` command), where pushing a relative path will append its components and
    /// pushing an absolute path will first clear `self`'s existing components.
    ///
    /// Example:
    ///
    ///     var path: NIOFilePath = "/tmp"
    ///     path.push("dir/file.txt") // path is "/tmp/dir/file.txt"
    ///     path.push("/bin")         // path is "/bin"
    public mutating func push(_ other: NIOFilePath) {
        self.underlying.push(other.underlying)
    }

    /// Non-mutating version of ``push(_:)``
    public func pushing(_ other: NIOFilePath) -> NIOFilePath {
        NIOFilePath(self.underlying.pushing(other.underlying))
    }

    /// Remove the contents of the path, keeping the null terminator.
    public mutating func removeAll(keepingCapacity: Bool = false) {
        self.underlying.removeAll(keepingCapacity: keepingCapacity)
    }

    /// Creates a new path with everything up to but not including `lastComponent`.
    ///
    /// If the path only contains a root, returns `self`.
    /// If the path has no root and only includes a single component, returns an empty ``NIOFilePath``.
    ///
    /// Examples:
    /// * Unix:
    ///   * `/usr/bin/ls => /usr/bin`
    ///   * `/foo        => /`
    ///   * `/           => /`
    ///   * `foo         => ""`
    /// * Windows:
    ///   * `C:\foo\bar.exe                 => C:\foo`
    ///   * `C:\                            => C:\`
    ///   * `\\server\share\folder\file.txt => \\server\share\folder`
    ///   * `\\server\share\                => \\server\share\`
    public func removingLastComponent() -> NIOFilePath {
        NIOFilePath(self.underlying.removingLastComponent())
    }

    /// In-place mutating variant of ``removeLastComponent()``.
    ///
    /// If `self` only contains a root, does nothing and returns `false`. Otherwise removes `lastComponent` and returns `true`.
    ///
    /// Example:
    ///
    ///     var path = "/usr/bin"
    ///     path.removeLastComponent() == true  // path is "/usr"
    ///     path.removeLastComponent() == true  // path is "/"
    ///     path.removeLastComponent() == false // path is "/"
    @discardableResult
    public mutating func removeLastComponent() -> Bool {
        self.underlying.removeLastComponent()
    }

    /// If `prefix` is a prefix of `self`, removes it and returns `true`.
    /// Otherwise returns `false`.
    ///
    /// Example:
    ///
    ///     var path: NIOFilePath = "/usr/local/bin"
    ///     path.removePrefix("/usr/bin")   // false
    ///     path.removePrefix("/us")        // false
    ///     path.removePrefix("/usr/local") // true, path is "bin"
    public mutating func removePrefix(_ other: NIOFilePath) -> Bool {
        self.underlying.removePrefix(other.underlying)
    }

    /// Creates a new path containing just the components, i.e. everything after `root`.
    ///
    /// Returns self if `root == nil`.
    ///
    /// Examples:
    /// * Unix:
    ///   * `/foo/bar => foo/bar`
    ///   * `foo/bar  => foo/bar`
    ///   * `/        => ""`
    /// * Windows:
    ///   * `C:\foo\bar                  => foo\bar`
    ///   * `foo\bar                     => foo\bar`
    ///   * `\\?\UNC\server\share\file   => file`
    ///   * `\\?\device\folder\file.exe  => folder\file.exe`
    ///   * `\\server\share\file         => file`
    ///   * `\                           => ""
    public func removingRoot() -> NIOFilePath {
        NIOFilePath(self.underlying.removingRoot())
    }

    /// Reserve enough storage space to store `minimumCapacity` platform characters.
    public mutating func reserveCapacity(_ minimumCapacity: Int) {
        self.underlying.reserveCapacity(minimumCapacity)
    }

    /// Returns whether `other` is a prefix of `self`, only considering whole path components.
    ///
    /// Example:
    ///
    ///     let path: NIOFilePath = "/usr/bin/ls"
    ///     path.starts(with: "/")              // true
    ///     path.starts(with: "/usr/bin")       // true
    ///     path.starts(with: "/usr/bin/ls")    // true
    ///     path.starts(with: "/usr/bin/ls///") // true
    ///     path.starts(with: "/us")            // false
    public func starts(with other: NIOFilePath) -> Bool {
        self.underlying.starts(with: other.underlying)
    }

    /// For backwards compatibility only.
    public func withCString<Result>(_ body: (UnsafePointer<CChar>) throws -> Result) rethrows -> Result {
        try self.underlying.withCString(body)
    }
}

// MARK: NIOFilePath.Root
extension NIOFilePath.Root: ExpressibleByStringLiteral, CustomStringConvertible, CustomDebugStringConvertible {
    /// Create a file path root from a string.
    ///
    /// Returns `nil` if `string` is empty or is not a root.
    public init?(_ other: String) {
        guard let underlyingInstance = SystemPackage.FilePath.Root(other) else {
            return nil
        }
        self.underlying = underlyingInstance
    }

    /// Creates a file path root by copying bytes from a null-terminated platform string. It is a precondition that a null byte indicates the end of the string. The absence of a null byte will trigger a runtime error.
    ///
    /// Returns `nil` if `platformString` is empty or is not a root.
    ///
    /// - Warning: It is a precondition that `platformString` must be null-terminated.
    /// The absence of a null byte will trigger a runtime error.
    ///
    /// - Parameter platformString: A null-terminated platform string.
    public init?(platformString: [CInterop.PlatformChar]) {
        guard let underlyingInstance = FilePath.Root(platformString: platformString) else {
            return nil
        }
        self.underlying = underlyingInstance
    }

    /// Creates a file path root by copying bytes from a null-terminated platform string.
    ///
    /// Returns `nil` if `platformString` is empty or is not a root.
    ///
    /// - Parameter platformString: A pointer to a null-terminated platform string.
    public init?(platformString: UnsafePointer<CInterop.PlatformChar>) {
        guard let underlyingInstance = FilePath.Root(platformString: platformString) else {
            return nil
        }
        self.underlying = underlyingInstance
    }

    /// Create a file path root from a string literal.
    ///
    /// - Warning: Precondition: `stringLiteral` is non-empty and is a root.
    public init(stringLiteral: String) {
        self.underlying = .init(stringLiteral: stringLiteral)
    }

    public var description: String {
        self.underlying.description
    }

    /// A textual representation of the path root.
    ///
    /// If the content of the path root isn't a well-formed Unicode string,
    /// this replaces invalid bytes with U+FFFD. See `String.init(decoding:)`.
    public var debugDescription: String {
        self.underlying.debugDescription
    }

    /// On Unix, this returns `"/"`.
    ///
    /// On Windows, interprets the root's content as UTF-16 on Windows.
    ///
    /// This property is equivalent to calling `String(decoding: root)`.
    public var string: String {
        self.underlying.string
    }
}

// MARK: NIOFilePath.Component
extension NIOFilePath.Component: ExpressibleByStringLiteral, CustomStringConvertible, CustomDebugStringConvertible {
    /// Create a file path component from a string.
    ///
    /// Returns `nil` if `string` is empty, a root, or has more than one component in it.
    public init?(_ other: String) {
        guard let underlyingInstance = FilePath.Component(other) else {
            return nil
        }
        self.init(underlyingInstance)
    }

    /// Creates a file path component by copying bytes from a null-terminated platform string. It is a precondition that a null byte indicates the end of the string.
    /// The absence of a null byte will trigger a runtime error.
    ///
    /// Returns `nil` if `platformString` is empty, is a root, or has more than one component in it.
    ///
    /// - Warning: It is a precondition that `platformString` must be null-terminated.
    /// The absence of a null byte will trigger a runtime error.
    ///
    /// - Parameter platformString: A null-terminated platform string.
    public init?(platformString: [CInterop.PlatformChar]) {
        guard let underlyingInstance = FilePath.Component(platformString: platformString) else {
            return nil
        }
        self.init(underlyingInstance)
    }

    /// Creates a file path component by copying bytes from a null-terminated platform string.
    ///
    /// Returns `nil` if `platformString` is empty, is a root, or has more than one component in it.
    ///
    /// - Parameter platformString: A pointer to a null-terminated platform string.
    public init?(platformString: UnsafePointer<CInterop.PlatformChar>) {
        guard let underlyingInstance = FilePath.Component(platformString: platformString) else {
            return nil
        }
        self.init(underlyingInstance)
    }

    /// Create a file path component from a string literal.
    ///
    /// - Warning: Precondition: `stringLiteral` is non-empty, is not a root, and has only one component in it.
    public init(stringLiteral: String) {
        let underlyingInstance = SystemPackage.FilePath.Component(stringLiteral: stringLiteral)
        self.init(underlyingInstance)
    }

    /// The extension of this file or directory component.
    ///
    /// If `self` does not contain a `.` anywhere, or only at the start, returns `nil`. Otherwise, returns everything after the dot.
    ///
    /// Examples:
    ///   * `foo.txt    => txt`
    ///   * `foo.tar.gz => gz`
    ///   * `Foo.app    => app`
    ///   * `.hidden    => nil`
    ///   * `..         => nil`
    public var `extension`: String? {
        self.underlying.extension
    }

    /// Returns the kind of the path component: either a current directory (`.`), a parent directory (`..`), or a regular file/directory.
    public var kind: Kind {
        switch self.underlying.kind {
        case .currentDirectory:
            Kind.currentDirectory
        case .parentDirectory:
            Kind.parentDirectory
        case .regular:
            Kind.regular
        }
    }

    /// The non-extension portion of this file or directory component.
    ///
    /// Examples:
    ///   * `foo.txt => foo`
    ///   * `foo.tar.gz => foo.tar`
    ///   * `Foo.app => Foo`
    ///   * `.hidden => .hidden`
    ///   * `..      => ..`
    public var stem: String {
        self.underlying.stem
    }

    /// Creates a string by interpreting the component’s content as UTF-8 on Unix and UTF-16 on Windows.
    ///
    /// This property is equivalent to calling `String(decoding: component)`.
    public var string: String {
        self.underlying.string
    }

    /// A textual representation of the path component.
    ///
    /// If the content of the path component isn't a well-formed Unicode string, this replaces invalid bytes with U+FFFD. See `String.init(decoding:)`.
    public var description: String {
        self.underlying.description
    }

    /// A textual representation of the path component, suitable for debugging.
    ///
    /// If the content of the path component isn't a well-formed Unicode string, this replaces invalid bytes with U+FFFD. See `String.init(decoding:)`.
    public var debugDescription: String {
        self.underlying.debugDescription
    }

    /// Whether a component is a regular file or directory name, or a special directory `.` or `..`
    @frozen
    public enum Kind {
        /// The special directory `.`, representing the current directory.
        case currentDirectory

        /// The special directory `..`, representing the parent directory.
        case parentDirectory

        /// A file or directory name
        case regular
    }
}

// MARK: NIOFilePath.ComponentView
extension NIOFilePath.ComponentView: BidirectionalCollection, RangeReplaceableCollection, Collection, Sequence {
    public typealias Element = NIOFilePath.Component

    // Creates an empty component view.
    public init() {
        self.init(SystemPackage.FilePath.ComponentView())
    }

    public struct Index: Sendable, Comparable, Hashable {
        let underlying: SystemPackage.FilePath.ComponentView.Index

        init(underlying: SystemPackage.FilePath.ComponentView.Index) {
            self.underlying = underlying
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.underlying < rhs.underlying
        }
    }

    public var startIndex: Index {
        Index(underlying: self.underlying.startIndex)
    }

    public var endIndex: Index {
        Index(underlying: self.underlying.endIndex)
    }

    public func index(after i: Index) -> Index {
        Index(underlying: self.underlying.index(after: i.underlying))
    }

    public func index(before i: Index) -> Index {
        Index(underlying: self.underlying.index(before: i.underlying))
    }

    public subscript(position: Index) -> NIOFilePath.Component {
        .init(self.underlying[position.underlying])
    }

    public mutating func replaceSubrange<C>(_ subrange: Range<Index>, with newElements: C)
    where C: Collection, C.Element == NIOFilePath.Component {
        let convertedSubrange = Range(
            uncheckedBounds: (lower: subrange.lowerBound.underlying, upper: subrange.upperBound.underlying)
        )

        self.underlying.replaceSubrange(convertedSubrange, with: newElements.map(\.underlying))
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
