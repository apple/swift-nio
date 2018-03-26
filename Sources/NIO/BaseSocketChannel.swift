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

    internal var interestedEvent: IOEvent = .none

    var readPending = false
    var pendingConnect: EventLoopPromise<Void>?
    var recvAllocator: RecvByteBufferAllocator
    var maxMessagesPerRead: UInt = 4

    private var inFlushNow: Bool = false // Guard against re-entrance of flushNow() method.
    private var neverRegistered = true
    private var neverActivated = true
    private var active: Atomic<Bool> = Atomic(value: false)
    private var _isOpen: Bool = true
    private var autoRead: Bool = true
    private var _pipeline: ChannelPipeline!
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
        return self._isOpen
    }

    internal var selectable: T {
        return self.socket
    }

    // This is `Channel` API so must be thread-safe.
    public var isActive: Bool {
        return self.active.load()
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
        return _pipeline
    }

    // MARK: Methods to override in subclasses.
    func writeToSocket() throws -> OverallWriteResult {
        fatalError("must be overridden")
    }

    /// Provides the registration for this selector. Must be implemented by subclasses.
    func registrationFor(interested: IOEvent) -> NIORegistration {
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
        self.active.store(false)
        self.recvAllocator = recvAllocator
        self._pipeline = ChannelPipeline(channel: self)
        // As the socket may already be connected we should ensure we start with the correct addresses cached.
        self.addressesCached.store(Box((local: try? socket.localAddress(), remote: try? socket.remoteAddress())))
    }

    deinit {
        assert(!self._isOpen, "leak of open Channel")
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

                // We need to continue reading until there is nothing more to be read from the socket as we will not have another chance to drain it.
                while let read = try? readFromSocket(), read == .some {
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
            if !neverRegistered && old != auto {
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

        bufferPendingWrite(data: data, promise: promise)
    }

    private func registerForWritable() {
        assert(eventLoop.inEventLoop)

        switch interestedEvent {
        case .read:
            safeReregister(interested: .all)
        case .none:
            safeReregister(interested: .write)
        case .write, .all:
            break
        }
    }

    func unregisterForWritable() {
        assert(eventLoop.inEventLoop)
        switch interestedEvent {
        case .all:
            safeReregister(interested: .read)
        case .write:
            safeReregister(interested: .none)
        case .read, .none:
            break
        }
    }

    public final func flush0() {
        assert(eventLoop.inEventLoop)

        guard self.isOpen else {
            return
        }

        self.markFlushPoint()

        if !isWritePending() && flushNow() == .register {
            registerForWritable()
        }
    }

    public func read0() {
        assert(eventLoop.inEventLoop)

        guard self.isOpen else {
            return
        }
        readPending = true

        if !neverRegistered {
            registerForReadable()
        }
    }

    private final func pauseRead0() {
        assert(eventLoop.inEventLoop)

        if self.isOpen && !neverRegistered{
            unregisterForReadable()
        }
    }

    private func registerForReadable() {
        assert(eventLoop.inEventLoop)

        switch interestedEvent {
        case .write:
            safeReregister(interested: .all)
        case .none:
            safeReregister(interested: .read)
        case .read, .all:
            break
        }
    }

    func unregisterForReadable() {
        assert(eventLoop.inEventLoop)

        switch interestedEvent {
        case .read:
            safeReregister(interested: .none)
        case .all:
            safeReregister(interested: .write)
        case .write, .none:
            break
        }
    }

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

        interestedEvent = .none
        do {
            try selectableEventLoop.deregister(channel: self)
        } catch {
            // There is not much we can do here, so just ignore
        }

        // We need to notify the promise after we are done failing the writes and updating the channel state to guard
        // against re-entrance by a callback that will call close0(...) again.
        let closeError: Error?
        do {
            try socket.close()
            closeError = nil
        } catch {
            closeError = error
        }

        // Fail all pending writes and so ensure all pending promises are notified
        self._isOpen = false
        self.unsetCachedAddressesFromSocket()
        self.cancelWritesOnClose(error: error)

        if !self.neverActivated {
            if let err = closeError {
                promise?.fail(error: err)
                becomeInactive0(promise: nil)
            } else {
                becomeInactive0(promise: promise)
            }
        } else if let promise = promise {
            if let err = closeError {
                promise.fail(error: err)
            } else {
                promise.succeed(result: ())
            }
        }

        if !self.neverRegistered {
            pipeline.fireChannelUnregistered0()
        }

        eventLoop.execute {
            // ensure this is executed in a delayed fashion as the users code may still traverse the pipeline
            self.pipeline.removeHandlers()

            self.closePromise.succeed(result: ())
        }

        if let connectPromise = pendingConnect {
            pendingConnect = nil
            connectPromise.fail(error: error)
        }
    }


    public final func register0(promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)

        guard self.isOpen else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }

        // Was not registered yet so do it now.
        do {
            // We always register with interested .none and will just trigger readIfNeeded0() later to re-register if needed.
            try self.safeRegister(interested: .none)
            neverRegistered = false
            promise?.succeed(result: ())
            pipeline.fireChannelRegistered0()
        } catch {
            promise?.fail(error: error)
        }
    }

    public final func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        promise?.succeed(result: ())
    }

    // Methods invoked from the EventLoop itself
    public final func writable() {
        assert(self.eventLoop.inEventLoop)
        assert(self.isOpen)

        finishConnect()  // If we were connecting, that has finished.
        if flushNow() == .unregister {
            // Everything was written or connect was complete
            finishWritable()
        }
    }

    private func finishConnect() {
        assert(eventLoop.inEventLoop)

        if let connectPromise = pendingConnect {
            pendingConnect = nil

            do {
                try finishConnectSocket()
            } catch {
                connectPromise.fail(error: error)
                return
            }
            // We already know what the local address is.
            self.updateCachedAddressesFromSocket(updateLocal: false, updateRemote: true)
            becomeActive0(promise: connectPromise)
        }
    }

    private func finishWritable() {
        assert(eventLoop.inEventLoop)

        if self.isOpen {
            unregisterForWritable()
        }
    }

    public final func readable() {
        assert(eventLoop.inEventLoop)
        assert(self.isOpen)

        defer {
            if self.isOpen && !self.readPending {
                unregisterForReadable()
            }
        }

        do {
            try readFromSocket()
        } catch let err {
            // ChannelError.eof is not something we want to fire through the pipeline as it just means the remote
            // peer closed / shutdown the connection.
            if let channelErr = err as? ChannelError, channelErr == ChannelError.eof {
                // Directly call getOption0 as we are already on the EventLoop and so not need to create an extra future.
                if try! getOption0(option: ChannelOptions.allowRemoteHalfClosure) {
                    // If we want to allow half closure we will just mark the input side of the Channel
                    // as closed.
                    pipeline.fireChannelReadComplete0()
                    if shouldCloseOnReadError(err) {
                        close0(error: err, mode: .input, promise: nil)
                    }
                    readPending = false
                    return
                }
            } else {
                pipeline.fireErrorCaught0(error: err)
            }

            // Call before triggering the close of the Channel.
            pipeline.fireChannelReadComplete0()

            if shouldCloseOnReadError(err) {
                close0(error: err, mode: .all, promise: nil)
            }

            return
        }
        pipeline.fireChannelReadComplete0()
        readIfNeeded0()
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
        do {
            if try !connectSocket(to: address) {
                // We aren't connected, we'll get the remote address later.
                self.updateCachedAddressesFromSocket(updateLocal: true, updateRemote: false)
                if promise != nil {
                    pendingConnect = promise
                } else {
                    pendingConnect = eventLoop.newPromise()
                }
                registerForWritable()
            } else {
                self.updateCachedAddressesFromSocket()
                becomeActive0(promise: promise)
            }
        } catch let error {
            promise?.fail(error: error)
        }
    }

    public func channelRead0(_ data: NIOAny) {
        // Do nothing by default
    }

    public func errorCaught0(error: Error) {
        // Do nothing
    }

    private func isWritePending() -> Bool {
        return interestedEvent == .write || interestedEvent == .all
    }

    private func safeReregister(interested: IOEvent) {
        assert(eventLoop.inEventLoop)
        guard self.isOpen else {
            interestedEvent = .none
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
            pipeline.fireErrorCaught0(error: err)
            close0(error: err, mode: .all, promise: nil)
        }
    }

    private func safeRegister(interested: IOEvent) throws {
        assert(eventLoop.inEventLoop)

        guard self.isOpen else {
            interestedEvent = .none
            throw ChannelError.ioOnClosedChannel
        }
        interestedEvent = interested
        do {
            try selectableEventLoop.register(channel: self)
        } catch let err {
            pipeline.fireErrorCaught0(error: err)
            close0(error: err, mode: .all, promise: nil)
            throw err
        }
    }

    final func becomeActive0(promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)
        assert(!self.active.load())
        assert(self._isOpen)

        self.neverActivated = false
        active.store(true)

        // Notify the promise before firing the inbound event through the pipeline.
        if let promise = promise {
            promise.succeed(result: ())
        }
        pipeline.fireChannelActive0()
        self.readIfNeeded0()
    }

    func becomeInactive0(promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)
        assert(self.active.load())
        active.store(false)

        // Notify the promise before firing the inbound event through the pipeline.
        if let promise = promise {
            promise.succeed(result: ())
        }
        pipeline.fireChannelInactive0()
    }
}
