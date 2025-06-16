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
    func testMetricsDelegateNotCalledWhenNoEvents() {
        let delegate = RecorderDelegate()
        _ = MultiThreadedEventLoopGroup(numberOfThreads: 1, metricsDelegate: delegate)
        XCTAssertEqual(delegate.infos.count, 0)
    }

    func testMetricsDelegateTickInfo() {
        let delegate = RecorderDelegate()
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1, metricsDelegate: delegate)
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
            // There are 4 tasks (scheduleTask, scheduleTask, whenSuccess, wait) which can trigger a total of 2...4 ticks
            XCTAssertTrue((2...4).contains(delegate.infos.count), "Expected 2...4 ticks, got \(delegate.infos.count)")
            // The total number of tasks across these ticks should be either 3 or 4
            let totalTasks = delegate.infos.map { $0.numberOfTasks }.reduce(0, { $0 + $1 })
            XCTAssertTrue((3...4).contains(totalTasks), "Expected 3...4 tasks, got \(totalTasks)")
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
