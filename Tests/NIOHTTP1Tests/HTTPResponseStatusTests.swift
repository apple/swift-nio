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
import NIOHTTP1
import XCTest

class HTTPResponseStatusTests: XCTestCase {
    func testHTTPResponseStatusFromStatusCode() {
        XCTAssertEqual(HTTPResponseStatus(statusCode: 100), .continue)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 101), .switchingProtocols)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 102), .processing)

        XCTAssertEqual(HTTPResponseStatus(statusCode: 200), .ok)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 201), .created)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 202), .accepted)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 203), .nonAuthoritativeInformation)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 204), .noContent)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 205), .resetContent)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 206), .partialContent)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 207), .multiStatus)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 208), .alreadyReported)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 226), .imUsed)

        XCTAssertEqual(HTTPResponseStatus(statusCode: 300), .multipleChoices)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 301), .movedPermanently)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 302), .found)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 303), .seeOther)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 304), .notModified)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 305), .useProxy)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 307), .temporaryRedirect)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 308), .permanentRedirect)

        XCTAssertEqual(HTTPResponseStatus(statusCode: 400), .badRequest)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 401), .unauthorized)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 402), .paymentRequired)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 403), .forbidden)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 404), .notFound)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 405), .methodNotAllowed)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 406), .notAcceptable)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 407), .proxyAuthenticationRequired)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 408), .requestTimeout)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 409), .conflict)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 410), .gone)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 411), .lengthRequired)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 412), .preconditionFailed)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 413), .payloadTooLarge)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 414), .uriTooLong)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 415), .unsupportedMediaType)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 416), .rangeNotSatisfiable)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 417), .expectationFailed)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 418), .imATeapot)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 421), .misdirectedRequest)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 422), .unprocessableEntity)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 423), .locked)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 424), .failedDependency)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 426), .upgradeRequired)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 428), .preconditionRequired)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 429), .tooManyRequests)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 431), .requestHeaderFieldsTooLarge)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 451), .unavailableForLegalReasons)

        XCTAssertEqual(HTTPResponseStatus(statusCode: 500), .internalServerError)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 501), .notImplemented)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 502), .badGateway)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 503), .serviceUnavailable)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 504), .gatewayTimeout)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 505), .httpVersionNotSupported)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 506), .variantAlsoNegotiates)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 507), .insufficientStorage)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 508), .loopDetected)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 510), .notExtended)
        XCTAssertEqual(HTTPResponseStatus(statusCode: 511), .networkAuthenticationRequired)
    }

    func testHTTPResponseStatusCodeAndReason() {
        XCTAssertEqual("\(HTTPResponseStatus.ok)", "200 OK")
        XCTAssertEqual("\(HTTPResponseStatus.imATeapot)", "418 I'm a teapot")
        XCTAssertEqual(
            "\(HTTPResponseStatus.custom(code: 347, reasonPhrase: "I like ice cream"))",
            "347 I like ice cream"
        )
    }
}
