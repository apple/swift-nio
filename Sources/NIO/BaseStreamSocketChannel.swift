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

class BaseStreamSocketChannel<Socket: SocketProtocol>: BaseSocketChannel<Socket> {
    internal var connectTimeoutScheduled: Optional<Scheduled<Void>>
    private var allowRemoteHalfClosure: Bool = false
    private var inputShutdown: Bool = false
    private var outputShutdown: Bool = false
    private let pendingWrites: PendingStreamWritesManager

    override init(socket: Socket,
                  parent: Channel?,
                  eventLoop: SelectableEventLoop,
                  recvAllocator: RecvByteBufferAllocator) throws {
        self.pendingWrites = PendingStreamWritesManager(iovecs: eventLoop.iovecs, storageRefs: eventLoop.storageRefs)
        self.connectTimeoutScheduled = nil
        try super.init(socket: socket, parent: parent, eventLoop: eventLoop, recvAllocator: recvAllocator)
    }

    deinit {
        // We should never have any pending writes left as otherwise we may leak callbacks
        assert(self.pendingWrites.isEmpty)
    }

    // MARK: BaseSocketChannel's must override API that might be further refined by subclasses
    override func setOption0<Option: ChannelOption>(_ option: Option, value: Option.Value) throws {
        self.eventLoop.assertInEventLoop()

        guard self.isOpen else {
            throw ChannelError.ioOnClosedChannel
        }

        switch option {
        case _ as ChannelOptions.Types.AllowRemoteHalfClosureOption:
            self.allowRemoteHalfClosure = value as! Bool
        case _ as ChannelOptions.Types.WriteSpinOption:
            self.pendingWrites.writeSpinCount = value as! UInt
        case _ as ChannelOptions.Types.WriteBufferWaterMarkOption:
            self.pendingWrites.waterMark = value as! ChannelOptions.Types.WriteBufferWaterMark
        default:
            try super.setOption0(option, value: value)
        }
    }

    override func getOption0<Option: ChannelOption>(_ option: Option) throws -> Option.Value {
        self.eventLoop.assertInEventLoop()

        guard self.isOpen else {
            throw ChannelError.ioOnClosedChannel
        }

        switch option {
        case _ as ChannelOptions.Types.AllowRemoteHalfClosureOption:
            return self.allowRemoteHalfClosure as! Option.Value
        case _ as ChannelOptions.Types.WriteSpinOption:
            return self.pendingWrites.writeSpinCount as! Option.Value
        case _ as ChannelOptions.Types.WriteBufferWaterMarkOption:
            return self.pendingWrites.waterMark as! Option.Value
        default:
            return try super.getOption0(option)
        }
    }

    // MARK: BaseSocketChannel's must override API that cannot be further refined by subclasses
    // This is `Channel` API so must be thread-safe.
    final override public var isWritable: Bool {
        return self.pendingWrites.isWritable
    }

    final override var isOpen: Bool {
        self.eventLoop.assertInEventLoop()
        assert(super.isOpen == self.pendingWrites.isOpen)
        return super.isOpen
    }

    final override func readFromSocket() throws -> ReadResult {
        self.eventLoop.assertInEventLoop()
        // Just allocate one time for the while read loop. This is fine as ByteBuffer is a struct and uses COW.
        var buffer = self.recvAllocator.buffer(allocator: allocator)
        var result = ReadResult.none
        for i in 1...self.maxMessagesPerRead {
            guard self.isOpen && !self.inputShutdown else {
                throw ChannelError.eof
            }
            // Reset reader and writerIndex and so allow to have the buffer filled again. This is better here than at
            // the end of the loop to not do an allocation when the loop exits.
            buffer.clear()
            switch try buffer.withMutableWritePointer(body: { try self.socket.read(pointer: $0) }) {
            case .processed(let bytesRead):
                if bytesRead > 0 {
                    let mayGrow = recvAllocator.record(actualReadBytes: bytesRead)

                    self.readPending = false

                    assert(self.isActive)
                    self.pipeline.fireChannelRead0(NIOAny(buffer))
                    result = .some

                    if buffer.writableBytes > 0 {
                        // If we did not fill the whole buffer with read(...) we should stop reading and wait until we get notified again.
                        // Otherwise chances are good that the next read(...) call will either read nothing or only a very small amount of data.
                        // Also this will allow us to call fireChannelReadComplete() which may give the user the chance to flush out all pending
                        // writes.
                        return result
                    } else if mayGrow && i < self.maxMessagesPerRead {
                        // if the ByteBuffer may grow on the next allocation due we used all the writable bytes we should allocate a new `ByteBuffer` to allow ramping up how much data
                        // we are able to read on the next read operation.
                        buffer = self.recvAllocator.buffer(allocator: allocator)
                    }
                } else {
                    if self.inputShutdown {
                        // We received a EOF because we called shutdown on the fd by ourself, unregister from the Selector and return
                        self.readPending = false
                        self.unregisterForReadable()
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

    final override func writeToSocket() throws -> OverallWriteResult {
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
        return result
    }

    final override func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        do {
            switch mode {
            case .output:
                if self.outputShutdown {
                    promise?.fail(ChannelError.outputClosed)
                    return
                }
                try self.socket.shutdown(how: .WR)
                self.outputShutdown = true
                // Fail all pending writes and so ensure all pending promises are notified
                self.pendingWrites.failAll(error: error, close: false)
                self.unregisterForWritable()
                promise?.succeed(())

                self.pipeline.fireUserInboundEventTriggered(ChannelEvent.outputClosed)

            case .input:
                if self.inputShutdown {
                    promise?.fail(ChannelError.inputClosed)
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
                self.inputShutdown = true
                self.unregisterForReadable()
                promise?.succeed(())

                self.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
            case .all:
                if let timeout = self.connectTimeoutScheduled {
                    self.connectTimeoutScheduled = nil
                    timeout.cancel()
                }
                super.close0(error: error, mode: mode, promise: promise)
            }
        } catch let err {
            promise?.fail(err)
        }
    }

    final override func hasFlushedPendingWrites() -> Bool {
        return self.pendingWrites.isFlushPending
    }

    final override func markFlushPoint() {
        // Even if writable() will be called later by the EventLoop we still need to mark the flush checkpoint so we are sure all the flushed messages
        // are actually written once writable() is called.
        self.pendingWrites.markFlushCheckpoint()
    }

    final override func cancelWritesOnClose(error: Error) {
        self.pendingWrites.failAll(error: error, close: true)
    }

    @discardableResult
    final override func readIfNeeded0() -> Bool {
        if self.inputShutdown {
            return false
        }
        return super.readIfNeeded0()
    }

    final override public func read0() {
        if self.inputShutdown {
            return
        }
        super.read0()
    }

    final override func bufferPendingWrite(data: NIOAny, promise: EventLoopPromise<Void>?) {
        if self.outputShutdown {
            promise?.fail(ChannelError.outputClosed)
            return
        }

        let data = data.forceAsIOData()

        if !self.pendingWrites.add(data: data, promise: promise) {
            self.pipeline.fireChannelWritabilityChanged0()
        }
    }
}
