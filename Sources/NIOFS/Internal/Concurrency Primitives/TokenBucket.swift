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

import DequeModule
import NIOConcurrencyHelpers

/// Type modeled after a "token bucket" pattern, which is similar to a semaphore, but is built with
/// Swift Concurrency primitives.
///
/// This is an adaptation of the TokenBucket found in Swift Package Manager.
/// Instead of using an ``actor``, we define a class and limit access through
/// ``NIOLock``.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class TokenBucket: @unchecked Sendable {
    private struct State {
        var tokens: Int
        var waiters: Deque<CheckedContinuation<Void, Never>>

        enum TakeTokenResult {
            /// A token is available to use.
            case tookToken
            /// No token is available, call back with a continuation.
            case tryAgainWithContinuation
            /// No token is available, the continuation will be resumed with one later.
            case storedContinuation
        }

        mutating func takeToken(continuation: CheckedContinuation<Void, Never>?) -> TakeTokenResult {
            if self.tokens > 0 {
                self.tokens &-= 1
                return .tookToken
            } else if let continuation = continuation {
                self.waiters.append(continuation)
                return .storedContinuation
            } else {
                return .tryAgainWithContinuation
            }
        }

        mutating func returnToken() -> CheckedContinuation<Void, Never>? {
            if let next = self.waiters.popFirst() {
                return next
            } else {
                self.tokens &+= 1
                return nil
            }
        }
    }

    private let lock: NIOLockedValueBox<State>

    init(tokens: Int) {
        precondition(tokens >= 1, "Need at least one token!")
        self.lock = NIOLockedValueBox(State(tokens: tokens, waiters: []))
    }

    /// Executes an `async` closure immediately when a token is available.
    /// Only the same number of closures will be executed concurrently as the number
    /// of `tokens` passed to ``TokenBucket/init(tokens:)``, all subsequent
    /// invocations of `withToken` will suspend until a "free" token is available.
    /// - Parameter body: The closure to invoke when a token is available.
    /// - Returns: Resulting value returned by `body`.
    func withToken<ReturnType>(
        _ body: @Sendable () async throws -> ReturnType
    ) async rethrows -> ReturnType {
        await self.getToken()
        defer { self.returnToken() }
        return try await body()
    }

    private func getToken() async {
        switch self.lock.withLockedValue({ $0.takeToken(continuation: nil) }) {
        case .tookToken:
            ()

        case .tryAgainWithContinuation:
            // Holding the lock here *should* be safe but because of a bug in the runtime
            // it isn't, so drop the lock, create the continuation and try again.
            //
            // See also: https://github.com/swiftlang/swift/issues/85668
            await withCheckedContinuation { continuation in
                switch self.lock.withLockedValue({ $0.takeToken(continuation: continuation) }) {
                case .tookToken:
                    continuation.resume()
                case .storedContinuation:
                    ()
                case .tryAgainWithContinuation:
                    // Only possible when 'takeToken(continuation:)' is called with no continuation.
                    fatalError()
                }
            }

        case .storedContinuation:
            // Only possible when 'takeToken(continuation:)' is called with a continuation.
            fatalError()
        }
    }

    private func returnToken() {
        let continuation = self.lock.withLockedValue { $0.returnToken() }
        continuation?.resume()
    }
}
