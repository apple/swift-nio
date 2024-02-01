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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux) || os(Android)
@_spi(Testing) import NIOFileSystem
import XCTest

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
internal final class IOExecutorTests: XCTestCase {
    func testExecuteAsync() async throws {
        try await withExecutor { executor in
            let n = try await executor.execute {
                return fibonacci(13)
            }
            XCTAssertEqual(n, 233)
        }
    }

    func testExecuteWithCallback() async throws {
        try await withExecutor { executor in
            await withCheckedContinuation { continuation in
                executor.execute {
                    fibonacci(13)
                } onCompletion: { result in
                    switch result {
                    case let .success(n):
                        XCTAssertEqual(n, 233)
                    case let .failure(error):
                        XCTFail("Unexpected error: \(error)")
                    }
                    continuation.resume()
                }
            }
        }
    }

    func testExecuteManyWorkItemsOn2Threads() async throws {
        // There are (slightly) different code paths depending on the number
        // of threads which determine which executor to pick so run this test
        // on 2 and 4 threads to exercise those paths.
        try await self.testExecuteManyWorkItems(threadCount: 2)
    }

    func testExecuteManyWorkItemsOn4Threads() async throws {
        // There are (slightly) different code paths depending on the number
        // of threads which determine which executor to pick so run this test
        // on 2 and 4 threads to exercise those paths.
        try await self.testExecuteManyWorkItems(threadCount: 4)
    }

    func testExecuteManyWorkItems(threadCount threads: Int) async throws {
        try await withExecutor(numberOfThreads: threads) { executor in
            try await withThrowingTaskGroup(of: Int.self) { group in
                let values = Array(0..<10_000)

                for value in values {
                    group.addTask {
                        try await executor.execute { return value }
                    }
                }

                // Wait for the values.
                let processed = try await group.reduce(into: [], { $0.append($1) })

                // They should be the same but may be in a different order.
                XCTAssertEqual(processed.sorted(), values)
            }
        }
    }

    func testExecuteCancellation() async throws {
        try await withExecutor { executor in
            await withThrowingTaskGroup(of: Void.self) { group in
                group.cancelAll()
                group.addTask {
                    try await executor.execute {
                        XCTFail("Should be cancelled before executed")
                    }
                }

                await XCTAssertThrowsErrorAsync {
                    try await group.waitForAll()
                } onError: { error in
                    XCTAssert(error is CancellationError)
                }
            }
        }
    }

    func testDrainWhenEmpty() async throws {
        let executor = await IOExecutor.running(numberOfThreads: 1)
        await executor.drain()
    }

    func testExecuteAfterDraining() async throws {
        let executor = await IOExecutor.running(numberOfThreads: 1)
        await executor.drain()

        // Callback should fire with an error.
        executor.execute {
            XCTFail("Work unexpectedly ran in drained pool.")
        } onCompletion: { result in
            switch result {
            case .success:
                XCTFail("Work unexpectedly ran in drained pool.")
            case let .failure(error):
                if let fsError = error as? FileSystemError {
                    XCTAssertEqual(fsError.code, .unavailable)
                } else {
                    XCTFail("Unexpected error: \(error)")
                }
            }
        }

        // Should throw immediately.
        await XCTAssertThrowsErrorAsync {
            try await executor.execute {
                XCTFail("Work unexpectedly ran in drained pool.")
            }
        } onError: { error in
            if let fsError = error as? FileSystemError {
                XCTAssertEqual(fsError.code, .unavailable)
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testWorkWhenStartingAsync() async throws {
        try await withThrowingTaskGroup(of: Int.self) { group in
            let executor = IOExecutor.runningAsync(numberOfThreads: 4)
            for _ in 0..<1000 {
                group.addTask {
                    try await executor.execute { fibonacci(8) }
                }
            }

            try await group.waitForAll()
            await executor.drain()
        }
    }
}

private func fibonacci(_ n: Int) -> Int {
    if n < 2 {
        return n
    } else {
        return fibonacci(n - 1) + fibonacci(n - 2)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private func withExecutor(
    numberOfThreads: Int = 1,
    execute: (IOExecutor) async throws -> Void
) async throws {
    let executor = await IOExecutor.running(numberOfThreads: numberOfThreads)
    do {
        try await execute(executor)
        await executor.drain()
    } catch {
        await executor.drain()
    }
}
#endif
