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
/// - traditional NIO back pressure such as writability signals and the channel's read call
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
            backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark = .init(
                lowWatermark: 2,
                highWatermark: 10
            ),
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
    @available(*, deprecated, message: "Use the executeThenClose scoped method instead.")
    public var inbound: NIOAsyncChannelInboundStream<Inbound> {
        self._inbound
    }
    /// The writer for writing outbound messages.
    @available(*, deprecated, message: "Use the executeThenClose scoped method instead.")
    public var outbound: NIOAsyncChannelOutboundWriter<Outbound> {
        self._outbound
    }

    @usableFromInline
    let _inbound: NIOAsyncChannelInboundStream<Inbound>
    @usableFromInline
    let _outbound: NIOAsyncChannelOutboundWriter<Outbound>

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
        wrappingChannelSynchronously channel: Channel,
        configuration: Configuration = .init()
    ) throws {
        channel.eventLoop.preconditionInEventLoop()
        self.channel = channel
        (self._inbound, self._outbound) = try channel._syncAddAsyncHandlers(
            backPressureStrategy: configuration.backPressureStrategy,
            isOutboundHalfClosureEnabled: configuration.isOutboundHalfClosureEnabled,
            closeOnDeinit: false
        )
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
        wrappingChannelSynchronously channel: Channel,
        configuration: Configuration = .init()
    ) throws where Outbound == Never {
        channel.eventLoop.preconditionInEventLoop()
        self.channel = channel
        (self._inbound, self._outbound) = try channel._syncAddAsyncHandlers(
            backPressureStrategy: configuration.backPressureStrategy,
            isOutboundHalfClosureEnabled: configuration.isOutboundHalfClosureEnabled,
            closeOnDeinit: false
        )

        self._outbound.finish()
    }

    /// Initializes a new ``NIOAsyncChannel`` wrapping a ``Channel``.
    ///
    /// - Important: This **must** be called on the channel's event loop otherwise this init will crash. This is necessary because
    /// we must install the handlers before any other event in the pipeline happens otherwise we might drop reads.
    ///
    /// - Parameters:
    ///   - channel: The ``Channel`` to wrap.
    ///   - configuration: The ``NIOAsyncChannel``s configuration.
    @available(
        *,
        deprecated,
        renamed: "init(wrappingChannelSynchronously:configuration:)",
        message: "This method has been deprecated since it defaults to deinit based resource teardown"
    )
    @inlinable
    public init(
        synchronouslyWrapping channel: Channel,
        configuration: Configuration = .init()
    ) throws {
        channel.eventLoop.preconditionInEventLoop()
        self.channel = channel
        (self._inbound, self._outbound) = try channel._syncAddAsyncHandlers(
            backPressureStrategy: configuration.backPressureStrategy,
            isOutboundHalfClosureEnabled: configuration.isOutboundHalfClosureEnabled,
            closeOnDeinit: true
        )
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
    @available(
        *,
        deprecated,
        renamed: "init(wrappingChannelSynchronously:configuration:)",
        message: "This method has been deprecated since it defaults to deinit based resource teardown"
    )
    public init(
        synchronouslyWrapping channel: Channel,
        configuration: Configuration = .init()
    ) throws where Outbound == Never {
        channel.eventLoop.preconditionInEventLoop()
        self.channel = channel
        (self._inbound, self._outbound) = try channel._syncAddAsyncHandlers(
            backPressureStrategy: configuration.backPressureStrategy,
            isOutboundHalfClosureEnabled: configuration.isOutboundHalfClosureEnabled,
            closeOnDeinit: true
        )

        self._outbound.finish()
    }

    @inlinable
    internal init(
        channel: Channel,
        inboundStream: NIOAsyncChannelInboundStream<Inbound>,
        outboundWriter: NIOAsyncChannelOutboundWriter<Outbound>
    ) {
        channel.eventLoop.preconditionInEventLoop()
        self.channel = channel
        self._inbound = inboundStream
        self._outbound = outboundWriter
    }

    /// This method is only used from our server bootstrap to allow us to run the child channel initializer
    /// at the right moment.
    ///
    /// - Important: This is not considered stable API and should not be used.
    @inlinable
    @available(
        *,
        deprecated,
        message: "This method has been deprecated since it defaults to deinit based resource teardown"
    )
    public static func _wrapAsyncChannelWithTransformations(
        synchronouslyWrapping channel: Channel,
        backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        isOutboundHalfClosureEnabled: Bool = false,
        channelReadTransformation: @Sendable @escaping (Channel) -> EventLoopFuture<Inbound>
    ) throws -> NIOAsyncChannel<Inbound, Outbound> where Outbound == Never {
        channel.eventLoop.preconditionInEventLoop()
        let (inboundStream, outboundWriter):
            (NIOAsyncChannelInboundStream<Inbound>, NIOAsyncChannelOutboundWriter<Outbound>) =
                try channel._syncAddAsyncHandlersWithTransformations(
                    backPressureStrategy: backPressureStrategy,
                    isOutboundHalfClosureEnabled: isOutboundHalfClosureEnabled,
                    closeOnDeinit: true,
                    channelReadTransformation: channelReadTransformation
                )

        outboundWriter.finish()

        return .init(
            channel: channel,
            inboundStream: inboundStream,
            outboundWriter: outboundWriter
        )
    }

    /// This method is only used from our server bootstrap to allow us to run the child channel initializer
    /// at the right moment.
    ///
    /// - Important: This is not considered stable API and should not be used.
    @inlinable
    public static func _wrapAsyncChannelWithTransformations(
        wrappingChannelSynchronously channel: Channel,
        backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark? = nil,
        isOutboundHalfClosureEnabled: Bool = false,
        channelReadTransformation: @Sendable @escaping (Channel) -> EventLoopFuture<Inbound>
    ) throws -> NIOAsyncChannel<Inbound, Outbound> where Outbound == Never {
        channel.eventLoop.preconditionInEventLoop()
        let (inboundStream, outboundWriter):
            (NIOAsyncChannelInboundStream<Inbound>, NIOAsyncChannelOutboundWriter<Outbound>) =
                try channel._syncAddAsyncHandlersWithTransformations(
                    backPressureStrategy: backPressureStrategy,
                    isOutboundHalfClosureEnabled: isOutboundHalfClosureEnabled,
                    closeOnDeinit: false,
                    channelReadTransformation: channelReadTransformation
                )

        outboundWriter.finish()

        return .init(
            channel: channel,
            inboundStream: inboundStream,
            outboundWriter: outboundWriter
        )
    }

    /// Provides scoped access to the inbound and outbound side of the underlying ``Channel``.
    ///
    /// - Important: After this method returned the underlying ``Channel`` will be closed.
    ///
    /// - Parameter body: A closure that gets scoped access to the inbound and outbound.
    @_disfavoredOverload
    public func executeThenClose<Result>(
        _ body: (_ inbound: NIOAsyncChannelInboundStream<Inbound>, _ outbound: NIOAsyncChannelOutboundWriter<Outbound>)
            async throws -> Result
    ) async throws -> Result {
        let result: Result
        do {
            result = try await body(self._inbound, self._outbound)
        } catch let bodyError {
            do {
                self._outbound.finish()
                try await self.channel.close().get()
                throw bodyError
            } catch {
                throw bodyError
            }
        }

        self._outbound.finish()
        // We ignore errors from close, since all we care about is that the channel has been closed
        // at this point.
        self.channel.close(promise: nil)
        // `closeFuture` should never be failed, so we could ignore the error. However, do an
        // assertionFailure to guide bad Channel implementations that are incorrectly failing this
        // future to stop failing it.
        do {
            try await self.channel.closeFuture.get()
        } catch {
            assertionFailure(
                """
                The channel's closeFuture should never be failed, but it was failed with error: \(error).
                This is an error in the channel's implementation.
                Refer to `Channel/closeFuture`'s documentation for more information.
                """
            )
        }
        return result
    }

    /// Provides scoped access to the inbound and outbound side of the underlying ``Channel``.
    ///
    /// - Important: After this method returned the underlying ``Channel`` will be closed.
    ///
    /// - Parameters:
    ///     - actor: actor where this function should be isolated to
    ///     - body: A closure that gets scoped access to the inbound and outbound.
    public func executeThenClose<Result>(
        isolation actor: isolated (any Actor)? = #isolation,
        _ body: (_ inbound: NIOAsyncChannelInboundStream<Inbound>, _ outbound: NIOAsyncChannelOutboundWriter<Outbound>)
            async throws -> sending Result
    ) async throws -> sending Result {
        let result: Result
        do {
            result = try await body(self._inbound, self._outbound)
        } catch let bodyError {
            do {
                self._outbound.finish()
                try await self.channel.close().get()
                throw bodyError
            } catch {
                throw bodyError
            }
        }

        self._outbound.finish()
        // We ignore errors from close, since all we care about is that the channel has been closed
        // at this point.
        self.channel.close(promise: nil)
        // `closeFuture` should never be failed, so we could ignore the error. However, do an
        // assertionFailure to guide bad Channel implementations that are incorrectly failing this
        // future to stop failing it.
        do {
            try await self.channel.closeFuture.get()
        } catch {
            assertionFailure(
                """
                The channel's closeFuture should never be failed, but it was failed with error: \(error).
                This is an error in the channel's implementation.
                Refer to `Channel/closeFuture`'s documentation for more information.
                """
            )
        }

        return result
    }
}

// swift-format-ignore: AmbiguousTrailingClosureOverload
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncChannel {
    /// Provides scoped access to the inbound side of the underlying ``Channel``.
    ///
    /// - Important: After this method returned the underlying ``Channel`` will be closed.
    ///
    /// - Parameter body: A closure that gets scoped access to the inbound.
    @_disfavoredOverload
    public func executeThenClose<Result>(
        _ body: (_ inbound: NIOAsyncChannelInboundStream<Inbound>) async throws -> Result
    ) async throws -> Result where Outbound == Never {
        let result: Result
        do {
            result = try await body(self._inbound)
        } catch let bodyError {
            do {
                self._outbound.finish()
                try await self.channel.close().get()
                throw bodyError
            } catch {
                throw bodyError
            }
        }

        self._outbound.finish()
        // We ignore errors from close, since all we care about is that the channel has been closed
        // at this point.
        self.channel.close(promise: nil)
        // `closeFuture` should never be failed, so we could ignore the error. However, do an
        // assertionFailure to guide bad Channel implementations that are incorrectly failing this
        // future to stop failing it.
        do {
            try await self.channel.closeFuture.get()
        } catch {
            assertionFailure(
                """
                The channel's closeFuture should never be failed, but it was failed with error: \(error).
                This is an error in the channel's implementation.
                Refer to `Channel/closeFuture`'s documentation for more information.
                """
            )
        }
        return result
    }

    /// Provides scoped access to the inbound side of the underlying ``Channel``.
    ///
    /// - Important: After this method returned the underlying ``Channel`` will be closed.
    ///
    /// - Parameters:
    ///     - actor: actor where this function should be isolated to
    ///     - body: A closure that gets scoped access to the inbound.
    public func executeThenClose<Result>(
        isolation actor: isolated (any Actor)? = #isolation,
        _ body: (_ inbound: NIOAsyncChannelInboundStream<Inbound>) async throws -> sending Result
    ) async throws -> sending Result where Outbound == Never {
        let result: Result
        do {
            result = try await body(self._inbound)
        } catch let bodyError {
            do {
                self._outbound.finish()
                try await self.channel.close().get()
                throw bodyError
            } catch {
                throw bodyError
            }
        }

        self._outbound.finish()
        // We ignore errors from close, since all we care about is that the channel has been closed
        // at this point.
        self.channel.close(promise: nil)
        // `closeFuture` should never be failed, so we could ignore the error. However, do an
        // assertionFailure to guide bad Channel implementations that are incorrectly failing this
        // future to stop failing it.
        do {
            try await self.channel.closeFuture.get()
        } catch {
            assertionFailure(
                """
                The channel's closeFuture should never be failed, but it was failed with error: \(error).
                This is an error in the channel's implementation.
                Refer to `Channel/closeFuture`'s documentation for more information.
                """
            )
        }

        return result
    }
}

extension Channel {
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @inlinable
    func _syncAddAsyncHandlers<Inbound: Sendable, Outbound: Sendable>(
        backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        isOutboundHalfClosureEnabled: Bool,
        closeOnDeinit: Bool
    ) throws -> (NIOAsyncChannelInboundStream<Inbound>, NIOAsyncChannelOutboundWriter<Outbound>) {
        self.eventLoop.assertInEventLoop()

        let handler = NIOAsyncChannelHandler<Inbound, Inbound, Outbound>(
            eventLoop: self.eventLoop,
            transformation: .syncWrapping { $0 },
            isOutboundHalfClosureEnabled: isOutboundHalfClosureEnabled
        )

        let inboundStream = try NIOAsyncChannelInboundStream(
            eventLoop: self.eventLoop,
            handler: handler,
            backPressureStrategy: backPressureStrategy,
            closeOnDeinit: closeOnDeinit
        )

        let writer = try NIOAsyncChannelOutboundWriter<Outbound>(
            eventLoop: self.eventLoop,
            handler: handler,
            isOutboundHalfClosureEnabled: isOutboundHalfClosureEnabled,
            closeOnDeinit: closeOnDeinit
        )

        try self.pipeline.syncOperations.addHandler(handler)
        return (inboundStream, writer)
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    @inlinable
    func _syncAddAsyncHandlersWithTransformations<ChannelReadResult>(
        backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        isOutboundHalfClosureEnabled: Bool,
        closeOnDeinit: Bool,
        channelReadTransformation: @Sendable @escaping (Channel) -> EventLoopFuture<ChannelReadResult>
    ) throws -> (NIOAsyncChannelInboundStream<ChannelReadResult>, NIOAsyncChannelOutboundWriter<Never>) {
        self.eventLoop.assertInEventLoop()

        let handler = NIOAsyncChannelHandler<Channel, ChannelReadResult, Never>(
            eventLoop: self.eventLoop,
            transformation: .transformation(channelReadTransformation: channelReadTransformation),
            isOutboundHalfClosureEnabled: isOutboundHalfClosureEnabled
        )

        let inboundStream = try NIOAsyncChannelInboundStream(
            eventLoop: self.eventLoop,
            handler: handler,
            backPressureStrategy: backPressureStrategy,
            closeOnDeinit: closeOnDeinit
        )

        let writer = try NIOAsyncChannelOutboundWriter<Never>(
            eventLoop: self.eventLoop,
            handler: handler,
            isOutboundHalfClosureEnabled: isOutboundHalfClosureEnabled,
            closeOnDeinit: closeOnDeinit
        )

        try self.pipeline.syncOperations.addHandler(handler)
        return (inboundStream, writer)
    }
}
