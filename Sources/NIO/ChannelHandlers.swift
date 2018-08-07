//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
//  Contains ChannelHandler implementations which are generic and can be re-used easily.
//
//

import struct Dispatch.DispatchTime


/// A `ChannelHandler` that implements a backoff for a `ServerChannel` when accept produces an `IOError`.
/// These errors are often recoverable by reducing the rate at which we call accept.
public final class AcceptBackoffHandler: ChannelDuplexHandler {
    public typealias InboundIn = Channel
    public typealias OutboundIn = Channel

    private var nextReadDeadlineNS: TimeAmount.Value?
    private let backoffProvider: (IOError) -> TimeAmount?
    private var scheduledRead: Scheduled<Void>?

    /// Default implementation used as `backoffProvider` which delays accept by 1 second.
    public static func defaultBackoffProvider(error: IOError) -> TimeAmount? {
        return .seconds(1)
    }

    /// Create a new instance
    ///
    /// - parameters:
    ///     - backoffProvider: returns a `TimeAmount` which will be the amount of time to wait before attempting another `read`.
    public init(backoffProvider: @escaping (IOError) -> TimeAmount? = AcceptBackoffHandler.defaultBackoffProvider) {
        self.backoffProvider = backoffProvider
    }

    public func read(ctx: ChannelHandlerContext) {
        // If we already have a read scheduled there is no need to schedule another one.
        guard scheduledRead == nil else { return }

        if let deadline = self.nextReadDeadlineNS {
            let now = TimeAmount.Value(DispatchTime.now().uptimeNanoseconds)
            if now >= deadline {
                // The backoff already expired, just do a read.
                doRead(ctx)
            } else {
                // Schedule the read to be executed after the backoff time elapsed.
                scheduleRead(in: .nanoseconds(deadline - now), ctx: ctx)
            }
        } else {
            ctx.read()
        }
    }

    public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        if let ioError = error as? IOError {
            if let amount = backoffProvider(ioError) {
                self.nextReadDeadlineNS = TimeAmount.Value(DispatchTime.now().uptimeNanoseconds) + amount.nanoseconds
                if let scheduled = self.scheduledRead {
                    scheduled.cancel()
                    scheduleRead(in: amount, ctx: ctx)
                }
            }
        }
        ctx.fireErrorCaught(error)
    }

    public func channelInactive(ctx: ChannelHandlerContext) {
        if let scheduled = self.scheduledRead {
            scheduled.cancel()
            self.scheduledRead = nil
        }
        self.nextReadDeadlineNS = nil
        ctx.fireChannelInactive()
    }

    public func handlerRemoved(ctx: ChannelHandlerContext) {
        if let scheduled = self.scheduledRead {
            // Cancel the previous scheduled read and trigger a read directly. This is needed as otherwise we may never read again.
            scheduled.cancel()
            self.scheduledRead = nil
            ctx.read()
        }
        self.nextReadDeadlineNS = nil
    }

    private func scheduleRead(in: TimeAmount, ctx: ChannelHandlerContext) {
        self.scheduledRead = ctx.eventLoop.scheduleTask(in: `in`) {
            self.doRead(ctx)
        }
    }

    private func doRead(_ ctx: ChannelHandlerContext) {
        /// Reset the backoff time and read.
        self.nextReadDeadlineNS = nil
        self.scheduledRead = nil
        ctx.read()
    }
}

/**
 ChannelHandler implementation which enforces back-pressure by stopping to read from the remote peer when it cannot write back fast enough.
 It will start reading again once pending data was written.
*/
public class BackPressureHandler: ChannelDuplexHandler {
    public typealias OutboundIn = NIOAny
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private var pendingRead = false
    private var writable: Bool = true

    public init() { }

    public func read(ctx: ChannelHandlerContext) {
        if writable {
            ctx.read()
        } else {
            pendingRead = true
        }
    }

    public func channelWritabilityChanged(ctx: ChannelHandlerContext) {
        self.writable = ctx.channel.isWritable
        if writable {
            mayRead(ctx: ctx)
        } else {
            ctx.flush()
        }

        // Propagate the event as the user may still want to do something based on it.
        ctx.fireChannelWritabilityChanged()
    }

    public func handlerRemoved(ctx: ChannelHandlerContext) {
        mayRead(ctx: ctx)
    }

    private func mayRead(ctx: ChannelHandlerContext) {
        if pendingRead {
            pendingRead = false
            ctx.read()
        }
    }
}

/// Triggers an IdleStateEvent when a Channel has not performed read, write, or both operation for a while.
public class IdleStateHandler: ChannelDuplexHandler {
    public typealias InboundIn = NIOAny
    public typealias InboundOut = NIOAny
    public typealias OutboundIn = NIOAny
    public typealias OutboundOut = NIOAny

    ///A user event triggered by IdleStateHandler when a Channel is idle.
    public enum IdleStateEvent {
        /// Will be triggered when no write was performed for the specified amount of time
        case write
        /// Will be triggered when no read was performed for the specified amount of time
        case read
        /// Will be triggered when neither read nor write was performed for the specified amount of time
        case all
    }

    public let readTimeout: TimeAmount?
    public let writeTimeout: TimeAmount?
    public let allTimeout: TimeAmount?

    private var reading = false
    private var lastReadTime: DispatchTime = DispatchTime(uptimeNanoseconds: 0)
    private var lastWriteCompleteTime: DispatchTime = DispatchTime(uptimeNanoseconds: 0)
    private var scheduledReaderTask: Scheduled<Void>?
    private var scheduledWriterTask: Scheduled<Void>?
    private var scheduledAllTask: Scheduled<Void>?

    public init(readTimeout: TimeAmount? = nil, writeTimeout: TimeAmount? = nil, allTimeout: TimeAmount? = nil) {
        self.readTimeout = readTimeout
        self.writeTimeout = writeTimeout
        self.allTimeout = allTimeout
    }

    public func handlerAdded(ctx: ChannelHandlerContext) {
        if ctx.channel.isActive {
            initIdleTasks(ctx)
        }
    }

    public func handlerRemoved(ctx: ChannelHandlerContext) {
        cancelIdleTasks(ctx)
    }

    public func channelActive(ctx: ChannelHandlerContext) {
        initIdleTasks(ctx)
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        if readTimeout != nil || allTimeout != nil {
            reading = true
        }
        ctx.fireChannelRead(data)
    }

    public func channelReadComplete(ctx: ChannelHandlerContext) {
        if (readTimeout != nil  || allTimeout != nil) && reading {
            lastReadTime = DispatchTime.now()
            reading = false
        }
        ctx.fireChannelReadComplete()
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if writeTimeout == nil && allTimeout == nil {
            ctx.write(data, promise: promise)
            return
        }

        let writePromise = promise ?? ctx.eventLoop.newPromise()
        writePromise.futureResult.whenComplete {
            self.lastWriteCompleteTime = DispatchTime.now()
        }
        ctx.write(data, promise: writePromise)
    }

    private func shouldReschedule(_ ctx: ChannelHandlerContext) -> Bool {
        if ctx.channel.isActive {
            return true
        }
        return false
    }

    private func newReadTimeoutTask(_ ctx: ChannelHandlerContext, _ timeout: TimeAmount) -> (() -> Void) {
        return {
            guard self.shouldReschedule(ctx) else  {
                return
            }

            if self.reading {
                self.scheduledReaderTask = ctx.eventLoop.scheduleTask(in: timeout, self.newReadTimeoutTask(ctx, timeout))
                return
            }

            let diff = TimeAmount.Value(DispatchTime.now().uptimeNanoseconds) - TimeAmount.Value(self.lastReadTime.uptimeNanoseconds)
            if diff >= timeout.nanoseconds {
                // Reader is idle - set a new timeout and trigger an event through the pipeline
                self.scheduledReaderTask = ctx.eventLoop.scheduleTask(in: timeout, self.newReadTimeoutTask(ctx, timeout))

                ctx.fireUserInboundEventTriggered(IdleStateEvent.read)
            } else {
                // Read occurred before the timeout - set a new timeout with shorter delay.
                self.scheduledReaderTask = ctx.eventLoop.scheduleTask(in: .nanoseconds(timeout.nanoseconds - diff), self.newReadTimeoutTask(ctx, timeout))
            }
        }
    }

    private func newWriteTimeoutTask(_ ctx: ChannelHandlerContext, _ timeout: TimeAmount) -> (() -> Void) {
        return {
            guard self.shouldReschedule(ctx) else  {
                return
            }

            let lastWriteTime = self.lastWriteCompleteTime
            let diff = DispatchTime.now().uptimeNanoseconds - lastWriteTime.uptimeNanoseconds

            if diff >= timeout.nanoseconds {
                // Writer is idle - set a new timeout and notify the callback.
                self.scheduledWriterTask = ctx.eventLoop.scheduleTask(in: timeout, self.newWriteTimeoutTask(ctx, timeout))

                ctx.fireUserInboundEventTriggered(IdleStateEvent.write)
            } else {
                // Write occurred before the timeout - set a new timeout with shorter delay.
                self.scheduledWriterTask = ctx.eventLoop.scheduleTask(in: .nanoseconds(TimeAmount.Value(timeout.nanoseconds) - TimeAmount.Value(diff)), self.newWriteTimeoutTask(ctx, timeout))
            }
        }
    }

    private func newAllTimeoutTask(_ ctx: ChannelHandlerContext, _ timeout: TimeAmount) -> (() -> Void) {
        return {
            guard self.shouldReschedule(ctx) else  {
                return
            }

            if self.reading {
                self.scheduledReaderTask = ctx.eventLoop.scheduleTask(in: timeout, self.newAllTimeoutTask(ctx, timeout))
                return
            }
            let lastRead = self.lastReadTime
            let lastWrite = self.lastWriteCompleteTime

            let diff = TimeAmount.Value(DispatchTime.now().uptimeNanoseconds) - TimeAmount.Value((lastRead > lastWrite ? lastRead : lastWrite).uptimeNanoseconds)
            if diff >= timeout.nanoseconds {
                // Reader is idle - set a new timeout and trigger an event through the pipeline
                self.scheduledReaderTask = ctx.eventLoop.scheduleTask(in: timeout, self.newAllTimeoutTask(ctx, timeout))

                ctx.fireUserInboundEventTriggered(IdleStateEvent.all)
            } else {
                // Read occurred before the timeout - set a new timeout with shorter delay.
                self.scheduledReaderTask = ctx.eventLoop.scheduleTask(in: .nanoseconds(TimeAmount.Value(timeout.nanoseconds) - diff), self.newAllTimeoutTask(ctx, timeout))
            }
        }
    }

    private func schedule(_ ctx: ChannelHandlerContext, _ amount: TimeAmount?, _ body: @escaping (ChannelHandlerContext, TimeAmount) -> (() -> Void) ) -> Scheduled<Void>? {
        if let timeout = amount {
            return ctx.eventLoop.scheduleTask(in: timeout, body(ctx, timeout))
        }
        return nil
    }

    private func initIdleTasks(_ ctx: ChannelHandlerContext) {
        let now = DispatchTime.now()
        lastReadTime = now
        lastWriteCompleteTime = now
        scheduledReaderTask = schedule(ctx, readTimeout, newReadTimeoutTask)
        scheduledWriterTask = schedule(ctx, writeTimeout, newWriteTimeoutTask)
        scheduledAllTask = schedule(ctx, allTimeout, newAllTimeoutTask)
    }

    private func cancelIdleTasks(_ ctx: ChannelHandlerContext) {
        scheduledReaderTask?.cancel()
        scheduledWriterTask?.cancel()
        scheduledAllTask?.cancel()
        scheduledReaderTask = nil
        scheduledWriterTask = nil
        scheduledAllTask = nil
    }
}
