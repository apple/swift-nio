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

private extension ByteBuffer {
    mutating func withMutableWritePointer(body: (UnsafeMutablePointer<UInt8>, Int) throws -> IOResult<Int>) rethrows -> IOResult<Int> {
        var writeResult: IOResult<Int>!
        _ = try self.writeWithUnsafeMutableBytes { ptr in
            let localWriteResult = try body(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), ptr.count)
            writeResult = localWriteResult
            switch localWriteResult {
            case .processed(let written):
                return written
            case .wouldBlock(let written):
                return written
            }
        }
        return writeResult
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
class BaseSocketChannel<T : BaseSocket> : SelectableChannel, ChannelCore {
    typealias SelectableType = T

    // MARK: Methods to override in subclasses.

    /// `true` if the whole `Channel` is closed and so no more IO operation can be done.
    public var closed: Bool {
        assert(eventLoop.inEventLoop)
        return _closed
    }

    /// Provides the registration for this selector. Must be implemented by subclasses.
    func registrationFor(interested: IOEvent) -> NIORegistration {
        fatalError("must override")
    }

    /// Read data from the underlying socket and dispatch it to the `ChannelPipeline`
    ///
    /// - returns: `true` if any data was read, `false` otherwise.
    @discardableResult fileprivate func readFromSocket() throws -> ReadResult {
        fatalError("this must be overridden by sub class")
    }

    fileprivate enum ReadResult {
        /// Nothing was read by the read operation.
        case none

        /// Some data was read by the read operation.
        case some
    }

    /// Begin connection of the underlying socket.
    ///
    /// - parameters:
    ///     - to: The `SocketAddress` to connect to.
    /// - returns: `true` if the socket connected synchronously, `false` otherwise.
    fileprivate func connectSocket(to address: SocketAddress) throws -> Bool {
        fatalError("this must be overridden by sub class")
    }

    /// Make any state changes needed to complete the connection process.
    fileprivate func finishConnectSocket() throws {
        fatalError("this must be overridden by sub class")
    }

    /// Buffer a write in preparation for a flush.
    fileprivate func bufferPendingWrite(data: NIOAny, promise: EventLoopPromise<Void>?) {
        fatalError("this must be overridden by sub class")
    }

    /// Mark a flush point. This is called when flush is received, and instructs
    /// the implementation to record the flush.
    fileprivate func markFlushPoint(promise: EventLoopPromise<Void>?) {
        fatalError("this must be overridden by sub class")
    }

    /// Called when closing, to instruct the specific implementation to discard all pending
    /// writes.
    fileprivate func cancelWritesOnClose(error: Error) {
        fatalError("this must be overridden by sub class")
    }

    /// Flush data to the underlying socket.
    ///
    /// - returns: `true` if there is no further data to write.
    fileprivate func flushNow() -> Bool {
        fatalError("this must be overridden by sub class")
    }

    // MARK: Common base socket logic.

    var selectable: T {
        return self.socket
    }

    public final var _unsafe: ChannelCore { return self }

    // Visible to access from EventLoop directly
    let socket: T
    public var interestedEvent: IOEvent = .none

    fileprivate var readPending = false
    private var neverRegistered = true
    fileprivate var pendingConnect: EventLoopPromise<Void>?
    private let closePromise: EventLoopPromise<Void>
    private var active: Atomic<Bool> = Atomic(value: false)
    private var _closed: Bool = false
    public var isActive: Bool {
        return active.load()
    }

    public var parent: Channel? = nil

    public final var closeFuture: EventLoopFuture<Void> {
        return closePromise.futureResult
    }

    private let selectableEventLoop: SelectableEventLoop

    public final var eventLoop: EventLoop {
        return selectableEventLoop
    }

    public var isWritable: Bool {
        return true
    }

    public final var allocator: ByteBufferAllocator {
        if eventLoop.inEventLoop {
            return bufferAllocator
        } else {
            return try! eventLoop.submit{ self.bufferAllocator }.wait()
        }
    }

    private var bufferAllocator: ByteBufferAllocator = ByteBufferAllocator()
    fileprivate var recvAllocator: RecvByteBufferAllocator = AdaptiveRecvByteBufferAllocator()
    fileprivate var autoRead: Bool = true
    fileprivate var maxMessagesPerRead: UInt = 4

    // We don't use lazy var here as this is more expensive then doing this :/
    public final var pipeline: ChannelPipeline {
        return _pipeline
    }

    private var _pipeline: ChannelPipeline!

    public final func setOption<T: ChannelOption>(option: T, value: T.OptionType) -> EventLoopFuture<Void> {
        if eventLoop.inEventLoop {
            let promise: EventLoopPromise<Void> = eventLoop.newPromise()
            executeAndComplete(promise) { try setOption0(option: option, value: value) }
            return promise.futureResult
        } else {
            return eventLoop.submit { try self.setOption0(option: option, value: value) }
        }
    }

    fileprivate func setOption0<T: ChannelOption>(option: T, value: T.OptionType) throws {
        assert(eventLoop.inEventLoop)

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
            autoRead = auto
            if auto {
                read0(promise: nil)
            } else {
                pauseRead0()
            }
        case _ as MaxMessagesPerReadOption:
            maxMessagesPerRead = value as! UInt
        default:
            fatalError("option \(option) not supported")
        }
    }

    public final func getOption<T: ChannelOption>(option: T) throws -> T.OptionType {
        if eventLoop.inEventLoop {
            return try getOption0(option: option)
        } else {
            return try eventLoop.submit{ try self.getOption0(option: option) }.wait()
        }
    }

    fileprivate func getOption0<T: ChannelOption>(option: T) throws -> T.OptionType {
        assert(eventLoop.inEventLoop)

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

    public final var localAddress: SocketAddress? {
        get {
            return socket.localAddress
        }
    }

    public final var remoteAddress: SocketAddress? {
        get {
            return socket.remoteAddress
        }
    }

    /// Triggers a `ChannelPipeline.read()` if `autoRead` is enabled.`
    ///
    /// - returns: `true` if `readPending` is `true`, `false` otherwise.
    @discardableResult func readIfNeeded0() -> Bool {
        assert(eventLoop.inEventLoop)

        if !readPending && autoRead {
            pipeline.read0(promise: nil)
        }
        return readPending
    }

    // Methods invoked from the HeadHandler of the ChannelPipeline
    public func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)

        guard !self.closed else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }

        executeAndComplete(promise) {
            try socket.bind(to: address)
        }
    }

    public final func write0(data: NIOAny, promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)

        if closed {
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
        default:
            break
        }
    }

    fileprivate func unregisterForWritable() {
        assert(eventLoop.inEventLoop)
        switch interestedEvent {
        case .all:
            safeReregister(interested: .read)
        case .write:
            safeReregister(interested: .none)
        default:
            break
        }
    }

    public final func flush0(promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)

        if closed {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }

        self.markFlushPoint(promise: promise)

        if !isWritePending() && !flushNow() && !closed {
            registerForWritable()
        }
    }

    public func read0(promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)

        if closed {
            promise?.fail(error:ChannelError.ioOnClosedChannel)
            return
        }
        defer {
            promise?.succeed(result: ())
        }
        readPending = true

        registerForReadable()
    }

    private final func pauseRead0() {
        assert(eventLoop.inEventLoop)

        if !closed {
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
        default:
            break
        }
    }

    fileprivate func unregisterForReadable() {
        assert(eventLoop.inEventLoop)

        switch interestedEvent {
        case .read:
            safeReregister(interested: .none)
        case .all:
            safeReregister(interested: .write)
        default:
            break
        }
    }

    public func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)

        if closed {
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
        } catch let err {
            pipeline.fireErrorCaught0(error: err)
        }

        executeAndComplete(promise) {
            try socket.close()
        }

        // Fail all pending writes and so ensure all pending promises are notified
        self._closed = true
        self.cancelWritesOnClose(error: error)

        becomeInactive0()

        if !neverRegistered {
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

        guard !self.closed else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }

        // Was not registered yet so do it now.
        do {
            try self.safeRegister(interested: .read)
            neverRegistered = false
            promise?.succeed(result: ())
            pipeline.fireChannelRegistered0()
        } catch {
            promise?.fail(error: error)
        }
    }

    public final func triggerUserOutboundEvent0(event: Any, promise: EventLoopPromise<Void>?) {
        promise?.succeed(result: ())
    }

    // Methods invoked from the EventLoop itself
    public final func writable() {
        assert(eventLoop.inEventLoop)
        assert(!closed)

        finishConnect()  // If we were connecting, that has finished.
        if flushNow() {
            // Everything was written or connect was complete
            finishWritable()
        }
    }

    private func finishConnect() {
        assert(eventLoop.inEventLoop)

        if let connectPromise = pendingConnect {
            pendingConnect = nil
            executeAndComplete(connectPromise) {
                try finishConnectSocket()
            }
        }
    }

    private func finishWritable() {
        assert(eventLoop.inEventLoop)

        if !closed {
            unregisterForWritable()
        }
    }

    public final func readable() {
        assert(eventLoop.inEventLoop)
        assert(!closed)

        defer {
            if !closed, !readPending {
                unregisterForReadable()
            }
        }

        do {
            try readFromSocket()
        } catch let err {
            // ChannelError.eof is not something we want to fire through the pipeline as it just means the remote
            // per closed / shutdown the connection.
            if let channelErr = err as? ChannelError, channelErr != ChannelError.eof {
                pipeline.fireErrorCaught0(error: err)
            } else if try! getOption(option: ChannelOptions.allowRemoteHalfClosure) {
                // If we want to allow half closure we will just mark the input side of the Channel
                // as closed.
                pipeline.fireChannelReadComplete0()
                close0(error: err, mode: .input, promise: nil)
                readPending = false
                return
            } else {
                pipeline.fireErrorCaught0(error: err)
            }

            // Call before triggering the close of the Channel.
            pipeline.fireChannelReadComplete0()
            close0(error: err, mode: .all, promise: nil)
            return
        }
        pipeline.fireChannelReadComplete0()
        readIfNeeded0()
    }

    public final func connect0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)

        guard !self.closed else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }

        guard pendingConnect == nil else {
            promise?.fail(error: ChannelError.connectPending)
            return
        }
        do {
            if try !connectSocket(to: address) {
                if promise != nil {
                    pendingConnect = promise
                } else {
                    pendingConnect = eventLoop.newPromise()
                }
                registerForWritable()
            } else {
                promise?.succeed(result: ())
            }
        } catch let error {
            promise?.fail(error: error)
        }
    }

    public func channelRead0(data: NIOAny) {
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
        if closed {
            interestedEvent = .none
            return
        }
        if interested == interestedEvent || interestedEvent == .none {
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

        if closed {
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

    fileprivate func becomeActive0() {
        assert(eventLoop.inEventLoop)
        active.store(true)
        pipeline.fireChannelActive0()
    }

    fileprivate func becomeInactive0() {
        assert(eventLoop.inEventLoop)
        active.store(false)
        pipeline.fireChannelInactive0()
    }

    fileprivate init(socket: T, eventLoop: SelectableEventLoop) throws {
        self.socket = socket
        self.selectableEventLoop = eventLoop
        self.closePromise = eventLoop.newPromise()
        active.store(false)
        self._pipeline = ChannelPipeline(channel: self)
    }

    deinit {
        assert(self._closed, "leak of open Channel")
    }
}

/// A `Channel` for a client socket.
///
/// - note: All operations on `SocketChannel` are thread-safe.
final class SocketChannel: BaseSocketChannel<Socket> {

    private var connectTimeout: TimeAmount? = nil
    private var connectTimeoutScheduled: Scheduled<Void>?
    private var allowRemoteHalfClosure: Bool = false
    private var inputShutdown: Bool = false
    private var outputShutdown: Bool = false

    // Guard against re-entrance of flushNow() method.
    private var inFlushNow: Bool = false
    private let pendingWrites: PendingStreamWritesManager

    override public var isWritable: Bool {
        return pendingWrites.isWritable
    }

    override public var closed: Bool {
        assert(eventLoop.inEventLoop)
        return pendingWrites.closed
    }

    init(eventLoop: SelectableEventLoop, protocolFamily: Int32) throws {
        let socket = try Socket(protocolFamily: protocolFamily, type: Posix.SOCK_STREAM)
        do {
            try socket.setNonBlocking()
        } catch let err {
            let _ = try? socket.close()
            throw err
        }
        self.pendingWrites = PendingStreamWritesManager(iovecs: eventLoop.iovecs, storageRefs: eventLoop.storageRefs)
        try super.init(socket: socket, eventLoop: eventLoop)
    }

    deinit {
        // We should never have any pending writes left as otherwise we may leak callbacks
        assert(pendingWrites.isEmpty)
    }

    override fileprivate func setOption0<T: ChannelOption>(option: T, value: T.OptionType) throws {
        assert(eventLoop.inEventLoop)
        switch option {
        case _ as ConnectTimeoutOption:
            connectTimeout = value as? TimeAmount
        case _ as AllowRemoteHalfClosureOption:
            allowRemoteHalfClosure = value as! Bool
        case _ as WriteSpinOption:
            pendingWrites.writeSpinCount = value as! UInt
        case _ as WriteBufferWaterMarkOption:
            pendingWrites.waterMark = value as! WriteBufferWaterMark
        default:
            try super.setOption0(option: option, value: value)
        }
    }

    override fileprivate func getOption0<T: ChannelOption>(option: T) throws -> T.OptionType {
        assert(eventLoop.inEventLoop)
        switch option {
        case _ as ConnectTimeoutOption:
            return connectTimeout as! T.OptionType
        case _ as AllowRemoteHalfClosureOption:
            return allowRemoteHalfClosure as! T.OptionType
        case _ as WriteSpinOption:
            return pendingWrites.writeSpinCount as! T.OptionType
        case _ as WriteBufferWaterMarkOption:
            return pendingWrites.waterMark as! T.OptionType
        default:
            return try super.getOption0(option: option)
        }
    }

    public override func registrationFor(interested: IOEvent) -> NIORegistration {
        return .socketChannel(self, interested)
    }

    fileprivate override init(socket: Socket, eventLoop: SelectableEventLoop) throws {
        try socket.setNonBlocking()
        self.pendingWrites = PendingStreamWritesManager(iovecs: eventLoop.iovecs, storageRefs: eventLoop.storageRefs)
        try super.init(socket: socket, eventLoop: eventLoop)
    }

    fileprivate convenience init(socket: Socket, eventLoop: SelectableEventLoop, parent: Channel) throws {
        try self.init(socket: socket, eventLoop: eventLoop)
        self.parent = parent
    }

    override fileprivate func readFromSocket() throws -> ReadResult {
        // Just allocate one time for the while read loop. This is fine as ByteBuffer is a struct and uses COW.
        var buffer = recvAllocator.buffer(allocator: allocator)
        var result = ReadResult.none
        for i in 1...maxMessagesPerRead {
            if closed || inputShutdown {
                return result
            }
            // Reset reader and writerIndex and so allow to have the buffer filled again. This is better here than at
            // the end of the loop to not do an allocation when the loop exits.
            buffer.clear()
            switch try buffer.withMutableWritePointer(body: self.socket.read(pointer:size:)) {
            case .processed(let bytesRead):
                if bytesRead > 0 {
                    let mayGrow = recvAllocator.record(actualReadBytes: bytesRead)

                    readPending = false

                    assert(!closed)
                    pipeline.fireChannelRead0(data: NIOAny(buffer))
                    if mayGrow && i < maxMessagesPerRead {
                        // if the ByteBuffer may grow on the next allocation due we used all the writable bytes we should allocate a new `ByteBuffer` to allow ramping up how much data
                        // we are able to read on the next read operation.
                        buffer = recvAllocator.buffer(allocator: allocator)
                    }
                    result = .some
                } else {
                    if inputShutdown {
                        // We received a EOF because we called shutdown on the fd by ourself, unregister from the Selector and return
                        readPending = false
                        unregisterForReadable()
                        return result
                    }
                    // end-of-file
                    throw ChannelError.eof
                }
            case .wouldBlock(let bytesRead):
                assert(bytesRead == 0)
                return result
            }
        }
        return result
    }

    private func writeToSocket(pendingWrites: PendingStreamWritesManager) throws -> WriteResult {
        repeat {
            let result = try pendingWrites.triggerAppropriateWriteOperation(singleWriteOperation: { ptr in
                guard ptr.count > 0 else {
                    // No need to call write if the buffer is empty.
                    return .processed(0)
                }
                // normal write
                return try self.socket.write(pointer: ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), size: ptr.count)
            }, vectorWriteOperation: { ptrs in
                switch ptrs.count {
                case 0:
                    // No need to call write if the buffer is empty.
                    return .processed(0)
                case 1:
                    let p = ptrs[0]
                    guard p.iov_len > 0 else {
                        // No need to call write if the buffer is empty.
                        return .processed(0)
                    }
                    return try self.socket.write(pointer: p.iov_base.assumingMemoryBound(to: UInt8.self), size: p.iov_len)
                default:
                    // Gathering write
                    return try self.socket.writev(iovecs: ptrs)
                }
            }, fileWriteOperation: { descriptor, index, endIndex in
                return try self.socket.sendFile(fd: descriptor, offset: index, count: endIndex - index)
            })
            if result.writable {
                // writable again
                self.pipeline.fireChannelWritabilityChanged0()
            }
            if result.writeResult == .writtenCompletely && pendingWrites.isFlushPending {
                // there are more buffers to process, so continue
                continue
            }
            return result.writeResult
        } while true
    }

    override fileprivate func connectSocket(to address: SocketAddress) throws -> Bool {
        if try self.socket.connect(to: address) {
            return true
        }
        if let timeout = connectTimeout {
            connectTimeoutScheduled = eventLoop.scheduleTask(in: timeout) { () -> (Void) in
                if self.pendingConnect != nil {
                    // The connection was still not established, close the Channel which will also fail the pending promise.
                    self.close0(error: ChannelError.connectTimeout(timeout), mode: .all, promise: nil)
                }
            }
        }

        return false
    }

    override fileprivate func finishConnectSocket() throws {
        if let scheduled = connectTimeoutScheduled {
            // Connection established so cancel the previous scheduled timeout.
            connectTimeoutScheduled = nil
            scheduled.cancel()
        }
        try self.socket.finishConnect()
        becomeActive0()
    }

    override func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        do {
            switch mode {
            case .output:
                if outputShutdown {
                    promise?.fail(error: ChannelError.outputClosed)
                    return
                }
                try socket.shutdown(how: .WR)
                outputShutdown = true
                // Fail all pending writes and so ensure all pending promises are notified
                pendingWrites.failAll(error: error, close: false)
                unregisterForWritable()
                promise?.succeed(result: ())

                pipeline.fireUserInboundEventTriggered(event: ChannelEvent.outputClosed)

            case .input:
                if inputShutdown {
                    promise?.fail(error: ChannelError.inputClosed)
                    return
                }
                switch error {
                case ChannelError.eof:
                    // No need to explicit call socket.shutdown(...) as we received an EOF and the call would only cause
                    // ENOTCON
                    break
                default:
                    try socket.shutdown(how: .RD)
                }
                inputShutdown = true
                unregisterForReadable()
                promise?.succeed(result: ())

                pipeline.fireUserInboundEventTriggered(event: ChannelEvent.inputClosed)
            case .all:
                if let timeout = connectTimeoutScheduled {
                    connectTimeoutScheduled = nil
                    timeout.cancel()
                }
                super.close0(error: error, mode: mode, promise: promise)
            }
        } catch let err {
            promise?.fail(error: err)
        }
    }

    override func markFlushPoint(promise: EventLoopPromise<Void>?) {
        // Even if writable() will be called later by the EventLoop we still need to mark the flush checkpoint so we are sure all the flushed messages
        // are actually written once writable() is called.
        self.pendingWrites.markFlushCheckpoint(promise: promise)
    }

    override func cancelWritesOnClose(error: Error) {
        self.pendingWrites.failAll(error: error, close: true)
    }

    @discardableResult override func readIfNeeded0() -> Bool {
        if inputShutdown {
            return false
        }
        return super.readIfNeeded0()
    }

    override public func read0(promise: EventLoopPromise<Void>?) {
        if inputShutdown {
            promise?.fail(error: ChannelError.inputClosed)
            return
        }
        super.read0(promise: promise)
    }

    override fileprivate func bufferPendingWrite(data: NIOAny, promise: EventLoopPromise<Void>?) {
        if outputShutdown {
            promise?.fail(error: ChannelError.outputClosed)
            return
        }

        guard let data = data.tryAsIOData() else {
            promise?.fail(error: ChannelError.writeDataUnsupported)
            return
        }

        if !self.pendingWrites.add(data: data, promise: promise) {
            pipeline.fireChannelWritabilityChanged0()
        }
    }

    override fileprivate func flushNow() -> Bool {
        // Guard against re-entry as data that will be put into `pendingWrites` will just be picked up by
        // `writeToSocket`.
        guard !inFlushNow else {
            return true
        }

        defer {
            inFlushNow = false
        }

        inFlushNow = true

        while !closed {
            do {
                switch try self.writeToSocket(pendingWrites: pendingWrites) {
                case .writtenPartially:
                    // Could not write the next buffer(s) completely
                    return false
                case .wouldBlock:
                    return false
                case .writtenCompletely:
                    return true
                case .closed:
                    return true
                case .nothingToBeWritten:
                    return true
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
                return true
            }
        }
        return true
    }
}

/// A `Channel` for a server socket.
///
/// - note: All operations on `ServerSocketChannel` are thread-safe.
final class ServerSocketChannel : BaseSocketChannel<ServerSocket> {

    private var backlog: Int32 = 128
    private let group: EventLoopGroup

    /// The server socket channel is never writable.
    override public var isWritable: Bool { return false }

    init(eventLoop: SelectableEventLoop, group: EventLoopGroup, protocolFamily: Int32) throws {
        let serverSocket = try ServerSocket(protocolFamily: protocolFamily)
        do {
            try serverSocket.setNonBlocking()
        } catch let err {
            let _ = try? serverSocket.close()
            throw err
        }
        self.group = group
        try super.init(socket: serverSocket, eventLoop: eventLoop)
    }

    public override func registrationFor(interested: IOEvent) -> NIORegistration {
        return .serverSocketChannel(self, interested)
    }

    override fileprivate func setOption0<T: ChannelOption>(option: T, value: T.OptionType) throws {
        assert(eventLoop.inEventLoop)
        switch option {
        case _ as BacklogOption:
            backlog = value as! Int32
        default:
            try super.setOption0(option: option, value: value)
        }
    }

    override fileprivate func getOption0<T: ChannelOption>(option: T) throws -> T.OptionType {
        assert(eventLoop.inEventLoop)
        switch option {
        case _ as BacklogOption:
            return backlog as! T.OptionType
        default:
            return try super.getOption0(option: option)
        }
    }

    override public func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)

        guard !self.closed else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }

        let p: EventLoopPromise<Void> = eventLoop.newPromise()
        p.futureResult.whenComplete { v in
            switch v {
            case .failure(let e):
                promise?.fail(error: e)
            case .success(let res):
                // Its important to call the methods before we actual notify the original promise for ordering reasons.
                self.becomeActive0()
                self.readIfNeeded0()
                promise?.succeed(result: res)
            }
        }
        executeAndComplete(p) {
            try socket.bind(to: address)
            try self.socket.listen(backlog: backlog)
        }
    }

    override fileprivate func connectSocket(to address: SocketAddress) throws -> Bool {
        throw ChannelError.operationUnsupported
    }

    override fileprivate func finishConnectSocket() throws {
        throw ChannelError.operationUnsupported
    }

    override fileprivate func readFromSocket() throws -> ReadResult {
        var result = ReadResult.none
        for _ in 1...maxMessagesPerRead {
            if closed {
                return result
            }
            if let accepted =  try self.socket.accept() {
                readPending = false
                result = .some
                do {
                    let chan = try SocketChannel(socket: accepted, eventLoop: group.next() as! SelectableEventLoop, parent: self)
                    pipeline.fireChannelRead0(data: NIOAny(chan))
                } catch let err {
                    let _ = try? accepted.close()
                    throw err
                }
            } else {
                break
            }
        }
        return result
    }

    override fileprivate func cancelWritesOnClose(error: Error) {
        // No writes to cancel.
        return
    }

    override public func channelRead0(data: NIOAny) {
        assert(eventLoop.inEventLoop)

        let ch = data.forceAsOther() as SocketChannel
        let f = ch.register()
        f.whenComplete { v in
            switch v {
            case .failure(_):
                ch.close(promise: nil)
            case .success(_):
                ch.becomeActive0()
                ch.readIfNeeded0()
            }
        }
    }
}

extension SocketChannel: CustomStringConvertible {
    var description: String {
        return "SocketChannel { descriptor = \(self.selectable.descriptor), localAddress = \(self.localAddress.debugDescription), remoteAddress = \(self.remoteAddress.debugDescription) }"
    }
}

extension ServerSocketChannel: CustomStringConvertible {
    var description: String {
        return "ServerSocketChannel { descriptor = \(self.selectable.descriptor), localAddress = \(self.localAddress.debugDescription), remoteAddress = \(self.remoteAddress.debugDescription) }"
    }
}
