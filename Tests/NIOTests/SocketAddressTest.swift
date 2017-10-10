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
}
