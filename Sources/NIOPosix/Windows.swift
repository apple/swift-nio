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
import NIOCore
import WinSDK
import CNIOWindows

typealias ssize_t = SSIZE_T

// overwrite the windows write method, as the one without underscore is deprecated.
// also we can use this to downcast the count Int to UInt32
func write(_ fd: Int32, _ ptr: UnsafeRawPointer?, _ count: Int) -> Int32 {
    _write(fd, ptr, UInt32(clamping: count))
}

var errno: Int32 {
    CNIOWindows_errno()
}

extension NIOCore.Windows {
    /// Call this to get a string representation from an error code that was returned from `GetLastError`.
    static func makeErrorMessageFromCode(_ errorCode: DWORD) -> String? {
        var errorMsg = UnsafeMutablePointer<CHAR>?.none
        CNIOWindows_FormatGetLastError(errorCode, &errorMsg)

        if let errorMsg {
            let result = String(cString: errorMsg)
            LocalFree(errorMsg)
            return result
        } else {
            // we could check GetLastError here again. But that feels quite recursive.
            return nil
        }
    }
}

#endif
