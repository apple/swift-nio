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

// swift-format-ignore: AmbiguousTrailingClosureOverload

import NIOConcurrencyHelpers
import XCTest

@testable import NIOCore

func assertNoThrowWithValue<T>(
    _ body: @autoclosure () throws -> T,
    defaultValue: T? = nil,
    message: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    do {
        return try body()
    } catch {
        XCTFail(
            "\(message.map { $0 + ": " } ?? "")unexpected error \(error) thrown",
            file: (file),
            line: line
        )
        if let defaultValue = defaultValue {
            return defaultValue
        } else {
            throw error
        }
    }
}

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

func assertSuccess<Value>(
    _ result: Result<Value, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .success = result else {
        return XCTFail("Expected result to be successful", file: (file), line: line)
    }
}

func assertFailure<Value>(
    _ result: Result<Value, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .failure = result else {
        return XCTFail("Expected result to be a failure", file: (file), line: line)
    }
}

extension EventLoopFuture {
    var isFulfilled: Bool {
        if self.eventLoop.inEventLoop {
            // Easy, we're on the EventLoop. Let's just use our knowledge that we run completed future callbacks
            // immediately.
            var fulfilled = false
            self.assumeIsolated().whenComplete { _ in
                fulfilled = true
            }
            return fulfilled
        } else {
            let fulfilledBox = NIOLockedValueBox(false)
            let group = DispatchGroup()

            group.enter()
            self.eventLoop.execute {
                let isFulfilled = self.isFulfilled  // This will now enter the above branch.
                fulfilledBox.withLockedValue {
                    $0 = isFulfilled
                }
                group.leave()
            }
            group.wait()  // this is very nasty but this is for tests only, so...
            return fulfilledBox.withLockedValue { $0 }
        }
    }
}
