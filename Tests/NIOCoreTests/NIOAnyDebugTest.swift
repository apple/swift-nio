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
import NIOCore

class NIOAnyDebugTest: XCTestCase {
    
    func testCustomStringConvertible() throws {
        XCTAssertEqual(wrappedInNIOAnyBlock("string"), wrappedInNIOAnyBlock("string"))
        XCTAssertEqual(wrappedInNIOAnyBlock(123), wrappedInNIOAnyBlock("123"))
        
        let bb = ByteBuffer(string: "byte buffer string")
        XCTAssertTrue(wrappedInNIOAnyBlock(bb).contains("NIOAny { ByteBuffer { readerIndex: 0, writerIndex: 18, readableBytes: 18, capacity: 32, storageCapacity: 32, slice: _ByteBufferSlice { 0..<32 }, storage: "))
        XCTAssertTrue(wrappedInNIOAnyBlock(bb).hasSuffix(" }"))
        
        let fileHandle = NIOFileHandle(descriptor: 1)
        defer {
            XCTAssertNoThrow(_ = try fileHandle.takeDescriptorOwnership())
        }
        let fileRegion = FileRegion(fileHandle: fileHandle, readerIndex: 1, endIndex: 5)
        XCTAssertEqual(wrappedInNIOAnyBlock(fileRegion), wrappedInNIOAnyBlock("""
        FileRegion { \
        handle: \
        FileHandle \
        { descriptor: 1 \
        }, \
        readerIndex: \(fileRegion.readerIndex), \
        endIndex: \(fileRegion.endIndex) }
        """))
        
        let socketAddress = try SocketAddress(unixDomainSocketPath: "socketAdress")
        let envelopeByteBuffer = ByteBuffer(string: "envelope buffer")
        let envelope = AddressedEnvelope<ByteBuffer>(remoteAddress: socketAddress, data: envelopeByteBuffer)
        XCTAssertEqual(wrappedInNIOAnyBlock("\(envelope)"), wrappedInNIOAnyBlock("""
        AddressedEnvelope { \
        remoteAddress: \(socketAddress), \
        data: \(envelopeByteBuffer) }
        """))
    }
    
    private func wrappedInNIOAnyBlock(_ item: Any) -> String {
        return "NIOAny { \(item) }"
    }
    
}
