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

import Atomics
@_spi(Testing) import NIOFS
import XCTest

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class CancellationTests: XCTestCase {
    func testWithoutCancellation() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.cancelAll()

            group.addTask {
                XCTAssertTrue(Task.isCancelled)
                try await withoutCancellation {
                    XCTAssertFalse(Task.isCancelled)
                }
            }

            group.addTask {
                try await withoutCancellation {
                    try Task.checkCancellation()
                }
            }

            try await group.waitForAll()
        }
    }

    func testUncancellableTearDownWhenNotThrowing() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.cancelAll()

            group.addTask {
                let ranTearDown = ManagedAtomic(false)

                let isCancelled = try await withUncancellableTearDown {
                    Task.isCancelled
                } tearDown: { _ in
                    ranTearDown.store(true, ordering: .releasing)
                }

                XCTAssertTrue(isCancelled)

                let didRunTearDown = ranTearDown.load(ordering: .acquiring)
                XCTAssertTrue(didRunTearDown)
            }

            try await group.waitForAll()
        }
    }

    func testUncancellableTearDownWhenThrowing() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.cancelAll()

            group.addTask {
                let ranTearDown = ManagedAtomic(false)

                await XCTAssertThrowsErrorAsync {
                    try await withUncancellableTearDown {
                        try Task.checkCancellation()
                    } tearDown: { _ in
                        ranTearDown.store(true, ordering: .releasing)
                    }
                } onError: { error in
                    XCTAssert(error is CancellationError)
                }

                let didRunTearDown = ranTearDown.load(ordering: .acquiring)
                XCTAssertTrue(didRunTearDown)
            }

            try await group.waitForAll()
        }
    }
}
