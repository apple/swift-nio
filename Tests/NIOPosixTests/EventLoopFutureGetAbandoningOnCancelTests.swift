//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOPosix
import Testing

private struct DummyError: Error {}

@Suite("EventLoopFuture.getAbandoningOnCancel()")
struct EventLoopFutureGetAbandoningOnCancelTests {
    private let loop = MultiThreadedEventLoopGroup.singleton.next()

    @Test
    func returnsValueOfAlreadySucceededFuture() async throws {
        let value = try await self.loop.makeSucceededFuture(42).getAbandoningOnCancel()
        #expect(value == 42)
    }

    @Test
    func returnsValueOfFutureThatSucceedsLater() async throws {
        let promise = self.loop.makePromise(of: Int.self)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let value = try await promise.futureResult.getAbandoningOnCancel()
                #expect(value == 42)
            }
            promise.succeed(42)
            try await group.waitForAll()
        }
    }

    @Test
    func throwsErrorOfFailedFuture() async throws {
        let future: EventLoopFuture<Int> = self.loop.makeFailedFuture(DummyError())
        await #expect(throws: DummyError.self) {
            try await future.getAbandoningOnCancel()
        }
    }

    @Test
    func throwsCancellationErrorAndAbandonsTheFutureOnCancellation() async throws {
        let promise = self.loop.makePromise(of: Int.self)
        let awaitingPromise = self.loop.makePromise(of: Void.self)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                awaitingPromise.succeed(())
                await #expect(throws: CancellationError.self) {
                    try await promise.futureResult.getAbandoningOnCancel()
                }
            }

            // Give the child task a chance to actually suspend on the future before we cancel it. Both orderings
            // (cancellation before and after the suspension) must throw `CancellationError` though.
            try? await awaitingPromise.futureResult.get()
            try? await self.loop.submit {}.get()

            group.cancelAll()
        }

        // Cancellation only abandoned the future, it didn't complete it: The underlying operation is still ongoing and
        // completing it later works just as before.
        promise.succeed(42)
        let value = try await promise.futureResult.get()
        #expect(value == 42)
    }

    @Test
    func throwsCancellationErrorIfTheTaskIsAlreadyCancelled() async throws {
        let promise = self.loop.makePromise(of: Int.self)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    await Task.yield()
                }
                await #expect(throws: CancellationError.self) {
                    try await promise.futureResult.getAbandoningOnCancel()
                }
            }
            group.cancelAll()
        }

        // The future itself is untouched, so we still need to complete it (or we'd leak an unfulfilled promise).
        promise.succeed(42)
        let value = try await promise.futureResult.get()
        #expect(value == 42)
    }

    @Test
    func survivesCancellationRacingTheFuturesCompletion() async throws {
        for _ in 0..<100 {
            let promise = self.loop.makePromise(of: Int.self)

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        let value = try await promise.futureResult.getAbandoningOnCancel()
                        #expect(value == 42)
                    } catch is CancellationError {
                        // Also acceptable: cancellation won the race.
                    } catch {
                        Issue.record("unexpected error: \(error)")
                    }
                }

                promise.succeed(42)
                group.cancelAll()
            }
        }
    }
}
