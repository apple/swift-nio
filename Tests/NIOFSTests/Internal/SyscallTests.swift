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

import CNIOLinux
@_spi(Testing) import NIOFS
import SystemPackage
import XCTest

#if ENABLE_MOCKING
final class SyscallTests: XCTestCase {
    func test_openat() throws {
        let fd = FileDescriptor(rawValue: 42)
        let testCases = [
            MockTestCase(
                name: "fdopenat",
                .interruptable,
                fd.rawValue,
                "a path",
                O_RDONLY | O_NONBLOCK
            ) { retryOnInterrupt in
                _ = try fd.open(
                    atPath: "a path",
                    mode: .readOnly,
                    options: [.nonBlocking],
                    permissions: nil,
                    retryOnInterrupt: retryOnInterrupt
                ).get()
            },

            MockTestCase(
                name: "fdopenat",
                .interruptable,
                fd.rawValue,
                "a path",
                O_WRONLY | O_CREAT,
                0o777
            ) { retryOnInterrupt in
                _ = try fd.open(
                    atPath: "a path",
                    mode: .writeOnly,
                    options: [.create],
                    permissions: [
                        .groupReadWriteExecute, .ownerReadWriteExecute, .otherReadWriteExecute,
                    ],
                    retryOnInterrupt: retryOnInterrupt
                ).get()
            },

        ]

        testCases.run()
    }

    func test_stat() throws {
        let testCases = [
            MockTestCase(name: "stat", .noInterrupt, "a path") { _ in
                _ = try Syscall.stat(path: "a path").get()
            },

            MockTestCase(name: "lstat", .noInterrupt, "a path") { _ in
                _ = try Syscall.lstat(path: "a path").get()
            },

            MockTestCase(name: "fstat", .noInterrupt, 42) { _ in
                _ = try FileDescriptor(rawValue: 42).status().get()
            },
        ]

        testCases.run()
    }

    func test_fchmod() throws {
        let fd = FileDescriptor(rawValue: 42)
        let permissions: FilePermissions = [
            .groupReadWriteExecute,
            .otherReadWriteExecute,
            .ownerReadWriteExecute,
        ]

        let testCases = [
            MockTestCase(name: "fchmod", .interruptable, 42, 0) { retryOnInterrupt in
                try fd.changeMode([], retryOnInterrupt: retryOnInterrupt).get()
            },

            MockTestCase(name: "fchmod", .interruptable, 42, 0o777) { retryOnInterrupt in
                try fd.changeMode(permissions, retryOnInterrupt: retryOnInterrupt).get()
            },
        ]

        testCases.run()
    }

    func test_fsync() throws {
        let fd = FileDescriptor(rawValue: 42)
        let testCases = [
            MockTestCase(name: "fsync", .interruptable, 42) { retryOnInterrupt in
                try fd.synchronize(retryOnInterrupt: retryOnInterrupt).get()
            }
        ]

        testCases.run()
    }

    func test_mkdir() throws {
        let testCases = [
            MockTestCase(name: "mkdir", .noInterrupt, "a path", 0) { _ in
                try Syscall.mkdir(at: "a path", permissions: []).get()
            },

            MockTestCase(name: "mkdir", .noInterrupt, "a path", 0o777) { _ in
                try Syscall.mkdir(
                    at: "a path",
                    permissions: [
                        .groupReadWriteExecute, .otherReadWriteExecute, .ownerReadWriteExecute,
                    ]
                ).get()
            },
        ]

        testCases.run()
    }

    func test_linkat() throws {
        #if canImport(Glibc) || canImport(Bionic)
        let fd1 = FileDescriptor(rawValue: 13)
        let fd2 = FileDescriptor(rawValue: 42)

        let testCases = [
            MockTestCase(name: "linkat", .noInterrupt, 13, "src", 42, "dst", 0) { _ in
                try Syscall.linkAt(
                    from: "src",
                    relativeTo: fd1,
                    to: "dst",
                    relativeTo: fd2,
                    flags: []
                ).get()
            },
            MockTestCase(name: "linkat", .noInterrupt, 13, "src", 42, "dst", 4096) { _ in
                try Syscall.linkAt(
                    from: "src",
                    relativeTo: fd1,
                    to: "dst",
                    relativeTo: fd2,
                    flags: [.emptyPath]
                ).get()
            },
        ]
        testCases.run()
        #else
        throw XCTSkip("'linkat' is only supported on Linux")
        #endif
    }

    func test_link() throws {
        let testCases = [
            MockTestCase(name: "link", .noInterrupt, "src", "dst") { _ in
                try Syscall.link(from: "src", to: "dst").get()
            }
        ]
        testCases.run()
    }

    func test_unlink() throws {
        let testCases = [
            MockTestCase(name: "unlink", .noInterrupt, "path") { _ in
                try Syscall.unlink(path: "path").get()
            }
        ]
        testCases.run()
    }

    func test_symlink() throws {
        let testCases = [
            MockTestCase(name: "symlink", .noInterrupt, "one", "two") { _ in
                try Syscall.symlink(to: "one", from: "two").get()
            }
        ]

        testCases.run()
    }

    func test_readlink() throws {
        let testCases = [
            MockTestCase(
                name: "readlink",
                .noInterrupt,
                "a path",
                "<buffer>",
                CInterop.maxPathLength
            ) { _ in
                _ = try Syscall.readlink(at: "a path").get()
            }
        ]

        testCases.run()
    }

    func test_flistxattr() throws {
        let fd = FileDescriptor(rawValue: 42)
        let buffer = UnsafeMutableBufferPointer<CInterop.PlatformChar>.allocate(capacity: 1024)
        defer { buffer.deallocate() }

        let testCases: [MockTestCase] = [
            MockTestCase(name: "flistxattr", .noInterrupt, 42, "nil", 0) { _ in
                _ = try fd.listExtendedAttributes(nil).get()
            },

            MockTestCase(name: "flistxattr", .noInterrupt, 42, "<buffer>", 1024) { _ in
                _ = try fd.listExtendedAttributes(buffer).get()
            },
        ]

        testCases.run()
    }

    func test_fgetxattr() throws {
        let fd = FileDescriptor(rawValue: 42)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1024, alignment: 1)
        defer { buffer.deallocate() }

        let testCases: [MockTestCase] = [
            MockTestCase(name: "fgetxattr", .noInterrupt, 42, "an attribute", "nil", 0) { _ in
                _ = try fd.getExtendedAttribute(named: "an attribute", buffer: nil).get()
            },

            MockTestCase(name: "fgetxattr", .noInterrupt, 42, "an attribute", "<buffer>", 1024) {
                _ in
                _ = try fd.getExtendedAttribute(named: "an attribute", buffer: buffer).get()
            },
        ]

        testCases.run()
    }

    func test_fsetxattr() throws {
        let fd = FileDescriptor(rawValue: 42)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1024, alignment: 1)
        defer { buffer.deallocate() }

        let testCases: [MockTestCase] = [
            MockTestCase(name: "fsetxattr", .noInterrupt, 42, "attr name", "nil", 0) { _ in
                _ = try fd.setExtendedAttribute(named: "attr name", to: nil).get()
            },

            MockTestCase(name: "fsetxattr", .noInterrupt, 42, "attr name", "<buffer>", 1024) { _ in
                _ = try fd.setExtendedAttribute(named: "attr name", to: .init(buffer)).get()
            },
        ]

        testCases.run()
    }

    func test_fremovexattr() throws {
        let fd = FileDescriptor(rawValue: 42)
        let testCases: [MockTestCase] = [
            MockTestCase(name: "fremovexattr", .noInterrupt, 42, "attr name") { _ in
                _ = try fd.removeExtendedAttribute("attr name").get()
            }
        ]
        testCases.run()
    }

    func test_rename() throws {
        let testCases: [MockTestCase] = [
            MockTestCase(name: "rename", .noInterrupt, "old", "new") { _ in
                try Syscall.rename(from: "old", to: "new").get()
            }
        ]
        testCases.run()
    }

    func test_renamex_np() throws {
        #if canImport(Darwin)
        let testCases: [MockTestCase] = [
            MockTestCase(name: "renamex_np", .noInterrupt, "foo", "bar", 0) { _ in
                _ = try Syscall.rename(from: "foo", to: "bar", options: []).get()
            },
            MockTestCase(name: "renamex_np", .noInterrupt, "bar", "baz", 2) { _ in
                _ = try Syscall.rename(from: "bar", to: "baz", options: [.swap]).get()
            },
            MockTestCase(name: "renamex_np", .noInterrupt, "bar", "baz", 4) { _ in
                _ = try Syscall.rename(from: "bar", to: "baz", options: [.exclusive]).get()
            },
            MockTestCase(name: "renamex_np", .noInterrupt, "bar", "baz", 2) { _ in
                _ = try Syscall.rename(from: "bar", to: "baz", options: [.swap]).get()
            },
            MockTestCase(name: "renamex_np", .noInterrupt, "bar", "baz", 6) { _ in
                _ = try Syscall.rename(from: "bar", to: "baz", options: [.exclusive, .swap]).get()
            },
        ]
        testCases.run()
        #else
        throw XCTSkip("'renamex_np' is only supported on Darwin")
        #endif
    }

    func test_renameat2() throws {
        #if canImport(Glibc) || canImport(Bionic)
        let fd1 = FileDescriptor(rawValue: 13)
        let fd2 = FileDescriptor(rawValue: 42)

        let testCases: [MockTestCase] = [
            MockTestCase(name: "renameat2", .noInterrupt, 13, "foo", 42, "bar", 0) { _ in
                _ = try Syscall.rename(
                    from: "foo",
                    relativeTo: fd1,
                    to: "bar",
                    relativeTo: fd2,
                    flags: []
                ).get()
            },
            MockTestCase(name: "renameat2", .noInterrupt, 13, "foo", 42, "bar", 1) { _ in
                _ = try Syscall.rename(
                    from: "foo",
                    relativeTo: fd1,
                    to: "bar",
                    relativeTo: fd2,
                    flags: [.exclusive]
                ).get()
            },
            MockTestCase(name: "renameat2", .noInterrupt, 13, "foo", 42, "bar", 2) { _ in
                _ = try Syscall.rename(
                    from: "foo",
                    relativeTo: fd1,
                    to: "bar",
                    relativeTo: fd2,
                    flags: [.swap]
                ).get()
            },
            MockTestCase(name: "renameat2", .noInterrupt, 13, "foo", 42, "bar", 3) { _ in
                _ = try Syscall.rename(
                    from: "foo",
                    relativeTo: fd1,
                    to: "bar",
                    relativeTo: fd2,
                    flags: [.swap, .exclusive]
                ).get()
            },
        ]
        testCases.run()
        #else
        throw XCTSkip("'renameat2' is only supported on Linux")
        #endif
    }

    func test_sendfile() throws {
        #if canImport(Glibc) || canImport(Bionic)
        let input = FileDescriptor(rawValue: 42)
        let output = FileDescriptor(rawValue: 1)

        let testCases: [MockTestCase] = [
            MockTestCase(name: "sendfile", .noInterrupt, 1, 42, 0, 1024) { _ in
                _ = try Syscall.sendfile(to: output, from: input, offset: 0, size: 1024).get()
            },
            MockTestCase(name: "sendfile", .noInterrupt, 1, 42, 100, 512) { _ in
                _ = try Syscall.sendfile(to: output, from: input, offset: 100, size: 512).get()
            },
        ]
        testCases.run()
        #else
        throw XCTSkip("'sendfile' is only supported on Linux")
        #endif
    }

    func test_fcopyfile() throws {
        #if canImport(Darwin)
        let input = FileDescriptor(rawValue: 42)
        let output = FileDescriptor(rawValue: 1)

        let testCases: [MockTestCase] = [
            MockTestCase(name: "fcopyfile", .noInterrupt, 42, 1, "nil", 0) { _ in
                try Libc.fcopyfile(from: input, to: output, state: nil, flags: 0).get()
            }
        ]
        testCases.run()
        #else
        throw XCTSkip("'fcopyfile' is only supported on Darwin")
        #endif
    }

    func test_copyfile() throws {
        #if canImport(Darwin)

        let testCases: [MockTestCase] = [
            MockTestCase(name: "copyfile", .noInterrupt, "foo", "bar", "nil", 0) { _ in
                try Libc.copyfile(from: "foo", to: "bar", state: nil, flags: 0).get()
            }
        ]
        testCases.run()
        #else
        throw XCTSkip("'copyfile' is only supported on Darwin")
        #endif
    }

    func test_remove() throws {
        let testCases: [MockTestCase] = [
            MockTestCase(name: "remove", .noInterrupt, "somepath") { _ in
                try Libc.remove("somepath").get()
            }
        ]
        testCases.run()
    }

    func test_futimens() throws {
        let fd = FileDescriptor(rawValue: 42)
        let times = timespec(tv_sec: 1, tv_nsec: 1)
        withUnsafePointer(to: times) { unsafeTimesPointer in
            let testCases = [
                MockTestCase(name: "futimens", .noInterrupt, 42, unsafeTimesPointer) { _ in
                    try Syscall.futimens(
                        fileDescriptor: fd,
                        times: unsafeTimesPointer
                    ).get()
                }
            ]
            testCases.run()
        }
    }

    func testValueOrErrno() throws {
        let r1: Result<Int, Errno> = valueOrErrno(retryOnInterrupt: false) {
            Errno._current = .addressInUse
            return -1
        }
        XCTAssertEqual(r1, .failure(.addressInUse))

        var shouldInterrupt = true
        let r2: Result<Int, Errno> = valueOrErrno(retryOnInterrupt: true) {
            if shouldInterrupt {
                shouldInterrupt = false
                Errno._current = .interrupted
                return -1
            } else {
                Errno._current = .permissionDenied
                return -1
            }
        }
        XCTAssertFalse(shouldInterrupt)
        XCTAssertEqual(r2, .failure(.permissionDenied))

        let r3: Result<Int, Errno> = valueOrErrno(retryOnInterrupt: false) { 0 }
        XCTAssertEqual(r3, .success(0))
    }

    func testNothingOrErrno() throws {
        let r1: Result<Void, Errno> = nothingOrErrno(retryOnInterrupt: false) {
            Errno._current = .addressInUse
            return -1
        }

        XCTAssertThrowsError(try r1.get()) { error in
            XCTAssertEqual(error as? Errno, .addressInUse)
        }

        var shouldInterrupt = true
        let r2: Result<Void, Errno> = nothingOrErrno(retryOnInterrupt: true) {
            if shouldInterrupt {
                shouldInterrupt = false
                Errno._current = .interrupted
                return -1
            } else {
                Errno._current = .permissionDenied
                return -1
            }
        }
        XCTAssertFalse(shouldInterrupt)
        XCTAssertThrowsError(try r2.get()) { error in
            XCTAssertEqual(error as? Errno, .permissionDenied)
        }

        let r3: Result<Void, Errno> = nothingOrErrno(retryOnInterrupt: false) { 0 }
        XCTAssertNoThrow(try r3.get())
    }

    func testOptionalValueOrErrno() throws {
        let r1: Result<String?, Errno> = optionalValueOrErrno(retryOnInterrupt: false) {
            Errno._current = .addressInUse
            return nil
        }
        XCTAssertEqual(r1, .failure(.addressInUse))

        var shouldInterrupt = true
        let r2: Result<String?, Errno> = optionalValueOrErrno(retryOnInterrupt: true) {
            if shouldInterrupt {
                shouldInterrupt = false
                Errno._current = .interrupted
                return nil
            } else {
                return "foo"
            }
        }
        XCTAssertFalse(shouldInterrupt)
        XCTAssertEqual(r2, .success("foo"))

        let r3: Result<String?, Errno> = optionalValueOrErrno(retryOnInterrupt: false) { "bar" }
        XCTAssertEqual(r3, .success("bar"))

        let r4: Result<String?, Errno> = optionalValueOrErrno(retryOnInterrupt: false) { nil }
        XCTAssertEqual(r4, .success(nil))
    }
}

extension Array where Element == MockTestCase {
    fileprivate func run() {
        for testCase in self {
            testCase.runAllTests()
        }
    }
}
#endif
