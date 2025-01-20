//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOEmbedded
import XCTest

@testable import NIOCore
@testable import NIOHTTP1

class HTTPHeadersTest: XCTestCase {
    func testCasePreservedButInsensitiveLookup() {
        let originalHeaders = [
            ("User-Agent", "1"),
            ("host", "2"),
            ("X-SOMETHING", "3"),
            ("SET-COOKIE", "foo=bar"),
            ("Set-Cookie", "buz=cux"),
        ]

        let headers = HTTPHeaders(originalHeaders)

        // looking up headers value is case-insensitive
        XCTAssertEqual(["1"], headers["User-Agent"])
        XCTAssertEqual(["1"], headers["User-agent"])
        XCTAssertEqual(["2"], headers["Host"])
        XCTAssertEqual(["foo=bar", "buz=cux"], headers["set-cookie"])

        for (key, value) in headers {
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

    func testDictionaryLiteralAlternative() {
        let headers: HTTPHeaders = [
            "User-Agent": "1",
            "host": "2",
            "X-SOMETHING": "3",
            "SET-COOKIE": "foo=bar",
            "Set-Cookie": "buz=cux",
        ]

        // looking up headers value is case-insensitive
        XCTAssertEqual(["1"], headers["User-Agent"])
        XCTAssertEqual(["1"], headers["User-agent"])
        XCTAssertEqual(["2"], headers["Host"])
        XCTAssertEqual(["foo=bar", "buz=cux"], headers["set-cookie"])

        for (key, value) in headers {
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
        let originalHeaders = [
            ("User-Agent", "1"),
            ("host", "2"),
            ("X-SOMETHING", "3"),
            ("X-Something", "4"),
            ("SET-COOKIE", "foo=bar"),
            ("Set-Cookie", "buz=cux"),
        ]

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

        XCTAssertTrue(try channel.finish().isClean)
    }

    func testRevealHeadersSeparately() {
        let originalHeaders = [
            ("User-Agent", "1"),
            ("host", "2"),
            ("X-SOMETHING", "3, 4"),
            ("X-Something", "5"),
        ]

        let headers = HTTPHeaders(originalHeaders)
        XCTAssertEqual(headers[canonicalForm: "user-agent"], ["1"])
        XCTAssertEqual(headers[canonicalForm: "host"], ["2"])
        XCTAssertEqual(headers[canonicalForm: "x-something"], ["3", "4", "5"])
        XCTAssertEqual(headers[canonicalForm: "foo"], [])
    }

    func testSubscriptDoesntSplitHeaders() {
        let originalHeaders = [
            ("User-Agent", "1"),
            ("host", "2"),
            ("X-SOMETHING", "3, 4"),
            ("X-Something", "5"),
        ]

        let headers = HTTPHeaders(originalHeaders)
        XCTAssertEqual(headers["user-agent"], ["1"])
        XCTAssertEqual(headers["host"], ["2"])
        XCTAssertEqual(headers["x-something"], ["3, 4", "5"])
        XCTAssertEqual(headers["foo"], [])
    }

    func testCanonicalisationDoesntHappenForSetCookie() {
        let originalHeaders = [
            ("User-Agent", "1"),
            ("host", "2"),
            ("Set-Cookie", "foo=bar; expires=Sun, 17-Mar-2013 13:49:50 GMT"),
            ("Set-Cookie", "buz=cux; expires=Fri, 13 Oct 2017 21:21:41 GMT"),
        ]

        let headers = HTTPHeaders(originalHeaders)
        XCTAssertEqual(headers[canonicalForm: "user-agent"], ["1"])
        XCTAssertEqual(headers[canonicalForm: "host"], ["2"])
        XCTAssertEqual(
            headers[canonicalForm: "set-cookie"],
            [
                "foo=bar; expires=Sun, 17-Mar-2013 13:49:50 GMT",
                "buz=cux; expires=Fri, 13 Oct 2017 21:21:41 GMT",
            ]
        )
    }

    func testTrimWhitespaceWorksOnEmptyString() {
        let expected = ""
        let actual = String("".trimASCIIWhitespace())
        XCTAssertEqual(expected, actual)
    }

    func testTrimWhitespaceWorksOnOnlyWhitespace() {
        let expected = ""
        for wsString in [" ", "\t", "  \t\t \t  "] {
            let actual = String(wsString.trimASCIIWhitespace())
            XCTAssertEqual(expected, actual)
        }
    }

    func testTrimWorksWithCharactersInTheMiddleAndWhitespaceAround() {
        let expected = "x"
        let actual = String("         x\t  ".trimASCIIWhitespace())
        XCTAssertEqual(expected, actual)
    }

    func testContains() {
        let originalHeaders = [
            ("X-Header", "1"),
            ("X-SomeHeader", "3"),
            ("X-Header", "2"),
        ]

        let headers = HTTPHeaders(originalHeaders)
        XCTAssertTrue(headers.contains(name: "x-header"))
        XCTAssertTrue(headers.contains(name: "X-Header"))
        XCTAssertFalse(headers.contains(name: "X-NonExistingHeader"))
    }

    func testFirst() throws {
        let headers = HTTPHeaders([
            (":method", "GET"),
            ("foo", "bar"),
            ("foo", "baz"),
            ("custom-key", "value-1,value-2"),
        ])

        XCTAssertEqual(headers.first(name: ":method"), "GET")
        XCTAssertEqual(headers.first(name: "Foo"), "bar")
        XCTAssertEqual(headers.first(name: "custom-key"), "value-1,value-2")
        XCTAssertNil(headers.first(name: "not-present"))
    }

    func testKeepAliveStateStartsWithClose() {
        var headers = HTTPHeaders([("Connection", "close")])

        XCTAssertEqual("close", headers["connection"].first)
        XCTAssertFalse(headers.isKeepAlive(version: .http1_1))

        headers.replaceOrAdd(name: "connection", value: "keep-alive")

        XCTAssertEqual("keep-alive", headers["connection"].first)
        XCTAssertTrue(headers.isKeepAlive(version: .http1_1))

        headers.remove(name: "connection")
        XCTAssertTrue(headers.isKeepAlive(version: .http1_1))
        XCTAssertFalse(headers.isKeepAlive(version: .http1_0))
    }

    func testKeepAliveStateStartsWithKeepAlive() {
        var headers = HTTPHeaders([("Connection", "keep-alive")])

        XCTAssertEqual("keep-alive", headers["connection"].first)
        XCTAssertTrue(headers.isKeepAlive(version: .http1_1))

        headers.replaceOrAdd(name: "connection", value: "close")

        XCTAssertEqual("close", headers["connection"].first)
        XCTAssertFalse(headers.isKeepAlive(version: .http1_1))

        headers.remove(name: "connection")
        XCTAssertTrue(headers.isKeepAlive(version: .http1_1))
        XCTAssertFalse(headers.isKeepAlive(version: .http1_0))
    }

    func testKeepAliveStateHasKeepAlive() {
        let headers = HTTPHeaders([
            ("Connection", "other, keEP-alive"),
            ("Content-Type", "text/html"),
            ("Connection", "server, x-options"),
        ])

        XCTAssertTrue(headers.isKeepAlive(version: .http1_1))
    }

    func testKeepAliveStateHasClose() {
        let headers = HTTPHeaders([
            ("Connection", "x-options,  other"),
            ("Content-Type", "text/html"),
            ("Connection", "server,     clOse"),
        ])

        XCTAssertFalse(headers.isKeepAlive(version: .http1_1))
    }

    func testRandomAccess() {
        let originalHeaders = [
            ("X-first", "one"),
            ("X-second", "two"),
        ]
        let headers = HTTPHeaders(originalHeaders)

        XCTAssertEqual(headers[headers.startIndex].name, originalHeaders.first?.0)
        XCTAssertEqual(headers[headers.startIndex].value, originalHeaders.first?.1)
        XCTAssertEqual(headers[headers.index(before: headers.endIndex)].name, originalHeaders.last?.0)
        XCTAssertEqual(headers[headers.index(before: headers.endIndex)].value, originalHeaders.last?.1)

        let beforeLast = headers[headers.index(before: headers.endIndex)]
        XCTAssertEqual(beforeLast.name, originalHeaders[originalHeaders.endIndex - 1].0)
        XCTAssertEqual(beforeLast.value, originalHeaders[originalHeaders.endIndex - 1].1)

        let afterFirst = headers[headers.index(after: headers.startIndex)]
        XCTAssertEqual(afterFirst.name, originalHeaders[originalHeaders.startIndex + 1].0)
        XCTAssertEqual(afterFirst.value, originalHeaders[originalHeaders.startIndex + 1].1)
    }

    func testCanBeSeededWithKeepAliveState() {
        // we may later on decide that this test doesn't make sense but for now we want to keep the seeding behaviour.
        let headersSeededWithClose = HTTPHeaders([], keepAliveState: .close)
        XCTAssertEqual(false, headersSeededWithClose.isKeepAlive(version: .init(major: 0, minor: 0)))

        let headersSeededWithKeepAlive = HTTPHeaders([], keepAliveState: .keepAlive)
        XCTAssertEqual(true, headersSeededWithKeepAlive.isKeepAlive(version: .init(major: 0, minor: 0)))
    }

    func testSeedDominatesActualValue() {
        // we may later on decide that this test doesn't make sense but for now we want to keep the seeding behaviour
        let headersSeededWithClose = HTTPHeaders([], keepAliveState: .close)
        XCTAssertEqual(false, headersSeededWithClose.isKeepAlive(version: .http1_1))

        let headersSeededWithKeepAlive = HTTPHeaders([], keepAliveState: .keepAlive)
        XCTAssertEqual(true, headersSeededWithKeepAlive.isKeepAlive(version: .http1_0))
    }

    func testSeedDominatesEvenAfterMutation() {
        // we may later on decide that this test doesn't make sense but for now we want to keep the seeding behaviour
        var headersSeededWithClose = HTTPHeaders([], keepAliveState: .close)
        headersSeededWithClose.add(name: "foo", value: "bar")
        headersSeededWithClose.add(name: "bar", value: "qux")
        headersSeededWithClose.remove(name: "bar")
        XCTAssertEqual(false, headersSeededWithClose.isKeepAlive(version: .http1_1))

        var headersSeededWithKeepAlive = HTTPHeaders([], keepAliveState: .keepAlive)
        headersSeededWithKeepAlive.add(name: "foo", value: "bar")
        headersSeededWithKeepAlive.add(name: "bar", value: "qux")
        headersSeededWithKeepAlive.remove(name: "bar")
        XCTAssertEqual(true, headersSeededWithKeepAlive.isKeepAlive(version: .http1_0))
    }

    func testSeedGetsUpdatedToDefaultOnConnectionHeaderModification() {
        var headersSeededWithClose = HTTPHeaders([], keepAliveState: .close)
        headersSeededWithClose.add(name: "connection", value: "bar")
        XCTAssertEqual(true, headersSeededWithClose.isKeepAlive(version: .http1_1))
        XCTAssertEqual(false, headersSeededWithClose.isKeepAlive(version: .http1_0))

        var headersSeededWithKeepAlive = HTTPHeaders([], keepAliveState: .keepAlive)
        headersSeededWithKeepAlive.add(name: "connection", value: "bar")
        XCTAssertEqual(true, headersSeededWithKeepAlive.isKeepAlive(version: .http1_1))
        XCTAssertEqual(false, headersSeededWithKeepAlive.isKeepAlive(version: .http1_0))
    }

    func testSeedGetsUpdatedToWhateverTheHeaderSaysIfPresent() {
        var headersSeededWithClose = HTTPHeaders([], keepAliveState: .close)
        headersSeededWithClose.add(name: "connection", value: "bar,keep-alive,true")
        XCTAssertEqual(true, headersSeededWithClose.isKeepAlive(version: .http1_1))
        XCTAssertEqual(true, headersSeededWithClose.isKeepAlive(version: .http1_0))

        var headersSeededWithKeepAlive = HTTPHeaders([], keepAliveState: .keepAlive)
        headersSeededWithKeepAlive.add(name: "connection", value: "bar,close,true")
        XCTAssertEqual(false, headersSeededWithKeepAlive.isKeepAlive(version: .http1_1))
        XCTAssertEqual(false, headersSeededWithKeepAlive.isKeepAlive(version: .http1_0))
    }

    func testWeDefaultToCloseIfDoesNotMakeSense() {
        var nonSenseInOneHeaderCK = HTTPHeaders([])
        nonSenseInOneHeaderCK.add(name: "connection", value: "close,keep-alive")
        XCTAssertEqual(false, nonSenseInOneHeaderCK.isKeepAlive(version: .http1_1))
        XCTAssertEqual(false, nonSenseInOneHeaderCK.isKeepAlive(version: .http1_0))

        var nonSenseInMultipleHeadersCK = HTTPHeaders([])
        nonSenseInMultipleHeadersCK.add(name: "connection", value: "close")
        nonSenseInMultipleHeadersCK.add(name: "connection", value: "keep-alive")
        XCTAssertEqual(false, nonSenseInMultipleHeadersCK.isKeepAlive(version: .http1_1))
        XCTAssertEqual(false, nonSenseInMultipleHeadersCK.isKeepAlive(version: .http1_0))

        var nonSenseInOneHeaderKC = HTTPHeaders([])
        nonSenseInOneHeaderKC.add(name: "connection", value: "keep-alive,close")
        XCTAssertEqual(false, nonSenseInOneHeaderKC.isKeepAlive(version: .http1_1))
        XCTAssertEqual(false, nonSenseInOneHeaderKC.isKeepAlive(version: .http1_0))

        var nonSenseInMultipleHeadersKC = HTTPHeaders([])
        nonSenseInMultipleHeadersKC.add(name: "connection", value: "keep-alive")
        nonSenseInMultipleHeadersKC.add(name: "connection", value: "close")
        XCTAssertEqual(false, nonSenseInMultipleHeadersKC.isKeepAlive(version: .http1_1))
        XCTAssertEqual(false, nonSenseInMultipleHeadersKC.isKeepAlive(version: .http1_0))
    }

    func testAddingSequenceOfPairs() {
        var headers = HTTPHeaders([], keepAliveState: .keepAlive)
        let fooBar = [("foo", "bar"), ("bar", "qux"), ("connection", "foo")]
        headers.add(contentsOf: fooBar)

        XCTAssertEqual(["bar"], headers["foo"])
        XCTAssertEqual(["qux"], headers["bar"])
        XCTAssertEqual(.unknown, headers.keepAliveState)
    }

    func testAddingOtherHTTPHeader() {
        var fooBarHeaders = HTTPHeaders([("foo", "bar"), ("bar", "qux")], keepAliveState: .keepAlive)
        let bazHeaders = HTTPHeaders([("bar", "baz"), ("baz", "bazzy")], keepAliveState: .unknown)
        fooBarHeaders.add(contentsOf: bazHeaders)

        XCTAssertEqual(["bar"], fooBarHeaders["foo"])
        XCTAssertEqual(["qux", "baz"], fooBarHeaders["bar"])
        XCTAssertEqual(["bazzy"], fooBarHeaders["baz"])
        XCTAssertEqual(.unknown, fooBarHeaders.keepAliveState)
    }

    func testCapacity() {
        // no headers
        var headers = HTTPHeaders()
        XCTAssertEqual(headers.capacity, 0)
        // reserve capacity
        headers.reserveCapacity(5)
        XCTAssertEqual(headers.capacity, 5)

        // initialize with some headers
        headers = HTTPHeaders([("foo", "bar")])
        XCTAssertEqual(headers.capacity, 1)
        // reserve more capacity
        headers.reserveCapacity(4)
        XCTAssertEqual(headers.capacity, 4)
    }

    func testHTTPHeadersDescription() {
        let originalHeaders = [
            ("User-Agent", "1"),
            ("host", "2"),
            ("X-SOMETHING", "3"),
            ("SET-COOKIE", "foo=bar"),
            ("Set-Cookie", "buz=cux"),
        ]

        let headers = HTTPHeaders(originalHeaders)

        let expectedOutput = """
            User-Agent: 1; \
            host: 2; \
            X-SOMETHING: 3; \
            SET-COOKIE: foo=bar; \
            Set-Cookie: buz=cux
            """

        XCTAssertEqual(expectedOutput, headers.description)
    }
}
