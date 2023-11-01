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
/// - writes can be written to with async functions on a writer, providing back pressure
/// - channels can be closed seamlessly
///
/// This type does not replace the full complexity of NIO's ``Channel``. In particular, it
/// does not expose the following functionality:
///
/// - user events
/// - traditional NIO back pressure such as writability signals and the ``Channel/read()`` call
///
/// Users are encouraged to separate their ``ChannelHandler``s into those that implement
/// protocol-specific logic (such as parsers and encoders) and those that implement business
/// logic. Protocol-specific logic should be implemented as a ``ChannelHandler``, while business
/// logic should use ``NIOAsyncChannel`` to consume and produce data to the network.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct NIOAsyncChannel<Inbound: Sendable, Outbound: Sendable>: Sendable {
    public struct Configuration: Sendable {
        /// The back pressure strategy of the ``NIOAsyncChannel/inbound``.
        public var backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark

        /// If outbound half closure should be enabled. Outbound half closure is triggered once
        /// the ``NIOAsyncChannelOutboundWriter`` is either finished or deinitialized.
        public var isOutboundHalfClosureEnabled: Bool

        /// The ``NIOAsyncChannel/inbound`` message's type.
        public var inboundType: Inbound.Type

        /// The ``NIOAsyncChannel/outbound`` message's type.
        public var outboundType: Outbound.Type

        /// Initializes a new ``NIOAsyncChannel/Configuration``.
        ///
        /// - Parameters:
        ///   - backPressureStrategy: The back pressure strategy of the ``NIOAsyncChannel/inbound``. Defaults
        ///     to a watermarked strategy (lowWatermark: 2, highWatermark: 10).
        ///   - isOutboundHalfClosureEnabled: If outbound half closure should be enabled. Outbound half closure is triggered once
        ///     the ``NIOAsyncChannelOutboundWriter`` is either finished or deinitialized. Defaults to `false`.
        ///   - inboundType: The ``NIOAsyncChannel/inbound`` message's type.
        ///   - outboundType: The ``NIOAsyncChannel/outbound`` message's type.
        public init(
            backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark = .init(lowWatermark: 2, highWatermark: 10),
            isOutboundHalfClosureEnabled: Bool = false,
            inboundType: Inbound.Type = Inbound.self,
            outboundType: Outbound.Type = Outbound.self
        ) {
            self.backPressureStrategy = backPressureStrategy
            self.isOutboundHalfClosureEnabled = isOutboundHalfClosureEnabled
            self.inboundType = inboundType
            self.outboundType = outboundType
        }
    }

    /// The underlying channel being wrapped by this ``NIOAsyncChannel``.
    public let channel: Channel
    /// The stream of inbound messages.
    ///
    /// - Important: The `inbound` stream is a unicast `AsyncSequence` and only one iterator can be created.
    public let inbound: NIOAsyncChannelInboundStream<Inbound>
    /// The writer for writing outbound messages.
    public let outbound: NIOAsyncChannelOutboundWriter<Outbound>

    /// Initializes a new ``NIOAsyncChannel`` wrapping a ``Channel``.
    ///
    /// - Important: This **must** be called on the channel's event loop otherwise this init will crash. This is necessary because
    /// we must install the handlers before any other event in the pipeline happens otherwise we might drop reads.
    ///
    /// - Parameters:
    ///   - channel: The ``Channel`` to wrap.
    ///   - configuration: The ``NIOAsyncChannel``s configuration.
    @inlinable
    public init(
        synchronouslyWrapping channel: Channel,
        configuration: Configuration = .init(),
        finishOnDeinit: Bool = false
    ) throws {
        channel.eventLoop.preconditionInEventLoop()
        self.channel = channel
        (self.inbound, self.outbound) = try channel._syncAddAsyncHandlers(
            backPressureStrategy: configuration.backPressureStrategy,
            isOutboundHalfClosureEnabled: configuration.isOutboundHalfClosureEnabled,
            finishOnDeinit: finishOnDeinit
        )
    }

    /// Initializes a new ``NIOAsyncChannel`` wrapping a ``Channel``.
    ///
    /// - Important: This **must** be called on the channel's event loop otherwise this init will crash. This is necessary because
    /// we must install the handlers before any other event in the pipeline happens otherwise we might drop reads.
    ///
    /// - Parameters:
    ///   - channel: The ``Channel`` to wrap.
    ///   - configuration: The ``NIOAsyncChannel``s configuration.
    @inlinable
    @_disfavoredOverload
    @available(*, deprecated, renamed: "init(synchronouslyWrapping:configuration:finishOnDeinit:)")
    public init(
        synchronouslyWrapping channel: Channel,
        configuration: Configuration = .init()
    ) throws {
        try self.init(synchronouslyWrapping: channel, configuration: configuration, finishOnDeinit: true)
    }

    /// Initializes a new ``NIOAsyncChannel`` wrapping a ``Channel`` where the outbound type is `Never`.
    ///
    /// This initializer will finish the ``NIOAsyncChannel/outbound`` immediately.
    ///
    /// - Important: This **must** be called on the channel's event loop otherwise this init will crash. This is necessary because
    /// we must install the handlers before any other event in the pipeline happens otherwise we might drop reads.
    ///
    /// - Parameters:
    ///   - channel: The ``Channel`` to wrap.
    ///   - configuration: The ``NIOAsyncChannel``s configuration.
    @inlinable
    public init(
        synchronouslyWrapping channel: Channel,
        configuration: Configuration = .init(),
        finishOnDeinit: Bool = false
    ) throws where Outbound == Never {
        channel.eventLoop.preconditionInEventLoop()
        self.channel = channel
        (self.inbound, self.outbound) = try channel._syncAddAsyncHandlers(
            backPressureStrategy: configuration.backPressureStrategy,
            isOutboundHalfClosureEnabled: configuration.isOutboundHalfClosureEnabled,
            finishOnDeinit: finishOnDeinit
        )

        self.outbound.finish()
    }

    /// Initializes a new ``NIOAsyncChannel`` wrapping a ``Channel`` where the outbound type is `Never`.
    ///
    /// This initializer will finish the ``NIOAsyncChannel/outbound`` immediately.
    ///
    /// - Important: This **must** be called on the channel's event loop otherwise this init will crash. This is necessary because
    /// we must install the handlers before any other event in the pipeline happens otherwise we might drop reads.
    ///
    /// - Parameters:
    ///   - channel: The ``Channel`` to wrap.
    ///   - configuration: The ``NIOAsyncChannel``s configuration.
    @inlinable
    @_disfavoredOverload
    @available(*, deprecated, renamed: "init(synchronouslyWrapping:configuration:)")
    public init(
        synchronouslyWrapping channel: Channel,
        configuration: Configuration = .init()
    ) throws where Outbound == Never {
        channel.eventLoop.preconditionInEventLoop()
        self.channel = channel
        (self.inbound, self.outbound) = try channel._syncAddAsyncHandlers(
            backPressureStrategy: configuration.backPressureStrategy,
            isOutboundHalfClosureEnabled: configuration.isOutboundHalfClosureEnabled,
            finishOnDeinit: true
        )

        self.outbound.finish()
    }

    @inlinable
    internal init(
        channel: Channel,
        inboundStream: NIOAsyncChannelInboundStream<Inbound>,
        outboundWriter: NIOAsyncChannelOutboundWriter<Outbound>
    ) {
        channel.eventLoop.preconditionInEventLoop()
        self.channel = channel
        self.inbound = inboundStream
        self.outbound = outboundWriter
    }


    /// This method is only used from our server bootstrap to allow us to run the child channel initializer
    /// at the right moment.
    ///
    /// - Important: This is not considered stable API and should not be used.
    @inlinable
    public static func _wrapAsyncChannelWithTransformations(
        synchronouslyWrapping channel: Channel,
        backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        isOutboundHalfClosureEnabled: Bool = false,
        finishOnDeinit: Bool = false,
        channelReadTransformation: @Sendable @escaping (Channel) -> EventLoopFuture<Inbound>
    ) throws -> NIOAsyncChannel<Inbound, Outbound> where Outbound == Never {
        channel.eventLoop.preconditionInEventLoop()
        let (inboundStream, outboundWriter): (NIOAsyncChannelInboundStream<Inbound>, NIOAsyncChannelOutboundWriter<Outbound>) = try channel._syncAddAsyncHandlersWithTransformations(
            backPressureStrategy: backPressureStrategy,
            isOutboundHalfClosureEnabled: isOutboundHalfClosureEnabled,
            finishOnDeinit: finishOnDeinit,
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
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @inlinable
    func _syncAddAsyncHandlers<Inbound: Sendable, Outbound: Sendable>(
        backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        isOutboundHalfClosureEnabled: Bool,
        finishOnDeinit: Bool
    ) throws -> (NIOAsyncChannelInboundStream<Inbound>, NIOAsyncChannelOutboundWriter<Outbound>) {
        self.eventLoop.assertInEventLoop()

        let closeRatchet = CloseRatchet(isOutboundHalfClosureEnabled: isOutboundHalfClosureEnabled)
        let inboundStream = try NIOAsyncChannelInboundStream<Inbound>.makeWrappingHandler(
            channel: self,
            backPressureStrategy: backPressureStrategy,
            closeRatchet: closeRatchet
        )
        let writer = try NIOAsyncChannelOutboundWriter<Outbound>(
            channel: self,
            closeRatchet: closeRatchet,
            finishOnDeinit: finishOnDeinit
        )
        return (inboundStream, writer)
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @inlinable
    func _syncAddAsyncHandlersWithTransformations<ChannelReadResult>(
        backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        isOutboundHalfClosureEnabled: Bool,
        finishOnDeinit: Bool,
        channelReadTransformation: @Sendable @escaping (Channel) -> EventLoopFuture<ChannelReadResult>
    ) throws -> (NIOAsyncChannelInboundStream<ChannelReadResult>, NIOAsyncChannelOutboundWriter<Never>) {
        self.eventLoop.assertInEventLoop()

        let closeRatchet = CloseRatchet(isOutboundHalfClosureEnabled: isOutboundHalfClosureEnabled)
        let inboundStream = try NIOAsyncChannelInboundStream<ChannelReadResult>.makeTransformationHandler(
            channel: self,
            backPressureStrategy: backPressureStrategy,
            closeRatchet: closeRatchet,
            channelReadTransformation: channelReadTransformation
        )
        let writer = try NIOAsyncChannelOutboundWriter<Never>(
            channel: self,
            closeRatchet: closeRatchet,
            finishOnDeinit: finishOnDeinit
        )
        return (inboundStream, writer)
    }
}
