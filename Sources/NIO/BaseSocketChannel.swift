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

import NIOConcurrencyHelpers

private struct SocketChannelLifecycleManager {
    // MARK: Types
    private enum State {
        case fresh
        case preRegistered // register() has been run but the selector doesn't know about it yet
        case fullyRegistered // fully registered, ie. the selector knows about it
        case activated
        case closed
    }

    private enum Event {
        case activate
        case beginRegistration
        case finishRegistration
        case close
    }

    // MARK: properties
    private let eventLoop: EventLoop
    // this is queried from the Channel, ie. must be thread-safe
    internal let isActiveAtomic: Atomic<Bool>
    // these are only to be accessed on the EventLoop

    // have we seen the `.readEOF` notification
    // note: this can be `false` on a deactivated channel, we might just have torn it down.
    var hasSeenEOFNotification: Bool = false

    private var currentState: State = .fresh {
        didSet {
            assert(self.eventLoop.inEventLoop)
            switch (oldValue, self.currentState) {
            case (_, .activated):
                self.isActiveAtomic.store(true)
            case (.activated, _):
                self.isActiveAtomic.store(false)
            default:
                ()
            }
        }
    }

    // MARK: API
    // isActiveAtomic needs to be injected as it's accessed from arbitrary threads and `SocketChannelLifecycleManager` is usually held mutable
    internal init(eventLoop: EventLoop, isActiveAtomic: Atomic<Bool>) {
        self.eventLoop = eventLoop
        self.isActiveAtomic = isActiveAtomic
    }

    // this is called from Channel's deinit, so don't assert we're on the EventLoop!
    internal var canBeDestroyed: Bool {
        return self.currentState == .closed
    }

    @inline(__always) // we need to return a closure here and to not suffer from a potential allocation for that this must be inlined
    internal mutating func beginRegistration(promise: EventLoopPromise<Void>?) -> ((ChannelPipeline) -> Void) {
        return self.moveState(event: .beginRegistration, promise: promise)
    }

    @inline(__always) // we need to return a closure here and to not suffer from a potential allocation for that this must be inlined
    internal mutating func finishRegistration(promise: EventLoopPromise<Void>?) -> ((ChannelPipeline) -> Void) {
        return self.moveState(event: .finishRegistration, promise: promise)
    }

    @inline(__always) // we need to return a closure here and to not suffer from a potential allocation for that this must be inlined
    internal mutating func close(promise: EventLoopPromise<Void>?) -> ((ChannelPipeline) -> Void) {
        return self.moveState(event: .close, promise: promise)
    }

    @inline(__always) // we need to return a closure here and to not suffer from a potential allocation for that this must be inlined
    internal mutating func activate(promise: EventLoopPromise<Void>?) -> ((ChannelPipeline) -> Void) {
        return self.moveState(event: .activate, promise: promise)
    }

    // MARK: private API
    @inline(__always) // we need to return a closure here and to not suffer from a potential allocation for that this must be inlined
    private mutating func moveState(event: Event, promise: EventLoopPromise<Void>?) -> ((ChannelPipeline) -> Void) {
        assert(self.eventLoop.inEventLoop)

        switch (self.currentState, event) {
        // origin: .fresh
        case (.fresh, .beginRegistration):
            return self.doStateTransfer(newState: .preRegistered, promise: promise) { pipeline in
                pipeline.fireChannelRegistered0()
            }

        case (.fresh, .close):
            return self.doStateTransfer(newState: .closed, promise: promise) { (_: ChannelPipeline) in }

        // origin: .preRegistered
        case (.preRegistered, .finishRegistration):
            return self.doStateTransfer(newState: .fullyRegistered, promise: promise) { pipeline in
                // we don't tell the user about this
            }

        // origin: .fullyRegistered
        case (.fullyRegistered, .activate):
            return self.doStateTransfer(newState: .activated, promise: promise) { pipeline in
                pipeline.fireChannelActive0()
            }

        // origin: .preRegistered || .fullyRegistered
        case (.preRegistered, .close), (.fullyRegistered, .close):
            return self.doStateTransfer(newState: .closed, promise: promise) { pipeline in
                pipeline.fireChannelUnregistered0()
            }

        // origin: .activated
        case (.activated, .close):
            return self.doStateTransfer(newState: .closed, promise: promise) { pipeline in
                pipeline.fireChannelInactive0()
                pipeline.fireChannelUnregistered0()
            }

        // bad transitions
        case (.fresh, .activate),                  // should go through .registered first
             (.preRegistered, .activate),       // need to first be fully registered
             (.preRegistered, .beginRegistration), // already registered
             (.fullyRegistered, .beginRegistration),  // already registered
             (.activated, .activate),              // already activated
             (.activated, .beginRegistration),        // already fully registered (and activated)
             (.activated, .finishRegistration),         // already fully registered (and activated)
             (.fullyRegistered, .finishRegistration),   // already fully registered
             (.fresh, .finishRegistration),             // need to register lazily first
             (.closed, _):                         // already closed
            self.badTransition(event: event)
        }
    }

    private func badTransition(event: Event) -> Never {
        fatalError("illegal transition: state=\(self.currentState), event=\(event)")
    }

    @inline(__always) // we need to return a closure here and to not suffer from a potential allocation for that this must be inlined
    private mutating func doStateTransfer(newState: State, promise: EventLoopPromise<Void>?, _ callouts: @escaping (ChannelPipeline) -> Void) -> ((ChannelPipeline) -> Void) {
        self.currentState = newState

        return { pipeline in
            promise?.succeed(result: ())
            callouts(pipeline)
        }
    }

    // MARK: convenience properties
    internal var isActive: Bool {
        assert(self.eventLoop.inEventLoop)
        return self.currentState == .activated
    }

    internal var isPreRegistered: Bool {
        assert(self.eventLoop.inEventLoop)
        switch self.currentState {
        case .fresh, .closed:
            return false
        case .preRegistered, .fullyRegistered, .activated:
            return true
        }
    }

    internal var isRegisteredFully: Bool {
        assert(self.eventLoop.inEventLoop)
        switch self.currentState {
        case .fresh, .closed, .preRegistered:
            return false
        case .fullyRegistered, .activated:
            return true
        }
    }

    /// Returns whether the underlying file descriptor is open. This property will always be true (even before registration)
    /// until the Channel is closed.
    internal var isOpen: Bool {
        assert(self.eventLoop.inEventLoop)
        return self.currentState != .closed
    }
}

/// The base class for all socket-based channels in NIO.
///
/// There are many types of specialised socket-based channel in NIO. Each of these
/// has different logic regarding how exactly they read from and write to the network.
/// However, they share a great deal of common logic around the managing of their
/// file descriptors.
///
/// For this reason, `BaseSocketChannel` exists to provide a common core implementation of
/// the `SelectableChannel` protocol. It uses a number of private functions to provide hooks
/// for subclasses to implement the specific logic to handle their writes and reads.
class BaseSocketChannel<T: BaseSocket>: SelectableChannel, ChannelCore {
    typealias SelectableType = T

    // MARK: Stored Properties
    // Visible to access from EventLoop directly
    public let parent: Channel?
    internal let socket: T
    private let closePromise: EventLoopPromise<Void>
    private let selectableEventLoop: SelectableEventLoop
    private let addressesCached: AtomicBox<Box<(local:SocketAddress?, remote:SocketAddress?)>> = AtomicBox(value: Box((local: nil, remote: nil)))
    private let bufferAllocatorCached: AtomicBox<Box<ByteBufferAllocator>>
    private let isActiveAtomic: Atomic<Bool> = Atomic(value: false)
    private var _pipeline: ChannelPipeline! = nil // this is really a constant (set in .init) but needs `self` to be constructed and therefore a `var`. Do not change as this needs to accessed from arbitrary threads

    internal var interestedEvent: SelectorEventSet = [.readEOF, .reset] {
        didSet {
            assert(self.interestedEvent.contains(.reset), "impossible to unregister for reset")
        }
    }

    var readPending = false
    var pendingConnect: EventLoopPromise<Void>?
    var recvAllocator: RecvByteBufferAllocator
    var maxMessagesPerRead: UInt = 4

    private var inFlushNow: Bool = false // Guard against re-entrance of flushNow() method.
    private var autoRead: Bool = true
    private var lifecycleManager: SocketChannelLifecycleManager {
        didSet {
            assert(self.eventLoop.inEventLoop)
        }
    }

    private var bufferAllocator: ByteBufferAllocator = ByteBufferAllocator() {
        didSet {
            assert(self.eventLoop.inEventLoop)
            self.bufferAllocatorCached.store(Box(self.bufferAllocator))
        }
    }

    // MARK: Datatypes

    /// Indicates if a selectable should registered or not for IO notifications.
    enum IONotificationState {
        /// We should be registered for IO notifications.
        case register

        /// We should not be registered for IO notifications.
        case unregister
    }

    enum ReadResult {
        /// Nothing was read by the read operation.
        case none

        /// Some data was read by the read operation.
        case some
    }

    /// Returned by the `private func readable0()` to inform the caller about the current state of the underlying read stream.
    /// This is mostly useful when receiving `.readEOF` as we then need to drain the read stream fully (ie. until we receive EOF or error of course)
    private enum ReadStreamState {
        /// Everything seems normal
        case normal(ReadResult)

        /// We saw EOF.
        case eof

        /// A read error was received.
        case error
    }

    // MARK: Computed Properties
    public final var _unsafe: ChannelCore { return self }

    // This is `Channel` API so must be thread-safe.
    public final var localAddress: SocketAddress? {
        return self.addressesCached.load().value.local
    }

    // This is `Channel` API so must be thread-safe.
    public final var remoteAddress: SocketAddress? {
        return self.addressesCached.load().value.remote
    }

    /// `false` if the whole `Channel` is closed and so no more IO operation can be done.
    var isOpen: Bool {
        assert(eventLoop.inEventLoop)
        return self.lifecycleManager.isOpen
    }

    var isRegistered: Bool {
        assert(self.eventLoop.inEventLoop)
        return self.lifecycleManager.isPreRegistered
    }

    internal var selectable: T {
        return self.socket
    }

    // This is `Channel` API so must be thread-safe.
    public var isActive: Bool {
        return self.isActiveAtomic.load()
    }

    // This is `Channel` API so must be thread-safe.
    public final var closeFuture: EventLoopFuture<Void> {
        return self.closePromise.futureResult
    }

    public final var eventLoop: EventLoop {
        return selectableEventLoop
    }

    // This is `Channel` API so must be thread-safe.
    public var isWritable: Bool {
        return true
    }

    // This is `Channel` API so must be thread-safe.
    public final var allocator: ByteBufferAllocator {
        if eventLoop.inEventLoop {
            return bufferAllocator
        } else {
            return self.bufferAllocatorCached.load().value
        }
    }

    // This is `Channel` API so must be thread-safe.
    public final var pipeline: ChannelPipeline {
        return self._pipeline
    }

    // MARK: Methods to override in subclasses.
    func writeToSocket() throws -> OverallWriteResult {
        fatalError("must be overridden")
    }

    /// Provides the registration for this selector. Must be implemented by subclasses.
    func registrationFor(interested: SelectorEventSet) -> NIORegistration {
        fatalError("must override")
    }

    /// Read data from the underlying socket and dispatch it to the `ChannelPipeline`
    ///
    /// - returns: `true` if any data was read, `false` otherwise.
    @discardableResult func readFromSocket() throws -> ReadResult {
        fatalError("this must be overridden by sub class")
    }

    /// Begin connection of the underlying socket.
    ///
    /// - parameters:
    ///     - to: The `SocketAddress` to connect to.
    /// - returns: `true` if the socket connected synchronously, `false` otherwise.
    func connectSocket(to address: SocketAddress) throws -> Bool {
        fatalError("this must be overridden by sub class")
    }

    /// Make any state changes needed to complete the connection process.
    func finishConnectSocket() throws {
        fatalError("this must be overridden by sub class")
    }

    /// Buffer a write in preparation for a flush.
    func bufferPendingWrite(data: NIOAny, promise: EventLoopPromise<Void>?) {
        fatalError("this must be overridden by sub class")
    }

    /// Mark a flush point. This is called when flush is received, and instructs
    /// the implementation to record the flush.
    func markFlushPoint() {
        fatalError("this must be overridden by sub class")
    }

    /// Called when closing, to instruct the specific implementation to discard all pending
    /// writes.
    func cancelWritesOnClose(error: Error) {
        fatalError("this must be overridden by sub class")
    }

    // MARK: Common base socket logic.
    init(socket: T, parent: Channel? = nil, eventLoop: SelectableEventLoop, recvAllocator: RecvByteBufferAllocator) throws {
        self.bufferAllocatorCached = AtomicBox(value: Box(self.bufferAllocator))
        self.socket = socket
        self.selectableEventLoop = eventLoop
        self.closePromise = eventLoop.newPromise()
        self.parent = parent
        self.recvAllocator = recvAllocator
        self.lifecycleManager = SocketChannelLifecycleManager(eventLoop: eventLoop, isActiveAtomic: self.isActiveAtomic)
        // As the socket may already be connected we should ensure we start with the correct addresses cached.
        self._pipeline = ChannelPipeline(channel: self)
        self.addressesCached.store(Box((local: try? socket.localAddress(), remote: try? socket.remoteAddress())))
    }

    deinit {
        assert(self.lifecycleManager.canBeDestroyed,
               "leak of open Channel, state: \(String(describing: self.lifecycleManager))")
    }

    public final func localAddress0() throws -> SocketAddress {
        assert(self.eventLoop.inEventLoop)
        guard self.isOpen else {
            throw ChannelError.ioOnClosedChannel
        }
        return try self.socket.localAddress()
    }

    public final func remoteAddress0() throws -> SocketAddress {
        assert(self.eventLoop.inEventLoop)
        guard self.isOpen else {
            throw ChannelError.ioOnClosedChannel
        }
        return try self.socket.remoteAddress()
    }

    /// Flush data to the underlying socket and return if this socket needs to be registered for write notifications.
    ///
    /// - returns: If this socket should be registered for write notifications. Ie. `IONotificationState.register` if _not_ all data could be written, so notifications are necessary; and `IONotificationState.unregister` if everything was written and we don't need to be notified about writability at the moment.
    func flushNow() -> IONotificationState {
        assert(self.eventLoop.inEventLoop)
        // Guard against re-entry as data that will be put into `pendingWrites` will just be picked up by
        // `writeToSocket`.
        guard !self.inFlushNow && self.isOpen else {
            return .unregister
        }

        defer {
            inFlushNow = false
        }
        inFlushNow = true

        do {
            assert(self.lifecycleManager.isActive)
            switch try self.writeToSocket() {
            case .couldNotWriteEverything:
                return .register
            case .writtenCompletely:
                return .unregister
            }
        } catch let err {
            // If there is a write error we should try drain the inbound before closing the socket as there may be some data pending.
            // We ignore any error that is thrown as we will use the original err to close the channel and notify the user.
            if readIfNeeded0() {
                assert(self.lifecycleManager.isActive)

                // We need to continue reading until there is nothing more to be read from the socket as we will not have another chance to drain it.
                while let read = try? readFromSocket(), read == .some {
                    assert(self.lifecycleManager.isActive)
                    pipeline.fireChannelReadComplete()
                }
            }

            close0(error: err, mode: .all, promise: nil)

            // we handled all writes
            return .unregister
        }
    }


    public final func setOption<T: ChannelOption>(option: T, value: T.OptionType) -> EventLoopFuture<Void> {
        if eventLoop.inEventLoop {
            let promise: EventLoopPromise<Void> = eventLoop.newPromise()
            executeAndComplete(promise) { try setOption0(option: option, value: value) }
            return promise.futureResult
        } else {
            return eventLoop.submit { try self.setOption0(option: option, value: value) }
        }
    }

    func setOption0<T: ChannelOption>(option: T, value: T.OptionType) throws {
        assert(eventLoop.inEventLoop)

        guard isOpen else {
            throw ChannelError.ioOnClosedChannel
        }

        switch option {
        case _ as SocketOption:
            let (level, name) = option.value as! (SocketOptionLevel, SocketOptionName)
            try socket.setOption(level: Int32(level), name: name, value: value)
        case _ as AllocatorOption:
            bufferAllocator = value as! ByteBufferAllocator
        case _ as RecvAllocatorOption:
            recvAllocator = value as! RecvByteBufferAllocator
        case _ as AutoReadOption:
            let auto = value as! Bool
            let old = self.autoRead
            self.autoRead = auto

            // We only want to call read0() or pauseRead0() if we already registered to the EventLoop if not this will be automatically done
            // once register0 is called. Beside this we also only need to do it when the value actually change.
            if self.lifecycleManager.isPreRegistered && old != auto {
                if auto {
                    read0()
                } else {
                    pauseRead0()
                }
            }
        case _ as MaxMessagesPerReadOption:
            maxMessagesPerRead = value as! UInt
        default:
            fatalError("option \(option) not supported")
        }
    }

    public func getOption<T>(option: T) -> EventLoopFuture<T.OptionType> where T: ChannelOption {
        if eventLoop.inEventLoop {
            do {
                return eventLoop.newSucceededFuture(result: try getOption0(option: option))
            } catch {
                return eventLoop.newFailedFuture(error: error)
            }
        } else {
            return eventLoop.submit { try self.getOption0(option: option) }
        }
    }

    func getOption0<T: ChannelOption>(option: T) throws -> T.OptionType {
        assert(eventLoop.inEventLoop)

        guard isOpen else {
            throw ChannelError.ioOnClosedChannel
        }

        switch option {
        case _ as SocketOption:
            let (level, name) = option.value as! (SocketOptionLevel, SocketOptionName)
            return try socket.getOption(level: Int32(level), name: name)
        case _ as AllocatorOption:
            return bufferAllocator as! T.OptionType
        case _ as RecvAllocatorOption:
            return recvAllocator as! T.OptionType
        case _ as AutoReadOption:
            return autoRead as! T.OptionType
        case _ as MaxMessagesPerReadOption:
            return maxMessagesPerRead as! T.OptionType
        default:
            fatalError("option \(option) not supported")
        }
    }

    /// Triggers a `ChannelPipeline.read()` if `autoRead` is enabled.`
    ///
    /// - returns: `true` if `readPending` is `true`, `false` otherwise.
    @discardableResult func readIfNeeded0() -> Bool {
        assert(eventLoop.inEventLoop)
        if !self.lifecycleManager.isActive {
            return false
        }

        if !readPending && autoRead {
            pipeline.read0()
        }
        return readPending
    }

    // Methods invoked from the HeadHandler of the ChannelPipeline
    public func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)

        guard self.isOpen else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }
        guard self.lifecycleManager.isPreRegistered else {
            promise?.fail(error: ChannelLifecycleError.inappropriateOperationForState)
            return
        }

        executeAndComplete(promise) {
            try socket.bind(to: address)
            self.updateCachedAddressesFromSocket(updateRemote: false)
        }
    }

    public final func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)

        guard self.isOpen else {
            // Channel was already closed, fail the promise and not even queue it.
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }

        guard self.lifecycleManager.isActive else {
            promise?.fail(error: ChannelLifecycleError.inappropriateOperationForState)
            return
        }

        bufferPendingWrite(data: data, promise: promise)
    }

    private func registerForWritable() {
        assert(eventLoop.inEventLoop)

        guard !self.interestedEvent.contains(.write) else {
            // nothing to do if we were previously interested in write
            return
        }
        self.safeReregister(interested: self.interestedEvent.union(.write))
    }

    func unregisterForWritable() {
        assert(eventLoop.inEventLoop)

        guard self.interestedEvent.contains(.write) else {
            // nothing to do if we were not previously interested in write
            return
        }
        self.safeReregister(interested: self.interestedEvent.subtracting(.write))
    }

    public final func flush0() {
        assert(eventLoop.inEventLoop)

        guard self.isOpen else {
            return
        }

        self.markFlushPoint()

        guard self.lifecycleManager.isActive else {
            return
        }

        if !isWritePending() && flushNow() == .register {
            assert(self.lifecycleManager.isPreRegistered)
            registerForWritable()
        }
    }

    public func read0() {
        assert(eventLoop.inEventLoop)

        guard self.isOpen else {
            return
        }
        readPending = true

        if self.lifecycleManager.isPreRegistered {
            registerForReadable()
        }
    }

    private final func pauseRead0() {
        assert(eventLoop.inEventLoop)

        if self.lifecycleManager.isPreRegistered {
            unregisterForReadable()
        }
    }

    private final func registerForReadable() {
        assert(eventLoop.inEventLoop)
        assert(self.lifecycleManager.isRegisteredFully)

        guard !self.lifecycleManager.hasSeenEOFNotification else {
            // we have seen an EOF notification before so there's no point in registering for reads
            return
        }

        guard !self.interestedEvent.contains(.read) else {
            return
        }

        self.safeReregister(interested: self.interestedEvent.union(.read))
    }

    internal final func unregisterForReadable() {
        assert(eventLoop.inEventLoop)
        assert(self.lifecycleManager.isRegisteredFully)

        guard self.interestedEvent.contains(.read) else {
            return
        }

        self.safeReregister(interested: self.interestedEvent.subtracting(.read))
    }

    /// Closes the this `BaseChannelChannel` and fulfills `promise` with the result of the _close_ operation.
    /// So unless either the deregistration or the close itself fails, `promise` will be succeeded regardless of
    /// `error`. `error` is used to fail outstanding writes (if any) and the `connectPromise` if set.
    ///
    /// - parameters:
    ///    - error: The error to fail the outstanding (if any) writes/connect with.
    ///    - mode: The close mode, must be `.all` for `BaseSocketChannel`
    ///    - promise: The promise that gets notified about the result of the deregistration/close operations.
    public func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)

        guard self.isOpen else {
            promise?.fail(error: ChannelError.alreadyClosed)
            return
        }

        guard mode == .all else {
            promise?.fail(error: ChannelError.operationUnsupported)
            return
        }

        // === BEGIN: No user callouts ===

        // this is to register all error callouts as all the callouts must happen after we transition out state
        var errorCallouts: [(ChannelPipeline) -> Void] = []

        self.interestedEvent = .reset
        do {
            try selectableEventLoop.deregister(channel: self)
        } catch let err {
            errorCallouts.append { pipeline in
                pipeline.fireErrorCaught0(error: err)
            }
        }

        let p: EventLoopPromise<Void>?
        do {
            try socket.close()
            p = promise
        } catch {
            errorCallouts.append { (_: ChannelPipeline) in
                promise?.fail(error: error)
                // Set p to nil as we want to ensure we pass nil to becomeInactive0(...) so we not try to notify the promise again.
            }
            p = nil
        }

        // Transition our internal state.
        let callouts = self.lifecycleManager.close(promise: p)

        // === END: No user callouts (now that our state is reconciled, we can call out to user code.) ===

        // this must be the first to call out as it transitions the PendingWritesManager into the closed state
        // and we assert elsewhere that the PendingWritesManager has the same idea of 'open' as we have in here.
        self.cancelWritesOnClose(error: error)

        // this should be a no-op as we shouldn't have any
        errorCallouts.forEach {
            $0(self.pipeline)
        }

        if let connectPromise = self.pendingConnect {
            self.pendingConnect = nil
            connectPromise.fail(error: error)
        }

        callouts(self.pipeline)

        eventLoop.execute {
            // ensure this is executed in a delayed fashion as the users code may still traverse the pipeline
            self.pipeline.removeHandlers()

            self.closePromise.succeed(result: ())

            // Now reset the addresses as we notified all handlers / futures.
            self.unsetCachedAddressesFromSocket()
        }
    }


    public final func register0(promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)

        guard self.isOpen else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }

        guard !self.lifecycleManager.isPreRegistered else {
            promise?.fail(error: ChannelLifecycleError.inappropriateOperationForState)
            return
        }

        guard self.selectableEventLoop.isOpen else {
            let error = EventLoopError.shutdown
            self.pipeline.fireErrorCaught0(error: error)
            // `close0`'s error is about the result of the `close` operation, ...
            self.close0(error: error, mode: .all, promise: nil)
            // ... therefore we need to fail the registration `promise` separately.
            promise?.fail(error: error)
            return
        }

        // we can't fully register yet as epoll would give us EPOLLHUP if bind/connect wasn't called yet.
        self.lifecycleManager.beginRegistration(promise: promise)(self.pipeline)
    }

    public final func registerAlreadyConfigured0(promise: EventLoopPromise<Void>?) {
        assert(self.eventLoop.inEventLoop)
        assert(self.isOpen)
        assert(!self.lifecycleManager.isActive)
        let registerPromise: EventLoopPromise<Void> = self.eventLoop.newPromise()
        self.register0(promise: registerPromise)
        registerPromise.futureResult.whenFailure { (_: Error) in
            self.close(promise: nil)
        }
        if let promise = promise {
            registerPromise.futureResult.cascadeFailure(promise: promise)
        }

        if self.lifecycleManager.isPreRegistered {
            try! becomeFullyRegistered0()
            if self.lifecycleManager.isRegisteredFully {
                self.becomeActive0(promise: promise)
            }
        }
    }

    public final func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        promise?.succeed(result: ())
    }

    // Methods invoked from the EventLoop itself
    public final func writable() {
        assert(self.eventLoop.inEventLoop)
        assert(self.isOpen)

        self.finishConnect()  // If we were connecting, that has finished.
        if self.flushNow() == .unregister {
            // Everything was written or connect was complete
            self.finishWritable()
        }
    }

    private func finishConnect() {
        assert(eventLoop.inEventLoop)
        assert(self.lifecycleManager.isPreRegistered)

        if let connectPromise = self.pendingConnect {
            assert(!self.lifecycleManager.isActive)

            do {
                try self.finishConnectSocket()
            } catch {
                assert(!self.lifecycleManager.isActive)
                // close0 fails the connectPromise itself so no need to do it here
                self.close0(error: error, mode: .all, promise: nil)
                return
            }
            // now this has succeeded, becomeActive0 will actually fulfill this.
            self.pendingConnect = nil
            // We already know what the local address is.
            self.updateCachedAddressesFromSocket(updateLocal: false, updateRemote: true)
            self.becomeActive0(promise: connectPromise)
        } else {
            assert(self.lifecycleManager.isActive)
        }
    }

    private func finishWritable() {
        assert(eventLoop.inEventLoop)

        if self.isOpen {
            assert(self.lifecycleManager.isPreRegistered)
            self.unregisterForWritable()
        }
    }

    final func readEOF() {
        assert(!self.lifecycleManager.hasSeenEOFNotification)
        self.lifecycleManager.hasSeenEOFNotification = true

        // we can't be not active but still registered here; this would mean that we got a notification about a
        // channel before we're ready to receive them.
        assert(self.lifecycleManager.isRegisteredFully,
               "illegal state: \(self): active: \(self.lifecycleManager.isActive), registered: \(self.lifecycleManager.isRegisteredFully)")

        self.readEOF0()

        assert(!self.interestedEvent.contains(.read))
        assert(!self.interestedEvent.contains(.readEOF))
    }

    final func readEOF0() {
        if self.lifecycleManager.isRegisteredFully {
            // we're unregistering from `readEOF` here as we want this to be one-shot. We're then synchronously
            // reading all input until the EOF that we're guaranteed to see. After that `readEOF` becomes uninteresting
            // and would anyway fire constantly.
            self.safeReregister(interested: self.interestedEvent.subtracting(.readEOF))

            loop: while self.lifecycleManager.isActive {
                switch self.readable0() {
                case .eof:
                    // on EOF we stop the loop and we're done with our processing for `readEOF`.
                    // we could both be registered & active (if our channel supports half-closure) or unregistered & inactive (if it doesn't).
                    break loop
                case .error:
                    // we should be unregistered and inactive now (as `readable0` would've called close).
                    assert(!self.lifecycleManager.isActive)
                    assert(!self.lifecycleManager.isPreRegistered)
                    break loop
                case .normal(.none):
                    preconditionFailure("got .readEOF and read returned not reading any bytes, nor EOF.")
                case .normal(.some):
                    // normal, note that there is no guarantee we're still active (as the user might have closed in callout)
                    continue loop
                }
            }
        }
    }

    // this _needs_ to synchronously cause the fd to be unregistered because we cannot unregister from `reset`. In
    // other words: Failing to unregister the whole selector will cause NIO to spin at 100% CPU constantly delivering
    // the `reset` event.
    final func reset() {
        self.readEOF0()

        if self.socket.isOpen {
            assert(self.lifecycleManager.isPreRegistered)
            let error: IOError
            // if the socket is still registered (and therefore open), let's try to get the actual socket error from the socket
            do {
                let result: Int32 = try self.socket.getOption(level: SOL_SOCKET, name: SO_ERROR)
                if result != 0 {
                    // we have a socket error, let's forward
                    // this path will be executed on Linux (EPOLLERR) & Darwin (ev.fflags != 0)
                    error = IOError(errnoCode: result, reason: "connection reset (error set)")
                } else {
                    // we don't have a socket error, this must be connection reset without an error then
                    // this path should only be executed on Linux (EPOLLHUP, no EPOLLERR)
                    #if os(Linux)
                    let message: String = "connection reset (no error set)"
                    #else
                    let message: String = "BUG IN SwiftNIO (possibly #572), please report! Connection reset (no error set)."
                    #endif
                    error = IOError(errnoCode: ECONNRESET, reason: message)
                }
                self.close0(error: error, mode: .all, promise: nil)
            } catch {
                self.close0(error: error, mode: .all, promise: nil)
            }
        }
        assert(!self.lifecycleManager.isPreRegistered)
    }

    public final func readable() {
        assert(!self.lifecycleManager.hasSeenEOFNotification,
               "got a read notification after having already seen .readEOF")
        self.readable0()
    }

    @discardableResult
    private final func readable0() -> ReadStreamState {
        assert(eventLoop.inEventLoop)
        assert(self.lifecycleManager.isActive)

        defer {
            if self.isOpen && !self.readPending {
                unregisterForReadable()
            }
        }

        let readResult: ReadResult
        do {
            readResult = try readFromSocket()
        } catch let err {
            let readStreamState: ReadStreamState
            // ChannelError.eof is not something we want to fire through the pipeline as it just means the remote
            // peer closed / shutdown the connection.
            if let channelErr = err as? ChannelError, channelErr == ChannelError.eof {
                readStreamState = .eof
                // Directly call getOption0 as we are already on the EventLoop and so not need to create an extra future.
                if self.lifecycleManager.isActive, try! getOption0(option: ChannelOptions.allowRemoteHalfClosure) {
                    // If we want to allow half closure we will just mark the input side of the Channel
                    // as closed.
                    assert(self.lifecycleManager.isActive)
                    self.pipeline.fireChannelReadComplete0()
                    if self.shouldCloseOnReadError(err) {
                        self.close0(error: err, mode: .input, promise: nil)
                    }
                    self.readPending = false
                    return .eof
                }
            } else {
                readStreamState = .error
                self.pipeline.fireErrorCaught0(error: err)
            }

            // Call before triggering the close of the Channel.
            if self.lifecycleManager.isActive {
                self.pipeline.fireChannelReadComplete0()
            }

            if self.shouldCloseOnReadError(err) {
                self.close0(error: err, mode: .all, promise: nil)
            }

            return readStreamState
        }
        if self.lifecycleManager.isActive {
            self.pipeline.fireChannelReadComplete0()
        }
        self.readIfNeeded0()
        return .normal(readResult)
    }

    /// Returns `true` if the `Channel` should be closed as result of the given `Error` which happened during `readFromSocket`.
    ///
    /// - parameters:
    ///     - err: The `Error` which was thrown by `readFromSocket`.
    /// - returns: `true` if the `Channel` should be closed, `false` otherwise.
    func shouldCloseOnReadError(_ err: Error) -> Bool {
        return true
    }

    internal final func updateCachedAddressesFromSocket(updateLocal: Bool = true, updateRemote: Bool = true) {
        assert(self.eventLoop.inEventLoop)
        assert(updateLocal || updateRemote)
        let cached = addressesCached.load().value
        let local = updateLocal ? try? self.localAddress0() : cached.local
        let remote = updateRemote ? try? self.remoteAddress0() : cached.remote
        self.addressesCached.store(Box((local: local, remote: remote)))
    }

    internal final func unsetCachedAddressesFromSocket() {
        assert(self.eventLoop.inEventLoop)
        self.addressesCached.store(Box((local: nil, remote: nil)))
    }

    public final func connect0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)

        guard self.isOpen else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }

        guard pendingConnect == nil else {
            promise?.fail(error: ChannelError.connectPending)
            return
        }

        guard self.lifecycleManager.isPreRegistered else {
            promise?.fail(error: ChannelLifecycleError.inappropriateOperationForState)
            return
        }

        do {
            if try !self.connectSocket(to: address) {
                // We aren't connected, we'll get the remote address later.
                self.updateCachedAddressesFromSocket(updateLocal: true, updateRemote: false)
                if promise != nil {
                    self.pendingConnect = promise
                } else {
                    self.pendingConnect = eventLoop.newPromise()
                }
                try self.becomeFullyRegistered0()
                self.registerForWritable()
            } else {
                self.updateCachedAddressesFromSocket()
                self.becomeActive0(promise: promise)
            }
        } catch let error {
            assert(self.lifecycleManager.isPreRegistered)
            // We would like to have this assertion here, but we want to be able to go through this
            // code path in cases where connect() is being called on channels that are already active.
            //assert(!self.lifecycleManager.isActive)
            // We're going to set the promise as the pending connect promise, and let close0 fail it for us.
            self.pendingConnect = promise
            self.close0(error: error, mode: .all, promise: nil)
        }
    }

    public func channelRead0(_ data: NIOAny) {
        assert(self.lifecycleManager.isActive)
        // Do nothing by default
    }

    public func errorCaught0(error: Error) {
        // Do nothing
    }

    private func isWritePending() -> Bool {
        return self.interestedEvent.contains(.write)
    }

    private final func safeReregister(interested: SelectorEventSet) {
        assert(eventLoop.inEventLoop)
        assert(self.lifecycleManager.isRegisteredFully)

        guard self.isOpen else {
            assert(self.interestedEvent == .reset, "interestedEvent=\(self.interestedEvent) event though we're closed")
            return
        }
        if interested == interestedEvent {
            // we don't need to update and so cause a syscall if we already are registered with the correct event
            return
        }
        interestedEvent = interested
        do {
            try selectableEventLoop.reregister(channel: self)
        } catch let err {
            self.pipeline.fireErrorCaught0(error: err)
            self.close0(error: err, mode: .all, promise: nil)
        }
    }

    private func safeRegister(interested: SelectorEventSet) throws {
        assert(eventLoop.inEventLoop)
        assert(!self.lifecycleManager.isRegisteredFully)

        guard self.isOpen else {
            throw ChannelError.ioOnClosedChannel
        }

        self.interestedEvent = interested
        do {
            try self.selectableEventLoop.register(channel: self)
        } catch {
            self.pipeline.fireErrorCaught0(error: error)
            self.close0(error: error, mode: .all, promise: nil)
            throw error
        }
    }

    final func becomeFullyRegistered0() throws {
        assert(self.eventLoop.inEventLoop)
        assert(self.lifecycleManager.isPreRegistered)
        assert(!self.lifecycleManager.isRegisteredFully)

        // We always register with interested .none and will just trigger readIfNeeded0() later to re-register if needed.
        try self.safeRegister(interested: [.readEOF, .reset])
        self.lifecycleManager.finishRegistration(promise: nil)(self.pipeline)
    }

    final func becomeActive0(promise: EventLoopPromise<Void>?) {
        assert(self.eventLoop.inEventLoop)
        assert(self.lifecycleManager.isPreRegistered)
        if !self.lifecycleManager.isRegisteredFully {
            do {
                try self.becomeFullyRegistered0()
            } catch {
                self.close0(error: error, mode: .all, promise: promise)
                return
            }
        }
        self.lifecycleManager.activate(promise: promise)(self.pipeline)
        self.readIfNeeded0()
    }
}
