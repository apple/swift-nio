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

@Suite
struct LoopBoundCrashTests {
    private static let regex = "NIOCore/NIOLoopBound.swift:[0-9]+: Precondition failed"

    @Test
    func initChecksEventLoop() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
            _ = NIOLoopBound(1, eventLoop: group.any())  // BOOM
        }
        expectCrashOutput(result, matches: Self.regex)
    }

    @Test
    func initOfBoxChecksEventLoop() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
            _ = NIOLoopBoundBox(1, eventLoop: group.any())  // BOOM
        }
        expectCrashOutput(result, matches: Self.regex)
    }

    @Test
    func getChecksEventLoop() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            func blockingFunctionsAllowedInCrashTest() {
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
                let loop = group.any()
                let sendable = try? loop.submit {
                    NIOLoopBound(1, eventLoop: loop)
                }.wait()
                _ = sendable?.value  // BOOM
            }
            blockingFunctionsAllowedInCrashTest()
        }
        expectCrashOutput(result, matches: Self.regex)
    }

    @Test
    func getOfBoxChecksEventLoop() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            func blockingFunctionsAllowedInCrashTest() {
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
                let loop = group.any()
                let sendable = try? loop.submit {
                    NIOLoopBoundBox(1, eventLoop: loop)
                }.wait()
                _ = sendable?.value  // BOOM
            }
            blockingFunctionsAllowedInCrashTest()
        }
        expectCrashOutput(result, matches: Self.regex)
    }

    @Test
    func setChecksEventLoop() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            func blockingFunctionsAllowedInCrashTest() {
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
                let loop = group.any()
                let sendable = try? loop.submit {
                    NIOLoopBound(1, eventLoop: loop)
                }.wait()
                var sendableVar = sendable
                sendableVar?.value = 2
            }
            blockingFunctionsAllowedInCrashTest()
        }
        expectCrashOutput(result, matches: Self.regex)
    }

    @Test
    func setOfBoxChecksEventLoop() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            func blockingFunctionsAllowedInCrashTest() {
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
                let loop = group.any()
                let sendable = try? loop.submit {
                    NIOLoopBoundBox(1, eventLoop: loop)
                }.wait()
                sendable?.value = 2
            }
            blockingFunctionsAllowedInCrashTest()
        }
        expectCrashOutput(result, matches: Self.regex)
    }
}
#endif
