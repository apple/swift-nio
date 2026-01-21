//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers
import NIOCore
import XCTest

@testable import NIOPosix

final class RecorderDelegate: NIOEventLoopMetricsDelegate, Sendable {

    private let _infos: NIOLockedValueBox<[NIOEventLoopTickInfo]> = .init([])

    var infos: [NIOEventLoopTickInfo] {
        _infos.withLockedValue { $0 }
    }

    func processedTick(info: NIOPosix.NIOEventLoopTickInfo) {
        _infos.withLockedValue {
            $0.append(info)
        }
    }
}

final class EventLoopMetricsDelegateTests: XCTestCase {
    func testMetricsDelegateNotCalledWhenNoEvents() throws {
        let delegate = RecorderDelegate()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1, metricsDelegate: delegate)
        XCTAssertEqual(delegate.infos.count, 0)
        try group.syncShutdownGracefully()
    }

    func testMetricsDelegateTickInfo() {
        let delegate = RecorderDelegate()
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1, metricsDelegate: delegate)
        defer {
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }
        let el = elg.any()
        let testStartTime = NIODeadline.now()

        XCTAssertEqual(delegate.infos.count, 0)

        let promise = el.makePromise(of: Void.self)
        el.scheduleTask(in: .milliseconds(100)) {
            // Nop. Ensures that we collect multiple tick infos.
        }
        el.scheduleTask(in: .seconds(1)) {
            promise.succeed()
        }

        promise.futureResult.whenSuccess {
            // There are 4 tasks here:
            // 1. scheduleTask in 100ms,
            // 2. scheduleTask in 1s,
            // 3. whenSuccess (this callback),
            // 4. wait() (which is secrectly a whenComplete)
            //
            // These can run in 2...6 event loop ticks. The worst case happens when:
            // 1. The selector blocks after the EL is created and is woken by the 100ms task being
            //    scheduled. The EL wakes up but has no tasks to run so goes blocks until no later
            //    than the 100ms task needs running.
            // 2. The 1s task is scheduled which causes the selector to wakeup again but it has
            //    nothing to do. It goes back to sleep blocking until the 100ms task is run.
            // 3. whenSuccess is called which wakes the selector as whenSuccess executes onto
            //    the EL to enqueue the task. The selector goes back to sleep waiting for the
            //    100ms task.
            // 4. wait() is called which under the hood does a whenComplete which can then wake the
            //    as per (3). The selector goes back to sleep waiting for the 100ms task.
            // 5. The EL wakes up and runs the 100ms task. It goes back to sleep waiting for the
            //    1s task.
            // 6. The 1s task is run which succeeds the promise and runs both this whenSuccess
            //    callback and the whenComplete in the wait().
            //
            // Why a maximum of five? I literally just listed six times the loop can tick. This
            // task (whenSuccess) is running as part of the last tick, and so the info hasn't
            // been published to the delegate yet.
            XCTAssertTrue((2...5).contains(delegate.infos.count), "Expected 2...5 ticks, got \(delegate.infos.count)")

            // The total number of tasks across these ticks should be 3. Not four, because this
            // task is the fourth and it hasn't finished running yet.
            let totalTasks = delegate.infos.map { $0.numberOfTasks }.reduce(0, +)
            XCTAssertEqual(totalTasks, 3, "Expected 3 tasks, got \(totalTasks)")
            // All tasks were run by the same event loop. The measurements are monotonically increasing.
            var lastEndTime: NIODeadline?
            for info in delegate.infos {
                XCTAssertEqual(info.eventLoopID, ObjectIdentifier(el))
                XCTAssertTrue(info.startTime < info.endTime)
                // If this is not the first tick, verify the sleep time.
                if let lastEndTime {
                    XCTAssertTrue(lastEndTime < info.startTime)
                    XCTAssertEqual(lastEndTime + info.sleepTime, info.startTime)
                }
                // Keep track of the last event time to verify the sleep interval.
                lastEndTime = info.endTime
            }
            if let lastTickStartTime = delegate.infos.last?.startTime {
                let timeSinceStart = lastTickStartTime - testStartTime
                // This should be near instantly after the delay of the first run.
                XCTAssertLessThan(timeSinceStart.nanoseconds, 200_000_000)
                XCTAssertGreaterThan(timeSinceStart.nanoseconds, 0)
            }
        }
        try? promise.futureResult.wait()
    }
}
