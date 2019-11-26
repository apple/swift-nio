//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOConcurrencyHelpers

/// `EventCounterHandler` is a `ChannelHandler` that counts and forwards all the events that it sees coming through
/// the `ChannelPipeline`.
///
/// Adding `EventCounterHandler` to any point of your `ChannelPipeline` should not change the program's behaviour.
/// `EventCounterHandler` is mostly useful in unit tests to validate other `ChannelHandler`'s behaviour.
///
/// - note: Contrary to most `ChannelHandler`s, all of `EventCounterHandler`'s API is thread-safe meaning that you can
///         query the events received from any thread.
public final class EventCounterHandler {
    private let _channelRegisteredCalls = FastAtomic<Int>.makeAtomic(value: 0)
    private let _channelUnregisteredCalls = FastAtomic<Int>.makeAtomic(value: 0)
    private let _channelActiveCalls = FastAtomic<Int>.makeAtomic(value: 0)
    private let _channelInactiveCalls = FastAtomic<Int>.makeAtomic(value: 0)
    private let _channelReadCalls = FastAtomic<Int>.makeAtomic(value: 0)
    private let _channelReadCompleteCalls = FastAtomic<Int>.makeAtomic(value: 0)
    private let _channelWritabilityChangedCalls = FastAtomic<Int>.makeAtomic(value: 0)
    private let _userInboundEventTriggeredCalls = FastAtomic<Int>.makeAtomic(value: 0)
    private let _errorCaughtCalls = FastAtomic<Int>.makeAtomic(value: 0)
    private let _registerCalls = FastAtomic<Int>.makeAtomic(value: 0)
    private let _bindCalls = FastAtomic<Int>.makeAtomic(value: 0)
    private let _connectCalls = FastAtomic<Int>.makeAtomic(value: 0)
    private let _writeCalls = FastAtomic<Int>.makeAtomic(value: 0)
    private let _flushCalls = FastAtomic<Int>.makeAtomic(value: 0)
    private let _readCalls = FastAtomic<Int>.makeAtomic(value: 0)
    private let _closeCalls = FastAtomic<Int>.makeAtomic(value: 0)
    private let _triggerUserOutboundEventCalls = FastAtomic<Int>.makeAtomic(value: 0)

    public init() {}
}

// MARK: Public API
extension EventCounterHandler {
    public struct ValidityError: Error {
        public var reason: String

        init(_ reason: String) {
            self.reason = reason
        }
    }

    /// Returns the number of `channelRegistered` events seen so far in the `ChannelPipeline`.
    public var channelRegisteredCalls: Int {
        return self._channelRegisteredCalls.load()
    }

    /// Returns the number of `channelUnregistered` events seen so far in the `ChannelPipeline`.
    public var channelUnregisteredCalls: Int {
        return self._channelUnregisteredCalls.load()
    }

    /// Returns the number of `channelActive` events seen so far in the `ChannelPipeline`.
    public var channelActiveCalls: Int {
        return self._channelActiveCalls.load()
    }

    /// Returns the number of `channelInactive` events seen so far in the `ChannelPipeline`.
    public var channelInactiveCalls: Int {
        return self._channelInactiveCalls.load()
    }

    /// Returns the number of `channelRead` events seen so far in the `ChannelPipeline`.
    public var channelReadCalls: Int {
        return self._channelReadCalls.load()
    }

    /// Returns the number of `channelReadComplete` events seen so far in the `ChannelPipeline`.
    public var channelReadCompleteCalls: Int {
        return self._channelReadCompleteCalls.load()
    }

    /// Returns the number of `channelWritabilityChanged` events seen so far in the `ChannelPipeline`.
    public var channelWritabilityChangedCalls: Int {
        return self._channelWritabilityChangedCalls.load()
    }

    /// Returns the number of `userInboundEventTriggered` events seen so far in the `ChannelPipeline`.
    public var userInboundEventTriggeredCalls: Int {
        return self._userInboundEventTriggeredCalls.load()
    }

    /// Returns the number of `errorCaught` events seen so far in the `ChannelPipeline`.
    public var errorCaughtCalls: Int {
        return self._errorCaughtCalls.load()
    }

    /// Returns the number of `register` events seen so far in the `ChannelPipeline`.
    public var registerCalls: Int {
        return self._registerCalls.load()
    }

    /// Returns the number of `bind` events seen so far in the `ChannelPipeline`.
    public var bindCalls: Int {
        return self._bindCalls.load()
    }

    /// Returns the number of `connect` events seen so far in the `ChannelPipeline`.
    public var connectCalls: Int {
        return self._connectCalls.load()
    }

    /// Returns the number of `write` events seen so far in the `ChannelPipeline`.
    public var writeCalls: Int {
        return self._writeCalls.load()
    }

    /// Returns the number of `flush` events seen so far in the `ChannelPipeline`.
    public var flushCalls: Int {
        return self._flushCalls.load()
    }

    /// Returns the number of `read` events seen so far in the `ChannelPipeline`.
    public var readCalls: Int {
        return self._readCalls.load()
    }

    /// Returns the number of `close` events seen so far in the `ChannelPipeline`.
    public var closeCalls: Int {
        return self._closeCalls.load()
    }

    /// Returns the number of `triggerUserOutboundEvent` events seen so far in the `ChannelPipeline`.
    public var triggerUserOutboundEventCalls: Int {
        return self._triggerUserOutboundEventCalls.load()
    }

    /// Validate some basic assumptions about the number of events and if any of those assumptions are violated, throw
    /// an error.
    ///
    /// For example, any `Channel` should only be registered with the `Selector` at most once. That means any
    /// `ChannelHandler` should see no more than one `register` event. If `EventCounterHandler` sees more than one
    /// `register` event and you call `checkValidity`, it will throw `EventCounterHandler.ValidityError` with an
    /// appropriate explanation.
    ///
    /// - note: This API is thread-safe, you may call it from any thread. The results of this API may vary though if you
    ///         call it whilst the `Channel` this `ChannelHandler` is in is still in use.
    public func checkValidity() throws {
        guard self.channelRegisteredCalls <= 1 else {
            throw ValidityError("channelRegistered should be called no more than once")
        }
        guard self.channelUnregisteredCalls <= 1 else {
            throw ValidityError("channelUnregistered should be called no more than once")
        }
        guard self.channelActiveCalls <= 1 else {
            throw ValidityError("channelActive should be called no more than once")
        }
        guard self.channelInactiveCalls <= 1 else {
            throw ValidityError("channelInactive should be called no more than once")
        }
        guard self.registerCalls <= 1 else {
            throw ValidityError("register should be called no more than once")
        }
        guard self.bindCalls <= 1 else {
            throw ValidityError("bind should be called no more than once")
        }
        guard self.connectCalls <= 1 else {
            throw ValidityError("connect should be called no more than once")
        }
    }

    /// Return all event descriptions that have triggered.
    ///
    /// This is most useful in unit tests where you want to make sure only certain events have been triggered.
    ///
    /// - note: This API is thread-safe, you may call it from any thread. The results of this API may vary though if you
    ///         call it whilst the `Channel` this `ChannelHandler` is in is still in use.
    public func allTriggeredEvents() -> Set<String> {
        var allEvents: Set<String> = []

        if self.channelRegisteredCalls != 0 {
            allEvents.insert("channelRegistered")
        }

        if self.channelUnregisteredCalls != 0 {
            allEvents.insert("channelUnregistered")
        }

        if self.channelActiveCalls != 0 {
            allEvents.insert("channelActive")
        }

        if self.channelInactiveCalls != 0 {
            allEvents.insert("channelInactive")
        }

        if self.channelReadCalls != 0 {
            allEvents.insert("channelRead")
        }

        if self.channelReadCompleteCalls != 0 {
            allEvents.insert("channelReadComplete")
        }

        if self.channelWritabilityChangedCalls != 0 {
            allEvents.insert("channelWritabilityChanged")
        }

        if self.userInboundEventTriggeredCalls != 0 {
            allEvents.insert("userInboundEventTriggered")
        }

        if self.errorCaughtCalls != 0 {
            allEvents.insert("errorCaught")
        }

        if self.registerCalls != 0 {
            allEvents.insert("register")
        }

        if self.bindCalls != 0 {
            allEvents.insert("bind")
        }

        if self.connectCalls != 0 {
            allEvents.insert("connect")
        }

        if self.writeCalls != 0 {
            allEvents.insert("write")
        }

        if self.flushCalls != 0 {
            allEvents.insert("flush")
        }

        if self.readCalls != 0 {
            allEvents.insert("read")
        }

        if self.closeCalls != 0 {
            allEvents.insert("close")
        }

        if self.triggerUserOutboundEventCalls != 0 {
            allEvents.insert("triggerUserOutboundEvent")
        }

        return allEvents
    }
}

// MARK: ChannelHandler API
extension EventCounterHandler: ChannelDuplexHandler {
    public typealias InboundIn = Any
    public typealias InboundOut = Any
    public typealias OutboundIn = Any
    public typealias OutboundOut = Any

    /// @see: `_ChannelInboundHandler.channelRegistered`
    public func channelRegistered(context: ChannelHandlerContext) {
        _ = self._channelRegisteredCalls.add(1)
        context.fireChannelRegistered()
    }

    /// @see: `_ChannelInboundHandler.channelUnregistered`
    public func channelUnregistered(context: ChannelHandlerContext) {
        _ = self._channelUnregisteredCalls.add(1)
        context.fireChannelUnregistered()
    }

    /// @see: `_ChannelInboundHandler.channelActive`
    public func channelActive(context: ChannelHandlerContext) {
        _ = self._channelActiveCalls.add(1)
        context.fireChannelActive()
    }

    /// @see: `_ChannelInboundHandler.channelInactive`
    public func channelInactive(context: ChannelHandlerContext) {
        _ = self._channelInactiveCalls.add(1)
        context.fireChannelInactive()
    }

    /// @see: `_ChannelInboundHandler.channelRead`
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        _ = self._channelReadCalls.add(1)
        context.fireChannelRead(data)
    }
    
    /// @see: `_ChannelInboundHandler.channelReadComplete`
    public func channelReadComplete(context: ChannelHandlerContext) {
        _ = self._channelReadCompleteCalls.add(1)
        context.fireChannelReadComplete()
    }

    /// @see: `_ChannelInboundHandler.channelWritabilityChanged`
    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        _ = self._channelWritabilityChangedCalls.add(1)
        context.fireChannelWritabilityChanged()
    }

    /// @see: `_ChannelInboundHandler.userInboundEventTriggered`
    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        _ = self._userInboundEventTriggeredCalls.add(1)
        context.fireUserInboundEventTriggered(event)
    }
    
    /// @see: `_ChannelInboundHandler.errorCaught`
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        _ = self._errorCaughtCalls.add(1)
        context.fireErrorCaught(error)
    }

    /// @see: `_ChannelOutboundHandler.register`
    public func register(context: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        _ = self._registerCalls.add(1)
        context.register(promise: promise)
    }

    /// @see: `_ChannelOutboundHandler.bind`
    public func bind(context: ChannelHandlerContext, to: SocketAddress, promise: EventLoopPromise<Void>?) {
        _ = self._bindCalls.add(1)
        context.bind(to: to, promise: promise)
    }

    /// @see: `_ChannelOutboundHandler.connect`
    public func connect(context: ChannelHandlerContext, to: SocketAddress, promise: EventLoopPromise<Void>?) {
        _ = self._connectCalls.add(1)
        context.connect(to: to, promise: promise)
    }

    /// @see: `_ChannelOutboundHandler.write`
    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        _ = self._writeCalls.add(1)
        context.write(data, promise: promise)
    }

    /// @see: `_ChannelOutboundHandler.flush`
    public func flush(context: ChannelHandlerContext) {
        _ = self._flushCalls.add(1)
        context.flush()
    }

    /// @see: `_ChannelOutboundHandler.read`
    public func read(context: ChannelHandlerContext) {
        _ = self._readCalls.add(1)
        context.read()
    }

    /// @see: `_ChannelOutboundHandler.close`
    public func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        _ = self._closeCalls.add(1)
        context.close(mode: mode, promise: promise)
    }

    /// @see: `_ChannelOutboundHandler.triggerUserOutboundEvent`
    public func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        _ = self._triggerUserOutboundEventCalls.add(1)
        context.triggerUserOutboundEvent(event, promise: promise)
    }
}
