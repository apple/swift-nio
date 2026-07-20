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
import Foundation
import NIOCore
import NIOPosix
import Testing

#if os(Windows)
import ucrt  // for `EBADF`
#endif

@Suite
struct SystemCrashTests {
    // `NIOPipeBootstrap` deliberately `fatalError`s on Windows, so this test can
    // only exercise its `EBADF` handling on the POSIX platforms. It's compiled
    // everywhere exit tests are available but skipped at runtime on Windows.
    @Test(
        .disabled("NIOPipeBootstrap is not supported on Windows") {
            #if os(Windows)
            return true
            #else
            return false
            #endif
        }
    )
    func ebadfIsUnacceptable() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            func blockingFunctionsAllowedInCrashTest() {
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                _ = try? NIOPipeBootstrap(group: group).takingOwnershipOfDescriptors(input: .max, output: .max - 1)
                    .wait()
            }
            blockingFunctionsAllowedInCrashTest()
        }
        expectCrashOutput(result, matches: "Precondition failed: unacceptable errno \(EBADF) Bad file descriptor in")
    }
}
#endif
