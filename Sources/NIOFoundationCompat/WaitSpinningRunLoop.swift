//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if !os(WASI)

import Atomics
import Foundation
import NIOConcurrencyHelpers
import NIOCore

extension EventLoopFuture {
    /// Wait for the resolution of this `EventLoopFuture` by spinning `RunLoop.current` in `mode` until the future
    /// resolves. The calling thread will be blocked albeit running `RunLoop.current`.
    ///
    /// If the `EventLoopFuture` resolves with a value, that value is returned from `waitSpinningRunLoop()`. If
    /// the `EventLoopFuture` resolves with an error, that error will be thrown instead.
    /// `waitSpinningRunLoop()` will block whatever thread it is called on, so it must not be called on event loop
    /// threads: it is primarily useful for testing, or for building interfaces between blocking
    /// and non-blocking code.
    ///
    /// This is also forbidden in async contexts: prefer `EventLoopFuture/get()`.
    ///
    /// - Note: The `Value` must be `Sendable` since it is shared outside of the isolation domain of the event loop.
    ///
    /// - Returns: The value of the `EventLoopFuture` when it completes.
    /// - Throws: The error value of the `EventLoopFuture` if it errors.
    @available(*, noasync, message: "waitSpinningRunLoop() can block indefinitely, prefer get()", renamed: "get()")
    @inlinable
    public func waitSpinningRunLoop(
        inMode mode: RunLoop.Mode = .default,
        file: StaticString = #file,
        line: UInt = #line
    ) throws -> Value where Value: Sendable {
        try self._blockingWaitForFutureCompletion(mode: mode, file: file, line: line)
    }

    @inlinable
    @inline(never)
    func _blockingWaitForFutureCompletion(
        mode: RunLoop.Mode,
        file: StaticString,
        line: UInt
    ) throws -> Value where Value: Sendable {
        self.eventLoop._preconditionSafeToWait(file: file, line: line)

        let runLoop = RunLoop.current

        let value: NIOLockedValueBox<Result<Value, any Error>?> = NIOLockedValueBox(nil)
        self.whenComplete { result in
            value.withLockedValue { value in
                value = result
            }
        }

        while value.withLockedValue({ $0 }) == nil {
            _ = runLoop.run(mode: mode, before: Date().addingTimeInterval(0.01))
        }

        return try value.withLockedValue { value in
            try value!.get()
        }
    }
}

#endif  // !os(WASI)
