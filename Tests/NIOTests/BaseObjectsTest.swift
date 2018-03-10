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

class BaseObjectTest: XCTestCase {
    func testNIOByteBufferConversion() {
        let expected = ByteBufferAllocator().buffer(capacity: 1024)
        let asAny = NIOAny(expected)
        XCTAssertEqual(expected, asAny.forceAs(type: ByteBuffer.self))
        XCTAssertEqual(expected, asAny.forceAsByteBuffer())
        if let actual = asAny.tryAs(type: ByteBuffer.self) {
            XCTAssertEqual(expected, actual)
        } else {
            XCTFail("tryAs didn't work")
        }
        if let actual = asAny.tryAsByteBuffer() {
            XCTAssertEqual(expected, actual)
        } else {
            XCTFail("tryAs didn't work")
        }
    }

    func testNIOIODataConversion() {
        let expected = IOData.byteBuffer(ByteBufferAllocator().buffer(capacity: 1024))
        let asAny = NIOAny(expected)
        XCTAssertEqual(expected, asAny.forceAs(type: IOData.self))
        XCTAssertEqual(expected, asAny.forceAsIOData())
        if let actual = asAny.tryAs(type: IOData.self) {
            XCTAssertEqual(expected, actual)
        } else {
            XCTFail("tryAs didn't work")
        }
        if let actual = asAny.tryAsIOData() {
            XCTAssertEqual(expected, actual)
        } else {
            XCTFail("tryAs didn't work")
        }
    }

    func testNIOFileRegionConversion() throws {
        try withPipe { (readFH, writeFH) in
            let expected = FileRegion(fileHandle: readFH, readerIndex: 1, endIndex: 2)
            let asAny = NIOAny(expected)
            XCTAssert(expected == asAny.forceAs(type: FileRegion.self))
            XCTAssert(expected == asAny.forceAsFileRegion())
            if let actual = asAny.tryAs(type: FileRegion.self) {
                XCTAssert(expected == actual)
            } else {
                XCTFail("tryAs didn't work")
            }
            if let actual = asAny.tryAsFileRegion() {
                XCTAssert(expected == actual)
            } else {
                XCTFail("tryAs didn't work")
            }
            return [readFH, writeFH]
        }
    }

    func testBadConversions() throws {
        try withPipe { (readFH, writeFH) in
            let bb = ByteBufferAllocator().buffer(capacity: 1024)
            let fr = FileRegion(fileHandle: readFH, readerIndex: 1, endIndex: 2)
            let id = IOData.byteBuffer(bb)

            XCTAssertNil(NIOAny(bb).tryAsFileRegion())
            XCTAssertNil(NIOAny(fr).tryAsByteBuffer())
            XCTAssertNil(NIOAny(id).tryAsFileRegion())
            return [readFH, writeFH]
        }
    }

    func testByteBufferFromIOData() {
        let expected = ByteBufferAllocator().buffer(capacity: 1024)
        let wrapped = IOData.byteBuffer(expected)
        XCTAssertEqual(expected, NIOAny(wrapped).tryAsByteBuffer())
    }

    func testFileRegionFromIOData() throws {
        try withPipe { (readFH, writeFH) in
            let expected = FileRegion(fileHandle: readFH, readerIndex: 1, endIndex: 2)
            let wrapped = IOData.fileRegion(expected)
            XCTAssert(expected == NIOAny(wrapped).tryAsFileRegion())
            return [readFH, writeFH]
        }
    }

    func testIODataEquals() throws {
        try withPipe { (readFH, writeFH) in
            var bb1 = ByteBufferAllocator().buffer(capacity: 1024)
            let bb2 = ByteBufferAllocator().buffer(capacity: 1024)
            bb1.write(string: "hello")
            let fr = FileRegion(fileHandle: readFH, readerIndex: 1, endIndex: 2)
            XCTAssertEqual(IOData.byteBuffer(bb1), IOData.byteBuffer(bb1))
            XCTAssertNotEqual(IOData.byteBuffer(bb1), IOData.byteBuffer(bb2))
            XCTAssertNotEqual(IOData.byteBuffer(bb1), IOData.fileRegion(fr))
            return [readFH, writeFH]
        }
    }
}
