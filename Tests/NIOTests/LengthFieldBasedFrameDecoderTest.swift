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
    func testNegativeLengths() throws {
        let channel = EmbeddedChannel()
        
        XCTAssertNoThrow(_ = try channel.pipeline.add(handler: LengthFieldBasedFrameDecoder<Int8>(upperBound: 5)).wait())
        
        var buffer = channel.allocator.buffer(capacity:1024)
        buffer.write(integer: Int8(-1))
        buffer.write(string: "hello")
        
        XCTAssertThrowsError(try channel.writeInbound(buffer)) { (error) -> Void in
            XCTAssertEqual(error as? LengthFieldBasedFrameDecoder<Int8>.NIOLengthFieldBasedFrameDecoderError, LengthFieldBasedFrameDecoder<Int8>.NIOLengthFieldBasedFrameDecoderError.invalidFrameLength)
        }
        XCTAssertThrowsError(try channel.finish())
    }
    
    func testAbsurdlyLargeLengths() throws {
        let channel = EmbeddedChannel()
        
        XCTAssertNoThrow(_ = try channel.pipeline.add(handler: LengthFieldBasedFrameDecoder<Int8>(upperBound: 15)).wait())
        
        var buffer = channel.allocator.buffer(capacity:1024)
        buffer.write(integer: Int8(127))
        buffer.write(string: "hello")
        
        XCTAssertThrowsError(try channel.writeInbound(buffer)) { (error) -> Void in
            XCTAssertEqual(error as? LengthFieldBasedFrameDecoder<Int8>.NIOLengthFieldBasedFrameDecoderError, LengthFieldBasedFrameDecoder<Int8>.NIOLengthFieldBasedFrameDecoderError.invalidFrameLength)
        }
        XCTAssertThrowsError(try channel.finish())
    }
    
    func testEOFBeforeReceivingAppropriateNumberOfBytes() throws {
        let channel = EmbeddedChannel()
        
        XCTAssertNoThrow(_ = try channel.pipeline.add(handler: LengthFieldBasedFrameDecoder<Int8>(upperBound: 15)).wait())
        
        var buffer = channel.allocator.buffer(capacity:1024)
        buffer.write(integer: Int8(10))
        buffer.write(string: "hello")

        XCTAssertFalse(try channel.writeInbound(buffer))
        XCTAssertNil(channel.readInbound())
        XCTAssertThrowsError(try channel.finish()) { (error) -> Void in
            XCTAssertEqual(error as? LengthFieldBasedFrameDecoder<Int8>.NIOLengthFieldBasedFrameDecoderError, LengthFieldBasedFrameDecoder<Int8>.NIOLengthFieldBasedFrameDecoderError.bytesLeftOver)
        }
    }
    
    func testEOFWhileWaitingForLength() throws {
        let channel = EmbeddedChannel()
        
        XCTAssertNoThrow(_ = try channel.pipeline.add(handler: LengthFieldBasedFrameDecoder<Int8>(upperBound: 15)).wait())

        let buffer = channel.allocator.buffer(capacity:1024)
        XCTAssertFalse(try channel.writeInbound(buffer))
        XCTAssertNil(channel.readInbound())

        XCTAssertThrowsError(try channel.finish()) { (error) -> Void in
            XCTAssertEqual(error as? LengthFieldBasedFrameDecoder<Int8>.NIOLengthFieldBasedFrameDecoderError, LengthFieldBasedFrameDecoder<Int8>.NIOLengthFieldBasedFrameDecoderError.bytesLeftOver)
        }
    }
    
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

        let handler = LengthFieldBasedFrameDecoder<T>(upperBound: 15)
        XCTAssertNoThrow(_ = try channel.pipeline.add(handler: handler).wait())
        
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
