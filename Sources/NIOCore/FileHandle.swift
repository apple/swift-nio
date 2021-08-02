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
#if os(Windows)
import ucrt
#elseif os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#elseif os(Linux) || os(Android)
import Glibc
#endif

/// A `NIOFileHandle` is a handle to an open file.
///
/// When creating a `NIOFileHandle` it takes ownership of the underlying file descriptor. When a `NIOFileHandle` is no longer
/// needed you must `close` it or take back ownership of the file descriptor using `takeDescriptorOwnership`.
///
/// - note: One underlying file descriptor should usually be managed by one `NIOFileHandle` only.
///
/// - warning: Failing to manage the lifetime of a `NIOFileHandle` correctly will result in undefined behaviour.
///
/// - warning: `NIOFileHandle` objects are not thread-safe and are mutable. They also cannot be fully thread-safe as they refer to a global underlying file descriptor.
public final class NIOFileHandle: FileDescriptor {
    public private(set) var isOpen: Bool
    private let descriptor: CInt

    /// Create a `NIOFileHandle` taking ownership of `descriptor`. You must call `NIOFileHandle.close` or `NIOFileHandle.takeDescriptorOwnership` before
    /// this object can be safely released.
    public init(descriptor: CInt) {
        self.descriptor = descriptor
        self.isOpen = true
    }

    deinit {
        assert(!self.isOpen, "leaked open NIOFileHandle(descriptor: \(self.descriptor)). Call `close()` to close or `takeDescriptorOwnership()` to take ownership and close by some other means.")
    }

    /// Duplicates this `NIOFileHandle`. This means that a new `NIOFileHandle` object with a new underlying file descriptor
    /// is returned. The caller takes ownership of the returned `NIOFileHandle` and is responsible for closing it.
    ///
    /// - warning: The returned `NIOFileHandle` is not fully independent, the seek pointer is shared as documented by `dup(2)`.
    ///
    /// - returns: A new `NIOFileHandle` with a fresh underlying file descriptor but shared seek pointer.
    public func duplicate() throws -> NIOFileHandle {
        return try withUnsafeFileDescriptor { fd in
            NIOFileHandle(descriptor: try SystemCalls.dup(descriptor: fd))
        }
    }

    /// Take the ownership of the underlying file descriptor. This is similar to `close()` but the underlying file
    /// descriptor remains open. The caller is responsible for closing the file descriptor by some other means.
    ///
    /// After calling this, the `NIOFileHandle` cannot be used for anything else and all the operations will throw.
    ///
    /// - returns: The underlying file descriptor, now owned by the caller.
    public func takeDescriptorOwnership() throws -> CInt {
        guard self.isOpen else {
            throw IOError(errnoCode: EBADF, reason: "can't close file (as it's not open anymore).")
        }

        self.isOpen = false
        return self.descriptor
    }

    public func close() throws {
        try withUnsafeFileDescriptor { fd in
            try SystemCalls.close(descriptor: fd)
        }

        self.isOpen = false
    }

    public func withUnsafeFileDescriptor<T>(_ body: (CInt) throws -> T) throws -> T {
        guard self.isOpen else {
            throw IOError(errnoCode: EBADF, reason: "file descriptor already closed!")
        }
        return try body(self.descriptor)
    }
}

extension NIOFileHandle {
    /// `Mode` represents file access modes.
    public struct Mode: OptionSet {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        internal var posixFlags: CInt {
            switch self {
            case [.read, .write]:
                return O_RDWR
            case .read:
                return O_RDONLY
            case .write:
                return O_WRONLY
            default:
                preconditionFailure("Unsupported mode value")
            }
        }

        /// Opens file for reading
        public static let read = Mode(rawValue: 1 << 0)
        /// Opens file for writing
        public static let write = Mode(rawValue: 1 << 1)
    }

    /// `Flags` allows to specify additional flags to `Mode`, such as permission for file creation.
    public struct Flags {
        internal var posixMode: mode_t
        internal var posixFlags: CInt

        public static let `default` = Flags(posixMode: 0, posixFlags: 0)

        /// Allows file creation when opening file for writing. File owner is set to the effective user ID of the process.
        ///
        /// - parameters:
        ///     - posixMode: `file mode` applied when file is created. Default permissions are: read and write for fileowner, read for owners group and others.
        public static func allowFileCreation(posixMode: mode_t = S_IWUSR | S_IRUSR | S_IRGRP | S_IROTH) -> Flags {
            return Flags(posixMode: posixMode, posixFlags: O_CREAT)
        }

        /// Allows the specification of POSIX flags (e.g. `O_TRUNC`) and mode (e.g. `S_IWUSR`)
        ///
        /// - parameters:
        ///     - flags: The POSIX open flags (the second parameter for `open(2)`).
        ///     - mode: The POSIX mode (the third parameter for `open(2)`).
        /// - returns: A `NIOFileHandle.Mode` equivalent to the given POSIX flags and mode.
        public static func posix(flags: CInt, mode: mode_t) -> Flags {
            return Flags(posixMode: mode, posixFlags: flags)
        }
    }

    /// Open a new `NIOFileHandle`. This operation is blocking.
    ///
    /// - parameters:
    ///     - path: The path of the file to open. The ownership of the file descriptor is transferred to this `NIOFileHandle` and so it will be closed once `close` is called.
    ///     - mode: Access mode. Default mode is `.read`.
    ///     - flags: Additional POSIX flags.
    public convenience init(path: String, mode: Mode = .read, flags: Flags = .default) throws {
        let fd = try SystemCalls.open(file: path, oFlag: mode.posixFlags | O_CLOEXEC | flags.posixFlags, mode: flags.posixMode)
        self.init(descriptor: fd)
    }

    /// Open a new `NIOFileHandle`. This operation is blocking.
    ///
    /// - parameters:
    ///     - path: The path of the file to open. The ownership of the file descriptor is transferred to this `NIOFileHandle` and so it will be closed once `close` is called.
    public convenience init(path: String) throws {
        // This function is here because we had a function like this in NIO 2.0, and the one above doesn't quite match. Sadly we can't
        // really deprecate this either, because it'll be preferred to the one above in many cases.
        try self.init(path: path, mode: .read, flags: .default)
    }
}

extension NIOFileHandle: CustomStringConvertible {
    public var description: String {
        return "FileHandle { descriptor: \(self.descriptor) }"
    }
}
