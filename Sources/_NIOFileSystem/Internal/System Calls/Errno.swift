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

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Android)
@preconcurrency import Android
#endif

extension Errno {
    @_spi(Testing)
    public static var _current: Errno {
        get {
            #if canImport(Darwin)
            return Errno(rawValue: Darwin.errno)
            #elseif canImport(Glibc)
            return Errno(rawValue: Glibc.errno)
            #elseif canImport(Musl)
            return Errno(rawValue: Musl.errno)
            #elseif canImport(Android)
            return Errno(rawValue: Android.errno)
            #endif
        }
        set {
            #if canImport(Darwin)
            Darwin.errno = newValue.rawValue
            #elseif canImport(Glibc)
            Glibc.errno = newValue.rawValue
            #elseif canImport(Musl)
            Musl.errno = newValue.rawValue
            #elseif canImport(Android)
            Android.errno = newValue.rawValue
            #endif
        }
    }

    fileprivate static func clear() {
        #if canImport(Darwin)
        Darwin.errno = 0
        #elseif canImport(Glibc)
        Glibc.errno = 0
        #elseif canImport(Musl)
        Musl.errno = 0
        #elseif canImport(Android)
        Android.errno = 0
        #endif
    }
}

/// Returns a `Result` representing the value returned from the given closure
/// or an `Errno` if that value was -1.
///
/// If desired this function can call the closure in a loop until it does not
/// result in `Errno` being `.interrupted`.
@_spi(Testing)
public func valueOrErrno<I: FixedWidthInteger>(
    retryOnInterrupt: Bool = true,
    _ fn: () -> I
) -> Result<I, Errno> {
    while true {
        Errno.clear()
        let result = fn()
        if result == -1 {
            let errno = Errno._current
            if errno == .interrupted, retryOnInterrupt {
                continue
            } else {
                return .failure(errno)
            }
        } else {
            return .success(result)
        }
    }
}

/// As `valueOrErrno` but discards the success value.
@_spi(Testing)
public func nothingOrErrno<I: FixedWidthInteger>(
    retryOnInterrupt: Bool = true,
    _ fn: () -> I
) -> Result<Void, Errno> {
    valueOrErrno(retryOnInterrupt: retryOnInterrupt, fn).map { _ in }
}

/// Returns a `Result` representing the value returned from the given closure
/// or an `Errno` if that value was `nil`.
///
/// If desired this function can call the closure in a loop until it does not
/// result in `Errno` being `.interrupted`. `Errno` is only checked if the
/// closure returns `nil`.
@_spi(Testing)
public func optionalValueOrErrno<R>(
    retryOnInterrupt: Bool = true,
    _ fn: () -> R?
) -> Result<R?, Errno> {
    while true {
        Errno.clear()
        if let result = fn() {
            return .success(result)
        } else {
            let errno = Errno._current
            if errno == .interrupted, retryOnInterrupt {
                continue
            } else if errno.rawValue == 0 {
                return .success(nil)
            } else {
                return .failure(errno)
            }
        }
    }
}

/// As `valueOrErrno` but unconditionally checks the current `Errno`.
@_spi(Testing)
public func valueOrErrno<R>(
    retryOnInterrupt: Bool = true,
    _ fn: () -> R
) -> Result<R, Errno> {
    while true {
        Errno.clear()
        let value = fn()
        let errno = Errno._current
        if errno.rawValue == 0 {
            return .success(value)
        } else if errno == .interrupted, retryOnInterrupt {
            continue
        } else {
            return .failure(errno)
        }
    }
}
