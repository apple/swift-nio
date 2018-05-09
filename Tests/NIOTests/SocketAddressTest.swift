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
        let sa = SocketAddress(ipv4SocketAddress, host: "foobar.com")
        XCTAssertEqual("[IPv4]foobar.com:12345", sa.description)
    }

    func testIn6AddrDescriptionWorks() throws {
        let sampleString = "::1"
        let sampleIn6Addr: [UInt8] = [ // ::1
            0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0,
            0x0, 0x0, 0x1, 0x0, 0x0, 0x0, 0x0, 0x0, 0x70, 0x0, 0x0, 0x54,
            0xc2, 0xb5, 0x58, 0xff, 0x7f, 0x0, 0x0, 0x7,
            0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x40, 0x1, 0x1, 0x0
        ]

        var address         = sockaddr_in6()
        #if os(Linux) // no sin_len on Linux
        #else
          address.sin6_len  = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr   = sampleIn6Addr.withUnsafeBytes {
            $0.baseAddress!.bindMemory(to: in6_addr.self, capacity: 1).pointee
        }

        let s = address.addressDescription()
        XCTAssertEqual(s.count, sampleString.count,
                       "Address description has unexpected length 😱")
        XCTAssertEqual(s, sampleString,
                       "Address description is way below our expectations 😱")
    }

    func testCanCreateIPv4AddressFromString() throws {
        let sa = try SocketAddress(ipAddress: "127.0.0.1", port: 80)
        let expectedAddress: [UInt8] = [0x7F, 0x00, 0x00, 0x01]
        if case .v4(let address) = sa {
            var addr = address.address
            let host = address.host
            XCTAssertEqual(host, "")
            XCTAssertEqual(addr.sin_family, sa_family_t(AF_INET))
            XCTAssertEqual(addr.sin_port, in_port_t(80).bigEndian)
            expectedAddress.withUnsafeBytes { expectedPtr in
                withUnsafeBytes(of: &addr.sin_addr) { actualPtr in
                    let rc = memcmp(actualPtr.baseAddress!, expectedPtr.baseAddress!, MemoryLayout<in_addr>.size)
                    XCTAssertEqual(rc, 0)
                }
            }
        } else {
            XCTFail("Invalid address: \(sa)")
        }
    }

    func testCanCreateIPv6AddressFromString() throws {
        let sa = try SocketAddress(ipAddress: "fe80::5", port: 443)
        let expectedAddress: [UInt8] = [0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05]
        if case .v6(let address) = sa {
            var addr = address.address
            let host = address.host
            XCTAssertEqual(host, "")
            XCTAssertEqual(addr.sin6_family, sa_family_t(AF_INET6))
            XCTAssertEqual(addr.sin6_port, in_port_t(443).bigEndian)
            XCTAssertEqual(addr.sin6_scope_id, 0)
            XCTAssertEqual(addr.sin6_flowinfo, 0)
            expectedAddress.withUnsafeBytes { expectedPtr in
                withUnsafeBytes(of: &addr.sin6_addr) { actualPtr in
                    let rc = memcmp(actualPtr.baseAddress!, expectedPtr.baseAddress!, MemoryLayout<in6_addr>.size)
                    XCTAssertEqual(rc, 0)
                }
            }
        } else {
            XCTFail("Invalid address: \(sa)")
        }
    }

    func testRejectsNonIPStrings() throws {
        do {
            _ = try SocketAddress(ipAddress: "definitelynotanip", port: 800)
        } catch SocketAddressError.failedToParseIPString(let str) {
            XCTAssertEqual(str, "definitelynotanip")
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testWithMutableAddressCopiesFaithfully() throws {
        let first = try SocketAddress(ipAddress: "127.0.0.1", port: 80)
        let second = try SocketAddress(ipAddress: "::1", port: 80)
        let third = try SocketAddress(unixDomainSocketPath: "/definitely/a/path")

        guard case .v4(let firstAddress) = first else {
            XCTFail("Unable to extract IPv4 address")
            return
        }
        guard case .v6(let secondAddress) = second else {
            XCTFail("Unable to extract IPv6 address")
            return
        }
        guard case .unixDomainSocket(let thirdAddress) = third else {
            XCTFail("Unable to extract UDS address")
            return
        }

        var firstIPAddress = firstAddress.address
        var secondIPAddress = secondAddress.address
        var thirdIPAddress = thirdAddress.address

        var firstCopy = firstIPAddress.withMutableSockAddr { (addr, size) -> sockaddr_in in
            XCTAssertEqual(size, MemoryLayout<sockaddr_in>.size)
            return addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        }
        var secondCopy = secondIPAddress.withMutableSockAddr { (addr, size) -> sockaddr_in6 in
            XCTAssertEqual(size, MemoryLayout<sockaddr_in6>.size)
            return addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
        }
        var thirdCopy = thirdIPAddress.withMutableSockAddr { (addr, size) -> sockaddr_un in
            XCTAssertEqual(size, MemoryLayout<sockaddr_un>.size)
            return addr.withMemoryRebound(to: sockaddr_un.self, capacity: 1) { $0.pointee }
        }

        XCTAssertEqual(memcmp(&firstIPAddress, &firstCopy, MemoryLayout<sockaddr_in>.size), 0)
        XCTAssertEqual(memcmp(&secondIPAddress, &secondCopy, MemoryLayout<sockaddr_in6>.size), 0)
        XCTAssertEqual(memcmp(&thirdIPAddress, &thirdCopy, MemoryLayout<sockaddr_un>.size), 0)
    }

    func testWithMutableAddressAllowsMutationWithoutPersistence() throws {
        let first = try SocketAddress(ipAddress: "127.0.0.1", port: 80)
        let second = try SocketAddress(ipAddress: "::1", port: 80)
        let third = try SocketAddress(unixDomainSocketPath: "/definitely/a/path")

        guard case .v4(let firstAddress) = first else {
            XCTFail("Unable to extract IPv4 address")
            return
        }
        guard case .v6(let secondAddress) = second else {
            XCTFail("Unable to extract IPv6 address")
            return
        }
        guard case .unixDomainSocket(let thirdAddress) = third else {
            XCTFail("Unable to extract UDS address")
            return
        }

        var firstIPAddress = firstAddress.address
        var secondIPAddress = secondAddress.address
        var thirdIPAddress = thirdAddress.address

        // Copy the original values.
        var firstCopy = firstIPAddress
        var secondCopy = secondIPAddress
        var thirdCopy = thirdIPAddress

        _ = firstIPAddress.withMutableSockAddr { (addr, size) -> Void in
            addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_port = 5
            }
        }
        _ = secondIPAddress.withMutableSockAddr { (addr, size) -> Void in
            XCTAssertEqual(size, MemoryLayout<sockaddr_in6>.size)
            addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                $0.pointee.sin6_port = in_port_t(5).bigEndian
            }
        }
        _ = thirdIPAddress.withMutableSockAddr { (addr, size) -> Void in
            XCTAssertEqual(size, MemoryLayout<sockaddr_un>.size)
            addr.withMemoryRebound(to: sockaddr_un.self, capacity: 1) {
                $0.pointee.sun_path.2 = 50
            }
        }

        XCTAssertEqual(memcmp(&firstIPAddress, &firstCopy, MemoryLayout<sockaddr_in>.size), 0)
        XCTAssertEqual(memcmp(&secondIPAddress, &secondCopy, MemoryLayout<sockaddr_in6>.size), 0)
        XCTAssertEqual(memcmp(&thirdIPAddress, &thirdCopy, MemoryLayout<sockaddr_un>.size), 0)
    }

    func testConvertingStorage() throws {
        let first = try SocketAddress(ipAddress: "127.0.0.1", port: 80)
        let second = try SocketAddress(ipAddress: "::1", port: 80)
        let third = try SocketAddress(unixDomainSocketPath: "/definitely/a/path")

        guard case .v4(let firstAddress) = first else {
            XCTFail("Unable to extract IPv4 address")
            return
        }
        guard case .v6(let secondAddress) = second else {
            XCTFail("Unable to extract IPv6 address")
            return
        }
        guard case .unixDomainSocket(let thirdAddress) = third else {
            XCTFail("Unable to extract UDS address")
            return
        }

        var storage = sockaddr_storage()
        var firstIPAddress = firstAddress.address
        var secondIPAddress = secondAddress.address
        var thirdIPAddress = thirdAddress.address

        var firstCopy: sockaddr_in = withUnsafeBytes(of: &firstIPAddress) { outer in
            _ = withUnsafeMutableBytes(of: &storage) { temp in
                memcpy(temp.baseAddress!, outer.baseAddress!, MemoryLayout<sockaddr_in>.size)
            }
            return storage.convert()
        }
        var secondCopy: sockaddr_in6 = withUnsafeBytes(of: &secondIPAddress) { outer in
            _ = withUnsafeMutableBytes(of: &storage) { temp in
                memcpy(temp.baseAddress!, outer.baseAddress!, MemoryLayout<sockaddr_in6>.size)
            }
            return storage.convert()
        }
        var thirdCopy: sockaddr_un = withUnsafeBytes(of: &thirdIPAddress) { outer in
            _ = withUnsafeMutableBytes(of: &storage) { temp in
                memcpy(temp.baseAddress!, outer.baseAddress!, MemoryLayout<sockaddr_un>.size)
            }
            return storage.convert()
        }

        XCTAssertEqual(memcmp(&firstIPAddress, &firstCopy, MemoryLayout<sockaddr_in>.size), 0)
        XCTAssertEqual(memcmp(&secondIPAddress, &secondCopy, MemoryLayout<sockaddr_in6>.size), 0)
        XCTAssertEqual(memcmp(&thirdIPAddress, &thirdCopy, MemoryLayout<sockaddr_un>.size), 0)
    }

    func testComparingSockaddrs() throws {
        let first = try SocketAddress(ipAddress: "127.0.0.1", port: 80)
        let second = try SocketAddress(ipAddress: "::1", port: 80)
        let third = try SocketAddress(unixDomainSocketPath: "/definitely/a/path")

        guard case .v4(let firstAddress) = first else {
            XCTFail("Unable to extract IPv4 address")
            return
        }
        guard case .v6(let secondAddress) = second else {
            XCTFail("Unable to extract IPv6 address")
            return
        }
        guard case .unixDomainSocket(let thirdAddress) = third else {
            XCTFail("Unable to extract UDS address")
            return
        }

        var firstIPAddress = firstAddress.address
        var secondIPAddress = secondAddress.address
        var thirdIPAddress = thirdAddress.address

        first.withSockAddr { outerAddr, outerSize in
            firstIPAddress.withSockAddr { innerAddr, innerSize in
                XCTAssertEqual(outerSize, innerSize)
                XCTAssertEqual(memcmp(innerAddr, outerAddr, min(outerSize, innerSize)), 0)
                XCTAssertNotEqual(outerAddr, innerAddr)
            }
        }
        second.withSockAddr { outerAddr, outerSize in
            secondIPAddress.withSockAddr { innerAddr, innerSize in
                XCTAssertEqual(outerSize, innerSize)
                XCTAssertEqual(memcmp(innerAddr, outerAddr, min(outerSize, innerSize)), 0)
                XCTAssertNotEqual(outerAddr, innerAddr)
            }
        }
        third.withSockAddr { outerAddr, outerSize in
            thirdIPAddress.withSockAddr { innerAddr, innerSize in
                XCTAssertEqual(outerSize, innerSize)
                XCTAssertEqual(memcmp(innerAddr, outerAddr, min(outerSize, innerSize)), 0)
                XCTAssertNotEqual(outerAddr, innerAddr)
            }
        }
    }

    func testEqualSocketAddresses() throws {
        let first = try SocketAddress(ipAddress: "::1", port: 80)
        let second = try SocketAddress(ipAddress: "00:00::1", port: 80)
        let third = try SocketAddress(ipAddress: "127.0.0.1", port: 443)
        let fourth = try SocketAddress(ipAddress: "127.0.0.1", port: 443)
        let fifth = try SocketAddress(unixDomainSocketPath: "/var/tmp")
        let sixth = try SocketAddress(unixDomainSocketPath: "/var/tmp")

        XCTAssertEqual(first, second)
        XCTAssertEqual(third, fourth)
        XCTAssertEqual(fifth, sixth)
    }

    func testUnequalAddressesOnPort() throws {
        let first = try SocketAddress(ipAddress: "::1", port: 80)
        let second = try SocketAddress(ipAddress: "::1", port: 443)
        let third = try SocketAddress(ipAddress: "127.0.0.1", port: 80)
        let fourth = try SocketAddress(ipAddress: "127.0.0.1", port: 443)

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(third, fourth)
    }

    func testUnequalOnAddress() throws {
        let first = try SocketAddress(ipAddress: "::1", port: 80)
        let second = try SocketAddress(ipAddress: "::2", port: 80)
        let third = try SocketAddress(ipAddress: "127.0.0.1", port: 443)
        let fourth = try SocketAddress(ipAddress: "127.0.0.2", port: 443)
        let fifth = try SocketAddress(unixDomainSocketPath: "/var/tmp")
        let sixth = try SocketAddress(unixDomainSocketPath: "/var/tmq")

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(third, fourth)
        XCTAssertNotEqual(fifth, sixth)
    }

    func testUnequalAcrossFamilies() throws {
        let first = try SocketAddress(ipAddress: "::1", port: 80)
        let second = try SocketAddress(ipAddress: "127.0.0.1", port: 80)
        let third = try SocketAddress(unixDomainSocketPath: "/var/tmp")

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(second, third)
        // By the transitive property first != third, but let's protect against me being an idiot
        XCTAssertNotEqual(third, first)
    }

    func testPortAccessor() throws {
        XCTAssertEqual(try SocketAddress(ipAddress: "127.0.0.1", port: 80).port, 80)
        XCTAssertEqual(try SocketAddress(ipAddress: "::1", port: 80).port, 80)
        XCTAssertEqual(try SocketAddress(unixDomainSocketPath: "/definitely/a/path").port, nil)
    }

    func testCanMutateSockaddrStorage() throws {
        var storage = sockaddr_storage()
        XCTAssertEqual(storage.ss_family, 0)
        storage.withMutableSockAddr { (addr, _) in
            addr.pointee.sa_family = sa_family_t(AF_UNIX)
        }
        XCTAssertEqual(storage.ss_family, sa_family_t(AF_UNIX))
    }
}
