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
public final class AcceptBackoffHandler: ChannelDuplexHandler, RemovableChannelHandler {
    public typealias InboundIn = Channel
    public typealias OutboundIn = Channel

    private var nextReadDeadlineNS: Optional<NIODeadline>
    private let backoffProvider: (IOError) -> TimeAmount?
    private var scheduledRead: Optional<Scheduled<Void>>

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
        self.nextReadDeadlineNS = nil
        self.scheduledRead = nil
    }

    public func read(context: ChannelHandlerContext) {
        // If we already have a read scheduled there is no need to schedule another one.
        guard scheduledRead == nil else { return }

        if let deadline = self.nextReadDeadlineNS {
            let now = NIODeadline.now()
            if now >= deadline {
                // The backoff already expired, just do a read.
                doRead(context)
            } else {
                // Schedule the read to be executed after the backoff time elapsed.
                scheduleRead(at: deadline, context: context)
            }
        } else {
            context.read()
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let ioError = error as? IOError {
            if let amount = backoffProvider(ioError) {
                self.nextReadDeadlineNS = .now() + amount
                if let scheduled = self.scheduledRead {
                    scheduled.cancel()
                    scheduleRead(at: self.nextReadDeadlineNS!, context: context)
                }
            }
        }
        context.fireErrorCaught(error)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        if let scheduled = self.scheduledRead {
            scheduled.cancel()
            self.scheduledRead = nil
        }
        self.nextReadDeadlineNS = nil
        context.fireChannelInactive()
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        if let scheduled = self.scheduledRead {
            // Cancel the previous scheduled read and trigger a read directly. This is needed as otherwise we may never read again.
            scheduled.cancel()
            self.scheduledRead = nil
            context.read()
        }
        self.nextReadDeadlineNS = nil
    }

    private func scheduleRead(at: NIODeadline, context: ChannelHandlerContext) {
        self.scheduledRead = context.eventLoop.scheduleTask(deadline: at) {
            self.doRead(context)
        }
    }

    private func doRead(_ context: ChannelHandlerContext) {
        // Reset the backoff time and read.
        self.nextReadDeadlineNS = nil
        self.scheduledRead = nil
        context.read()
    }
}

/**
 ChannelHandler implementation which enforces back-pressure by stopping to read from the remote peer when it cannot write back fast enough.
 It will start reading again once pending data was written.
*/
public final class BackPressureHandler: ChannelDuplexHandler, RemovableChannelHandler {
    public typealias OutboundIn = NIOAny
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private var pendingRead = false
    private var writable: Bool = true

    public init() { }

    public func read(context: ChannelHandlerContext) {
        if writable {
            context.read()
        } else {
            pendingRead = true
        }
    }

    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        self.writable = context.channel.isWritable
        if writable {
            mayRead(context: context)
        } else {
            context.flush()
        }

        // Propagate the event as the user may still want to do something based on it.
        context.fireChannelWritabilityChanged()
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        mayRead(context: context)
    }

    private func mayRead(context: ChannelHandlerContext) {
        if pendingRead {
            pendingRead = false
            context.read()
        }
    }
}

/// Triggers an IdleStateEvent when a Channel has not performed read, write, or both operation for a while.
public final class IdleStateHandler: ChannelDuplexHandler, RemovableChannelHandler {
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
    private var lastReadTime: NIODeadline = .distantPast
    private var lastWriteCompleteTime: NIODeadline = .distantPast
    private var scheduledReaderTask: Optional<Scheduled<Void>>
    private var scheduledWriterTask: Optional<Scheduled<Void>>
    private var scheduledAllTask: Optional<Scheduled<Void>>

    public init(readTimeout: TimeAmount? = nil, writeTimeout: TimeAmount? = nil, allTimeout: TimeAmount? = nil) {
        self.readTimeout = readTimeout
        self.writeTimeout = writeTimeout
        self.allTimeout = allTimeout
        self.scheduledAllTask = nil
        self.scheduledReaderTask = nil
        self.scheduledWriterTask = nil
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            initIdleTasks(context)
        }
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        cancelIdleTasks(context)
    }

    public func channelActive(context: ChannelHandlerContext) {
        initIdleTasks(context)
        context.fireChannelActive()
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if readTimeout != nil || allTimeout != nil {
            reading = true
        }
        context.fireChannelRead(data)
    }

    public func channelReadComplete(context: ChannelHandlerContext) {
        if (readTimeout != nil  || allTimeout != nil) && reading {
            lastReadTime = .now()
            reading = false
        }
        context.fireChannelReadComplete()
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        if writeTimeout == nil && allTimeout == nil {
            context.write(data, promise: promise)
            return
        }

        let writePromise = promise ?? context.eventLoop.makePromise()
        writePromise.futureResult.whenComplete { (_: Result<Void, Error>) in
            self.lastWriteCompleteTime = .now()
        }
        context.write(data, promise: writePromise)
    }

    private func shouldReschedule(_ context: ChannelHandlerContext) -> Bool {
        if context.channel.isActive {
            return true
        }
        return false
    }

    private func makeReadTimeoutTask(_ context: ChannelHandlerContext, _ timeout: TimeAmount) -> (() -> Void) {
        return {
            guard self.shouldReschedule(context) else  {
                return
            }

            if self.reading {
                self.scheduledReaderTask = context.eventLoop.scheduleTask(in: timeout, self.makeReadTimeoutTask(context, timeout))
                return
            }

            let diff = .now() - self.lastReadTime
            if diff >= timeout {
                // Reader is idle - set a new timeout and trigger an event through the pipeline
                self.scheduledReaderTask = context.eventLoop.scheduleTask(in: timeout, self.makeReadTimeoutTask(context, timeout))

                context.fireUserInboundEventTriggered(IdleStateEvent.read)
            } else {
                // Read occurred before the timeout - set a new timeout with shorter delay.
                self.scheduledReaderTask = context.eventLoop.scheduleTask(deadline: self.lastReadTime + timeout, self.makeReadTimeoutTask(context, timeout))
            }
        }
    }

    private func makeWriteTimeoutTask(_ context: ChannelHandlerContext, _ timeout: TimeAmount) -> (() -> Void) {
        return {
            guard self.shouldReschedule(context) else  {
                return
            }

            let lastWriteTime = self.lastWriteCompleteTime
            let diff = .now() - lastWriteTime

            if diff >= timeout {
                // Writer is idle - set a new timeout and notify the callback.
                self.scheduledWriterTask = context.eventLoop.scheduleTask(in: timeout, self.makeWriteTimeoutTask(context, timeout))

                context.fireUserInboundEventTriggered(IdleStateEvent.write)
            } else {
                // Write occurred before the timeout - set a new timeout with shorter delay.
                self.scheduledWriterTask = context.eventLoop.scheduleTask(deadline: self.lastWriteCompleteTime + timeout, self.makeWriteTimeoutTask(context, timeout))
            }
        }
    }

    private func makeAllTimeoutTask(_ context: ChannelHandlerContext, _ timeout: TimeAmount) -> (() -> Void) {
        return {
            guard self.shouldReschedule(context) else  {
                return
            }

            if self.reading {
                self.scheduledReaderTask = context.eventLoop.scheduleTask(in: timeout, self.makeAllTimeoutTask(context, timeout))
                return
            }
            let lastRead = self.lastReadTime
            let lastWrite = self.lastWriteCompleteTime
            let latestLast = max(lastRead, lastWrite)

            let diff = .now() - latestLast
            if diff >= timeout {
                // Reader is idle - set a new timeout and trigger an event through the pipeline
                self.scheduledReaderTask = context.eventLoop.scheduleTask(in: timeout, self.makeAllTimeoutTask(context, timeout))

                context.fireUserInboundEventTriggered(IdleStateEvent.all)
            } else {
                // Read occurred before the timeout - set a new timeout with shorter delay.
                self.scheduledReaderTask = context.eventLoop.scheduleTask(deadline: latestLast + timeout, self.makeAllTimeoutTask(context, timeout))
            }
        }
    }

    private func schedule(_ context: ChannelHandlerContext, _ amount: TimeAmount?, _ body: @escaping (ChannelHandlerContext, TimeAmount) -> (() -> Void) ) -> Scheduled<Void>? {
        if let timeout = amount {
            return context.eventLoop.scheduleTask(in: timeout, body(context, timeout))
        }
        return nil
    }

    private func initIdleTasks(_ context: ChannelHandlerContext) {
        let now = NIODeadline.now()
        lastReadTime = now
        lastWriteCompleteTime = now
        scheduledReaderTask = schedule(context, readTimeout, makeReadTimeoutTask)
        scheduledWriterTask = schedule(context, writeTimeout, makeWriteTimeoutTask)
        scheduledAllTask = schedule(context, allTimeout, makeAllTimeoutTask)
    }

    private func cancelIdleTasks(_ context: ChannelHandlerContext) {
        scheduledReaderTask?.cancel()
        scheduledWriterTask?.cancel()
        scheduledAllTask?.cancel()
        scheduledReaderTask = nil
        scheduledWriterTask = nil
        scheduledAllTask = nil
    }
}
