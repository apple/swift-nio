//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022-2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// Wraps a NIO ``Channel`` object into a form suitable for use in Swift Concurrency.
///
/// ``NIOAsyncChannel`` abstracts the notion of a NIO ``Channel`` into something that
/// can safely be used in a structured concurrency context. In particular, this exposes
/// the following functionality:
///
/// - reads are presented as an `AsyncSequence`
/// - writes can be written to with async functions on a writer, providing backpressure
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
@_spi(AsyncChannel)
public final class NIOAsyncChannel<Inbound: Sendable, Outbound: Sendable>: Sendable {
    @_spi(AsyncChannel)
    public struct Configuration: Sendable {
        /// The backpressure strategy of the ``NIOAsyncChannel/inboundStream``.
        public var backpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark

        /// If outbound half closure should be enabled. Outbound half closure is triggered once
        /// the ``NIOAsyncChannelWriter`` is either finished or deinitialized.
        public var isOutboundHalfClosureEnabled: Bool

        /// The ``NIOAsyncChannel/inboundStream`` message's type.
        public var inboundType: Inbound.Type

        /// The ``NIOAsyncChannel/outboundWriter`` message's type.
        public var outboundType: Outbound.Type

        /// Initializes a new ``NIOAsyncChannel/Configuration``.
        ///
        /// - Parameters:
        ///   - backpressureStrategy: The backpressure strategy of the ``NIOAsyncChannel/inboundStream``. Defaults
        ///     to a watermarked strategy (lowWatermark: 2, highWatermark: 10).
        ///   - isOutboundHalfClosureEnabled: If outbound half closure should be enabled. Outbound half closure is triggered once
        ///     the ``NIOAsyncChannelWriter`` is either finished or deinitialized. Defaults to `false`.
        ///   - inboundType: The ``NIOAsyncChannel/inboundStream`` message's type.
        ///   - outboundType: The ``NIOAsyncChannel/outboundWriter`` message's type.
        public init(
            backpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark = .init(lowWatermark: 2, highWatermark: 10),
            isOutboundHalfClosureEnabled: Bool = false,
            inboundType: Inbound.Type = Inbound.self,
            outboundType: Outbound.Type = Outbound.self
        ) {
            self.backpressureStrategy = backpressureStrategy
            self.isOutboundHalfClosureEnabled = isOutboundHalfClosureEnabled
            self.inboundType = inboundType
            self.outboundType = outboundType
        }
    }

    /// The underlying channel being wrapped by this ``NIOAsyncChannel``.
    @_spi(AsyncChannel)
    public let channel: Channel
    /// The stream of inbound messages.
    @_spi(AsyncChannel)
    public let inboundStream: NIOAsyncChannelInboundStream<Inbound>
    /// The writer for writing outbound messages.
    @_spi(AsyncChannel)
    public let outboundWriter: NIOAsyncChannelOutboundWriter<Outbound>

    /// Initializes a new ``NIOAsyncChannel`` wrapping a ``Channel``.
    ///
    /// - Important: This **must** be called on the channel's event loop otherwise this init will crash. This is necessary because
    /// we must install the handlers before any other event in the pipeline happens otherwise we might drop reads.
    ///
    /// - Parameters:
    ///   - channel: The ``Channel`` to wrap.
    ///   - configuration: The ``NIOAsyncChannel``s configuration.
    @inlinable
    @_spi(AsyncChannel)
    public init(
        synchronouslyWrapping channel: Channel,
        configuration: Configuration = .init()
    ) throws {
        channel.eventLoop.preconditionInEventLoop()
        self.channel = channel
        (self.inboundStream, self.outboundWriter) = try channel._syncAddAsyncHandlers(
            backpressureStrategy: configuration.backpressureStrategy,
            isOutboundHalfClosureEnabled: configuration.isOutboundHalfClosureEnabled
        )
    }

    /// Initializes a new ``NIOAsyncChannel`` wrapping a ``Channel`` where the outbound type is `Never`.
    ///
    /// This initializer will finish the ``NIOAsyncChannel/outboundWriter`` immediately.
    ///
    /// - Important: This **must** be called on the channel's event loop otherwise this init will crash. This is necessary because
    /// we must install the handlers before any other event in the pipeline happens otherwise we might drop reads.
    ///
    /// - Parameters:
    ///   - channel: The ``Channel`` to wrap.
    ///   - configuration: The ``NIOAsyncChannel``s configuration.
    @inlinable
    @_spi(AsyncChannel)
    public init(
        synchronouslyWrapping channel: Channel,
        configuration: Configuration
    ) throws where Outbound == Never {
        channel.eventLoop.preconditionInEventLoop()
        self.channel = channel
        (self.inboundStream, self.outboundWriter) = try channel._syncAddAsyncHandlers(
            backpressureStrategy: configuration.backpressureStrategy,
            isOutboundHalfClosureEnabled: configuration.isOutboundHalfClosureEnabled
        )

        self.outboundWriter.finish()
    }

    @inlinable
    @_spi(AsyncChannel)
    public init(
        channel: Channel,
        inboundStream: NIOAsyncChannelInboundStream<Inbound>,
        outboundWriter: NIOAsyncChannelOutboundWriter<Outbound>
    ) {
        channel.eventLoop.preconditionInEventLoop()
        self.channel = channel
        self.inboundStream = inboundStream
        self.outboundWriter = outboundWriter
    }

    @inlinable
    @_spi(AsyncChannel)
    public static func wrapAsyncChannelWithTransformations(
        synchronouslyWrapping channel: Channel,
        backpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        isOutboundHalfClosureEnabled: Bool = false,
        channelReadTransformation: @Sendable @escaping (Channel) -> EventLoopFuture<Inbound>
    ) throws -> NIOAsyncChannel<Inbound, Outbound> where Outbound == Never {
        channel.eventLoop.preconditionInEventLoop()
        let (inboundStream, outboundWriter): (NIOAsyncChannelInboundStream<Inbound>, NIOAsyncChannelOutboundWriter<Outbound>) = try channel._syncAddAsyncHandlersWithTransformations(
            backpressureStrategy: backpressureStrategy,
            isOutboundHalfClosureEnabled: isOutboundHalfClosureEnabled,
            channelReadTransformation: channelReadTransformation
        )

        outboundWriter.finish()

        return .init(
            channel: channel,
            inboundStream: inboundStream,
            outboundWriter: outboundWriter
        )
    }
}

extension Channel {
    // TODO: We need to remove the public and spi here once we make the AsyncChannel methods public
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @inlinable
    @_spi(AsyncChannel)
    public func _syncAddAsyncHandlers<Inbound: Sendable, Outbound: Sendable>(
        backpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        isOutboundHalfClosureEnabled: Bool
    ) throws -> (NIOAsyncChannelInboundStream<Inbound>, NIOAsyncChannelOutboundWriter<Outbound>) {
        self.eventLoop.assertInEventLoop()

        let closeRatchet = CloseRatchet(isOutboundHalfClosureEnabled: isOutboundHalfClosureEnabled)
        let inboundStream = try NIOAsyncChannelInboundStream<Inbound>.makeWrappingHandler(
            channel: self,
            backpressureStrategy: backpressureStrategy,
            closeRatchet: closeRatchet
        )
        let writer = try NIOAsyncChannelOutboundWriter<Outbound>(
            channel: self,
            closeRatchet: closeRatchet
        )
        return (inboundStream, writer)
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @inlinable
    @_spi(AsyncChannel)
    public func _syncAddAsyncHandlersWithTransformations<ChannelReadResult>(
        backpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        isOutboundHalfClosureEnabled: Bool,
        channelReadTransformation: @Sendable @escaping (Channel) -> EventLoopFuture<ChannelReadResult>
    ) throws -> (NIOAsyncChannelInboundStream<ChannelReadResult>, NIOAsyncChannelOutboundWriter<Never>) {
        self.eventLoop.assertInEventLoop()

        let closeRatchet = CloseRatchet(isOutboundHalfClosureEnabled: isOutboundHalfClosureEnabled)
        let inboundStream = try NIOAsyncChannelInboundStream<ChannelReadResult>.makeTransformationHandler(
            channel: self,
            backpressureStrategy: backpressureStrategy,
            closeRatchet: closeRatchet,
            channelReadTransformation: channelReadTransformation
        )
        let writer = try NIOAsyncChannelOutboundWriter<Never>(
            channel: self,
            closeRatchet: closeRatchet
        )
        return (inboundStream, writer)
    }
}
