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
import NIOConcurrencyHelpers

/// A `ChannelHandler` that is used to transform the inbound portion of a NIO
/// `Channel` into an `AsyncSequence` that supports backpressure.
///
/// Users should not construct this type directly: instead, they should use the
/// `Channel.makeAsyncStream(of:config:)` method to use the `Channel`'s preferred
/// construction. These types are `public` only to allow other `Channel`s to
/// override the implementation of that method.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public final class NIOAsyncChannelAdapterHandler<InboundIn>: ChannelDuplexHandler {
    public typealias OutboundIn = Any
    public typealias OutboundOut = Any

    // The initial buffer is just using a lock. We'll do something better later if profiling
    // shows it's necessary.
    @usableFromInline let config: NIOInboundChannelStreamConfig
    @usableFromInline let _lock: Lock
    @usableFromInline var _state: StreamState

    @inlinable
    public init(config: NIOInboundChannelStreamConfig) {
        self.config = config
        self._lock = Lock()
        self._state = .bufferingWithoutPendingRead(CircularBuffer(initialCapacity: config.bufferSize))
    }

    @inlinable
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // TODO: This should really be done a little differently, with a single big append in the channelReadComplete to reduce
        // lock contention.
        var promise: EventLoopPromise<Void>? = nil
        if self.config.forwardReads {
            let readPromise = context.eventLoop.makePromise(of: Void.self)
            readPromise.futureResult.whenSuccess {
                // This is less than ideal because we pay no attention to read(), but I didn't really
                // want to manage the complexity of that right now. We should be wary of this though
                // as it might cause gnarly bugs in the future.
                context.fireChannelRead(data)
                context.fireChannelReadComplete()
            }
            promise = readPromise
        }
        self._receiveNewEvent(.channelRead(self.unwrapInboundIn(data), promise))
    }

    @inlinable
    public func channelInactive(context: ChannelHandlerContext) {
        self._receiveNewEvent(.eof)
    }

    @inlinable
    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed {
            self._receiveNewEvent(.eof)
        }
    }

    @inlinable
    public func read(context: ChannelHandlerContext) {
        let continueReading: Bool = self._lock.withLock {
            switch self._state {
            case .bufferingWithPendingRead:
                return false
            case .waitingForBuffer:
                return true
            case .bufferingWithoutPendingRead(let buffer):
                if buffer.count >= self.config.bufferSize {
                    // TODO: Rewrite this to avoid promises.
                    let promise = context.eventLoop.makePromise(of: Void.self)
                    promise.futureResult.whenComplete { result in
                        self._delayedRead(result: result, context: context)
                    }
                    self._state = .bufferingWithPendingRead(buffer, promise)
                    return false
                } else {
                    return true
                }
            }
        }

        if continueReading {
            context.read()
        }
    }

    @inlinable
    func _delayedRead(result: Result<Void, Error>, context: ChannelHandlerContext) {
        self._lock.withLockVoid {
            switch self._state {
            case .bufferingWithPendingRead(let buffer, _):
                self._state = .bufferingWithoutPendingRead(buffer)
            case .bufferingWithoutPendingRead, .waitingForBuffer:
                preconditionFailure()
            }
        }

        switch result {
        case .success:
            context.read()
        case .failure:
            context.close(promise: nil)
        }
    }

    @inlinable
    func _receiveNewEvent(_ event: InboundMessage) {
        // Sadly, we need to do some lock shenanigans here.
        self._lock.lock()

        switch self._state {
        case .bufferingWithPendingRead(var buffer, let promise):
            // Weird, but let's tolerate it.
            buffer.append(event)
            self._state = .bufferingWithPendingRead(buffer, promise)
            self._lock.unlock()
        case .bufferingWithoutPendingRead(var buffer):
            buffer.append(event)
            self._state = .bufferingWithoutPendingRead(buffer)
            self._lock.unlock()
        case .waitingForBuffer(let buffer, let continuation):
            precondition(buffer.count == 0)
            self._state = .bufferingWithoutPendingRead(buffer)
            // DANGER: This is only safe if we aren't a custom executor. Otherwise this is
            // v. bad. We should decide if it matters.
            continuation.resume(returning: event)
            self._lock.unlock()
        }
    }

    @inlinable
    func loadEvent() async -> InboundMessage {
        // We have to do some lock shenanigans here.
        self._lock.lock()

        switch self._state {
        case .bufferingWithoutPendingRead(var buffer):
            if buffer.count > 0 {
                let result = buffer.removeFirst()
                self._state = .bufferingWithoutPendingRead(buffer)
                self._lock.unlock()
                return result
            } else {
                // We have to create a continuation. Drop the lock.
                self._lock.unlock()
                return await self._loadEventSlowPath()
            }
        case .bufferingWithPendingRead(var buffer, let promise):
            // No matter what happens here, we need to complete this promise.
            if buffer.count > 0 {
                let result = buffer.removeFirst()
                self._state = .bufferingWithoutPendingRead(buffer)
                self._lock.unlock()
                promise.succeed(())
                return result
            } else {
                // We have to create a continuation, drop the lock.
                self._lock.unlock()
                return await self._loadEventSlowPath()
            }
        case .waitingForBuffer:
            preconditionFailure("Should never be async nexting twice.")
        }
    }

    @inlinable
    func _loadEventSlowPath() async -> InboundMessage {
        return await withCheckedContinuation { (continuation: CheckedContinuation<InboundMessage, Never>) in
            let result: (InboundMessage?, EventLoopPromise<Void>?) = self._lock.withLock {
                switch self._state {
                case .bufferingWithoutPendingRead(var buffer):
                    if let result = buffer.popFirst() {
                        // In the time between dropping the lock and getting it back we got some data. We can satisfy immediately.
                        self._state = .bufferingWithoutPendingRead(buffer)
                        return (result, nil)
                    } else {
                        self._state = .waitingForBuffer(buffer, continuation)
                        return (nil, nil)
                    }

                case .bufferingWithPendingRead(var buffer, let promise):
                    // No matter what happens here, we need to complete this promise.
                    if let result = buffer.popFirst() {
                        self._state = .bufferingWithoutPendingRead(buffer)
                        return (result, promise)
                    } else {
                        self._state = .waitingForBuffer(buffer, continuation)
                        return (nil, promise)
                    }

                case .waitingForBuffer:
                    preconditionFailure("Should never be async nexting twice")
                }
            }

            if let message = result.0 {
                continuation.resume(returning: message)
            }
            if let promise = result.1 {
                promise.succeed(())
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
    @usableFromInline let _handler: NIOAsyncChannelAdapterHandler<InboundIn>

    @inlinable
    public init(_ handler: NIOAsyncChannelAdapterHandler<InboundIn>) {
        self._handler = handler
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension NIOInboundChannelStream: AsyncSequence {
    public typealias Element = InboundIn

    public class AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline let _handler: NIOAsyncChannelAdapterHandler<InboundIn>

        @inlinable
        init(_ handler: NIOAsyncChannelAdapterHandler<InboundIn>) {
            self._handler = handler
        }

        @inlinable public func next() async throws -> Element? {
            switch await self._handler.loadEvent() {
            case .channelRead(let message, let promise):
                promise?.succeed(())
                return message
            case .eof:
                return nil
            }
        }
    }

    @inlinable
    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(self._handler)
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct NIOInboundChannelStreamConfig {
    /// The size of the backpressure buffer to use.
    ///
    /// The larger this buffer, the higher the throughput will be, but the
    /// higher the peak latencies will be. Tuning buffer sizes is a complex
    /// art.
    public var bufferSize: Int

    /// Whether `channelRead`s should be forwarded to the rest of the
    /// `ChannelPipeline` after they're delivered to the stream. This is
    /// generally set to `false` because it imposes a performance cost, but
    /// some `Channel`s require this for correct functionality.
    public var forwardReads: Bool

    @inlinable
    public init(bufferSize: Int, forwardReads: Bool = false) {
        self.bufferSize = bufferSize
        self.forwardReads = forwardReads
    }
}
#endif
