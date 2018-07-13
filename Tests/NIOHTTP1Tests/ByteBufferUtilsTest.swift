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
//
// ByteBufferUtilsTest.swift
//

import XCTest
import NIO
@testable import NIOHTTP1

fileprivate enum DummyError: Error {
    case err
}

class ByteBufferUtilsTest: XCTestCase {
    
    func testComparators() {
        var someByteBuffer: ByteBuffer = ByteBufferAllocator.init().buffer(capacity: 16)
        someByteBuffer.write(string: "fiRSt")
        XCTAssert(
            someByteBuffer.readableBytesView.compareReadableBytes(
                to: "first".utf8))
        XCTAssert(
            someByteBuffer.readableBytesView.compareReadableBytes(
                to: "fiRSt".utf8))
        XCTAssert(
            someByteBuffer.readableBytesView.compareReadableBytes(
                to: "fIrst".utf8))
        XCTAssertFalse(
            someByteBuffer.readableBytesView.compareReadableBytes(
                to: "fIrt".utf8))
        XCTAssertFalse(
            someByteBuffer.readableBytesView.compareReadableBytes(
                to: "firsta".utf8))
        XCTAssertFalse(
            someByteBuffer.readableBytesView.compareReadableBytes(
                to: "afirst".utf8))
        XCTAssertFalse(
            someByteBuffer.readableBytesView.compareReadableBytes(
                to: "eiRSt".utf8))
        XCTAssertFalse(
            someByteBuffer.readableBytesView.compareReadableBytes(
                to: "fIrso".utf8))
        XCTAssertFalse(
            someByteBuffer.readableBytesView.compareReadableBytes(
                to: "firot".utf8))
        
    }

    private func byteBufferView(string: String) -> ByteBufferView {
        let byteBufferAllocator = ByteBufferAllocator.init()
        var buffer = byteBufferAllocator.buffer(capacity: string.lengthOfBytes(using: .utf8))
        buffer.write(string: string)
        return buffer.readableBytesView
    }

    func testTrimming() {
        XCTAssertEqual(byteBufferView(string: "   first").trimSpaces().map({CChar($0)}), byteBufferView(string: "first").map({CChar($0)}))
        XCTAssertEqual(byteBufferView(string: "   first  ").trimSpaces().map({CChar($0)}), byteBufferView(string: "first").map({CChar($0)}))
        XCTAssertEqual(byteBufferView(string: "first  ").trimSpaces().map({CChar($0)}), byteBufferView(string: "first").map({CChar($0)}))
        XCTAssertEqual(byteBufferView(string: "first").trimSpaces().map({CChar($0)}), byteBufferView(string: "first").map({CChar($0)}))
        XCTAssertEqual(byteBufferView(string: " \t\t  fi  rst").trimSpaces().map({CChar($0)}), byteBufferView(string: "fi  rst").map({CChar($0)}))
        XCTAssertEqual(byteBufferView(string: "   firs  t \t ").trimSpaces().map({CChar($0)}), byteBufferView(string: "firs  t").map({CChar($0)}))
        XCTAssertEqual(byteBufferView(string: "f\t  irst  ").trimSpaces().map({CChar($0)}), byteBufferView(string: "f\t  irst").map({CChar($0)}))
        XCTAssertEqual(byteBufferView(string: "f i  rs  t").trimSpaces().map({CChar($0)}), byteBufferView(string: "f i  rs  t").map({CChar($0)}))
    }

}
