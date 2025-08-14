//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics

#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
import WinSDK
#elseif canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Bionic)
@preconcurrency import Bionic
#elseif canImport(WASILibc)
@preconcurrency import WASILibc
#else
#error("Unsupported C library")
#endif

/// SwiftNIO provided singleton resources for programs & libraries that don't need full control over all operating
/// system resources. This type holds sizing (how many loops/threads) suggestions.
///
/// Users who need very tight control about the exact threads and resources created may decide to set
/// `NIOSingletons.singletonsEnabledSuggestion = false`. All singleton-creating facilities should check
/// this setting and if `false` restrain from creating any global singleton resources. Please note that disabling the
/// global singletons will lead to a crash if _any_ code attempts to use any of the singletons.
public enum NIOSingletons: Sendable {
}

extension NIOSingletons {
    /// A suggestion of how many ``EventLoop``s the global singleton ``EventLoopGroup``s are supposed to consist of.
    ///
    /// The thread count is ``System/coreCount`` unless the environment variable `NIO_SINGLETON_GROUP_LOOP_COUNT`
    /// is set or this value was set manually by the user.
    ///
    /// Please note that setting this value is a privileged operation which should be performed very early on in the program's lifecycle
    /// by the main function, or ideally not at all.
    /// Furthermore, setting the value will only have an effect if the global singleton ``EventLoopGroup`` has not already
    /// been used.
    ///
    /// - Warning: This value can only be set _once_, attempts to set it again will crash the program.
    /// - Note: This value must be set _before_ any singletons are used and must only be set once.
    public static var groupLoopCountSuggestion: Int {
        set {
            Self.userSetSingletonThreadCount(rawStorage: globalRawSuggestedLoopCount, userValue: newValue)
        }

        get {
            Self.getTrustworthyThreadCount(
                rawStorage: globalRawSuggestedLoopCount,
                environmentVariable: "NIO_SINGLETON_GROUP_LOOP_COUNT"
            )
        }
    }

    /// A suggestion of how many threads the global singleton thread pools that can be used for synchronous, blocking
    /// functions (such as `NIOThreadPool`) are supposed to consist of
    ///
    /// The thread count is ``System/coreCount`` unless the environment variable
    /// `NIO_SINGLETON_BLOCKING_POOL_THREAD_COUNT` is set or this value was set manually by the user.
    ///
    /// Please note that setting this value is a privileged operation which should be performed very early on in the program's lifecycle
    /// by the main function, or ideally not at all.
    /// Furthermore, setting the value will only have an effect if the global singleton thread pool has not already
    /// been used.
    ///
    /// - Warning: This value can only be set _once_, attempts to set it again will crash the program.
    /// - Note: This value must be set _before_ any singletons are used and must only be set once.
    public static var blockingPoolThreadCountSuggestion: Int {
        set {
            Self.userSetSingletonThreadCount(rawStorage: globalRawSuggestedBlockingThreadCount, userValue: newValue)
        }

        get {
            Self.getTrustworthyThreadCount(
                rawStorage: globalRawSuggestedBlockingThreadCount,
                environmentVariable: "NIO_SINGLETON_BLOCKING_POOL_THREAD_COUNT"
            )
        }
    }

    /// A suggestion for whether the global singletons should be enabled. This is `true` unless changed by the user.
    ///
    /// This value cannot be changed using an environment variable.
    ///
    /// Please note that setting this value is a privileged operation which should be performed very early on in the program's lifecycle
    /// by the main function, or ideally not at all.
    ///
    /// - Warning: This value can only be set _once_, attempts to set it again will crash the program.
    /// - Note: This value must be set _before_ any singletons are used and must only be set once.
    public static var singletonsEnabledSuggestion: Bool {
        get {
            let (exchanged, original) = globalRawSingletonsEnabled.compareExchange(
                expected: 0,
                desired: 1,
                ordering: .relaxed
            )
            if exchanged {
                // Never been set, we're committing to the default (enabled).
                assert(original == 0)
                return true
            } else {
                // This has been set before, 1: enabled; -1 disabled.
                assert(original != 0)
                assert(original == -1 || original == 1)
                return original > 0
            }
        }

        set {
            let intRepresentation = newValue ? 1 : -1
            let (exchanged, _) = globalRawSingletonsEnabled.compareExchange(
                expected: 0,
                desired: intRepresentation,
                ordering: .relaxed
            )
            guard exchanged else {
                fatalError(
                    """
                    Bug in user code: Global singleton enabled suggestion has been changed after \
                    user or has been changed more than once. Either is an error, you must set this value very \
                    early and only once.
                    """
                )
            }
        }
    }
}

// DO NOT TOUCH THESE DIRECTLY, use `userSetSingletonThreadCount` and `getTrustworthyThreadCount`.
private let globalRawSuggestedLoopCount = ManagedAtomic(0)
private let globalRawSuggestedBlockingThreadCount = ManagedAtomic(0)
private let globalRawSingletonsEnabled = ManagedAtomic(0)

extension NIOSingletons {
    private static func userSetSingletonThreadCount(rawStorage: ManagedAtomic<Int>, userValue: Int) {
        precondition(userValue > 0, "illegal value: needs to be strictly positive")

        // The user is trying to set it. We can only do this if the value is at 0 and we will set the
        // negative value. So if the user wants `5`, we will set `-5`. Once it's used (set getter), it'll be upped
        // to 5.
        let (exchanged, _) = rawStorage.compareExchange(expected: 0, desired: -userValue, ordering: .relaxed)
        guard exchanged else {
            fatalError(
                """
                Bug in user code: Global singleton suggested loop/thread count has been changed after \
                user or has been changed more than once. Either is an error, you must set this value very early \
                and only once.
                """
            )
        }
    }

    private static func validateTrustedThreadCount(_ threadCount: Int) {
        assert(
            threadCount > 0,
            "BUG IN NIO, please report: negative suggested loop/thread count: \(threadCount)"
        )
        assert(
            threadCount <= 1024,
            "BUG IN NIO, please report: overly big suggested loop/thread count: \(threadCount)"
        )
    }

    private static func getTrustworthyThreadCount(rawStorage: ManagedAtomic<Int>, environmentVariable: String) -> Int {
        let returnedValueUnchecked: Int

        let rawSuggestion = rawStorage.load(ordering: .relaxed)
        switch rawSuggestion {
        case 0:  // == 0
            // Not set by user, not yet finalised, let's try to get it from the env var and fall back to
            // `System.coreCount`.
            #if os(Windows)
            let envVarString = Windows.getenv(environmentVariable)
            #else
            let envVarString = getenv(environmentVariable).map { String(cString: $0) }
            #endif
            returnedValueUnchecked = envVarString.flatMap(Int.init) ?? System.coreCount
        case .min..<0:  // < 0
            // Untrusted and unchecked user value. Let's invert and then sanitise/check.
            returnedValueUnchecked = -rawSuggestion
        case 1 ... .max:  // > 0
            // Trustworthy value that has been evaluated and sanitised before.
            let returnValue = rawSuggestion
            Self.validateTrustedThreadCount(returnValue)
            return returnValue
        default:
            // Unreachable
            preconditionFailure()
        }

        // Can't have fewer than 1, don't want more than 1024.
        let returnValue = max(1, min(1024, returnedValueUnchecked))
        Self.validateTrustedThreadCount(returnValue)

        // Store it for next time.
        let (exchanged, _) = rawStorage.compareExchange(
            expected: rawSuggestion,
            desired: returnValue,
            ordering: .relaxed
        )
        if !exchanged {
            // We lost the race, this must mean it has been concurrently set correctly so we can safely recurse
            // and try again.
            return Self.getTrustworthyThreadCount(rawStorage: rawStorage, environmentVariable: environmentVariable)
        }
        return returnValue
    }
}
