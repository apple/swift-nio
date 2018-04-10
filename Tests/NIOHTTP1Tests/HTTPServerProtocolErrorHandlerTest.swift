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
import NIO
import NIOHTTP1

class HTTPServerProtocolErrorHandlerTest: XCTestCase {
    func testHandlesBasicErrors() throws {
        let channel = EmbeddedChannel()
        XCTAssertNoThrow(try channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).wait())

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.write(staticString: "GET / HTTP/1.1\r\nContent-Length: -4\r\n\r\n")
        do {
            try channel.writeInbound(buffer)
        } catch HTTPParserError.invalidContentLength {
            // This error is expected
        }
        (channel.eventLoop as! EmbeddedEventLoop).run()

        // The channel should be closed at this stage.
        XCTAssertNoThrow(try channel.closeFuture.wait())

        // We expect exactly one ByteBuffer in the output.
        guard case .some(.byteBuffer(var written)) = channel.readOutbound() else {
            XCTFail("No writes")
            return
        }

        XCTAssertNil(channel.readOutbound())

        // Check the response.
        assertResponseIs(response: written.readString(length: written.readableBytes)!,
                         expectedResponseLine: "HTTP/1.1 400 Bad Request",
                         expectedResponseHeaders: ["Connection: close", "Content-Length: 0"])
    }

    func testIgnoresNonParserErrors() throws {
        enum DummyError: Error {
            case error
        }
        let channel = EmbeddedChannel()
        XCTAssertNoThrow(try channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).wait())

        channel.pipeline.fireErrorCaught(DummyError.error)
        do {
            try channel.throwIfErrorCaught()
            XCTFail("No error caught")
        } catch DummyError.error {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNoThrow(try channel.finish())
    }
}
