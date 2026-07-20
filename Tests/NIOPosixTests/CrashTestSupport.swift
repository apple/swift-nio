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

// Exit tests are available on macOS, Linux, FreeBSD, OpenBSD, and Windows; see
// https://github.com/swiftlang/swift-testing/blob/main/Sources/Testing/Testing.docc/exit-testing.md
#if compiler(>=6.2) && (os(macOS) || os(Linux) || os(FreeBSD) || os(OpenBSD) || os(Windows))
import Foundation
import Testing

/// Assert that a completed exit test crashed with a message on its standard
/// error stream matching `regex`.
///
/// The exit test itself already asserts that the process crashed (via
/// `#expect(processExitsWith: .failure)`). This helper additionally checks the
/// crash *message*, preserving the message checks the old NIOCrashTester did.
///
/// The message check only runs in debug builds: Swift writes `precondition` and
/// `assert` failure messages to stderr only when assertions are enabled, so in
/// release builds there's nothing to match and we rely solely on the exit
/// status. Pass the child's standard error by observing `\.standardErrorContent`.
func expectCrashOutput(
    _ result: ExitTest.Result?,
    matches regex: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let result else {
        // The process didn't crash as expected; that failure is already
        // reported by the `#expect(processExitsWith:)` macro.
        return
    }
    // The crash message is only written to stderr in debug builds (Swift omits
    // `precondition`/`assert` messages in release), so only check it there. The
    // exit test itself already asserted that the process crashed.
    if isDebugAssertConfiguration() {
        let output = String(decoding: result.standardErrorContent, as: UTF8.self)
        #expect(
            output.range(of: regex, options: .regularExpression) != nil,
            "crash output \(output.debugDescription) did not match regex \(regex.debugDescription)",
            sourceLocation: sourceLocation
        )
    }
}

/// Whether the test binary is built with assertions enabled (i.e. a debug
/// build).
///
/// NIO's `assert`-based checks — including `debugOnly { }` and the promise-leak
/// detector — only fire in this configuration, so crash tests that rely on them
/// must be skipped in release builds (where they would not crash).
func isDebugAssertConfiguration() -> Bool {
    var isDebugAssert = false
    assert(
        {
            isDebugAssert = true
            return true
        }()
    )
    return isDebugAssert
}
#endif
