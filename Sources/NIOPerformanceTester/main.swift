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

import NIO
import NIOHTTP1
import NIOFoundationCompat
import Foundation
import Dispatch

// MARK: Test Harness

var warning: String = ""
assert({
    print("======================================================")
    print("= YOU ARE RUNNING NIOPerformanceTester IN DEBUG MODE =")
    print("======================================================")
    warning = " <<< DEBUG MODE >>>"
    return true
    }())

public func measure(_ fn: () throws -> Int) rethrows -> [TimeInterval] {
    func measureOne(_ fn: () throws -> Int) rethrows -> TimeInterval {
        let start = Date()
        _ = try fn()
        let end = Date()
        return end.timeIntervalSince(start)
    }

    _ = try measureOne(fn) /* pre-heat and throw away */
    var measurements = Array(repeating: 0.0, count: 10)
    for i in 0..<10 {
        measurements[i] = try measureOne(fn)
    }

    return measurements
}

public func measureAndPrint(desc: String, fn: () throws -> Int) rethrows -> Void {
    print("measuring\(warning): \(desc): ", terminator: "")
    let measurements = try measure(fn)
    print(measurements.reduce("") { $0 + "\($1), " })
}

// MARK: Utilities

private final class SimpleHTTPServer: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var files: [String] = Array()
    private var seenEnd: Bool = false
    private var sentEnd: Bool = false
    private var isOpen: Bool = true

    private let cachedHead: HTTPResponseHead
    private let cachedBody: [UInt8]
    private let bodyLength = 1024
    private let numberOfAdditionalHeaders = 10

    init() {
        var head = HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: .ok)
        head.headers.add(name: "Content-Length", value: "\(self.bodyLength)")
        for i in 0..<self.numberOfAdditionalHeaders {
            head.headers.add(name: "X-Random-Extra-Header", value: "\(i)")
        }
        self.cachedHead = head

        var body: [UInt8] = []
        body.reserveCapacity(self.bodyLength)
        for i in 0..<self.bodyLength {
            body.append(UInt8(i % Int(UInt8.max)))
        }
        self.cachedBody = body
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        if case .head(let req) = self.unwrapInboundIn(data) {
            switch req.uri {
            case "/perf-test-1":
                var buffer = ctx.channel.allocator.buffer(capacity: self.cachedBody.count)
                buffer.write(bytes: self.cachedBody)
                ctx.write(self.wrapOutboundOut(.head(self.cachedHead)), promise: nil)
                ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                return
            case "/perf-test-2":
                var req = HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: .ok)
                for i in 1...8 {
                    req.headers.add(name: "X-ResponseHeader-\(i)", value: "foo")
                }
                req.headers.add(name: "content-length", value: "0")
                ctx.write(self.wrapOutboundOut(.head(req)), promise: nil)
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                return
            default:
                fatalError("unknown uri \(req.uri)")
            }
        }
    }
}


let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
defer {
    try! group.syncShutdownGracefully()
}

let serverChannel = try ServerBootstrap(group: group)
    .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
    .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
    .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: true).then {
            channel.pipeline.add(handler: SimpleHTTPServer())
        }
    }.bind(host: "127.0.0.1", port: 0).wait()

defer {
    try! serverChannel.close().wait()
}

var head = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/perf-test-1")
head.headers.add(name: "Host", value: "localhost")

final class RepeatedRequests: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let numberOfRequests: Int
    private var remainingNumberOfRequests: Int
    private var doneRequests = 0
    private let isDonePromise: EventLoopPromise<Int>

    init(numberOfRequests: Int, eventLoop: EventLoop) {
        self.remainingNumberOfRequests = numberOfRequests
        self.numberOfRequests = numberOfRequests
        self.isDonePromise = eventLoop.newPromise()
    }

    func wait() throws -> Int {
        let reqs = try self.isDonePromise.futureResult.wait()
        precondition(reqs == self.numberOfRequests)
        return reqs
    }

    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        ctx.channel.close(promise: nil)
        self.isDonePromise.fail(error: error)
    }

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let reqPart = self.unwrapInboundIn(data)
        if case .end(nil) = reqPart {
            if self.remainingNumberOfRequests <= 0 {
                ctx.channel.close().map { self.doneRequests }.cascade(promise: self.isDonePromise)
            } else {
                self.doneRequests += 1
                self.remainingNumberOfRequests -= 1

                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}

// MARK: Performance Tests

measureAndPrint(desc: "bytebuffer_lots_of_rw") {
    let dispatchData = ("A" as StaticString).withUTF8Buffer { ptr in
        DispatchData(bytes: UnsafeRawBufferPointer(start: UnsafeRawPointer(ptr.baseAddress), count: ptr.count))
    }
    var buffer = ByteBufferAllocator().buffer(capacity: 7 * 1024 * 1024)
    let foundationData = "A".data(using: .utf8)!
    @inline(never)
    func doWrites(buffer: inout ByteBuffer) {
        /* all of those should be 0 allocations */

        // buffer.write(bytes: foundationData) // see SR-7542
        buffer.write(bytes: [0x41])
        buffer.write(bytes: dispatchData)
        buffer.write(bytes: "A".utf8)
        buffer.write(string: "A")
        buffer.write(staticString: "A")
        buffer.write(integer: 0x41, as: UInt8.self)
    }
    @inline(never)
    func doReads(buffer: inout ByteBuffer) {
        /* these ones are zero allocations */
        let val = buffer.readInteger(as: UInt8.self)
        precondition(0x41 == val, "\(val!)")
        var slice = buffer.readSlice(length: 1)
        let sliceVal = slice!.readInteger(as: UInt8.self)
        precondition(0x41 == sliceVal, "\(sliceVal!)")
        buffer.withUnsafeReadableBytes { ptr in
            precondition(ptr[0] == 0x41)
        }

        /* those down here should be one allocation each */
        let arr = buffer.readBytes(length: 1)
        precondition([0x41] == arr!, "\(arr!)")
        let str = buffer.readString(length: 1)
        precondition("A" == str, "\(str!)")
    }
    for _ in 0 ..< 1024*1024 {
        doWrites(buffer: &buffer)
        doReads(buffer: &buffer)
    }
    return buffer.readableBytes
}

func writeExampleHTTPResponseAsString(buffer: inout ByteBuffer) {
    buffer.write(string: "HTTP/1.1 200 OK")
    buffer.write(string: "\r\n")
    buffer.write(string: "Connection")
    buffer.write(string: ":")
    buffer.write(string: " ")
    buffer.write(string: "close")
    buffer.write(string: "\r\n")
    buffer.write(string: "Proxy-Connection")
    buffer.write(string: ":")
    buffer.write(string: " ")
    buffer.write(string: "close")
    buffer.write(string: "\r\n")
    buffer.write(string: "Via")
    buffer.write(string: ":")
    buffer.write(string: " ")
    buffer.write(string: "HTTP/1.1 localhost (IBM-PROXY-WTE)")
    buffer.write(string: "\r\n")
    buffer.write(string: "Date")
    buffer.write(string: ":")
    buffer.write(string: " ")
    buffer.write(string: "Tue, 08 May 2018 13:42:56 GMT")
    buffer.write(string: "\r\n")
    buffer.write(string: "Server")
    buffer.write(string: ":")
    buffer.write(string: " ")
    buffer.write(string: "Apache/2.2.15 (Red Hat)")
    buffer.write(string: "\r\n")
    buffer.write(string: "Strict-Transport-Security")
    buffer.write(string: ":")
    buffer.write(string: " ")
    buffer.write(string: "max-age=15768000; includeSubDomains")
    buffer.write(string: "\r\n")
    buffer.write(string: "Last-Modified")
    buffer.write(string: ":")
    buffer.write(string: " ")
    buffer.write(string: "Tue, 08 May 2018 13:39:13 GMT")
    buffer.write(string: "\r\n")
    buffer.write(string: "ETag")
    buffer.write(string: ":")
    buffer.write(string: " ")
    buffer.write(string: "357031-1809-56bb1e96a6240")
    buffer.write(string: "\r\n")
    buffer.write(string: "Accept-Ranges")
    buffer.write(string: ":")
    buffer.write(string: " ")
    buffer.write(string: "bytes")
    buffer.write(string: "\r\n")
    buffer.write(string: "Content-Length")
    buffer.write(string: ":")
    buffer.write(string: " ")
    buffer.write(string: "6153")
    buffer.write(string: "\r\n")
    buffer.write(string: "Content-Type")
    buffer.write(string: ":")
    buffer.write(string: " ")
    buffer.write(string: "text/html; charset=UTF-8")
    buffer.write(string: "\r\n")
    buffer.write(string: "\r\n")
}

func writeExampleHTTPResponseAsStaticString(buffer: inout ByteBuffer) {
    buffer.write(staticString: "HTTP/1.1 200 OK")
    buffer.write(staticString: "\r\n")
    buffer.write(staticString: "Connection")
    buffer.write(staticString: ":")
    buffer.write(staticString: " ")
    buffer.write(staticString: "close")
    buffer.write(staticString: "\r\n")
    buffer.write(staticString: "Proxy-Connection")
    buffer.write(staticString: ":")
    buffer.write(staticString: " ")
    buffer.write(staticString: "close")
    buffer.write(staticString: "\r\n")
    buffer.write(staticString: "Via")
    buffer.write(staticString: ":")
    buffer.write(staticString: " ")
    buffer.write(staticString: "HTTP/1.1 localhost (IBM-PROXY-WTE)")
    buffer.write(staticString: "\r\n")
    buffer.write(staticString: "Date")
    buffer.write(staticString: ":")
    buffer.write(staticString: " ")
    buffer.write(staticString: "Tue, 08 May 2018 13:42:56 GMT")
    buffer.write(staticString: "\r\n")
    buffer.write(staticString: "Server")
    buffer.write(staticString: ":")
    buffer.write(staticString: " ")
    buffer.write(staticString: "Apache/2.2.15 (Red Hat)")
    buffer.write(staticString: "\r\n")
    buffer.write(staticString: "Strict-Transport-Security")
    buffer.write(staticString: ":")
    buffer.write(staticString: " ")
    buffer.write(staticString: "max-age=15768000; includeSubDomains")
    buffer.write(staticString: "\r\n")
    buffer.write(staticString: "Last-Modified")
    buffer.write(staticString: ":")
    buffer.write(staticString: " ")
    buffer.write(staticString: "Tue, 08 May 2018 13:39:13 GMT")
    buffer.write(staticString: "\r\n")
    buffer.write(staticString: "ETag")
    buffer.write(staticString: ":")
    buffer.write(staticString: " ")
    buffer.write(staticString: "357031-1809-56bb1e96a6240")
    buffer.write(staticString: "\r\n")
    buffer.write(staticString: "Accept-Ranges")
    buffer.write(staticString: ":")
    buffer.write(staticString: " ")
    buffer.write(staticString: "bytes")
    buffer.write(staticString: "\r\n")
    buffer.write(staticString: "Content-Length")
    buffer.write(staticString: ":")
    buffer.write(staticString: " ")
    buffer.write(staticString: "6153")
    buffer.write(staticString: "\r\n")
    buffer.write(staticString: "Content-Type")
    buffer.write(staticString: ":")
    buffer.write(staticString: " ")
    buffer.write(staticString: "text/html; charset=UTF-8")
    buffer.write(staticString: "\r\n")
    buffer.write(staticString: "\r\n")
}

measureAndPrint(desc: "bytebuffer_write_http_response_ascii_only_as_string") {
    var buffer = ByteBufferAllocator().buffer(capacity: 16 * 1024)
    for _ in 0..<20_000 {
        writeExampleHTTPResponseAsString(buffer: &buffer)
        buffer.write(string: htmlASCIIOnly)
        buffer.clear()
    }
    return buffer.readableBytes
}

measureAndPrint(desc: "bytebuffer_write_http_response_ascii_only_as_staticstring") {
    var buffer = ByteBufferAllocator().buffer(capacity: 16 * 1024)
    for _ in 0..<20_000 {
        writeExampleHTTPResponseAsStaticString(buffer: &buffer)
        buffer.write(staticString: htmlASCIIOnlyStaticString)
        buffer.clear()
    }
    return buffer.readableBytes
}

measureAndPrint(desc: "bytebuffer_write_http_response_some_nonascii_as_string") {
    var buffer = ByteBufferAllocator().buffer(capacity: 16 * 1024)
    for _ in 0..<20_000 {
        writeExampleHTTPResponseAsString(buffer: &buffer)
        buffer.write(string: htmlMostlyASCII)
        buffer.clear()
    }
    return buffer.readableBytes
}

measureAndPrint(desc: "bytebuffer_write_http_response_some_nonascii_as_staticstring") {
    var buffer = ByteBufferAllocator().buffer(capacity: 16 * 1024)
    for _ in 0..<20_000 {
        writeExampleHTTPResponseAsStaticString(buffer: &buffer)
        buffer.write(staticString: htmlMostlyASCIIStaticString)
        buffer.clear()
    }
    return buffer.readableBytes
}

try measureAndPrint(desc: "no-net_http1_10k_reqs_1_conn") {
    final class MeasuringHandler: ChannelDuplexHandler {
        typealias InboundIn = Never
        typealias InboundOut = ByteBuffer
        typealias OutboundIn = ByteBuffer

        private var requestBuffer: ByteBuffer!
        private var expectedResponseBuffer: ByteBuffer?
        private var remainingNumberOfRequests: Int

        private let completionHandler: (Int) -> Void
        private let numberOfRequests: Int

        init(numberOfRequests: Int, completionHandler: @escaping (Int) -> Void) {
            self.completionHandler = completionHandler
            self.numberOfRequests = numberOfRequests
            self.remainingNumberOfRequests = numberOfRequests
        }

        func handlerAdded(ctx: ChannelHandlerContext) {
            self.requestBuffer = ctx.channel.allocator.buffer(capacity: 512)
            self.requestBuffer.write(string: """
                                             GET /perf-test-2 HTTP/1.1\r
                                             Host: example.com\r
                                             X-Some-Header-1: foo\r
                                             X-Some-Header-2: foo\r
                                             X-Some-Header-3: foo\r
                                             X-Some-Header-4: foo\r
                                             X-Some-Header-5: foo\r
                                             X-Some-Header-6: foo\r
                                             X-Some-Header-7: foo\r
                                             X-Some-Header-8: foo\r\n\r\n
                                             """)
        }

        func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            var buf = self.unwrapOutboundIn(data)
            if self.expectedResponseBuffer == nil {
                self.expectedResponseBuffer = buf
            }
            precondition(buf == self.expectedResponseBuffer, "got \(buf.readString(length: buf.readableBytes)!)")
            let channel = ctx.channel
            self.remainingNumberOfRequests -= 1
            if self.remainingNumberOfRequests > 0 {
                ctx.eventLoop.execute {
                    self.kickOff(channel: channel)
                }
            } else {
                self.completionHandler(self.numberOfRequests)
            }
        }

        func kickOff(channel: Channel) -> Void {
            try! (channel as! EmbeddedChannel).writeInbound(self.requestBuffer)
        }
    }

    let eventLoop = EmbeddedEventLoop()
    let channel = EmbeddedChannel(handler: nil, loop: eventLoop)
    var done = false
    var requestsDone = -1
    let measuringHandler = MeasuringHandler(numberOfRequests: 10_000) { reqs in
        requestsDone = reqs
        done = true
    }
    try channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: true,
                                                     withErrorHandling: true).then {
        channel.pipeline.add(handler: SimpleHTTPServer())
    }.then {
        channel.pipeline.add(handler: measuringHandler, first: true)
    }.wait()

    measuringHandler.kickOff(channel: channel)

    while !done {
        eventLoop.run()
    }
    _ = try channel.finish()
    precondition(requestsDone == 10_000)
    return requestsDone
}

measureAndPrint(desc: "http1_10k_reqs_1_conn") {
    let repeatedRequestsHandler = RepeatedRequests(numberOfRequests: 10_000, eventLoop: group.next())

    let clientChannel = try! ClientBootstrap(group: group)
        .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
        .channelInitializer { channel in
            channel.pipeline.addHTTPClientHandlers().then {
                channel.pipeline.add(handler: repeatedRequestsHandler)
            }
        }
        .connect(to: serverChannel.localAddress!)
        .wait()

    clientChannel.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
    try! clientChannel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil))).wait()
    return try! repeatedRequestsHandler.wait()
}

measureAndPrint(desc: "http1_10k_reqs_100_conns") {
    var reqs: [Int] = []
    let reqsPerConn = 100
    reqs.reserveCapacity(reqsPerConn)
    for _ in 0..<reqsPerConn {
        let repeatedRequestsHandler = RepeatedRequests(numberOfRequests: 100, eventLoop: group.next())

        let clientChannel = try! ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().then {
                    channel.pipeline.add(handler: repeatedRequestsHandler)
                }
            }
            .connect(to: serverChannel.localAddress!)
            .wait()

        clientChannel.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
        try! clientChannel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil))).wait()
        reqs.append(try! repeatedRequestsHandler.wait())
    }
    return reqs.reduce(0, +) / reqsPerConn
}
