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
    func testCanCreateIPv4AddressFromString() throws {
        let ipAddress = try NIOIPAddress(string: "255.0.128.18")
        let expectedAddressBytes: IPv4Bytes = .init((255, 0, 128, 18))
        
        switch ipAddress {
        case .v4(let iPv4Address):
            XCTAssertEqual(iPv4Address.address, expectedAddressBytes)
        default:
            XCTFail()
        }
    }
    
    func testCanCreateIPv6AddressFromString() throws {
        let ipAddress = try NIOIPAddress(string: "FFFF:0:18:1E0:0:0:6:0")
        let expectedAddressBytes: IPv6Bytes = .init((255, 255, 0, 0, 0, 24, 1, 224, 0, 0, 0, 0, 0, 6, 0, 0))
        
        switch ipAddress {
        case .v6(let iPv6Address):
            XCTAssertEqual(iPv6Address.address, expectedAddressBytes)
        default:
            XCTFail()
        }
    }
    
    func testCanCreateIPv6AddressFromShortenedString() throws {
        let ipAddress = try NIOIPAddress(string: "FF::1")
        let expectedAddressBytes: IPv6Bytes = .init((0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
        
        switch ipAddress {
        case .v6(let iPv6Address):
            XCTAssertEqual(iPv6Address.address, expectedAddressBytes)
        default:
            XCTFail()
        }
    }
    
    func testCanCreateIPv4AddressFromBytes() throws {
        let ipAddress = try NIOIPAddress(packedBytes: [255, 0, 128, 18])
        let expectedAddressBytes: IPv4Bytes = .init((255, 0, 128, 18))
        
        switch ipAddress {
        case .v4(let iPv4Address):
            XCTAssertEqual(iPv4Address.address, expectedAddressBytes)
        default:
            XCTFail()
        }
    }
    
    func testCanCreateIPv6AddressFromBytes() throws {
        let ipAddress = try NIOIPAddress(packedBytes: [255, 255, 0, 0, 0, 24, 1, 224, 0, 0, 0, 0, 0, 6, 0, 0])
        let expectedAddressBytes: IPv6Bytes = .init((255, 255, 0, 0, 0, 24, 1, 224, 0, 0, 0, 0, 0, 6, 0, 0))
        
        switch ipAddress {
        case .v6(let iPv6Address):
            XCTAssertEqual(iPv6Address.address, expectedAddressBytes)
        default:
            XCTFail()
        }
    }
    
    func testCanCreateIPv4AddressFromPosix() throws {
        let bigEndianAddress: Int32 = 255 << 24 + 0 << 16 + 128 << 8 + 18
        let testPosixAddress: in_addr = .init(s_addr: .init(bitPattern: bigEndianAddress))
        
        let ipAddress = NIOIPAddress(posixIPv4Address: testPosixAddress)
        let expectedAddressBytes: IPv4Bytes = .init((255, 0, 128, 18))
        
        switch ipAddress {
        case .v4(let iPv4Address):
            XCTAssertEqual(iPv4Address.address, expectedAddressBytes)
        default:
            XCTFail()
        }
    }
    
    func testCanCreateIPv6AddressFromPosix() throws {
        let testPosixAddress: in6_addr = .init(__u6_addr: .init(__u6_addr8: (255, 255, 0, 0, 0, 24, 1, 224, 0, 0, 0, 0, 0, 6, 0, 0)))
        
        let ipAddress = NIOIPAddress(posixIPv6Address: testPosixAddress)
        let expectedAddressBytes: IPv6Bytes = .init((255, 255, 0, 0, 0, 24, 1, 224, 0, 0, 0, 0, 0, 6, 0, 0))
        
        switch ipAddress {
        case .v6(let iPv6Address):
            XCTAssertEqual(iPv6Address.address, expectedAddressBytes)
        default:
            XCTFail()
        }
    }
    
    func testDescriptionWorksIPv4Address() throws {
        let ipAddress = try NIOIPAddress(packedBytes: [255, 0, 128, 18])
        let expectedDescription = "[IPv4]255.0.128.18"
        
        XCTAssertEqual(ipAddress.description, expectedDescription)
    }
    
    func testDescriptionWorksIPv6Address() throws {
        let ipAddress1 = try NIOIPAddress(packedBytes: [255, 255, 0, 0, 0, 24, 1, 224, 0, 0, 0, 0, 0, 6, 0, 0])
        let expectedDescription1 = "[IPv6]FFFF:0:18:1E0::6:0"
        
        let ipAddress2 = try NIOIPAddress(packedBytes: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        let expectedDescription2 = "[IPv6]::1"
        
        let ipAddress3 = try NIOIPAddress(packedBytes: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let expectedDescription3 = "[IPv6]::"
    
        XCTAssertEqual(ipAddress1.description, expectedDescription1)
        XCTAssertEqual(ipAddress2.description, expectedDescription2)
        XCTAssertEqual(ipAddress3.description, expectedDescription3)
    }
    
    func testPosixWorksIPv4Address() throws {
        let expectedPosix = in_addr(s_addr: UInt32(255) << 24 + UInt32(128) << 8 + UInt32(18))
        let ipAddress = NIOIPAddress(posixIPv4Address: expectedPosix)
        
        switch ipAddress {
        case .v4(let iPv4Address):
            XCTAssertEqual(iPv4Address.posix.s_addr, expectedPosix.s_addr)
        default:
            XCTFail()
        }
    }
    
    func testPosixWorksIPv6Address() throws {
        let ipAddress = NIOIPAddress((255, 255, 0, 0, 0, 24, 1, 224, 0, 0, 0, 0, 0, 6, 0, 0))
        let expectedPosix = in6_addr.init(__u6_addr: .init(__u6_addr8: (255, 255, 0, 0, 0, 24, 1, 224, 0, 0, 0, 0, 0, 6, 0, 0)))
        
        
        switch ipAddress {
        case .v6(let iPv6Address):
            let ipAddressPosix32 = iPv6Address.posix.__u6_addr.__u6_addr32
            let expectedPosix32 = expectedPosix.__u6_addr.__u6_addr32
            
            XCTAssertEqual(ipAddressPosix32.0, expectedPosix32.0)
            XCTAssertEqual(ipAddressPosix32.1, expectedPosix32.1)
            XCTAssertEqual(ipAddressPosix32.2, expectedPosix32.2)
            XCTAssertEqual(ipAddressPosix32.3, expectedPosix32.3)
        default:
            XCTFail()
        }
    }
    
    func testInvalidIPAddressString() throws {
        // non categorised strings
        XCTAssertThrowsError(try NIOIPAddress(string: ""))
        XCTAssertThrowsError(try NIOIPAddress(string: "0"))
        // invalid ipv4
        XCTAssertThrowsError(try NIOIPAddress(string: "."))
        XCTAssertThrowsError(try NIOIPAddress(string: ".."))
        XCTAssertThrowsError(try NIOIPAddress(string: "..."))
        XCTAssertThrowsError(try NIOIPAddress(string: "...."))
        XCTAssertThrowsError(try NIOIPAddress(string: "0.256.0.0"))
        XCTAssertThrowsError(try NIOIPAddress(string: "0.0.-1.0"))
        XCTAssertThrowsError(try NIOIPAddress(string: "0.0.0"))
        XCTAssertThrowsError(try NIOIPAddress(string: "0.0.0.0.0"))
        // invalid ipv6
        XCTAssertThrowsError(try NIOIPAddress(string: ":"))
        XCTAssertThrowsError(try NIOIPAddress(string: ":::"))
        XCTAssertThrowsError(try NIOIPAddress(string: ":::::::"))
        XCTAssertThrowsError(try NIOIPAddress(string: "10000:0:0:0:0:0:0:0"))
        XCTAssertThrowsError(try NIOIPAddress(string: "0:0:0:-0:0:0:0:0"))
        XCTAssertThrowsError(try NIOIPAddress(string: "0::0:0:0::0"))
        XCTAssertThrowsError(try NIOIPAddress(string: "0:0:0:0:0:0:0"))
        XCTAssertThrowsError(try NIOIPAddress(string: "0:0:0:0:0:0:0:0:0"))
    }
}

