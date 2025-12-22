//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DequeModule

/// A ``ChannelHandler`` that is used to transform the inbound portion of a NIO
/// ``Channel`` into an asynchronous sequence that supports back-pressure. It's also used
/// to write the outbound portion of a NIO ``Channel`` from Swift Concurrency with back-pressure
/// support.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@usableFromInline
internal final class NIOAsyncChannelHandler<InboundIn: Sendable, ProducerElement: Sendable, OutboundOut: Sendable> {
    @usableFromInline
    enum _ProducingState: Sendable {
        // Not .stopProducing
        case keepProducing

        // .stopProducing but not read()
        case producingPaused

        // .stopProducing and read()
        case producingPausedWithOutstandingRead
    }

    @usableFromInline
    typealias Source = NIOThrowingAsyncSequenceProducer<
        ProducerElement,
        Error,
        NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark,
        NIOAsyncChannelHandlerProducerDelegate
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

    @usableFromInline
    typealias Writer = NIOAsyncWriter<
        OutboundOut,
        NIOAsyncChannelHandlerWriterDelegate<OutboundOut>
    >

    @usableFromInline
    typealias Sink = Writer.Sink

    /// The sink of the ``NIOAsyncWriter``.
    @usableFromInline
    var sink: Sink?

    /// The writer of the ``NIOAsyncWriter``.
    ///
    /// The reference is retained until `channelActive` is fired. This avoids situations
    /// where `deinit` is called on the unfinished writer because the `Channel` was never returned
    /// to the caller (e.g. because a connect failed or or happy-eyeballs created multiple
    /// channels).
    ///
    /// Effectively `channelActive` is used at the point in time at which NIO cedes ownership of
    /// the writer to the caller.
    @usableFromInline
    var writer: Writer?

    @usableFromInline
    let isOutboundHalfClosureEnabled: Bool

    @inlinable
    init(
        eventLoop: EventLoop,
        transformation: Transformation,
        isOutboundHalfClosureEnabled: Bool
    ) {
        self.eventLoop = eventLoop
        self.transformation = transformation
        self.isOutboundHalfClosureEnabled = isOutboundHalfClosureEnabled
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncChannelHandler: ChannelInboundHandler {
    @usableFromInline
    typealias InboundIn = InboundIn

    @inlinable
    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    @inlinable
    func handlerRemoved(context: ChannelHandlerContext) {
        self._finishSource(context: context)
        self.sink?.finish(error: ChannelError._ioOnClosedChannel)
        self.context = nil
        self.writer = nil
    }

    @inlinable
    func channelActive(context: ChannelHandlerContext) {
        // Drop the writer ref, the caller is responsible for it now.
        self.writer = nil
        context.fireChannelActive()
    }

    @inlinable
    func channelInactive(context: ChannelHandlerContext) {
        self._finishSource(context: context)
        self.sink?.finish(error: ChannelError._ioOnClosedChannel)
        context.fireChannelInactive()
    }

    @inlinable
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case ChannelEvent.inputClosed:
            self._finishSource(context: context)
        case ChannelEvent.outputClosed:
            self.sink?.finish()
        default:
            break
        }

        context.fireUserInboundEventTriggered(event)
    }

    @inlinable
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        self.sink?.setWritability(to: context.channel.isWritable)
        context.fireChannelWritabilityChanged()
    }

    @inlinable
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self._finishSource(with: error, context: context)
        context.fireErrorCaught(error)
    }

    @inlinable
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let unwrapped = NIOAsyncChannelHandler.unwrapInboundIn(data)

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
                .assumeIsolatedUnsafeUnchecked()
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
    func channelReadComplete(context: ChannelHandlerContext) {
        self._deliverReads(context: context)
        context.fireChannelReadComplete()
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncChannelHandler: ChannelOutboundHandler {
    @usableFromInline
    typealias OutboundIn = Any

    @usableFromInline
    typealias OutboundOut = OutboundOut

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
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncChannelHandler {
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
extension NIOAsyncChannelHandler {
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
struct NIOAsyncChannelHandlerProducerDelegate: @unchecked Sendable, NIOAsyncSequenceProducerDelegate {
    @usableFromInline
    let eventLoop: EventLoop

    @usableFromInline
    let _didTerminate: () -> Void

    @usableFromInline
    let _produceMore: () -> Void

    @inlinable
    init<InboundIn, ProducerElement, OutboundOut>(
        handler: NIOAsyncChannelHandler<InboundIn, ProducerElement, OutboundOut>
    ) {
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
@usableFromInline
struct NIOAsyncChannelHandlerWriterDelegate<Element: Sendable>: NIOAsyncWriterSinkDelegate, @unchecked Sendable {
    @usableFromInline
    let eventLoop: EventLoop

    @usableFromInline
    let _didYieldContentsOf: (Deque<Element>) -> Void

    @usableFromInline
    let _didYield: (Element) -> Void

    @usableFromInline
    let _didTerminate: ((any Error)?) -> Void

    @inlinable
    init<InboundIn, ProducerElement>(handler: NIOAsyncChannelHandler<InboundIn, ProducerElement, Element>) {
        self.eventLoop = handler.eventLoop
        self._didYieldContentsOf = handler._didYield(sequence:)
        self._didYield = handler._didYield(element:)
        self._didTerminate = handler._didTerminate(error:)
    }

    @inlinable
    func didYield(contentsOf sequence: Deque<Element>) {
        if self.eventLoop.inEventLoop {
            self._didYieldContentsOf(sequence)
        } else {
            self.eventLoop.execute {
                self._didYieldContentsOf(sequence)
            }
        }
    }

    @inlinable
    func didYield(_ element: Element) {
        if self.eventLoop.inEventLoop {
            self._didYield(element)
        } else {
            self.eventLoop.execute {
                self._didYield(element)
            }
        }
    }

    @inlinable
    func didTerminate(error: (any Error)?) {
        if self.eventLoop.inEventLoop {
            self._didTerminate(error)
        } else {
            self.eventLoop.execute {
                self._didTerminate(error)
            }
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncChannelHandler {
    @inlinable
    func _didYield(sequence: Deque<OutboundOut>) {
        // This is always called from an async context, so we must loop-hop.
        // Because we always loop-hop, we're always at the top of a stack frame. As this
        // is the only source of writes for us, and as this channel handler doesn't implement
        // func write(), we cannot possibly re-entrantly write. That means we can skip many of the
        // awkward re-entrancy protections NIO usually requires, and can safely just do an iterative
        // write.
        self.eventLoop.preconditionInEventLoop()
        guard let context = self.context else {
            // Already removed from the channel by now, we can stop.
            return
        }

        self._doOutboundWrites(context: context, writes: sequence)
    }

    @inlinable
    func _didYield(element: OutboundOut) {
        // This is always called from an async context, so we must loop-hop.
        // Because we always loop-hop, we're always at the top of a stack frame. As this
        // is the only source of writes for us, and as this channel handler doesn't implement
        // func write(), we cannot possibly re-entrantly write. That means we can skip many of the
        // awkward re-entrancy protections NIO usually requires, and can safely just do an iterative
        // write.
        self.eventLoop.preconditionInEventLoop()
        guard let context = self.context else {
            // Already removed from the channel by now, we can stop.
            return
        }

        self._doOutboundWrite(context: context, write: element)
    }

    @inlinable
    func _didTerminate(error: Error?) {
        self.eventLoop.preconditionInEventLoop()

        if self.isOutboundHalfClosureEnabled {
            self.context?.close(mode: .output, promise: nil)
        }

        self.sink = nil
    }

    @inlinable
    func _doOutboundWrites(context: ChannelHandlerContext, writes: Deque<OutboundOut>) {
        for write in writes {
            context.write(NIOAsyncChannelHandler.wrapOutboundOut(write), promise: nil)
        }

        context.flush()
    }

    @inlinable
    func _doOutboundWrite(context: ChannelHandlerContext, write: OutboundOut) {
        context.write(NIOAsyncChannelHandler.wrapOutboundOut(write), promise: nil)
        context.flush()
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@available(*, unavailable)
extension NIOAsyncChannelHandler: Sendable {}

@available(*, unavailable)
extension NIOAsyncChannelHandler.Transformation: Sendable {}
