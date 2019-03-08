//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) YEARS Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import NIO

class NIOAnyDebugTest: XCTestCase {
    
    func testCustomStringConvertible() throws {
        XCTAssertEqual(wrappedInNIOAnyBlock("string"), wrappedInNIOAnyBlock("string"))
        XCTAssertEqual(wrappedInNIOAnyBlock(123), wrappedInNIOAnyBlock("123"))
        
        let bb = ByteBufferAllocator().byteBuffer(string: "byte buffer string")
        XCTAssertTrue(wrappedInNIOAnyBlock(bb).contains("NIOAny { ByteBuffer { readerIndex: 0, writerIndex: 18, readableBytes: 18, capacity: 32, slice: _ByteBufferSlice { 0..<32 }, storage: "))
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
        { descriptor: 1, \
        isOpen: \(fileHandle.isOpen) \
        }, \
        readerIndex: \(fileRegion.readerIndex), \
        endIndex: \(fileRegion.endIndex) }
        """))
        
        let socketAddress = try SocketAddress(unixDomainSocketPath: "socketAdress")
        let envelopeByteBuffer = ByteBufferAllocator().byteBuffer(string: "envelope buffer")
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

private extension ByteBufferAllocator {
    func byteBuffer(string: String) -> ByteBuffer {
        var buffer = self.buffer(capacity: string.count)
        buffer.writeString(string)
        return buffer
    }
}
