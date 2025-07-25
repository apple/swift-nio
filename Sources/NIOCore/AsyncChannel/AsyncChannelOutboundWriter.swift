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

/// A ``NIOAsyncChannelOutboundWriter`` is used to write and flush new outbound messages in a channel.
///
/// The writer acts as a bridge between the Concurrency and NIO world. It allows to write and flush messages into the
/// underlying ``Channel``. Furthermore, it respects back-pressure of the channel by suspending the calls to write until
/// the channel becomes writable again.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct NIOAsyncChannelOutboundWriter<OutboundOut: Sendable>: Sendable {
    @usableFromInline
    typealias _Writer = NIOAsyncWriter<
        OutboundOut,
        NIOAsyncChannelHandlerWriterDelegate<OutboundOut>
    >

    /// An `AsyncSequence` backing a ``NIOAsyncChannelOutboundWriter`` for testing purposes.
    public struct TestSink: AsyncSequence {
        public typealias Element = OutboundOut

        @usableFromInline
        internal let stream: AsyncStream<OutboundOut>

        @usableFromInline
        internal let continuation: AsyncStream<OutboundOut>.Continuation

        @inlinable
        init(
            stream: AsyncStream<OutboundOut>,
            continuation: AsyncStream<OutboundOut>.Continuation
        ) {
            self.stream = stream
            self.continuation = continuation
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(iterator: self.stream.makeAsyncIterator())
        }

        public struct AsyncIterator: AsyncIteratorProtocol {
            @usableFromInline
            internal var iterator: AsyncStream<OutboundOut>.AsyncIterator

            @inlinable
            init(iterator: AsyncStream<OutboundOut>.AsyncIterator) {
                self.iterator = iterator
            }

            public mutating func next() async -> Element? {
                await self.iterator.next()
            }
        }
    }

    @usableFromInline
    enum Backing: Sendable {
        case asyncStream(AsyncStream<OutboundOut>.Continuation)
        case writer(_Writer)
    }

    @usableFromInline
    internal let _backing: Backing

    /// Creates a new ``NIOAsyncChannelOutboundWriter`` backed by a ``NIOAsyncChannelOutboundWriter/TestSink``.
    /// This is mostly useful for testing purposes where one wants to observe the written data.
    @inlinable
    public static func makeTestingWriter() -> (Self, TestSink) {
        var continuation: AsyncStream<OutboundOut>.Continuation!
        let asyncStream = AsyncStream<OutboundOut> { continuation = $0 }
        let writer = Self(continuation: continuation)
        let sink = TestSink(stream: asyncStream, continuation: continuation)

        return (writer, sink)
    }

    @inlinable
    init<InboundIn, ProducerElement>(
        eventLoop: any EventLoop,
        handler: NIOAsyncChannelHandler<InboundIn, ProducerElement, OutboundOut>,
        isOutboundHalfClosureEnabled: Bool,
        closeOnDeinit: Bool
    ) throws {
        eventLoop.preconditionInEventLoop()
        let writer = _Writer.makeWriter(
            elementType: OutboundOut.self,
            isWritable: true,
            finishOnDeinit: closeOnDeinit,
            delegate: .init(handler: handler)
        )

        handler.sink = writer.sink
        handler.writer = writer.writer

        self._backing = .writer(writer.writer)
    }

    @inlinable
    init(continuation: AsyncStream<OutboundOut>.Continuation) {
        self._backing = .asyncStream(continuation)
    }

    /// Send a write into the ``ChannelPipeline`` and flush it right away.
    ///
    /// This method suspends if the underlying channel is not writable and will resume once the it becomes writable again.
    @inlinable
    public func write(_ data: OutboundOut) async throws {
        switch self._backing {
        case .asyncStream(let continuation):
            continuation.yield(data)
        case .writer(let writer):
            try await writer.yield(data)
        }
    }

    /// Send a sequence of writes into the ``ChannelPipeline`` and flush them right away.
    ///
    /// This method suspends if the underlying channel is not writable and will resume once the it becomes writable again.
    @inlinable
    public func write<Writes: Sequence>(contentsOf sequence: Writes) async throws where Writes.Element == OutboundOut {
        switch self._backing {
        case .asyncStream(let continuation):
            for data in sequence {
                continuation.yield(data)
            }
        case .writer(let writer):
            try await writer.yield(contentsOf: sequence)
        }
    }

    /// Send an asynchronous sequence of writes into the ``ChannelPipeline``.
    ///
    /// This will flush after every write.
    ///
    /// This method suspends if the underlying channel is not writable and will resume once the it becomes writable again.
    @inlinable
    public func write<Writes: AsyncSequence>(contentsOf sequence: Writes) async throws
    where Writes.Element == OutboundOut {
        for try await data in sequence {
            try await self.write(data)
        }
    }

    /// Finishes the writer.
    ///
    /// This might trigger a half closure if the ``NIOAsyncChannel`` was configured to support it.
    public func finish() {
        switch self._backing {
        case .asyncStream(let continuation):
            continuation.finish()
        case .writer(let writer):
            writer.finish()
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncChannelOutboundWriter.TestSink: Sendable {}

@available(*, unavailable)
extension NIOAsyncChannelOutboundWriter.TestSink.AsyncIterator: Sendable {}
