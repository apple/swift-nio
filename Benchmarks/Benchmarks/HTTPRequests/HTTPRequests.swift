//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020-2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOPerformanceTester
import NIOEmbedded
import NIOCore
import NIOHTTP1
import NIOPosix

import BenchmarkSupport
@main
extension BenchmarkRunner {}


@_dynamicReplacement(for: registerBenchmarks)
func benchmarks() {
    Benchmark.defaultConfiguration = .init(metrics:[.wallClock, .mallocCountTotal, .throughput],
                                           warmupIterations: 0,
                                           maxDuration: .seconds(1),
                                           maxIterations: Int.max)

     Benchmark("net_http1_1k_reqs_1_conn") { benchmark in
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
        let desiredRequests = 1_000
        var requestsDone = -1
        let measuringHandler = MeasuringHandler(numberOfRequests: desiredRequests) { reqs in
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
        precondition(requestsDone == desiredRequests)
        blackHole(requestsDone)
    }

    Benchmark("http1_1k_reqs_1_conn") { benchmark in
        let repeatedRequestsHandler = RepeatedRequests(numberOfRequests: 1_000, eventLoop: group.next())

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
        blackHole(try! repeatedRequestsHandler.wait())
    }

    Benchmark("http1_1k_reqs_100_conns") { benchmark in
        var reqs: [Int] = []
        let numConns = 100
        let numReqs = 1_000
        let reqsPerConn = numReqs / numConns
        reqs.reserveCapacity(reqsPerConn)
        for _ in 0..<numConns {
            let repeatedRequestsHandler = RepeatedRequests(numberOfRequests: reqsPerConn, eventLoop: group.next())

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
        blackHole(reqs.reduce(0, +) / numConns)
    }
}
