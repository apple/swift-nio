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

/// A ``ChannelHandler`` that is used to transform the inbound portion of a NIO
/// ``Channel`` into an asynchronous sequence that supports back-pressure.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@usableFromInline
internal final class NIOAsyncChannelInboundStreamChannelHandler<InboundIn: Sendable, ProducerElement: Sendable>: ChannelDuplexHandler {
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
        ProducerElement,
        Error,
        NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark,
        NIOAsyncChannelInboundStreamChannelHandlerProducerDelegate
    >.Source

    /// The source of the asynchronous sequence.
    @usableFromInline
    var source: Source?

    /// The channel handler's context.
    @usableFromInline
    var context: ChannelHandlerContext?

    /// An array of reads which will be yielded to the source with the next channel read complete.
    @usableFromInline
    var buffer: [ProducerElement] = []

    /// The current producing state.
    @usableFromInline
    var producingState: _ProducingState = .keepProducing

    /// The event loop.
    @usableFromInline
    let eventLoop: EventLoop

    /// A type indicating what kind of transformation to apply to reads.
    @usableFromInline
    enum Transformation {
        /// A synchronous transformation is applied to incoming reads. This is used when sync wrapping a channel.
        case syncWrapping((InboundIn) -> ProducerElement)
        case transformation(
            channelReadTransformation: @Sendable (InboundIn) -> EventLoopFuture<ProducerElement>
        )
    }

    /// The transformation applied to incoming reads.
    @usableFromInline
    let transformation: Transformation

    @inlinable
    init(
        eventLoop: EventLoop,
        transformation: Transformation
    ) {
        self.eventLoop = eventLoop
        self.transformation = transformation
    }

    /// Creates a new ``NIOAsyncChannelInboundStreamChannelHandler`` which is used when the pipeline got synchronously wrapped.
    @inlinable
    static func makeHandler(
        eventLoop: EventLoop
    ) -> NIOAsyncChannelInboundStreamChannelHandler where InboundIn == ProducerElement {
        return .init(
            eventLoop: eventLoop,
            transformation: .syncWrapping { $0 }
        )
    }

    /// Creates a new ``NIOAsyncChannelInboundStreamChannelHandler`` which has hooks for transformations.
    @inlinable
    static func makeHandlerWithTransformations(
        eventLoop: EventLoop,
        channelReadTransformation: @Sendable @escaping (InboundIn) -> EventLoopFuture<ProducerElement>
    ) -> NIOAsyncChannelInboundStreamChannelHandler where InboundIn == Channel {
        return .init(
            eventLoop: eventLoop,
            transformation: .transformation(
                channelReadTransformation: channelReadTransformation
            )
        )
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
        let unwrapped = self.unwrapInboundIn(data)

        switch self.transformation {
        case .syncWrapping(let transformation):
            self.buffer.append(transformation(unwrapped))
            // We forward on reads here to enable better channel composition.
            context.fireChannelRead(data)

        case .transformation(let channelReadTransformation):
            // The unsafe transfers here are required because we need to use self in whenComplete
            // We are making sure to be on our event loop so we can safely use self in whenComplete
            channelReadTransformation(unwrapped)
                .hop(to: context.eventLoop)
                .assumeIsolated()
                .whenComplete { result in
                    switch result {
                    case .success:
                        // We have to fire through the original data now. Since our channelReadTransformation
                        // is the channel initializer. Once that's done we need to fire the channel as a read
                        // so that it hits channelRead0 in the base socket channel.
                        context.fireChannelRead(data)
                    case .failure:
                        break
                    }
                    self._transformationCompleted(context: context, result: result)
                }
        }
    }

    @inlinable
    func _transformationCompleted(
        context: ChannelHandlerContext,
        result: Result<ProducerElement, Error>
    ) {
        context.eventLoop.preconditionInEventLoop()

        switch result {
        case .success(let transformed):
            self.buffer.append(transformed)
            // We are delivering out of band here since the future can complete at any point
            self._deliverReads(context: context)

        case .failure:
            // Transformation failed. Nothing to really do here this must be handled in the transformation
            // futures themselves.
            break
        }
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
@usableFromInline
struct NIOAsyncChannelInboundStreamChannelHandlerProducerDelegate: @unchecked Sendable, NIOAsyncSequenceProducerDelegate {
    @usableFromInline
    let eventLoop: EventLoop

    @usableFromInline
    let _didTerminate: () -> Void

    @usableFromInline
    let _produceMore: () -> Void

    @inlinable
    init<InboundIn, ProducerElement>(handler: NIOAsyncChannelInboundStreamChannelHandler<InboundIn, ProducerElement>) {
        self.eventLoop = handler.eventLoop
        self._didTerminate = handler._didTerminate
        self._produceMore = handler._produceMore
    }

    @inlinable
    func didTerminate() {
        if self.eventLoop.inEventLoop {
            self._didTerminate()
        } else {
            self.eventLoop.execute {
                self._didTerminate()
            }
        }
    }

    @inlinable
    func produceMore() {
        if self.eventLoop.inEventLoop {
            self._produceMore()
        } else {
            self.eventLoop.execute {
                self._produceMore()
            }
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@available(*, unavailable)
extension NIOAsyncChannelInboundStreamChannelHandler: Sendable {}
