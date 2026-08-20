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

import Foundation
@_spi(CustomByteBufferAllocator) import NIOCore
import Testing

// Exit tests are available on macOS, Linux, FreeBSD, OpenBSD, and Windows; see
// https://github.com/swiftlang/swift-testing/blob/main/Sources/Testing/Testing.docc/exit-testing.md
#if compiler(>=6.2) && (os(macOS) || os(Linux) || os(FreeBSD) || os(OpenBSD) || os(Windows))
@Suite struct ByteBufferCrashTests {

    @Test func copyBytesToIndexExceedingUInt32Max() async {
        await #expect(processExitsWith: .failure) {
            var buf = ByteBufferAllocator().buffer(capacity: 256)
            buf.writeBytes(Array(repeating: UInt8(0x41), count: 64))
            let toIndex = Int(UInt32.max) + 1
            try buf.copyBytes(at: 0, to: toIndex, length: 64)
        }
    }

    @Test func writeWithUnsafeMutableBytesCrashesWhenWritingMoreThanUInt32MaxBytes() async {
        await #expect(processExitsWith: .failure) {
            var buf = ByteBufferAllocator().buffer(capacity: 0)
            // ask for more capacity then ByteBuffer can provide.
            buf.writeWithUnsafeMutableBytes(minimumWritableBytes: Int(UInt32.max) + 2) { ptr in
                Issue.record("This should not be called")
                // in release without bounds checks, devs can write to
                // larger than 1 here.
                #expect(ptr.count == 1)
                return 1
            }
        }
    }

    @Test func moveReaderIndexTooFar() async {
        await #expect(processExitsWith: .failure) {
            var bb = ByteBuffer()
            bb.writeString("Hello World")
            bb.moveReaderIndex(forwardBy: 32)
        }
    }

    @Test func moveReaderIndexWayTooFar() async {
        await #expect(processExitsWith: .failure) {
            var bb = ByteBuffer()
            bb.writeString("Hello World")
            bb.moveReaderIndex(forwardBy: Int(UInt32.max) + 1)
        }
    }

    @Test func moveWriterIndexTooFar() async {
        await #expect(processExitsWith: .failure) {
            var bb = ByteBuffer()
            bb.reserveCapacity(64)
            bb.moveWriterIndex(forwardBy: 70)
        }
    }

    @Test func moveWriterIndexWayTooFar() async {
        await #expect(processExitsWith: .failure) {
            var bb = ByteBuffer()
            bb.reserveCapacity(64)
            bb.moveWriterIndex(forwardBy: Int(UInt32.max) + 1)
        }
    }

    @Test func setBytesWithMoreThanUInt32MaxBytes() async {
        await #expect(processExitsWith: .failure) {
            let sequence = Array(repeating: UInt8(0), count: Int(UInt32.max) + 1)
            var bb = ByteBuffer()
            bb.reserveCapacity(64)
            bb.setBytes(sequence, at: bb.writerIndex)
        }
    }

    @Test func setBytesAtIndexAfterUInt32Max() async {
        await #expect(processExitsWith: .failure) {
            var bb = ByteBuffer()
            bb.reserveCapacity(64)
            bb.setBytes([1], at: Int(UInt32.max) + 1)
        }
    }

    @Test(
        // Allocating ~4GB is slow, so this test is opt-in via a truthy SWIFTNIO_RUN_SLOW_TESTS.
        .disabled(
            if: !slowTestsEnabled(),
            "Set SWIFTNIO_RUN_SLOW_TESTS to run this slow (~4GB of memory written) test"
        ),
        .disabled(if: MemoryLayout<Int>.size < 8, "Doesn't work on 32-bit machines")
    )
    func setBytesWithoutContigiousStorageMoreThanUInt32MaxBytes() async {
        await #expect(processExitsWith: .failure) {
            let circularBuffer = CircularBuffer<UInt8>(repeating: 0, count: Int(UInt32.max) + 1)
            var bb = ByteBuffer()
            bb.reserveCapacity(64)
            bb.setBytes(circularBuffer, at: bb.writerIndex)
        }
    }

    @Test func setBytesWithoutContigiousStorageAfterUInt32Max() async {
        await #expect(processExitsWith: .failure) {
            let circularBuffer = CircularBuffer<UInt8>(repeating: 0, count: 4)
            var bb = ByteBuffer()
            bb.reserveCapacity(64)
            bb.setBytes(circularBuffer, at: Int(UInt32.max) + 1)
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *)
    @Test func setRawSpanWithMoreThanUInt32MaxBytes() async {
        await #expect(processExitsWith: .failure) {
            let count = Int(UInt32.max) + 1
            let sequence = Array(repeating: UInt8(0), count: count)
            var bb = ByteBuffer()
            bb.reserveCapacity(64)
            let rawSpan = sequence.span.bytes
            #expect(rawSpan.byteCount == count)
            bb.setBytes(sequence.span.bytes, at: bb.writerIndex)
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *)
    @Test func setRawSpanAfterUInt32Max() async {
        await #expect(processExitsWith: .failure) {
            let sequence = Array(repeating: UInt8(0), count: 4)
            var bb = ByteBuffer()
            bb.reserveCapacity(64)
            let rawSpan = sequence.span.bytes
            bb.setBytes(rawSpan, at: Int(UInt32.max) + 1)
        }
    }

    @Test func takingOwnershipOfPointerThatsToLarge() async {
        await #expect(processExitsWith: .failure) {
            let capacity = Int(UInt32.max) + 1
            let ptr = malloc(capacity)!

            let allocator = ByteBufferCustomAllocatorTest.makeTrackedAllocator()

            // this should crash
            let buffer = ByteBuffer(
                takingOwnershipOf: UnsafeMutableRawBufferPointer(start: ptr, count: capacity),
                allocator: allocator
            )

            _ = buffer
        }
    }

    @Test func movingReaderIndexPastWriterIndex() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            var buffer = ByteBufferAllocator().buffer(capacity: 16)
            buffer.moveReaderIndex(forwardBy: 1)
        }
        expectCrashOutput(result, matches: #"Precondition failed: new readerIndex: 1, expected: range\(0, 0\)"#)
    }

    @Test func allocatingNegativeSize() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = ByteBufferAllocator().buffer(capacity: -1)
        }
        expectCrashOutput(result, matches: #"Precondition failed: ByteBuffer capacity must be positive."#)
    }
}

/// Assert that a completed exit test crashed with a message on its standard
/// error stream matching `regex`. This preserves the crash-message checks the
/// old NIOCrashTester performed, ensuring the process crashed for the *expected*
/// reason rather than any reason.
private func expectCrashOutput(
    _ result: ExitTest.Result?,
    matches regex: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let result else { return }
    // `precondition` failure messages are only written to stderr in debug
    // builds, so only check the message there; the exit test already asserted
    // that the process crashed.
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
/// build). `precondition` failure messages are only written to stderr in this
/// configuration, so crash tests that assert on them must be skipped in release.
private func isDebugAssertConfiguration() -> Bool {
    var isDebugAssert = false
    assert(
        {
            isDebugAssert = true
            return true
        }()
    )
    return isDebugAssert
}

/// Whether opt-in slow tests should run, gated on a truthy `SWIFTNIO_RUN_SLOW_TESTS`
/// environment variable. Unset (the default) means slow tests do not run.
private func slowTestsEnabled() -> Bool {
    switch ProcessInfo.processInfo.environment["SWIFTNIO_RUN_SLOW_TESTS"]?.lowercased() {
    case "true", "y", "yes", "on", "1":
        return true
    default:
        return false
    }
}
#endif
