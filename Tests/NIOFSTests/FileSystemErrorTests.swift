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
import XCTest

final class FileSystemErrorTests: XCTestCase {
    func testFileSystemErrorCustomStringConvertible() throws {
        var error = FileSystemError(
            code: .unsupported,
            message: "An error message.",
            cause: nil,
            location: .init(function: "fn(_:)", file: "file.swift", line: 42)
        )

        XCTAssertEqual(String(describing: error), "Unsupported: An error message.")

        struct SomeCausalInfo: Error {}
        error.cause = SomeCausalInfo()

        XCTAssertEqual(
            String(describing: error),
            "Unsupported: An error message. (SomeCausalInfo())"
        )
    }

    func testFileSystemErrorCustomDebugStringConvertible() throws {
        var error = FileSystemError(
            code: .permissionDenied,
            message: "An error message.",
            cause: nil,
            location: .init(function: "fn(_:)", file: "file.swift", line: 42)
        )

        XCTAssertEqual(
            String(reflecting: error),
            """
            Permission denied: "An error message."
            """
        )

        struct SomeCausalInfo: Error, CustomStringConvertible, CustomDebugStringConvertible {
            var description: String { "SomeCausalInfo()" }
            var debugDescription: String {
                String(reflecting: self.description)
            }
        }
        error.cause = SomeCausalInfo()

        XCTAssertEqual(
            String(reflecting: error),
            """
            Permission denied: "An error message." ("SomeCausalInfo()")
            """
        )
    }

    func testFileSystemErrorDetailedDescription() throws {
        var error = FileSystemError(
            code: .permissionDenied,
            message: "An error message.",
            cause: nil,
            location: .init(function: "fn(_:)", file: "file.swift", line: 42)
        )

        XCTAssertEqual(
            error.detailedDescription(),
            """
            FileSystemError: Permission denied
            ├─ Reason: An error message.
            └─ Source location: fn(_:) (file.swift:42)
            """
        )

        struct SomeCausalInfo: Error, CustomStringConvertible {
            var description: String { "SomeCausalInfo()" }
        }
        error.cause = SomeCausalInfo()

        XCTAssertEqual(
            error.detailedDescription(),
            """
            FileSystemError: Permission denied
            ├─ Reason: An error message.
            ├─ Cause: SomeCausalInfo()
            └─ Source location: fn(_:) (file.swift:42)
            """
        )
    }

    func testFileSystemErrorCustomDebugStringConvertibleWithNestedCause() throws {
        let location = FileSystemError.SourceLocation(
            function: "fn(_:)",
            file: "file.swift",
            line: 42
        )

        let subCause = FileSystemError(
            code: .notFound,
            message: "Where did I put that?",
            cause: FileSystemError.SystemCallError(systemCall: "close", errno: .badFileDescriptor),
            location: location
        )

        let cause = FileSystemError(
            code: .invalidArgument,
            message: "Can't close a file which is already closed.",
            cause: subCause,
            location: location
        )

        let error = FileSystemError(
            code: .permissionDenied,
            message: "I'm afraid I can't let you do that Dave.",
            cause: cause,
            location: location
        )

        XCTAssertEqual(
            error.detailedDescription(),
            """
            FileSystemError: Permission denied
            ├─ Reason: I'm afraid I can't let you do that Dave.
            ├─ Cause:
            │  └─ FileSystemError: Invalid argument
            │     ├─ Reason: Can't close a file which is already closed.
            │     ├─ Cause:
            │     │  └─ FileSystemError: Not found
            │     │     ├─ Reason: Where did I put that?
            │     │     ├─ Cause: 'close' system call failed with '(9) Bad file descriptor'.
            │     │     └─ Source location: fn(_:) (file.swift:42)
            │     └─ Source location: fn(_:) (file.swift:42)
            └─ Source location: fn(_:) (file.swift:42)
            """
        )
    }

    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    func testErrorsMapToCorrectSyscallCause() throws {
        let here = FileSystemError.SourceLocation(function: "fn", file: "file", line: 42)
        let path = FilePath("/foo")

        for statName in ["stat", "lstat", "fstat"] {
            assertCauseIsSyscall(statName, here) {
                .stat(statName, errno: .badFileDescriptor, path: path, location: here)
            }
        }

        assertCauseIsSyscall("fchmod", here) {
            .fchmod(
                operation: .add,
                operand: [],
                permissions: [],
                errno: .badFileDescriptor,
                path: path,
                location: here
            )
        }

        assertCauseIsSyscall("flistxattr", here) {
            .flistxattr(errno: .badFileDescriptor, path: path, location: here)
        }

        assertCauseIsSyscall("fgetxattr", here) {
            .fgetxattr(attribute: "attr", errno: .badFileDescriptor, path: path, location: here)
        }

        assertCauseIsSyscall("fsetxattr", here) {
            .fsetxattr(attribute: "attr", errno: .badFileDescriptor, path: path, location: here)
        }

        assertCauseIsSyscall("fremovexattr", here) {
            .fremovexattr(attribute: "attr", errno: .badFileDescriptor, path: path, location: here)
        }

        assertCauseIsSyscall("fsync", here) {
            .fsync(errno: .badFileDescriptor, path: path, location: here)
        }

        assertCauseIsSyscall("dup", here) {
            .dup(error: Errno.badFileDescriptor, path: path, location: here)
        }

        assertCauseIsSyscall("close", here) {
            .close(error: Errno.badFileDescriptor, path: path, location: here)
        }

        assertCauseIsSyscall("read", here) {
            .read(usingSyscall: .read, error: Errno.badFileDescriptor, path: path, location: here)
        }

        assertCauseIsSyscall("pread", here) {
            .read(usingSyscall: .pread, error: Errno.badFileDescriptor, path: path, location: here)
        }

        assertCauseIsSyscall("write", here) {
            .write(usingSyscall: .write, error: Errno.badFileDescriptor, path: path, location: here)
        }

        assertCauseIsSyscall("pwrite", here) {
            .write(usingSyscall: .pwrite, error: Errno.badFileDescriptor, path: path, location: here)
        }

        assertCauseIsSyscall("fdopendir", here) {
            .fdopendir(errno: .badFileDescriptor, path: path, location: here)
        }

        assertCauseIsSyscall("readdir", here) {
            .readdir(errno: .badFileDescriptor, path: path, location: here)
        }

        assertCauseIsSyscall("openat", here) {
            .open("openat", error: Errno.badFileDescriptor, path: path, location: here)
        }

        assertCauseIsSyscall("mkdir", here) {
            .mkdir(errno: .badFileDescriptor, path: path, location: here)
        }

        assertCauseIsSyscall("rename", here) {
            .rename("rename", errno: .badFileDescriptor, oldName: "old", newName: "new", location: here)
        }

        assertCauseIsSyscall("remove", here) {
            .remove(errno: .badFileDescriptor, path: path, location: here)
        }

        assertCauseIsSyscall("symlink", here) {
            .symlink(errno: .badFileDescriptor, link: "link", target: "target", location: here)
        }

        assertCauseIsSyscall("unlink", here) {
            .unlink(errno: .badFileDescriptor, path: "unlink", location: here)
        }

        assertCauseIsSyscall("readlink", here) {
            .readlink(errno: .badFileDescriptor, path: "link", location: here)
        }

        assertCauseIsSyscall("getcwd", here) {
            .getcwd(errno: .badFileDescriptor, location: here)
        }

        assertCauseIsSyscall("confstr", here) {
            .confstr(name: "foo", errno: .badFileDescriptor, location: here)
        }

        assertCauseIsSyscall("fcopyfile", here) {
            .fcopyfile(errno: .badFileDescriptor, from: "src", to: "dst", location: here)
        }

        assertCauseIsSyscall("copyfile", here) {
            .copyfile(errno: .badFileDescriptor, from: "src", to: "dst", location: here)
        }

        assertCauseIsSyscall("sendfile", here) {
            .sendfile(errno: .badFileDescriptor, from: "src", to: "dst", location: here)
        }

        assertCauseIsSyscall("ftruncate", here) {
            .ftruncate(error: Errno.badFileDescriptor, path: path, location: here)
        }
    }

    func testErrnoMapping_stat() {
        self.testErrnoToErrorCode(
            expected: [
                .badFileDescriptor: .closed
            ]
        ) { errno in
            .stat("stat", errno: errno, path: "path", location: .fixed)
        }
    }

    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    func testErrnoMapping_fchmod() {
        self.testErrnoToErrorCode(
            expected: [
                .badFileDescriptor: .closed,
                .invalidArgument: .invalidArgument,
                .notPermitted: .permissionDenied,
            ]
        ) { errno in
            .fchmod(
                operation: .add,
                operand: [],
                permissions: [],
                errno: errno,
                path: "",
                location: .fixed
            )
        }
    }

    func testErrnoMapping_flistxattr() {
        self.testErrnoToErrorCode(
            expected: [
                .badFileDescriptor: .closed,
                .notSupported: .unsupported,
                .notPermitted: .unsupported,
                .permissionDenied: .permissionDenied,
            ]
        ) { errno in
            .flistxattr(errno: errno, path: "", location: .fixed)
        }
    }

    func testErrnoMapping_fgetxattr() {
        self.testErrnoToErrorCode(
            expected: [
                .badFileDescriptor: .closed,
                .notSupported: .unsupported,
            ]
        ) { errno in
            .fgetxattr(attribute: "attr", errno: errno, path: "", location: .fixed)
        }
    }

    func testErrnoMapping_fsetxattr() {
        self.testErrnoToErrorCode(
            expected: [
                .badFileDescriptor: .closed,
                .notSupported: .unsupported,
                .invalidArgument: .invalidArgument,
            ]
        ) { errno in
            .fsetxattr(attribute: "attr", errno: errno, path: "", location: .fixed)
        }
    }

    func testErrnoMapping_fremovexattr() {
        self.testErrnoToErrorCode(
            expected: [
                .badFileDescriptor: .closed,
                .notSupported: .unsupported,
            ]
        ) { errno in
            .fremovexattr(attribute: "attr", errno: errno, path: "", location: .fixed)
        }
    }

    func testErrnoMapping_fsync() {
        self.testErrnoToErrorCode(
            expected: [
                .badFileDescriptor: .closed,
                .ioError: .io,
            ]
        ) { errno in
            .fsync(errno: errno, path: "", location: .fixed)
        }
    }

    func testErrnoMapping_dup() {
        self.testErrnoToErrorCode(
            expected: [
                .badFileDescriptor: .closed
            ]
        ) { errno in
            .dup(error: errno, path: "", location: .fixed)
        }
    }

    func testErrnoMapping_close() {
        self.testErrnoToErrorCode(
            expected: [
                .badFileDescriptor: .closed,
                .ioError: .io,
            ]
        ) { errno in
            .close(error: errno, path: "", location: .fixed)
        }
    }

    func testErrnoMapping_read() {
        self.testErrnoToErrorCode(
            expected: [
                .badFileDescriptor: .closed,
                .ioError: .io,
            ]
        ) { errno in
            .read(usingSyscall: .read, error: errno, path: "", location: .fixed)
        }
    }

    func testErrnoMapping_pread() {
        self.testErrnoToErrorCode(
            expected: [
                .badFileDescriptor: .closed,
                .ioError: .io,
                .illegalSeek: .unsupported,
            ]
        ) { errno in
            .read(usingSyscall: .pread, error: errno, path: "", location: .fixed)
        }
    }

    func testErrnoMapping_write() {
        self.testErrnoToErrorCode(
            expected: [
                .badFileDescriptor: .closed,
                .ioError: .io,
            ]
        ) { errno in
            .write(usingSyscall: .write, error: errno, path: "", location: .fixed)
        }
    }

    func testErrnoMapping_pwrite() {
        self.testErrnoToErrorCode(
            expected: [
                .badFileDescriptor: .closed,
                .ioError: .io,
                .illegalSeek: .unsupported,
            ]
        ) { errno in
            .write(usingSyscall: .pwrite, error: errno, path: "", location: .fixed)
        }
    }

    func testErrnoMapping_open() {
        self.testErrnoToErrorCode(
            expected: [
                .badFileDescriptor: .closed,
                .permissionDenied: .permissionDenied,
                .fileExists: .fileAlreadyExists,
                .ioError: .io,
                .tooManyOpenFiles: .unavailable,
                .noSuchFileOrDirectory: .notFound,
                .notDirectory: .notFound,
            ]
        ) { errno in
            .open("open", error: errno, path: "", location: .fixed)
        }
    }

    func testErrnoMapping_mkdir() {
        self.testErrnoToErrorCode(
            expected: [
                .permissionDenied: .permissionDenied,
                .isDirectory: .invalidArgument,
                .notDirectory: .invalidArgument,
                .noSuchFileOrDirectory: .invalidArgument,
                .ioError: .io,
                .fileExists: .fileAlreadyExists,
            ]
        ) { errno in
            .mkdir(errno: errno, path: "", location: .fixed)
        }
    }

    func testErrnoMapping_rename() {
        self.testErrnoToErrorCode(
            expected: [
                .permissionDenied: .permissionDenied,
                .invalidArgument: .invalidArgument,
                .noSuchFileOrDirectory: .notFound,
                .ioError: .io,
            ]
        ) { errno in
            .rename("rename", errno: errno, oldName: "old", newName: "new", location: .fixed)
        }
    }

    func testErrnoMapping_remove() {
        self.testErrnoToErrorCode(
            expected: [
                .permissionDenied: .permissionDenied,
                .notPermitted: .permissionDenied,
                .resourceBusy: .unavailable,
                .ioError: .io,
            ]
        ) { errno in
            .remove(errno: errno, path: "", location: .fixed)
        }
    }

    func testErrnoMapping_symlink() {
        self.testErrnoToErrorCode(
            expected: [
                .permissionDenied: .permissionDenied,
                .notPermitted: .permissionDenied,
                .fileExists: .fileAlreadyExists,
                .noSuchFileOrDirectory: .invalidArgument,
                .notDirectory: .invalidArgument,
                .ioError: .io,
            ]
        ) { errno in
            .symlink(errno: errno, link: "link", target: "target", location: .fixed)
        }
    }

    func testErrnoMapping_unlink() {
        self.testErrnoToErrorCode(
            expected: [
                .permissionDenied: .permissionDenied,
                .notPermitted: .permissionDenied,
                .noSuchFileOrDirectory: .notFound,
                .ioError: .io,
            ]
        ) { errno in
            .unlink(errno: errno, path: "path", location: .fixed)
        }
    }

    func testErrnoMapping_readlink() {
        self.testErrnoToErrorCode(
            expected: [
                .permissionDenied: .permissionDenied,
                .invalidArgument: .invalidArgument,
                .noSuchFileOrDirectory: .notFound,
                .ioError: .io,
            ]
        ) { errno in
            .readlink(errno: errno, path: "", location: .fixed)
        }
    }

    func testErrnoMapping_copyfile() {
        self.testErrnoToErrorCode(
            expected: [
                .notSupported: .invalidArgument,
                .permissionDenied: .permissionDenied,
                .invalidArgument: .invalidArgument,
                .fileExists: .fileAlreadyExists,
                .tooManyOpenFiles: .unavailable,
                .noSuchFileOrDirectory: .notFound,
            ]
        ) { errno in
            .copyfile(errno: errno, from: "src", to: "dst", location: .fixed)
        }
    }

    func testErrnoMapping_fcopyfile() {
        self.testErrnoToErrorCode(
            expected: [
                .notSupported: .invalidArgument,
                .invalidArgument: .invalidArgument,
                .permissionDenied: .permissionDenied,
            ]
        ) { errno in
            .fcopyfile(errno: errno, from: "src", to: "dst", location: .fixed)
        }
    }

    func testErrnoMapping_sendfile() {
        self.testErrnoToErrorCode(
            expected: [
                .ioError: .io,
                .noMemory: .io,
            ]
        ) { errno in
            .sendfile(errno: errno, from: "src", to: "dst", location: .fixed)
        }
    }

    func testErrnoMapping_resize() {
        self.testErrnoToErrorCode(
            expected: [
                .badFileDescriptor: .closed,
                .fileTooLarge: .invalidArgument,
                .invalidArgument: .invalidArgument,
            ]
        ) { errno in
            .ftruncate(error: errno, path: "", location: .fixed)
        }
    }

    func testErrnoMapping_futimens() {
        self.testErrnoToErrorCode(
            expected: [
                .permissionDenied: .permissionDenied,
                .notPermitted: .permissionDenied,
                .readOnlyFileSystem: .unsupported,
                .badFileDescriptor: .closed,
            ]
        ) { errno in
            .futimens(errno: errno, path: "", lastAccessTime: nil, lastDataModificationTime: nil, location: .fixed)
        }
    }

    private func testErrnoToErrorCode(
        expected mapping: [Errno: FileSystemError.Code],
        _ makeError: (Errno) -> FileSystemError
    ) {
        for (errno, code) in mapping {
            let error = makeError(errno)
            XCTAssertEqual(error.code, code, "\(error)")
        }

        let errno = Errno(rawValue: -1)
        let error = makeError(errno)
        XCTAssertEqual(error.code, .unknown, "\(error)")
    }
}

private func assertCauseIsSyscall(
    _ name: String,
    _ location: FileSystemError.SourceLocation,
    _ buildError: () -> FileSystemError
) {
    let error = buildError()

    XCTAssertEqual(error.location, location)
    if let cause = error.cause as? FileSystemError.SystemCallError {
        XCTAssertEqual(cause.systemCall, name)
    } else {
        XCTFail("Unexpected error: \(String(describing: error.cause))")
    }
}

extension FileSystemError.SourceLocation {
    fileprivate static let fixed = Self(function: "fn", file: "file", line: 1)
}
