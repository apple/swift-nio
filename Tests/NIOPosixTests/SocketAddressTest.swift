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

import CNIOLinux
import XCTest

@testable import NIOCore
@testable import NIOPosix

class SocketAddressTest: XCTestCase {

    func testDescriptionWorks() throws {
        var ipv4SocketAddress = sockaddr_in()
        let res = "10.0.0.1".withCString { p in
            inet_pton(NIOBSDSocket.AddressFamily.inet.rawValue, p, &ipv4SocketAddress.sin_addr)
        }
        XCTAssertEqual(res, 1)
        ipv4SocketAddress.sin_port = (12345 as in_port_t).bigEndian
        let sa = SocketAddress(ipv4SocketAddress, host: "foobar.com")
        XCTAssertEqual("[IPv4]foobar.com/10.0.0.1:12345", sa.description)
    }

    func testDescriptionWorksWithoutIP() throws {
        var ipv4SocketAddress = sockaddr_in()
        ipv4SocketAddress.sin_port = (12345 as in_port_t).bigEndian
        let sa = SocketAddress(ipv4SocketAddress, host: "foobar.com")
        XCTAssertEqual("[IPv4]foobar.com/0.0.0.0:12345", sa.description)
    }

    func testDescriptionWorksWithIPOnly() throws {
        let sa = try! SocketAddress(ipAddress: "10.0.0.2", port: 12345)
        XCTAssertEqual("[IPv4]10.0.0.2:12345", sa.description)
    }

    func testDescriptionWorksWithByteBufferIPv4IP() throws {
        let IPv4: [UInt8] = [0x7F, 0x00, 0x00, 0x01]
        let ipv4Address: ByteBuffer = ByteBuffer.init(bytes: IPv4)
        let sa = try! SocketAddress(packedIPAddress: ipv4Address, port: 12345)
        XCTAssertEqual("[IPv4]127.0.0.1:12345", sa.description)
    }

    func testDescriptionWorksWithByteBufferIPv6IP() throws {
        let IPv6: [UInt8] = [
            0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05,
        ]
        let ipv6Address: ByteBuffer = ByteBuffer.init(bytes: IPv6)
        let sa = try! SocketAddress(packedIPAddress: ipv6Address, port: 12345)
        XCTAssertEqual("[IPv6]fe80::5:12345", sa.description)
    }

    func testRejectsWrongIPByteBufferLength() {
        let wrongIP: [UInt8] = [0x01, 0x7F, 0x00]
        let ipAddress: ByteBuffer = ByteBuffer.init(bytes: wrongIP)
        XCTAssertThrowsError(try SocketAddress(packedIPAddress: ipAddress, port: 12345)) { error in
            switch error {
            case is SocketAddressError.FailedToParseIPByteBuffer:
                XCTAssertEqual(ipAddress, (error as! SocketAddressError.FailedToParseIPByteBuffer).address)
            default:
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testIn6AddrDescriptionWorks() throws {
        let sampleString = "::1"
        let sampleIn6Addr: [UInt8] = [  // ::1
            0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0,
            0x0, 0x0, 0x1, 0x0, 0x0, 0x0, 0x0, 0x0, 0x70, 0x0, 0x0, 0x54,
            0xc2, 0xb5, 0x58, 0xff, 0x7f, 0x0, 0x0, 0x7,
            0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x0, 0x40, 0x1, 0x1, 0x0,
        ]

        var address = sockaddr_in6()
        #if os(Linux) || os(Android)  // no sin6_len on Linux/Android
        #else
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        address.sin6_family = sa_family_t(NIOBSDSocket.AddressFamily.inet6.rawValue)
        address.sin6_addr = sampleIn6Addr.withUnsafeBytes {
            $0.baseAddress!.bindMemory(to: in6_addr.self, capacity: 1).pointee
        }

        let s = __testOnly_addressDescription(address)
        XCTAssertEqual(
            s.count,
            sampleString.count,
            "Address description has unexpected length 😱"
        )
        XCTAssertEqual(
            s,
            sampleString,
            "Address description is way below our expectations 😱"
        )
    }

    func testIPAddressWorks() throws {
        let sa = try! SocketAddress(ipAddress: "127.0.0.1", port: 12345)
        XCTAssertEqual("127.0.0.1", sa.ipAddress)
        let sa6 = try! SocketAddress(ipAddress: "::1", port: 12345)
        XCTAssertEqual("::1", sa6.ipAddress)
        let unix = try! SocketAddress(unixDomainSocketPath: "/definitely/a/path")
        XCTAssertEqual(nil, unix.ipAddress)
    }

    func testCanCreateIPv4AddressFromString() throws {
        let sa = try SocketAddress(ipAddress: "127.0.0.1", port: 80)
        let expectedAddress: [UInt8] = [0x7F, 0x00, 0x00, 0x01]
        if case .v4(let address) = sa {
            var addr = address.address
            let host = address.host
            XCTAssertEqual(host, "")
            XCTAssertEqual(addr.sin_family, sa_family_t(NIOBSDSocket.AddressFamily.inet.rawValue))
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
        let expectedAddress: [UInt8] = [
            0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05,
        ]
        if case .v6(let address) = sa {
            var addr = address.address
            let host = address.host
            XCTAssertEqual(host, "")
            XCTAssertEqual(addr.sin6_family, sa_family_t(NIOBSDSocket.AddressFamily.inet6.rawValue))
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

    func testRejectsNonIPStrings() {
        XCTAssertThrowsError(try SocketAddress(ipAddress: "definitelynotanip", port: 800)) { error in
            switch error as? SocketAddressError {
            case .some(.failedToParseIPString("definitelynotanip")):
                ()  // ok
            default:
                XCTFail("unexpected error: \(error)")
            }
        }
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
            return __testOnly_convertSockAddr(storage)
        }
        var secondCopy: sockaddr_in6 = withUnsafeBytes(of: &secondIPAddress) { outer in
            _ = withUnsafeMutableBytes(of: &storage) { temp in
                memcpy(temp.baseAddress!, outer.baseAddress!, MemoryLayout<sockaddr_in6>.size)
            }
            return __testOnly_convertSockAddr(storage)
        }
        var thirdCopy: sockaddr_un = withUnsafeBytes(of: &thirdIPAddress) { outer in
            _ = withUnsafeMutableBytes(of: &storage) { temp in
                memcpy(temp.baseAddress!, outer.baseAddress!, MemoryLayout<sockaddr_un>.size)
            }
            return __testOnly_convertSockAddr(storage)
        }

        XCTAssertEqual(memcmp(&firstIPAddress, &firstCopy, MemoryLayout<sockaddr_in>.size), 0)
        XCTAssertEqual(memcmp(&secondIPAddress, &secondCopy, MemoryLayout<sockaddr_in6>.size), 0)
        XCTAssertEqual(memcmp(&thirdIPAddress, &thirdCopy, MemoryLayout<sockaddr_un>.size), 0)

        // Test unsupported socket address family.
        var unspecAddr = sockaddr_storage()
        unspecAddr.ss_family = sa_family_t(AF_UNSPEC)
        XCTAssertThrowsError(try __testOnly_convertSockAddr(unspecAddr) as SocketAddress) { error in
            guard case .unsupported = error as? SocketAddressError else {
                XCTFail("Expected error \(SocketAddressError.unsupported), got error \(error).")
                return
            }
        }
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

        let firstIPAddress = firstAddress.address
        let secondIPAddress = secondAddress.address
        let thirdIPAddress = thirdAddress.address

        first.withSockAddr { outerAddr, outerSize in
            __testOnly_withSockAddr(firstIPAddress) { innerAddr, innerSize in
                XCTAssertEqual(outerSize, innerSize)
                XCTAssertEqual(memcmp(innerAddr, outerAddr, min(outerSize, innerSize)), 0)
                XCTAssertNotEqual(outerAddr, innerAddr)
            }
        }
        second.withSockAddr { outerAddr, outerSize in
            __testOnly_withSockAddr(secondIPAddress) { innerAddr, innerSize in
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

    func testHashEqualSocketAddresses() throws {
        let first = try SocketAddress(ipAddress: "::1", port: 80)
        let second = try SocketAddress(ipAddress: "00:00::1", port: 80)
        let third = try SocketAddress(ipAddress: "127.0.0.1", port: 443)
        let fourth = try SocketAddress(ipAddress: "127.0.0.1", port: 443)
        let fifth = try SocketAddress(unixDomainSocketPath: "/var/tmp")
        let sixth = try SocketAddress(unixDomainSocketPath: "/var/tmp")

        let set: Set<SocketAddress> = [first, second, third, fourth, fifth, sixth]
        XCTAssertEqual(set.count, 3)
        XCTAssertEqual(set, [first, third, fifth])
        XCTAssertEqual(set, [second, fourth, sixth])
    }

    func testHashUnequalAddressesOnPort() throws {
        let first = try SocketAddress(ipAddress: "::1", port: 80)
        let second = try SocketAddress(ipAddress: "::1", port: 443)
        let third = try SocketAddress(ipAddress: "127.0.0.1", port: 80)
        let fourth = try SocketAddress(ipAddress: "127.0.0.1", port: 443)

        let set: Set<SocketAddress> = [first, second, third, fourth]
        XCTAssertEqual(set.count, 4)
    }

    func testHashUnequalOnAddress() throws {
        let first = try SocketAddress(ipAddress: "::1", port: 80)
        let second = try SocketAddress(ipAddress: "::2", port: 80)
        let third = try SocketAddress(ipAddress: "127.0.0.1", port: 443)
        let fourth = try SocketAddress(ipAddress: "127.0.0.2", port: 443)
        let fifth = try SocketAddress(unixDomainSocketPath: "/var/tmp")
        let sixth = try SocketAddress(unixDomainSocketPath: "/var/tmq")

        let set: Set<SocketAddress> = [first, second, third, fourth, fifth, sixth]
        XCTAssertEqual(set.count, 6)
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

    func testUnixSocketAddressIgnoresTrailingJunk() throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(NIOBSDSocket.AddressFamily.unix.rawValue)
        let pathBytes: [UInt8] = "/var/tmp".utf8 + [0]

        pathBytes.withUnsafeBufferPointer { srcPtr in
            withUnsafeMutablePointer(to: &addr.sun_path) { dstPtr in
                dstPtr.withMemoryRebound(to: UInt8.self, capacity: srcPtr.count) { dstPtr in
                    dstPtr.update(from: srcPtr.baseAddress!, count: srcPtr.count)
                }
            }
        }

        let first = SocketAddress(addr)

        // Now poke a random byte at the end. This should be ignored, as that's uninitialized memory.
        addr.sun_path.100 = 60
        let second = SocketAddress(addr)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.hashValue, second.hashValue)
    }

    func testPortAccessor() throws {
        XCTAssertEqual(try SocketAddress(ipAddress: "127.0.0.1", port: 80).port, 80)
        XCTAssertEqual(try SocketAddress(ipAddress: "::1", port: 80).port, 80)
        XCTAssertEqual(try SocketAddress(unixDomainSocketPath: "/definitely/a/path").port, nil)
    }

    func testCanMutateSockaddrStorage() throws {
        var storage = sockaddr_storage()
        XCTAssertEqual(storage.ss_family, 0)
        __testOnly_withMutableSockAddr(&storage) { (addr, _) in
            addr.pointee.sa_family = sa_family_t(NIOBSDSocket.AddressFamily.unix.rawValue)
        }
        XCTAssertEqual(storage.ss_family, sa_family_t(NIOBSDSocket.AddressFamily.unix.rawValue))
    }

    func testPortIsMutable() throws {
        var ipV4 = try SocketAddress(ipAddress: "127.0.0.1", port: 80)
        var ipV6 = try SocketAddress(ipAddress: "::1", port: 80)
        var unix = try SocketAddress(unixDomainSocketPath: "/definitely/a/path")

        ipV4.port = 81
        ipV6.port = 81

        XCTAssertEqual(ipV4.port, 81)
        XCTAssertEqual(ipV6.port, 81)

        ipV4.port = nil
        ipV6.port = nil
        unix.port = nil

        XCTAssertEqual(ipV4.port, 0)
        XCTAssertEqual(ipV6.port, 0)
        XCTAssertNil(unix.port)
    }

    func testCanCreateIPv4MaskFromPrefix() throws {
        // This function is simple enough that we can simply test it for all valid inputs.
        let vectors: [(Int, SocketAddress)] = [
            (0, try SocketAddress(ipAddress: "0.0.0.0", port: 0)),
            (1, try SocketAddress(ipAddress: "128.0.0.0", port: 0)),
            (2, try SocketAddress(ipAddress: "192.0.0.0", port: 0)),
            (3, try SocketAddress(ipAddress: "224.0.0.0", port: 0)),
            (4, try SocketAddress(ipAddress: "240.0.0.0", port: 0)),
            (5, try SocketAddress(ipAddress: "248.0.0.0", port: 0)),
            (6, try SocketAddress(ipAddress: "252.0.0.0", port: 0)),
            (7, try SocketAddress(ipAddress: "254.0.0.0", port: 0)),
            (8, try SocketAddress(ipAddress: "255.0.0.0", port: 0)),
            (9, try SocketAddress(ipAddress: "255.128.0.0", port: 0)),
            (10, try SocketAddress(ipAddress: "255.192.0.0", port: 0)),
            (11, try SocketAddress(ipAddress: "255.224.0.0", port: 0)),
            (12, try SocketAddress(ipAddress: "255.240.0.0", port: 0)),
            (13, try SocketAddress(ipAddress: "255.248.0.0", port: 0)),
            (14, try SocketAddress(ipAddress: "255.252.0.0", port: 0)),
            (15, try SocketAddress(ipAddress: "255.254.0.0", port: 0)),
            (16, try SocketAddress(ipAddress: "255.255.0.0", port: 0)),
            (17, try SocketAddress(ipAddress: "255.255.128.0", port: 0)),
            (18, try SocketAddress(ipAddress: "255.255.192.0", port: 0)),
            (19, try SocketAddress(ipAddress: "255.255.224.0", port: 0)),
            (20, try SocketAddress(ipAddress: "255.255.240.0", port: 0)),
            (21, try SocketAddress(ipAddress: "255.255.248.0", port: 0)),
            (22, try SocketAddress(ipAddress: "255.255.252.0", port: 0)),
            (23, try SocketAddress(ipAddress: "255.255.254.0", port: 0)),
            (24, try SocketAddress(ipAddress: "255.255.255.0", port: 0)),
            (25, try SocketAddress(ipAddress: "255.255.255.128", port: 0)),
            (26, try SocketAddress(ipAddress: "255.255.255.192", port: 0)),
            (27, try SocketAddress(ipAddress: "255.255.255.224", port: 0)),
            (28, try SocketAddress(ipAddress: "255.255.255.240", port: 0)),
            (29, try SocketAddress(ipAddress: "255.255.255.248", port: 0)),
            (30, try SocketAddress(ipAddress: "255.255.255.252", port: 0)),
            (31, try SocketAddress(ipAddress: "255.255.255.254", port: 0)),
            (32, try SocketAddress(ipAddress: "255.255.255.255", port: 0)),
        ]

        for vector in vectors {
            XCTAssertEqual(SocketAddress(ipv4MaskForPrefix: vector.0), vector.1)
        }
    }

    func testCanCreateIPv6MaskFromPrefix() throws {
        // This function is simple enough that we can simply test it for all valid inputs.
        let vectors: [(Int, SocketAddress)] = [
            (0, try SocketAddress(ipAddress: "0000::", port: 0)),
            (1, try SocketAddress(ipAddress: "8000::", port: 0)),
            (2, try SocketAddress(ipAddress: "c000::", port: 0)),
            (3, try SocketAddress(ipAddress: "e000::", port: 0)),
            (4, try SocketAddress(ipAddress: "f000::", port: 0)),
            (5, try SocketAddress(ipAddress: "f800::", port: 0)),
            (6, try SocketAddress(ipAddress: "fc00::", port: 0)),
            (7, try SocketAddress(ipAddress: "fe00::", port: 0)),
            (8, try SocketAddress(ipAddress: "ff00::", port: 0)),
            (9, try SocketAddress(ipAddress: "ff80::", port: 0)),
            (10, try SocketAddress(ipAddress: "ffc0::", port: 0)),
            (11, try SocketAddress(ipAddress: "ffe0::", port: 0)),
            (12, try SocketAddress(ipAddress: "fff0::", port: 0)),
            (13, try SocketAddress(ipAddress: "fff8::", port: 0)),
            (14, try SocketAddress(ipAddress: "fffc::", port: 0)),
            (15, try SocketAddress(ipAddress: "fffe::", port: 0)),
            (16, try SocketAddress(ipAddress: "ffff::", port: 0)),
            (17, try SocketAddress(ipAddress: "ffff:8000::", port: 0)),
            (18, try SocketAddress(ipAddress: "ffff:c000::", port: 0)),
            (19, try SocketAddress(ipAddress: "ffff:e000::", port: 0)),
            (20, try SocketAddress(ipAddress: "ffff:f000::", port: 0)),
            (21, try SocketAddress(ipAddress: "ffff:f800::", port: 0)),
            (22, try SocketAddress(ipAddress: "ffff:fc00::", port: 0)),
            (23, try SocketAddress(ipAddress: "ffff:fe00::", port: 0)),
            (24, try SocketAddress(ipAddress: "ffff:ff00::", port: 0)),
            (25, try SocketAddress(ipAddress: "ffff:ff80::", port: 0)),
            (26, try SocketAddress(ipAddress: "ffff:ffc0::", port: 0)),
            (27, try SocketAddress(ipAddress: "ffff:ffe0::", port: 0)),
            (28, try SocketAddress(ipAddress: "ffff:fff0::", port: 0)),
            (29, try SocketAddress(ipAddress: "ffff:fff8::", port: 0)),
            (30, try SocketAddress(ipAddress: "ffff:fffc::", port: 0)),
            (31, try SocketAddress(ipAddress: "ffff:fffe::", port: 0)),
            (32, try SocketAddress(ipAddress: "ffff:ffff::", port: 0)),
            (33, try SocketAddress(ipAddress: "ffff:ffff:8000::", port: 0)),
            (34, try SocketAddress(ipAddress: "ffff:ffff:c000::", port: 0)),
            (35, try SocketAddress(ipAddress: "ffff:ffff:e000::", port: 0)),
            (36, try SocketAddress(ipAddress: "ffff:ffff:f000::", port: 0)),
            (37, try SocketAddress(ipAddress: "ffff:ffff:f800::", port: 0)),
            (38, try SocketAddress(ipAddress: "ffff:ffff:fc00::", port: 0)),
            (39, try SocketAddress(ipAddress: "ffff:ffff:fe00::", port: 0)),
            (40, try SocketAddress(ipAddress: "ffff:ffff:ff00::", port: 0)),
            (41, try SocketAddress(ipAddress: "ffff:ffff:ff80::", port: 0)),
            (42, try SocketAddress(ipAddress: "ffff:ffff:ffc0::", port: 0)),
            (43, try SocketAddress(ipAddress: "ffff:ffff:ffe0::", port: 0)),
            (44, try SocketAddress(ipAddress: "ffff:ffff:fff0::", port: 0)),
            (45, try SocketAddress(ipAddress: "ffff:ffff:fff8::", port: 0)),
            (46, try SocketAddress(ipAddress: "ffff:ffff:fffc::", port: 0)),
            (47, try SocketAddress(ipAddress: "ffff:ffff:fffe::", port: 0)),
            (48, try SocketAddress(ipAddress: "ffff:ffff:ffff::", port: 0)),
            (49, try SocketAddress(ipAddress: "ffff:ffff:ffff:8000::", port: 0)),
            (50, try SocketAddress(ipAddress: "ffff:ffff:ffff:c000::", port: 0)),
            (51, try SocketAddress(ipAddress: "ffff:ffff:ffff:e000::", port: 0)),
            (52, try SocketAddress(ipAddress: "ffff:ffff:ffff:f000::", port: 0)),
            (53, try SocketAddress(ipAddress: "ffff:ffff:ffff:f800::", port: 0)),
            (54, try SocketAddress(ipAddress: "ffff:ffff:ffff:fc00::", port: 0)),
            (55, try SocketAddress(ipAddress: "ffff:ffff:ffff:fe00::", port: 0)),
            (56, try SocketAddress(ipAddress: "ffff:ffff:ffff:ff00::", port: 0)),
            (57, try SocketAddress(ipAddress: "ffff:ffff:ffff:ff80::", port: 0)),
            (58, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffc0::", port: 0)),
            (59, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffe0::", port: 0)),
            (60, try SocketAddress(ipAddress: "ffff:ffff:ffff:fff0::", port: 0)),
            (61, try SocketAddress(ipAddress: "ffff:ffff:ffff:fff8::", port: 0)),
            (62, try SocketAddress(ipAddress: "ffff:ffff:ffff:fffc::", port: 0)),
            (63, try SocketAddress(ipAddress: "ffff:ffff:ffff:fffe::", port: 0)),
            (64, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff::", port: 0)),
            (65, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:8000::", port: 0)),
            (66, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:c000::", port: 0)),
            (67, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:e000::", port: 0)),
            (68, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:f000::", port: 0)),
            (69, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:f800::", port: 0)),
            (70, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:fc00::", port: 0)),
            (71, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:fe00::", port: 0)),
            (72, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ff00::", port: 0)),
            (73, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ff80::", port: 0)),
            (74, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffc0::", port: 0)),
            (75, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffe0::", port: 0)),
            (76, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:fff0::", port: 0)),
            (77, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:fff8::", port: 0)),
            (78, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:fffc::", port: 0)),
            (79, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:fffe::", port: 0)),
            (80, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff::", port: 0)),
            (81, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:8000::", port: 0)),
            (82, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:c000::", port: 0)),
            (83, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:e000::", port: 0)),
            (84, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:f000::", port: 0)),
            (85, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:f800::", port: 0)),
            (86, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:fc00::", port: 0)),
            (87, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:fe00::", port: 0)),
            (88, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ff00::", port: 0)),
            (89, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ff80::", port: 0)),
            (90, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffc0::", port: 0)),
            (91, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffe0::", port: 0)),
            (92, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:fff0::", port: 0)),
            (93, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:fff8::", port: 0)),
            (94, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:fffc::", port: 0)),
            (95, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:fffe::", port: 0)),
            (96, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff::", port: 0)),
            (97, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:8000::", port: 0)),
            (98, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:c000::", port: 0)),
            (99, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:e000::", port: 0)),
            (100, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:f000::", port: 0)),
            (101, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:f800::", port: 0)),
            (102, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:fc00::", port: 0)),
            (103, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:fe00::", port: 0)),
            (104, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ff00::", port: 0)),
            (105, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ff80::", port: 0)),
            (106, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffc0::", port: 0)),
            (107, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffe0::", port: 0)),
            (108, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:fff0::", port: 0)),
            (109, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:fff8::", port: 0)),
            (110, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:fffc::", port: 0)),
            (111, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:fffe::", port: 0)),
            (112, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffff::", port: 0)),
            (113, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:8000", port: 0)),
            (114, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:c000", port: 0)),
            (115, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:e000", port: 0)),
            (116, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:f000", port: 0)),
            (117, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:f800", port: 0)),
            (118, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:fc00", port: 0)),
            (119, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:fe00", port: 0)),
            (120, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ff00", port: 0)),
            (121, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ff80", port: 0)),
            (122, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffc0", port: 0)),
            (123, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffe0", port: 0)),
            (124, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:fff0", port: 0)),
            (125, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:fff8", port: 0)),
            (126, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:fffc", port: 0)),
            (127, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:fffe", port: 0)),
            (128, try SocketAddress(ipAddress: "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", port: 0)),
        ]

        for vector in vectors {
            XCTAssertEqual(SocketAddress(ipv6MaskForPrefix: vector.0), vector.1)
        }
    }
}
