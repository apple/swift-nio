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
import NIOCore
import XCTest

@testable import NIOPosix

class SystemTest: XCTestCase {
    func testSystemCallWrapperPerformance() throws {
        try runSystemCallWrapperPerformanceTest(
            testAssertFunction: XCTAssert,
            debugModeAllowed: true
        )
    }

    func testErrorsWorkCorrectly() throws {
        try withPipe { readFD, writeFD in
            var randomBytes: UInt8 = 42
            do {
                _ = try withUnsafePointer(to: &randomBytes) { ptr in
                    try readFD.withUnsafeFileDescriptor { readFD in
                        try NIOBSDSocket.setsockopt(
                            socket: readFD,
                            level: NIOBSDSocket.OptionLevel(rawValue: -1),
                            option_name: NIOBSDSocket.Option(rawValue: -1),
                            option_value: ptr,
                            option_len: 0
                        )
                    }
                }
                XCTFail("success even though the call was invalid")
            } catch let e as IOError {
                // ENOTSOCK almost everything and ENOPROTOOPT in Qemu
                XCTAssert([ENOTSOCK, ENOPROTOOPT].contains(e.errnoCode))
                XCTAssert(e.description.contains("setsockopt"))
                XCTAssert(e.description.contains("\(ENOTSOCK)") || e.description.contains("\(ENOPROTOOPT)"))
            } catch let e {
                XCTFail("wrong error thrown: \(e)")
            }
            return [readFD, writeFD]
        }
    }

    #if canImport(Darwin)
    // Example twin data options captured on macOS
    private static let cmsghdrExample: [UInt8] = [
        0x10, 0x00, 0x00, 0x00,  // Length 16 including header
        0x00, 0x00, 0x00, 0x00,  // IPPROTO_IP
        0x07, 0x00, 0x00, 0x00,  // IP_RECVDSTADDR
        0x7F, 0x00, 0x00, 0x01,  // 127.0.0.1
        0x0D, 0x00, 0x00, 0x00,  // Length 13 including header
        0x00, 0x00, 0x00, 0x00,  // IPPROTO_IP
        0x1B, 0x00, 0x00, 0x00,  // IP_RECVTOS
        0x01, 0x00, 0x00, 0x00,
    ]  // ECT-1 (1 byte)
    private static let cmsghdr_secondStartPosition = 16
    private static let cmsghdr_firstDataStart = 12
    private static let cmsghdr_firstDataCount = 4
    private static let cmsghdr_secondDataCount = 1
    private static let cmsghdr_firstType = IP_RECVDSTADDR
    private static let cmsghdr_secondType = IP_RECVTOS
    #elseif os(Android) && arch(arm)
    private static let cmsghdrExample: [UInt8] = [
        0x10, 0x00, 0x00, 0x00,  // Length 16 including header
        0x00, 0x00, 0x00, 0x00,  // IPPROTO_IP
        0x08, 0x00, 0x00, 0x00,  // IP_PKTINFO
        0x7F, 0x00, 0x00, 0x01,  // 127.0.0.1
        0x0D, 0x00, 0x00, 0x00,  // Length 13 including header
        0x00, 0x00, 0x00, 0x00,  // IPPROTO_IP
        0x01, 0x00, 0x00, 0x00,  // IP_TOS
        0x01, 0x00, 0x00, 0x00,
    ]  // ECT-1 (1 byte)
    private static let cmsghdr_secondStartPosition = 16
    private static let cmsghdr_firstDataStart = 12
    private static let cmsghdr_firstDataCount = 4
    private static let cmsghdr_secondDataCount = 1
    private static let cmsghdr_firstType = IP_PKTINFO
    private static let cmsghdr_secondType = IP_TOS
    #elseif os(Linux) || os(Android)
    // Example twin data options captured on Linux
    private static let cmsghdrExample: [UInt8] = [
        0x1C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // Length 28 including header.
        0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00,  // IPPROTO_IP, IP_PKTINFO
        0x01, 0x00, 0x00, 0x00, 0x7F, 0x00, 0x00, 0x01,  // interface number, 127.0.0.1 (local)
        0x7F, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,  // 127.0.0.1 (destination), 4 bytes to align length
        0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // Length 17
        0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,  // IPPROTO_IP, IP_TOS
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // ECT-1 (1 byte)
    ]
    private static let cmsghdr_secondStartPosition = 32
    private static let cmsghdr_firstDataStart = 16
    private static let cmsghdr_firstDataCount = 12
    private static let cmsghdr_secondDataCount = 1
    private static let cmsghdr_firstType = IP_PKTINFO
    private static let cmsghdr_secondType = IP_TOS
    #else
    #error("No cmsg support on this platform.")
    #endif

    func testCmsgFirstHeader() {
        var exampleCmsgHdr = SystemTest.cmsghdrExample
        exampleCmsgHdr.withUnsafeMutableBytes { pCmsgHdr in
            var msgHdr = msghdr()
            msgHdr.control_ptr = pCmsgHdr

            withUnsafePointer(to: msgHdr) { pMsgHdr in
                let result = NIOBSDSocketControlMessage.firstHeader(inside: pMsgHdr)
                XCTAssertEqual(pCmsgHdr.baseAddress, result)
            }
        }
    }

    func testCMsgNextHeader() {
        var exampleCmsgHdr = SystemTest.cmsghdrExample
        exampleCmsgHdr.withUnsafeMutableBytes { pCmsgHdr in
            var msgHdr = msghdr()
            msgHdr.control_ptr = pCmsgHdr

            withUnsafeMutablePointer(to: &msgHdr) { pMsgHdr in
                let first = NIOBSDSocketControlMessage.firstHeader(inside: pMsgHdr)
                let second = NIOBSDSocketControlMessage.nextHeader(inside: pMsgHdr, after: first!)
                let expectedSecondStart = pCmsgHdr.baseAddress! + SystemTest.cmsghdr_secondStartPosition
                XCTAssertEqual(expectedSecondStart, second!)
                let third = NIOBSDSocketControlMessage.nextHeader(inside: pMsgHdr, after: second!)
                XCTAssertEqual(third, nil)
            }
        }
    }

    func testCMsgData() {
        var exampleCmsgHrd = SystemTest.cmsghdrExample
        exampleCmsgHrd.withUnsafeMutableBytes { pCmsgHdr in
            var msgHdr = msghdr()
            msgHdr.control_ptr = pCmsgHdr

            withUnsafePointer(to: msgHdr) { pMsgHdr in
                let first = NIOBSDSocketControlMessage.firstHeader(inside: pMsgHdr)
                let firstData = NIOBSDSocketControlMessage.data(for: first!)
                let expecedFirstData = UnsafeRawBufferPointer(
                    rebasing: pCmsgHdr[
                        SystemTest
                            .cmsghdr_firstDataStart..<(SystemTest.cmsghdr_firstDataStart
                            + SystemTest.cmsghdr_firstDataCount)
                    ]
                )
                XCTAssertEqual(expecedFirstData.baseAddress, firstData?.baseAddress)
                XCTAssertEqual(expecedFirstData.count, firstData?.count)
            }
        }
    }

    func testCMsgCollection() {
        var exampleCmsgHrd = SystemTest.cmsghdrExample
        exampleCmsgHrd.withUnsafeMutableBytes { pCmsgHdr in
            var msgHdr = msghdr()
            msgHdr.control_ptr = pCmsgHdr
            let collection = UnsafeControlMessageCollection(messageHeader: msgHdr)
            var msgNum = 0
            for cmsg in collection {
                if msgNum == 0 {
                    XCTAssertEqual(cmsg.level, .init(IPPROTO_IP))
                    XCTAssertEqual(cmsg.type, .init(SystemTest.cmsghdr_firstType))
                    XCTAssertEqual(cmsg.data?.count, SystemTest.cmsghdr_firstDataCount)
                } else if msgNum == 1 {
                    XCTAssertEqual(cmsg.level, .init(IPPROTO_IP))
                    XCTAssertEqual(cmsg.type, .init(SystemTest.cmsghdr_secondType))
                    XCTAssertEqual(cmsg.data?.count, SystemTest.cmsghdr_secondDataCount)
                }
                msgNum += 1
            }
            XCTAssertEqual(msgNum, 2)
        }
    }
}
