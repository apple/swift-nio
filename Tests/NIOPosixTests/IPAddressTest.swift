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
        let ipAddress = try IPAddress(string: "255.0.128.18")
        let expectedAddressBytes: IPv4Bytes = .init((255, 0, 128, 18))
        
        switch ipAddress {
        case .v4(let iPv4Address):
            XCTAssertEqual(iPv4Address.address, expectedAddressBytes)
        default:
            XCTFail()
        }
    }
    
    func testCanCreateIPv6AddressFromString() throws {
        let ipAddress = try IPAddress(string: "FFFF:0:18:1E0:0:0:6:0")
        let expectedAddressBytes: IPv6Bytes = .init((255, 255, 0, 0, 0, 24, 1, 224, 0, 0, 0, 0, 0, 6, 0, 0))
        
        switch ipAddress {
        case .v6(let iPv6Address):
            XCTAssertEqual(iPv6Address.address, expectedAddressBytes)
        default:
            XCTFail()
        }
    }
    
    func testCanCreateIPv6AddressFromShortenedString() throws {
        let ipAddress = try IPAddress(string: "FFFF:0:18:1E0::6:0")
        let expectedAddressBytes: IPv6Bytes = .init((255, 255, 0, 0, 0, 24, 1, 224, 0, 0, 0, 0, 0, 6, 0, 0))
        
        switch ipAddress {
        case .v6(let iPv6Address):
            XCTAssertEqual(iPv6Address.address, expectedAddressBytes)
        default:
            XCTFail()
        }
    }
    
    func testCanCreateIPv4AddressFromBytes() throws {
        let ipAddress = try IPAddress(packedBytes: [255, 0, 128, 18])
        let expectedAddressBytes: IPv4Bytes = .init((255, 0, 128, 18))
        
        switch ipAddress {
        case .v4(let iPv4Address):
            XCTAssertEqual(iPv4Address.address, expectedAddressBytes)
        default:
            XCTFail()
        }
    }
    
    func testCanCreateIPv6AddressFromBytes() throws {
        let ipAddress = try IPAddress(packedBytes: [255, 255, 0, 0, 0, 24, 1, 224, 0, 0, 0, 0, 0, 6, 0, 0])
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
        
        let ipAddress = IPAddress(posixIPv4Address: testPosixAddress)
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
        
        let ipAddress = IPAddress(posixIPv6Address: testPosixAddress)
        let expectedAddressBytes: IPv6Bytes = .init((255, 255, 0, 0, 0, 24, 1, 224, 0, 0, 0, 0, 0, 6, 0, 0))
        
        switch ipAddress {
        case .v6(let iPv6Address):
            XCTAssertEqual(iPv6Address.address, expectedAddressBytes)
        default:
            XCTFail()
        }
    }
    
    func testDescriptionWorksIPv4Address() throws {
        let ipAddress1 = try IPAddress(packedBytes: [255, 0, 128, 18])
        let ipAddress2 = try IPAddress(string: "255.0.128.18")
        let expectedDescription = "[IPv4]255.0.128.18"
        
        XCTAssertEqual(ipAddress1.description, expectedDescription)
        XCTAssertEqual(ipAddress2.description, expectedDescription)
    }
    
    func testDescriptionWorksIPv6Address() throws {
        let ipAddress1 = try IPAddress(packedBytes: [255, 255, 0, 0, 0, 24, 1, 224, 0, 0, 0, 0, 0, 6, 0, 0])
        let ipAddress2 = try IPAddress(string: "FFFF:0:18:1E0:0:0:6:0")
        
        let expectedDescription = "[IPv6]FFFF:0000:0018:01E0:0000:0000:0006:0000"
        
        XCTAssertEqual(ipAddress1.description, expectedDescription)
        XCTAssertEqual(ipAddress2.description, expectedDescription)
    }
    
    // TODO: Test posix representation
    // TODO: Test error cases
    // TODO: description remove leading zeros
    // TODO: IPv6 description shortened
}

