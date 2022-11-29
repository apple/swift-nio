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

#if compiler(>=5.5.2) && canImport(_Concurrency)

/// Wraps a NIO ``Channel`` object into a form suitable for use in Swift Concurrency.
///
/// ``NIOAsyncChannel`` abstracts the notion of a NIO ``Channel`` into something that
/// can safely be used in a structured concurrency context. In particular, this exposes
/// the following functionality:
///
/// - reads are presented as an `AsyncSequence`
/// - writes can be written to with async functions, providing backpressure
/// - channels can be closed seamlessly
///
/// This type does not replace the full complexity of NIO's ``Channel``. In particular, it
/// does not expose the following functionality:
///
/// - user events
/// - traditional NIO backpressure such as writability signals and the ``Channel/read()`` call
///
/// Users are encouraged to separate their ``ChannelHandler``s into those that implement
/// protocol-specific logic (such as parsers and encoders) and those that implement business
/// logic. Protocol-specific logic should be implemented as a ``ChannelHandler``, while business
/// logic should use ``NIOAsyncChannel`` to consume and produce data to the network.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public final class NIOAsyncChannel<InboundIn: Sendable, OutboundOut: Sendable>: Sendable {
    /// The underlying channel being wrapped by this ``NIOAsyncChannel``.
    public let channel: Channel

    public let inboundStream: NIOInboundChannelStream<InboundIn>

    @usableFromInline
    let outboundWriter: NIOAsyncChannelWriterHandler<OutboundOut>.Writer

    @inlinable
    public init(
        wrapping channel: Channel,
        backpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        enableOutboundHalfClosure: Bool = true,
        inboundIn: InboundIn.Type = InboundIn.self,
        outboundOut: OutboundOut.Type = OutboundOut.self
    ) async throws {
        (self.inboundStream, self.outboundWriter) = try await channel.eventLoop.submit {
            try channel.syncAddAsyncHandlers(backpressureStrategy: backpressureStrategy, enableOutboundHalfClosure: enableOutboundHalfClosure)
        }.get()
        
        self.channel = channel
    }

    @inlinable
    public init(
        synchronouslyWrapping channel: Channel,
        backpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        enableOutboundHalfClosure: Bool = true,
        inboundIn: InboundIn.Type = InboundIn.self,
        outboundOut: OutboundOut.Type = OutboundOut.self
    ) throws {
        channel.eventLoop.preconditionInEventLoop()
        (self.inboundStream, self.outboundWriter) = try channel.syncAddAsyncHandlers(backpressureStrategy: backpressureStrategy, enableOutboundHalfClosure: enableOutboundHalfClosure)
        self.channel = channel
    }

    @inlinable
    public func writeAndFlush(_ data: OutboundOut) async throws {
        try await self.outboundWriter.yield(data)
    }

    @inlinable
    public func writeAndFlush<Writes: Sequence>(contentsOf data: Writes) async throws where Writes.Element == OutboundOut {
        try await self.outboundWriter.yield(contentsOf: data)
    }
}

extension Channel {
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @inlinable
    func syncAddAsyncHandlers<InboundIn: Sendable, OutboundOut: Sendable>(
        backpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        enableOutboundHalfClosure: Bool
    ) throws -> (NIOInboundChannelStream<InboundIn>, NIOAsyncChannelWriterHandler<OutboundOut>.Writer) {
        self.eventLoop.assertInEventLoop()

        let closeRatchet = CloseRatchet()
        let inboundStream = try NIOInboundChannelStream<InboundIn>(self, backpressureStrategy: backpressureStrategy, closeRatchet: closeRatchet)
        let (handler, writer) = NIOAsyncChannelWriterHandler<OutboundOut>.makeHandler(loop: self.eventLoop, closeRatchet: closeRatchet, enableOutboundHalfClosure: enableOutboundHalfClosure)
        try self.pipeline.syncOperations.addHandler(handler)
        return (inboundStream, writer)
    }
}
#endif
