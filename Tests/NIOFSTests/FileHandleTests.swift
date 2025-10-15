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

@_spi(Testing) import NIOFS
import NIOPosix
import XCTest

#if ENABLE_MOCKING
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
internal final class FileHandleTests: XCTestCase {
    private func withHandleForMocking(
        path: FilePath = "/probably/does/not/exist",
        _ execute: (SystemFileHandle, MockingDriver) throws -> Void
    ) async throws {
        #if ENABLE_MOCKING
        // The executor is required to create the handle, we won't do any async work if we're
        // mocking as the driver requires synchronous code (as it uses thread local storage).
        let threadPool = NIOThreadPool(numberOfThreads: 1)
        try! await threadPool.shutdownGracefully()

        // Not a real descriptor.
        let descriptor = FileDescriptor(rawValue: -1)
        let handle = SystemFileHandle(takingOwnershipOf: descriptor, path: path, threadPool: threadPool)
        defer {
            // Not a 'real' descriptor so just detach to avoid "leaking" the descriptor and
            // trapping in the deinit of handle.
            XCTAssertNoThrow(try handle.detachUnsafeFileDescriptor())
        }

        try MockingDriver.withMockingEnabled { driver in
            try execute(handle, driver)
        }
        #else
        throw XCTSkip("Mocking is not enabled (via 'ENABLE_MOCKING')")
        #endif
    }

    /// A test case which mocks system calls made by the a file handle.
    private struct MockHandleTest {
        /// The function to run which makes a system call.
        var fn: (SystemFileHandle) throws -> Void

        /// The name of the system call being made. This is used to verify information provided
        /// in expected errors.
        var systemCall: String

        /// Errnos which when emitted by the system are not expected to result in errors being
        /// thrown.
        var nonThrowingErrnos: [Errno]

        /// Errnos which map to known file system error codes.
        var knownErrnos: [Errno: FileSystemError.Code]

        /// Errnos with no known mapping to file system error codes.
        var unknownErrnos: [Errno]

        init<R>(
            expectedSystemCall: String,
            nonThrowingErrnos: [Errno] = [],
            knownErrnos: [Errno: FileSystemError.Code] = [:],
            unknownErrnos: [Errno] = [],
            expression: @escaping (SystemFileHandle) throws -> R
        ) {
            self.systemCall = expectedSystemCall
            self.nonThrowingErrnos = nonThrowingErrnos
            self.knownErrnos = knownErrnos
            self.unknownErrnos = unknownErrnos
            self.fn = { _ = try expression($0) }

            // Verify that EBADF results in the '.closed' status.
            let existing = self.knownErrnos.updateValue(.closed, forKey: .badFileDescriptor)
            assert(existing == nil)
        }
    }

    private func run(_ test: MockHandleTest) async throws {
        try await self.withHandleForMocking { handle, driver in
            // No errno should not throw an error.
            try driver.testNoErrnoDoesNotThrow(try test.fn(handle))

            // Some errnos are safe to ignore and should not throw.
            for errno in test.nonThrowingErrnos {
                try driver.testNoErrnoDoesNotThrow(errno)
            }

            // Each of these should result in an known status code.
            for (errno, code) in test.knownErrnos {
                try driver.testErrnoThrowsError(errno, try test.fn(handle)) { error in
                    XCTAssertEqual(
                        error.code,
                        code,
                        """
                        \(test.systemCall) throwing \(errno) resulted in '\(error.code)',\
                        expected '\(code)'.
                        """
                    )
                    XCTAssertSystemCallError(error.cause, name: test.systemCall, errno: errno)
                }
            }

            // Each of these should result in an unknown status code.
            for errno in test.unknownErrnos {
                try driver.testErrnoThrowsError(errno, try test.fn(handle)) { error in
                    XCTAssertEqual(error.code, .unknown)
                    XCTAssertEqual(
                        error.code,
                        .unknown,
                        """
                        \(test.systemCall) throwing \(errno) resulted in '\(error.code)',\
                        expected 'unknown'.
                        """
                    )
                    XCTAssertSystemCallError(error.cause, name: test.systemCall, errno: errno)
                }
            }
        }
    }

    func testInfo() async throws {
        let testCase = MockHandleTest(
            expectedSystemCall: "fstat",
            unknownErrnos: [.deadlock, .ioError]
        ) { handle in
            try handle.sendableView._info().get()
        }

        try await self.run(testCase)
    }

    func testReplacePermissions() async throws {
        let testCase = MockHandleTest(
            expectedSystemCall: "fchmod",
            knownErrnos: [
                .invalidArgument: .invalidArgument,
                .notPermitted: .permissionDenied,
            ],
            unknownErrnos: [.deadlock, .ioError]
        ) { handle in
            try handle.sendableView._replacePermissions(.groupRead)
        }

        try await self.run(testCase)
    }

    func testListAttributeNames() async throws {
        let testCase = MockHandleTest(
            expectedSystemCall: "flistxattr",
            knownErrnos: [
                .notSupported: .unsupported,
                .notPermitted: .unsupported,
                .permissionDenied: .permissionDenied,
            ],
            unknownErrnos: [.deadlock, .ioError]
        ) { handle in
            try handle.sendableView._attributeNames()
        }

        try await self.run(testCase)
    }

    func testValueForAttribute() async throws {
        var nonThrowingErrnos: [Errno] = [.noData]
        var knownErrnos: [Errno: FileSystemError.Code] = [.notSupported: .unsupported]
        #if canImport(Darwin)
        nonThrowingErrnos.append(.attributeNotFound)
        knownErrnos[.fileNameTooLong] = .invalidArgument
        #endif

        let testCase = MockHandleTest(
            expectedSystemCall: "fgetxattr",
            nonThrowingErrnos: nonThrowingErrnos,
            knownErrnos: knownErrnos,
            unknownErrnos: [.deadlock, .ioError]
        ) { handle in
            try handle.sendableView._valueForAttribute("foobar")
        }

        try await self.run(testCase)
    }

    func testSynchronize() async throws {
        let testCase = MockHandleTest(
            expectedSystemCall: "fsync",
            knownErrnos: [.ioError: .io],
            unknownErrnos: [.deadlock, .addressInUse]
        ) { handle in
            try handle.sendableView._synchronize()
        }

        try await self.run(testCase)
    }

    func testUpdateValueForAttribute() async throws {
        var knownErrnos: [Errno: FileSystemError.Code] = [
            .notSupported: .unsupported,
            .invalidArgument: .invalidArgument,
        ]
        #if canImport(Darwin)
        knownErrnos[.fileNameTooLong] = .invalidArgument
        #endif

        let testCase = MockHandleTest(
            expectedSystemCall: "fsetxattr",
            knownErrnos: knownErrnos,
            unknownErrnos: [.deadlock, .ioError]
        ) { handle in
            try handle.sendableView._updateValueForAttribute([0, 1, 2, 4], attribute: "foobar")
        }

        try await self.run(testCase)
    }

    func testRemoveValueForAttribute() async throws {
        var knownErrnos: [Errno: FileSystemError.Code] = [.notSupported: .unsupported]
        #if canImport(Darwin)
        knownErrnos[.fileNameTooLong] = .invalidArgument
        #endif

        let testCase = MockHandleTest(
            expectedSystemCall: "fremovexattr",
            knownErrnos: knownErrnos,
            unknownErrnos: [.deadlock, .ioError]
        ) { handle in
            try handle.sendableView._removeValueForAttribute("foobar")
        }

        try await self.run(testCase)
    }
}

extension MockingDriver {
    fileprivate func testNoErrnoDoesNotThrow<R>(
        _ expression: @autoclosure () throws -> R,
        line: UInt = #line
    ) throws {
        self.forceErrno = .none
        XCTAssertNoThrow(try expression(), line: line)
    }

    fileprivate func testErrnoDoesNotThrowError<R>(
        _ errno: Errno,
        _ expression: @autoclosure () throws -> R,
        line: UInt = #line
    ) throws {
        self.forceErrno = .always(errno: errno.rawValue)
        XCTAssertNoThrow(try expression(), line: line)
    }

    fileprivate func testErrnoThrowsError<R>(
        _ errno: Errno,
        _ expression: @autoclosure () throws -> R,
        line: UInt = #line,
        onError: (FileSystemError) -> Void
    ) throws {
        self.forceErrno = .always(errno: errno.rawValue)
        XCTAssertThrowsFileSystemError(try expression(), line: line) { error in
            onError(error)
        }
    }
}
#endif
