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


/// A `ChannelHandler` that implements a backoff for a `ServerChannel` when accept produces an `IOError`.
/// These errors are often recoverable by reducing the rate at which we call accept.
public final class AcceptBackoffHandler: ChannelDuplexHandler {
    public typealias InboundIn = Channel
    public typealias OutboundIn = Channel

    private var nextReadDeadlineNS: NIODeadline?
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
            let now = NIODeadline.now()
            if now >= deadline {
                // The backoff already expired, just do a read.
                doRead(ctx)
            } else {
                // Schedule the read to be executed after the backoff time elapsed.
                scheduleRead(at: deadline, ctx: ctx)
            }
        } else {
            ctx.read()
        }
    }

    public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        if let ioError = error as? IOError {
            if let amount = backoffProvider(ioError) {
                self.nextReadDeadlineNS = .now() + amount
                if let scheduled = self.scheduledRead {
                    scheduled.cancel()
                    scheduleRead(at: self.nextReadDeadlineNS!, ctx: ctx)
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

    private func scheduleRead(at: NIODeadline, ctx: ChannelHandlerContext) {
        self.scheduledRead = ctx.eventLoop.scheduleTask(at: at) {
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
    private var lastReadTime: NIODeadline = .exactly(0)
    private var lastWriteCompleteTime: NIODeadline = .exactly(0)
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
        ctx.fireChannelActive()
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        if readTimeout != nil || allTimeout != nil {
            reading = true
        }
        ctx.fireChannelRead(data)
    }

    public func channelReadComplete(ctx: ChannelHandlerContext) {
        if (readTimeout != nil  || allTimeout != nil) && reading {
            lastReadTime = .now()
            reading = false
        }
        ctx.fireChannelReadComplete()
    }

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if writeTimeout == nil && allTimeout == nil {
            ctx.write(data, promise: promise)
            return
        }

        let writePromise = promise ?? ctx.eventLoop.makePromise()
        writePromise.futureResult.whenComplete { (_: Result<Void, Error>) in
            self.lastWriteCompleteTime = .now()
        }
        ctx.write(data, promise: writePromise)
    }

    private func shouldReschedule(_ ctx: ChannelHandlerContext) -> Bool {
        if ctx.channel.isActive {
            return true
        }
        return false
    }

    private func makeReadTimeoutTask(_ ctx: ChannelHandlerContext, _ timeout: TimeAmount) -> (() -> Void) {
        return {
            guard self.shouldReschedule(ctx) else  {
                return
            }

            if self.reading {
                self.scheduledReaderTask = ctx.eventLoop.scheduleTask(in: timeout, self.makeReadTimeoutTask(ctx, timeout))
                return
            }

            let diff = .now() - self.lastReadTime
            if diff >= timeout {
                // Reader is idle - set a new timeout and trigger an event through the pipeline
                self.scheduledReaderTask = ctx.eventLoop.scheduleTask(in: timeout, self.makeReadTimeoutTask(ctx, timeout))

                ctx.fireUserInboundEventTriggered(IdleStateEvent.read)
            } else {
                // Read occurred before the timeout - set a new timeout with shorter delay.
                self.scheduledReaderTask = ctx.eventLoop.scheduleTask(at: self.lastReadTime + timeout, self.makeReadTimeoutTask(ctx, timeout))
            }
        }
    }

    private func makeWriteTimeoutTask(_ ctx: ChannelHandlerContext, _ timeout: TimeAmount) -> (() -> Void) {
        return {
            guard self.shouldReschedule(ctx) else  {
                return
            }

            let lastWriteTime = self.lastWriteCompleteTime
            let diff = .now() - lastWriteTime

            if diff >= timeout {
                // Writer is idle - set a new timeout and notify the callback.
                self.scheduledWriterTask = ctx.eventLoop.scheduleTask(in: timeout, self.makeWriteTimeoutTask(ctx, timeout))

                ctx.fireUserInboundEventTriggered(IdleStateEvent.write)
            } else {
                // Write occurred before the timeout - set a new timeout with shorter delay.
                self.scheduledWriterTask = ctx.eventLoop.scheduleTask(at: self.lastWriteCompleteTime + timeout, self.makeWriteTimeoutTask(ctx, timeout))
            }
        }
    }

    private func makeAllTimeoutTask(_ ctx: ChannelHandlerContext, _ timeout: TimeAmount) -> (() -> Void) {
        return {
            guard self.shouldReschedule(ctx) else  {
                return
            }

            if self.reading {
                self.scheduledReaderTask = ctx.eventLoop.scheduleTask(in: timeout, self.makeAllTimeoutTask(ctx, timeout))
                return
            }
            let lastRead = self.lastReadTime
            let lastWrite = self.lastWriteCompleteTime
            let latestLast = max(lastRead, lastWrite)

            let diff = .now() - latestLast
            if diff >= timeout {
                // Reader is idle - set a new timeout and trigger an event through the pipeline
                self.scheduledReaderTask = ctx.eventLoop.scheduleTask(in: timeout, self.makeAllTimeoutTask(ctx, timeout))

                ctx.fireUserInboundEventTriggered(IdleStateEvent.all)
            } else {
                // Read occurred before the timeout - set a new timeout with shorter delay.
                self.scheduledReaderTask = ctx.eventLoop.scheduleTask(at: latestLast + timeout, self.makeAllTimeoutTask(ctx, timeout))
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
        let now = NIODeadline.now()
        lastReadTime = now
        lastWriteCompleteTime = now
        scheduledReaderTask = schedule(ctx, readTimeout, makeReadTimeoutTask)
        scheduledWriterTask = schedule(ctx, writeTimeout, makeWriteTimeoutTask)
        scheduledAllTask = schedule(ctx, allTimeout, makeAllTimeoutTask)
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
