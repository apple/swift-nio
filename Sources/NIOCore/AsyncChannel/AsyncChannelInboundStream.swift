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

/// The inbound message asynchronous sequence of a ``NIOAsyncChannel``.
///
/// This is a unicast async sequence that allows a single iterator to be created.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@_spi(AsyncChannel)
public struct NIOAsyncChannelInboundStream<Inbound: Sendable>: Sendable {
    @usableFromInline
    typealias Producer = NIOThrowingAsyncSequenceProducer<Inbound, Error, NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark, NIOAsyncChannelInboundStreamChannelHandlerProducerDelegate>

    /// A source used for driving a ``NIOAsyncChannelInboundStream`` during tests.
    public struct TestSource {
        @usableFromInline
        internal let continuation: AsyncStream<Inbound>.Continuation

        @inlinable
        init(continuation: AsyncStream<Inbound>.Continuation) {
            self.continuation = continuation
        }

        /// Yields the element to the inbound stream.
        ///
        /// - Parameter element: The element to yield to the inbound stream.
        @inlinable
        public func yield(_ element: Inbound) {
            self.continuation.yield(element)
        }

        /// Finished the inbound stream.
        @inlinable
        public func finish() {
            self.continuation.finish()
        }
    }

    #if swift(>=5.7)
    @usableFromInline
    enum _Backing: Sendable {
        case asyncStream(AsyncStream<Inbound>)
        case producer(Producer)
    }
    #else
    // AsyncStream wasn't marked as `Sendable` in 5.6
    @usableFromInline
    enum _Backing: @unchecked Sendable {
        case asyncStream(AsyncStream<Inbound>)
        case producer(Producer)
    }
    #endif

    /// The underlying async sequence.
    @usableFromInline
    let _backing: _Backing

    /// Creates a new stream with a source for testing.
    ///
    /// This is useful for writing unit tests where you want to drive a ``NIOAsyncChannelInboundStream``.
    ///
    /// - Returns: A tuple containing the input stream and a test source to drive it.
    @inlinable
    public static func makeTestingStream() -> (Self, TestSource) {
        var continuation: AsyncStream<Inbound>.Continuation!
        let stream = AsyncStream<Inbound> { continuation = $0 }
        let source = TestSource(continuation: continuation)
        let inputStream = Self(stream: stream)
        return (inputStream, source)
    }

    @inlinable
    init(stream: AsyncStream<Inbound>) {
        self._backing = .asyncStream(stream)
    }

    @inlinable
    init<HandlerInbound: Sendable>(
        channel: Channel,
        backpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        closeRatchet: CloseRatchet,
        handler: NIOAsyncChannelInboundStreamChannelHandler<HandlerInbound, Inbound>
    ) throws {
        channel.eventLoop.preconditionInEventLoop()
        let strategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark

        if let userProvided = backpressureStrategy {
            strategy = userProvided
        } else {
            // Default strategy. These numbers are fairly arbitrary, but they line up with the default value of
            // maxMessagesPerRead.
            strategy = .init(lowWatermark: 2, highWatermark: 10)
        }

        let sequence = Producer.makeSequence(
            backPressureStrategy: strategy,
            delegate: NIOAsyncChannelInboundStreamChannelHandlerProducerDelegate(handler: handler)
        )
        handler.source = sequence.source
        try channel.pipeline.syncOperations.addHandler(handler)
        self._backing = .producer(sequence.sequence)
    }

    /// Creates a new ``NIOAsyncChannelInboundStream`` which is used when the pipeline got synchronously wrapped.
    @inlinable
    static func makeWrappingHandler(
        channel: Channel,
        backpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        closeRatchet: CloseRatchet
    ) throws -> NIOAsyncChannelInboundStream {
        let handler = NIOAsyncChannelInboundStreamChannelHandler<Inbound, Inbound>.makeHandler(
            eventLoop: channel.eventLoop,
            closeRatchet: closeRatchet
        )

        return try .init(
            channel: channel,
            backpressureStrategy: backpressureStrategy,
            closeRatchet: closeRatchet,
            handler: handler
        )
    }

    /// Creates a new ``NIOAsyncChannelInboundStream`` which has hooks for transformations.
    @inlinable
    static func makeTransformationHandler(
        channel: Channel,
        backpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        closeRatchet: CloseRatchet,
        channelReadTransformation: @Sendable @escaping (Channel) -> EventLoopFuture<Inbound>
    ) throws -> NIOAsyncChannelInboundStream {
        let handler = NIOAsyncChannelInboundStreamChannelHandler<Channel, Inbound>.makeHandlerWithTransformations(
            eventLoop: channel.eventLoop,
            closeRatchet: closeRatchet,
            channelReadTransformation: channelReadTransformation
        )

        return try .init(
            channel: channel,
            backpressureStrategy: backpressureStrategy,
            closeRatchet: closeRatchet,
            handler: handler
        )
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncChannelInboundStream: AsyncSequence {
    @_spi(AsyncChannel)
    public typealias Element = Inbound

    @_spi(AsyncChannel)
    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        enum _Backing {
            case asyncStream(AsyncStream<Inbound>.Iterator)
            case producer(Producer.AsyncIterator)
        }

        @usableFromInline var _backing: _Backing

        @inlinable
        init(_ backing: NIOAsyncChannelInboundStream<Inbound>._Backing) {
            switch backing {
            case .asyncStream(let asyncStream):
                self._backing = .asyncStream(asyncStream.makeAsyncIterator())
            case .producer(let producer):
                self._backing = .producer(producer.makeAsyncIterator())
            }
        }

        @inlinable @_spi(AsyncChannel)
        public mutating func next() async throws -> Element? {
            switch self._backing {
            case .asyncStream(var iterator):
                let value = await iterator.next()
                self._backing = .asyncStream(iterator)
                return value

            case .producer(let iterator):
                return try await iterator.next()
            }
        }
    }

    @inlinable
    @_spi(AsyncChannel)
    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(self._backing)
    }
}

/// The ``NIOAsyncChannelInboundStream/AsyncIterator`` MUST NOT be shared across `Task`s. With marking this as
/// unavailable we are explicitly declaring this.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@available(*, unavailable)
extension NIOAsyncChannelInboundStream.AsyncIterator: Sendable {}
