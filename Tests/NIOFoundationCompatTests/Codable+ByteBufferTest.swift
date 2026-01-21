//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the SwiftNIO project authors
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

class CodableByteBufferTest: XCTestCase {
    var buffer: ByteBuffer!
    var allocator: ByteBufferAllocator!
    var decoder: JSONDecoder!
    var encoder: JSONEncoder!

    override func setUp() {
        self.allocator = ByteBufferAllocator()
        self.buffer = self.allocator.buffer(capacity: 1024)
        self.buffer.writeString(String(repeating: "A", count: 1024))
        self.buffer.moveReaderIndex(to: 129)
        self.buffer.moveWriterIndex(to: 129)
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    override func tearDown() {
        self.encoder = nil
        self.decoder = nil
        self.buffer = nil
        self.allocator = nil
    }

    func testSimpleDecode() {
        self.buffer.writeString(#"{"string": "hello", "int": 42}"#)
        var sAndI: StringAndInt?
        XCTAssertNoThrow(sAndI = try self.decoder.decode(StringAndInt.self, from: self.buffer))
        XCTAssertEqual(StringAndInt(string: "hello", int: 42), sAndI)
    }

    func testSimpleEncodeIntoBuffer() {
        let expectedSandI = StringAndInt(string: "hello", int: 42)
        XCTAssertNoThrow(try self.encoder.encode(expectedSandI, into: &self.buffer))
        XCTAssertNoThrow(XCTAssertEqual(expectedSandI, try self.decoder.decode(StringAndInt.self, from: self.buffer)))
    }

    func testSimpleEncodeToFreshByteBuffer() {
        let expectedSandI = StringAndInt(string: "hello", int: 42)
        var buffer = self.allocator.buffer(capacity: 0)
        XCTAssertNoThrow(buffer = try self.encoder.encodeAsByteBuffer(expectedSandI, allocator: self.allocator))
        XCTAssertNoThrow(XCTAssertEqual(expectedSandI, try self.decoder.decode(StringAndInt.self, from: buffer)))
    }

    func testGetJSONDecodableFromBufferWorks() {
        self.buffer.writeString("GARBAGE {}!!? / GARBAGE")
        let beginIndex = self.buffer.writerIndex
        self.buffer.writeString(#"{"string": "hello", "int": 42}"#)
        let endIndex = self.buffer.writerIndex
        self.buffer.writeString("GARBAGE {}!!? / GARBAGE")

        let expectedSandI = StringAndInt(string: "hello", int: 42)
        XCTAssertNoThrow(
            XCTAssertEqual(
                expectedSandI,
                try self.buffer.getJSONDecodable(
                    StringAndInt.self,
                    at: beginIndex,
                    length: endIndex - beginIndex
                )
            )
        )
    }

    func testGetJSONDecodableFromBufferFailsBecauseShort() {
        self.buffer.writeString("GARBAGE {}!!? / GARBAGE")
        let beginIndex = self.buffer.writerIndex
        self.buffer.writeString(#"{"string": "hello", "int": 42}"#)
        let endIndex = self.buffer.writerIndex

        XCTAssertThrowsError(
            try self.buffer.getJSONDecodable(
                StringAndInt.self,
                at: beginIndex,
                length: endIndex - beginIndex - 1
            )
        ) { error in
            XCTAssert(error is DecodingError)
        }
    }

    func testReadJSONDecodableFromBufferWorks() {
        let beginIndex = self.buffer.writerIndex
        self.buffer.writeString(#"{"string": "hello", "int": 42}"#)
        let endIndex = self.buffer.writerIndex
        self.buffer.writeString("GARBAGE {}!!? / GARBAGE")

        let expectedSandI = StringAndInt(string: "hello", int: 42)
        XCTAssertNoThrow(
            XCTAssertEqual(
                expectedSandI,
                try self.buffer.readJSONDecodable(
                    StringAndInt.self,
                    length: endIndex - beginIndex
                )
            )
        )
    }

    func testReadJSONDecodableFromBufferFailsBecauseShort() {
        let beginIndex = self.buffer.writerIndex
        self.buffer.writeString(#"{"string": "hello", "int": 42}"#)
        let endIndex = self.buffer.writerIndex

        XCTAssertThrowsError(
            try self.buffer.readJSONDecodable(
                StringAndInt.self,
                length: endIndex - beginIndex - 1
            )
        ) { error in
            XCTAssert(error is DecodingError)
        }
    }

    func testReadWriteJSONDecodableWorks() {
        let expectedSandI = StringAndInt(string: "hello", int: 42)
        self.buffer.writeString("hello")
        self.buffer.moveReaderIndex(forwardBy: 5)
        var writtenBytes: Int?
        XCTAssertNoThrow(writtenBytes = try self.buffer.writeJSONEncodable(expectedSandI))
        for _ in 0..<10 {
            XCTAssertNoThrow(try self.buffer.writeJSONEncodable(expectedSandI, encoder: JSONEncoder()))
        }
        for _ in 0..<11 {
            XCTAssertNoThrow(try self.buffer.readJSONDecodable(StringAndInt.self, length: writtenBytes ?? -1))
        }
        XCTAssertEqual(0, self.buffer.readableBytes)
    }

    func testGetSetJSONDecodableWorks() {
        let expectedSandI = StringAndInt(string: "hello", int: 42)
        self.buffer.writeString(String(repeating: "{", count: 1000))
        var writtenBytes: Int?
        XCTAssertNoThrow(
            writtenBytes = try self.buffer.setJSONEncodable(
                expectedSandI,
                at: self.buffer.readerIndex + 123
            )
        )
        XCTAssertNoThrow(
            try self.buffer.setJSONEncodable(
                expectedSandI,
                encoder: JSONEncoder(),
                at: self.buffer.readerIndex + 501
            )
        )
        XCTAssertNoThrow(
            XCTAssertEqual(
                expectedSandI,
                try self.buffer.getJSONDecodable(
                    StringAndInt.self,
                    at: self.buffer.readerIndex + 123,
                    length: writtenBytes ?? -1
                )
            )
        )
        XCTAssertNoThrow(
            XCTAssertEqual(
                expectedSandI,
                try self.buffer.getJSONDecodable(
                    StringAndInt.self,
                    at: self.buffer.readerIndex + 501,
                    length: writtenBytes ?? -1
                )
            )
        )
    }

    func testFailingReadsDoNotChangeReaderIndex() {
        let expectedSandI = StringAndInt(string: "hello", int: 42)
        var writtenBytes: Int?
        XCTAssertNoThrow(writtenBytes = try self.buffer.writeJSONEncodable(expectedSandI))
        for length in 0..<(writtenBytes ?? 0) {
            XCTAssertThrowsError(
                try self.buffer.readJSONDecodable(
                    StringAndInt.self,
                    length: length
                )
            ) { error in
                XCTAssert(error is DecodingError)
            }
        }
        XCTAssertNoThrow(try self.buffer.readJSONDecodable(StringAndInt.self, length: writtenBytes ?? -1))
    }

    func testCustomEncoderIsRespected() {
        let expectedDate = Date(timeIntervalSinceReferenceDate: 86400)
        let strategyExpectation = XCTestExpectation(description: "Custom encoding strategy invoked")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom({ date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
            strategyExpectation.fulfill()
        })
        XCTAssertNoThrow(try encoder.encode(["date": expectedDate], into: &self.buffer))
        XCTAssertEqual(XCTWaiter().wait(for: [strategyExpectation], timeout: 0.0), .completed)
    }

    func testCustomDecoderIsRespected() {
        let expectedDate = Date(timeIntervalSinceReferenceDate: 86400)
        let strategyExpectation = XCTestExpectation(description: "Custom decoding strategy invoked")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .custom({ date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        })
        decoder.dateDecodingStrategy = .custom({ decoder in
            strategyExpectation.fulfill()
            let container = try decoder.singleValueContainer()
            return Date(timeIntervalSinceReferenceDate: try container.decode(Double.self))
        })
        XCTAssertNoThrow(try encoder.encode(["date": expectedDate], into: &self.buffer))
        XCTAssertNoThrow(
            XCTAssertEqual(["date": expectedDate], try decoder.decode(Dictionary<String, Date>.self, from: self.buffer))
        )
        XCTAssertEqual(XCTWaiter().wait(for: [strategyExpectation], timeout: 0.0), .completed)
    }

    func testCustomCodersAreRespectedWhenUsingReadWriteJSONDecodable() {
        let expectedDate = Date(timeIntervalSinceReferenceDate: 86400)
        let decoderStrategyExpectation = XCTestExpectation(description: "Custom decoding strategy invoked")
        let encoderStrategyExpectation = XCTestExpectation(description: "Custom encoding strategy invoked")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .custom({ date, encoder in
            encoderStrategyExpectation.fulfill()
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        })
        decoder.dateDecodingStrategy = .custom({ decoder in
            decoderStrategyExpectation.fulfill()
            let container = try decoder.singleValueContainer()
            return Date(timeIntervalSinceReferenceDate: try container.decode(Double.self))
        })
        XCTAssertNoThrow(try self.buffer.writeJSONEncodable(["date": expectedDate], encoder: encoder))
        XCTAssertNoThrow(
            XCTAssertEqual(
                ["date": expectedDate],
                try self.buffer.readJSONDecodable(
                    Dictionary<String, Date>.self,
                    decoder: decoder,
                    length: self.buffer.readableBytes
                )
            )
        )
        XCTAssertEqual(XCTWaiter().wait(for: [decoderStrategyExpectation], timeout: 0.0), .completed)
        XCTAssertEqual(XCTWaiter().wait(for: [encoderStrategyExpectation], timeout: 0.0), .completed)
    }
}

struct StringAndInt: Codable, Equatable {
    var string: String
    var int: Int
}
