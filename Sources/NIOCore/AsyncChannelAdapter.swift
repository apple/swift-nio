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
import Darwin

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@usableFromInline
final class AsyncChannelAdapterHandler<InboundIn>: ChannelDuplexHandler {
    @usableFromInline typealias OutboundIn = Any
    @usableFromInline typealias OutboundOut = Any

    // The initial buffer is just using a lock. We'll do something better later if profiling
    // shows it's necessary.
    @usableFromInline let bufferSize: Int
    @usableFromInline let _lock: Lock
    @usableFromInline var _state: StreamState

    @inlinable
    init(bufferSize: Int) {
        self.bufferSize = bufferSize
        self._lock = Lock()
        self._state = .bufferingWithoutPendingRead(CircularBuffer(initialCapacity: bufferSize))
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
            switch self._state {
            case .bufferingWithPendingRead:
                return false
            case .waitingForBuffer:
                return true
            case .bufferingWithoutPendingRead(let buffer):
                if buffer.count >= self.bufferSize {
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
                // We're going to wait for a load. Here we do our lock shenanigans.
                // Observe my madness.
                let capturedBuffer = buffer
                async let result = withCheckedContinuation { continuation in
                    self._state = .waitingForBuffer(capturedBuffer, continuation)
                }
                self._lock.unlock()
                return await result
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
                // We're going to wait for a load. Here we do our lock shenanigans.
                // Observe my madness.
                let capturedBuffer = buffer
                async let result = withCheckedContinuation { continuation in
                    self._state = .waitingForBuffer(capturedBuffer, continuation)
                }
                self._lock.unlock()
                promise.succeed(())
                return await result
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
extension AsyncChannelAdapterHandler {
    @usableFromInline
    enum InboundMessage {
        case channelRead(InboundIn)
        case eof
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension AsyncChannelAdapterHandler {
    @usableFromInline
    enum StreamState {
        case bufferingWithoutPendingRead(CircularBuffer<InboundMessage>)
        case bufferingWithPendingRead(CircularBuffer<InboundMessage>, EventLoopPromise<Void>)
        case waitingForBuffer(CircularBuffer<InboundMessage>, CheckedContinuation<InboundMessage, Never>)
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
