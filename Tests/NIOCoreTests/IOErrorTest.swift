//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

//
import XCTest

@testable import NIOCore

#if os(Windows)
import WinSDK
#endif

class IOErrorTest: XCTestCase {
    func testMemoryLayoutBelowThreshold() {
        XCTAssert(MemoryLayout<IOError>.size <= 24)
    }

    @available(*, deprecated, message: "deprecated because it tests deprecated functionality")
    func testDeprecatedAPIStillFunctional() {
        XCTAssertNoThrow(IOError(errnoCode: 1, function: "anyFunc"))
    }

    #if os(Windows)
    func testWinsockErrorsReportTheEquivalentErrno() {
        // A representative sample rather than the whole table: the ones NIO itself compares
        // against when classifying errors.
        let equivalents: [(CInt, CInt)] = [
            (WSAEMSGSIZE, EMSGSIZE),
            (WSAEHOSTUNREACH, EHOSTUNREACH),
            (WSAEAFNOSUPPORT, EAFNOSUPPORT),
            (WSAECONNREFUSED, ECONNREFUSED),
            (WSAECONNRESET, ECONNRESET),
            (WSAEBADF, EBADF),
            (WSAEINVAL, EINVAL),
            (WSAEWOULDBLOCK, EWOULDBLOCK),
        ]
        for (winsock, expected) in equivalents {
            XCTAssertEqual(
                IOError(winsock: winsock, reason: "test").errnoCode,
                expected,
                "winsock error \(winsock) should report errno \(expected)"
            )
        }
    }

    func testWinsockErrorWithoutAnErrnoEquivalentIsReportedUnchanged() {
        // `WSAEDISCON` has no `errno` counterpart, so it is passed through. It cannot be
        // confused with an `errno`, which never exceeds 140 on Windows.
        let error = IOError(winsock: WSAEDISCON, reason: "test")
        XCTAssertEqual(error.errnoCode, WSAEDISCON)
        XCTAssertGreaterThan(error.errnoCode, 140)
    }

    func testWindowsDomainErrorIsReportedUnchanged() {
        let error = IOError(windows: DWORD(ERROR_FILE_NOT_FOUND), reason: "test")
        XCTAssertEqual(error.errnoCode, ERROR_FILE_NOT_FOUND)
    }

    func testErrnoDomainErrorIsUnaffected() {
        XCTAssertEqual(IOError(errnoCode: ENOENT, reason: "test").errnoCode, ENOENT)
    }
    #endif
}
