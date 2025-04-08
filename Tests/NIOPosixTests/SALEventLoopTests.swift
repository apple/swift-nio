//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import XCTest

final class SALEventLoopTests: XCTestCase {
    func testSchedulingTaskOnSleepingLoopWakesUpOnce() throws {
        try withSALContext { context in
            try context.runSALOnEventLoopAndWait { thisLoop, _, _ in
                // We're going to execute some tasks on the loop. This will force a single wakeup, as the first task will wedge the loop open.
                // However, we're currently _on_ the loop so the first thing we have to do is give it up.
                let promise = thisLoop.makePromise(of: Void.self)

                DispatchQueue(label: "background").asyncAfter(deadline: .now() + .milliseconds(100)) {
                    let semaphore = DispatchSemaphore(value: 0)

                    thisLoop.execute {
                        // Wedge the loop open. This will also _wake_ the loop.
                        XCTAssertEqual(semaphore.wait(timeout: .now() + .milliseconds(500)), .success)
                    }

                    // Now execute 10 tasks.
                    for _ in 0..<10 {
                        thisLoop.execute {}
                    }

                    // Now enqueue a "last" task.
                    thisLoop.execute {
                        promise.succeed(())
                    }

                    // Now we can unblock the semaphore.
                    semaphore.signal()
                }

                return promise.futureResult
            } syscallAssertions: { assertions in
                try assertions.assertParkedRightNow()
                try assertions.assertWakeup()

                // We actually need to wait for the inner code to exit, as the optimisation we're testing here will remove a signal that the
                // SAL is actually going to wait for in salWait().
                try assertions.assertParkedRightNow()
            }
        }
    }
}
