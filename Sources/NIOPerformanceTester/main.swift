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

// swift-format-ignore: AmbiguousTrailingClosureOverload

// swift-format-ignore: OrderedImports
// Required due to https://github.com/swiftlang/swift/issues/76842

#if canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#endif

import Dispatch
import NIOCore
import NIOEmbedded
import NIOFoundationCompat
import NIOHTTP1
#if os(Android)
// workaround for error: reference to var 'stdout' is not concurrency-safe because it involves shared mutable state
@preconcurrency import NIOPosix
#else
import NIOPosix
#endif
import NIOWebSocket

// Use unbuffered stdout to help detect exactly which test was running in the event of a crash.
setbuf(stdout, nil)

// MARK: Test Harness

func makeWarning() -> String {
    var warning = ""
    assert(
        {
            print("======================================================")
            print("= YOU ARE RUNNING NIOPerformanceTester IN DEBUG MODE =")
            print("======================================================")
            warning = " <<< DEBUG MODE >>>"
            return true
        }()
    )
    return warning
}

let warning = makeWarning()

public func measure(_ fn: () throws -> Int) rethrows -> [Double] {
    func measureOne(_ fn: () throws -> Int) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try fn()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / Double(TimeAmount.seconds(1).nanoseconds)
    }

    _ = try measureOne(fn)  // pre-heat and throw away
    var measurements = Array(repeating: 0.0, count: 10)
    for i in 0..<10 {
        measurements[i] = try measureOne(fn)
    }

    return measurements
}

let limitSet = CommandLine.arguments.dropFirst()

public func measureAndPrint(desc: String, fn: () throws -> Int) rethrows {
    if limitSet.isEmpty || limitSet.contains(desc) {
        print("measuring\(warning): \(desc): ", terminator: "")
        let measurements = try measure(fn)
        print(measurements.reduce(into: "") { $0.append("\($1), ") })
    } else {
        print("skipping '\(desc)', limit set = \(limitSet)")
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public func measure(_ fn: () async throws -> Int) async rethrows -> [Double] {
    func measureOne(_ fn: () async throws -> Int) async rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try await fn()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / Double(TimeAmount.seconds(1).nanoseconds)
    }

    _ = try await measureOne(fn)  // pre-heat and throw away
    var measurements = Array(repeating: 0.0, count: 10)
    for i in 0..<10 {
        measurements[i] = try await measureOne(fn)
    }

    return measurements
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public func measureAndPrint(desc: String, fn: () async throws -> Int) async rethrows {
    if limitSet.isEmpty || limitSet.contains(desc) {
        print("measuring\(warning): \(desc): ", terminator: "")
        let measurements = try await measure(fn)
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
        if case .head(let req) = Self.unwrapInboundIn(data) {
            switch req.uri {
            case "/perf-test-1":
                var buffer = context.channel.allocator.buffer(capacity: self.cachedBody.count)
                buffer.writeBytes(self.cachedBody)
                context.write(Self.wrapOutboundOut(.head(self.cachedHead)), promise: nil)
                context.write(Self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: nil)
                return
            case "/perf-test-2":
                var req = HTTPResponseHead(version: .http1_1, status: .ok)
                for i in 1...8 {
                    req.headers.add(name: "X-ResponseHeader-\(i)", value: "foo")
                }
                req.headers.add(name: "content-length", value: "0")
                context.write(Self.wrapOutboundOut(.head(req)), promise: nil)
                context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: nil)
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
    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
    .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: true)
            try channel.pipeline.syncOperations.addHandler(SimpleHTTPServer())
        }
    }.bind(host: "127.0.0.1", port: 0).wait()

defer {
    try! serverChannel.close().wait()
}

let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/perf-test-1", headers: ["Host": "localhost"])

final class RepeatedRequests: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let numberOfRequests: Int
    private var remainingNumberOfRequests: Int
    private var doneRequests = 0
    private let isDonePromise: EventLoopPromise<Int>

    init(numberOfRequests: Int, isDonePromise: EventLoopPromise<Int>) {
        self.remainingNumberOfRequests = numberOfRequests
        self.numberOfRequests = numberOfRequests
        self.isDonePromise = isDonePromise
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
        let reqPart = Self.unwrapInboundIn(data)
        if case .end(nil) = reqPart {
            if self.remainingNumberOfRequests <= 0 {
                context.channel.close().assumeIsolated().map {
                    self.doneRequests
                }.nonisolated().cascade(to: self.isDonePromise)
            } else {
                self.doneRequests += 1
                self.remainingNumberOfRequests -= 1

                context.write(Self.wrapOutboundOut(.head(head)), promise: nil)
                context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: nil)
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
    for _ in 0..<1_000_000 {
        let headers = HTTPHeaders(headers)
        val += headers.underestimatedCount
    }
    return val
}

measureAndPrint(desc: "http_headers_canonical_form") {
    let headers: HTTPHeaders = ["key": "no,trimming"]
    var count = 0
    for _ in 0..<100_000 {
        count &+= headers[canonicalForm: "key"].count
    }
    return count
}

measureAndPrint(desc: "http_headers_canonical_form_trimming_whitespace") {
    let headers: HTTPHeaders = ["key": "         some   ,   trimming     "]
    var count = 0
    for _ in 0..<10_000 {
        count &+= headers[canonicalForm: "key"].count
    }
    return count
}

measureAndPrint(desc: "http_headers_canonical_form_trimming_whitespace_from_short_string") {
    let headers: HTTPHeaders = ["key": "   smallString   ,whenStripped"]
    var count = 0
    for _ in 0..<10_000 {
        count &+= headers[canonicalForm: "key"].count
    }
    return count
}

measureAndPrint(desc: "http_headers_canonical_form_trimming_whitespace_from_long_string") {
    let headers: HTTPHeaders = ["key": " moreThan15CharactersWithAndWithoutWhitespace ,anotherValue"]
    var count = 0
    for _ in 0..<10_000 {
        count &+= headers[canonicalForm: "key"].count
    }
    return count
}

measureAndPrint(desc: "http_headers_description_100k") {
    let headers = HTTPHeaders(Array(repeating: ("String", "String"), count: 100))

    for _ in 0..<100_000 {
        let str = headers.description
        precondition(str.utf8.count > 100)
    }

    return 0
}

measureAndPrint(desc: "bytebuffer_write_12MB_short_string_literals") {
    let bufferSize = 12 * 1024 * 1024
    var buffer = ByteBufferAllocator().buffer(capacity: bufferSize)

    for _ in 0..<3 {
        buffer.clear()
        for _ in 0..<(bufferSize / 4) {
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

    for _ in 0..<1 {
        buffer.clear()
        for _ in 0..<(bufferSize / 4) {
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

    for _ in 0..<100 {
        buffer.clear()
        for _ in 0..<(bufferSize / 24) {
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

    for _ in 0..<5 {
        buffer.clear()
        for _ in 0..<(bufferSize / 24) {
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

    for _ in 0..<5 {
        buffer.clear()
        for _ in 0..<12 {
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
    let substring = Substring("A")
    @inline(never)
    func doWrites(buffer: inout ByteBuffer, dispatchData: DispatchData, substring: Substring) {
        // all of those should be 0 allocations

        // buffer.writeBytes(foundationData) // see SR-7542
        buffer.writeBytes([0x41])
        buffer.writeBytes(dispatchData)
        buffer.writeBytes("A".utf8)
        buffer.writeString("A")
        buffer.writeStaticString("A")
        buffer.writeInteger(0x41, as: UInt8.self)
        buffer.writeSubstring(substring)
    }
    @inline(never)
    func doReads(buffer: inout ByteBuffer) {
        // these ones are zero allocations
        let val = buffer.readInteger(as: UInt8.self)
        precondition(0x41 == val, "\(val!)")
        var slice = buffer.readSlice(length: 1)
        let sliceVal = slice!.readInteger(as: UInt8.self)
        precondition(0x41 == sliceVal, "\(sliceVal!)")
        buffer.withUnsafeReadableBytes { ptr in
            precondition(ptr[0] == 0x41)
        }

        // those down here should be one allocation each
        let arr = buffer.readBytes(length: 1)
        precondition([0x41] == arr!, "\(arr!)")
        let str = buffer.readString(length: 1)
        precondition("A" == str, "\(str!)")
    }
    for _ in 0..<100_000 {
        doWrites(buffer: &buffer, dispatchData: dispatchData, substring: substring)
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

try measureAndPrint(desc: "no-net_http1_1k_reqs_1_conn") {
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
            self.requestBuffer.writeString(
                """
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
                """
            )
        }

        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            var buf = Self.unwrapOutboundIn(data)
            if self.expectedResponseBuffer == nil {
                self.expectedResponseBuffer = buf
            }
            precondition(buf == self.expectedResponseBuffer, "got \(buf.readString(length: buf.readableBytes)!)")
            let channel = context.channel
            self.remainingNumberOfRequests -= 1
            if self.remainingNumberOfRequests > 0 {
                context.eventLoop.assumeIsolated().execute {
                    self.kickOff(channel: channel)
                }
            } else {
                self.completionHandler(self.numberOfRequests)
            }
        }

        func kickOff(channel: Channel) {
            try! (channel as! EmbeddedChannel).writeInbound(self.requestBuffer)
        }
    }

    let eventLoop = EmbeddedEventLoop()
    let channel = EmbeddedChannel(handler: nil, loop: eventLoop)
    var done = false
    let desiredRequests = 1_000
    var requestsDone = -1
    let measuringHandler = MeasuringHandler(numberOfRequests: desiredRequests) { reqs in
        requestsDone = reqs
        done = true
    }

    let sync = channel.pipeline.syncOperations
    try sync.configureHTTPServerPipeline(
        withPipeliningAssistance: true,
        withErrorHandling: true
    )

    try sync.addHandler(SimpleHTTPServer())
    try sync.addHandler(measuringHandler, position: .first)

    measuringHandler.kickOff(channel: channel)

    while !done {
        eventLoop.run()
    }
    _ = try channel.finish()
    precondition(requestsDone == desiredRequests)
    return requestsDone
}

measureAndPrint(desc: "http1_1k_reqs_1_conn") {
    let isDone = group.next().makePromise(of: Int.self)
    let clientChannel = try! ClientBootstrap(group: group)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                let repeatedRequestsHandler = RepeatedRequests(numberOfRequests: 1_000, isDonePromise: isDone)
                let sync = channel.pipeline.syncOperations
                try sync.addHTTPClientHandlers()
                try sync.addHandler(repeatedRequestsHandler)
            }
        }
        .connect(to: serverChannel.localAddress!)
        .wait()

    try! clientChannel.eventLoop.flatSubmit {
        let promise = clientChannel.eventLoop.makePromise(of: Void.self)
        clientChannel.pipeline.syncOperations.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
        clientChannel.pipeline.syncOperations.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil)), promise: promise)
        return promise.futureResult
    }.wait()
    return try! isDone.futureResult.wait()
}

measureAndPrint(desc: "http1_1k_reqs_100_conns") {
    var reqs: [Int] = []
    let numConns = 100
    let numReqs = 1_000
    let reqsPerConn = numReqs / numConns
    reqs.reserveCapacity(reqsPerConn)
    for _ in 0..<numConns {
        let isDone = group.next().makePromise(of: Int.self)

        let clientChannel = try! ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let repeatedRequestsHandler = RepeatedRequests(numberOfRequests: reqsPerConn, isDonePromise: isDone)
                    let sync = channel.pipeline.syncOperations
                    try sync.addHTTPClientHandlers()
                    try sync.addHandler(repeatedRequestsHandler)
                }
            }
            .connect(to: serverChannel.localAddress!)
            .wait()

        try! clientChannel.eventLoop.flatSubmit {
            let promise = clientChannel.eventLoop.makePromise(of: Void.self)
            clientChannel.pipeline.syncOperations.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
            clientChannel.pipeline.syncOperations.writeAndFlush(
                NIOAny(HTTPClientRequestPart.end(nil)),
                promise: promise
            )
            return promise.futureResult
        }.wait()
        reqs.append(try! isDone.futureResult.wait())
    }
    return reqs.reduce(0, +) / numConns
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

measureAndPrint(desc: "future_whenallsucceed_10k_deferred_off_loop") {
    let loop = group.next()
    let expected = Array(0..<10_000)
    let promises = expected.map { _ in loop.makePromise(of: Int.self) }
    let allSucceeded = EventLoopFuture.whenAllSucceed(promises.map { $0.futureResult }, on: loop)
    for (index, promise) in promises.enumerated() {
        promise.succeed(index)
    }
    return try! allSucceeded.wait().count
}

measureAndPrint(desc: "future_whenallsucceed_10k_deferred_on_loop") {
    let loop = group.next()
    let expected = Array(0..<10_000)
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

measureAndPrint(desc: "future_whenallcomplete_10k_deferred_off_loop") {
    let loop = group.next()
    let expected = Array(0..<10_000)
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

    let futures = (1...10_000).map { i in el1.makeSucceededFuture(i) }
    return try! EventLoopFuture<Int>.reduce(0, futures, on: el1, { $0 + $1 }).wait()
}

measureAndPrint(desc: "future_reduce_into_10k_futures") {
    let el1 = group.next()

    let futures = (1...10_000).map { i in el1.makeSucceededFuture(i) }
    return try! EventLoopFuture<Int>.reduce(into: 0, futures, on: el1, { $0 += $1 }).wait()
}

try measureAndPrint(desc: "el_in_eventloop_100M") {
    let el1 = group.next()

    let inEL = try el1.submit {
        var inEL = 0
        for _ in 0..<100_000_000 {
            inEL = inEL &+ (el1.inEventLoop ? 1 : 0)
        }
        return inEL
    }.wait()
    precondition(inEL == 100_000_000)
    return inEL
}

measureAndPrint(desc: "el_not_in_eventloop_100M") {
    let el1 = group.next()

    var inEL = 0
    for _ in 0..<100_000_000 {
        inEL = inEL &+ (el1.inEventLoop ? 1 : 0)
    }
    precondition(inEL == 0)
    return inEL
}

try measureAndPrint(desc: "channel_pipeline_1m_events", benchmark: ChannelPipelineBenchmark(runCount: 1_000_000))

try measureAndPrint(
    desc: "websocket_encode_50b_space_at_front_100k_frames_cow",
    benchmark: WebSocketFrameEncoderBenchmark(
        dataSize: 50,
        runCount: 100_000,
        dataStrategy: .spaceAtFront,
        cowStrategy: .always,
        maskingKeyStrategy: .never
    )
)

try measureAndPrint(
    desc: "websocket_encode_50b_space_at_front_1m_frames_cow_masking",
    benchmark: WebSocketFrameEncoderBenchmark(
        dataSize: 50,
        runCount: 1_000_000,
        dataStrategy: .spaceAtFront,
        cowStrategy: .always,
        maskingKeyStrategy: .always
    )
)

try measureAndPrint(
    desc: "websocket_encode_1kb_space_at_front_1m_frames_cow",
    benchmark: WebSocketFrameEncoderBenchmark(
        dataSize: 1024,
        runCount: 1_000_000,
        dataStrategy: .spaceAtFront,
        cowStrategy: .always,
        maskingKeyStrategy: .never
    )
)

try measureAndPrint(
    desc: "websocket_encode_50b_no_space_at_front_100k_frames_cow",
    benchmark: WebSocketFrameEncoderBenchmark(
        dataSize: 50,
        runCount: 100_000,
        dataStrategy: .noSpaceAtFront,
        cowStrategy: .always,
        maskingKeyStrategy: .never
    )
)

try measureAndPrint(
    desc: "websocket_encode_1kb_no_space_at_front_100k_frames_cow",
    benchmark: WebSocketFrameEncoderBenchmark(
        dataSize: 1024,
        runCount: 100_000,
        dataStrategy: .noSpaceAtFront,
        cowStrategy: .always,
        maskingKeyStrategy: .never
    )
)

try measureAndPrint(
    desc: "websocket_encode_50b_space_at_front_100k_frames",
    benchmark: WebSocketFrameEncoderBenchmark(
        dataSize: 50,
        runCount: 100_000,
        dataStrategy: .spaceAtFront,
        cowStrategy: .never,
        maskingKeyStrategy: .never
    )
)

try measureAndPrint(
    desc: "websocket_encode_50b_space_at_front_10k_frames_masking",
    benchmark: WebSocketFrameEncoderBenchmark(
        dataSize: 50,
        runCount: 10_000,
        dataStrategy: .spaceAtFront,
        cowStrategy: .never,
        maskingKeyStrategy: .always
    )
)

try measureAndPrint(
    desc: "websocket_encode_1kb_space_at_front_10k_frames",
    benchmark: WebSocketFrameEncoderBenchmark(
        dataSize: 1024,
        runCount: 10_000,
        dataStrategy: .spaceAtFront,
        cowStrategy: .never,
        maskingKeyStrategy: .never
    )
)

try measureAndPrint(
    desc: "websocket_encode_50b_no_space_at_front_100k_frames",
    benchmark: WebSocketFrameEncoderBenchmark(
        dataSize: 50,
        runCount: 100_000,
        dataStrategy: .noSpaceAtFront,
        cowStrategy: .never,
        maskingKeyStrategy: .never
    )
)

try measureAndPrint(
    desc: "websocket_encode_1kb_no_space_at_front_10k_frames",
    benchmark: WebSocketFrameEncoderBenchmark(
        dataSize: 1024,
        runCount: 10_000,
        dataStrategy: .noSpaceAtFront,
        cowStrategy: .never,
        maskingKeyStrategy: .never
    )
)

try measureAndPrint(
    desc: "websocket_decode_125b_10k_frames",
    benchmark: WebSocketFrameDecoderBenchmark(
        dataSize: 125,
        runCount: 10_000
    )
)

try measureAndPrint(
    desc: "websocket_decode_125b_with_a_masking_key_10k_frames",
    benchmark: WebSocketFrameDecoderBenchmark(
        dataSize: 125,
        runCount: 10_000,
        maskingKey: [0x80, 0x08, 0x10, 0x01]
    )
)

try measureAndPrint(
    desc: "websocket_decode_64kb_10k_frames",
    benchmark: WebSocketFrameDecoderBenchmark(
        dataSize: Int(UInt16.max),
        runCount: 10_000
    )
)

try measureAndPrint(
    desc: "websocket_decode_64kb_with_a_masking_key_10k_frames",
    benchmark: WebSocketFrameDecoderBenchmark(
        dataSize: Int(UInt16.max),
        runCount: 10_000,
        maskingKey: [0x80, 0x08, 0x10, 0x01]
    )
)

try measureAndPrint(
    desc: "websocket_decode_64kb_+1_10k_frames",
    benchmark: WebSocketFrameDecoderBenchmark(
        dataSize: Int(UInt16.max) + 1,
        runCount: 10_000
    )
)

try measureAndPrint(
    desc: "websocket_decode_64kb_+1_with_a_masking_key_10k_frames",
    benchmark: WebSocketFrameDecoderBenchmark(
        dataSize: Int(UInt16.max) + 1,
        runCount: 10_000,
        maskingKey: [0x80, 0x08, 0x10, 0x01]
    )
)

try measureAndPrint(
    desc: "circular_buffer_into_byte_buffer_1kb",
    benchmark: CircularBufferIntoByteBufferBenchmark(
        iterations: 10_000,
        bufferSize: 1024
    )
)

try measureAndPrint(
    desc: "circular_buffer_into_byte_buffer_1mb",
    benchmark: CircularBufferIntoByteBufferBenchmark(
        iterations: 20,
        bufferSize: 1024 * 1024
    )
)

try measureAndPrint(
    desc: "byte_buffer_view_iterator_1mb",
    benchmark: ByteBufferViewIteratorBenchmark(
        iterations: 20,
        bufferSize: 1024 * 1024
    )
)

try measureAndPrint(
    desc: "byte_buffer_view_contains_12mb",
    benchmark: ByteBufferViewContainsBenchmark(
        iterations: 5,
        bufferSize: 12 * 1024 * 1024
    )
)

try measureAndPrint(
    desc: "byte_to_message_decoder_decode_many_small",
    benchmark: ByteToMessageDecoderDecodeManySmallsBenchmark(
        iterations: 200,
        bufferSize: 16384
    )
)

measureAndPrint(desc: "generate_10k_random_request_keys") {
    let numKeys = 10_000
    return (0..<numKeys).reduce(
        into: 0,
        { result, _ in
            result &+= NIOWebSocketClientUpgrader.randomRequestKey().count
        }
    )
}

try measureAndPrint(
    desc: "bytebuffer_rw_10_uint32s",
    benchmark: ByteBufferReadWriteMultipleIntegersBenchmark<UInt32>(
        iterations: 100_000,
        numberOfInts: 10
    )
)

try measureAndPrint(
    desc: "bytebuffer_multi_rw_10_uint32s",
    benchmark: ByteBufferMultiReadWriteTenIntegersBenchmark<UInt32>(
        iterations: 1_000_000
    )
)

try measureAndPrint(
    desc: "lock_1_thread_10M_ops",
    benchmark: NIOLockBenchmark(
        numberOfThreads: 1,
        lockOperationsPerThread: 10_000_000
    )
)

try measureAndPrint(
    desc: "lock_2_threads_10M_ops",
    benchmark: NIOLockBenchmark(
        numberOfThreads: 2,
        lockOperationsPerThread: 5_000_000
    )
)

try measureAndPrint(
    desc: "lock_4_threads_10M_ops",
    benchmark: NIOLockBenchmark(
        numberOfThreads: 4,
        lockOperationsPerThread: 2_500_000
    )
)

try measureAndPrint(
    desc: "lock_8_threads_10M_ops",
    benchmark: NIOLockBenchmark(
        numberOfThreads: 8,
        lockOperationsPerThread: 1_250_000
    )
)

try measureAndPrint(
    desc: "schedule_and_run_100k_tasks",
    benchmark: SchedulingAndRunningBenchmark(numTasks: 100_000)
)

try measureAndPrint(
    desc: "execute_100k_tasks",
    benchmark: ExecuteBenchmark(numTasks: 100_000)
)

try measureAndPrint(
    desc: "runIfActive_1_thread_100k_tasks",
    benchmark: RunIfActiveBenchmark(numThreads: 1, numTasks: 100_000)
)

try measureAndPrint(
    desc: "runIfActive_8_threads_100k_tasks",
    benchmark: RunIfActiveBenchmark(numThreads: 8, numTasks: 100_000)
)

try measureAndPrint(
    desc: "bytebufferview_copy_to_array_100k_times_1kb",
    benchmark: ByteBufferViewCopyToArrayBenchmark(
        iterations: 100_000,
        size: 1024
    )
)

try measureAndPrint(
    desc: "circularbuffer_copy_to_array_10k_times_1kb",
    benchmark: CircularBufferViewCopyToArrayBenchmark(
        iterations: 10_000,
        size: 1024
    )
)

try measureAndPrint(
    desc: "deadline_now_1M_times",
    benchmark: DeadlineNowBenchmark(
        iterations: 1_000_000
    )
)

if #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) {
    try measureAndPrint(
        desc: "asyncwriter_single_writes_1M_times",
        benchmark: NIOAsyncWriterSingleWritesBenchmark(
            iterations: 1_000_000
        )
    )

    try measureAndPrint(
        desc: "asyncsequenceproducer_consume_1M_times",
        benchmark: NIOAsyncSequenceProducerBenchmark(
            iterations: 1_000_000
        )
    )
}

try measureAndPrint(
    desc: "udp_10k_writes",
    benchmark: UDPBenchmark(
        data: ByteBuffer(repeating: 42, count: 1000),
        numberOfRequests: 10_000,
        vectorReads: 1,
        vectorWrites: 1
    )
)

try measureAndPrint(
    desc: "udp_10k_vector_writes",
    benchmark: UDPBenchmark(
        data: ByteBuffer(repeating: 42, count: 1000),
        numberOfRequests: 10_000,
        vectorReads: 1,
        vectorWrites: 10
    )
)

try measureAndPrint(
    desc: "udp_10k_vector_reads",
    benchmark: UDPBenchmark(
        data: ByteBuffer(repeating: 42, count: 1000),
        numberOfRequests: 10_000,
        vectorReads: 10,
        vectorWrites: 1
    )
)

try measureAndPrint(
    desc: "udp_10k_vector_reads_and_writes",
    benchmark: UDPBenchmark(
        data: ByteBuffer(repeating: 42, count: 1000),
        numberOfRequests: 10_000,
        vectorReads: 10,
        vectorWrites: 10
    )
)

if #available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *) {
    try measureAndPrint(
        desc: "tcp_100k_messages_throughput",
        benchmark: TCPThroughputBenchmark(messages: 100_000, messageSize: 500)
    )
}
