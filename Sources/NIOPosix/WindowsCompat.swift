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

#if os(Windows)
import WinSDK
import ucrt

/// SwiftNIO leans on a number of small POSIX conveniences that are absent from
/// the Windows CRT surface area.  The declarations in this file bridge a subset
/// of those APIs to unblock the Windows build without forcing every call site to
/// grow additional platform checks.

/// Standard POSIX-style file descriptor numbers used by example code and tests.
public let STDIN_FILENO: CInt = 0
public let STDOUT_FILENO: CInt = 1
public let STDERR_FILENO: CInt = 2

/// Windows-compatible implementation of `setenv(3)` that mirrors the common
/// POSIX semantics used within SwiftNIO.  Internally this delegates to
/// `_putenv_s`, applying the documented overwrite behaviour and translating the
/// CRT error codes back into `errno` so the return value matches the POSIX
/// contract (0 on success, -1 on failure).
@discardableResult
public func setenv(_ name: String, _ value: String, _ overwrite: Int32) -> Int32 {
    if overwrite == 0 {
        var duplicated: UnsafeMutablePointer<CChar>?
        var size: size_t = 0
        let dupResult = _dupenv_s(&duplicated, &size, name)
        defer { free(duplicated) }

        if dupResult != 0 {
            _set_errno(dupResult)
            return -1
        }

        if duplicated != nil {
            // Variable already exists and we were asked not to overwrite it.
            return 0
        }
    }

    let putResult = _putenv_s(name, value)
    if putResult == 0 {
        return 0
    }

    _set_errno(putResult)
    return -1
}

/// Windows-compatible implementation of `unsetenv(3)` expressed in terms of the
/// CRT's `_putenv_s`.  Setting the variable to an empty string removes it from
/// the environment block.  We surface errors via `errno` to preserve the POSIX
/// contract.
@discardableResult
public func unsetenv(_ name: String) -> Int32 {
    let result = _putenv_s(name, "")
    if result == 0 {
        return 0
    }

    _set_errno(result)
    return -1
}

#endif
