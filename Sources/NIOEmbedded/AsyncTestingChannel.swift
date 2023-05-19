//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers
import NIOCore

/// A `Channel` with fine-grained control for testing.
///
/// ``NIOAsyncTestingChannel`` is a `Channel` implementation that does no
/// actual IO but that does have proper eventing mechanism, albeit one that users can
/// control. The prime use-case for ``NIOAsyncTestingChannel`` is in unit tests when you
/// want to feed the inbound events and check the outbound events manually.
///
/// Please remember to call ``finish()`` when you are no longer using this
/// ``NIOAsyncTestingChannel``.
///
/// To feed events through an ``NIOAsyncTestingChannel``'s `ChannelPipeline` use
/// ``NIOAsyncTestingChannel/writeInbound(_:)`` which accepts data of any type. It will then
/// forward that data through the `ChannelPipeline` and the subsequent
/// `ChannelInboundHandler` will receive it through the usual `channelRead`
/// event. The user is responsible for making sure the first
/// `ChannelInboundHandler` expects data of that type.
///
/// Unlike in a regular `ChannelPipeline`, it is expected that the test code will act
/// as the "network layer", using ``readOutbound(as:)`` to observe the data that the
/// `Channel` has "written" to the network, and using ``writeInbound(_:)`` to simulate
/// receiving data from the network. There are also facilities to make it a bit easier
/// to handle the logic for `write` and `flush` (using ``writeOutbound(_:)``), and to
/// extract data that passed the whole way along the channel in `channelRead` (using
/// ``readOutbound(as:)``. Below is a diagram showing the layout of a `ChannelPipeline`
/// inside a ``NIOAsyncTestingChannel``, including the functions that can be used to
/// inject and extract data at each end.
///
/// ```
///
///            Extract data                         Inject data
///         using readInbound()                using writeOutbound()
///                  ▲                                   |
///  +---------------+-----------------------------------+---------------+
///  |               |           ChannelPipeline         |               |
///  |               |                TAIL               ▼               |
///  |    +---------------------+            +-----------+----------+    |
///  |    | Inbound Handler  N  |            | Outbound Handler  1  |    |
///  |    +----------+----------+            +-----------+----------+    |
///  |               ▲                                   |               |
///  |               |                                   ▼               |
///  |    +----------+----------+            +-----------+----------+    |
///  |    | Inbound Handler N-1 |            | Outbound Handler  2  |    |
///  |    +----------+----------+            +-----------+----------+    |
///  |               ▲                                   .               |
///  |               .                                   .               |
///  | ChannelHandlerContext.fireIN_EVT() ChannelHandlerContext.OUT_EVT()|
///  |        [ method call]                       [method call]         |
///  |               .                                   .               |
///  |               .                                   ▼               |
///  |    +----------+----------+            +-----------+----------+    |
///  |    | Inbound Handler  2  |            | Outbound Handler M-1 |    |
///  |    +----------+----------+            +-----------+----------+    |
///  |               ▲                                   |               |
///  |               |                                   ▼               |
///  |    +----------+----------+            +-----------+----------+    |
///  |    | Inbound Handler  1  |            | Outbound Handler  M  |    |
///  |    +----------+----------+            +-----------+----------+    |
///  |               ▲              HEAD                 |               |
///  +---------------+-----------------------------------+---------------+
///                  |                                   ▼
///             Inject data                         Extract data
///         using writeInbound()                using readOutbound()
/// ```
///
/// - note: ``NIOAsyncTestingChannel`` is currently only compatible with
///   ``NIOAsyncTestingEventLoop``s and cannot be used with `SelectableEventLoop`s from
///   for example `MultiThreadedEventLoopGroup`.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public final class NIOAsyncTestingChannel: Channel {
    /// ``LeftOverState`` represents any left-over inbound, outbound, and pending outbound events that hit the
    /// ``NIOAsyncTestingChannel`` and were not consumed when ``finish()`` was called on the ``NIOAsyncTestingChannel``.
    ///
    /// ``NIOAsyncTestingChannel`` is most useful in testing and usually in unit tests, you want to consume all inbound and
    /// outbound data to verify they are what you expect. Therefore, when you ``finish()`` a ``NIOAsyncTestingChannel`` it will
    /// return if it's either ``LeftOverState/clean`` (no left overs) or that it has ``LeftOverState/leftOvers(inbound:outbound:pendingOutbound:)``.
    public enum LeftOverState {
        /// The ``NIOAsyncTestingChannel`` is clean, ie. no inbound, outbound, or pending outbound data left on ``NIOAsyncTestingChannel/finish()``.
        case clean

        /// The ``NIOAsyncTestingChannel`` has inbound, outbound, or pending outbound data left on ``NIOAsyncTestingChannel/finish()``.
        case leftOvers(inbound: CircularBuffer<NIOAny>, outbound: CircularBuffer<NIOAny>, pendingOutbound: [NIOAny])

        /// `true` if the ``NIOAsyncTestingChannel`` was `clean` on ``NIOAsyncTestingChannel/finish()``, ie. there is no unconsumed inbound, outbound, or
        /// pending outbound data left on the `Channel`.
        public var isClean: Bool {
            if case .clean = self {
                return true
            } else {
                return false
            }
        }

        /// `true` if the ``NIOAsyncTestingChannel`` if there was unconsumed inbound, outbound, or pending outbound data left
        /// on the `Channel` when it was `finish`ed.
        public var hasLeftOvers: Bool {
            return !self.isClean
        }
    }

    /// ``BufferState`` represents the state of either the inbound, or the outbound ``NIOAsyncTestingChannel`` buffer.
    ///
    /// These buffers contain data that travelled the `ChannelPipeline` all the way through..
    ///
    /// If the last `ChannelHandler` explicitly (by calling `fireChannelRead`) or implicitly (by not implementing
    /// `channelRead`) sends inbound data into the end of the ``NIOAsyncTestingChannel``, it will be held in the
    /// ``NIOAsyncTestingChannel``'s inbound buffer. Similarly for `write` on the outbound side. The state of the respective
    /// buffer will be returned from ``writeInbound(_:)``/``writeOutbound(_:)`` as a ``BufferState``.
    public enum BufferState {
        /// The buffer is empty.
        case empty

        /// The buffer is non-empty.
        case full(CircularBuffer<NIOAny>)

        /// Returns `true` is the buffer was empty.
        public var isEmpty: Bool {
            if case .empty = self {
                return true
            } else {
                return false
            }
        }

        /// Returns `true` if the buffer was non-empty.
        public var isFull: Bool {
            return !self.isEmpty
        }
    }

    /// ``WrongTypeError`` is thrown if you use ``readInbound(as:)`` or ``readOutbound(as:)`` and request a certain type but the first
    /// item in the respective buffer is of a different type.
    public struct WrongTypeError: Error, Equatable {
        /// The type you expected.
        public let expected: Any.Type

        /// The type of the actual first element.
        public let actual: Any.Type

        public init(expected: Any.Type, actual: Any.Type) {
            self.expected = expected
            self.actual = actual
        }

        public static func == (lhs: WrongTypeError, rhs: WrongTypeError) -> Bool {
            return lhs.expected == rhs.expected && lhs.actual == rhs.actual
        }
    }

    /// Returns `true` if the ``NIOAsyncTestingChannel`` is 'active'.
    ///
    /// An active ``NIOAsyncTestingChannel`` can be closed by calling `close` or ``finish()`` on the ``NIOAsyncTestingChannel``.
    ///
    /// - note: An ``NIOAsyncTestingChannel`` starts _inactive_ and can be activated, for example by calling `connect`.
    public var isActive: Bool { return channelcore.isActive }

    /// - see: `ChannelOptions.Types.AllowRemoteHalfClosureOption`
    public var allowRemoteHalfClosure: Bool {
        get {
            return channelcore.allowRemoteHalfClosure
        }
        set {
            channelcore.allowRemoteHalfClosure = newValue
        }
    }

    /// - see: `Channel.closeFuture`
    public var closeFuture: EventLoopFuture<Void> { return channelcore.closePromise.futureResult }

    /// - see: `Channel.allocator`
    public let allocator: ByteBufferAllocator = ByteBufferAllocator()

    /// - see: `Channel.eventLoop`
    public var eventLoop: EventLoop {
        return self.testingEventLoop
    }

    /// Returns the ``NIOAsyncTestingEventLoop`` that this ``NIOAsyncTestingChannel`` uses. This will return the same instance as
    /// ``NIOAsyncTestingChannel/eventLoop`` but as the concrete ``NIOAsyncTestingEventLoop`` rather than as `EventLoop` existential.
    public let testingEventLoop: NIOAsyncTestingEventLoop

    /// `nil` because ``NIOAsyncTestingChannel``s don't have parents.
    public let parent: Channel? = nil

    // This is only written once, from a single thread, and never written again, so it's _technically_ thread-safe. Most methods cannot safely
    // be used from multiple threads, but `isActive`, `isOpen`, `eventLoop`, and `closeFuture` can all safely be used from any thread. Just.
    @usableFromInline
    /*private but usableFromInline */ var channelcore: EmbeddedChannelCore!

    /// Guards any of the getters/setters that can be accessed from any thread.
    private let stateLock: NIOLock = NIOLock()

    // Guarded by `stateLock`
    private var _isWritable: Bool = true

    // Guarded by `stateLock`
    private var _localAddress: SocketAddress? = nil

    // Guarded by `stateLock`
    private var _remoteAddress: SocketAddress? = nil

    private var _pipeline: ChannelPipeline!

    /// - see: `Channel._channelCore`
    public var _channelCore: ChannelCore {
        return channelcore
    }

    /// - see: `Channel.pipeline`
    public var pipeline: ChannelPipeline {
        return _pipeline
    }

    /// - see: `Channel.isWritable`
    public var isWritable: Bool {
        get {
            return self.stateLock.withLock { self._isWritable }
        }
        set {
            self.stateLock.withLock { () -> Void in
                self._isWritable = newValue
            }
        }
    }

    /// - see: `Channel.localAddress`
    public var localAddress: SocketAddress? {
        get {
            return self.stateLock.withLock { self._localAddress }
        }
        set {
            self.stateLock.withLock { () -> Void in
                self._localAddress = newValue
            }
        }
    }

    /// - see: `Channel.remoteAddress`
    public var remoteAddress: SocketAddress? {
        get {
            return self.stateLock.withLock { self._remoteAddress }
        }
        set {
            self.stateLock.withLock { () -> Void in
                self._remoteAddress = newValue
            }
        }
    }

    /// Create a new instance.
    ///
    /// During creation it will automatically also register itself on the ``NIOAsyncTestingEventLoop``.
    ///
    /// - parameters:
    ///     - loop: The ``NIOAsyncTestingEventLoop`` to use.
    public init(loop: NIOAsyncTestingEventLoop = NIOAsyncTestingEventLoop()) {
        self.testingEventLoop = loop
        self._pipeline = ChannelPipeline(channel: self)
        self.channelcore = EmbeddedChannelCore(pipeline: self._pipeline, eventLoop: self.eventLoop)
    }

    /// Create a new instance.
    ///
    /// During creation it will automatically also register itself on the ``NIOAsyncTestingEventLoop``.
    ///
    /// - parameters:
    ///     - handler: The `ChannelHandler` to add to the `ChannelPipeline` before register.
    ///     - loop: The ``NIOAsyncTestingEventLoop`` to use.
    public convenience init(handler: ChannelHandler, loop: NIOAsyncTestingEventLoop = NIOAsyncTestingEventLoop()) async {
        await self.init(handlers: [handler], loop: loop)
    }

    /// Create a new instance.
    ///
    /// During creation it will automatically also register itself on the ``NIOAsyncTestingEventLoop``.
    ///
    /// - parameters:
    ///     - handlers: The `ChannelHandler`s to add to the `ChannelPipeline` before register.
    ///     - loop: The ``NIOAsyncTestingEventLoop`` to use.
    public convenience init(handlers: [ChannelHandler], loop: NIOAsyncTestingEventLoop = NIOAsyncTestingEventLoop()) async {
        self.init(loop: loop)

        try! await self._pipeline.addHandlers(handlers)

        // This will never throw...
        try! await self.register()
    }

    /// Asynchronously closes the ``NIOAsyncTestingChannel``.
    ///
    /// Errors in the ``NIOAsyncTestingChannel`` can be consumed using ``throwIfErrorCaught()``.
    ///
    /// - parameters:
    ///     - acceptAlreadyClosed: Whether ``finish()`` should throw if the ``NIOAsyncTestingChannel`` has been previously `close`d.
    /// - returns: The ``LeftOverState`` of the ``NIOAsyncTestingChannel``. If all the inbound and outbound events have been
    ///            consumed (using ``readInbound(as:)`` / ``readOutbound(as:)``) and there are no pending outbound events (unflushed
    ///            writes) this will be ``LeftOverState/clean``. If there are any unconsumed inbound, outbound, or pending outbound
    ///            events, the ``NIOAsyncTestingChannel`` will returns those as ``LeftOverState/leftOvers(inbound:outbound:pendingOutbound:)``.
    public func finish(acceptAlreadyClosed: Bool) async throws -> LeftOverState {
        do {
            try await self.close().get()
        } catch let error as ChannelError {
            guard error == .alreadyClosed && acceptAlreadyClosed else {
                throw error
            }
        }

        // This can never actually throw.
        try! await self.testingEventLoop.executeInContext {
            self.testingEventLoop.drainScheduledTasksByRunningAllCurrentlyScheduledTasks()
        }
        await self.testingEventLoop.run()
        try await throwIfErrorCaught()

        // This can never actually throw.
        return try! await self.testingEventLoop.executeInContext {
            let c = self.channelcore!
            if c.outboundBuffer.isEmpty && c.inboundBuffer.isEmpty && c.pendingOutboundBuffer.isEmpty {
                return .clean
            } else {
                return .leftOvers(inbound: c.inboundBuffer,
                                  outbound: c.outboundBuffer,
                                  pendingOutbound: c.pendingOutboundBuffer.map { $0.0 })
            }
        }
    }

    /// Asynchronously closes the ``NIOAsyncTestingChannel``.
    ///
    /// This method will throw if the `Channel` hit any unconsumed errors or if the `close` fails. Errors in the
    /// ``NIOAsyncTestingChannel`` can be consumed using ``throwIfErrorCaught()``.
    ///
    /// - returns: The ``LeftOverState`` of the ``NIOAsyncTestingChannel``. If all the inbound and outbound events have been
    ///            consumed (using ``readInbound(as:)`` / ``readOutbound(as:)``) and there are no pending outbound events (unflushed
    ///            writes) this will be ``LeftOverState/clean``. If there are any unconsumed inbound, outbound, or pending outbound
    ///            events, the ``NIOAsyncTestingChannel`` will returns those as ``LeftOverState/leftOvers(inbound:outbound:pendingOutbound:)``.
    public func finish() async throws -> LeftOverState {
        return try await self.finish(acceptAlreadyClosed: false)
    }

    /// If available, this method reads one element of type `T` out of the ``NIOAsyncTestingChannel``'s outbound buffer. If the
    /// first element was of a different type than requested, ``WrongTypeError`` will be thrown, if there
    /// are no elements in the outbound buffer, `nil` will be returned.
    ///
    /// Data hits the ``NIOAsyncTestingChannel``'s outbound buffer when data was written using `write`, then `flush`ed, and
    /// then travelled the `ChannelPipeline` all the way to the front. For data to hit the outbound buffer, the very
    /// first `ChannelHandler` must have written and flushed it either explicitly (by calling
    /// `ChannelHandlerContext.write` and `flush`) or implicitly by not implementing `write`/`flush`.
    ///
    /// - note: Outbound events travel the `ChannelPipeline` _back to front_.
    /// - note: ``NIOAsyncTestingChannel/writeOutbound(_:)`` will `write` data through the `ChannelPipeline`, starting with last
    ///         `ChannelHandler`.
    @inlinable
    public func readOutbound<T: Sendable>(as type: T.Type = T.self) async throws -> T? {
        try await self.testingEventLoop.executeInContext {
            try self._readFromBuffer(buffer: &self.channelcore.outboundBuffer)
        }
    }

    /// This method is similar to ``NIOAsyncTestingChannel/readOutbound(as:)`` but will wait if the outbound buffer is empty.
    /// If available, this method reads one element of type `T` out of the ``NIOAsyncTestingChannel``'s outbound buffer. If the
    /// first element was of a different type than requested, ``WrongTypeError`` will be thrown, if there
    /// are no elements in the outbound buffer, `nil` will be returned.
    ///
    /// Data hits the ``NIOAsyncTestingChannel``'s outbound buffer when data was written using `write`, then `flush`ed, and
    /// then travelled the `ChannelPipeline` all the way to the front. For data to hit the outbound buffer, the very
    /// first `ChannelHandler` must have written and flushed it either explicitly (by calling
    /// `ChannelHandlerContext.write` and `flush`) or implicitly by not implementing `write`/`flush`.
    ///
    /// - note: Outbound events travel the `ChannelPipeline` _back to front_.
    /// - note: ``NIOAsyncTestingChannel/writeOutbound(_:)`` will `write` data through the `ChannelPipeline`, starting with last
    ///         `ChannelHandler`.
    public func waitForOutboundWrite<T: Sendable>(as type: T.Type = T.self) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            self.testingEventLoop.execute {
                do {
                    if let element: T = try self._readFromBuffer(buffer: &self.channelcore.outboundBuffer) {
                        continuation.resume(returning: element)
                        return
                    }
                    self.channelcore.outboundBufferConsumer.append { element in
                        continuation.resume(with: Result {
                            try self._cast(element)
                        })
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// If available, this method reads one element of type `T` out of the ``NIOAsyncTestingChannel``'s inbound buffer. If the
    /// first element was of a different type than requested, ``WrongTypeError`` will be thrown, if there
    /// are no elements in the outbound buffer, `nil` will be returned.
    ///
    /// Data hits the ``NIOAsyncTestingChannel``'s inbound buffer when data was send through the pipeline using `fireChannelRead`
    /// and then travelled the `ChannelPipeline` all the way to the back. For data to hit the inbound buffer, the
    /// last `ChannelHandler` must have send the event either explicitly (by calling
    /// `ChannelHandlerContext.fireChannelRead`) or implicitly by not implementing `channelRead`.
    ///
    /// - note: ``NIOAsyncTestingChannel/writeInbound(_:)`` will fire data through the `ChannelPipeline` using `fireChannelRead`.
    @inlinable
    public func readInbound<T: Sendable>(as type: T.Type = T.self) async throws -> T? {
        try await self.testingEventLoop.executeInContext {
            try self._readFromBuffer(buffer: &self.channelcore.inboundBuffer)
        }
    }

    /// This method is similar to ``NIOAsyncTestingChannel/readInbound(as:)`` but will wait if the inbound buffer is empty.
    /// If available, this method reads one element of type `T` out of the ``NIOAsyncTestingChannel``'s inbound buffer. If the
    /// first element was of a different type than requested, ``WrongTypeError`` will be thrown, if there
    /// are no elements in the outbound buffer, this method will wait until an element is in the inbound buffer.
    ///
    /// Data hits the ``NIOAsyncTestingChannel``'s inbound buffer when data was send through the pipeline using `fireChannelRead`
    /// and then travelled the `ChannelPipeline` all the way to the back. For data to hit the inbound buffer, the
    /// last `ChannelHandler` must have send the event either explicitly (by calling
    /// `ChannelHandlerContext.fireChannelRead`) or implicitly by not implementing `channelRead`.
    ///
    /// - note: ``NIOAsyncTestingChannel/writeInbound(_:)`` will fire data through the `ChannelPipeline` using `fireChannelRead`.
    public func waitForInboundWrite<T: Sendable>(as type: T.Type = T.self) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            self.testingEventLoop.execute {
                do {
                    if let element: T = try self._readFromBuffer(buffer: &self.channelcore.inboundBuffer) {
                        continuation.resume(returning: element)
                        return
                    }
                    self.channelcore.inboundBufferConsumer.append { element in
                        continuation.resume(with: Result {
                            try self._cast(element)
                        })
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Sends an inbound `channelRead` event followed by a `channelReadComplete` event through the `ChannelPipeline`.
    ///
    /// The immediate effect being that the first `ChannelInboundHandler` will get its `channelRead` method called
    /// with the data you provide.
    ///
    /// - parameters:
    ///    - data: The data to fire through the pipeline.
    /// - returns: The state of the inbound buffer which contains all the events that travelled the `ChannelPipeline`
    //             all the way.
    @inlinable
    @discardableResult public func writeInbound<T: Sendable>(_ data: T) async throws -> BufferState {
        try await self.testingEventLoop.executeInContext {
            self.pipeline.fireChannelRead(NIOAny(data))
            self.pipeline.fireChannelReadComplete()
            try self._throwIfErrorCaught()
            return self.channelcore.inboundBuffer.isEmpty ? .empty : .full(self.channelcore.inboundBuffer)
        }
    }

    /// Sends an outbound `writeAndFlush` event through the `ChannelPipeline`.
    ///
    /// The immediate effect being that the first `ChannelOutboundHandler` will get its `write` method called
    /// with the data you provide. Note that the first `ChannelOutboundHandler` in the pipeline is the _last_ handler
    /// because outbound events travel the pipeline from back to front.
    ///
    /// - parameters:
    ///    - data: The data to fire through the pipeline.
    /// - returns: The state of the outbound buffer which contains all the events that travelled the `ChannelPipeline`
    //             all the way.
    @inlinable
    @discardableResult public func writeOutbound<T: Sendable>(_ data: T) async throws -> BufferState {
        try await self.writeAndFlush(NIOAny(data))

        return try await self.testingEventLoop.executeInContext {
            return self.channelcore.outboundBuffer.isEmpty ? .empty : .full(self.channelcore.outboundBuffer)
        }
    }

    /// This method will throw the error that is stored in the ``NIOAsyncTestingChannel`` if any.
    ///
    /// The ``NIOAsyncTestingChannel`` will store an error if some error travels the `ChannelPipeline` all the way past its end.
    public func throwIfErrorCaught() async throws {
        try await self.testingEventLoop.executeInContext {
            try self._throwIfErrorCaught()
        }
    }

    @usableFromInline
    func _throwIfErrorCaught() throws {
        self.testingEventLoop.preconditionInEventLoop()
        if let error = self.channelcore.error {
            self.channelcore.error = nil
            throw error
        }
    }


    @inlinable
    func _readFromBuffer<T>(buffer: inout CircularBuffer<NIOAny>) throws -> T? {
        self.testingEventLoop.preconditionInEventLoop()

        if buffer.isEmpty {
            return nil
        }
        return try self._cast(buffer.removeFirst(), to: T.self)
    }

    @inlinable
    func _cast<T>(_ element: NIOAny, to: T.Type = T.self) throws -> T {
        guard let t = self._channelCore.tryUnwrapData(element, as: T.self) else {
            throw WrongTypeError(expected: T.self, actual: type(of: self._channelCore.tryUnwrapData(element, as: Any.self)!))
        }
        return t
    }

    /// - see: `Channel.setOption`
    @inlinable
    public func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) -> EventLoopFuture<Void> {
        if self.eventLoop.inEventLoop {
            self.setOptionSync(option, value: value)
            return self.eventLoop.makeSucceededVoidFuture()
        } else {
            return self.eventLoop.submit { self.setOptionSync(option, value: value) }
        }
    }

    @inlinable
    internal func setOptionSync<Option: ChannelOption>(_ option: Option, value: Option.Value) {
        if option is ChannelOptions.Types.AllowRemoteHalfClosureOption {
            self.allowRemoteHalfClosure = value as! Bool
            return
        }
        // No other options supported
        fatalError("option not supported")
    }

    /// - see: `Channel.getOption`
    @inlinable
    public func getOption<Option: ChannelOption>(_ option: Option) -> EventLoopFuture<Option.Value>  {
        if self.eventLoop.inEventLoop {
            return self.eventLoop.makeSucceededFuture(self.getOptionSync(option))
        } else {
            return self.eventLoop.submit { self.getOptionSync(option) }
        }
    }

    @inlinable
    internal func getOptionSync<Option: ChannelOption>(_ option: Option) -> Option.Value {
        if option is ChannelOptions.Types.AutoReadOption {
            return true as! Option.Value
        }
        if option is ChannelOptions.Types.AllowRemoteHalfClosureOption {
            return self.allowRemoteHalfClosure as! Option.Value
        }
        fatalError("option \(option) not supported")
    }

    /// Fires the (outbound) `bind` event through the `ChannelPipeline`. If the event hits the ``NIOAsyncTestingChannel`` which
    /// happens when it travels the `ChannelPipeline` all the way to the front, this will also set the
    /// ``NIOAsyncTestingChannel``'s ``localAddress``.
    ///
    /// - parameters:
    ///     - address: The address to fake-bind to.
    ///     - promise: The `EventLoopPromise` which will be fulfilled when the fake-bind operation has been done.
    public func bind(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.futureResult.whenSuccess {
            self.localAddress = address
        }
        if self.eventLoop.inEventLoop {
            self.pipeline.bind(to: address, promise: promise)
        } else {
            self.eventLoop.execute {
                self.pipeline.bind(to: address, promise: promise)
            }
        }
    }

    /// Fires the (outbound) `connect` event through the `ChannelPipeline`. If the event hits the ``NIOAsyncTestingChannel``
    /// which happens when it travels the `ChannelPipeline` all the way to the front, this will also set the
    /// ``NIOAsyncTestingChannel``'s ``remoteAddress``.
    ///
    /// - parameters:
    ///     - address: The address to fake-bind to.
    ///     - promise: The `EventLoopPromise` which will be fulfilled when the fake-bind operation has been done.
    public func connect(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.futureResult.whenSuccess {
            self.remoteAddress = address
        }
        if self.eventLoop.inEventLoop {
            self.pipeline.connect(to: address, promise: promise)
        } else {
            self.eventLoop.execute {
                self.pipeline.connect(to: address, promise: promise)
            }
        }
    }

    public struct SynchronousOptions: NIOSynchronousChannelOptions {
        @usableFromInline
        internal let channel: NIOAsyncTestingChannel

        fileprivate init(channel: NIOAsyncTestingChannel) {
            self.channel = channel
        }

        @inlinable
        public func setOption<Option: ChannelOption>(_ option: Option, value: Option.Value) throws {
            self.channel.eventLoop.preconditionInEventLoop()
            self.channel.setOptionSync(option, value: value)
        }

        @inlinable
        public func getOption<Option: ChannelOption>(_ option: Option) throws -> Option.Value {
            self.channel.eventLoop.preconditionInEventLoop()
            return self.channel.getOptionSync(option)
        }
    }

    public final var syncOptions: NIOSynchronousChannelOptions? {
        return SynchronousOptions(channel: self)
    }
}

// MARK: Unchecked sendable
//
// Both of these types are unchecked Sendable because strictly, they aren't. This is
// because they contain NIOAny, a non-Sendable type. In this instance, we tolerate the moving
// of this object across threads because in the overwhelming majority of cases the data types
// in a channel pipeline _are_ `Sendable`, and because these objects only carry NIOAnys in cases
// where the `Channel` itself no longer holds a reference to these objects.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension NIOAsyncTestingChannel.LeftOverState: @unchecked Sendable { }

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension NIOAsyncTestingChannel.BufferState: @unchecked Sendable { }
