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

@testable import NIOPosix
import NIOCore
import NIOConcurrencyHelpers
import XCTest

final class RecorderDelegate: NIOEventLoopMetricsDelegate, Sendable {

    private let _infos: NIOLockedValueBox<[NIOEventLoopTickInfo]> = .init([])

    var infos: [NIOEventLoopTickInfo] {
        _infos.withLockedValue {$0 }
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
        el.scheduleTask(in: .seconds(1)) {
            promise.succeed()
        }
        promise.futureResult.whenSuccess {
            // There are 3 tasks (scheduleTask, whenSuccess, wait) which can trigger a total of 1...3 ticks
            XCTAssertTrue((1...3).contains(delegate.infos.count), "Expected 1...3 ticks, got \(delegate.infos.count)")
            // the total number of tasks across these ticks should be either 2 or 3
            let totalTasks = delegate.infos.map { $0.numberOfTasks }.reduce(0, { $0 + $1 })
            XCTAssertTrue((2...3).contains(totalTasks), "Expected 2...3 tasks, got \(totalTasks)")
            for info in delegate.infos {
                XCTAssertEqual(info.eventLoopID, ObjectIdentifier(el))
            }
            if let lastTickStartTime = delegate.infos.last?.startTime {
                let timeSinceStart = lastTickStartTime - testStartTime
                XCTAssertLessThan(timeSinceStart.nanoseconds, 100_000_000) // This should be near instant, limiting to 100ms
                XCTAssertGreaterThan(timeSinceStart.nanoseconds, 0)
            }
        }
        try? promise.futureResult.wait()
    }
}
