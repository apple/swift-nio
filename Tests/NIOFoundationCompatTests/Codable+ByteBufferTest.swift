//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIO
import NIOFoundationCompat
import XCTest

class CodableByteBufferTest: XCTestCase {
    var buffer: ByteBuffer!
    var allocator: ByteBufferAllocator!
    var decoder: JSONDecoder!
    var encoder: JSONEncoder!

    override func setUp() {
        allocator = ByteBufferAllocator()
        buffer = allocator.buffer(capacity: 1024)
        buffer.writeString(String(repeating: "A", count: 1024))
        buffer.moveReaderIndex(to: 129)
        buffer.moveWriterIndex(to: 129)
        decoder = JSONDecoder()
        encoder = JSONEncoder()
    }

    override func tearDown() {
        encoder = nil
        decoder = nil
        buffer = nil
        allocator = nil
    }

    func testSimpleDecode() {
        buffer.writeString(#"{"string": "hello", "int": 42}"#)
        var sAndI: StringAndInt?
        XCTAssertNoThrow(sAndI = try decoder.decode(StringAndInt.self, from: buffer))
        XCTAssertEqual(StringAndInt(string: "hello", int: 42), sAndI)
    }

    func testSimpleEncodeIntoBuffer() {
        let expectedSandI = StringAndInt(string: "hello", int: 42)
        XCTAssertNoThrow(try encoder.encode(expectedSandI, into: &buffer))
        XCTAssertNoThrow(XCTAssertEqual(expectedSandI, try decoder.decode(StringAndInt.self, from: buffer)))
    }

    func testSimpleEncodeToFreshByteBuffer() {
        let expectedSandI = StringAndInt(string: "hello", int: 42)
        var buffer = allocator.buffer(capacity: 0)
        XCTAssertNoThrow(buffer = try encoder.encodeAsByteBuffer(expectedSandI, allocator: allocator))
        XCTAssertNoThrow(XCTAssertEqual(expectedSandI, try decoder.decode(StringAndInt.self, from: buffer)))
    }

    func testGetJSONDecodableFromBufferWorks() {
        buffer.writeString("GARBAGE {}!!? / GARBAGE")
        let beginIndex = buffer.writerIndex
        buffer.writeString(#"{"string": "hello", "int": 42}"#)
        let endIndex = buffer.writerIndex
        buffer.writeString("GARBAGE {}!!? / GARBAGE")

        let expectedSandI = StringAndInt(string: "hello", int: 42)
        XCTAssertNoThrow(XCTAssertEqual(expectedSandI,
                                        try buffer.getJSONDecodable(StringAndInt.self,
                                                                    at: beginIndex,
                                                                    length: endIndex - beginIndex)))
    }

    func testGetJSONDecodableFromBufferFailsBecauseShort() {
        buffer.writeString("GARBAGE {}!!? / GARBAGE")
        let beginIndex = buffer.writerIndex
        buffer.writeString(#"{"string": "hello", "int": 42}"#)
        let endIndex = buffer.writerIndex

        XCTAssertThrowsError(try buffer.getJSONDecodable(StringAndInt.self,
                                                         at: beginIndex,
                                                         length: endIndex - beginIndex - 1)) { error in
            XCTAssert(error is DecodingError)
        }
    }

    func testReadJSONDecodableFromBufferWorks() {
        let beginIndex = buffer.writerIndex
        buffer.writeString(#"{"string": "hello", "int": 42}"#)
        let endIndex = buffer.writerIndex
        buffer.writeString("GARBAGE {}!!? / GARBAGE")

        let expectedSandI = StringAndInt(string: "hello", int: 42)
        XCTAssertNoThrow(XCTAssertEqual(expectedSandI,
                                        try buffer.readJSONDecodable(StringAndInt.self,
                                                                     length: endIndex - beginIndex)))
    }

    func testReadJSONDecodableFromBufferFailsBecauseShort() {
        let beginIndex = buffer.writerIndex
        buffer.writeString(#"{"string": "hello", "int": 42}"#)
        let endIndex = buffer.writerIndex

        XCTAssertThrowsError(try buffer.readJSONDecodable(StringAndInt.self,
                                                          length: endIndex - beginIndex - 1)) { error in
            XCTAssert(error is DecodingError)
        }
    }

    func testReadWriteJSONDecodableWorks() {
        let expectedSandI = StringAndInt(string: "hello", int: 42)
        buffer.writeString("hello")
        buffer.moveReaderIndex(forwardBy: 5)
        var writtenBytes: Int?
        XCTAssertNoThrow(writtenBytes = try buffer.writeJSONEncodable(expectedSandI))
        for _ in 0 ..< 10 {
            XCTAssertNoThrow(try buffer.writeJSONEncodable(expectedSandI, encoder: JSONEncoder()))
        }
        for _ in 0 ..< 11 {
            XCTAssertNoThrow(try buffer.readJSONDecodable(StringAndInt.self, length: writtenBytes ?? -1))
        }
        XCTAssertEqual(0, buffer.readableBytes)
    }

    func testGetSetJSONDecodableWorks() {
        let expectedSandI = StringAndInt(string: "hello", int: 42)
        buffer.writeString(String(repeating: "{", count: 1000))
        var writtenBytes: Int?
        XCTAssertNoThrow(writtenBytes = try buffer.setJSONEncodable(expectedSandI,
                                                                    at: buffer.readerIndex + 123))
        XCTAssertNoThrow(try buffer.setJSONEncodable(expectedSandI,
                                                     encoder: JSONEncoder(),
                                                     at: buffer.readerIndex + 501))
        XCTAssertNoThrow(XCTAssertEqual(expectedSandI,
                                        try buffer.getJSONDecodable(StringAndInt.self,
                                                                    at: buffer.readerIndex + 123,
                                                                    length: writtenBytes ?? -1)))
        XCTAssertNoThrow(XCTAssertEqual(expectedSandI,
                                        try buffer.getJSONDecodable(StringAndInt.self,
                                                                    at: buffer.readerIndex + 501,
                                                                    length: writtenBytes ?? -1)))
    }

    func testFailingReadsDoNotChangeReaderIndex() {
        let expectedSandI = StringAndInt(string: "hello", int: 42)
        var writtenBytes: Int?
        XCTAssertNoThrow(writtenBytes = try buffer.writeJSONEncodable(expectedSandI))
        for length in 0 ..< (writtenBytes ?? 0) {
            XCTAssertThrowsError(try buffer.readJSONDecodable(StringAndInt.self,
                                                              length: length)) { error in
                XCTAssert(error is DecodingError)
            }
        }
        XCTAssertNoThrow(try buffer.readJSONDecodable(StringAndInt.self, length: writtenBytes ?? -1))
    }

    func testCustomEncoderIsRespected() {
        let expectedDate = Date(timeIntervalSinceReferenceDate: 86400)
        let strategyExpectation = XCTestExpectation(description: "Custom encoding strategy invoked")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
            strategyExpectation.fulfill()
        }
        XCTAssertNoThrow(try encoder.encode(["date": expectedDate], into: &buffer))
        XCTAssertEqual(XCTWaiter().wait(for: [strategyExpectation], timeout: 0.0), .completed)
    }

    func testCustomDecoderIsRespected() {
        let expectedDate = Date(timeIntervalSinceReferenceDate: 86400)
        let strategyExpectation = XCTestExpectation(description: "Custom decoding strategy invoked")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
        decoder.dateDecodingStrategy = .custom { decoder in
            strategyExpectation.fulfill()
            let container = try decoder.singleValueContainer()
            return Date(timeIntervalSinceReferenceDate: try container.decode(Double.self))
        }
        XCTAssertNoThrow(try encoder.encode(["date": expectedDate], into: &buffer))
        XCTAssertNoThrow(XCTAssertEqual(["date": expectedDate], try decoder.decode([String: Date].self, from: buffer)))
        XCTAssertEqual(XCTWaiter().wait(for: [strategyExpectation], timeout: 0.0), .completed)
    }

    func testCustomCodersAreRespectedWhenUsingReadWriteJSONDecodable() {
        let expectedDate = Date(timeIntervalSinceReferenceDate: 86400)
        let decoderStrategyExpectation = XCTestExpectation(description: "Custom decoding strategy invoked")
        let encoderStrategyExpectation = XCTestExpectation(description: "Custom encoding strategy invoked")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            encoderStrategyExpectation.fulfill()
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
        decoder.dateDecodingStrategy = .custom { decoder in
            decoderStrategyExpectation.fulfill()
            let container = try decoder.singleValueContainer()
            return Date(timeIntervalSinceReferenceDate: try container.decode(Double.self))
        }
        XCTAssertNoThrow(try buffer.writeJSONEncodable(["date": expectedDate], encoder: encoder))
        XCTAssertNoThrow(XCTAssertEqual(["date": expectedDate],
                                        try buffer.readJSONDecodable([String: Date].self,
                                                                     decoder: decoder,
                                                                     length: buffer.readableBytes)))
        XCTAssertEqual(XCTWaiter().wait(for: [decoderStrategyExpectation], timeout: 0.0), .completed)
        XCTAssertEqual(XCTWaiter().wait(for: [encoderStrategyExpectation], timeout: 0.0), .completed)
    }
}

struct StringAndInt: Codable, Equatable {
    var string: String
    var int: Int
}
