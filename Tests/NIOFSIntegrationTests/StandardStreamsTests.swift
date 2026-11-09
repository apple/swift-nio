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

@_spi(Testing) import NIOFS
import NIOPosix
import XCTest

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class StandardStreamsTests: XCTestCase {
    override func setUpWithError() throws {
        #if os(Windows)
        throw XCTSkip("The NIOFileSystem family is not yet functional on Windows")
        #endif
    }

    func testStandardHandlesAreDuplicated() async throws {
        // Check each handle independently so a failed open cannot leave earlier handles
        // outstanding. SystemFileHandle requires descriptors to be closed explicitly.
        let input = try await FileSystem.shared.openStandardInput()
        let inputDescriptor = try await input.withUnsafeDescriptor { $0.rawValue }
        XCTAssertNotEqual(inputDescriptor, 0)
        try await input.close()

        let output = try await FileSystem.shared.openStandardOutput()
        let outputDescriptor = try await output.withUnsafeDescriptor { $0.rawValue }
        XCTAssertNotEqual(outputDescriptor, 1)
        try await output.close()

        let error = try await FileSystem.shared.openStandardError()
        let errorDescriptor = try await error.withUnsafeDescriptor { $0.rawValue }
        XCTAssertNotEqual(errorDescriptor, 2)
        try await error.close()

        // Closing the duplicates must not close the process's original standard descriptors.
        for descriptor in 0...2 {
            let copy = try FileDescriptor(rawValue: CInt(descriptor)).duplicate()
            try copy.close()
        }
    }

    func testScopedStandardHandles() async throws {
        try await FileSystem.shared.withStandardInput { input in
            let descriptor = try await input.withUnsafeDescriptor { $0.rawValue }
            XCTAssertNotEqual(descriptor, 0)
        }
        try await FileSystem.shared.withStandardOutput { output in
            let descriptor = try await output.withUnsafeDescriptor { $0.rawValue }
            XCTAssertNotEqual(descriptor, 1)
        }
        try await FileSystem.shared.withStandardError { error in
            let descriptor = try await error.withUnsafeDescriptor { $0.rawValue }
            XCTAssertNotEqual(descriptor, 2)
        }
    }

    func testScopedStandardOutputClosesOnThrow() async throws {
        struct ExpectedError: Error {}

        do {
            try await FileSystem.shared.withStandardOutput { _ in
                throw ExpectedError()
            }
            XCTFail("Expected the scoped operation to throw")
        } catch is ExpectedError {
            // The scoped handle was closed, but the process's stdout must still be open.
            let duplicate = try FileDescriptor(rawValue: 1).duplicate()
            try duplicate.close()
        }
    }

    func testSequentialIOIgnoresOffsetsOnPipe() async throws {
        #if canImport(Darwin) || canImport(Glibc)
        var descriptors: [CInt] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            XCTFail("Failed to create a pipe")
            return
        }

        let reader = SystemFileHandle(
            takingOwnershipOf: FileDescriptor(rawValue: descriptors[0]),
            path: "test-pipe-read",
            threadPool: .singleton,
            usesSequentialIO: true
        )
        let writer = SystemFileHandle(
            takingOwnershipOf: FileDescriptor(rawValue: descriptors[1]),
            path: "test-pipe-write",
            threadPool: .singleton,
            usesSequentialIO: true
        )

        do {
            let firstWrite = try await writer.write(contentsOf: Array("ab".utf8), toAbsoluteOffset: 0)
            let secondWrite = try await writer.write(contentsOf: Array("cd".utf8), toAbsoluteOffset: 2)
            XCTAssertEqual(firstWrite, 2)
            XCTAssertEqual(secondWrite, 2)
            let first = try await reader.readChunk(fromAbsoluteOffset: 0, length: .bytes(2))
            let second = try await reader.readChunk(fromAbsoluteOffset: 2, length: .bytes(2))
            XCTAssertEqual(Array(first.readableBytesView), Array("ab".utf8))
            XCTAssertEqual(Array(second.readableBytesView), Array("cd".utf8))
            try await writer.close()
            try await reader.close()
        } catch {
            try? await writer.close()
            try? await reader.close()
            throw error
        }
        #else
        throw XCTSkip("Pipe tests require a POSIX platform")
        #endif
    }
}
