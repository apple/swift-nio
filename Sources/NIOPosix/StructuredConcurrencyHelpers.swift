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

//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2025 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
// swift-format-ignore
// Note: Whitespace changes are used to workaround compiler bug
// https://github.com/swiftlang/swift/issues/79285

#if compiler(>=6.0)
@inlinable
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
internal func asyncDo<R>(
    isolation: isolated (any Actor)? = #isolation,
    // DO NOT FIX THE WHITESPACE IN THE NEXT LINE UNTIL 5.10 IS UNSUPPORTED
    // https://github.com/swiftlang/swift/issues/79285
    _ body: () async throws -> sending R, finally: sending @escaping ((any Error)?) async throws -> Void) async throws -> sending R {
    let result: R
    do {
        result = try await body()
    } catch {
        // `body` failed, we need to invoke `finally` with the `error`.

        // This _looks_ unstructured but isn't really because we unconditionally always await the return.
        // We need to have an uncancelled task here to assure this is actually running in case we hit a
        // cancellation error.
        try await Task {
            try await finally(error)
        }.value
        throw error
    }

    // `body` succeeded, we need to invoke `finally` with `nil` (no error).

    // This _looks_ unstructured but isn't really because we unconditionally always await the return.
    // We need to have an uncancelled task here to assure this is actually running in case we hit a
    // cancellation error.
    try await Task {
        try await finally(nil)
    }.value
    return result
}
#else
@inlinable
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
internal func asyncDo<R: Sendable>(
    _ body: () async throws -> R,
    finally: @escaping @Sendable ((any Error)?) async throws -> Void
) async throws -> R {
    let result: R
    do {
        result = try await body()
    } catch {
        // `body` failed, we need to invoke `finally` with the `error`.

        // This _looks_ unstructured but isn't really because we unconditionally always await the return.
        // We need to have an uncancelled task here to assure this is actually running in case we hit a
        // cancellation error.
        try await Task {
            try await finally(error)
        }.value
        throw error
    }

    // `body` succeeded, we need to invoke `finally` with `nil` (no error).

    // This _looks_ unstructured but isn't really because we unconditionally always await the return.
    // We need to have an uncancelled task here to assure this is actually running in case we hit a
    // cancellation error.
    try await Task {
        try await finally(nil)
    }.value
    return result
}
#endif
