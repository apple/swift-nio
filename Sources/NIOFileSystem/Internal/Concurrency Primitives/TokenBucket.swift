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
//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

/// Type modeled after a "token bucket" pattern, which is similar to a semaphore, but is built with
/// Swift Concurrency primitives.
///
/// This is an adaptation of the TokenBucket found in Swift Package Manager.
/// Instead of using an ``actor``, we define a class and limit access through
/// ``NIOLock``.

import DequeModule
import NIOConcurrencyHelpers

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
class TokenBucket {
    var tokens: Int
    var waiters: Deque<CheckedContinuation<Void, Never>>
    let lock: NIOLock

    public init(tokens: Int) {
        self.tokens = tokens
        self.waiters = Deque()
        self.lock = NIOLock()
    }

    /// Executes an `async` closure immediately when a token is available.
    /// Only the same number of closures will be executed concurrently as the number
    /// of `tokens` passed to ``TokenBucket/init(tokens:)``, all subsequent
    /// invocations of `withToken` will suspend until a "free" token is available.
    /// - Parameter body: The closure to invoke when a token is available.
    /// - Returns: Resulting value returned by `body`.
    public func withToken<ReturnType>(
        _ body: @Sendable () async throws -> ReturnType
    ) async rethrows -> ReturnType {
        await self.getToken()
        defer { self.returnToken() }
        return try await body()
    }

    func getToken() async {
        self.lock.lock()
        if self.tokens > 0 {
            self.tokens -= 1
            self.lock.unlock()
            return
        }
        self.lock.unlock()

        await withCheckedContinuation {
            self.lock.lock()
            self.waiters.append($0)
            self.lock.unlock()
        }
    }

    func returnToken() {
        self.lock.lock()
        defer { self.lock.unlock() }

        if let nextWaiter = self.waiters.popFirst() {
            nextWaiter.resume()
        } else {
            self.tokens += 1
        }
    }
}
