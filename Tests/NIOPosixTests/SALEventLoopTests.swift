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

import XCTest
import NIOCore
@testable import NIOPosix
import NIOConcurrencyHelpers
import Dispatch

final class SALEventLoopTests: XCTestCase, SALTest {
    var group: MultiThreadedEventLoopGroup!
    var kernelToUserBox: LockedBox<KernelToUser>!
    var userToKernelBox: LockedBox<UserToKernel>!
    var wakeups: LockedBox<()>!

    override func setUp() {
        self.setUpSAL()
    }

    override func tearDown() {
        self.tearDownSAL()
    }

    func testSchedulingTaskOnSleepingLoopWakesUpOnce() throws {
        let thisLoop = self.group.next()

        try thisLoop.runSAL(syscallAssertions: {
            try self.assertParkedRightNow()

            try self.assertWakeup()

            // We actually need to wait for the inner code to exit, as the optimisation we're testing here will remove a signal that the
            // SAL is actually going to wait for in salWait().
            try self.assertParkedRightNow()
        }) { () -> EventLoopFuture<Void> in
            // We're going to execute some tasks on the loop. This will force a single wakeup, as the first task will wedge the loop open.
            // However, we're currently _on_ the loop so the first thing we have to do is give it up.
            let promise = thisLoop.makePromise(of: Void.self)

            DispatchQueue(label: "background").asyncAfter(deadline: .now() + .milliseconds(100)) {
                let semaphore = DispatchSemaphore(value: 0)

                thisLoop.execute {
                    // Wedge the loop open. This will also _wake_ the loop.
                    XCTAssertEqual(semaphore.wait(timeout: .now() + .milliseconds(500)), .success)
                    print("Unblocking wedged task")
                }

                // Now execute 10 tasks.
                var i = 0
                for _ in 0..<10 {
                    thisLoop.execute {
                        i &+= 1
                    }
                }

                // Now enqueue a "last" task.
                thisLoop.execute {
                    i &+= 1
                    promise.succeed(())
                }

                // Now we can unblock the semaphore.
                semaphore.signal()
            }
            
            return promise.futureResult
        }.salWait()
    }
}
