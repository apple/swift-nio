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
        headers.write(buffer: &buffer)

        let writtenBytes = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes)!
        XCTAssertTrue(writtenBytes.contains("user-agent: 1\r\n"))
        XCTAssertTrue(writtenBytes.contains("host: 2\r\n"))
        XCTAssertTrue(writtenBytes.contains("x-something: 3,4\r\n"))
        XCTAssertTrue(writtenBytes.contains("set-cookie: foo=bar\r\n"))
        XCTAssertTrue(writtenBytes.contains("set-cookie: buz=cux\r\n"))
    }

    func testRevealHeadersSeparately() {
        let originalHeaders = [ ("User-Agent", "1"),
                                ("host", "2"),
                                ("X-SOMETHING", "3, 4"),
                                ("X-Something", "5")]

        let headers = HTTPHeaders(originalHeaders)
        XCTAssertEqual(headers.getCanonicalForm("user-agent"), ["1"])
        XCTAssertEqual(headers.getCanonicalForm("host"), ["2"])
        XCTAssertEqual(headers.getCanonicalForm("x-something"), ["3", "4", "5"])
        XCTAssertEqual(headers.getCanonicalForm("foo"), [])
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
        XCTAssertEqual(headers.getCanonicalForm("user-agent"), ["1"])
        XCTAssertEqual(headers.getCanonicalForm("host"), ["2"])
        XCTAssertEqual(headers.getCanonicalForm("set-cookie"), ["foo=bar; expires=Sun, 17-Mar-2013 13:49:50 GMT",
                                                                "buz=cux; expires=Fri, 13 Oct 2017 21:21:41 GMT"])
    }
}
