//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2024 Apple Inc. and the SwiftNIO project authors
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
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Android)
@preconcurrency import Android
#elseif canImport(WASILibc)
@preconcurrency import WASILibc
import CNIOWASI
#else
#error("The File Handle module was unable to identify your C library.")
#endif

#if os(Windows)
public typealias NIOPOSIXFileMode = CInt
#else
public typealias NIOPOSIXFileMode = mode_t
#endif

#if arch(x86_64) || arch(arm64)
// 64 bit architectures
typealias OneUInt32 = UInt32
typealias TwoUInt32s = UInt64

// Now we need to make `UInt64` match `DoubleWord`'s API but we can't use a custom
// type because we need special support by the `swift-atomics` package.
extension UInt64 {
    fileprivate init(first: UInt32, second: UInt32) {
        self = UInt64(first) << 32 | UInt64(second)
    }

    fileprivate var first: UInt32 {
        get {
            UInt32(truncatingIfNeeded: self >> 32)
        }
        set {
            self = (UInt64(newValue) << 32) | UInt64(self.second)
        }
    }

    fileprivate var second: UInt32 {
        get {
            UInt32(truncatingIfNeeded: self & 0xff_ff_ff_ff)
        }
        set {
            self = (UInt64(self.first) << 32) | UInt64(newValue)
        }
    }
}
#elseif arch(arm) || arch(i386) || arch(arm64_32) || arch(wasm32)
// 32 bit architectures
// Note: for testing purposes you can also use these defines for 64 bit platforms, they'll just consume twice as
// much space, nothing else will go bad.
typealias OneUInt32 = UInt
typealias TwoUInt32s = DoubleWord
#else
#error("Unknown architecture")
#endif

internal struct FileDescriptorState {
    private static let closedValue: OneUInt32 = 0xdead
    private static let inUseValue: OneUInt32 = 0xbeef
    private static let openValue: OneUInt32 = 0xcafe
    internal var rawValue: TwoUInt32s

    internal init(rawValue: TwoUInt32s) {
        self.rawValue = rawValue
    }

    internal init(descriptor: CInt) {
        self.rawValue = TwoUInt32s(
            first: .init(truncatingIfNeeded: CUnsignedInt(bitPattern: descriptor)),
            second: Self.openValue
        )
    }

    internal var descriptor: CInt {
        get {
            CInt(bitPattern: UInt32(truncatingIfNeeded: self.rawValue.first))
        }
        set {
            self.rawValue.first = .init(truncatingIfNeeded: CUnsignedInt(bitPattern: newValue))
        }
    }

    internal var isOpen: Bool {
        self.rawValue.second == Self.openValue
    }

    internal var isInUse: Bool {
        self.rawValue.second == Self.inUseValue
    }

    internal var isClosed: Bool {
        self.rawValue.second == Self.closedValue
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

/// Deprecated. `NIOFileHandle` is a handle to an open file descriptor.
///
/// - warning: The `NIOFileHandle` API is deprecated, do not use going forward. It's not marked as `deprecated` yet such
///            that users don't get the deprecation warnings affecting their APIs everywhere. For file I/O, please use
///            the `NIOFileSystem` API.
///
/// When creating a `NIOFileHandle` it takes ownership of the underlying file descriptor. When a `NIOFileHandle` is no longer
/// needed you must `close` it or take back ownership of the file descriptor using `takeDescriptorOwnership`.
///
/// - Note: One underlying file descriptor should usually be managed by one `NIOFileHandle` only.
///
/// - warning: Failing to manage the lifetime of a `NIOFileHandle` correctly will result in undefined behaviour.
///
/// - Note: As of SwiftNIO 2.77.0, `NIOFileHandle` objects are are thread-safe and enforce singular access. If you access the same `NIOFileHandle`
///         multiple times, it will throw `IOError(errorCode: EBUSY)` for the second access.
public final class NIOFileHandle: FileDescriptor & Sendable {
    private static let descriptorClosed: CInt = CInt.min
    private let descriptor: UnsafeAtomic<TwoUInt32s>

    public var isOpen: Bool {
        FileDescriptorState(
            rawValue: self.descriptor.load(ordering: .sequentiallyConsistent)
        ).isOpen
    }

    private static func interpretDescriptorValueThrowIfInUseOrNotOpen(
        _ descriptor: TwoUInt32s
    ) throws -> FileDescriptorState {
        let descriptorState = FileDescriptorState(rawValue: descriptor)
        if descriptorState.isOpen {
            return descriptorState
        } else if descriptorState.isClosed {
            throw IOError(errnoCode: EBADF, reason: "can't close file (as it's not open anymore).")
        } else {
            throw IOError(errnoCode: EBUSY, reason: "file descriptor currently in use")
        }
    }

    private func peekAtDescriptorIfOpen() throws -> FileDescriptorState {
        let descriptor = self.descriptor.load(ordering: .relaxed)
        return try Self.interpretDescriptorValueThrowIfInUseOrNotOpen(descriptor)
    }

    /// Create a `NIOFileHandle` taking ownership of `descriptor`. You must call `NIOFileHandle.close` or `NIOFileHandle.takeDescriptorOwnership` before
    /// this object can be safely released.
    @available(
        *,
        deprecated,
        message: """
            Avoid using NIOFileHandle. The type is difficult to hold correctly, \
            use NIOFileSystem as a replacement API.
            """
    )
    public convenience init(descriptor: CInt) {
        self.init(_deprecatedTakingOwnershipOfDescriptor: descriptor)
    }

    /// Create a `NIOFileHandle` taking ownership of `descriptor`. You must call `NIOFileHandle.close` or `NIOFileHandle.takeDescriptorOwnership` before
    /// this object can be safely released.
    public init(_deprecatedTakingOwnershipOfDescriptor descriptor: CInt) {
        self.descriptor = UnsafeAtomic.create(FileDescriptorState(descriptor: descriptor).rawValue)
    }

    deinit {
        assert(
            !self.isOpen,
            "leaked open NIOFileHandle(descriptor: \(self.descriptor)). Call `close()` to close or `takeDescriptorOwnership()` to take ownership and close by some other means."
        )
        self.descriptor.destroy()
    }

    #if !os(WASI)
    /// Duplicates this `NIOFileHandle`. This means that a new `NIOFileHandle` object with a new underlying file descriptor
    /// is returned. The caller takes ownership of the returned `NIOFileHandle` and is responsible for closing it.
    ///
    /// - warning: The returned `NIOFileHandle` is not fully independent, the seek pointer is shared as documented by `dup(2)`.
    ///
    /// - Returns: A new `NIOFileHandle` with a fresh underlying file descriptor but shared seek pointer.
    public func duplicate() throws -> NIOFileHandle {
        try self.withUnsafeFileDescriptor { fd in
            NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: try SystemCalls.dup(descriptor: fd))
        }
    }
    #endif

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
        let peekedDescriptor = try self.peekAtDescriptorIfOpen()
        // Don't worry, the above is just opportunistic. If we lose the race, we re-check below --> `!exchanged`
        assert(peekedDescriptor.isOpen)
        var desired = peekedDescriptor
        if toClosed {
            desired.close()
        } else {
            desired.markInUse()
        }
        assert(desired.rawValue != peekedDescriptor.rawValue, "\(desired.rawValue) == \(peekedDescriptor.rawValue)")
        let (exchanged, originalDescriptor) = self.descriptor.compareExchange(
            expected: peekedDescriptor.rawValue,
            desired: desired.rawValue,
            ordering: .sequentiallyConsistent
        )

        if exchanged {
            assert(peekedDescriptor.rawValue == originalDescriptor)
            return peekedDescriptor.descriptor
        } else {
            // We lost the race above, so this _will_ throw (as we're not closed).
            let fauxDescriptor = try Self.interpretDescriptorValueThrowIfInUseOrNotOpen(originalDescriptor)
            // This is impossible, because there are only 4 options in which the exchange above can fail
            // 1. Descriptor already closed (would've thrown above)
            // 2. Descriptor in use (would've thrown above)
            // 3. Descriptor at illegal negative value (would've crashed above)
            // 4. Descriptor a different, positive value (this is where we're at) --> memory corruption, let's crash
            fatalError(
                """
                bug in NIO (please report): \
                NIOFileDescriptor illegal state \
                (\(peekedDescriptor), \(originalDescriptor), \(fauxDescriptor))")
                """
            )
        }
    }

    /// Take the ownership of the underlying file descriptor. This is similar to `close()` but the underlying file
    /// descriptor remains open. The caller is responsible for closing the file descriptor by some other means.
    ///
    /// After calling this, the `NIOFileHandle` cannot be used for anything else and all the operations will throw.
    ///
    /// - Returns: The underlying file descriptor, now owned by the caller.
    public func takeDescriptorOwnership() throws -> CInt {
        try self.deactivateDescriptor(toClosed: true)
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

        @inlinable
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
        @inlinable
        public static var read: Mode { Mode(rawValue: 1 << 0) }
        /// Opens file for writing
        @inlinable
        public static var write: NIOFileHandle.Mode { Mode(rawValue: 1 << 1) }
    }

    /// `Flags` allows to specify additional flags to `Mode`, such as permission for file creation.
    public struct Flags: Sendable {
        @usableFromInline
        internal var posixMode: NIOPOSIXFileMode

        @usableFromInline
        internal var posixFlags: CInt

        @inlinable
        internal init(posixMode: NIOPOSIXFileMode, posixFlags: CInt) {
            self.posixMode = posixMode
            self.posixFlags = posixFlags
        }

        public static var `default`: Flags { Flags(posixMode: 0, posixFlags: 0) }

        #if os(Windows)
        public static let defaultPermissions = _S_IREAD | _S_IWRITE
        #elseif os(WASI)
        public static let defaultPermissions = WASILibc.S_IWUSR | WASILibc.S_IRUSR | WASILibc.S_IRGRP | WASILibc.S_IROTH
        #else
        public static let defaultPermissions = S_IWUSR | S_IRUSR | S_IRGRP | S_IROTH
        #endif

        /// Allows file creation when opening file for writing. File owner is set to the effective user ID of the process.
        ///
        /// - Parameters:
        ///   - posixMode: `file mode` applied when file is created. Default permissions are: read and write for fileowner, read for owners group and others.
        public static func allowFileCreation(posixMode: NIOPOSIXFileMode = defaultPermissions) -> Flags {
            #if os(WASI)
            let flags = CNIOWASI_O_CREAT()
            #else
            let flags = O_CREAT
            #endif
            return Flags(posixMode: posixMode, posixFlags: flags)
        }

        /// Allows the specification of POSIX flags (e.g. `O_TRUNC`) and mode (e.g. `S_IWUSR`)
        ///
        /// - Parameters:
        ///   - flags: The POSIX open flags (the second parameter for `open(2)`).
        ///   - mode: The POSIX mode (the third parameter for `open(2)`).
        /// - Returns: A `NIOFileHandle.Mode` equivalent to the given POSIX flags and mode.
        public static func posix(flags: CInt, mode: NIOPOSIXFileMode) -> Flags {
            Flags(posixMode: mode, posixFlags: flags)
        }
    }

    /// Open a new `NIOFileHandle`. This operation is blocking.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open. The ownership of the file descriptor is transferred to this `NIOFileHandle` and so it will be closed once `close` is called.
    ///   - mode: Access mode. Default mode is `.read`.
    ///   - flags: Additional POSIX flags.
    @available(
        *,
        deprecated,
        message: """
            Avoid using NIOFileHandle. The type is difficult to hold correctly, \
            use NIOFileSystem as a replacement API.
            """
    )
    public convenience init(
        path: String,
        mode: Mode = .read,
        flags: Flags = .default
    ) throws {
        try self.init(_deprecatedPath: path, mode: mode, flags: flags)
    }

    /// Open a new `NIOFileHandle`. This operation is blocking.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open. The ownership of the file descriptor is transferred to this `NIOFileHandle` and so it will be closed once `close` is called.
    ///   - mode: Access mode. Default mode is `.read`.
    ///   - flags: Additional POSIX flags.
    @available(*, noasync, message: "This method may block the calling thread")
    public convenience init(
        _deprecatedPath path: String,
        mode: Mode = .read,
        flags: Flags = .default
    ) throws {
        #if os(Windows)
        let fl = mode.posixFlags | flags.posixFlags | _O_NOINHERIT
        #else
        let fl = mode.posixFlags | flags.posixFlags | O_CLOEXEC
        #endif
        let fd = try SystemCalls.open(file: path, oFlag: fl, mode: flags.posixMode)
        self.init(_deprecatedTakingOwnershipOfDescriptor: fd)
    }

    /// Open a new `NIOFileHandle`. This operation is blocking.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open. The ownership of the file descriptor is transferred to this `NIOFileHandle` and so it will be closed once `close` is called.
    @available(
        *,
        deprecated,
        message: """
            Avoid using NIOFileHandle. The type is difficult to hold correctly, \
            use NIOFileSystem as a replacement API.
            """
    )
    public convenience init(path: String) throws {
        try self.init(_deprecatedPath: path)
    }

    /// Open a new `NIOFileHandle`. This operation is blocking.
    ///
    /// - Parameters:
    ///   - path: The path of the file to open. The ownership of the file descriptor is transferred to this `NIOFileHandle` and so it will be closed once `close` is called.
    @available(*, noasync, message: "This method may block the calling thread")
    public convenience init(_deprecatedPath path: String) throws {
        // This function is here because we had a function like this in NIO 2.0, and the one above doesn't quite match. Sadly we can't
        // really deprecate this either, because it'll be preferred to the one above in many cases.
        try self.init(_deprecatedPath: path, mode: .read, flags: .default)
    }
}

extension NIOFileHandle: CustomStringConvertible {
    public var description: String {
        "FileHandle { descriptor: \(FileDescriptorState(rawValue: self.descriptor.load(ordering: .relaxed)).descriptor) }"
    }
}
