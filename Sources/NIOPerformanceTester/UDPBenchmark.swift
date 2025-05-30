//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore
import NIOPosix

final class UDPBenchmark {
    /// Request to send.
    private let data: ByteBuffer
    /// Number of requests to send in each run.
    private let numberOfRequests: Int
    /// Setting for `.datagramVectorReadMessageCount`
    private let vectorReads: Int
    /// Number of writes before each flush (for the client; the server flushes at the end
    /// of each read cycle).
    private let vectorWrites: Int

    private var group: EventLoopGroup!
    private var server: Channel!
    private var client: Channel!
    private var clientHandler: EchoHandlerClient.SendableView!

    init(data: ByteBuffer, numberOfRequests: Int, vectorReads: Int, vectorWrites: Int) {
        self.data = data
        self.numberOfRequests = numberOfRequests
        self.vectorReads = vectorReads
        self.vectorWrites = vectorWrites
    }
}

extension UDPBenchmark: Benchmark {
    func setUp() throws {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let address = try SocketAddress.makeAddressResolvingHost("127.0.0.1", port: 0)
        self.server = try DatagramBootstrap(group: group)
            // zero is the same as not applying the option.
            .channelOption(.datagramVectorReadMessageCount, value: self.vectorReads)
            .channelInitializer { channel in
                channel.pipeline.addHandler(EchoHandler())
            }
            .bind(to: address)
            .wait()

        let remoteAddress = self.server.localAddress!

        self.client = try DatagramBootstrap(group: group)
            // zero is the same as not applying the option.
            .channelOption(.datagramVectorReadMessageCount, value: self.vectorReads)
            .channelInitializer { [data, numberOfRequests, vectorWrites] channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = EchoHandlerClient(
                        eventLoop: channel.eventLoop,
                        config: .init(
                            remoteAddress: remoteAddress,
                            request: data,
                            requests: numberOfRequests,
                            writesPerFlush: vectorWrites
                        )
                    )
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
            .bind(to: address)
            .wait()

        self.clientHandler = try self.client.pipeline.handler(type: EchoHandlerClient.self).map { $0.sendableView }
            .wait()
    }

    func tearDown() {
        try! self.client.close().wait()
        try! self.server.close().wait()
    }

    func run() throws -> Int {
        try self.clientHandler.run().wait()
        return self.vectorReads &+ self.vectorWrites
    }
}

extension UDPBenchmark {
    final class EchoHandler: ChannelInboundHandler, Sendable {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>
        typealias OutboundOut = AddressedEnvelope<ByteBuffer>

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            // echo back the message; skip the unwrap/rewrap.
            context.write(data, promise: nil)
        }

        func channelReadComplete(context: ChannelHandlerContext) {
            context.flush()
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            fatalError("EchoHandler received errorCaught")
        }
    }

    final class EchoHandlerClient: ChannelInboundHandler, RemovableChannelHandler {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>
        typealias OutboundOut = AddressedEnvelope<ByteBuffer>

        private let eventLoop: EventLoop
        private let config: Config

        private var state = State()
        private var context: ChannelHandlerContext?

        private struct State {
            private enum _State {
                case stopped
                case running(Running)

                struct Running {
                    /// Number of requests still to send.
                    var requestsToSend: Int
                    /// Number of responses still being waited for.
                    var responsesToReceive: Int
                    /// Number of writes before the next flush, i.e. flush on zero.
                    var writesBeforeNextFlush: Int
                    /// Number of writes before each flush.
                    let writesPerFlush: Int
                    /// Completed once the `requestsToSend` and outstanding have dropped to zero.
                    let promise: EventLoopPromise<Void>

                    init(requests: Int, writesPerFlush: Int, promise: EventLoopPromise<Void>) {
                        self.requestsToSend = requests
                        self.responsesToReceive = requests
                        self.writesBeforeNextFlush = writesPerFlush
                        self.writesPerFlush = writesPerFlush
                        self.promise = promise
                    }
                }
            }

            private var state: _State

            init() {
                self.state = .stopped
            }

            mutating func run(requests: Int, writesPerFlush: Int, promise: EventLoopPromise<Void>) {
                switch self.state {
                case .stopped:
                    let running = _State.Running(requests: requests, writesPerFlush: writesPerFlush, promise: promise)
                    self.state = .running(running)
                case .running:
                    fatalError("Invalid state")
                }
            }

            enum Receive {
                case write
                case finished(EventLoopPromise<Void>)
            }

            mutating func receive() -> Receive {
                switch self.state {
                case .running(var running):
                    running.responsesToReceive &-= 1
                    if running.responsesToReceive == 0, running.requestsToSend == 0 {
                        self.state = .stopped
                        return .finished(running.promise)
                    } else {
                        self.state = .running(running)
                        return .write
                    }

                case .stopped:
                    fatalError("Received too many messages")
                }
            }

            enum Write {
                case write(flush: Bool)
                case doNothing
            }

            mutating func write() -> Write {
                switch self.state {
                case .stopped:
                    return .doNothing

                case .running(var running):
                    guard running.requestsToSend > 0 else {
                        return .doNothing
                    }

                    running.requestsToSend &-= 1
                    running.writesBeforeNextFlush &-= 1

                    let flush: Bool
                    if running.writesBeforeNextFlush == 0 {
                        running.writesBeforeNextFlush = running.writesPerFlush
                        flush = true
                    } else {
                        flush = false
                    }

                    self.state = .running(running)
                    return .write(flush: flush)
                }
            }
        }

        init(eventLoop: EventLoop, config: Config) {
            self.eventLoop = eventLoop
            self.config = config
        }

        struct Config {
            var remoteAddress: SocketAddress
            var request: ByteBuffer
            var requests: Int
            var writesPerFlush: Int
        }

        func handlerAdded(context: ChannelHandlerContext) {
            self.context = context
        }

        func handlerRemoved(context: ChannelHandlerContext) {
            self.context = nil
        }

        var sendableView: SendableView {
            SendableView(handler: self, eventLoop: self.eventLoop)
        }

        struct SendableView: Sendable {
            private let handler: NIOLoopBound<EchoHandlerClient>
            private let eventLoop: EventLoop

            init(handler: EchoHandlerClient, eventLoop: EventLoop) {
                self.handler = NIOLoopBound(handler, eventLoop: eventLoop)
                self.eventLoop = eventLoop
            }

            func run() -> EventLoopFuture<Void> {
                let p = self.eventLoop.makePromise(of: Void.self)
                self.eventLoop.execute {
                    self.handler.value._run(promise: p)
                }
                return p.futureResult
            }
        }

        private func _run(promise: EventLoopPromise<Void>) {
            self.state.run(requests: self.config.requests, writesPerFlush: self.config.writesPerFlush, promise: promise)
            let context = self.context!

            for _ in 0..<self.config.writesPerFlush {
                self.maybeSend(context: context)
            }
        }

        private func maybeSend(context: ChannelHandlerContext) {
            switch self.state.write() {
            case .doNothing:
                ()
            case let .write(flush):
                let envolope = AddressedEnvelope<ByteBuffer>(
                    remoteAddress: self.config.remoteAddress,
                    data: self.config.request
                )
                context.write(Self.wrapOutboundOut(envolope), promise: nil)
                if flush {
                    context.flush()
                }
            }
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch self.state.receive() {
            case .write:
                self.maybeSend(context: context)
            case .finished(let promise):
                promise.succeed()
            }
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            fatalError("EchoHandlerClient received errorCaught")
        }
    }
}
