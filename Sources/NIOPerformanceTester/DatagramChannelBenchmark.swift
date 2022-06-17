//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
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

final class DoNothingHandler: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer
}

final class CountReadsHandler: ChannelInboundHandler {
    public typealias InboundIn = NIOAny
    public typealias OutboundOut = NIOAny

    private var numReads: Int = 0
    private let receivedAtLeastOneReadPromise: EventLoopPromise<Void>

    var receivedAtLeastOneRead: EventLoopFuture<Void> {
        self.receivedAtLeastOneReadPromise.futureResult
    }

    init(receivedAtLeastOneReadPromise: EventLoopPromise<Void>) {
        self.receivedAtLeastOneReadPromise = receivedAtLeastOneReadPromise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.numReads += 1
        self.receivedAtLeastOneReadPromise.succeed(())
    }
}


private final class EchoHandler: ChannelInboundHandler {
    public typealias InboundIn = AddressedEnvelope<ByteBuffer>
    public typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.write(data, promise: nil)
    }

    public func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        preconditionFailure("EchoHandler received errorCaught")
    }
}

class DatagramClientBenchmark {
    final private let group: MultiThreadedEventLoopGroup
    final let serverChannel: Channel
    final let localhostPickPort: SocketAddress
    final let clientBootstrap: DatagramBootstrap
    final let clientHandler: CountReadsHandler
    final let clientChannel: Channel
    final let payload: NIOAny

    final let iterations: Int

    init(iterations: Int, connect: Bool, envelope: Bool, metadata: Bool) {
        self.iterations = iterations

        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        // server setup
        self.localhostPickPort = try! SocketAddress.makeAddressResolvingHost("127.0.0.1", port: 0)
        self.serverChannel = try! DatagramBootstrap(group: self.group)
            .channelInitializer { $0.pipeline.addHandler(EchoHandler()) }
            .bind(to: localhostPickPort)
            .wait()

        // client handler setup
        let clientHandler = CountReadsHandler(
            receivedAtLeastOneReadPromise: self.group.next().makePromise()
        )
        self.clientHandler = clientHandler

        // client bootstrap setup
        self.clientBootstrap = DatagramBootstrap(group: self.group).channelInitializer { channel in
            channel.pipeline.addHandler(clientHandler)
        }

        // client channel setup
        if connect {
            self.clientChannel = try! self.clientBootstrap.connect(to: self.serverChannel.localAddress!).wait()
        } else {
            self.clientChannel = try! self.clientBootstrap.bind(to: self.localhostPickPort).wait()
        }

        // payload setup
        let buffer = self.clientChannel.allocator.buffer(integer: 1, as: UInt8.self)
        switch (envelope, metadata) {
        case (true, true):
            self.payload = NIOAny(AddressedEnvelope<ByteBuffer>(
                remoteAddress: self.serverChannel.localAddress!,
                data: buffer,
                metadata: .init(ecnState: .transportCapableFlag1)
            ))
        case (true, false):
            self.payload = NIOAny(AddressedEnvelope<ByteBuffer>(
                remoteAddress: self.serverChannel.localAddress!,
                data: buffer
            ))
        case (false, false):
            self.payload = NIOAny(buffer)
        case (false, true):
            preconditionFailure("No API for this")
        }
    }

    func setUp() throws {
    }

    func tearDown() {
        try! self.group.syncShutdownGracefully()
    }
}

final class DatagramBootstrapCreateBenchmark: DatagramClientBenchmark, Benchmark {
    init(iterations: Int) {
        super.init(iterations: iterations, connect: false, envelope: false, metadata: false)
    }

    func run() throws -> Int {
        for _ in 1...self.iterations {
            _ = DatagramBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(DoNothingHandler())
                }
        }
        return 0
    }
}

final class DatagramChannelBindBenchmark: DatagramClientBenchmark, Benchmark {
    init(iterations: Int) {
        super.init(iterations: iterations, connect: false, envelope: false, metadata: false)
    }

    func run() throws -> Int {
        for _ in 1...self.iterations {
            try! self.clientBootstrap.bind(to: self.localhostPickPort).flatMap { $0.close() }.wait()
        }
        return 0
    }
}

final class DatagramChannelConnectBenchmark: DatagramClientBenchmark, Benchmark {
    init(iterations: Int) {
        super.init(iterations: iterations, connect: false, envelope: false, metadata: false)
    }

    func run() throws -> Int {
        for _ in 1...self.iterations {
            try! self.clientBootstrap.connect(to: self.serverChannel.localAddress!).flatMap { $0.close() }.wait()
        }
        return 0
    }
}

final class DatagramChannelWriteBenchmark: DatagramClientBenchmark, Benchmark {
    func run() throws -> Int {
        for _ in 1...self.iterations {
            _ = self.clientChannel.writeAndFlush(self.payload, promise: nil)
        }
        return 0
    }

    override func tearDown() {
        try! self.clientHandler.receivedAtLeastOneRead.wait()
        super.tearDown()
    }
}
