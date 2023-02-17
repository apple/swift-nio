//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
#if !os(iOS) && !os(tvOS) && !os(watchOS)
import NIOCore
import NIOPosix

fileprivate let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

struct EventLoopCrashTests {
    let testMultiThreadedELGCrashesOnZeroThreads = CrashTest(
        regex: "Precondition failed: numberOfThreads must be positive"
    ) {
        try? MultiThreadedEventLoopGroup(numberOfThreads: 0).syncShutdownGracefully()
    }

    let testWaitCrashesWhenOnEL = CrashTest(
        regex: #"Precondition failed: BUG DETECTED: wait\(\) must not be called when on an EventLoop"#
    ) {
        let promise = group.next().makePromise(of: Void.self)
        try? group.next().submit {
            try? promise.futureResult.wait()
        }.wait()
    }

    let testAssertInEventLoop = CrashTest(
        regex: "Precondition failed"
    ) {
        group.next().assertInEventLoop(file: "DUMMY", line: 42)
    }

    let testPreconditionInEventLoop = CrashTest(
        regex: "Precondition failed"
    ) {
        group.next().preconditionInEventLoop(file: "DUMMY", line: 42)
    }

    let testAssertNotInEventLoop = CrashTest(
        regex: "Precondition failed"
    ) {
        let el = group.next()
        try? el.submit {
            el.assertNotInEventLoop(file: "DUMMY", line: 42)
        }.wait()
    }

    let testPreconditionNotInEventLoop = CrashTest(
        regex: "Precondition failed"
    ) {
        let el = group.next()
        try? el.submit {
            el.preconditionNotInEventLoop(file: "DUMMY", line: 42)
        }.wait()
    }

    let testSchedulingEndlesslyInELShutdown = CrashTest(
        regex: #"Precondition failed: EventLoop SelectableEventLoop \{ .* \} didn't quiesce after 1000 ticks."#
    ) {
        let group = MultiThreadedEventLoopGroup.init(numberOfThreads: 1)
        defer {
            try? group.syncShutdownGracefully()
            exit(4)
        }
        let el = group.next()
        el.scheduleTask(in: .hours(7)) {
            // Will never happen.
            exit(1)
        }.futureResult.whenFailure { error in
            guard case .some(.shutdown) = error as? EventLoopError else {
                exit(2)
            }
            func f() {
                el.scheduleTask(in: .nanoseconds(0)) { [f /* to make 5.1 compiler not crash */] in
                    f()
                }.futureResult.whenFailure { [f /* to make 5.1 compiler not crash */] error in
                    guard case .some(.shutdown) = error as? EventLoopError else {
                        exit(3)
                    }
                    f()
                }
            }
            f()
        }
    }

    let testLeakingAPromiseCrashes = CrashTest(
        regex: #"Fatal error: leaking promise created at"#
    ) {
        @inline(never)
        func leaker() {
            _ = group.next().makePromise(of: Void.self)
        }
        leaker()
        for el in group.makeIterator() {
            try! el.submit {}.wait()
        }
    }
}
#endif
