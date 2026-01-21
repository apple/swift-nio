//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOFoundationCompat
import XCTest

final class WaitSpinningRunLoopTests: XCTestCase {
    private let loop = MultiThreadedEventLoopGroup.singleton.any()

    func testPreFailedWorks() {
        struct Dummy: Error {}
        let future: EventLoopFuture<Never> = self.loop.makeFailedFuture(Dummy())
        XCTAssertThrowsError(try future.waitSpinningRunLoop()) { error in
            XCTAssert(error is Dummy)
        }
    }

    func testPreSucceededWorks() {
        let future = self.loop.makeSucceededFuture("hello")
        XCTAssertEqual("hello", try future.waitSpinningRunLoop())
    }

    func testFailingAfterALittleWhileWorks() {
        struct Dummy: Error {}
        let future: EventLoopFuture<Never> = self.loop.scheduleTask(in: .milliseconds(10)) {
            throw Dummy()
        }.futureResult
        XCTAssertThrowsError(try future.waitSpinningRunLoop()) { error in
            XCTAssert(error is Dummy)
        }
    }

    func testSucceedingAfterALittleWhileWorks() {
        let future = self.loop.scheduleTask(in: .milliseconds(10)) {
            "hello"
        }.futureResult
        XCTAssertEqual("hello", try future.waitSpinningRunLoop())
    }

    func testWeCanStillUseOurRunLoopWhilstBlocking() {
        let promise = self.loop.makePromise(of: String.self)
        let myRunLoop = RunLoop.current
        let timer = Timer(timeInterval: 0.1, repeats: false) { [loop = self.loop] _ in
            loop.scheduleTask(in: .microseconds(10)) {
                promise.succeed("hello")
            }
        }
        myRunLoop.add(timer, forMode: .default)
        XCTAssertEqual("hello", try promise.futureResult.waitSpinningRunLoop())
    }

}
