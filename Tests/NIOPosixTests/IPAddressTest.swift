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

import XCTest
@testable import NIOCore
@testable import NIOPosix

class IPAddressTest: XCTestCase {
    
    func testDescriptionWorksIPv4() throws {
        let ipAddress = IPAddress(packedBytes: [
            1, 2, 3, 4
        ])
        print(ipAddress.description)
    }
    
    func testDescriptionWorksIPv6() throws {
        let ipAddress = IPAddress(packedBytes: [
            0, 1, 255, 3, 128, 5, 6, 54, 8, 9, 100, 11, 132, 13, 104, 15
        ])
        
        print(ipAddress.description)
    }
    
    func testPosixInitWorksIPv4() throws {
        // TODO: not more than 24 bits? Using _UInt24
        // TODO: Only netmask?
        let addr: in_addr = .init(s_addr: 255 * 256 * 256 + 7 * 256 + 40)
        let ipAddress = IPAddress(posixIPv4Address: addr)
        
        print(ipAddress.description)
    }
    
    func testPosixInitWorksIPv6() throws {
        let addr: in6_addr = .init(__u6_addr: .init(__u6_addr8:(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
        let ipAddress = IPAddress(posixIPv6Address: addr)
        
        print(ipAddress.description)
    }
}
