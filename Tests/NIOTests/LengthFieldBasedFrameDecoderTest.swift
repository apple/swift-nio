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
import XCTest

struct fixedLengthFrameDecoderHelper<T: FixedWidthInteger> {
    static fileprivate func fixedLengthFrameHelper(_ channel: EmbeddedChannel) throws {
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

public class LengthFieldBasedFrameDecoderTest: XCTestCase {
    func testFixedLengthFrameDecoderInt8() throws {
        let channel = EmbeddedChannel()
        
        try fixedLengthFrameDecoderHelper<Int8>.fixedLengthFrameHelper(channel)
    }
    
    func testFixedLengthFrameDecoderInt16() throws {
        let channel = EmbeddedChannel()
        
        try fixedLengthFrameDecoderHelper<Int16>.fixedLengthFrameHelper(channel)
    }
    
    func testFixedLengthFrameDecoderInt32() throws {
        let channel = EmbeddedChannel()
        
        try fixedLengthFrameDecoderHelper<Int32>.fixedLengthFrameHelper(channel)
    }
    
    func testFixedLengthFrameDecoderInt64() throws {
        let channel = EmbeddedChannel()
        
        try fixedLengthFrameDecoderHelper<Int64>.fixedLengthFrameHelper(channel)
    }
    
    func testFixedLengthFrameDecoderUInt8() throws {
        let channel = EmbeddedChannel()
        
        try fixedLengthFrameDecoderHelper<UInt8>.fixedLengthFrameHelper(channel)
    }
    
    func testFixedLengthFrameDecoderUInt16() throws {
        let channel = EmbeddedChannel()
        
        try fixedLengthFrameDecoderHelper<UInt16>.fixedLengthFrameHelper(channel)
    }
    
    func testFixedLengthFrameDecoderUInt32() throws {
        let channel = EmbeddedChannel()
        
        try fixedLengthFrameDecoderHelper<UInt32>.fixedLengthFrameHelper(channel)
    }
    
    func testFixedLengthFrameDecoderUInt64() throws {
        let channel = EmbeddedChannel()
        
        try fixedLengthFrameDecoderHelper<Int64>.fixedLengthFrameHelper(channel)
    }
}
