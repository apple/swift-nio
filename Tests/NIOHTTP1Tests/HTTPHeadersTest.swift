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
@testable import NIOHTTP1

class HTTPHeadersTest : XCTestCase {
    func testCasePreservedButInsensitiveLookup() {
        let originalHeaders = [ ("User-Agent", "1"),
                                ("host", "2"),
                                ("X-SOMETHING", "3"),
                                ("SET-COOKIE", "foo=bar"),
                                ("Set-Cookie", "buz=cux")]

        let headers = HTTPHeaders(originalHeaders)

        // looking up headers value is case-insensitive
        XCTAssertEqual(["1"], headers["User-Agent"])
        XCTAssertEqual(["1"], headers["User-agent"])
        XCTAssertEqual(["2"], headers["Host"])
        XCTAssertEqual(["foo=bar", "buz=cux"], headers["set-cookie"])

        for (key,value) in headers {
            switch key {
            case "User-Agent":
                XCTAssertEqual("1", value)
            case "host":
                XCTAssertEqual("2", value)
            case "X-SOMETHING":
                XCTAssertEqual("3", value)
            case "SET-COOKIE":
                XCTAssertEqual("foo=bar", value)
            case "Set-Cookie":
                XCTAssertEqual("buz=cux", value)
            default:
                XCTFail("Unexpected key: \(key)")
            }
        }
    }

    func testWriteHeadersSeparately() {
        let originalHeaders = [ ("User-Agent", "1"),
                                ("host", "2"),
                                ("X-SOMETHING", "3"),
                                ("X-Something", "4"),
                                ("SET-COOKIE", "foo=bar"),
                                ("Set-Cookie", "buz=cux")]

        let headers = HTTPHeaders(originalHeaders)
        let channel = EmbeddedChannel()
        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.write(headers: headers)

        let writtenBytes = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes)!
        XCTAssertTrue(writtenBytes.contains("User-Agent: 1\r\n"))
        XCTAssertTrue(writtenBytes.contains("host: 2\r\n"))
        XCTAssertTrue(writtenBytes.contains("X-SOMETHING: 3\r\n"))
        XCTAssertTrue(writtenBytes.contains("X-Something: 4\r\n"))
        XCTAssertTrue(writtenBytes.contains("SET-COOKIE: foo=bar\r\n"))
        XCTAssertTrue(writtenBytes.contains("Set-Cookie: buz=cux\r\n"))

        XCTAssertFalse(try channel.finish())
    }

    func testRevealHeadersSeparately() {
        let originalHeaders = [ ("User-Agent", "1"),
                                ("host", "2"),
                                ("X-SOMETHING", "3, 4"),
                                ("X-Something", "5")]

        let headers = HTTPHeaders(originalHeaders)
        XCTAssertEqual(headers[canonicalForm: "user-agent"], ["1"])
        XCTAssertEqual(headers[canonicalForm: "host"], ["2"])
        XCTAssertEqual(headers[canonicalForm: "x-something"], ["3", "4", "5"])
        XCTAssertEqual(headers[canonicalForm: "foo"], [])
    }

    func testSubscriptDoesntSplitHeaders() {
        let originalHeaders = [ ("User-Agent", "1"),
                                ("host", "2"),
                                ("X-SOMETHING", "3, 4"),
                                ("X-Something", "5")]

        let headers = HTTPHeaders(originalHeaders)
        XCTAssertEqual(headers["user-agent"], ["1"])
        XCTAssertEqual(headers["host"], ["2"])
        XCTAssertEqual(headers["x-something"], ["3, 4", "5"])
        XCTAssertEqual(headers["foo"], [])
    }

    func testCanonicalisationDoesntHappenForSetCookie() {
        let originalHeaders = [ ("User-Agent", "1"),
                                ("host", "2"),
                                ("Set-Cookie", "foo=bar; expires=Sun, 17-Mar-2013 13:49:50 GMT"),
                                ("Set-Cookie", "buz=cux; expires=Fri, 13 Oct 2017 21:21:41 GMT")]

        let headers = HTTPHeaders(originalHeaders)
        XCTAssertEqual(headers[canonicalForm: "user-agent"], ["1"])
        XCTAssertEqual(headers[canonicalForm: "host"], ["2"])
        XCTAssertEqual(headers[canonicalForm: "set-cookie"], ["foo=bar; expires=Sun, 17-Mar-2013 13:49:50 GMT",
                                                              "buz=cux; expires=Fri, 13 Oct 2017 21:21:41 GMT"])
    }

    func testTrimWhitespaceWorksOnEmptyString() {
        let expected = ""
        let actual = String("".trimASCIIWhitespace())
        XCTAssertEqual(expected, actual)
    }

    func testTrimWhitespaceWorksOnOnlyWhitespace() {
        let expected = ""
        for wsString in [" ", "\t", "\r", "\n", "\r\n", "\n\r", "  \r\n \n\r\t\r\t\n"] {
            let actual = String(wsString.trimASCIIWhitespace())
            XCTAssertEqual(expected, actual)
        }
    }

    func testTrimWorksWithCharactersInTheMiddleAndWhitespaceAround() {
        let expected = "x"
        let actual = String("         x\n\n\n".trimASCIIWhitespace())
        XCTAssertEqual(expected, actual)
    }

    func testContains() {
        let originalHeaders = [ ("X-Header", "1"),
                                ("X-SomeHeader", "3"),
                                ("X-Header", "2")]

        let headers = HTTPHeaders(originalHeaders)
        XCTAssertTrue(headers.contains(name: "x-header"))
        XCTAssertTrue(headers.contains(name: "X-Header"))
        XCTAssertFalse(headers.contains(name: "X-NonExistingHeader"))
    }
}
