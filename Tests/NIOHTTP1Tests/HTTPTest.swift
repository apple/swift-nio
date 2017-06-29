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

    private let fn: (IOData) -> IOData

    init(_ fn: @escaping (IOData) -> IOData) {
        self.fn = fn
    }

    public func channelRead(ctx: ChannelHandlerContext, data: IOData) {
        ctx.fireChannelRead(data: self.fn(data))
    }
}


class HTTPTest: XCTestCase {

    func checkHTTPRequest(_ expected: HTTPRequestHead, body: String? = nil) throws {
        try checkHTTPRequests([expected], body: body)
    }

    func checkHTTPRequests(_ expecteds: [HTTPRequestHead], body: String? = nil) throws {
        func httpRequestStrForRequest(_ req: HTTPRequestHead) -> String {
            var s = "\(req.method) \(req.uri) HTTP/\(req.version.major).\(req.version.minor)\r\n"
            for (k, vs) in req.headers {
                for v in vs {
                    s += "\(k): \(v)\r\n"
                }
            }
            if let body = body {
                let bodyData = body.data(using: .utf8)!
                s += "Content-Length: \(bodyData.count)\r\n"
                s += "\r\n"
                s += body
            } else {
                s += "\r\n"
            }
            return s
        }

        func sendAndCheckRequests(_ expecteds: [HTTPRequestHead], body: String?, sendStrategy: (String, Channel) throws -> Void) throws -> String? {
            var step = 0
            var index = 0
            let channel = EmbeddedChannel()
            try channel.pipeline.add(handler: HTTPRequestDecoder()).wait()
            var bodyData: Data? = nil
            var allBodyDatas: [Data] = []
            try channel.pipeline.add(handler: TestChannelInboundHandler { data in
                if let reqPart = data.tryAsOther(type: NIOHTTP1.HTTPRequest.self) {
                    switch reqPart {
                    case .head(var req):
                        XCTAssertEqual((index * 2), step)
                        req.headers.remove(name: "Content-Length")
                        XCTAssertEqual(expecteds[index], req)
                        step += 1
                    case .body(let chunk):
                        switch chunk {
                        case .more(var buffer):
                            if bodyData == nil {
                                bodyData = buffer.readData(length: buffer.readableBytes)!
                            } else {
                                bodyData!.append(buffer.readData(length: buffer.readableBytes)!)
                            }
                        case .last(let buffer):
                            if var buffer = buffer {
                                if bodyData == nil {
                                    bodyData = buffer.readData(length: buffer.readableBytes)!
                                } else {
                                    bodyData!.append(buffer.readData(length: buffer.readableBytes)!)
                                }
                            }
                            step += 1
                            XCTAssertEqual(((index + 1) * 2), step)
                        }
                    }
                } else {
                    XCTFail("wrong type \(data)")
                }
                return data
            }).wait()

            for expected in expecteds {
                try sendStrategy(httpRequestStrForRequest(expected), channel)
                index += 1
                if let bodyData = bodyData {
                    allBodyDatas.append(bodyData)
                }
                bodyData = nil
            }
            try channel.pipeline.flush().wait()
            XCTAssertEqual(2 * expecteds.count, step)

            if let _ = body {
                XCTAssertGreaterThan(allBodyDatas.count, 0)
                let firstBodyData = allBodyDatas[0]
                for bodyData in allBodyDatas {
                    XCTAssertEqual(firstBodyData, bodyData)
                }
                return String(bytes: firstBodyData, encoding: .utf8)!
            } else {
                XCTAssertEqual([], allBodyDatas)
                return nil
            }
        }

        /* send all bytes in one go */
        let bd1 = try sendAndCheckRequests(expecteds, body: body, sendStrategy: { (reqString, chan) in
            var buf = chan.allocator.buffer(capacity: 1024)
            buf.write(string: reqString)
            chan.pipeline.fireChannelRead(data: .byteBuffer(buf))
        })

        /* send the bytes one by one */
        let bd2 = try sendAndCheckRequests(expecteds, body: body, sendStrategy: { (reqString, chan) in
            for c in reqString {
                var buf = chan.allocator.buffer(capacity: 1024)

                buf.write(string: "\(c)")
                chan.pipeline.fireChannelRead(data: .byteBuffer(buf))
            }
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

}
