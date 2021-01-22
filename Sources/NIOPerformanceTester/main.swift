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

public func measure(_ fn: () throws -> Int) rethrows -> [Double] {
    func measureOne(_ fn: () throws -> Int) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try fn()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / Double(TimeAmount.seconds(1).nanoseconds)
    }

    _ = try measureOne(fn) /* pre-heat and throw away */
    var measurements = Array(repeating: 0.0, count: 10)
    for i in 0..<10 {
        measurements[i] = try measureOne(fn)
    }

    return measurements
}

let limitSet = CommandLine.arguments.dropFirst()

public func measureAndPrint(desc: String, fn: () throws -> Int) rethrows -> Void {
    if limitSet.isEmpty || limitSet.contains(desc) {
        print("measuring\(warning): \(desc): ", terminator: "")
        let measurements = try measure(fn)
        print(measurements.reduce(into: "") { $0.append("\($1), ") })
    } else {
        print("skipping '\(desc)', limit set = \(limitSet)")
    }
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
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
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

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .head(let req) = self.unwrapInboundIn(data) {
            switch req.uri {
            case "/perf-test-1":
                var buffer = context.channel.allocator.buffer(capacity: self.cachedBody.count)
                buffer.writeBytes(self.cachedBody)
                context.write(self.wrapOutboundOut(.head(self.cachedHead)), promise: nil)
                context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                return
            case "/perf-test-2":
                var req = HTTPResponseHead(version: .http1_1, status: .ok)
                for i in 1...8 {
                    req.headers.add(name: "X-ResponseHeader-\(i)", value: "foo")
                }
                req.headers.add(name: "content-length", value: "0")
                context.write(self.wrapOutboundOut(.head(req)), promise: nil)
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
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
    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: true).flatMap {
            channel.pipeline.addHandler(SimpleHTTPServer())
        }
    }.bind(host: "127.0.0.1", port: 0).wait()

defer {
    try! serverChannel.close().wait()
}

var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/perf-test-1")
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
        self.isDonePromise = eventLoop.makePromise()
    }

    func wait() throws -> Int {
        let reqs = try self.isDonePromise.futureResult.wait()
        precondition(reqs == self.numberOfRequests)
        return reqs
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.channel.close(promise: nil)
        self.isDonePromise.fail(error)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = self.unwrapInboundIn(data)
        if case .end(nil) = reqPart {
            if self.remainingNumberOfRequests <= 0 {
                context.channel.close().map { self.doneRequests }.cascade(to: self.isDonePromise)
            } else {
                self.doneRequests += 1
                self.remainingNumberOfRequests -= 1

                context.write(self.wrapOutboundOut(.head(head)), promise: nil)
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}

private func someString(size: Int) -> String {
    var s = "A"
    for f in 1..<size {
        s += String("\(f)".first!)
    }
    return s
}

// MARK: Performance Tests

measureAndPrint(desc: "write_http_headers") {
    var headers: [(String, String)] = []
    for i in 1..<10 {
        headers.append(("\(i)", "\(i)"))
    }

    var val = 0
    for _ in 0..<100_000 {
        let headers = HTTPHeaders(headers)
        val += headers.underestimatedCount
    }
    return val
}

measureAndPrint(desc: "bytebuffer_write_12MB_short_string_literals") {
    let bufferSize = 12 * 1024 * 1024
    var buffer = ByteBufferAllocator().buffer(capacity: bufferSize)

    for _ in 0 ..< 5 {
        buffer.clear()
        for _ in 0 ..< (bufferSize / 4) {
            buffer.writeString("abcd")
        }
    }

    let readableBytes = buffer.readableBytes
    precondition(readableBytes == bufferSize)
    return readableBytes
}

measureAndPrint(desc: "bytebuffer_write_12MB_short_calculated_strings") {
    let bufferSize = 12 * 1024 * 1024
    var buffer = ByteBufferAllocator().buffer(capacity: bufferSize)
    let s = someString(size: 4)

    for _ in 0 ..< 5 {
        buffer.clear()
        for _ in  0 ..< (bufferSize / 4) {
            buffer.writeString(s)
        }
    }

    let readableBytes = buffer.readableBytes
    precondition(readableBytes == bufferSize)
    return readableBytes
}

measureAndPrint(desc: "bytebuffer_write_12MB_medium_string_literals") {
    let bufferSize = 12 * 1024 * 1024
    var buffer = ByteBufferAllocator().buffer(capacity: bufferSize)

    for _ in 0 ..< 10 {
        buffer.clear()
        for _ in  0 ..< (bufferSize / 24) {
            buffer.writeString("012345678901234567890123")
        }
    }

    let readableBytes = buffer.readableBytes
    precondition(readableBytes == bufferSize)
    return readableBytes
}

measureAndPrint(desc: "bytebuffer_write_12MB_medium_calculated_strings") {
    let bufferSize = 12 * 1024 * 1024
    var buffer = ByteBufferAllocator().buffer(capacity: bufferSize)
    let s = someString(size: 24)

    for _ in 0 ..< 10 {
        buffer.clear()
        for _ in 0 ..< (bufferSize / 24) {
            buffer.writeString(s)
        }
    }

    let readableBytes = buffer.readableBytes
    precondition(readableBytes == bufferSize)
    return readableBytes
}

measureAndPrint(desc: "bytebuffer_write_12MB_large_calculated_strings") {
    let bufferSize = 12 * 1024 * 1024
    var buffer = ByteBufferAllocator().buffer(capacity: bufferSize)
    let s = someString(size: 1024 * 1024)

    for _ in 0 ..< 10 {
        buffer.clear()
        for _ in 0 ..< 12 {
            buffer.writeString(s)
        }
    }

    let readableBytes = buffer.readableBytes
    precondition(readableBytes == bufferSize)
    return readableBytes
}

measureAndPrint(desc: "bytebuffer_lots_of_rw") {
    let dispatchData = ("A" as StaticString).withUTF8Buffer { ptr in
        DispatchData(bytes: UnsafeRawBufferPointer(start: UnsafeRawPointer(ptr.baseAddress), count: ptr.count))
    }
    var buffer = ByteBufferAllocator().buffer(capacity: 7 * 1024 * 1024)
    @inline(never)
    func doWrites(buffer: inout ByteBuffer) {
        /* all of those should be 0 allocations */

        // buffer.writeBytes(foundationData) // see SR-7542
        buffer.writeBytes([0x41])
        buffer.writeBytes(dispatchData)
        buffer.writeBytes("A".utf8)
        buffer.writeString("A")
        buffer.writeStaticString("A")
        buffer.writeInteger(0x41, as: UInt8.self)
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
    buffer.writeString("HTTP/1.1 200 OK")
    buffer.writeString("\r\n")
    buffer.writeString("Connection")
    buffer.writeString(":")
    buffer.writeString(" ")
    buffer.writeString("close")
    buffer.writeString("\r\n")
    buffer.writeString("Proxy-Connection")
    buffer.writeString(":")
    buffer.writeString(" ")
    buffer.writeString("close")
    buffer.writeString("\r\n")
    buffer.writeString("Via")
    buffer.writeString(":")
    buffer.writeString(" ")
    buffer.writeString("HTTP/1.1 localhost (IBM-PROXY-WTE)")
    buffer.writeString("\r\n")
    buffer.writeString("Date")
    buffer.writeString(":")
    buffer.writeString(" ")
    buffer.writeString("Tue, 08 May 2018 13:42:56 GMT")
    buffer.writeString("\r\n")
    buffer.writeString("Server")
    buffer.writeString(":")
    buffer.writeString(" ")
    buffer.writeString("Apache/2.2.15 (Red Hat)")
    buffer.writeString("\r\n")
    buffer.writeString("Strict-Transport-Security")
    buffer.writeString(":")
    buffer.writeString(" ")
    buffer.writeString("max-age=15768000; includeSubDomains")
    buffer.writeString("\r\n")
    buffer.writeString("Last-Modified")
    buffer.writeString(":")
    buffer.writeString(" ")
    buffer.writeString("Tue, 08 May 2018 13:39:13 GMT")
    buffer.writeString("\r\n")
    buffer.writeString("ETag")
    buffer.writeString(":")
    buffer.writeString(" ")
    buffer.writeString("357031-1809-56bb1e96a6240")
    buffer.writeString("\r\n")
    buffer.writeString("Accept-Ranges")
    buffer.writeString(":")
    buffer.writeString(" ")
    buffer.writeString("bytes")
    buffer.writeString("\r\n")
    buffer.writeString("Content-Length")
    buffer.writeString(":")
    buffer.writeString(" ")
    buffer.writeString("6153")
    buffer.writeString("\r\n")
    buffer.writeString("Content-Type")
    buffer.writeString(":")
    buffer.writeString(" ")
    buffer.writeString("text/html; charset=UTF-8")
    buffer.writeString("\r\n")
    buffer.writeString("\r\n")
}

func writeExampleHTTPResponseAsStaticString(buffer: inout ByteBuffer) {
    buffer.writeStaticString("HTTP/1.1 200 OK")
    buffer.writeStaticString("\r\n")
    buffer.writeStaticString("Connection")
    buffer.writeStaticString(":")
    buffer.writeStaticString(" ")
    buffer.writeStaticString("close")
    buffer.writeStaticString("\r\n")
    buffer.writeStaticString("Proxy-Connection")
    buffer.writeStaticString(":")
    buffer.writeStaticString(" ")
    buffer.writeStaticString("close")
    buffer.writeStaticString("\r\n")
    buffer.writeStaticString("Via")
    buffer.writeStaticString(":")
    buffer.writeStaticString(" ")
    buffer.writeStaticString("HTTP/1.1 localhost (IBM-PROXY-WTE)")
    buffer.writeStaticString("\r\n")
    buffer.writeStaticString("Date")
    buffer.writeStaticString(":")
    buffer.writeStaticString(" ")
    buffer.writeStaticString("Tue, 08 May 2018 13:42:56 GMT")
    buffer.writeStaticString("\r\n")
    buffer.writeStaticString("Server")
    buffer.writeStaticString(":")
    buffer.writeStaticString(" ")
    buffer.writeStaticString("Apache/2.2.15 (Red Hat)")
    buffer.writeStaticString("\r\n")
    buffer.writeStaticString("Strict-Transport-Security")
    buffer.writeStaticString(":")
    buffer.writeStaticString(" ")
    buffer.writeStaticString("max-age=15768000; includeSubDomains")
    buffer.writeStaticString("\r\n")
    buffer.writeStaticString("Last-Modified")
    buffer.writeStaticString(":")
    buffer.writeStaticString(" ")
    buffer.writeStaticString("Tue, 08 May 2018 13:39:13 GMT")
    buffer.writeStaticString("\r\n")
    buffer.writeStaticString("ETag")
    buffer.writeStaticString(":")
    buffer.writeStaticString(" ")
    buffer.writeStaticString("357031-1809-56bb1e96a6240")
    buffer.writeStaticString("\r\n")
    buffer.writeStaticString("Accept-Ranges")
    buffer.writeStaticString(":")
    buffer.writeStaticString(" ")
    buffer.writeStaticString("bytes")
    buffer.writeStaticString("\r\n")
    buffer.writeStaticString("Content-Length")
    buffer.writeStaticString(":")
    buffer.writeStaticString(" ")
    buffer.writeStaticString("6153")
    buffer.writeStaticString("\r\n")
    buffer.writeStaticString("Content-Type")
    buffer.writeStaticString(":")
    buffer.writeStaticString(" ")
    buffer.writeStaticString("text/html; charset=UTF-8")
    buffer.writeStaticString("\r\n")
    buffer.writeStaticString("\r\n")
}

measureAndPrint(desc: "bytebuffer_write_http_response_ascii_only_as_string") {
    var buffer = ByteBufferAllocator().buffer(capacity: 16 * 1024)
    for _ in 0..<20_000 {
        writeExampleHTTPResponseAsString(buffer: &buffer)
        buffer.writeString(htmlASCIIOnly)
        buffer.clear()
    }
    return buffer.readableBytes
}

measureAndPrint(desc: "bytebuffer_write_http_response_ascii_only_as_staticstring") {
    var buffer = ByteBufferAllocator().buffer(capacity: 16 * 1024)
    for _ in 0..<20_000 {
        writeExampleHTTPResponseAsStaticString(buffer: &buffer)
        buffer.writeStaticString(htmlASCIIOnlyStaticString)
        buffer.clear()
    }
    return buffer.readableBytes
}

measureAndPrint(desc: "bytebuffer_write_http_response_some_nonascii_as_string") {
    var buffer = ByteBufferAllocator().buffer(capacity: 16 * 1024)
    for _ in 0..<20_000 {
        writeExampleHTTPResponseAsString(buffer: &buffer)
        buffer.writeString(htmlMostlyASCII)
        buffer.clear()
    }
    return buffer.readableBytes
}

measureAndPrint(desc: "bytebuffer_write_http_response_some_nonascii_as_staticstring") {
    var buffer = ByteBufferAllocator().buffer(capacity: 16 * 1024)
    for _ in 0..<20_000 {
        writeExampleHTTPResponseAsStaticString(buffer: &buffer)
        buffer.writeStaticString(htmlMostlyASCIIStaticString)
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

        func handlerAdded(context: ChannelHandlerContext) {
            self.requestBuffer = context.channel.allocator.buffer(capacity: 512)
            self.requestBuffer.writeString("""
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

        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            var buf = self.unwrapOutboundIn(data)
            if self.expectedResponseBuffer == nil {
                self.expectedResponseBuffer = buf
            }
            precondition(buf == self.expectedResponseBuffer, "got \(buf.readString(length: buf.readableBytes)!)")
            let channel = context.channel
            self.remainingNumberOfRequests -= 1
            if self.remainingNumberOfRequests > 0 {
                context.eventLoop.execute {
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
                                                     withErrorHandling: true).flatMap {
        channel.pipeline.addHandler(SimpleHTTPServer())
    }.flatMap {
        channel.pipeline.addHandler(measuringHandler, position: .first)
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
        .channelInitializer { channel in
            channel.pipeline.addHTTPClientHandlers().flatMap {
                channel.pipeline.addHandler(repeatedRequestsHandler)
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
                channel.pipeline.addHTTPClientHandlers().flatMap {
                    channel.pipeline.addHandler(repeatedRequestsHandler)
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

measureAndPrint(desc: "future_whenallsucceed_100k_immediately_succeeded_off_loop") {
    let loop = group.next()
    let expected = Array(0..<100_000)
    let futures = expected.map { loop.makeSucceededFuture($0) }
    let allSucceeded = try! EventLoopFuture.whenAllSucceed(futures, on: loop).wait()
    return allSucceeded.count
}

measureAndPrint(desc: "future_whenallsucceed_100k_immediately_succeeded_on_loop") {
    let loop = group.next()
    let expected = Array(0..<100_000)
    let allSucceeded = try! loop.makeSucceededFuture(()).flatMap { _ -> EventLoopFuture<[Int]> in
        let futures = expected.map { loop.makeSucceededFuture($0) }
        return EventLoopFuture.whenAllSucceed(futures, on: loop)
        }.wait()
    return allSucceeded.count
}

measureAndPrint(desc: "future_whenallsucceed_100k_deferred_off_loop") {
    let loop = group.next()
    let expected = Array(0..<100_000)
    let promises = expected.map { _ in loop.makePromise(of: Int.self) }
    let allSucceeded = EventLoopFuture.whenAllSucceed(promises.map { $0.futureResult }, on: loop)
    for (index, promise) in promises.enumerated() {
        promise.succeed(index)
    }
    return try! allSucceeded.wait().count
}

measureAndPrint(desc: "future_whenallsucceed_100k_deferred_on_loop") {
    let loop = group.next()
    let expected = Array(0..<100_000)
    let promises = expected.map { _ in loop.makePromise(of: Int.self) }
    let allSucceeded = try! loop.makeSucceededFuture(()).flatMap { _ -> EventLoopFuture<[Int]> in
        let result = EventLoopFuture.whenAllSucceed(promises.map { $0.futureResult }, on: loop)
        for (index, promise) in promises.enumerated() {
            promise.succeed(index)
        }
        return result
        }.wait()
    return allSucceeded.count
}


measureAndPrint(desc: "future_whenallcomplete_100k_immediately_succeeded_off_loop") {
    let loop = group.next()
    let expected = Array(0..<100_000)
    let futures = expected.map { loop.makeSucceededFuture($0) }
    let allSucceeded = try! EventLoopFuture.whenAllComplete(futures, on: loop).wait()
    return allSucceeded.count
}

measureAndPrint(desc: "future_whenallcomplete_100k_immediately_succeeded_on_loop") {
    let loop = group.next()
    let expected = Array(0..<100_000)
    let allSucceeded = try! loop.makeSucceededFuture(()).flatMap { _ -> EventLoopFuture<[Result<Int, Error>]> in
        let futures = expected.map { loop.makeSucceededFuture($0) }
        return EventLoopFuture.whenAllComplete(futures, on: loop)
        }.wait()
    return allSucceeded.count
}

measureAndPrint(desc: "future_whenallcomplete_100k_deferred_off_loop") {
    let loop = group.next()
    let expected = Array(0..<100_000)
    let promises = expected.map { _ in loop.makePromise(of: Int.self) }
    let allSucceeded = EventLoopFuture.whenAllComplete(promises.map { $0.futureResult }, on: loop)
    for (index, promise) in promises.enumerated() {
        promise.succeed(index)
    }
    return try! allSucceeded.wait().count
}

measureAndPrint(desc: "future_whenallcomplete_100k_deferred_on_loop") {
    let loop = group.next()
    let expected = Array(0..<100_000)
    let promises = expected.map { _ in loop.makePromise(of: Int.self) }
    let allSucceeded = try! loop.makeSucceededFuture(()).flatMap { _ -> EventLoopFuture<[Result<Int, Error>]> in
        let result = EventLoopFuture.whenAllComplete(promises.map { $0.futureResult }, on: loop)
        for (index, promise) in promises.enumerated() {
            promise.succeed(index)
        }
        return result
        }.wait()
    return allSucceeded.count
}

measureAndPrint(desc: "future_reduce_10k_futures") {
    let el1 = group.next()

    let oneHundredFutures = (1 ... 10_000).map { i in el1.makeSucceededFuture(i) }
    return try! EventLoopFuture<Int>.reduce(0, oneHundredFutures, on: el1, +).wait()
}

measureAndPrint(desc: "future_reduce_into_10k_futures") {
    let el1 = group.next()

    let oneHundredFutures = (1 ... 10_000).map { i in el1.makeSucceededFuture(i) }
    return try! EventLoopFuture<Int>.reduce(into: 0, oneHundredFutures, on: el1, { $0 += $1 }).wait()
}

try measureAndPrint(desc: "channel_pipeline_1m_events", benchmark: ChannelPipelineBenchmark())

try measureAndPrint(desc: "websocket_encode_50b_space_at_front_1m_frames_cow",
                    benchmark: WebSocketFrameEncoderBenchmark(dataSize: 50, runCount: 1_000_000, dataStrategy: .spaceAtFront, cowStrategy: .always, maskingKeyStrategy: .never))

try measureAndPrint(desc: "websocket_encode_50b_space_at_front_1m_frames_cow_masking",
                    benchmark: WebSocketFrameEncoderBenchmark(dataSize: 50, runCount: 100_000, dataStrategy: .spaceAtFront, cowStrategy: .always, maskingKeyStrategy: .always))

try measureAndPrint(desc: "websocket_encode_1kb_space_at_front_100k_frames_cow",
                    benchmark: WebSocketFrameEncoderBenchmark(dataSize: 1024, runCount: 100_000, dataStrategy: .spaceAtFront, cowStrategy: .always, maskingKeyStrategy: .never))

try measureAndPrint(desc: "websocket_encode_50b_no_space_at_front_1m_frames_cow",
                    benchmark: WebSocketFrameEncoderBenchmark(dataSize: 50, runCount: 1_000_000, dataStrategy: .noSpaceAtFront, cowStrategy: .always, maskingKeyStrategy: .never))

try measureAndPrint(desc: "websocket_encode_1kb_no_space_at_front_100k_frames_cow",
                    benchmark: WebSocketFrameEncoderBenchmark(dataSize: 1024, runCount: 100_000, dataStrategy: .noSpaceAtFront, cowStrategy: .always, maskingKeyStrategy: .never))

try measureAndPrint(desc: "websocket_encode_50b_space_at_front_10k_frames",
                    benchmark: WebSocketFrameEncoderBenchmark(dataSize: 50, runCount: 10_000, dataStrategy: .spaceAtFront, cowStrategy: .never, maskingKeyStrategy: .never))

try measureAndPrint(desc: "websocket_encode_50b_space_at_front_10k_frames_masking",
                    benchmark: WebSocketFrameEncoderBenchmark(dataSize: 50, runCount: 100_000, dataStrategy: .spaceAtFront, cowStrategy: .never, maskingKeyStrategy: .always))

try measureAndPrint(desc: "websocket_encode_1kb_space_at_front_1k_frames",
                    benchmark: WebSocketFrameEncoderBenchmark(dataSize: 1024, runCount: 1_000, dataStrategy: .spaceAtFront, cowStrategy: .never, maskingKeyStrategy: .never))

try measureAndPrint(desc: "websocket_encode_50b_no_space_at_front_10k_frames",
                    benchmark: WebSocketFrameEncoderBenchmark(dataSize: 50, runCount: 10_000, dataStrategy: .noSpaceAtFront, cowStrategy: .never, maskingKeyStrategy: .never))

try measureAndPrint(desc: "websocket_encode_1kb_no_space_at_front_1k_frames",
                    benchmark: WebSocketFrameEncoderBenchmark(dataSize: 1024, runCount: 1_000, dataStrategy: .noSpaceAtFront, cowStrategy: .never, maskingKeyStrategy: .never))

 try measureAndPrint(desc: "websocket_decode_125b_100k_frames",
                     benchmark: WebSocketFrameDecoderBenchmark(dataSize: 125, runCount: 100_000))

try measureAndPrint(desc: "websocket_decode_125b_with_a_masking_key_100k_frames",
                    benchmark: WebSocketFrameDecoderBenchmark(dataSize: 125, runCount: 100_000, maskingKey: [0x80, 0x08, 0x10, 0x01]))

try measureAndPrint(desc: "websocket_decode_64kb_100k_frames",
                    benchmark: WebSocketFrameDecoderBenchmark(dataSize: Int(UInt16.max), runCount: 100_000))

try measureAndPrint(desc: "websocket_decode_64kb_with_a_masking_key_100k_frames",
                    benchmark: WebSocketFrameDecoderBenchmark(dataSize: Int(UInt16.max), runCount: 100_000, maskingKey: [0x80, 0x08, 0x10, 0x01]))

try measureAndPrint(desc: "websocket_decode_64kb_+1_100k_frames",
                    benchmark: WebSocketFrameDecoderBenchmark(dataSize: Int(UInt16.max) + 1, runCount: 100_000))

try measureAndPrint(desc: "websocket_decode_64kb_+1_with_a_masking_key_100k_frames",
                    benchmark: WebSocketFrameDecoderBenchmark(dataSize: Int(UInt16.max) + 1, runCount: 100_000, maskingKey: [0x80, 0x08, 0x10, 0x01]))

try measureAndPrint(desc: "circular_buffer_into_byte_buffer_1kb", benchmark: CircularBufferIntoByteBufferBenchmark(iterations: 10000, bufferSize: 1024))

try measureAndPrint(desc: "circular_buffer_into_byte_buffer_1mb", benchmark: CircularBufferIntoByteBufferBenchmark(iterations: 20, bufferSize: 1024*1024))

try measureAndPrint(desc: "byte_buffer_view_iterator_1mb", benchmark: ByteBufferViewIteratorBenchmark(iterations: 20, bufferSize: 1024*1024))

try measureAndPrint(desc: "byte_to_message_decoder_decode_many_small",
                    benchmark: ByteToMessageDecoderDecodeManySmallsBenchmark(iterations: 1_000, bufferSize: 16384))
