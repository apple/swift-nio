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

private final class TestChannelInboundHandler: ChannelInboundHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias InboundOut = HTTPServerRequestPart

    private let body: (HTTPServerRequestPart) -> HTTPServerRequestPart

    init(_ body: @escaping (HTTPServerRequestPart) -> HTTPServerRequestPart) {
        self.body = body
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(Self.wrapInboundOut(self.body(Self.unwrapInboundIn(data))))
    }
}

class HTTPTest: XCTestCase {

    func checkHTTPRequest(_ expected: HTTPRequestHead, body: String? = nil, trailers: HTTPHeaders? = nil) throws {
        try checkHTTPRequests([expected], body: body, trailers: trailers)
    }

    func checkHTTPRequests(_ expecteds: [HTTPRequestHead], body: String? = nil, trailers: HTTPHeaders? = nil) throws {
        func httpRequestStrForRequest(_ req: HTTPRequestHead) -> String {
            var s = "\(req.method) \(req.uri) HTTP/\(req.version.major).\(req.version.minor)\r\n"
            for (k, v) in req.headers {
                s += "\(k): \(v)\r\n"
            }
            if trailers != nil {
                s += "Transfer-Encoding: chunked\r\n"
                s += "\r\n"
                if let body = body {
                    s += String(body.utf8.count, radix: 16)
                    s += "\r\n"
                    s += body
                    s += "\r\n"
                }
                s += "0\r\n"
                if let trailers = trailers {
                    for (k, v) in trailers {
                        s += "\(k): \(v)\r\n"
                    }
                }
                s += "\r\n"
            } else if let body = body {
                let bodyData = body.data(using: .utf8)!
                s += "Content-Length: \(bodyData.count)\r\n"
                s += "\r\n"
                s += body
            } else {
                s += "\r\n"
            }
            return s
        }

        func sendAndCheckRequests(
            _ expecteds: [HTTPRequestHead],
            body: String?,
            trailers: HTTPHeaders?,
            sendStrategy: (String, EmbeddedChannel) -> EventLoopFuture<Void>
        ) throws -> String? {
            var step = 0
            var index = 0
            let channel = EmbeddedChannel()
            defer {
                XCTAssertNoThrow(try channel.finish())
            }
            try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(HTTPRequestDecoder()))
            var bodyData: [UInt8]? = nil
            var allBodyDatas: [[UInt8]] = []
            try channel.pipeline.syncOperations.addHandler(
                TestChannelInboundHandler { reqPart in
                    switch reqPart {
                    case .head(var req):
                        XCTAssertEqual((index * 2), step)
                        req.headers.remove(name: "Content-Length")
                        req.headers.remove(name: "Transfer-Encoding")
                        XCTAssertEqual(expecteds[index], req)
                        step += 1
                    case .body(var buffer):
                        if bodyData == nil {
                            bodyData = buffer.readBytes(length: buffer.readableBytes)!
                        } else {
                            bodyData!.append(contentsOf: buffer.readBytes(length: buffer.readableBytes)!)
                        }
                    case .end(let receivedTrailers):
                        XCTAssertEqual(trailers, receivedTrailers)
                        step += 1
                        XCTAssertEqual(((index + 1) * 2), step)
                    }
                    return reqPart
                }
            )

            var writeFutures: [EventLoopFuture<Void>] = []
            for expected in expecteds {
                writeFutures.append(sendStrategy(httpRequestStrForRequest(expected), channel))
                index += 1
                if let bodyData = bodyData {
                    allBodyDatas.append(bodyData)
                }
                bodyData = nil
            }
            channel.pipeline.flush()
            XCTAssertNoThrow(try EventLoopFuture.andAllSucceed(writeFutures, on: channel.eventLoop).wait())
            XCTAssertEqual(2 * expecteds.count, step)

            if body != nil {
                XCTAssertGreaterThan(allBodyDatas.count, 0)
                let firstBodyData = allBodyDatas[0]
                for bodyData in allBodyDatas {
                    XCTAssertEqual(firstBodyData, bodyData)
                }
                return String(decoding: firstBodyData, as: Unicode.UTF8.self)
            } else {
                XCTAssertEqual(0, allBodyDatas.count, "left with \(allBodyDatas)")
                return nil
            }
        }

        // send all bytes in one go
        let bd1 = try sendAndCheckRequests(
            expecteds,
            body: body,
            trailers: trailers,
            sendStrategy: { (reqString, chan) in
                chan.eventLoop.makeSucceededFuture(()).flatMapThrowing {
                    var buf = chan.allocator.buffer(capacity: 1024)
                    buf.writeString(reqString)
                    try chan.writeInbound(buf)
                }
            }
        )

        // send the bytes one by one
        let bd2 = try sendAndCheckRequests(
            expecteds,
            body: body,
            trailers: trailers,
            sendStrategy: { (reqString, chan) in
                var writeFutures: [EventLoopFuture<Void>] = []
                for c in reqString {
                    var buf = chan.allocator.buffer(capacity: 1024)

                    buf.writeString("\(c)")
                    writeFutures.append(
                        chan.eventLoop.makeSucceededFuture(()).flatMapThrowing { [buf] in
                            try chan.writeInbound(buf)
                        }
                    )
                }
                return EventLoopFuture.andAllSucceed(writeFutures, on: chan.eventLoop)
            }
        )

        XCTAssertEqual(bd1, bd2)
        XCTAssertEqual(body, bd1)
    }

    func testHTTPSimpleNoHeaders() throws {
        try checkHTTPRequest(HTTPRequestHead(version: .http1_1, method: .GET, uri: "/"))
    }

    func testHTTPSimple1Header() throws {
        var req = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/hello/world")
        req.headers.add(name: "foo", value: "bar")
        try checkHTTPRequest(req)
    }

    func testHTTPSimpleSomeHeader() throws {
        var req = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/foo/bar/buz?qux=quux")
        req.headers.add(name: "foo", value: "bar")
        req.headers.add(name: "qux", value: "quuux")
        try checkHTTPRequest(req)
    }

    func testHTTPPipelining() throws {
        var req1 = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/foo/bar/buz?qux=quux")
        req1.headers.add(name: "foo", value: "bar")
        req1.headers.add(name: "qux", value: "quuux")
        var req2 = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        req2.headers.add(name: "a", value: "b")
        req2.headers.add(name: "C", value: "D")

        try checkHTTPRequests([req1, req2])
        try checkHTTPRequests(Array(repeating: req1, count: 10))
    }

    func testHTTPBody() throws {
        try checkHTTPRequest(
            HTTPRequestHead(version: .http1_1, method: .GET, uri: "/"),
            body: "hello world"
        )
    }

    func test1ByteHTTPBody() throws {
        try checkHTTPRequest(
            HTTPRequestHead(version: .http1_1, method: .GET, uri: "/"),
            body: "1"
        )
    }

    func testHTTPPipeliningWithBody() throws {
        try checkHTTPRequests(
            Array(
                repeating: HTTPRequestHead(
                    version: .http1_1,
                    method: .GET,
                    uri: "/"
                ),
                count: 20
            ),
            body: "1"
        )
    }

    func testChunkedBody() throws {
        var trailers = HTTPHeaders()
        trailers.add(name: "X-Key", value: "X-Value")
        trailers.add(name: "Something", value: "Else")
        try checkHTTPRequest(
            HTTPRequestHead(version: .http1_1, method: .POST, uri: "/"),
            body: "100",
            trailers: trailers
        )
    }

    func testHTTPRequestHeadCoWWorks() throws {
        let headers = HTTPHeaders([("foo", "bar")])
        var httpReq = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/uri")
        httpReq.headers = headers

        var modVersion = httpReq
        modVersion.version = .http2
        XCTAssertEqual(.http1_1, httpReq.version)
        XCTAssertEqual(.http2, modVersion.version)

        var modMethod = httpReq
        modMethod.method = .POST
        XCTAssertEqual(.GET, httpReq.method)
        XCTAssertEqual(.POST, modMethod.method)

        var modURI = httpReq
        modURI.uri = "/changed"
        XCTAssertEqual("/uri", httpReq.uri)
        XCTAssertEqual("/changed", modURI.uri)

        var modHeaders = httpReq
        modHeaders.headers.add(name: "qux", value: "quux")
        XCTAssertEqual(httpReq.headers, headers)
        XCTAssertNotEqual(httpReq, modHeaders)
        modHeaders.headers.remove(name: "foo")
        XCTAssertEqual(httpReq.headers, headers)
        XCTAssertNotEqual(httpReq, modHeaders)
        modHeaders.headers.remove(name: "qux")
        modHeaders.headers.add(name: "foo", value: "bar")
        XCTAssertEqual(httpReq, modHeaders)
    }

    func testHTTPResponseHeadCoWWorks() throws {
        let headers = HTTPHeaders([("foo", "bar")])
        let httpRes = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)

        var modVersion = httpRes
        modVersion.version = .http2
        XCTAssertEqual(.http1_1, httpRes.version)
        XCTAssertEqual(.http2, modVersion.version)

        var modStatus = httpRes
        modStatus.status = .notFound
        XCTAssertEqual(.ok, httpRes.status)
        XCTAssertEqual(.notFound, modStatus.status)

        var modHeaders = httpRes
        modHeaders.headers.add(name: "qux", value: "quux")
        XCTAssertEqual(httpRes.headers, headers)
        XCTAssertNotEqual(httpRes, modHeaders)
        modHeaders.headers.remove(name: "foo")
        XCTAssertEqual(httpRes.headers, headers)
        XCTAssertNotEqual(httpRes, modHeaders)
        modHeaders.headers.remove(name: "qux")
        modHeaders.headers.add(name: "foo", value: "bar")
        XCTAssertEqual(httpRes, modHeaders)
    }
}
