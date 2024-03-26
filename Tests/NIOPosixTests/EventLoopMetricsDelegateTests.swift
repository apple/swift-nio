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
        el.scheduleTask(in: .seconds(1)){
            promise.succeed()
        }
        promise.futureResult.whenSuccess {
            XCTAssertEqual(delegate.infos.count, 1)
            // 2 tasks: one is the scheduleTask call and one is the whenSuccess call
            XCTAssertEqual(delegate.infos.first?.numberOfTasks, 2)
            XCTAssertEqual(delegate.infos.first?.eventLoopID, ObjectIdentifier(el))
            if let tickStartTime = delegate.infos.first?.startTime {
                let timeSinceStart = tickStartTime - testStartTime
                XCTAssertLessThan(timeSinceStart.nanoseconds, 100_000_000) // This should be near instant, limiting to 100ms
                XCTAssertGreaterThan(timeSinceStart.nanoseconds, 0)
            }
        }
        try? promise.futureResult.wait()
    }
}
