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
        ], zone: "testzone")
        
        print(ipAddress.description)
    }
    
    func testStringInitWorksIPv4() throws {
        let address = "255.7.40.128"
        
        var posix: in_addr = .init()
        inet_aton(address, &posix)
        
        dump(posix)
        let ipAddress = IPAddress(string: address)
        switch ipAddress {
        case .v4(let iPv4Address):
            dump(iPv4Address.posix)
            XCTAssertEqual(posix.s_addr, iPv4Address.posix.s_addr)
        default:
            print("ups")
        }
    }
    
    func testStringInitWorksIPv6() throws {
        let ipAddress = IPAddress(string: "1:2:123:67:0:0:0:7")
        
        if let ipAddress = ipAddress {
            dump(ipAddress.description)
        }
    }
    
    func testStringInitWorksIPv6WithZone() throws {
        let ipAddress = IPAddress(string: "1:2:123:67:FF:0:0:7%testzone")
        
        if let ipAddress = ipAddress {
            dump(ipAddress.description)
        }
    }
    
    func testPosixInitWorksIPv4() throws {
        let addr: in_addr = .init(s_addr: 255 << 24 + 7 << 16 + 40 << 8 + 128)
        let ipAddress = IPAddress(posixIPv4Address: addr)
        
        switch ipAddress {
        case .v4(let iPv4Address):
            let address = "255.7.40.128"
            var posix: in_addr = .init()
            inet_aton(address, &posix)
            
            dump(posix)
            dump(iPv4Address.posix)
            XCTAssertEqual(posix.s_addr, iPv4Address.posix.s_addr)
        case .v6(_):
            return
        }
        print(ipAddress.description)
    }
    
    func testPosixInitWorksIPv6() throws {
        let addr: in6_addr = .init(__u6_addr: .init(__u6_addr8:(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
        let ipAddress = IPAddress(posixIPv6Address: addr)
        
        print(ipAddress.description)
    }
}

