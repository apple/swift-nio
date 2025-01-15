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

class VsockAddressTest: XCTestCase {

    func testDescriptionWorks() throws {
        XCTAssertEqual(VsockAddress(cid: .host, port: 12345).description, "[VSOCK]2:12345")
        XCTAssertEqual(VsockAddress(cid: .any, port: 12345).description, "[VSOCK]-1:12345")
        XCTAssertEqual(VsockAddress(cid: .host, port: .any).description, "[VSOCK]2:-1")
        XCTAssertEqual(VsockAddress(cid: .any, port: .any).description, "[VSOCK]-1:-1")
    }

    func testInitializeFromIntegerLiteral() throws {
        XCTAssertEqual(VsockAddress.ContextID(integerLiteral: 0), 0)
        XCTAssertEqual(VsockAddress.Port(integerLiteral: 0), 0)
        XCTAssertEqual(VsockAddress.ContextID(integerLiteral: 4_294_967_295), 4_294_967_295)
        XCTAssertEqual(VsockAddress.Port(integerLiteral: 4_294_967_295), 4_294_967_295)
    }

    func testInitializeFromInt() throws {
        XCTAssertEqual(VsockAddress.ContextID(0), 0)
        XCTAssertEqual(VsockAddress.ContextID(4_294_967_295), 4_294_967_295)
        XCTAssertEqual(VsockAddress.Port(0), 0)
        XCTAssertEqual(VsockAddress.Port(4_294_967_295), 4_294_967_295)
    }

    func testSocketAddressEqualitySpecialValues() throws {
        XCTAssertEqual(
            VsockAddress(cid: .any, port: 12345),
            .init(cid: .init(rawValue: UInt32(bitPattern: -1)), port: 12345)
        )
        XCTAssertEqual(VsockAddress(cid: .hypervisor, port: 12345), .init(cid: 0, port: 12345))
        XCTAssertEqual(VsockAddress(cid: .host, port: 12345), .init(cid: 2, port: 12345))
    }

    func testSocketAddressEquality() throws {
        XCTAssertEqual(VsockAddress(cid: 0, port: 0), .init(cid: 0, port: 0))
        XCTAssertEqual(VsockAddress(cid: 1, port: 0), .init(cid: 1, port: 0))
        XCTAssertEqual(VsockAddress(cid: 0, port: 1), .init(cid: 0, port: 1))

        XCTAssertNotEqual(VsockAddress(cid: 0, port: 0), .init(cid: 1, port: 0))
        XCTAssertNotEqual(VsockAddress(cid: 0, port: 0), .init(cid: 0, port: 1))
    }

    func testGetLocalCID() throws {
        try XCTSkipUnless(System.supportsVsockLoopback, "No vsock loopback transport available")

        let socket = try ServerSocket(protocolFamily: .vsock, setNonBlocking: true)
        defer { try? socket.close() }

        // Check we can get the local CID using the static property on ContextID.
        let localCID = try socket.withUnsafeHandle(VsockAddress.ContextID.getLocalContextID)

        // Check the local CID from the socket matches.
        XCTAssertEqual(try socket.getLocalVsockContextID(), localCID)

        // Check the local CID from the channel option matches.
        let singleThreadedELG = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try singleThreadedELG.syncShutdownGracefully()) }
        let eventLoop = singleThreadedELG.next()
        let channel = try ServerSocketChannel(
            serverSocket: socket,
            eventLoop: eventLoop as! SelectableEventLoop,
            group: singleThreadedELG
        )
        XCTAssertEqual(try channel.getOption(.localVsockContextID).wait(), localCID)
    }
}
