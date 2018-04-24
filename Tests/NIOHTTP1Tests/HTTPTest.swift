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

private final class TestChannelInboundHandler: ChannelInboundHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias InboundOut = HTTPServerRequestPart

    private let body: (HTTPServerRequestPart) -> HTTPServerRequestPart

    init(_ body: @escaping (HTTPServerRequestPart) -> HTTPServerRequestPart) {
        self.body = body
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        ctx.fireChannelRead(self.wrapInboundOut(self.body(self.unwrapInboundIn(data))))
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

        func sendAndCheckRequests(_ expecteds: [HTTPRequestHead], body: String?, trailers: HTTPHeaders?, sendStrategy: (String, EmbeddedChannel) -> EventLoopFuture<Void>) throws -> String? {
            var step = 0
            var index = 0
            let channel = EmbeddedChannel()
            defer {
                XCTAssertNoThrow(try channel.finish())
            }
            try channel.pipeline.add(handler: HTTPRequestDecoder()).wait()
            var bodyData: [UInt8]? = nil
            var allBodyDatas: [[UInt8]] = []
            try channel.pipeline.add(handler: TestChannelInboundHandler { reqPart in
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
            }).wait()

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
            XCTAssertNoThrow(try EventLoopFuture<Void>.andAll(writeFutures, eventLoop: channel.eventLoop).wait())
            XCTAssertEqual(2 * expecteds.count, step)

            if body != nil {
                XCTAssertGreaterThan(allBodyDatas.count, 0)
                let firstBodyData = allBodyDatas[0]
                for bodyData in allBodyDatas {
                    XCTAssertEqual(firstBodyData, bodyData)
                }
                return String(decoding: firstBodyData, as: UTF8.self)
            } else {
                XCTAssertEqual(0, allBodyDatas.count, "left with \(allBodyDatas)")
                return nil
            }
        }

        /* send all bytes in one go */
        let bd1 = try sendAndCheckRequests(expecteds, body: body, trailers: trailers, sendStrategy: { (reqString, chan) in
            var buf = chan.allocator.buffer(capacity: 1024)
            buf.write(string: reqString)
            return chan.eventLoop.newSucceededFuture(result: ()).thenThrowing {
                try chan.writeInbound(buf)
            }
        })

        /* send the bytes one by one */
        let bd2 = try sendAndCheckRequests(expecteds, body: body, trailers: trailers, sendStrategy: { (reqString, chan) in
            var writeFutures: [EventLoopFuture<Void>] = []
            for c in reqString {
                var buf = chan.allocator.buffer(capacity: 1024)

                buf.write(string: "\(c)")
                writeFutures.append(chan.eventLoop.newSucceededFuture(result: ()).thenThrowing {
                    try chan.writeInbound(buf)
                })
            }
            return EventLoopFuture<Void>.andAll(writeFutures, eventLoop: chan.eventLoop)
        })

        XCTAssertEqual(bd1, bd2)
        XCTAssertEqual(body, bd1)
    }

    func testHTTPSimpleNoHeaders() throws {
        try checkHTTPRequest(HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/"))
    }

    func testHTTPSimple1Header() throws {
        var req = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/hello/world")
        req.headers.add(name: "foo", value: "bar")
        try checkHTTPRequest(req)
    }

    func testHTTPSimpleSomeHeader() throws {
        var req = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/foo/bar/buz?qux=quux")
        req.headers.add(name: "foo", value: "bar")
        req.headers.add(name: "qux", value: "quuux")
        try checkHTTPRequest(req)
    }

    func testHTTPPipelining() throws {
        var req1 = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/foo/bar/buz?qux=quux")
        req1.headers.add(name: "foo", value: "bar")
        req1.headers.add(name: "qux", value: "quuux")
        var req2 = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/")
        req2.headers.add(name: "a", value: "b")
        req2.headers.add(name: "C", value: "D")

        try checkHTTPRequests([req1, req2])
        try checkHTTPRequests(Array(repeating: req1, count: 1000))
    }

    func testHTTPBody() throws {
        try checkHTTPRequest(HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/"),
                             body: "hello world")
    }

    func test1ByteHTTPBody() throws {
        try checkHTTPRequest(HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/"),
                             body: "1")
    }

    func testHTTPPipeliningWithBody() throws {
        try checkHTTPRequests(Array(repeating: HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/"), count: 1000),
                             body: "1")
    }

    func testChunkedBody() throws {
        var trailers = HTTPHeaders()
        trailers.add(name: "X-Key", value: "X-Value")
        trailers.add(name: "Something", value: "Else")
        try checkHTTPRequest(HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .POST, uri: "/"), body: "100", trailers: trailers)
    }

    func testHTTPRequestHeadCoWWorks() throws {
        let headers = HTTPHeaders([("foo", "bar")])
        var httpReq = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/uri")
        httpReq.headers = headers

        var modVersion = httpReq
        modVersion.version = HTTPVersion(major: 2, minor: 0)
        XCTAssertEqual(HTTPVersion(major: 1, minor: 1), httpReq.version)
        XCTAssertEqual(HTTPVersion(major: 2, minor: 0), modVersion.version)

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
        let httpRes = HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: .ok, headers: headers)

        var modVersion = httpRes
        modVersion.version = HTTPVersion(major: 2, minor: 0)
        XCTAssertEqual(HTTPVersion(major: 1, minor: 1), httpRes.version)
        XCTAssertEqual(HTTPVersion(major: 2, minor: 0), modVersion.version)

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
