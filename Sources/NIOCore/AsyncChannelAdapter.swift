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
enum PendingReadState {
    // Not .stopProducing
    case canRead

    // .stopProducing but not read()
    case readBlocked

    // .stopProducing and read()
    case pendingRead
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
        self.channelReadComplete(context: context)
        self.source?.finish()
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
        if self.buffer.isEmpty {
            context.fireChannelReadComplete()
            return
        }

        guard let source = self.source else {
            self.buffer.removeAll()
            context.fireChannelReadComplete()
            return
        }

        let result = source.yield(contentsOf: self.buffer)
        switch result {
        case .produceMore, .dropped:
            ()
        case .stopProducing:
            if self.pendingReadState != .pendingRead {
                self.pendingReadState = .readBlocked
            }
        }
        self.buffer.removeAll(keepingCapacity: true)
        context.fireChannelReadComplete()
    }

    @inlinable
    public func channelInactive(context: ChannelHandlerContext) {
        // TODO: make this less nasty
        self.channelReadComplete(context: context)
        self.source?.finish()
        context.fireChannelInactive()
    }

    @inlinable
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        // TODO: make this less nasty
        self.channelReadComplete(context: context)
        self.source?.finish(error)
        context.fireErrorCaught(error)
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
            self.source?.finish()
        default:
            ()
        }

        context.fireUserInboundEventTriggered(event)
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
public final class NIOAsyncChannelWriterHandler<OutboundOut>: @unchecked Sendable, ChannelDuplexHandler {
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

    @usableFromInline
    var bufferedWrites: Deque<OutboundOut>

    @usableFromInline
    var isWriting: Bool

    @inlinable
    init(loop: EventLoop) {
        self.loop = loop
        self.bufferedWrites = Deque()
        self.isWriting = false
    }

    @inlinable
    static func makeHandler(loop: EventLoop) -> (NIOAsyncChannelWriterHandler<OutboundOut>, Writer) {
        let handler = NIOAsyncChannelWriterHandler<OutboundOut>(loop: loop)
        let writerComponents = Writer.makeWriter(elementType: OutboundOut.self, isWritable: true, delegate: handler)
        handler.sink = writerComponents.sink
        return (handler, writerComponents.writer)
    }

    @inlinable
    func doOutboundWrites() {
        guard !self.isWriting else {
            // We've already got a write happening, no need to do anything more here.
            return
        }

        self.isWriting = true

        while let nextWrite = self.bufferedWrites.popFirst() {
            self.context?.write(self.wrapOutboundOut(nextWrite), promise: nil)
        }

        self.isWriting = false
        self.context?.flush()
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.sink = nil
        self.bufferedWrites.removeAll()
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
        self.loop.execute {
            if self.bufferedWrites.isEmpty {
                self.bufferedWrites = sequence
            } else {
                self.bufferedWrites.append(contentsOf: sequence)
            }

            self.doOutboundWrites()
        }
    }

    @inlinable
    public func didTerminate(error: Error?) {
        // TODO: how do we spot full closure here?
        // This always called from an async context, so we must loop-hop.
        self.loop.execute {
            self.context?.close(mode: .output, promise: nil)
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
        self._producer = try await channel.eventLoop.submit {
            let handler = NIOAsyncChannelAdapterHandler<InboundIn>(loop: channel.eventLoop)
            let strategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark

            if let userProvided = backpressureStrategy {
                strategy = userProvided
            } else if let syncOptions = channel.syncOptions {
                let maxReads = Int(Swift.min(UInt(Int.max), try syncOptions.getOption(ChannelOptions.maxMessagesPerRead)))
                strategy = .init(lowWatermark: maxReads / 4, highWatermark: maxReads)
            } else {
                // Fallback strategy. These numbers are really just arbitrary. The odds that we can't get
                // a syncOptions is very low.
                strategy = .init(lowWatermark: 25, highWatermark: 100)
            }

            let sequence = Producer.makeSequence(backPressureStrategy: strategy, delegate: handler)
            handler.source = sequence.source
            try channel.pipeline.syncOperations.addHandler(handler)
            return sequence.sequence
        }.get()
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
