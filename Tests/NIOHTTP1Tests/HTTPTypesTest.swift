//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOHTTP1
import XCTest

final class HTTPTypesTest: XCTestCase {

    func testConvertToString() {
        XCTAssertEqual(HTTPMethod.GET.rawValue, "GET")
        XCTAssertEqual(HTTPMethod.PUT.rawValue, "PUT")
        XCTAssertEqual(HTTPMethod.ACL.rawValue, "ACL")
        XCTAssertEqual(HTTPMethod.HEAD.rawValue, "HEAD")
        XCTAssertEqual(HTTPMethod.POST.rawValue, "POST")
        XCTAssertEqual(HTTPMethod.COPY.rawValue, "COPY")
        XCTAssertEqual(HTTPMethod.LOCK.rawValue, "LOCK")
        XCTAssertEqual(HTTPMethod.MOVE.rawValue, "MOVE")
        XCTAssertEqual(HTTPMethod.BIND.rawValue, "BIND")
        XCTAssertEqual(HTTPMethod.LINK.rawValue, "LINK")
        XCTAssertEqual(HTTPMethod.PATCH.rawValue, "PATCH")
        XCTAssertEqual(HTTPMethod.TRACE.rawValue, "TRACE")
        XCTAssertEqual(HTTPMethod.MKCOL.rawValue, "MKCOL")
        XCTAssertEqual(HTTPMethod.MERGE.rawValue, "MERGE")
        XCTAssertEqual(HTTPMethod.PURGE.rawValue, "PURGE")
        XCTAssertEqual(HTTPMethod.NOTIFY.rawValue, "NOTIFY")
        XCTAssertEqual(HTTPMethod.SEARCH.rawValue, "SEARCH")
        XCTAssertEqual(HTTPMethod.UNLOCK.rawValue, "UNLOCK")
        XCTAssertEqual(HTTPMethod.REBIND.rawValue, "REBIND")
        XCTAssertEqual(HTTPMethod.UNBIND.rawValue, "UNBIND")
        XCTAssertEqual(HTTPMethod.REPORT.rawValue, "REPORT")
        XCTAssertEqual(HTTPMethod.DELETE.rawValue, "DELETE")
        XCTAssertEqual(HTTPMethod.UNLINK.rawValue, "UNLINK")
        XCTAssertEqual(HTTPMethod.CONNECT.rawValue, "CONNECT")
        XCTAssertEqual(HTTPMethod.MSEARCH.rawValue, "MSEARCH")
        XCTAssertEqual(HTTPMethod.OPTIONS.rawValue, "OPTIONS")
        XCTAssertEqual(HTTPMethod.PROPFIND.rawValue, "PROPFIND")
        XCTAssertEqual(HTTPMethod.CHECKOUT.rawValue, "CHECKOUT")
        XCTAssertEqual(HTTPMethod.PROPPATCH.rawValue, "PROPPATCH")
        XCTAssertEqual(HTTPMethod.SUBSCRIBE.rawValue, "SUBSCRIBE")
        XCTAssertEqual(HTTPMethod.MKCALENDAR.rawValue, "MKCALENDAR")
        XCTAssertEqual(HTTPMethod.MKACTIVITY.rawValue, "MKACTIVITY")
        XCTAssertEqual(HTTPMethod.UNSUBSCRIBE.rawValue, "UNSUBSCRIBE")
        XCTAssertEqual(HTTPMethod.SOURCE.rawValue, "SOURCE")
        XCTAssertEqual(HTTPMethod.RAW(value: "SOMETHINGELSE").rawValue, "SOMETHINGELSE")
    }

    func testConvertFromString() {
        XCTAssertEqual(HTTPMethod(rawValue: "GET"), .GET)
        XCTAssertEqual(HTTPMethod(rawValue: "PUT"), .PUT)
        XCTAssertEqual(HTTPMethod(rawValue: "ACL"), .ACL)
        XCTAssertEqual(HTTPMethod(rawValue: "HEAD"), .HEAD)
        XCTAssertEqual(HTTPMethod(rawValue: "POST"), .POST)
        XCTAssertEqual(HTTPMethod(rawValue: "COPY"), .COPY)
        XCTAssertEqual(HTTPMethod(rawValue: "LOCK"), .LOCK)
        XCTAssertEqual(HTTPMethod(rawValue: "MOVE"), .MOVE)
        XCTAssertEqual(HTTPMethod(rawValue: "BIND"), .BIND)
        XCTAssertEqual(HTTPMethod(rawValue: "LINK"), .LINK)
        XCTAssertEqual(HTTPMethod(rawValue: "PATCH"), .PATCH)
        XCTAssertEqual(HTTPMethod(rawValue: "TRACE"), .TRACE)
        XCTAssertEqual(HTTPMethod(rawValue: "MKCOL"), .MKCOL)
        XCTAssertEqual(HTTPMethod(rawValue: "MERGE"), .MERGE)
        XCTAssertEqual(HTTPMethod(rawValue: "PURGE"), .PURGE)
        XCTAssertEqual(HTTPMethod(rawValue: "NOTIFY"), .NOTIFY)
        XCTAssertEqual(HTTPMethod(rawValue: "SEARCH"), .SEARCH)
        XCTAssertEqual(HTTPMethod(rawValue: "UNLOCK"), .UNLOCK)
        XCTAssertEqual(HTTPMethod(rawValue: "REBIND"), .REBIND)
        XCTAssertEqual(HTTPMethod(rawValue: "UNBIND"), .UNBIND)
        XCTAssertEqual(HTTPMethod(rawValue: "REPORT"), .REPORT)
        XCTAssertEqual(HTTPMethod(rawValue: "DELETE"), .DELETE)
        XCTAssertEqual(HTTPMethod(rawValue: "UNLINK"), .UNLINK)
        XCTAssertEqual(HTTPMethod(rawValue: "CONNECT"), .CONNECT)
        XCTAssertEqual(HTTPMethod(rawValue: "MSEARCH"), .MSEARCH)
        XCTAssertEqual(HTTPMethod(rawValue: "OPTIONS"), .OPTIONS)
        XCTAssertEqual(HTTPMethod(rawValue: "PROPFIND"), .PROPFIND)
        XCTAssertEqual(HTTPMethod(rawValue: "CHECKOUT"), .CHECKOUT)
        XCTAssertEqual(HTTPMethod(rawValue: "PROPPATCH"), .PROPPATCH)
        XCTAssertEqual(HTTPMethod(rawValue: "SUBSCRIBE"), .SUBSCRIBE)
        XCTAssertEqual(HTTPMethod(rawValue: "MKCALENDAR"), .MKCALENDAR)
        XCTAssertEqual(HTTPMethod(rawValue: "MKACTIVITY"), .MKACTIVITY)
        XCTAssertEqual(HTTPMethod(rawValue: "UNSUBSCRIBE"), .UNSUBSCRIBE)
        XCTAssertEqual(HTTPMethod(rawValue: "SOURCE"), .SOURCE)
        XCTAssertEqual(HTTPMethod(rawValue: "SOMETHINGELSE"), HTTPMethod.RAW(value: "SOMETHINGELSE"))
    }

    func testConvertFromStringToExplicitValue() {
        switch HTTPMethod(rawValue: "GET") {
        case .RAW(value: "GET"):
            XCTFail("Expected \"GET\" to map to explicit .GET value and not .RAW(value: \"GET\")")
        case .GET:
            break  // everything is awesome
        default:
            XCTFail("Unexpected case")
        }
    }
}
