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

import Atomics
import NIOConcurrencyHelpers
import NIOCore

/// `EventCounterHandler` is a `ChannelHandler` that counts and forwards all the events that it sees coming through
/// the `ChannelPipeline`.
///
/// Adding `EventCounterHandler` to any point of your `ChannelPipeline` should not change the program's behaviour.
/// `EventCounterHandler` is mostly useful in unit tests to validate other `ChannelHandler`'s behaviour.
///
/// - Note: Contrary to most `ChannelHandler`s, all of `EventCounterHandler`'s API is thread-safe meaning that you can
///         query the events received from any thread.
public final class EventCounterHandler: Sendable {
    private let _channelRegisteredCalls = ManagedAtomic<Int>(0)
    private let _channelUnregisteredCalls = ManagedAtomic<Int>(0)
    private let _channelActiveCalls = ManagedAtomic<Int>(0)
    private let _channelInactiveCalls = ManagedAtomic<Int>(0)
    private let _channelReadCalls = ManagedAtomic<Int>(0)
    private let _channelReadCompleteCalls = ManagedAtomic<Int>(0)
    private let _channelWritabilityChangedCalls = ManagedAtomic<Int>(0)
    private let _userInboundEventTriggeredCalls = ManagedAtomic<Int>(0)
    private let _errorCaughtCalls = ManagedAtomic<Int>(0)
    private let _registerCalls = ManagedAtomic<Int>(0)
    private let _bindCalls = ManagedAtomic<Int>(0)
    private let _connectCalls = ManagedAtomic<Int>(0)
    private let _writeCalls = ManagedAtomic<Int>(0)
    private let _flushCalls = ManagedAtomic<Int>(0)
    private let _readCalls = ManagedAtomic<Int>(0)
    private let _closeCalls = ManagedAtomic<Int>(0)
    private let _triggerUserOutboundEventCalls = ManagedAtomic<Int>(0)

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
        self._channelRegisteredCalls.load(ordering: .relaxed)
    }

    /// Returns the number of `channelUnregistered` events seen so far in the `ChannelPipeline`.
    public var channelUnregisteredCalls: Int {
        self._channelUnregisteredCalls.load(ordering: .relaxed)
    }

    /// Returns the number of `channelActive` events seen so far in the `ChannelPipeline`.
    public var channelActiveCalls: Int {
        self._channelActiveCalls.load(ordering: .relaxed)
    }

    /// Returns the number of `channelInactive` events seen so far in the `ChannelPipeline`.
    public var channelInactiveCalls: Int {
        self._channelInactiveCalls.load(ordering: .relaxed)
    }

    /// Returns the number of `channelRead` events seen so far in the `ChannelPipeline`.
    public var channelReadCalls: Int {
        self._channelReadCalls.load(ordering: .relaxed)
    }

    /// Returns the number of `channelReadComplete` events seen so far in the `ChannelPipeline`.
    public var channelReadCompleteCalls: Int {
        self._channelReadCompleteCalls.load(ordering: .relaxed)
    }

    /// Returns the number of `channelWritabilityChanged` events seen so far in the `ChannelPipeline`.
    public var channelWritabilityChangedCalls: Int {
        self._channelWritabilityChangedCalls.load(ordering: .relaxed)
    }

    /// Returns the number of `userInboundEventTriggered` events seen so far in the `ChannelPipeline`.
    public var userInboundEventTriggeredCalls: Int {
        self._userInboundEventTriggeredCalls.load(ordering: .relaxed)
    }

    /// Returns the number of `errorCaught` events seen so far in the `ChannelPipeline`.
    public var errorCaughtCalls: Int {
        self._errorCaughtCalls.load(ordering: .relaxed)
    }

    /// Returns the number of `register` events seen so far in the `ChannelPipeline`.
    public var registerCalls: Int {
        self._registerCalls.load(ordering: .relaxed)
    }

    /// Returns the number of `bind` events seen so far in the `ChannelPipeline`.
    public var bindCalls: Int {
        self._bindCalls.load(ordering: .relaxed)
    }

    /// Returns the number of `connect` events seen so far in the `ChannelPipeline`.
    public var connectCalls: Int {
        self._connectCalls.load(ordering: .relaxed)
    }

    /// Returns the number of `write` events seen so far in the `ChannelPipeline`.
    public var writeCalls: Int {
        self._writeCalls.load(ordering: .relaxed)
    }

    /// Returns the number of `flush` events seen so far in the `ChannelPipeline`.
    public var flushCalls: Int {
        self._flushCalls.load(ordering: .relaxed)
    }

    /// Returns the number of `read` events seen so far in the `ChannelPipeline`.
    public var readCalls: Int {
        self._readCalls.load(ordering: .relaxed)
    }

    /// Returns the number of `close` events seen so far in the `ChannelPipeline`.
    public var closeCalls: Int {
        self._closeCalls.load(ordering: .relaxed)
    }

    /// Returns the number of `triggerUserOutboundEvent` events seen so far in the `ChannelPipeline`.
    public var triggerUserOutboundEventCalls: Int {
        self._triggerUserOutboundEventCalls.load(ordering: .relaxed)
    }

    /// Validate some basic assumptions about the number of events and if any of those assumptions are violated, throw
    /// an error.
    ///
    /// For example, any `Channel` should only be registered with the `Selector` at most once. That means any
    /// `ChannelHandler` should see no more than one `register` event. If `EventCounterHandler` sees more than one
    /// `register` event and you call `checkValidity`, it will throw `EventCounterHandler.ValidityError` with an
    /// appropriate explanation.
    ///
    /// - Note: This API is thread-safe, you may call it from any thread. The results of this API may vary though if you
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
    /// - Note: This API is thread-safe, you may call it from any thread. The results of this API may vary though if you
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
        self._channelRegisteredCalls.wrappingIncrement(ordering: .relaxed)
        context.fireChannelRegistered()
    }

    /// @see: `_ChannelInboundHandler.channelUnregistered`
    public func channelUnregistered(context: ChannelHandlerContext) {
        self._channelUnregisteredCalls.wrappingIncrement(ordering: .relaxed)
        context.fireChannelUnregistered()
    }

    /// @see: `_ChannelInboundHandler.channelActive`
    public func channelActive(context: ChannelHandlerContext) {
        self._channelActiveCalls.wrappingIncrement(ordering: .relaxed)
        context.fireChannelActive()
    }

    /// @see: `_ChannelInboundHandler.channelInactive`
    public func channelInactive(context: ChannelHandlerContext) {
        self._channelInactiveCalls.wrappingIncrement(ordering: .relaxed)
        context.fireChannelInactive()
    }

    /// @see: `_ChannelInboundHandler.channelRead`
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self._channelReadCalls.wrappingIncrement(ordering: .relaxed)
        context.fireChannelRead(data)
    }

    /// @see: `_ChannelInboundHandler.channelReadComplete`
    public func channelReadComplete(context: ChannelHandlerContext) {
        self._channelReadCompleteCalls.wrappingIncrement(ordering: .relaxed)
        context.fireChannelReadComplete()
    }

    /// @see: `_ChannelInboundHandler.channelWritabilityChanged`
    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        self._channelWritabilityChangedCalls.wrappingIncrement(ordering: .relaxed)
        context.fireChannelWritabilityChanged()
    }

    /// @see: `_ChannelInboundHandler.userInboundEventTriggered`
    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        self._userInboundEventTriggeredCalls.wrappingIncrement(ordering: .relaxed)
        context.fireUserInboundEventTriggered(event)
    }

    /// @see: `_ChannelInboundHandler.errorCaught`
    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        self._errorCaughtCalls.wrappingIncrement(ordering: .relaxed)
        context.fireErrorCaught(error)
    }

    /// @see: `_ChannelOutboundHandler.register`
    public func register(context: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        self._registerCalls.wrappingIncrement(ordering: .relaxed)
        context.register(promise: promise)
    }

    /// @see: `_ChannelOutboundHandler.bind`
    public func bind(context: ChannelHandlerContext, to: SocketAddress, promise: EventLoopPromise<Void>?) {
        self._bindCalls.wrappingIncrement(ordering: .relaxed)
        context.bind(to: to, promise: promise)
    }

    /// @see: `_ChannelOutboundHandler.connect`
    public func connect(context: ChannelHandlerContext, to: SocketAddress, promise: EventLoopPromise<Void>?) {
        self._connectCalls.wrappingIncrement(ordering: .relaxed)
        context.connect(to: to, promise: promise)
    }

    /// @see: `_ChannelOutboundHandler.write`
    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self._writeCalls.wrappingIncrement(ordering: .relaxed)
        context.write(data, promise: promise)
    }

    /// @see: `_ChannelOutboundHandler.flush`
    public func flush(context: ChannelHandlerContext) {
        self._flushCalls.wrappingIncrement(ordering: .relaxed)
        context.flush()
    }

    /// @see: `_ChannelOutboundHandler.read`
    public func read(context: ChannelHandlerContext) {
        self._readCalls.wrappingIncrement(ordering: .relaxed)
        context.read()
    }

    /// @see: `_ChannelOutboundHandler.close`
    public func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        self._closeCalls.wrappingIncrement(ordering: .relaxed)
        context.close(mode: mode, promise: promise)
    }

    /// @see: `_ChannelOutboundHandler.triggerUserOutboundEvent`
    public func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        self._triggerUserOutboundEventCalls.wrappingIncrement(ordering: .relaxed)
        context.triggerUserOutboundEvent(event, promise: promise)
    }
}
