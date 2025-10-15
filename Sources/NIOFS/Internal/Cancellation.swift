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

/// Executes the closure and masks cancellation.
@_spi(Testing)
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public func withoutCancellation<R: Sendable>(
    _ execute: @escaping () async throws -> R
) async throws -> R {
    // Okay as we immediately wait for the result of the task.
    let unsafeExecute = UnsafeTransfer(execute)
    let t = Task {
        try await unsafeExecute.wrappedValue()
    }
    return try await t.value
}

/// Executes `fn` and then `tearDown`, which cannot be cancelled.
@_spi(Testing)
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public func withUncancellableTearDown<R>(
    _ fn: () async throws -> R,
    tearDown: @escaping (Result<Void, Error>) async throws -> Void
) async throws -> R {
    let result: Result<R, Error>
    do {
        result = .success(try await fn())
    } catch {
        result = .failure(error)
    }

    let errorOnlyResult: Result<Void, Error> = result.map { _ in () }
    let tearDownResult: Result<Void, Error> = try await withoutCancellation {
        do {
            return .success(try await tearDown(errorOnlyResult))
        } catch {
            return .failure(error)
        }
    }

    try tearDownResult.get()
    return try result.get()
}
