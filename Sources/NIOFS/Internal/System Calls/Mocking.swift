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

// This source file is part of the Swift System open source project//
// Copyright (c) 2020 Apple Inc. and the Swift System project authors
// Licensed under Apache License v2.0 with Runtime Library Exception//
// See https://swift.org/LICENSE.txt for license information

import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
@preconcurrency import Glibc
import CNIOLinux
#elseif canImport(Musl)
@preconcurrency import Musl
import CNIOLinux
#elseif canImport(Android)
@preconcurrency import Android
import CNIOLinux
#endif

// Syscall mocking support.
//
// NOTE: This is currently the bare minimum needed for System's testing purposes, though we do
// eventually want to expose some solution to users.
//
// Mocking is contextual, accessible through MockingDriver.withMockingEnabled. Mocking
// state, including whether it is enabled, is stored in thread-local storage. Mocking is only
// enabled in testing builds of System currently, to minimize runtime overhead of release builds.
//

#if ENABLE_MOCKING
@_spi(Testing)
public struct Trace {
    @_spi(Testing)
    public struct Entry {
        @_spi(Testing)
        public var name: String
        @_spi(Testing)
        public var arguments: [AnyHashable]

        @_spi(Testing)
        public init(name: String, _ arguments: [AnyHashable]) {
            self.name = name
            self.arguments = arguments
        }
    }

    private var entries: [Entry] = []
    private var firstEntry: Int = 0

    @_spi(Testing)
    public var isEmpty: Bool { firstEntry >= entries.count }

    @_spi(Testing)
    public mutating func dequeue() -> Entry? {
        guard !self.isEmpty else { return nil }
        defer { firstEntry += 1 }
        return entries[firstEntry]
    }

    fileprivate mutating func add(_ e: Entry) {
        entries.append(e)
    }
}

@available(*, unavailable)
extension Trace: Sendable {}

@available(*, unavailable)
extension Trace.Entry: Sendable {}

@_spi(Testing)
public enum ForceErrno: Equatable, Sendable {
    case none
    case always(errno: CInt)

    case counted(errno: CInt, count: Int)
}

// Provide access to the driver, context, and trace stack of mocking
@_spi(Testing)
public final class MockingDriver {
    // Record syscalls and their arguments
    @_spi(Testing)
    public var trace = Trace()

    // Mock errors inside syscalls
    @_spi(Testing)
    public var forceErrno = ForceErrno.none

    // Whether we should pretend to be Windows for syntactic operations
    // inside FilePath
    fileprivate var forceWindowsSyntaxForPaths = false
}

@available(*, unavailable)
extension MockingDriver: Sendable {}

private let driverKey: _PlatformTLSKey = { makeTLSKey() }()

internal var currentMockingDriver: MockingDriver? {
    #if !ENABLE_MOCKING
    fatalError("Contextual mocking in non-mocking build")
    #endif
    guard let rawPtr = getTLS(driverKey) else { return nil }

    return Unmanaged<MockingDriver>.fromOpaque(rawPtr).takeUnretainedValue()
}

extension MockingDriver {
    /// Enables mocking for the duration of `f` with a clean trace queue
    /// Restores prior mocking status and trace queue after execution
    @_spi(Testing)
    public static func withMockingEnabled(
        _ f: (MockingDriver) throws -> Void
    ) rethrows {
        let priorMocking = currentMockingDriver
        let driver = MockingDriver()

        defer {
            if let object = priorMocking {
                setTLS(driverKey, Unmanaged.passUnretained(object).toOpaque())
            } else {
                setTLS(driverKey, nil)
            }
            _fixLifetime(driver)
        }

        setTLS(driverKey, Unmanaged.passUnretained(driver).toOpaque())
        return try f(driver)
    }
}

// Check TLS for mocking
@inline(never)
private var contextualMockingEnabled: Bool {
    currentMockingDriver != nil
}

extension MockingDriver {
    @_spi(Testing)
    public static var enabled: Bool { mockingEnabled }

    @_spi(Testing)
    public static var forceWindowsPaths: Bool {
        currentMockingDriver?.forceWindowsSyntaxForPaths ?? false
    }
}

#endif  // ENABLE_MOCKING

@inline(__always)
internal var mockingEnabled: Bool {
    // Fast constant-foldable check for release builds
    #if ENABLE_MOCKING
    return contextualMockingEnabled
    #else
    return false
    #endif
}

@inline(__always)
internal var forceWindowsPaths: Bool {
    #if !ENABLE_MOCKING
    return false
    #else
    return MockingDriver.forceWindowsPaths
    #endif
}

#if ENABLE_MOCKING
// Strip the mock_system prefix and the arg list suffix
private func originalSyscallName(_ function: String) -> String {
    // `function` must be of format `system_<name>(<parameters>)`
    for `prefix` in ["system_", "libc_"] {
        if function.starts(with: `prefix`) {
            return String(function.dropFirst(`prefix`.count).prefix { $0 != "(" })
        }
    }
    preconditionFailure("\(function) must start with 'system_' or 'libc_'")
}

private func mockImpl(syscall name: String, args: [AnyHashable]) -> CInt {
    precondition(mockingEnabled)
    let origName = originalSyscallName(name)
    guard let driver = currentMockingDriver else {
        fatalError("Mocking requested from non-mocking context")
    }

    driver.trace.add(Trace.Entry(name: origName, args))

    switch driver.forceErrno {
    case .none: break
    case .always(let e):
        system_errno = e
        return -1
    case .counted(let e, let count):
        assert(count >= 1)
        system_errno = e
        driver.forceErrno = count > 1 ? .counted(errno: e, count: count - 1) : .none
        return -1
    }

    return 0
}

private func reinterpret(_ args: [AnyHashable?]) -> [AnyHashable] {
    args.map { arg in
        switch arg {
        case let charPointer as UnsafePointer<CInterop.PlatformChar>:
            return String(_errorCorrectingPlatformString: charPointer)
        case is UnsafeMutablePointer<CInterop.PlatformChar>:
            return "<buffer>"
        case is UnsafeMutableRawPointer:
            return "<buffer>"
        case is UnsafeRawPointer:
            return "<buffer>"
        case .none:
            return "nil"
        case let .some(arg):
            return arg
        }
    }
}

func mock(
    syscall name: String = #function,
    _ args: AnyHashable?...
) -> CInt {
    mockImpl(syscall: name, args: reinterpret(args))
}

func mockInt(
    syscall name: String = #function,
    _ args: AnyHashable?...
) -> Int {
    Int(mockImpl(syscall: name, args: reinterpret(args)))
}

#endif  // ENABLE_MOCKING

// Force paths to be treated as Windows syntactically if `enabled` is
// true.
@_spi(Testing)
public func _withWindowsPaths(enabled: Bool, _ body: () -> Void) {
    #if ENABLE_MOCKING
    guard enabled else {
        body()
        return
    }
    MockingDriver.withMockingEnabled { driver in
        driver.forceWindowsSyntaxForPaths = true
        body()
    }
    #else
    body()
    #endif
}

// Internal wrappers and typedefs which help reduce #if littering in System's
// code base.

// TODO: Should CSystem just include all the header files we need?

internal typealias _COffT = off_t

// MARK: syscalls and variables

#if canImport(Darwin)
internal var system_errno: CInt {
    get { Darwin.errno }
    set { Darwin.errno = newValue }
}
#elseif canImport(Glibc)
internal var system_errno: CInt {
    get { Glibc.errno }
    set { Glibc.errno = newValue }
}
#elseif canImport(Musl)
internal var system_errno: CInt {
    get { Musl.errno }
    set { Musl.errno = newValue }
}
#elseif canImport(Android)
internal var system_errno: CInt {
    get { Android.errno }
    set { Android.errno = newValue }
}
#endif

// MARK: C stdlib decls

// Convention: `system_foo` is system's wrapper for `foo`.

internal func system_strerror(_ __errnum: Int32) -> UnsafeMutablePointer<Int8>! {
    strerror(__errnum)
}

internal func system_strlen(_ s: UnsafePointer<CChar>) -> Int {
    strlen(s)
}
internal func system_strlen(_ s: UnsafeMutablePointer<CChar>) -> Int {
    strlen(s)
}

// Convention: `system_platform_foo` is a
// platform-representation-abstracted wrapper around `foo`-like functionality.
// Type and layout differences such as the `char` vs `wchar` are abstracted.
//

// strlen for the platform string
internal func system_platform_strlen(_ s: UnsafePointer<CInterop.PlatformChar>) -> Int {
    strlen(s)
}

// memset for raw buffers
// FIXME: Do we really not have something like this in the stdlib already?
internal func system_memset(
    _ buffer: UnsafeMutableRawBufferPointer,
    to byte: UInt8
) {
    guard buffer.count > 0 else { return }
    memset(buffer.baseAddress!, CInt(byte), buffer.count)
}

// Interop between String and platfrom string
extension String {
    internal func _withPlatformString<Result>(
        _ body: (UnsafePointer<CInterop.PlatformChar>) throws -> Result
    ) rethrows -> Result {
        // Need to #if because CChar may be signed
        try withCString(body)
    }

    internal init(
        _errorCorrectingPlatformString platformString: UnsafePointer<CInterop.PlatformChar>
    ) {
        // Need to #if because CChar may be signed
        self.init(cString: platformString)
    }
}

internal typealias _PlatformTLSKey = pthread_key_t

internal func makeTLSKey() -> _PlatformTLSKey {
    var raw = pthread_key_t()
    guard 0 == pthread_key_create(&raw, nil) else {
        fatalError("Unable to create key")
    }
    return raw
}

internal func setTLS(_ key: _PlatformTLSKey, _ p: UnsafeMutableRawPointer?) {
    guard 0 == pthread_setspecific(key, p) else {
        fatalError("Unable to set TLS")
    }
}

internal func getTLS(_ key: _PlatformTLSKey) -> UnsafeMutableRawPointer? {
    pthread_getspecific(key)
}
