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

@usableFromInline
enum PendingReadState {
    // Not .stopProducing
    case canRead

    // .stopProducing but not read()
    case readBlocked

    // .stopProducing and read()
    case pendingRead
}

#if compiler(>=5.5.2) && canImport(_Concurrency)
import NIOConcurrencyHelpers

/// A `ChannelHandler` that is used to transform the inbound portion of a NIO
/// `Channel` into an `AsyncSequence` that supports backpressure.
///
/// Users should not construct this type directly: instead, they should use the
/// `Channel.makeAsyncStream(of:config:)` method to use the `Channel`'s preferred
/// construction. These types are `public` only to allow other `Channel`s to
/// override the implementation of that method.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public final class NIOAsyncChannelAdapterHandler<InboundIn>: @unchecked Sendable, ChannelDuplexHandler {
    public typealias OutboundIn = Any
    public typealias OutboundOut = Any

    @usableFromInline
    typealias Source = NIOThrowingAsyncSequenceProducer<InboundIn, Error, NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark, NIOAsyncChannelAdapterHandler<InboundIn>>.Source

    // The initial buffer is just using a lock. We'll do something better later if profiling
    // shows it's necessary.
    @usableFromInline var source: Source?

    @usableFromInline var context: ChannelHandlerContext?

    @usableFromInline var buffer: [InboundIn] = []

    @usableFromInline var pendingReadState: PendingReadState = .canRead

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
        self.context = nil
    }

    @inlinable
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.buffer.append(self.unwrapInboundIn(data))
    }

    @inlinable
    public func channelReadComplete(context: ChannelHandlerContext) {
        if self.buffer.isEmpty {
            return
        }

        let result = self.source!.yield(contentsOf: self.buffer)
        switch result {
        case .produceMore:
            ()
        case .stopProducing:
            if self.pendingReadState != .pendingRead {
                self.pendingReadState = .readBlocked
            }
        case .dropped:
            fatalError("TODO: can this happen?")
        }
        self.buffer.removeAll(keepingCapacity: true)
    }

    @inlinable
    public func channelInactive(context: ChannelHandlerContext) {
        // TODO: make this less nasty
        self.channelReadComplete(context: context)
        self.source!.finish()
    }

    @inlinable
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        // TODO: make this less nasty
        self.channelReadComplete(context: context)
        self.source!.finish(error)
    }

    @inlinable
    public func read(context: ChannelHandlerContext) {
        switch self.pendingReadState {
        case .canRead:
            context.read()
        case .readBlocked:
            self.pendingReadState = .pendingRead
        case .pendingRead:
            ()
        }
    }

    @inlinable
    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelShouldQuiesceEvent:
            fatalError("What do we do here?")
        case ChannelEvent.inputClosed:
            // TODO: make this less nasty
            self.channelReadComplete(context: context)
            self.source!.finish()
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncChannelAdapterHandler: NIOAsyncSequenceProducerDelegate {
    public func didTerminate() {
        self.loop.execute {
            self.source = nil

            // Wedges the read open forever, we'll never read again.
            self.pendingReadState = .pendingRead
        }
    }

    public func produceMore() {
        self.loop.execute {
            switch self.pendingReadState {
            case .readBlocked:
                self.pendingReadState = .canRead
            case .pendingRead:
                self.pendingReadState = .canRead
                self.context?.read()
            case .canRead:
                ()
            }
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncChannelAdapterHandler {
    @usableFromInline
    enum InboundMessage {
        case channelRead(InboundIn, EventLoopPromise<Void>?)
        case eof
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncChannelAdapterHandler {
    @usableFromInline
    enum StreamState {
        case bufferingWithoutPendingRead(CircularBuffer<InboundMessage>)
        case bufferingWithPendingRead(CircularBuffer<InboundMessage>, EventLoopPromise<Void>)
        case waitingForBuffer(CircularBuffer<InboundMessage>, CheckedContinuation<InboundMessage, Never>)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct NIOInboundChannelStream<InboundIn>: @unchecked Sendable {
    @usableFromInline
    typealias Producer = NIOThrowingAsyncSequenceProducer<InboundIn, Error, NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark, NIOAsyncChannelAdapterHandler<InboundIn>>

    @usableFromInline let _producer: Producer

    @inlinable
    public init(_ channel: Channel, lowWatermark: Int, highWatermark: Int) async throws {
        let handler = NIOAsyncChannelAdapterHandler<InboundIn>(loop: channel.eventLoop)
        let sequence = Producer.makeSequence(backPressureStrategy: .init(lowWatermark: lowWatermark, highWatermark: highWatermark), delegate: handler)
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
