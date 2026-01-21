//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOCore
import NIOFoundationCompat
import XCTest

struct FakeContiguousBytes: ContiguousBytes {
    func withUnsafeBytes<T>(_ block: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        let ptr = UnsafeMutableRawBufferPointer.allocate(byteCount: 8, alignment: 1)
        ptr.initializeMemory(as: UInt8.self, repeating: 0xff)
        defer {
            ptr.deallocate()
        }

        return try block(UnsafeRawBufferPointer(ptr))
    }
}

class ByteBufferDataProtocolTests: XCTestCase {
    func testWritingData() {
        let d = Data([1, 2, 3, 4])
        var b = ByteBufferAllocator().buffer(capacity: 1024)
        b.writeData(d)
        XCTAssertEqual(b.readBytes(length: b.readableBytes), [1, 2, 3, 4])
    }

    func testWritingDispatchDataThoughDataProtocol() {
        var dd = DispatchData.empty
        var buffer = ByteBufferAllocator().buffer(capacity: 12)
        buffer.writeBytes([1, 2, 3, 4])
        dd.append(DispatchData(buffer: buffer))
        dd.append(DispatchData(buffer: buffer))

        buffer.clear()
        buffer.writeData(dd)
        XCTAssertEqual(buffer.readBytes(length: buffer.readableBytes), [1, 2, 3, 4, 1, 2, 3, 4])
    }

    func testSettingData() {
        let d = Data([1, 2, 3, 4])
        var b = ByteBufferAllocator().buffer(capacity: 1024)
        b.writeInteger(UInt64.max)
        b.setData(d, at: 2)
        XCTAssertEqual(b.readBytes(length: b.readableBytes), [0xFF, 0xFF, 0x01, 0x02, 0x03, 0x04, 0xFF, 0xFF])
    }

    func testSettingDispatchDataThoughDataProtocol() {
        var dd = DispatchData.empty
        var buffer = ByteBufferAllocator().buffer(capacity: 12)
        buffer.writeBytes([1, 2, 3, 4])
        dd.append(DispatchData(buffer: buffer))
        dd.append(DispatchData(buffer: buffer))

        buffer.clear()
        buffer.writeInteger(UInt64.max)
        buffer.writeInteger(UInt64.max)
        buffer.setData(dd, at: 4)
        XCTAssertEqual(
            buffer.readBytes(length: buffer.readableBytes),
            [0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x02, 0x03, 0x04, 0x01, 0x02, 0x03, 0x04, 0xFF, 0xFF, 0xFF, 0xFF]
        )
    }

    func testWriteContiguousBytes() {
        let fake = FakeContiguousBytes()
        var b = ByteBufferAllocator().buffer(capacity: 1024)
        b.writeContiguousBytes(fake)

        XCTAssertEqual(b.readBytes(length: b.readableBytes), [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
    }

    func testSetContiguousBytes() {
        let fake = FakeContiguousBytes()
        var b = ByteBufferAllocator().buffer(capacity: 1024)
        b.writeInteger(UInt64.min)
        b.writeInteger(UInt64.min)
        b.setContiguousBytes(fake, at: 4)

        XCTAssertEqual(
            b.readBytes(length: b.readableBytes),
            [0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00]
        )
    }
}
