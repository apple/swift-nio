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

public class LengthFieldBasedFrameDecoderTest: XCTestCase {
    func testFixedLengthFrameDecoderInt8() throws {
        try FixedLengthFrameDecoderHelper<Int8>.fixedLengthFrameHelper()
    }
    
    func testFixedLengthFrameDecoderInt16() throws {
        try FixedLengthFrameDecoderHelper<Int16>.fixedLengthFrameHelper()
    }
    
    func testFixedLengthFrameDecoderInt32() throws {
        try FixedLengthFrameDecoderHelper<Int32>.fixedLengthFrameHelper()
    }
    
    func testFixedLengthFrameDecoderInt64() throws {
        try FixedLengthFrameDecoderHelper<Int64>.fixedLengthFrameHelper()
    }
    
    func testFixedLengthFrameDecoderUInt8() throws {
        try FixedLengthFrameDecoderHelper<UInt8>.fixedLengthFrameHelper()
    }
    
    func testFixedLengthFrameDecoderUInt16() throws {
        try FixedLengthFrameDecoderHelper<UInt16>.fixedLengthFrameHelper()
    }
    
    func testFixedLengthFrameDecoderUInt32() throws {
        try FixedLengthFrameDecoderHelper<UInt32>.fixedLengthFrameHelper()
    }
    
    func testFixedLengthFrameDecoderUInt64() throws {
        try FixedLengthFrameDecoderHelper<Int64>.fixedLengthFrameHelper()
    }
}

struct FixedLengthFrameDecoderHelper<T: FixedWidthInteger> {
    static fileprivate func fixedLengthFrameHelper() throws {
        let channel = EmbeddedChannel()

        XCTAssertNoThrow(_ = try channel.pipeline.add(handler: LengthFieldBasedFrameDecoder<T>(upperBound: 15)).wait())
        
        let testStrings = ["try", "swift", "san", "jose"]
        var buffer = channel.allocator.buffer(capacity:1024)
        for testString in testStrings {
            buffer.write(integer: T(testString.count))
            buffer.write(string: testString)
        }
        
        for testString in testStrings {
            XCTAssertTrue(try channel.writeInbound(buffer))
            
            guard var result: ByteBuffer = channel.readInbound() else {
                XCTFail("Failed to read buffer for \(T.self)")
                return
            }
            let testResult = result.readString(length: (result.readableBytes))
            XCTAssertEqual(testResult, testString)
        }
        XCTAssertTrue(try channel.finish())
    }
}
