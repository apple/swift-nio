//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022-2026 Apple Inc. and the SwiftNIO project authors
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
import Foundation
import NIOCore
import NIOPosix
import Testing

#if os(Windows)
import ucrt
#endif

@Suite
struct StrictCrashTests {
    @Test
    func eventLoopScheduleAfterShutdown() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            func blockingFunctionsAllowedInCrashTest() {
                #if os(Windows)
                _ = _putenv_s("SWIFTNIO_STRICT", "1")
                #else
                setenv("SWIFTNIO_STRICT", "1", 1)
                #endif
                let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                let loop = elg.next()
                try! elg.syncShutdownGracefully()
                loop.execute {
                    print("Crash should happen before this line is printed.")
                }
            }
            blockingFunctionsAllowedInCrashTest()
        }
        expectCrashOutput(
            result,
            matches: "Fatal error: Cannot schedule tasks on an EventLoop that has already shut down."
        )
    }
}
#endif
