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
public struct NIOAsyncChannelInboundStream<Inbound: Sendable>: Sendable {
    @usableFromInline
    typealias Producer = NIOThrowingAsyncSequenceProducer<
        Inbound,
        Error,
        NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark,
        NIOAsyncChannelHandlerProducerDelegate
    >

    /// A source used for driving a ``NIOAsyncChannelInboundStream`` during tests.
    public struct TestSource: Sendable {
        @usableFromInline
        internal let continuation: AsyncThrowingStream<Inbound, Error>.Continuation

        @inlinable
        init(continuation: AsyncThrowingStream<Inbound, Error>.Continuation) {
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
        ///
        /// - Parameter error: The error to throw, or nil, to finish normally.
        @inlinable
        public func finish(throwing error: Error? = nil) {
            self.continuation.finish(throwing: error)
        }
    }

    @usableFromInline
    enum _Backing: Sendable {
        case asyncStream(AsyncThrowingStream<Inbound, Error>)
        case producer(Producer)
    }

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
        var continuation: AsyncThrowingStream<Inbound, Error>.Continuation!
        let stream = AsyncThrowingStream<Inbound, Error> { continuation = $0 }
        let source = TestSource(continuation: continuation)
        let inputStream = Self(stream: stream)
        return (inputStream, source)
    }

    @inlinable
    init(stream: AsyncThrowingStream<Inbound, Error>) {
        self._backing = .asyncStream(stream)
    }

    @inlinable
    init<ProducerElement: Sendable, Outbound: Sendable>(
        eventLoop: any EventLoop,
        handler: NIOAsyncChannelHandler<ProducerElement, Inbound, Outbound>,
        backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?,
        closeOnDeinit: Bool
    ) throws {
        eventLoop.preconditionInEventLoop()
        let strategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark

        if let userProvided = backPressureStrategy {
            strategy = userProvided
        } else {
            // Default strategy. These numbers are fairly arbitrary, but they line up with the default value of
            // maxMessagesPerRead.
            strategy = .init(lowWatermark: 2, highWatermark: 10)
        }

        let sequence = Producer.makeSequence(
            backPressureStrategy: strategy,
            finishOnDeinit: closeOnDeinit,
            delegate: NIOAsyncChannelHandlerProducerDelegate(handler: handler)
        )

        handler.source = sequence.source
        self._backing = .producer(sequence.sequence)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncChannelInboundStream: AsyncSequence {
    public typealias Element = Inbound

    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        enum _Backing {
            case asyncStream(AsyncThrowingStream<Inbound, Error>.Iterator)
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

        @inlinable
        public mutating func next() async throws -> Element? {
            switch self._backing {
            case .asyncStream(var iterator):
                defer {
                    self._backing = .asyncStream(iterator)
                }
                let value = try await iterator.next()
                return value

            case .producer(let iterator):
                return try await iterator.next()
            }
        }
    }

    @inlinable
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(self._backing)
    }
}

/// The ``NIOAsyncChannelInboundStream/AsyncIterator`` MUST NOT be shared across `Task`s. With marking this as
/// unavailable we are explicitly declaring this.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@available(*, unavailable)
extension NIOAsyncChannelInboundStream.AsyncIterator: Sendable {}

@available(*, unavailable)
extension NIOAsyncChannelInboundStream.AsyncIterator._Backing: Sendable {}
