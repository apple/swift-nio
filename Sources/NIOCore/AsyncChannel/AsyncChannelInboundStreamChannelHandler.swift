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
#if swift(>=5.6)
/// A ``ChannelHandler`` that is used to transform the inbound portion of a NIO
/// ``Channel`` into an asynchronous sequence that supports back-pressure.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@usableFromInline
internal final class NIOAsyncChannelInboundStreamChannelHandler<InboundIn: Sendable>: ChannelDuplexHandler {
    @usableFromInline
    enum _ProducingState {
        // Not .stopProducing
        case keepProducing

        // .stopProducing but not read()
        case producingPaused

        // .stopProducing and read()
        case producingPausedWithOutstandingRead
    }

    @usableFromInline
    typealias OutboundIn = Any

    @usableFromInline
    typealias OutboundOut = Any

    @usableFromInline
    typealias Source = NIOThrowingAsyncSequenceProducer<
        InboundIn,
        Error,
        NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark,
        NIOAsyncChannelInboundStreamChannelHandler<InboundIn>.Delegate
    >.Source

    /// The source of the asynchronous sequence.
    @usableFromInline
    var source: Source?

    /// The channel handler's context.
    @usableFromInline
    var context: ChannelHandlerContext?

    /// An array of reads which will be yielded to the source with the next channel read complete.
    @usableFromInline
    var buffer: [InboundIn] = []

    /// The current producing state.
    @usableFromInline
    var producingState: _ProducingState = .keepProducing

    /// The event loop.
    @usableFromInline
    let eventLoop: EventLoop

    /// The shared `CloseRatchet` between this handler and the writer handler.
    @usableFromInline
    let closeRatchet: CloseRatchet

    @inlinable
    init(eventLoop: EventLoop, closeRatchet: CloseRatchet) {
        self.eventLoop = eventLoop
        self.closeRatchet = closeRatchet
    }

    @inlinable
    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    @inlinable
    func handlerRemoved(context: ChannelHandlerContext) {
        self._finishSource(context: context)
        self.context = nil
    }

    @inlinable
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.buffer.append(self.unwrapInboundIn(data))

        // We forward on reads here to enable better channel composition.
        context.fireChannelRead(data)
    }

    @inlinable
    func channelReadComplete(context: ChannelHandlerContext) {
        self._deliverReads(context: context)
        context.fireChannelReadComplete()
    }

    @inlinable
    func channelInactive(context: ChannelHandlerContext) {
        self._finishSource(context: context)
        context.fireChannelInactive()
    }

    @inlinable
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self._finishSource(with: error, context: context)
        context.fireErrorCaught(error)
    }

    @inlinable
    func read(context: ChannelHandlerContext) {
        switch self.producingState {
        case .keepProducing:
            context.read()
        case .producingPaused:
            self.producingState = .producingPausedWithOutstandingRead
        case .producingPausedWithOutstandingRead:
            break
        }
    }

    @inlinable
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case ChannelEvent.inputClosed:
            self._finishSource(context: context)
        default:
            break
        }

        context.fireUserInboundEventTriggered(event)
    }

    @inlinable
    func _finishSource(with error: Error? = nil, context: ChannelHandlerContext) {
        guard let source = self.source else {
            return
        }

        // We need to deliver the reads first to buffer them in the source.
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
    func _deliverReads(context: ChannelHandlerContext) {
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
            break
        case .stopProducing:
            if self.producingState != .producingPausedWithOutstandingRead {
                self.producingState = .producingPaused
            }
        }
        self.buffer.removeAll(keepingCapacity: true)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncChannelInboundStreamChannelHandler {
    @inlinable
    func _didTerminate() {
        self.eventLoop.preconditionInEventLoop()
        self.source = nil

        // Wedges the read open forever, we'll never read again.
        self.producingState = .producingPausedWithOutstandingRead

        switch self.closeRatchet.closeRead() {
        case .nothing:
            break

        case .close:
            self.context?.close(promise: nil)
        }
    }

    @inlinable
    func _produceMore() {
        self.eventLoop.preconditionInEventLoop()

        switch self.producingState {
        case .producingPaused:
            self.producingState = .keepProducing

        case .producingPausedWithOutstandingRead:
            self.producingState = .keepProducing
            self.context?.read()

        case .keepProducing:
            break
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncChannelInboundStreamChannelHandler {
    @usableFromInline
    struct Delegate: @unchecked Sendable, NIOAsyncSequenceProducerDelegate {
        @usableFromInline
        let eventLoop: EventLoop

        @usableFromInline
        let handler: NIOAsyncChannelInboundStreamChannelHandler<InboundIn>

        @inlinable
        init(handler: NIOAsyncChannelInboundStreamChannelHandler<InboundIn>) {
            self.eventLoop = handler.eventLoop
            self.handler = handler
        }

        @inlinable
        func didTerminate() {
            self.eventLoop.execute {
                self.handler._didTerminate()
            }
        }

        @inlinable
        func produceMore() {
            self.eventLoop.execute {
                self.handler._produceMore()
            }
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@available(*, unavailable)
extension NIOAsyncChannelInboundStreamChannelHandler: Sendable {}
#endif
