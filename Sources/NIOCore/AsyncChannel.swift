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
public final class NIOAsyncChannel<InboundIn, OutboundOut>: Sendable {
    /// The underlying channel being wrapped by this ``NIOAsyncChannel``.
    public let channel: Channel

    public let inboundStream: NIOInboundChannelStream<InboundIn>

    @usableFromInline
    let outboundWriter: NIOAsyncChannelWriterHandler<OutboundOut>.Writer

    @inlinable
    public init(wrapping channel: Channel, inboundIn: InboundIn.Type = InboundIn.self, outboundOut: OutboundOut.Type = OutboundOut.self) async throws {
        self.channel = channel

        // TODO: Make configurable
        // TODO: Reduce the number of loop hops here
        self.inboundStream = try await NIOInboundChannelStream<InboundIn>(channel, lowWatermark: 0, highWatermark: 100)
        let (handler, writer) = NIOAsyncChannelWriterHandler<OutboundOut>.makeHandler(loop: channel.eventLoop)
        try await channel.pipeline.addHandler(handler)
        self.outboundWriter = writer
    }

    @inlinable
    public func writeAndFlush(_ data: OutboundOut) async throws {
        try await self.outboundWriter.yield(data)
    }
}
#endif
