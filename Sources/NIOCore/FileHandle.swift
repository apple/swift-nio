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

import Atomics
#if os(Windows)
import ucrt
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("The File Handle module was unable to identify your C library.")
#endif

#if os(Windows)
public typealias NIOPOSIXFileMode = CInt
#else
public typealias NIOPOSIXFileMode = mode_t
#endif

internal struct FileDescriptorState {
    private static let closedValue: UInt = 0xdead
    private static let inUseValue: UInt = 0xbeef
    private static let openValue: UInt = 0xcafe
    internal var rawValue: DoubleWord

    internal init(rawValue: DoubleWord) {
        self.rawValue = rawValue
    }

    internal init(descriptor: CInt) {
        self.rawValue = DoubleWord(
            first: UInt(truncatingIfNeeded: CUnsignedInt(bitPattern: descriptor)),
            second: Self.openValue
        )
    }

    internal var descriptor: CInt {
        get {
            return CInt(bitPattern: UInt32(truncatingIfNeeded: self.rawValue.first))
        }
        set {
            self.rawValue.first = UInt(truncatingIfNeeded: CUnsignedInt(bitPattern: newValue))
        }
    }

    internal var isOpen: Bool {
        return self.rawValue.second == Self.openValue
    }

    internal var isInUse: Bool {
        return self.rawValue.second == Self.inUseValue
    }

    internal var isClosed: Bool {
        return self.rawValue.second == Self.closedValue
    }

    mutating func close() {
        assert(self.isOpen)
        self.rawValue.second = Self.closedValue
    }

    mutating func markInUse() {
        assert(self.isOpen)
        self.rawValue.second = Self.inUseValue
    }

    mutating func markNotInUse() {
        assert(self.rawValue.second == Self.inUseValue)
        self.rawValue.second = Self.openValue
    }
}

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
public final class NIOFileHandle: FileDescriptor & Sendable {
    private static let descriptorClosed: CInt = CInt.min
    private let descriptor: UnsafeAtomic<DoubleWord>

    public var isOpen: Bool {
        return FileDescriptorState(
            rawValue: self.descriptor.load(ordering: .sequentiallyConsistent)
        ).isOpen
    }

    private static func interpretDescriptorValueThrowIfNotOpen(
        _ descriptor: DoubleWord,
        applyCloseInUseException: Bool
    ) throws -> FileDescriptorState {
        let descriptorState = FileDescriptorState(rawValue: descriptor)
        if descriptorState.isOpen {
            return descriptorState
        } else if descriptorState.isClosed {
            throw IOError(errnoCode: EBADF, reason: "can't close file (as it's not open anymore).")
        } else {
            if applyCloseInUseException {
                return descriptorState
            } else {
                throw IOError(errnoCode: EBUSY, reason: "file descriptor currently in use")
            }
        }
    }

    private func peekAtDescriptorIfOpen(applyCloseInUseException: Bool) throws -> FileDescriptorState {
        let descriptor = self.descriptor.load(ordering: .relaxed)
        return try Self.interpretDescriptorValueThrowIfNotOpen(
            descriptor,
            applyCloseInUseException: applyCloseInUseException
        )
    }

    /// Create a `NIOFileHandle` taking ownership of `descriptor`. You must call `NIOFileHandle.close` or `NIOFileHandle.takeDescriptorOwnership` before
    /// this object can be safely released.
    public init(descriptor: CInt) {
        self.descriptor = UnsafeAtomic.create(FileDescriptorState(descriptor: descriptor).rawValue)
    }

    deinit {
        assert(!self.isOpen, "leaked open NIOFileHandle(descriptor: \(self.descriptor)). Call `close()` to close or `takeDescriptorOwnership()` to take ownership and close by some other means.")
        self.descriptor.destroy()
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

    private func activateDescriptor(as descriptor: CInt) {
        let desired = FileDescriptorState(descriptor: descriptor)
        var expected = desired
        expected.markInUse()
        let (exchanged, original) = self.descriptor.compareExchange(
            expected: expected.rawValue,
            desired: desired.rawValue,
            ordering: .sequentiallyConsistent
        )
        guard exchanged || FileDescriptorState(rawValue: original).isClosed else {
            fatalError("bug in NIO (please report): NIOFileDescritor activate failed \(original)")
        }
    }

    private func deactivateDescriptor(toClosed: Bool) throws -> CInt {
        let peekedDescriptor = try self.peekAtDescriptorIfOpen(applyCloseInUseException: toClosed)
        assert(peekedDescriptor.isOpen || peekedDescriptor.isInUse)
        var desired = peekedDescriptor
        if toClosed {
            if desired.isInUse {
                desired.markNotInUse()
            }
            desired.close()
        } else {
            desired.markInUse()
        }
        let (exchanged, originalDescriptor) = self.descriptor.compareExchange(
            expected: peekedDescriptor.rawValue,
            desired: desired.rawValue,
            ordering: .sequentiallyConsistent
        )

        if exchanged {
            assert(peekedDescriptor.rawValue == originalDescriptor)
            return peekedDescriptor.descriptor
        } else {
            let fauxDescriptor = try Self.interpretDescriptorValueThrowIfNotOpen(
                originalDescriptor,
                applyCloseInUseException: toClosed
            )
            // This is impossible, because there are only 4 options in which the exchange above can fail
            // 1. Descriptor already closed (would've thrown above)
            // 2. Descriptor in use (would've thrown above)
            // 3. Descriptor at illegal negative value (would've crashed above)
            // 4. Descriptor a different, positive value (this is where we're at) --> memory corruption, let's crash
            fatalError("""
                       bug in NIO (please report): \
                       NIOFileDescriptor illegal state \
                       (\(peekedDescriptor), \(originalDescriptor), \(fauxDescriptor))")
                       """)
        }
    }

    /// Take the ownership of the underlying file descriptor. This is similar to `close()` but the underlying file
    /// descriptor remains open. The caller is responsible for closing the file descriptor by some other means.
    ///
    /// After calling this, the `NIOFileHandle` cannot be used for anything else and all the operations will throw.
    ///
    /// - returns: The underlying file descriptor, now owned by the caller.
    public func takeDescriptorOwnership() throws -> CInt {
        return try self.deactivateDescriptor(toClosed: true)
    }

    public func close() throws {
        let descriptor = try self.deactivateDescriptor(toClosed: true)
        try SystemCalls.close(descriptor: descriptor)
    }

    public func withUnsafeFileDescriptor<T>(_ body: (CInt) throws -> T) throws -> T {
        let descriptor = try self.deactivateDescriptor(toClosed: false)
        defer {
            self.activateDescriptor(as: descriptor)
        }
        return try body(descriptor)
    }
}

extension NIOFileHandle {
    /// `Mode` represents file access modes.
    public struct Mode: OptionSet, Sendable {
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
    public struct Flags: Sendable {
        internal var posixMode: NIOPOSIXFileMode
        internal var posixFlags: CInt

        public static let `default` = Flags(posixMode: 0, posixFlags: 0)

#if os(Windows)
        public static let defaultPermissions = _S_IREAD | _S_IWRITE
#else
        public static let defaultPermissions = S_IWUSR | S_IRUSR | S_IRGRP | S_IROTH
#endif

        /// Allows file creation when opening file for writing. File owner is set to the effective user ID of the process.
        ///
        /// - parameters:
        ///     - posixMode: `file mode` applied when file is created. Default permissions are: read and write for fileowner, read for owners group and others.
        public static func allowFileCreation(posixMode: NIOPOSIXFileMode = defaultPermissions) -> Flags {
            return Flags(posixMode: posixMode, posixFlags: O_CREAT)
        }

        /// Allows the specification of POSIX flags (e.g. `O_TRUNC`) and mode (e.g. `S_IWUSR`)
        ///
        /// - parameters:
        ///     - flags: The POSIX open flags (the second parameter for `open(2)`).
        ///     - mode: The POSIX mode (the third parameter for `open(2)`).
        /// - returns: A `NIOFileHandle.Mode` equivalent to the given POSIX flags and mode.
        public static func posix(flags: CInt, mode: NIOPOSIXFileMode) -> Flags {
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
#if os(Windows)
        let fl = mode.posixFlags | flags.posixFlags | _O_NOINHERIT
#else
        let fl = mode.posixFlags | flags.posixFlags | O_CLOEXEC
#endif
        let fd = try SystemCalls.open(file: path, oFlag: fl, mode: flags.posixMode)
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
        return "FileHandle { descriptor: \(FileDescriptorState(rawValue: self.descriptor.load(ordering: .relaxed)).descriptor) }"
    }
}
