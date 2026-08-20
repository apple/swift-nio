//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// Exit tests are available on macOS, Linux, FreeBSD, OpenBSD, and Windows; see
// https://github.com/swiftlang/swift-testing/blob/main/Sources/Testing/Testing.docc/exit-testing.md
#if compiler(>=6.2) && (os(macOS) || os(Linux) || os(FreeBSD) || os(OpenBSD) || os(Windows))
import NIOCore
import NIOPosix
import Testing

// The exit-test body is an `async` closure and there's no synchronous overload,
// so the `noasync` `wait()` / `syncShutdownGracefully()` calls the crash tests
// need are wrapped in a nested synchronous `blockingFunctionsAllowedInCrashTest()` function, where they're
// allowed: https://github.com/swiftlang/swift-testing/issues/1786
@Suite
struct EventLoopCrashTests {
    @Test
    func multiThreadedELGCrashesOnZeroThreads() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            func blockingFunctionsAllowedInCrashTest() {
                try? MultiThreadedEventLoopGroup(numberOfThreads: 0).syncShutdownGracefully()
            }
            blockingFunctionsAllowedInCrashTest()
        }
        expectCrashOutput(result, matches: "Precondition failed: numberOfThreads must be positive")
    }

    @Test
    func waitCrashesWhenOnEL() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            func blockingFunctionsAllowedInCrashTest() {
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
                let promise = group.next().makePromise(of: Void.self)
                try? group.next().submit {
                    try? promise.futureResult.wait()
                }.wait()
            }
            blockingFunctionsAllowedInCrashTest()
        }
        expectCrashOutput(
            result,
            matches: #"Precondition failed: BUG DETECTED: wait\(\) must not be called when on an EventLoop"#
        )
    }

    // `assertInEventLoop` is a `debugOnly` check that doesn't trap at all in
    // release builds, so this can't even assert `.failure` there.
    @Test(.disabled(if: !isDebugAssertConfiguration(), "assertInEventLoop only traps in debug builds"))
    func assertInEventLoop() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
            group.next().assertInEventLoop(file: "DUMMY", line: 42)
        }
        expectCrashOutput(result, matches: "Precondition failed")
    }

    @Test
    func preconditionInEventLoop() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
            group.next().preconditionInEventLoop(file: "DUMMY", line: 42)
        }
        expectCrashOutput(result, matches: "Precondition failed")
    }

    // `assertNotInEventLoop` is a `debugOnly` check that doesn't trap at all in
    // release builds, so this can't even assert `.failure` there.
    @Test(.disabled(if: !isDebugAssertConfiguration(), "assertNotInEventLoop only traps in debug builds"))
    func assertNotInEventLoop() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            func blockingFunctionsAllowedInCrashTest() {
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
                let el = group.next()
                try? el.submit {
                    el.assertNotInEventLoop(file: "DUMMY", line: 42)
                }.wait()
            }
            blockingFunctionsAllowedInCrashTest()
        }
        expectCrashOutput(result, matches: "Precondition failed")
    }

    @Test
    func preconditionNotInEventLoop() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            func blockingFunctionsAllowedInCrashTest() {
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
                let el = group.next()
                try? el.submit {
                    el.preconditionNotInEventLoop(file: "DUMMY", line: 42)
                }.wait()
            }
            blockingFunctionsAllowedInCrashTest()
        }
        expectCrashOutput(result, matches: "Precondition failed")
    }

    @Test
    func schedulingEndlesslyInELShutdown() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            func blockingFunctionsAllowedInCrashTest() {
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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
                        el.assumeIsolated().scheduleTask(in: .nanoseconds(0)) { [f] in
                            f()
                        }.futureResult.assumeIsolated().whenFailure { [f] error in
                            guard case .some(.shutdown) = error as? EventLoopError else {
                                exit(3)
                            }
                            f()
                        }
                    }
                    f()
                }
            }
            blockingFunctionsAllowedInCrashTest()
        }
        expectCrashOutput(
            result,
            matches: #"Precondition failed: EventLoop SelectableEventLoop \{ .* \} didn't quiesce after 1000 ticks."#
        )
    }

    // Promise-leak detection runs inside `debugOnly`, so nothing traps in
    // release builds and this can't even assert `.failure` there.
    @Test(.disabled(if: !isDebugAssertConfiguration(), "Promise-leak detection only fires in debug builds"))
    func leakingAPromiseCrashes() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            func blockingFunctionsAllowedInCrashTest() {
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
                @inline(never)
                func leaker() {
                    _ = group.next().makePromise(of: Void.self)
                }
                leaker()
                for el in group.makeIterator() {
                    try! el.submit {}.wait()
                }
            }
            blockingFunctionsAllowedInCrashTest()
        }
        expectCrashOutput(result, matches: #"Fatal error: leaking promise created at"#)
    }

    @Test
    func usingTheSingletonGroupWhenDisabled() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            func blockingFunctionsAllowedInCrashTest() {
                NIOSingletons.singletonsEnabledSuggestion = false
                try? NIOSingletons.posixEventLoopGroup.next().submit {}.wait()
            }
            blockingFunctionsAllowedInCrashTest()
        }
        expectCrashOutput(
            result,
            matches:
                #"Fatal error: Cannot create global singleton MultiThreadedEventLoopGroup because the global singletons"#
        )
    }

    @Test
    func usingTheSingletonBlockingPoolWhenDisabled() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            func blockingFunctionsAllowedInCrashTest() {
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                defer {
                    try? group.syncShutdownGracefully()
                }
                NIOSingletons.singletonsEnabledSuggestion = false
                try? NIOSingletons.posixBlockingThreadPool.runIfActive(eventLoop: group.next(), {}).wait()
            }
            blockingFunctionsAllowedInCrashTest()
        }
        expectCrashOutput(
            result,
            matches:
                #"Fatal error: Cannot create global singleton NIOThreadPool because the global singletons have been"#
        )
    }

    @Test
    func disablingSingletonsEnabledValueTwice() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            NIOSingletons.singletonsEnabledSuggestion = false
            NIOSingletons.singletonsEnabledSuggestion = false
        }
        expectCrashOutput(
            result,
            matches: #"Fatal error: Bug in user code: Global singleton enabled suggestion has been changed after"#
        )
    }

    @Test
    func enablingSingletonsEnabledValueTwice() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            NIOSingletons.singletonsEnabledSuggestion = true
            NIOSingletons.singletonsEnabledSuggestion = true
        }
        expectCrashOutput(
            result,
            matches: #"Fatal error: Bug in user code: Global singleton enabled suggestion has been changed after"#
        )
    }

    @Test
    func enablingThenDisablingSingletonsEnabledValue() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            NIOSingletons.singletonsEnabledSuggestion = true
            NIOSingletons.singletonsEnabledSuggestion = false
        }
        expectCrashOutput(
            result,
            matches: #"Fatal error: Bug in user code: Global singleton enabled suggestion has been changed after"#
        )
    }

    @Test
    func settingTheSingletonEnabledValueAfterUse() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            func blockingFunctionsAllowedInCrashTest() {
                try? MultiThreadedEventLoopGroup.singleton.next().submit({}).wait()
                NIOSingletons.singletonsEnabledSuggestion = true
            }
            blockingFunctionsAllowedInCrashTest()
        }
        expectCrashOutput(
            result,
            matches: #"Fatal error: Bug in user code: Global singleton enabled suggestion has been changed after"#
        )
    }

    @Test
    func settingTheSuggestedSingletonGroupCountTwice() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            NIOSingletons.groupLoopCountSuggestion = 17
            NIOSingletons.groupLoopCountSuggestion = 17
        }
        expectCrashOutput(
            result,
            matches:
                #"Fatal error: Bug in user code: Global singleton suggested loop/thread count has been changed after"#
        )
    }

    @Test
    func settingTheSuggestedSingletonGroupChangeAfterUse() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            func blockingFunctionsAllowedInCrashTest() {
                try? MultiThreadedEventLoopGroup.singleton.next().submit({}).wait()
                NIOSingletons.groupLoopCountSuggestion = 17
            }
            blockingFunctionsAllowedInCrashTest()
        }
        expectCrashOutput(
            result,
            matches:
                #"Fatal error: Bug in user code: Global singleton suggested loop/thread count has been changed after"#
        )
    }

    @Test
    func settingTheSuggestedSingletonGroupLoopCountToZero() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            NIOSingletons.groupLoopCountSuggestion = 0
        }
        expectCrashOutput(result, matches: #"Precondition failed: illegal value: needs to be strictly positive"#)
    }

    @Test
    func settingTheSuggestedSingletonGroupLoopCountToANegativeValue() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            NIOSingletons.groupLoopCountSuggestion = -1
        }
        expectCrashOutput(result, matches: #"Precondition failed: illegal value: needs to be strictly positive"#)
    }
}
#endif
