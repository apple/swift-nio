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

#if !canImport(Darwin) || os(macOS)
import Dispatch
import NIOCore
import NIOPosix

private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

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

    let testUsingTheSingletonGroupWhenDisabled = CrashTest(
        regex: #"Fatal error: Cannot create global singleton MultiThreadedEventLoopGroup because the global singletons"#
    ) {
        NIOSingletons.singletonsEnabledSuggestion = false
        try? NIOSingletons.posixEventLoopGroup.next().submit {}.wait()
    }

    let testUsingTheSingletonBlockingPoolWhenDisabled = CrashTest(
        regex: #"Fatal error: Cannot create global singleton NIOThreadPool because the global singletons have been"#
    ) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? group.syncShutdownGracefully()
        }
        NIOSingletons.singletonsEnabledSuggestion = false
        try? NIOSingletons.posixBlockingThreadPool.runIfActive(eventLoop: group.next(), {}).wait()
    }

    let testDisablingSingletonsEnabledValueTwice = CrashTest(
        regex: #"Fatal error: Bug in user code: Global singleton enabled suggestion has been changed after"#
    ) {
        NIOSingletons.singletonsEnabledSuggestion = false
        NIOSingletons.singletonsEnabledSuggestion = false
    }

    let testEnablingSingletonsEnabledValueTwice = CrashTest(
        regex: #"Fatal error: Bug in user code: Global singleton enabled suggestion has been changed after"#
    ) {
        NIOSingletons.singletonsEnabledSuggestion = true
        NIOSingletons.singletonsEnabledSuggestion = true
    }

    let testEnablingThenDisablingSingletonsEnabledValue = CrashTest(
        regex: #"Fatal error: Bug in user code: Global singleton enabled suggestion has been changed after"#
    ) {
        NIOSingletons.singletonsEnabledSuggestion = true
        NIOSingletons.singletonsEnabledSuggestion = false
    }

    let testSettingTheSingletonEnabledValueAfterUse = CrashTest(
        regex: #"Fatal error: Bug in user code: Global singleton enabled suggestion has been changed after"#
    ) {
        try? MultiThreadedEventLoopGroup.singleton.next().submit({}).wait()
        NIOSingletons.singletonsEnabledSuggestion = true
    }

    let testSettingTheSuggestedSingletonGroupCountTwice = CrashTest(
        regex: #"Fatal error: Bug in user code: Global singleton suggested loop/thread count has been changed after"#
    ) {
        NIOSingletons.groupLoopCountSuggestion = 17
        NIOSingletons.groupLoopCountSuggestion = 17
    }

    let testSettingTheSuggestedSingletonGroupChangeAfterUse = CrashTest(
        regex: #"Fatal error: Bug in user code: Global singleton suggested loop/thread count has been changed after"#
    ) {
        try? MultiThreadedEventLoopGroup.singleton.next().submit({}).wait()
        NIOSingletons.groupLoopCountSuggestion = 17
    }

    let testSettingTheSuggestedSingletonGroupLoopCountToZero = CrashTest(
        regex: #"Precondition failed: illegal value: needs to be strictly positive"#
    ) {
        NIOSingletons.groupLoopCountSuggestion = 0
    }

    let testSettingTheSuggestedSingletonGroupLoopCountToANegativeValue = CrashTest(
        regex: #"Precondition failed: illegal value: needs to be strictly positive"#
    ) {
        NIOSingletons.groupLoopCountSuggestion = -1
    }

    #if swift(<6.2)  // We only support Concurrency executor take-over on those Swift versions, as versions greater than that have not been properly tested.
    let testInstallingSingletonMTELGAsConcurrencyExecutorWorksButOnlyOnce = CrashTest(
        regex: #"Fatal error: Must be called only once"#
    ) {
        guard NIOSingletons.unsafeTryInstallSingletonPosixEventLoopGroupAsConcurrencyGlobalExecutor() else {
            print("Installation failed, that's unexpected -> let's not crash")
            return
        }

        // Yes, this pattern is bad abuse but this is a crash test, we don't mind.
        let semaphoreAbuse = DispatchSemaphore(value: 0)
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            Task {
                precondition(MultiThreadedEventLoopGroup.currentEventLoop != nil)
                try await Task.sleep(nanoseconds: 123)
                precondition(MultiThreadedEventLoopGroup.currentEventLoop != nil)
                semaphoreAbuse.signal()
            }
        } else {
            semaphoreAbuse.signal()
        }
        semaphoreAbuse.wait()
        print("Okay, worked")

        // This should crash
        _ = NIOSingletons.unsafeTryInstallSingletonPosixEventLoopGroupAsConcurrencyGlobalExecutor()
    }
    #endif  // swift(<6.2)
}
#endif  // !canImport(Darwin) || os(macOS)
