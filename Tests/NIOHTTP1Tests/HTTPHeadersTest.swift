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

import Foundation
import XCTest
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
}
