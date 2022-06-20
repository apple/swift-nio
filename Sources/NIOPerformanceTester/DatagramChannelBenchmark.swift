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

fileprivate final class DoNothingHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
}

class DatagramClientBenchmark {
    fileprivate final let group: MultiThreadedEventLoopGroup
    fileprivate final let serverChannel: Channel
    fileprivate final let localhostPickPort: SocketAddress
    fileprivate final let clientBootstrap: DatagramBootstrap
    fileprivate final let clientChannel: Channel
    fileprivate final let payload: NIOAny

    final let iterations: Int

    fileprivate init(iterations: Int, connect: Bool, envelope: Bool, metadata: Bool) {
        self.iterations = iterations

        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        // server setup
        self.localhostPickPort = try! SocketAddress.makeAddressResolvingHost("127.0.0.1", port: 0)
        self.serverChannel = try! DatagramBootstrap(group: self.group)
            .channelInitializer { $0.pipeline.addHandler(DoNothingHandler()) }
            .bind(to: localhostPickPort)
            .wait()

        // client bootstrap setup
        self.clientBootstrap = DatagramBootstrap(group: self.group)
            .channelInitializer { $0.pipeline.addHandler(DoNothingHandler()) }

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

        // send one payload to activate the channel
        try! self.clientChannel.writeAndFlush(payload).wait()
    }

    func setUp() throws {
    }

    func tearDown() {
        try! self.clientChannel.close().wait()
        try! self.serverChannel.close().wait()
        try! self.group.syncShutdownGracefully()
    }
}

final class DatagramBootstrapCreateBenchmark: DatagramClientBenchmark, Benchmark {
    init(iterations: Int) {
        super.init(iterations: iterations, connect: false, envelope: true, metadata: false)
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
        super.init(iterations: iterations, connect: false, envelope: true, metadata: false)
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
        super.init(iterations: iterations, connect: false, envelope: true, metadata: false)
    }

    func run() throws -> Int {
        for _ in 1...self.iterations {
            try! self.clientBootstrap.connect(to: self.serverChannel.localAddress!).flatMap { $0.close() }.wait()
        }
        return 0
    }
}

final class DatagramChannelWriteBenchmark: DatagramClientBenchmark, Benchmark {
    override init(iterations: Int, connect: Bool, envelope: Bool, metadata: Bool) {
        super.init(iterations: iterations, connect: connect, envelope: envelope, metadata: metadata)
    }

    func run() throws -> Int {
        for _ in 1...self.iterations {
            try! self.clientChannel.writeAndFlush(self.payload).wait()
        }
        return 0
    }
}
