//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
@testable import NIO

class SocketAddressTest: XCTestCase {
    func testDescriptionWorks() throws {
        var ipv4SocketAddress = sockaddr_in()
        ipv4SocketAddress.sin_port = (12345 as UInt16).bigEndian
        let sa = SocketAddress(IPv4Address: ipv4SocketAddress, host: "foobar.com")
        XCTAssertEqual("[IPv4]foobar.com:12345", sa.description)
    }

    func testCanCreateIPv4AddressFromString() throws {
        let sa = try SocketAddress.ipAddress(string: "127.0.0.1", port: 80)
        let expectedAddress: [UInt8] = [0x7F, 0x00, 0x00, 0x01]
        switch sa {
        case .v4(let address):
            var addr = address.address
            let host = address.host
            XCTAssertEqual(host, "")
            XCTAssertEqual(addr.sin_family, sa_family_t(AF_INET))
            XCTAssertEqual(addr.sin_port, 80)
            expectedAddress.withUnsafeBytes { expectedPtr in
                withUnsafeBytes(of: &addr.sin_addr) { actualPtr in
                    let rc = memcmp(actualPtr.baseAddress!, expectedPtr.baseAddress!, MemoryLayout<in_addr>.size)
                    XCTAssertEqual(rc, 0)
                }
            }
        default:
            XCTFail("Invalid address: \(sa)")
        }
    }

    func testCanCreateIPv6AddressFromString() throws {
        let sa = try SocketAddress.ipAddress(string: "fe80::5", port: 443)
        let expectedAddress: [UInt8] = [0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05]
        switch sa {
        case .v6(let address):
            var addr = address.address
            let host = address.host
            XCTAssertEqual(host, "")
            XCTAssertEqual(addr.sin6_family, sa_family_t(AF_INET6))
            XCTAssertEqual(addr.sin6_port, 443)
            XCTAssertEqual(addr.sin6_scope_id, 0)
            XCTAssertEqual(addr.sin6_flowinfo, 0)
            expectedAddress.withUnsafeBytes { expectedPtr in
                withUnsafeBytes(of: &addr.sin6_addr) { actualPtr in
                    let rc = memcmp(actualPtr.baseAddress!, expectedPtr.baseAddress!, MemoryLayout<in6_addr>.size)
                    XCTAssertEqual(rc, 0)
                }
            }
        default:
            XCTFail("Invalid address: \(sa)")
        }
    }

    func testRejectsNonIPStrings() throws {
        do {
            _ = try SocketAddress.ipAddress(string: "definitelynotanip", port: 800)
        } catch SocketAddressError.failedToParseIPString(let str) {
            XCTAssertEqual(str, "definitelynotanip")
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }
}
