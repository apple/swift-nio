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

#if os(Windows)
import NIOCore
import WinSDK
import XCTest

@testable import NIOPosix

final class BSDSocketAPIWindowsTests: XCTestCase {
    func testWinsockSyscallReturnsWouldBlock() throws {
        let result: IOResult<CInt> = try NIOBSDSocket.winsockSyscall {
            WSASetLastError(WSAEWOULDBLOCK)
            return SOCKET_ERROR
        }

        XCTAssertEqual(.wouldBlock(0), result)
    }

    func testWinsockSyscallThrowsOtherErrors() {
        let errorCode = WSAECONNRESET
        let call: () throws -> IOResult<CInt> = {
            try NIOBSDSocket.winsockSyscall {
                WSASetLastError(errorCode)
                return SOCKET_ERROR
            }
        }

        XCTAssertThrowsError(try call()) { error in
            guard let ioError = error as? IOError else {
                return XCTFail("Expected IOError, got \(error)")
            }
            guard case .winsock(let actualErrorCode) = ioError.error else {
                return XCTFail("Expected a Winsock error, got \(ioError)")
            }
            XCTAssertEqual(errorCode, actualErrorCode)
        }
    }

    func testWinsockSyscallWithTransferredCountReturnsProcessed() throws {
        let result: IOResult<Int> = try NIOBSDSocket.winsockSyscall { transferred in
            transferred = 42
            return 0
        }

        XCTAssertEqual(.processed(42), result)
    }

    func testWinsockSyscallWithTransferredCountIgnoresGarbageWhenWouldBlock() throws {
        let result: IOResult<Int> = try NIOBSDSocket.winsockSyscall { transferred in
            transferred = .max
            WSASetLastError(WSAEWOULDBLOCK)
            return SOCKET_ERROR
        }

        XCTAssertEqual(.wouldBlock(0), result)
    }

    func testWinsockSyscallWithTransferredCountThrowsOtherErrors() {
        let errorCode = WSAECONNRESET
        let call: () throws -> IOResult<Int> = {
            try NIOBSDSocket.winsockSyscall { transferred in
                transferred = 42
                WSASetLastError(errorCode)
                return SOCKET_ERROR
            }
        }

        XCTAssertThrowsError(try call()) { error in
            guard let ioError = error as? IOError else {
                return XCTFail("Expected IOError, got \(error)")
            }
            guard case .winsock(let actualErrorCode) = ioError.error else {
                return XCTFail("Expected a Winsock error, got \(ioError)")
            }
            XCTAssertEqual(errorCode, actualErrorCode)
        }
    }
}
#endif
