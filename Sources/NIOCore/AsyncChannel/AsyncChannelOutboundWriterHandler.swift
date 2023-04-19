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

import DequeModule

/// A ``ChannelHandler`` that is used to write the outbound portion of a NIO
/// ``Channel`` from Swift Concurrency with back-pressure support.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@usableFromInline
internal final class NIOAsyncChannelOutboundWriterHandler<OutboundOut: Sendable>: ChannelDuplexHandler {
    @usableFromInline typealias InboundIn = Any
    @usableFromInline typealias InboundOut = Any
    @usableFromInline typealias OutboundIn = Any
    @usableFromInline typealias OutboundOut = OutboundOut

    @usableFromInline
    typealias Writer = NIOAsyncWriter<
        OutboundOut,
        NIOAsyncChannelOutboundWriterHandler<OutboundOut>.Delegate
    >

    @usableFromInline
    typealias Sink = Writer.Sink

    /// The sink of the ``NIOAsyncWriter``.
    @usableFromInline
    var sink: Sink?

    /// The channel handler context.
    @usableFromInline
    var context: ChannelHandlerContext?

    /// The event loop.
    @usableFromInline
    let eventLoop: EventLoop

    /// The shared `CloseRatchet` between this handler and the inbound stream handler.
    @usableFromInline
    let closeRatchet: CloseRatchet

    @inlinable
    init(
        eventLoop: EventLoop,
        closeRatchet: CloseRatchet
    ) {
        self.eventLoop = eventLoop
        self.closeRatchet = closeRatchet
    }

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
    func _didTerminate(error: Error?) {
        self.eventLoop.preconditionInEventLoop()

        switch self.closeRatchet.closeWrite() {
        case .nothing:
            break

        case .closeOutput:
            self.context?.close(mode: .output, promise: nil)

        case .close:
            self.context?.close(promise: nil)
        }

        self.sink = nil
    }

    @inlinable
    func _doOutboundWrites(context: ChannelHandlerContext, writes: Deque<OutboundOut>) {
        for write in writes {
            context.write(self.wrapOutboundOut(write), promise: nil)
        }

        context.flush()
    }

    @inlinable
    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    @inlinable
    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.sink = nil
    }

    @inlinable
    func channelInactive(context: ChannelHandlerContext) {
        self.sink?.finish()
        context.fireChannelInactive()
    }

    @inlinable
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        self.sink?.setWritability(to: context.channel.isWritable)
        context.fireChannelWritabilityChanged()
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOAsyncChannelOutboundWriterHandler {
    @usableFromInline
    struct Delegate: @unchecked Sendable, NIOAsyncWriterSinkDelegate {
        @usableFromInline
        typealias Element = OutboundOut

        @usableFromInline
        let eventLoop: EventLoop

        @usableFromInline
        let handler: NIOAsyncChannelOutboundWriterHandler<OutboundOut>

        @inlinable
        init(handler: NIOAsyncChannelOutboundWriterHandler<OutboundOut>) {
            self.eventLoop = handler.eventLoop
            self.handler = handler
        }

        @inlinable
        func didYield(contentsOf sequence: Deque<OutboundOut>) {
            // This always called from an async context, so we must loop-hop.
            self.eventLoop.execute {
                self.handler._didYield(sequence: sequence)
            }
        }

        @inlinable
        func didTerminate(error: Error?) {
            // This always called from an async context, so we must loop-hop.
            self.eventLoop.execute {
                self.handler._didTerminate(error: error)
            }
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@available(*, unavailable)
extension NIOAsyncChannelOutboundWriterHandler: Sendable {}
