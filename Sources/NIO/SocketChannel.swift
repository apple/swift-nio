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

private extension ByteBuffer {
    mutating func withMutableWritePointer(body: (UnsafeMutableRawBufferPointer) throws -> IOResult<Int>) rethrows -> IOResult<Int> {
        var singleResult: IOResult<Int>!
        _ = try self.writeWithUnsafeMutableBytes { ptr in
            let localWriteResult = try body(ptr)
            singleResult = localWriteResult
            switch localWriteResult {
            case .processed(let written):
                return written
            case .wouldBlock(let written):
                return written
            }
        }
        return singleResult
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

    private let pendingWrites: PendingStreamWritesManager

    // This is `Channel` API so must be thread-safe.
    override public var isWritable: Bool {
        return pendingWrites.isWritable
    }

    override var isOpen: Bool {
        assert(eventLoop.inEventLoop)
        assert(super.isOpen == self.pendingWrites.isOpen)
        return super.isOpen
    }

    init(eventLoop: SelectableEventLoop, protocolFamily: Int32) throws {
        let socket = try Socket(protocolFamily: protocolFamily, type: Posix.SOCK_STREAM, setNonBlocking: true)
        self.pendingWrites = PendingStreamWritesManager(iovecs: eventLoop.iovecs, storageRefs: eventLoop.storageRefs)
        try super.init(socket: socket, eventLoop: eventLoop, recvAllocator: AdaptiveRecvByteBufferAllocator())
    }

    init(eventLoop: SelectableEventLoop, descriptor: CInt) throws {
        let socket = try Socket(descriptor: descriptor, setNonBlocking: true)
        self.pendingWrites = PendingStreamWritesManager(iovecs: eventLoop.iovecs, storageRefs: eventLoop.storageRefs)
        try super.init(socket: socket, eventLoop: eventLoop, recvAllocator: AdaptiveRecvByteBufferAllocator())
    }

    deinit {
        // We should never have any pending writes left as otherwise we may leak callbacks
        assert(pendingWrites.isEmpty)
    }

    override func setOption0<T: ChannelOption>(option: T, value: T.OptionType) throws {
        assert(eventLoop.inEventLoop)

        guard isOpen else {
            throw ChannelError.ioOnClosedChannel
        }

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

    override func getOption0<T: ChannelOption>(option: T) throws -> T.OptionType {
        assert(eventLoop.inEventLoop)

        guard isOpen else {
            throw ChannelError.ioOnClosedChannel
        }

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

    override func registrationFor(interested: SelectorEventSet) -> NIORegistration {
        return .socketChannel(self, interested)
    }

    init(socket: Socket, parent: Channel? = nil, eventLoop: SelectableEventLoop) throws {
        self.pendingWrites = PendingStreamWritesManager(iovecs: eventLoop.iovecs, storageRefs: eventLoop.storageRefs)
        try super.init(socket: socket, parent: parent, eventLoop: eventLoop, recvAllocator: AdaptiveRecvByteBufferAllocator())
    }

    override func readFromSocket() throws -> ReadResult {
        assert(self.eventLoop.inEventLoop)
        // Just allocate one time for the while read loop. This is fine as ByteBuffer is a struct and uses COW.
        var buffer = recvAllocator.buffer(allocator: allocator)
        var result = ReadResult.none
        for i in 1...maxMessagesPerRead {
            guard self.isOpen && !self.inputShutdown else {
                throw ChannelError.eof
            }
            // Reset reader and writerIndex and so allow to have the buffer filled again. This is better here than at
            // the end of the loop to not do an allocation when the loop exits.
            buffer.clear()
            switch try buffer.withMutableWritePointer(body: self.socket.read(pointer:)) {
            case .processed(let bytesRead):
                if bytesRead > 0 {
                    let mayGrow = recvAllocator.record(actualReadBytes: bytesRead)

                    readPending = false

                    assert(self.isActive)
                    pipeline.fireChannelRead0(NIOAny(buffer))
                    result = .some

                    if buffer.writableBytes > 0 {
                        // If we did not fill the whole buffer with read(...) we should stop reading and wait until we get notified again.
                        // Otherwise chances are good that the next read(...) call will either read nothing or only a very small amount of data.
                        // Also this will allow us to call fireChannelReadComplete() which may give the user the chance to flush out all pending
                        // writes.
                        return result
                    } else if mayGrow && i < maxMessagesPerRead {
                        // if the ByteBuffer may grow on the next allocation due we used all the writable bytes we should allocate a new `ByteBuffer` to allow ramping up how much data
                        // we are able to read on the next read operation.
                        buffer = recvAllocator.buffer(allocator: allocator)
                    }
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

    override func writeToSocket() throws -> OverallWriteResult {
        let result = try self.pendingWrites.triggerAppropriateWriteOperations(scalarBufferWriteOperation: { ptr in
            guard ptr.count > 0 else {
                // No need to call write if the buffer is empty.
                return .processed(0)
            }
            // normal write
            return try self.socket.write(pointer: ptr)
        }, vectorBufferWriteOperation: { ptrs in
            // Gathering write
            try self.socket.writev(iovecs: ptrs)
        }, scalarFileWriteOperation: { descriptor, index, endIndex in
            try self.socket.sendFile(fd: descriptor, offset: index, count: endIndex - index)
        })
        if result.writable {
            // writable again
            self.pipeline.fireChannelWritabilityChanged0()
        }
        return result.writeResult
    }

    override func connectSocket(to address: SocketAddress) throws -> Bool {
        if try self.socket.connect(to: address) {
            return true
        }
        if let timeout = connectTimeout {
            connectTimeoutScheduled = eventLoop.scheduleTask(in: timeout) { () -> Void in
                if self.pendingConnect != nil {
                    // The connection was still not established, close the Channel which will also fail the pending promise.
                    self.close0(error: ChannelError.connectTimeout(timeout), mode: .all, promise: nil)
                }
            }
        }

        return false
    }

    override func finishConnectSocket() throws {
        if let scheduled = self.connectTimeoutScheduled {
            // Connection established so cancel the previous scheduled timeout.
            self.connectTimeoutScheduled = nil
            scheduled.cancel()
        }
        try self.socket.finishConnect()
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

                pipeline.fireUserInboundEventTriggered(ChannelEvent.outputClosed)

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

                pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
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

    override func markFlushPoint() {
        // Even if writable() will be called later by the EventLoop we still need to mark the flush checkpoint so we are sure all the flushed messages
        // are actually written once writable() is called.
        self.pendingWrites.markFlushCheckpoint()
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

    override public func read0() {
        if inputShutdown {
            return
        }
        super.read0()
    }

    override func bufferPendingWrite(data: NIOAny, promise: EventLoopPromise<Void>?) {
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
}

/// A `Channel` for a server socket.
///
/// - note: All operations on `ServerSocketChannel` are thread-safe.
final class ServerSocketChannel: BaseSocketChannel<ServerSocket> {

    private var backlog: Int32 = 128
    private let group: EventLoopGroup

    /// The server socket channel is never writable.
    // This is `Channel` API so must be thread-safe.
    override public var isWritable: Bool { return false }

    convenience init(eventLoop: SelectableEventLoop, group: EventLoopGroup, protocolFamily: Int32) throws {
        try self.init(serverSocket: try ServerSocket(protocolFamily: protocolFamily, setNonBlocking: true), eventLoop: eventLoop, group: group)
    }

    init(serverSocket: ServerSocket, eventLoop: SelectableEventLoop, group: EventLoopGroup) throws {
        self.group = group
        try super.init(socket: serverSocket, eventLoop: eventLoop, recvAllocator: AdaptiveRecvByteBufferAllocator())
    }

    convenience init(descriptor: CInt, eventLoop: SelectableEventLoop, group: EventLoopGroup) throws {
        let socket = try ServerSocket(descriptor: descriptor, setNonBlocking: true)
        try self.init(serverSocket: socket, eventLoop: eventLoop, group: group)
        try self.socket.listen(backlog: backlog)
    }

    override func registrationFor(interested: SelectorEventSet) -> NIORegistration {
        return .serverSocketChannel(self, interested)
    }

    override func setOption0<T: ChannelOption>(option: T, value: T.OptionType) throws {
        assert(eventLoop.inEventLoop)

        guard isOpen else {
            throw ChannelError.ioOnClosedChannel
        }

        switch option {
        case _ as BacklogOption:
            backlog = value as! Int32
        default:
            try super.setOption0(option: option, value: value)
        }
    }

    override func getOption0<T: ChannelOption>(option: T) throws -> T.OptionType {
        assert(eventLoop.inEventLoop)

        guard isOpen else {
            throw ChannelError.ioOnClosedChannel
        }

        switch option {
        case _ as BacklogOption:
            return backlog as! T.OptionType
        default:
            return try super.getOption0(option: option)
        }
    }

    override public func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)

        guard self.isOpen else {
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }

        guard self.isRegistered else {
            promise?.fail(error: ChannelLifecycleError.inappropriateOperationForState)
            return
        }

        let p: EventLoopPromise<Void> = eventLoop.newPromise()
        p.futureResult.map {
            // It's important to call the methods before we actually notify the original promise for ordering reasons.
            self.becomeActive0(promise: promise)
        }.whenFailure{ error in
            promise?.fail(error: error)
        }
        executeAndComplete(p) {
            try socket.bind(to: address)
            self.updateCachedAddressesFromSocket(updateRemote: false)
            try self.socket.listen(backlog: backlog)
        }
    }

    override func connectSocket(to address: SocketAddress) throws -> Bool {
        throw ChannelError.operationUnsupported
    }

    override func finishConnectSocket() throws {
        throw ChannelError.operationUnsupported
    }

    override func readFromSocket() throws -> ReadResult {
        var result = ReadResult.none
        for _ in 1...maxMessagesPerRead {
            guard self.isOpen else {
                throw ChannelError.eof
            }
            if let accepted =  try self.socket.accept(setNonBlocking: true) {
                readPending = false
                result = .some
                do {
                    let chan = try SocketChannel(socket: accepted, parent: self, eventLoop: group.next() as! SelectableEventLoop)
                    assert(self.isActive)
                    pipeline.fireChannelRead0(NIOAny(chan))
                } catch let err {
                    _ = try? accepted.close()
                    throw err
                }
            } else {
                break
            }
        }
        return result
    }

    override func shouldCloseOnReadError(_ err: Error) -> Bool {
        guard let err = err as? IOError else { return true }

        switch err.errnoCode {
        case ECONNABORTED,
             EMFILE,
             ENFILE,
             ENOBUFS,
             ENOMEM:
            // These are errors we may be able to recover from. The user may just want to stop accepting connections for example
            // or provide some other means of back-pressure. This could be achieved by a custom ChannelDuplexHandler.
            return false
        default:
            return true
        }
    }

    override func cancelWritesOnClose(error: Error) {
        // No writes to cancel.
        return
    }

    override public func channelRead0(_ data: NIOAny) {
        assert(eventLoop.inEventLoop)

        let ch = data.forceAsOther() as SocketChannel
        ch.eventLoop.execute {
            ch.register().thenThrowing {
                guard ch.isOpen else {
                    throw ChannelError.ioOnClosedChannel
                }
                ch.becomeActive0(promise: nil)
            }.whenFailure { error in
                ch.close(promise: nil)
            }
        }
    }

    override func bufferPendingWrite(data: NIOAny, promise: EventLoopPromise<Void>?) {
        promise?.fail(error: ChannelError.operationUnsupported)
    }

    override func markFlushPoint() {
        // We do nothing here: flushes are no-ops.
    }

    override func flushNow() -> IONotificationState {
        return IONotificationState.unregister
    }
}

/// A channel used with datagram sockets.
///
/// Currently this channel is in an early stage. It supports only unconnected
/// datagram sockets, and does not currently support either multicast or
/// broadcast send or receive.
///
/// The following features are well worth adding:
///
/// - Multicast support
/// - Broadcast support
/// - Connected mode
final class DatagramChannel: BaseSocketChannel<Socket> {

    // Guard against re-entrance of flushNow() method.
    private let pendingWrites: PendingDatagramWritesManager

    // This is `Channel` API so must be thread-safe.
    override public var isWritable: Bool {
        return pendingWrites.isWritable
    }

    override var isOpen: Bool {
        assert(eventLoop.inEventLoop)
        assert(super.isOpen == self.pendingWrites.isOpen)
        return super.isOpen
    }

    convenience init(eventLoop: SelectableEventLoop, descriptor: CInt) throws {
        let socket = Socket(descriptor: descriptor)

        do {
            try self.init(socket: socket, eventLoop: eventLoop)
        } catch {
            _ = try? socket.close()
            throw error
        }
    }

    init(eventLoop: SelectableEventLoop, protocolFamily: Int32) throws {
        let socket = try Socket(protocolFamily: protocolFamily, type: Posix.SOCK_DGRAM)
        do {
            try socket.setNonBlocking()
        } catch let err {
            _ = try? socket.close()
            throw err
        }

        self.pendingWrites = PendingDatagramWritesManager(msgs: eventLoop.msgs,
                                                          iovecs: eventLoop.iovecs,
                                                          addresses: eventLoop.addresses,
                                                          storageRefs: eventLoop.storageRefs)

        try super.init(socket: socket, eventLoop: eventLoop, recvAllocator: FixedSizeRecvByteBufferAllocator(capacity: 2048))
    }

    init(socket: Socket, parent: Channel? = nil, eventLoop: SelectableEventLoop) throws {
        try socket.setNonBlocking()
        self.pendingWrites = PendingDatagramWritesManager(msgs: eventLoop.msgs,
                                                          iovecs: eventLoop.iovecs,
                                                          addresses: eventLoop.addresses,
                                                          storageRefs: eventLoop.storageRefs)
        try super.init(socket: socket, parent: parent, eventLoop: eventLoop, recvAllocator: FixedSizeRecvByteBufferAllocator(capacity: 2048))
    }

    // MARK: Datagram Channel overrides required by BaseSocketChannel

    override func setOption0<T: ChannelOption>(option: T, value: T.OptionType) throws {
        assert(eventLoop.inEventLoop)

        guard isOpen else {
            throw ChannelError.ioOnClosedChannel
        }

        switch option {
        case _ as WriteSpinOption:
            pendingWrites.writeSpinCount = value as! UInt
        case _ as WriteBufferWaterMarkOption:
            pendingWrites.waterMark = value as! WriteBufferWaterMark
        default:
            try super.setOption0(option: option, value: value)
        }
    }

    override func getOption0<T: ChannelOption>(option: T) throws -> T.OptionType {
        assert(eventLoop.inEventLoop)

        guard isOpen else {
            throw ChannelError.ioOnClosedChannel
        }

        switch option {
        case _ as WriteSpinOption:
            return pendingWrites.writeSpinCount as! T.OptionType
        case _ as WriteBufferWaterMarkOption:
            return pendingWrites.waterMark as! T.OptionType
        default:
            return try super.getOption0(option: option)
        }
    }

    override func registrationFor(interested: SelectorEventSet) -> NIORegistration {
        return .datagramChannel(self, interested)
    }

    override func connectSocket(to address: SocketAddress) throws -> Bool {
        // For now we don't support operating in connected mode for datagram channels.
        throw ChannelError.operationUnsupported
    }

    override func finishConnectSocket() throws {
        // For now we don't support operating in connected mode for datagram channels.
        throw ChannelError.operationUnsupported
    }

    override func readFromSocket() throws -> ReadResult {
        var rawAddress = sockaddr_storage()
        var rawAddressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        var buffer = self.recvAllocator.buffer(allocator: self.allocator)
        var readResult = ReadResult.none

        for i in 1...self.maxMessagesPerRead {
            guard self.isOpen else {
                throw ChannelError.eof
            }
            buffer.clear()

            let result = try buffer.withMutableWritePointer {
                try self.socket.recvfrom(pointer: $0, storage: &rawAddress, storageLen: &rawAddressLength)
            }
            switch result {
            case .processed(let bytesRead):
                assert(bytesRead > 0)
                assert(self.isOpen)
                let mayGrow = recvAllocator.record(actualReadBytes: bytesRead)
                readPending = false

                let msg = AddressedEnvelope(remoteAddress: rawAddress.convert(), data: buffer)
                assert(self.isActive)
                pipeline.fireChannelRead0(NIOAny(msg))
                if mayGrow && i < maxMessagesPerRead {
                    buffer = recvAllocator.buffer(allocator: allocator)
                }
                readResult = .some
            case .wouldBlock(let bytesRead):
                assert(bytesRead == 0)
                return readResult
            }
        }
        return readResult
    }

    override func shouldCloseOnReadError(_ err: Error) -> Bool {
        guard let err = err as? IOError else { return true }

        switch err.errnoCode {
        // ECONNREFUSED can happen on linux if the previous sendto(...) failed.
        // See also:
        // -    https://bugzilla.redhat.com/show_bug.cgi?id=1375
        // -    https://lists.gt.net/linux/kernel/39575
        case ECONNREFUSED,
             ENOMEM:
            // These are errors we may be able to recover from.
            return false
        default:
            return true
        }
    }
    /// Buffer a write in preparation for a flush.
    override func bufferPendingWrite(data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard let data = data.tryAsByteEnvelope() else {
            promise?.fail(error: ChannelError.writeDataUnsupported)
            return
        }

        if !self.pendingWrites.add(envelope: data, promise: promise) {
            assert(self.isActive)
            pipeline.fireChannelWritabilityChanged0()
        }
    }

    /// Mark a flush point. This is called when flush is received, and instructs
    /// the implementation to record the flush.
    override func markFlushPoint() {
        // Even if writable() will be called later by the EventLoop we still need to mark the flush checkpoint so we are sure all the flushed messages
        // are actually written once writable() is called.
        self.pendingWrites.markFlushCheckpoint()
    }

    /// Called when closing, to instruct the specific implementation to discard all pending
    /// writes.
    override func cancelWritesOnClose(error: Error) {
        self.pendingWrites.failAll(error: error, close: true)
    }

    override func writeToSocket() throws -> OverallWriteResult {
        let result = try self.pendingWrites.triggerAppropriateWriteOperations(scalarWriteOperation: { (ptr, destinationPtr, destinationSize) in
            guard ptr.count > 0 else {
                // No need to call write if the buffer is empty.
                return .processed(0)
            }
            // normal write
            return try self.socket.sendto(pointer: ptr,
                                          destinationPtr: destinationPtr,
                                          destinationSize: destinationSize)
        }, vectorWriteOperation: { msgs in
            try self.socket.sendmmsg(msgs: msgs)
        })
        if result.writable {
            // writable again
            assert(self.isActive)
            self.pipeline.fireChannelWritabilityChanged0()
        }
        return result.writeResult
    }

    // MARK: Datagram Channel overrides not required by BaseSocketChannel

    override func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        assert(self.eventLoop.inEventLoop)
        guard self.isRegistered else {
            promise?.fail(error: ChannelLifecycleError.inappropriateOperationForState)
            return
        }
        do {
            try socket.bind(to: address)
            self.updateCachedAddressesFromSocket(updateRemote: false)
            becomeActive0(promise: promise)
        } catch let err {
            promise?.fail(error: err)
        }
    }
}

extension SocketChannel: CustomStringConvertible {
    var description: String {
        return "SocketChannel { selectable = \(self.selectable), localAddress = \(self.localAddress.debugDescription), remoteAddress = \(self.remoteAddress.debugDescription) }"
    }
}

extension ServerSocketChannel: CustomStringConvertible {
    var description: String {
        return "ServerSocketChannel { selectable = \(self.selectable), localAddress = \(self.localAddress.debugDescription), remoteAddress = \(self.remoteAddress.debugDescription) }"
    }
}

extension DatagramChannel: CustomStringConvertible {
    var description: String {
        return "DatagramChannel { selectable = \(self.selectable), localAddress = \(self.localAddress.debugDescription), remoteAddress = \(self.remoteAddress.debugDescription) }"
    }
}
