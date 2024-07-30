//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore
import XCTest

final class AddressedEnvelopeTests: XCTestCase {
    func testHashable_whenEqual() throws {
        let address = try SocketAddress(ipAddress: "127.0.0.0", port: 443)
        let envelope1 = AddressedEnvelope(remoteAddress: address, data: "foo")
        let envelope2 = AddressedEnvelope(remoteAddress: address, data: "foo")

        XCTAssertEqual(envelope1, envelope2)
        XCTAssertEqual(envelope1.hashValue, envelope2.hashValue)
    }

    func testHashable_whenDifferentData() throws {
        let address = try SocketAddress(ipAddress: "127.0.0.0", port: 443)
        let envelope1 = AddressedEnvelope(remoteAddress: address, data: "foo")
        let envelope2 = AddressedEnvelope(remoteAddress: address, data: "bar")

        XCTAssertNotEqual(envelope1, envelope2)
    }

    func testHashable_whenDifferentAddress() throws {
        let address1 = try SocketAddress(ipAddress: "127.0.0.0", port: 443)
        let address2 = try SocketAddress(ipAddress: "127.0.0.0", port: 444)
        let envelope1 = AddressedEnvelope(remoteAddress: address1, data: "foo")
        let envelope2 = AddressedEnvelope(remoteAddress: address2, data: "foo")

        XCTAssertNotEqual(envelope1, envelope2)
    }

    func testHashable_whenDifferentMetadata() throws {
        let address = try SocketAddress(ipAddress: "127.0.0.0", port: 443)
        let envelope1 = AddressedEnvelope(
            remoteAddress: address,
            data: "foo",
            metadata: .init(ecnState: .congestionExperienced)
        )
        let envelope2 = AddressedEnvelope(
            remoteAddress: address,
            data: "foo",
            metadata: .init(ecnState: .transportCapableFlag0)
        )

        XCTAssertNotEqual(envelope1, envelope2)
    }

    func testHashable_whenDifferentData_andDifferentAddress() throws {
        let address1 = try SocketAddress(ipAddress: "127.0.0.0", port: 443)
        let address2 = try SocketAddress(ipAddress: "127.0.0.0", port: 444)
        let envelope1 = AddressedEnvelope(remoteAddress: address1, data: "foo")
        let envelope2 = AddressedEnvelope(remoteAddress: address2, data: "bar")

        XCTAssertNotEqual(envelope1, envelope2)
    }

    func testHashable_whenDifferentData_andDifferentMetadata() throws {
        let address = try SocketAddress(ipAddress: "127.0.0.0", port: 443)
        let envelope1 = AddressedEnvelope(
            remoteAddress: address,
            data: "foo",
            metadata: .init(ecnState: .congestionExperienced)
        )
        let envelope2 = AddressedEnvelope(
            remoteAddress: address,
            data: "bar",
            metadata: .init(ecnState: .transportCapableFlag0)
        )

        XCTAssertNotEqual(envelope1, envelope2)
    }

    func testHashable_whenDifferentAddress_andDifferentMetadata() throws {
        let address1 = try SocketAddress(ipAddress: "127.0.0.0", port: 443)
        let address2 = try SocketAddress(ipAddress: "127.0.0.0", port: 444)
        let envelope1 = AddressedEnvelope(
            remoteAddress: address1,
            data: "foo",
            metadata: .init(ecnState: .congestionExperienced)
        )
        let envelope2 = AddressedEnvelope(
            remoteAddress: address2,
            data: "bar",
            metadata: .init(ecnState: .transportCapableFlag0)
        )

        XCTAssertNotEqual(envelope1, envelope2)
    }
}
