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

extension ByteBuffer {
    mutating func withMutableWritePointer(body: (UnsafeMutableRawBufferPointer) throws -> IOResult<Int>) rethrows -> IOResult<Int> {
        var singleResult: IOResult<Int>!
        _ = try self.writeWithUnsafeMutableBytes(minimumWritableBytes: 0) { ptr in
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
final class SocketChannel: BaseStreamSocketChannel<Socket> {
    private var connectTimeout: TimeAmount? = nil

    init(eventLoop: SelectableEventLoop, protocolFamily: Int32) throws {
        let socket = try Socket(protocolFamily: protocolFamily, type: Posix.SOCK_STREAM, setNonBlocking: true)
        try super.init(socket: socket, parent: nil, eventLoop: eventLoop, recvAllocator: AdaptiveRecvByteBufferAllocator())
    }

    init(eventLoop: SelectableEventLoop, descriptor: CInt) throws {
        let socket = try Socket(descriptor: descriptor, setNonBlocking: true)
        try super.init(socket: socket, parent: nil, eventLoop: eventLoop, recvAllocator: AdaptiveRecvByteBufferAllocator())
    }

    init(socket: Socket, parent: Channel? = nil, eventLoop: SelectableEventLoop) throws {
        try super.init(socket: socket, parent: parent, eventLoop: eventLoop, recvAllocator: AdaptiveRecvByteBufferAllocator())
    }

    override func setOption0<Option: ChannelOption>(_ option: Option, value: Option.Value) throws {
        self.eventLoop.assertInEventLoop()

        guard isOpen else {
            throw ChannelError.ioOnClosedChannel
        }

        switch option {
        case _ as ChannelOptions.Types.ConnectTimeoutOption:
            connectTimeout = value as? TimeAmount
        default:
            try super.setOption0(option, value: value)
        }
    }

    override func getOption0<Option: ChannelOption>(_ option: Option) throws -> Option.Value {
        self.eventLoop.assertInEventLoop()

        guard isOpen else {
            throw ChannelError.ioOnClosedChannel
        }

        switch option {
        case _ as ChannelOptions.Types.ConnectTimeoutOption:
            return connectTimeout as! Option.Value
        default:
            return try super.getOption0(option)
        }
    }

    func registrationFor(interested: SelectorEventSet) -> NIORegistration {
        return .socketChannel(self, interested)
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


    override func register(selector: Selector<NIORegistration>, interested: SelectorEventSet) throws {
        try selector.register(selectable: self.socket, interested: interested, makeRegistration: self.registrationFor(interested:))
    }

    override func deregister(selector: Selector<NIORegistration>, mode: CloseMode) throws {
        assert(mode == .all)
        try selector.deregister(selectable: self.socket)
    }

    override func reregister(selector: Selector<NIORegistration>, interested: SelectorEventSet) throws {
        try selector.reregister(selectable: self.socket, interested: interested)
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
        try super.init(socket: serverSocket,
                       parent: nil,
                       eventLoop: eventLoop,
                       recvAllocator: AdaptiveRecvByteBufferAllocator())
    }

    convenience init(descriptor: CInt, eventLoop: SelectableEventLoop, group: EventLoopGroup) throws {
        let socket = try ServerSocket(descriptor: descriptor, setNonBlocking: true)
        try self.init(serverSocket: socket, eventLoop: eventLoop, group: group)
        try self.socket.listen(backlog: backlog)
    }

    func registrationFor(interested: SelectorEventSet) -> NIORegistration {
        return .serverSocketChannel(self, interested)
    }

    override func setOption0<Option: ChannelOption>(_ option: Option, value: Option.Value) throws {
        self.eventLoop.assertInEventLoop()

        guard isOpen else {
            throw ChannelError.ioOnClosedChannel
        }

        switch option {
        case _ as ChannelOptions.Types.BacklogOption:
            backlog = value as! Int32
        default:
            try super.setOption0(option, value: value)
        }
    }

    override func getOption0<Option: ChannelOption>(_ option: Option) throws -> Option.Value {
        self.eventLoop.assertInEventLoop()

        guard isOpen else {
            throw ChannelError.ioOnClosedChannel
        }

        switch option {
        case _ as ChannelOptions.Types.BacklogOption:
            return backlog as! Option.Value
        default:
            return try super.getOption0(option)
        }
    }

    override public func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.eventLoop.assertInEventLoop()

        guard self.isOpen else {
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }

        guard self.isRegistered else {
            promise?.fail(ChannelError.inappropriateOperationForState)
            return
        }

        let p = eventLoop.makePromise(of: Void.self)
        p.futureResult.map {
            // It's important to call the methods before we actually notify the original promise for ordering reasons.
            self.becomeActive0(promise: promise)
        }.whenFailure{ error in
            promise?.fail(error)
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
            if let accepted = try self.socket.accept(setNonBlocking: true) {
                readPending = false
                result = .some
                do {
                    let chan = try SocketChannel(socket: accepted,
                                                 parent: self,
                                                 eventLoop: group.next() as! SelectableEventLoop)
                    assert(self.isActive)
                    pipeline.fireChannelRead0(NIOAny(chan))
                } catch {
                    try? accepted.close()
                    throw error
                }
            } else {
                break
            }
        }
        return result
    }

    override func shouldCloseOnReadError(_ err: Error) -> Bool {
        if err is NIOFailedToSetSocketNonBlockingError {
            // see https://github.com/apple/swift-nio/issues/1030
            // on Darwin, fcntl(fd, F_SETFL, O_NONBLOCK) sometimes returns EINVAL...
            return false
        }
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
        self.eventLoop.assertInEventLoop()

        let ch = data.forceAsOther() as SocketChannel
        ch.eventLoop.execute {
            ch.register().flatMapThrowing {
                guard ch.isOpen else {
                    throw ChannelError.ioOnClosedChannel
                }
                ch.becomeActive0(promise: nil)
            }.whenFailure { error in
                ch.close(promise: nil)
            }
        }
    }

    override func hasFlushedPendingWrites() -> Bool {
        return false
    }

    override func bufferPendingWrite(data: NIOAny, promise: EventLoopPromise<Void>?) {
        promise?.fail(ChannelError.operationUnsupported)
    }

    override func markFlushPoint() {
        // We do nothing here: flushes are no-ops.
    }

    override func flushNow() -> IONotificationState {
        return IONotificationState.unregister
    }

    override func register(selector: Selector<NIORegistration>, interested: SelectorEventSet) throws {
        try selector.register(selectable: self.socket, interested: interested, makeRegistration: self.registrationFor(interested:))
    }

    override func deregister(selector: Selector<NIORegistration>, mode: CloseMode) throws {
        assert(mode == .all)
        try selector.deregister(selectable: self.socket)
    }

    override func reregister(selector: Selector<NIORegistration>, interested: SelectorEventSet) throws {
        try selector.reregister(selectable: self.socket, interested: interested)
    }
}

/// A channel used with datagram sockets.
///
/// Currently, it does not support connected mode which is well worth adding.
final class DatagramChannel: BaseSocketChannel<Socket> {

    // Guard against re-entrance of flushNow() method.
    private let pendingWrites: PendingDatagramWritesManager

    /// Support for vector reads, if enabled.
    private var vectorReadManager: Optional<DatagramVectorReadManager>

    // This is `Channel` API so must be thread-safe.
    override public var isWritable: Bool {
        return pendingWrites.isWritable
    }

    override var isOpen: Bool {
        self.eventLoop.assertInEventLoop()
        assert(super.isOpen == self.pendingWrites.isOpen)
        return super.isOpen
    }

    convenience init(eventLoop: SelectableEventLoop, descriptor: CInt) throws {
        let socket = try Socket(descriptor: descriptor)

        do {
            try self.init(socket: socket, eventLoop: eventLoop)
        } catch {
            try? socket.close()
            throw error
        }
    }

    deinit {
        if var vectorReadManager = self.vectorReadManager {
            vectorReadManager.deallocate()
        }
    }

    init(eventLoop: SelectableEventLoop, protocolFamily: Int32) throws {
        self.vectorReadManager = nil
        let socket = try Socket(protocolFamily: protocolFamily, type: Posix.SOCK_DGRAM)
        do {
            try socket.setNonBlocking()
        } catch let err {
            try? socket.close()
            throw err
        }

        self.pendingWrites = PendingDatagramWritesManager(msgs: eventLoop.msgs,
                                                          iovecs: eventLoop.iovecs,
                                                          addresses: eventLoop.addresses,
                                                          storageRefs: eventLoop.storageRefs)

        try super.init(socket: socket,
                       parent: nil,
                       eventLoop: eventLoop,
                       recvAllocator: FixedSizeRecvByteBufferAllocator(capacity: 2048))
    }

    init(socket: Socket, parent: Channel? = nil, eventLoop: SelectableEventLoop) throws {
        self.vectorReadManager = nil
        try socket.setNonBlocking()
        self.pendingWrites = PendingDatagramWritesManager(msgs: eventLoop.msgs,
                                                          iovecs: eventLoop.iovecs,
                                                          addresses: eventLoop.addresses,
                                                          storageRefs: eventLoop.storageRefs)
        try super.init(socket: socket, parent: parent, eventLoop: eventLoop, recvAllocator: FixedSizeRecvByteBufferAllocator(capacity: 2048))
    }

    // MARK: Datagram Channel overrides required by BaseSocketChannel

    override func setOption0<Option: ChannelOption>(_ option: Option, value: Option.Value) throws {
        self.eventLoop.assertInEventLoop()

        guard isOpen else {
            throw ChannelError.ioOnClosedChannel
        }

        switch option {
        case _ as ChannelOptions.Types.WriteSpinOption:
            pendingWrites.writeSpinCount = value as! UInt
        case _ as ChannelOptions.Types.WriteBufferWaterMarkOption:
            pendingWrites.waterMark = value as! ChannelOptions.Types.WriteBufferWaterMark
        case _ as ChannelOptions.Types.DatagramVectorReadMessageCountOption:
            // We only support vector reads on these OSes. Let us know if there's another OS with this syscall!
            #if os(Linux) || os(FreeBSD) || os(Android)
            self.vectorReadManager.updateMessageCount(value as! Int)
            #else
            break
            #endif
        default:
            try super.setOption0(option, value: value)
        }
    }

    override func getOption0<Option: ChannelOption>(_ option: Option) throws -> Option.Value {
        self.eventLoop.assertInEventLoop()

        guard isOpen else {
            throw ChannelError.ioOnClosedChannel
        }

        switch option {
        case _ as ChannelOptions.Types.WriteSpinOption:
            return pendingWrites.writeSpinCount as! Option.Value
        case _ as ChannelOptions.Types.WriteBufferWaterMarkOption:
            return pendingWrites.waterMark as! Option.Value
        case _ as ChannelOptions.Types.DatagramVectorReadMessageCountOption:
            return (self.vectorReadManager?.messageCount ?? 0) as! Option.Value
        default:
            return try super.getOption0(option)
        }
    }

    func registrationFor(interested: SelectorEventSet) -> NIORegistration {
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
        if self.vectorReadManager != nil {
            return try self.vectorReadFromSocket()
        } else {
            return try self.singleReadFromSocket()
        }
    }

    private func singleReadFromSocket() throws -> ReadResult {
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

    private func vectorReadFromSocket() throws -> ReadResult {
        #if os(Linux) || os(FreeBSD) || os(Android)
        var buffer = self.recvAllocator.buffer(allocator: self.allocator)
        var readResult = ReadResult.none

        readLoop: for i in 1...self.maxMessagesPerRead {
            guard self.isOpen else {
                throw ChannelError.eof
            }
            guard let vectorReadManager = self.vectorReadManager else {
                // The vector read manager went away. This happens if users unset the vector read manager
                // during channelRead. It's unlikely, but we tolerate it by aborting the read early.
                break readLoop
            }
            buffer.clear()

            // This force-unwrap is safe, as we checked whether this is nil in the caller.
            let result = try vectorReadManager.readFromSocket(socket: self.socket, buffer: &buffer)
            switch result {
            case .some(let results, let totalRead):
                assert(self.isOpen)
                assert(self.isActive)

                let mayGrow = recvAllocator.record(actualReadBytes: totalRead)
                readPending = false

                var messageIterator = results.makeIterator()
                while self.isActive, let message = messageIterator.next() {
                    pipeline.fireChannelRead(NIOAny(message))
                }

                if mayGrow && i < maxMessagesPerRead {
                    buffer = recvAllocator.buffer(allocator: allocator)
                }
                readResult = .some
            case .none:
                break readLoop
            }
        }

        return readResult
        #else
        fatalError("Cannot perform vector reads on this operating system")
        #endif
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
        let data = data.forceAsByteEnvelope()

        if !self.pendingWrites.add(envelope: data, promise: promise) {
            assert(self.isActive)
            pipeline.fireChannelWritabilityChanged0()
        }
    }

    override final func hasFlushedPendingWrites() -> Bool {
        return self.pendingWrites.isFlushPending
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
        return result
    }

    // MARK: Datagram Channel overrides not required by BaseSocketChannel

    override func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        self.eventLoop.assertInEventLoop()
        guard self.isRegistered else {
            promise?.fail(ChannelError.inappropriateOperationForState)
            return
        }
        do {
            try socket.bind(to: address)
            self.updateCachedAddressesFromSocket(updateRemote: false)
            becomeActive0(promise: promise)
        } catch let err {
            promise?.fail(err)
        }
    }

    override func register(selector: Selector<NIORegistration>, interested: SelectorEventSet) throws {
        try selector.register(selectable: self.socket, interested: interested, makeRegistration: self.registrationFor(interested:))
    }

    override func deregister(selector: Selector<NIORegistration>, mode: CloseMode) throws {
        assert(mode == .all)
        try selector.deregister(selectable: self.socket)
    }

    override func reregister(selector: Selector<NIORegistration>, interested: SelectorEventSet) throws {
        try selector.reregister(selectable: self.socket, interested: interested)
    }
}

extension SocketChannel: CustomStringConvertible {
    var description: String {
        return "SocketChannel { \(self.socketDescription), active = \(self.isActive), localAddress = \(self.localAddress.debugDescription), remoteAddress = \(self.remoteAddress.debugDescription) }"
    }
}

extension ServerSocketChannel: CustomStringConvertible {
    var description: String {
        return "ServerSocketChannel { \(self.socketDescription), active = \(self.isActive), localAddress = \(self.localAddress.debugDescription), remoteAddress = \(self.remoteAddress.debugDescription) }"
    }
}

extension DatagramChannel: CustomStringConvertible {
    var description: String {
        return "DatagramChannel { \(self.socketDescription), active = \(self.isActive), localAddress = \(self.localAddress.debugDescription), remoteAddress = \(self.remoteAddress.debugDescription) }"
    }
}

extension DatagramChannel: MulticastChannel {
    /// The socket options for joining and leaving multicast groups are very similar.
    /// This enum allows us to write a single function to do all the work, and then
    /// at the last second pull out the correct socket option name.
    private enum GroupOperation {
        /// Join a multicast group.
        case join

        /// Leave a multicast group.
        case leave

        /// Given a socket option level, returns the appropriate socket option name for
        /// this group operation.
        ///
        /// - parameters:
        ///     - level: The socket option level. Must be one of `IPPROTO_IP` or
        ///         `IPPROTO_IPV6`. Will trap if an invalid value is provided.
        /// - returns: The socket option name to use for this group operation.
        func optionName(level: CInt) -> CInt {
            switch (self, level) {
            case (.join, CInt(IPPROTO_IP)):
                return CInt(IP_ADD_MEMBERSHIP)
            case (.leave, CInt(IPPROTO_IP)):
                return CInt(IP_DROP_MEMBERSHIP)
            case (.join, CInt(IPPROTO_IPV6)):
                return CInt(IPV6_JOIN_GROUP)
            case (.leave, CInt(IPPROTO_IPV6)):
                return CInt(IPV6_LEAVE_GROUP)
            default:
                preconditionFailure("Unexpected socket option level: \(level)")
            }
        }
    }

    func joinGroup(_ group: SocketAddress, interface: NIONetworkInterface?, promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            self.performGroupOperation0(group, interface: interface, promise: promise, operation: .join)
        } else {
            eventLoop.execute {
                self.performGroupOperation0(group, interface: interface, promise: promise, operation: .join)
            }
        }
    }

    func leaveGroup(_ group: SocketAddress, interface: NIONetworkInterface?, promise: EventLoopPromise<Void>?) {
        if eventLoop.inEventLoop {
            self.performGroupOperation0(group, interface: interface, promise: promise, operation: .leave)
        } else {
            eventLoop.execute {
                self.performGroupOperation0(group, interface: interface, promise: promise, operation: .leave)
            }
        }
    }

    /// The implementation of `joinGroup` and `leaveGroup`.
    ///
    /// Joining and leaving a multicast group ultimately corresponds to a single, carefully crafted, socket option.
    private func performGroupOperation0(_ group: SocketAddress,
                                        interface: NIONetworkInterface?,
                                        promise: EventLoopPromise<Void>?,
                                        operation: GroupOperation) {
        self.eventLoop.assertInEventLoop()

        guard self.isActive else {
            promise?.fail(ChannelError.inappropriateOperationForState)
            return
        }

        /// Check if the interface supports multicast
        if let interface = interface {
            guard interface.multicastSupported else {
                promise?.fail(ChannelError.multicastNotSupported(interface))
                return
            }
        }

        // We need to check that we have the appropriate address types in all cases. They all need to overlap with
        // the address type of this channel, or this cannot work.
        guard let localAddress = self.localAddress else {
            promise?.fail(ChannelError.unknownLocalAddress)
            return
        }

        guard localAddress.protocolFamily == group.protocolFamily else {
            promise?.fail(ChannelError.badMulticastGroupAddressFamily)
            return
        }

        // Ok, now we need to check that the group we've been asked to join is actually a multicast group.
        guard group.isMulticast else {
            promise?.fail(ChannelError.illegalMulticastAddress(group))
            return
        }

        // Ok, we now have reason to believe this will actually work. We need to pass this on to the socket.
        do {
            switch (group, interface?.address) {
            case (.unixDomainSocket, _):
                preconditionFailure("Should not be reachable, UNIX sockets are never multicast addresses")
            case (.v4(let groupAddress), .some(.v4(let interfaceAddress))):
                // IPv4Binding with specific target interface.
                let multicastRequest = ip_mreq(imr_multiaddr: groupAddress.address.sin_addr, imr_interface: interfaceAddress.address.sin_addr)
                try self.socket.setOption(level: CInt(IPPROTO_IP), name: operation.optionName(level: CInt(IPPROTO_IP)), value: multicastRequest)
            case (.v4(let groupAddress), .none):
                // IPv4 binding without target interface.
                let multicastRequest = ip_mreq(imr_multiaddr: groupAddress.address.sin_addr, imr_interface: in_addr(s_addr: INADDR_ANY))
                try self.socket.setOption(level: CInt(IPPROTO_IP), name: operation.optionName(level: CInt(IPPROTO_IP)), value: multicastRequest)
            case (.v6(let groupAddress), .some(.v6)):
                // IPv6 binding with specific target interface.
                let multicastRequest = ipv6_mreq(ipv6mr_multiaddr: groupAddress.address.sin6_addr, ipv6mr_interface: UInt32(interface!.interfaceIndex))
                try self.socket.setOption(level: CInt(IPPROTO_IPV6), name: operation.optionName(level: CInt(IPPROTO_IPV6)), value: multicastRequest)
            case (.v6(let groupAddress), .none):
                // IPv6 binding with no specific interface requested.
                let multicastRequest = ipv6_mreq(ipv6mr_multiaddr: groupAddress.address.sin6_addr, ipv6mr_interface: 0)
                try self.socket.setOption(level: CInt(IPPROTO_IPV6), name: operation.optionName(level: CInt(IPPROTO_IPV6)), value: multicastRequest)
            case (.v4, .some(.v6)), (.v6, .some(.v4)), (.v4, .some(.unixDomainSocket)), (.v6, .some(.unixDomainSocket)):
                // Mismatched group and interface address: this is an error.
                throw ChannelError.badInterfaceAddressFamily
            }

            promise?.succeed(())
        } catch {
            promise?.fail(error)
            return
        }
    }
}
