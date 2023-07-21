//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
#if canImport(Darwin) || os(Linux)
import XCTest
@testable import NIOCore
@testable import NIOPosix

class VsockAddressTest: XCTestCase {

    func testDescriptionWorks() throws {
        XCTAssertEqual(VsockAddress(cid: .host, port: 12345).description, "[VSOCK]2:12345")
        XCTAssertEqual(VsockAddress(cid: .any, port: 12345).description, "[VSOCK]-1:12345")
    }

    func testSocketAddressEqualitySpecialValues() throws {
        XCTAssertEqual(VsockAddress(cid: .any, port: 12345), .init(cid: UInt32(bitPattern: -1), port: 12345))
        XCTAssertEqual(VsockAddress(cid: .hypervisor, port: 12345), .init(cid: 0, port: 12345))
        XCTAssertEqual(VsockAddress(cid: .host, port: 12345), .init(cid: 2, port: 12345))
    }

    func testSocketAddressEquality() throws {
        XCTAssertEqual(VsockAddress(cid: 0, port: 0), .init(cid: 0, port: 0))
        XCTAssertEqual(VsockAddress(cid: 1, port: 0), .init(cid: 1, port: 0))
        XCTAssertEqual(VsockAddress(cid: 0, port: 1), .init(cid: 0, port: 1))

        XCTAssertNotEqual(VsockAddress(cid: 0, port: 0), .init(cid: 1, port: 0))
        XCTAssertNotEqual(VsockAddress(cid: 0, port: 0), .init(cid: 0, port: 1))
    }
}

#endif
