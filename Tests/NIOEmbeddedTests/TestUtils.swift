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
import Atomics
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import XCTest

#if canImport(Android)
import Android
#endif

// FIXME: Duplicated with NIO
func assert(
    _ condition: @autoclosure () -> Bool,
    within time: TimeAmount,
    testInterval: TimeAmount? = nil,
    _ message: String = "condition not satisfied in time",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let testInterval = testInterval ?? TimeAmount.nanoseconds(time.nanoseconds / 5)
    let endTime = NIODeadline.now() + time

    repeat {
        if condition() { return }
        usleep(UInt32(testInterval.nanoseconds / 1000))
    } while NIODeadline.now() < endTime

    if !condition() {
        XCTFail(message, file: (file), line: line)
    }
}

extension EventLoopFuture {
    var isFulfilled: Bool {
        if self.eventLoop.inEventLoop {
            // Easy, we're on the EventLoop. Let's just use our knowledge that we run completed future callbacks
            // immediately.
            let fulfilled = NIOLoopBoundBox(false, eventLoop: self.eventLoop)
            self.whenComplete { _ in
                fulfilled.value = true
            }
            return fulfilled.value
        } else {
            let fulfilled = NIOLockedValueBox(false)
            let group = DispatchGroup()

            group.enter()
            self.eventLoop.execute {
                let isFulfilled = self.isFulfilled  // This will now enter the above branch.
                fulfilled.withLockedValue {
                    $0 = isFulfilled
                }
                group.leave()
            }
            group.wait()  // this is very nasty but this is for tests only, so...
            return fulfilled.withLockedValue { $0 }
        }
    }
}

internal func XCTAssertCompareAndSwapSucceeds<Type: AtomicValue>(
    storage: ManagedAtomic<Type>,
    expected: Type,
    desired: Type,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let result = storage.compareExchange(expected: expected, desired: desired, ordering: .relaxed)
    XCTAssertTrue(result.exchanged, file: file, line: line)
}
