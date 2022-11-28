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
import DequeModule

@usableFromInline
enum ProducingState {
    // Not .stopProducing
    case keepProducing

    // .stopProducing but not read()
    case producingPaused

    // .stopProducing and read()
    case producingPausedWithOutstandingRead
}

/// A `ChannelHandler` that is used to transform the inbound portion of a NIO
/// `Channel` into an `AsyncSequence` that supports backpressure.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public final class NIOAsyncChannelAdapterHandler<InboundIn>: @unchecked Sendable, ChannelDuplexHandler, RemovableChannelHandler {
    public typealias OutboundIn = Any
    public typealias OutboundOut = Any

    @usableFromInline
    typealias Source = NIOThrowingAsyncSequenceProducer<InboundIn, Error, NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark, NIOAsyncChannelAdapterHandler<InboundIn>>.Source

    @usableFromInline var source: Source?

    @usableFromInline var context: ChannelHandlerContext?

    @usableFromInline var buffer: [InboundIn] = []

    @usableFromInline var producingState: ProducingState = .keepProducing

    @usableFromInline let loop: EventLoop

    @inlinable
    internal init(loop: EventLoop) {
        self.loop = loop
    }

    @inlinable
    public func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    @inlinable
    public func handlerRemoved(context: ChannelHandlerContext) {
        self._completeStream(context: context)
        self.context = nil
    }

    @inlinable
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.buffer.append(self.unwrapInboundIn(data))

        // We forward on reads here to enable better channel composition.
        context.fireChannelRead(data)
    }

    @inlinable
    public func channelReadComplete(context: ChannelHandlerContext) {
        self._deliverReads(context: context)
        context.fireChannelReadComplete()
    }

    @inlinable
    public func channelInactive(context: ChannelHandlerContext) {
        self._completeStream(context: context)
        context.fireChannelInactive()
    }

    @inlinable
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        self._completeStream(with: error, context: context)
        context.fireErrorCaught(error)
    }

    @inlinable
    public func read(context: ChannelHandlerContext) {
        switch self.producingState {
        case .keepProducing:
            context.read()
        case .producingPaused:
            self.producingState = .producingPausedWithOutstandingRead
        case .producingPausedWithOutstandingRead:
            ()
        }
    }

    @inlinable
    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case ChannelEvent.inputClosed:
            self._completeStream(context: context)
        default:
            ()
        }

        context.fireUserInboundEventTriggered(event)
    }

    @inlinable
    internal func _completeStream(with error: Error? = nil, context: ChannelHandlerContext) {
        guard let source = self.source else {
            return
        }

        self._deliverReads(context: context)

        if let error = error {
            source.finish(error)
        } else {
            source.finish()
        }

        // We can nil the source here, as we're no longer going to use it.
        self.source = nil
    }

    @inlinable
    internal func _deliverReads(context: ChannelHandlerContext) {
        if self.buffer.isEmpty {
            return
        }

        guard let source = self.source else {
            self.buffer.removeAll()
            return
        }

        let result = source.yield(contentsOf: self.buffer)
        switch result {
        case .produceMore, .dropped:
            ()
        case .stopProducing:
            if self.producingState != .producingPausedWithOutstandingRead {
                self.producingState = .producingPaused
            }
        }
        self.buffer.removeAll(keepingCapacity: true)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncChannelAdapterHandler: NIOAsyncSequenceProducerDelegate {
    public func didTerminate() {
        self.loop.execute {
            self.source = nil

            // Wedges the read open forever, we'll never read again.
            self.producingState = .producingPausedWithOutstandingRead
        }
    }

    public func produceMore() {
        self.loop.execute {
            switch self.producingState {
            case .producingPaused:
                self.producingState = .keepProducing
            case .producingPausedWithOutstandingRead:
                self.producingState = .keepProducing
                self.context?.read()
            case .keepProducing:
                ()
            }
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@usableFromInline
internal final class NIOAsyncChannelWriterHandler<OutboundOut>: @unchecked Sendable, ChannelDuplexHandler {
    public typealias InboundIn = Any
    public typealias InboundOut = Any
    public typealias OutboundIn = Any
    public typealias OutboundOut = OutboundOut

    @usableFromInline
    typealias Writer = NIOAsyncWriter<OutboundOut, NIOAsyncChannelWriterHandler<OutboundOut>>

    @usableFromInline
    typealias Sink = Writer.Sink

    @usableFromInline
    var sink: Sink?

    @usableFromInline
    var context: ChannelHandlerContext?

    @usableFromInline
    let loop: EventLoop

    @inlinable
    init(loop: EventLoop) {
        self.loop = loop
    }

    @inlinable
    static func makeHandler(loop: EventLoop) -> (NIOAsyncChannelWriterHandler<OutboundOut>, Writer) {
        let handler = NIOAsyncChannelWriterHandler<OutboundOut>(loop: loop)
        let writerComponents = Writer.makeWriter(elementType: OutboundOut.self, isWritable: true, delegate: handler)
        handler.sink = writerComponents.sink
        return (handler, writerComponents.writer)
    }

    @inlinable
    func _doOutboundWrites(context: ChannelHandlerContext, writes: Deque<OutboundOut>) {
        for write in writes {
            context.write(self.wrapOutboundOut(write), promise: nil)
        }

        context.flush()
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.sink = nil
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.sink?.finish(error: error)
        context.fireErrorCaught(error)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        self.sink?.finish()
        context.fireChannelInactive()
    }

    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        self.sink?.setWritability(to: context.channel.isWritable)
        context.fireChannelWritabilityChanged()
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncChannelWriterHandler: NIOAsyncWriterSinkDelegate {
    public typealias Element = OutboundOut

    @inlinable
    public func didYield(contentsOf sequence: Deque<OutboundOut>) {
        // This is always called from an async context, so we must loop-hop.
        // Because we always loop-hop, we're always at the top of a stack frame. As this
        // is the only source of writes for us, and as this channel handler doesn't implement
        // func write(), we cannot possibly re-entrantly write. That means we can skip many of the
        // awkward re-entrancy protections NIO usually requires, and can safely just do an iterative
        // write.
        self.loop.execute {
            guard let context = self.context else {
                // Already removed from the channel by now, we can stop.
                return
            }

            self._doOutboundWrites(context: context, writes: sequence)
        }
    }

    @inlinable
    public func didTerminate(error: Error?) {
        // TODO: how do we spot full closure here?
        // This always called from an async context, so we must loop-hop.
        self.loop.execute {
            self.context?.close(mode: .output, promise: nil)
            self.sink = nil
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct NIOInboundChannelStream<InboundIn>: @unchecked Sendable {
    @usableFromInline
    typealias Producer = NIOThrowingAsyncSequenceProducer<InboundIn, Error, NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark, NIOAsyncChannelAdapterHandler<InboundIn>>

    @usableFromInline let _producer: Producer

    @inlinable
    public init(_ channel: Channel, backpressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark?) async throws {
        let handler = NIOAsyncChannelAdapterHandler<InboundIn>(loop: channel.eventLoop)
        let strategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark

        if let userProvided = backpressureStrategy {
            strategy = userProvided
        } else {
            // Default strategy
            strategy = .init(lowWatermark: 2, highWatermark: 10)
        }

        let sequence = Producer.makeSequence(backPressureStrategy: strategy, delegate: handler)
        handler.source = sequence.source
        try await channel.pipeline.addHandler(handler)
        self._producer = sequence.sequence
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOInboundChannelStream: AsyncSequence {
    public typealias Element = InboundIn

    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline var _iterator: Producer.AsyncIterator

        @inlinable
        init(_ iterator: Producer.AsyncIterator) {
            self._iterator = iterator
        }

        @inlinable public func next() async throws -> Element? {
            return try await self._iterator.next()
        }
    }

    @inlinable
    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(self._producer.makeAsyncIterator())
    }
}
#endif
