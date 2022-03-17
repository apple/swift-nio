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

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@usableFromInline
final class AsyncChannelAdapterHandler<InboundIn>: ChannelDuplexHandler {
    @usableFromInline typealias OutboundIn = Any
    @usableFromInline typealias OutboundOut = Any

    // The initial buffer is just using a lock. We'll do something better later if profiling
    // shows it's necessary.
    @usableFromInline let bufferSize: Int
    @usableFromInline let _lock: Lock
    @usableFromInline var _bufferedMessages: CircularBuffer<InboundMessage>
    @usableFromInline var _messageDelivered: Optional<CheckedContinuation<InboundMessage, Never>>
    @usableFromInline var _readPromise: Optional<EventLoopPromise<Void>>

    @inlinable
    init(bufferSize: Int) {
        self.bufferSize = bufferSize
        self._lock = Lock()
        self._bufferedMessages = CircularBuffer(initialCapacity: bufferSize)
        self._messageDelivered = nil
        self._readPromise = nil
    }

    @inlinable
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // TODO: This should really be done a little differently, with a single big append in the channelReadComplete to reduce
        // lock contention.
        self._receiveNewEvent(.channelRead(self.unwrapInboundIn(data)))
    }

    @inlinable
    func channelInactive(context: ChannelHandlerContext) {
        self._receiveNewEvent(.eof)
    }

    @inlinable
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed {
            self._receiveNewEvent(.eof)
        }
    }

    @inlinable
    func read(context: ChannelHandlerContext) {
        let continueReading: Bool = self._lock.withLock {
            if self._bufferedMessages.count >= bufferSize && self._readPromise == nil {
                // TODO: rewrite this to avoid promises
                let promise = context.eventLoop.makePromise(of: Void.self)
                promise.futureResult.whenComplete { result in
                    self._lock.withLockVoid { self._readPromise = nil }

                    switch result {
                    case .success:
                        context.read()
                    case .failure:
                        context.close(promise: nil)
                    }
                }
                return false
            } else {
                return true
            }
        }

        if continueReading {
            context.read()
        }
    }

    @inlinable
    func _receiveNewEvent(_ event: InboundMessage) {
        // Sadly, we need to do some lock shenanigans here.
        self._lock.lock()

        if let continuation = self._messageDelivered {
            self._messageDelivered = nil

            // We MUST unlock here in case this does something weird.
            self._lock.unlock()
            continuation.resume(returning: event)
        } else {
            self._bufferedMessages.append(event)
            self._lock.unlock()
        }
    }

    @inlinable
    func loadEvent() async throws -> InboundMessage {
        // We have to do some lock shenanigans here.
        self._lock.lock()

        if let nextElement = self._bufferedMessages.popFirst() {
            // TODO: promise?
            let mustRead = self._pendingRead
            let maybeLoop = self._eventLoop
            self._lock.unlock()

            if mustRead, let loop = maybeLoop {

            }

            return nextElement
        } else {
            // We need a continuation to come into existence.
            // We must not await it.
            async let continuation = withCheckedContinuation { continuation in
                self._messageDelivered = continuation
            }
            self._lock.unlock()

            return await continuation
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension AsyncChannelAdapterHandler {
    @usableFromInline
    enum InboundMessage {
        case channelRead(InboundIn)
        case eof
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct InboundChannelStream<InboundIn> {
    @usableFromInline let _handler: AsyncChannelAdapterHandler<InboundIn>

    @inlinable init(_ handler: AsyncChannelAdapterHandler<InboundIn>) {
        self._handler = handler
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension InboundChannelStream: AsyncSequence {
    public typealias Element = Void

    public class AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline let _handler: AsyncChannelAdapterHandler<InboundIn>

        @inlinable
        init(_ handler: AsyncChannelAdapterHandler<InboundIn>) {
            self._handler = handler
        }

        @inlinable public func next() async throws -> Element? { return () }
    }

    @inlinable
    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(self._handler)
    }
}

#endif
