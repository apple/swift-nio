//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Benchmark
import NIOCore
import NIOEmbedded

// MARK: - Handlers for AddressedEnvelope benchmarks

private final class ByteBufferEnvelopeForwardingHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }
}

private final class StringEnvelopeForwardingHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = AddressedEnvelope<String>

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }
}

// MARK: - Benchmarks

let benchmarks = {
    #if LOCAL_TESTING
    let defaultMetrics: [BenchmarkMetric] = [
        .mallocCountTotal,
        .contextSwitches,
        .wallClock,
        .instructions,
    ]
    #else
    let defaultMetrics: [BenchmarkMetric] = [
        .mallocCountTotal
    ]
    #endif

    let leakMetrics: [BenchmarkMetric] = [
        .mallocCountTotal,
        .memoryLeaked,
    ]

    Benchmark(
        "NIOAsyncChannel.init",
        configuration: .init(
            metrics: defaultMetrics,
            scalingFactor: .kilo,
            maxDuration: .seconds(10_000_000),
            maxIterations: 10
        )
    ) { benchmark in
        // Elide the cost of the 'EmbeddedChannel'. It's only used for its pipeline.
        var channels: [EmbeddedChannel] = []
        channels.reserveCapacity(benchmark.scaledIterations.count)
        for _ in 0..<benchmark.scaledIterations.count {
            channels.append(EmbeddedChannel())
        }

        benchmark.startMeasurement()
        defer {
            benchmark.stopMeasurement()
        }
        for channel in channels {
            let asyncChanel = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
            blackHole(asyncChanel)
        }
    }

    Benchmark(
        "WaitOnPromise",
        configuration: .init(
            metrics: leakMetrics,
            scalingFactor: .kilo,
            maxDuration: .seconds(10_000_000),
            maxIterations: 10_000  // need 10k to get a signal
        )
    ) { benchmark in
        // Elide the cost of the 'EmbeddedEventLoop'.
        let el = EmbeddedEventLoop()

        benchmark.startMeasurement()
        defer {
            benchmark.stopMeasurement()
        }

        for _ in 0..<benchmark.scaledIterations.count {
            let p = el.makePromise(of: Int.self)
            p.succeed(0)
            do { _ = try! p.futureResult.wait() }
        }
    }

    Benchmark(
        "AddressedEnvelope.ByteBuffer.noMetadata",
        configuration: .init(
            metrics: defaultMetrics,
            scalingFactor: .kilo,
            maxDuration: .seconds(10_000_000),
            maxIterations: 10
        )
    ) { benchmark in
        // Setup: Create channel with 20 forwarding handlers
        let channel = EmbeddedChannel()
        for _ in 0..<20 {
            try! channel.pipeline.syncOperations.addHandler(ByteBufferEnvelopeForwardingHandler())
        }

        // Create the envelope without metadata
        let address = try! SocketAddress(ipAddress: "::1", port: 8080)
        let buffer = ByteBuffer(string: "test data")
        let envelope = AddressedEnvelope(remoteAddress: address, data: buffer)

        benchmark.startMeasurement()
        defer {
            benchmark.stopMeasurement()
        }

        for _ in 0..<benchmark.scaledIterations.count {
            try! channel.writeInbound(envelope)
            let result: AddressedEnvelope<ByteBuffer>? = try! channel.readInbound()
            blackHole(result)
        }
    }

    Benchmark(
        "AddressedEnvelope.ByteBuffer.withMetadata",
        configuration: .init(
            metrics: defaultMetrics,
            scalingFactor: .kilo,
            maxDuration: .seconds(10_000_000),
            maxIterations: 10
        )
    ) { benchmark in
        // Setup: Create channel with 20 forwarding handlers
        let channel = EmbeddedChannel()
        for _ in 0..<20 {
            try! channel.pipeline.syncOperations.addHandler(ByteBufferEnvelopeForwardingHandler())
        }

        // Create the envelope with full metadata
        let address = try! SocketAddress(ipAddress: "::1", port: 8080)
        let buffer = ByteBuffer(string: "test data")
        let metadata = AddressedEnvelope<ByteBuffer>.Metadata(
            ecnState: .transportNotCapable,
            packetInfo: NIOPacketInfo(destinationAddress: address, interfaceIndex: 1),
            segmentSize: 1200
        )
        let envelope = AddressedEnvelope(remoteAddress: address, data: buffer, metadata: metadata)

        benchmark.startMeasurement()
        defer {
            benchmark.stopMeasurement()
        }

        for _ in 0..<benchmark.scaledIterations.count {
            try! channel.writeInbound(envelope)
            let result: AddressedEnvelope<ByteBuffer>? = try! channel.readInbound()
            blackHole(result)
        }
    }

    Benchmark(
        "AddressedEnvelope.String.noMetadata",
        configuration: .init(
            metrics: defaultMetrics,
            scalingFactor: .kilo,
            maxDuration: .seconds(10_000_000),
            maxIterations: 10
        )
    ) { benchmark in
        // Setup: Create channel with 20 forwarding handlers
        let channel = EmbeddedChannel()
        for _ in 0..<20 {
            try! channel.pipeline.syncOperations.addHandler(StringEnvelopeForwardingHandler())
        }

        // Create the envelope without metadata
        let address = try! SocketAddress(ipAddress: "::1", port: 8080)
        let envelope = AddressedEnvelope(remoteAddress: address, data: "test data")

        benchmark.startMeasurement()
        defer {
            benchmark.stopMeasurement()
        }

        for _ in 0..<benchmark.scaledIterations.count {
            try! channel.writeInbound(envelope)
            let result: AddressedEnvelope<String>? = try! channel.readInbound()
            blackHole(result)
        }
    }

    Benchmark(
        "AddressedEnvelope.String.withMetadata",
        configuration: .init(
            metrics: defaultMetrics,
            scalingFactor: .kilo,
            maxDuration: .seconds(10_000_000),
            maxIterations: 10
        )
    ) { benchmark in
        // Setup: Create channel with 20 forwarding handlers
        let channel = EmbeddedChannel()
        for _ in 0..<20 {
            try! channel.pipeline.syncOperations.addHandler(StringEnvelopeForwardingHandler())
        }

        // Create the envelope with full metadata
        let address = try! SocketAddress(ipAddress: "::1", port: 8080)
        let metadata = AddressedEnvelope<String>.Metadata(
            ecnState: .transportNotCapable,
            packetInfo: NIOPacketInfo(destinationAddress: address, interfaceIndex: 1),
            segmentSize: 1200
        )
        let envelope = AddressedEnvelope(remoteAddress: address, data: "test data", metadata: metadata)

        benchmark.startMeasurement()
        defer {
            benchmark.stopMeasurement()
        }

        for _ in 0..<benchmark.scaledIterations.count {
            try! channel.writeInbound(envelope)
            let result: AddressedEnvelope<String>? = try! channel.readInbound()
            blackHole(result)
        }
    }
}
