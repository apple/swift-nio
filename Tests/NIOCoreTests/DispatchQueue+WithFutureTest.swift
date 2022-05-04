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

import Dispatch
import NIOCore
import NIOEmbedded
import XCTest

enum DispatchQueueTestError: Error {
    case example
}

class DispatchQueueWithFutureTest: XCTestCase {
    func testDispatchQueueAsyncWithFuture() {
        let eventLoop = EmbeddedEventLoop()
        let sem = DispatchSemaphore(value: 0)
        var nonBlockingRan = false
        let futureResult: EventLoopFuture<String> = DispatchQueue.global().asyncWithFuture(eventLoop: eventLoop) {
            () -> String in
            sem.wait()  // Block in callback
            return "hello"
        }
        futureResult.whenSuccess { value in
            XCTAssertEqual(value, "hello")
            XCTAssertTrue(nonBlockingRan)
        }

        let p2 = eventLoop.makePromise(of: Bool.self)
        p2.futureResult.whenSuccess { _ in
            nonBlockingRan = true
        }
        p2.succeed(true)

        sem.signal()
    }

    func testDispatchQueueAsyncWithFutureThrows() {
        let eventLoop = EmbeddedEventLoop()
        let sem = DispatchSemaphore(value: 0)
        var nonBlockingRan = false
        let futureResult: EventLoopFuture<String> = DispatchQueue.global().asyncWithFuture(eventLoop: eventLoop) {
            () -> String in
            sem.wait()  // Block in callback
            throw DispatchQueueTestError.example
        }
        futureResult.whenFailure { err in
            XCTAssertEqual(err as! DispatchQueueTestError, DispatchQueueTestError.example)
            XCTAssertTrue(nonBlockingRan)
        }

        let p2 = eventLoop.makePromise(of: Bool.self)
        p2.futureResult.whenSuccess { _ in
            nonBlockingRan = true
        }
        p2.succeed(true)

        sem.signal()
    }
}
