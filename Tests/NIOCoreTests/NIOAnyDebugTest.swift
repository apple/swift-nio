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

import NIOCore
import XCTest

class NIOAnyDebugTest: XCTestCase {

    func testCustomStringConvertible() throws {
        XCTAssertEqual(wrappedInNIOAnyBlock("string").description, "String: string")
        XCTAssertEqual(wrappedInNIOAnyBlock(123).description, "Int: 123")

        let bb = ByteBuffer(string: "byte buffer string")
        XCTAssertEqual(
            wrappedInNIOAnyBlock(bb).description,
            "ByteBuffer: [627974652062756666657220737472696e67](18 bytes)"
        )

        let fileHandle = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: 1)
        defer {
            XCTAssertNoThrow(_ = try fileHandle.takeDescriptorOwnership())
        }
        let fileRegion = FileRegion(fileHandle: fileHandle, readerIndex: 1, endIndex: 5)
        XCTAssertEqual(
            wrappedInNIOAnyBlock(fileRegion).description,
            """
            FileRegion: \
            FileRegion { \
            handle: \
            FileHandle \
            { descriptor: 1 \
            }, \
            readerIndex: \(fileRegion.readerIndex), \
            endIndex: \(fileRegion.endIndex) }
            """
        )

        let socketAddress = try SocketAddress(unixDomainSocketPath: "socketAdress")
        let envelopeByteBuffer = ByteBuffer(string: "envelope buffer")
        let envelope = AddressedEnvelope<ByteBuffer>(remoteAddress: socketAddress, data: envelopeByteBuffer)
        XCTAssertEqual(
            wrappedInNIOAnyBlock(envelope).description,
            """
            AddressedEnvelope<ByteBuffer>: \
            AddressedEnvelope { \
            remoteAddress: \(socketAddress), \
            data: \(envelopeByteBuffer) }
            """
        )
    }

    func testCustomDebugStringConvertible() {
        XCTAssertEqual(wrappedInNIOAnyBlock("string").debugDescription, "(String: string)")
        let any = wrappedInNIOAnyBlock("test")
        XCTAssertEqual(any.debugDescription, "(\(any.description))")
    }

    private func wrappedInNIOAnyBlock(_ item: Any) -> NIOAny {
        NIOAny(item)
    }
}
