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

import NIO
import XCTest

class UtilitiesTest: XCTestCase {
    func testCoreCountWorks() {
        XCTAssertGreaterThan(System.coreCount, 0)
    }

    func testEnumeratingInterfaces() throws {
        // This is a tricky test, because we can't really assert much and expect this
        // to pass on all systems. The best we can do is assume there is a loopback:
        // maybe an IPv4 one, maybe an IPv6 one, but there will be one. We look for
        // both.
        let interfaces = try System.enumerateInterfaces()
        XCTAssertGreaterThan(interfaces.count, 0)

        var ipv4LoopbackPresent = false
        var ipv6LoopbackPresent = false

        for interface in interfaces {
            if try interface.address == SocketAddress(ipAddress: "127.0.0.1", port: 0) {
                ipv4LoopbackPresent = true
                XCTAssertEqual(interface.netmask, try SocketAddress(ipAddress: "255.0.0.0", port: 0))
                XCTAssertNil(interface.broadcastAddress)
                XCTAssertNil(interface.pointToPointDestinationAddress)
            } else if try interface.address == SocketAddress(ipAddress: "::1", port: 0) {
                ipv6LoopbackPresent = true
                XCTAssertEqual(interface.netmask, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", port: 0))
                XCTAssertNil(interface.broadcastAddress)
                XCTAssertNil(interface.pointToPointDestinationAddress)
            }
        }

        XCTAssertTrue(ipv4LoopbackPresent || ipv6LoopbackPresent)
    }
}
