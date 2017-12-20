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

#if os(Linux)
import Glibc
#else
import Darwin
#endif

private typealias PendingWrite = (data: IOData, promise: EventLoopPromise<Void>?)

private func doPendingWriteVectorOperation(pending: PendingWritesState,
                                           iovecs: UnsafeMutableBufferPointer<IOVector>,
                                           storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>,
                                           _ fn: (UnsafeBufferPointer<IOVector>) throws -> IOResult<Int>) throws -> IOResult<Int> {
    assert(iovecs.count >= Socket.writevLimitIOVectors, "Insufficiently sized buffer for a maximal writev")

    // Clamp the number of writes we're willing to issue to the limit for writev.
    let count = min(pending.flushedChunks, Socket.writevLimitIOVectors)
    
    // the numbers of storage refs that we need to decrease later.
    var c = 0

    var toWrite: Int = 0

    loop: for i in 0..<count {
        let p = pending[i]
        switch p.data {
        case .byteBuffer(let buffer):
            // Must not write more than Int32.max in one go.
            guard (c == 0) || (Socket.writevLimitBytes - toWrite >= buffer.readableBytes) else {
                break loop
            }
            let toWriteForThisBuffer = min(Socket.writevLimitBytes, buffer.readableBytes)
            toWrite += toWriteForThisBuffer

            buffer.withUnsafeReadableBytesWithStorageManagement { ptr, storageRef in
                storageRefs[i] = storageRef.retain()
                iovecs[i] = iovec(iov_base: UnsafeMutableRawPointer(mutating: ptr.baseAddress!), iov_len: toWriteForThisBuffer)
            }
            c += 1
        case .fileRegion(_):
            // We found a FileRegion so stop collecting
            break loop
        }
    }
    defer {
        for i in 0..<c {
            storageRefs[i].release()
        }
    }
    let result = try fn(UnsafeBufferPointer(start: iovecs.baseAddress!, count: c))
    return result
}

/// The high-level result of a write operation.
/* private but tests */ enum WriteResult {
    /// Wrote everything asked.
    case writtenCompletely

    /// Wrote some portion of what was asked.
    case writtenPartially

    /// There was nothing to be written.
    case nothingToBeWritten

    /// Could not write as doing that would have blocked.
    case wouldBlock

    /// Could not write as the underlying descriptor is closed.
    case closed
}

/// This holds the states of the currently pending writes. The core is a `MarkedCircularBuffer` which holds all the
/// writes and a mark up until the point the data is flushed.
///
/// The most important operations on this object are:
///  - `append` to add an `IOData` to the list of pending writes.
///  - `markFlushCheckpoint` which sets a flush mark on the current position of the `MarkedCircularBuffer`. All the items before the checkpoint will be written eventually.
///  - `didWrite` when a number of bytes have been written.
///  - `failAll` if for some reason all outstanding writes need to be discarded and the corresponding `EventLoopPromise` needs to be failed.
private struct PendingWritesState {
    private var pendingWrites = MarkedCircularBuffer<PendingWrite>(initialRingCapacity: 16)
    private var chunks: Int = 0
    public private(set) var bytes: Int = 0

    public var flushedChunks: Int {
        return self.pendingWrites.markedElementIndex().map { $0 + 1 } ?? 0
    }

    /// Subtract `bytes` from the number of outstanding bytes to write.
    private mutating func subtractOutstanding(bytes: Int) {
        assert(self.bytes >= bytes, "allegedly written more bytes (\(bytes)) than outstanding (\(self.bytes))")
        self.bytes -= bytes
    }

    /// Indicates that the first outstanding write was written in its entirety.
    ///
    /// - returns: The `EventLoopPromise` of the write or `nil` if none was provided. The promise needs to be fulfilled by the caller.
    ///
    private mutating func fullyWrittenFirst() -> EventLoopPromise<()>? {
        self.chunks -= 1
        let (data, promise) = self.pendingWrites.removeFirst()
        switch data {
        case .byteBuffer(let buffer):
            self.subtractOutstanding(bytes: buffer.readableBytes)
        case .fileRegion(_):
            () /* not accounting for file region sizes */
        }
        return promise
    }

    /// Indicates that the first outstanding object (a `ByteBuffer`) has been partially written.
    ///
    /// - parameters:
    ///     - buffer: The `ByteBuffer` that was partially written.
    ///     - bytes: How many bytes of the `ByteBuffer` were written.
    private mutating func partiallyWritten(buffer: ByteBuffer, bytes: Int) {
        assert(self.pendingWrites[0].data == .byteBuffer(buffer))
        var buffer = buffer
        buffer.moveReaderIndex(forwardBy: bytes)
        self.subtractOutstanding(bytes: bytes)
        self.pendingWrites[0] = (.byteBuffer(buffer), self.pendingWrites[0].promise)
    }

    /// Initialise a new, empty `PendingWritesState`.
    public init() {
    }

    /// Check if there are no outstanding writes.
    public var isEmpty: Bool {
        if self.pendingWrites.isEmpty {
            assert(self.chunks == 0)
            assert(self.bytes == 0)
            assert(!self.pendingWrites.hasMark())
            return true
        } else {
            assert(self.chunks > 0 && self.bytes >= 0)
            return false
        }
    }

    /// Add a new write and optionally the corresponding promise to the list of outstanding writes.
    public mutating func append(data: IOData, promise: EventLoopPromise<()>?) {
        self.pendingWrites.append((data: data, promise: promise))
        self.chunks += 1
        switch data {
        case .byteBuffer(let buffer):
            self.bytes += buffer.readableBytes
        case .fileRegion(_):
            () /* not accounting for file region sizes */
        }
    }

    /// Get the outstanding write at `index`.
    public subscript(index: Int) -> PendingWrite {
        return self.pendingWrites[index]
    }

    /// Mark the flush checkpoint.
    ///
    /// All writes before this checkpoint will eventually be written to the socket.
    ///
    /// - parameters:
    ///     - The flush promise.
    public mutating func markFlushCheckpoint(promise: EventLoopPromise<Void>?) {
        self.pendingWrites.mark()
        let checkpointIdx = self.pendingWrites.markedElementIndex()
        if let promise = promise, let checkpoint = checkpointIdx {
            if let p = self.pendingWrites[checkpoint].promise {
                p.futureResult.cascade(promise: promise)
            } else {
                self.pendingWrites[checkpoint].promise = promise
            }
        } else if let promise = promise {
            // No checkpoint index means this is a flush on empty, so we can
            // satisfy it immediately.
            promise.succeed(result: ())
        }
    }

    /// Are there at least two `ByteBuffer`s to be written (they must be flushed)? This helps to decide if we should
    /// call `writev` instead of `write` or `sendfile`.
    public var hasMultipleFlushedByteBuffers: Bool {
        guard self.flushedChunks > 1 else {
            return false
        }

        if case .byteBuffer(_) = self.pendingWrites[0].data, case .byteBuffer(_) = self.pendingWrites[1].data {
            // We have at least two flushed ByteBuffer in the PendingWrites
            return true
        }
        return false
    }

    /// Indicate that a write has happened, this may be a write of multiple outstanding writes (using for example `writev`).
    ///
    /// - warning: The closure will simply fulfill all the promises in order. If one of those promises does for example close the `Channel` we might see subsequent writes fail out of order. Example: Imagine the user issues three writes: `A`, `B` and `C`. Imagine that `A` and `B` both get successfully written in one write operation but the user closes the `Channel` in `A`'s callback. Then overall the promises will be fulfilled in this order: 1) `A`: success 2) `C`: error 3) `B`: success. Note how `B` and `C` get fulfilled out of order.
    ///
    /// - parameters:
    ///     - data: The result of the write operation.
    /// - returns: A closure that the caller _needs_ to run which will fulfill the promises of the writes and a `WriteResult` which indicates if we could write everything or not.
    public mutating func didWrite(_ data: IOResult<Int>) -> (() -> Void, WriteResult) {
        var promises: [EventLoopPromise<()>] = []
        let fulfillPromises = { promises.forEach { $0.succeed(result: ()) } }
        switch data {
        case .processed(let written):
            var unaccountedWrites = written
            var isFirst = true
            while !self.pendingWrites.isEmpty {
                defer {
                    isFirst = false
                }
                switch self.pendingWrites[0].data {
                case .byteBuffer(let buffer):
                    if unaccountedWrites >= buffer.readableBytes {
                        unaccountedWrites -= buffer.readableBytes
                        /* we wrote at least the whole first ByteBuffer, so drop it and succeed the promise */
                        if let promise = self.fullyWrittenFirst() {
                            promises.append(promise)
                        }

                        if unaccountedWrites == 0 && !self.pendingWrites.hasMark() {
                            /* we wrote fully if there's no unaccounted writes left and we don't have a flush mark anymore */
                            return (fulfillPromises, .writtenCompletely)
                        }
                    } else {
                        /* we could only write a part of the first ByteBuffer, so don't drop it but remember what we wrote */
                        self.partiallyWritten(buffer: buffer, bytes: unaccountedWrites)

                        // may try again depending on the writeSpinCount
                        return (fulfillPromises, .writtenPartially)
                    }
                case .fileRegion(let file):
                    /* we don't account for the bytes written with FileRegions, so we drop iff this is first object */
                    switch (isFirst, file.readableBytes) {
                    case (true, 0):
                        if let promise = self.fullyWrittenFirst() {
                            promises.append(promise)
                        }
                    case (true, let n) where n > 0:
                        /* this is sendfile returning success but writing short, only known to happen on Linux (and in the ChannelTests) */
                        assert(promises.isEmpty)
                        return (fulfillPromises, .writtenPartially) /* don't alter the state as we don't account for bytes written by sendfile */
                    case (false, _):
                        assert(unaccountedWrites == 0, "still got \(unaccountedWrites) bytes of unaccounted writes")
                    default:
                        fatalError("the impossible happened: didWrite \(file) with isFirst=\(isFirst), readableBytes=\(file.readableBytes)")
                    }
                    // We found a FileRegion so we cannot continue with gathering writes but will need to use sendfile. Let the user call us again so we can use sendfile.
                    return (fulfillPromises, .writtenCompletely)
                }
            }
            assert(unaccountedWrites == 0, "after doing all the accounting for the byte written, \(unaccountedWrites) bytes of unaccounted writes remain.")
        case .wouldBlock(let n) where n != 0:
            assert(n > 0, "sendfile returned negative amount of bytes written: \(n)")
            if _isDebugAssertConfiguration() {
                switch self.pendingWrites[0].data {
                case .byteBuffer(let buffer):
                    fatalError("write with .wouldBlock(\(n)) but a ByteBuffer (\(buffer)) was written")
                case .fileRegion(let file):
                    if file.readableBytes == 0 {
                        /* this is odd, sendfile wrote everything but notionally failed with EWOULDBLOCK. This happens on Darwin. */
                        if let promise = self.fullyWrittenFirst() {
                            promises.append(promise)
                        }
                        return (fulfillPromises, .writtenCompletely)
                    }
                }
            }
            /* we don't update here as we get non-zero only if sendfile was used and we don't track bytes to be sent as `FileRegion` */
            return (fulfillPromises, .writtenPartially)
        case .wouldBlock(_ /* this is 0 but the compiler can't prove it */):
            return (fulfillPromises, .wouldBlock)
        }
        return (fulfillPromises, .writtenPartially)
    }

    /// Is there a pending flush?
    public var isFlushPending: Bool {
        return self.pendingWrites.hasMark()
    }

    /// Fail all the outstanding writes.
    ///
    /// - warning: See the warning for `didWrite`.
    ///
    /// - returns: A closure that the caller _needs_ to run which will fulfill the promises.
    public mutating func failAll(error: Error) -> () -> Void {
        var promises: [EventLoopPromise<()>] = []
        promises.reserveCapacity(self.pendingWrites.count)
        while !self.pendingWrites.isEmpty {
            if let p = self.fullyWrittenFirst() {
                promises.append(p)
            }
        }
        return { promises.forEach { $0.fail(error: error) } }
    }
}

/// This class manages the writing of pending writes. The state is held in a `PendingWritesState` value. The most
/// important purpose of this object is to call `write`, `writev` or `sendfile` depending on the currently pending
/// writes.
/* private but tests */ final class PendingWritesManager {
    private var state = PendingWritesState()
    private var iovecs: UnsafeMutableBufferPointer<IOVector>
    private var storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>

    fileprivate fileprivate(set) var waterMark: WriteBufferWaterMark = WriteBufferWaterMark(32 * 1024..<64 * 1024)
    private var writable: Atomic<Bool> = Atomic(value: true)

    internal fileprivate(set) var writeSpinCount: UInt = 16

    private(set) var closed = false

    /// Mark the flush checkpoint.
    ///
    /// - parameters:
    ///     - The flush promise.
    func markFlushCheckpoint(promise: EventLoopPromise<()>?) {
        self.state.markFlushCheckpoint(promise: promise)
    }

    /// Is there a flush pending?
    var isFlushPending: Bool {
        return self.state.isFlushPending
    }

    /// Is the `Channel` currently writable?
    var isWritable: Bool {
        return writable.load()
    }

    /// Are there any outstanding writes currently?
    var isEmpty: Bool {
        return self.state.isEmpty
    }
    
    /// Add a pending write alongside its promise.
    ///
    /// - parameters:
    ///     - data: The `IOData` to write.
    ///     - promise: Optionally an `EventLoopPromise` that will get the write operation's result
    /// - result: If the `Channel` is still writable after adding the write of `data`.
    func add(data: IOData, promise: EventLoopPromise<Void>?) -> Bool {
        assert(!closed)
        self.state.append(data: data, promise: promise)

        if self.state.bytes > waterMark.upperBound && writable.compareAndExchange(expected: true, desired: false) {
            // Returns false to signal the Channel became non-writable and we need to notify the user
            return false
        }
        return true
    }

    /// Triggers the appropriate write operation. This is a fancy way of saying trigger either `write`, `writev` or
    /// `sendfile`.
    ///
    /// - parameters:
    ///     - singleWriteOperation: An operation that writes a single, contiguous array of bytes (usually `write`).
    ///     - vectorWriteOperation: An operation that writes multiple contiguous arrays of bytes (usually `writev`).
    ///     - fileWriteOperation: An operation that writes a region of a file descriptor.
    /// - returns: The `WriteResult` and whether the `Channel` is now writable.
    func triggerAppropriateWriteOperation(singleWriteOperation: (UnsafeRawBufferPointer) throws -> IOResult<Int>,
                                          vectorWriteOperation: (UnsafeBufferPointer<IOVector>) throws -> IOResult<Int>,
                                          fileWriteOperation: (Int32, Int, Int) throws -> IOResult<Int>) throws -> (writeResult: WriteResult, writable: Bool) {
        let wasWritable = writable.load()
        let result: WriteResult
        if self.state.hasMultipleFlushedByteBuffers {
            result = try triggerVectorWrite(vectorWriteOperation: vectorWriteOperation)
        } else {
            result = try triggerSingleWrite(singleWriteOperation: singleWriteOperation, fileWriteOperation: fileWriteOperation)
        }

        if !wasWritable {
            // Was not writable before so signal back to the caller the possible state change
            return (result, writable.load())
        }
        return (result, false)
    }

    /// To be called after a write operation (usually selected and run by `triggerAppropriateWriteOperation`) has
    /// completed.
    ///
    /// - parameters:
    ///     - data: The result of the write operation.
    private func didWrite(_ data: IOResult<Int>) -> WriteResult {
        let (fulfillPromises, result) = self.state.didWrite(data)

        if self.state.bytes < waterMark.lowerBound {
            writable.store(true)
        }

        fulfillPromises()
        return result
    }

    /// Trigger a write of a single object where an object can either be a contiguous array of bytes or a region of a file.
    ///
    /// - parameters:
    ///     - singleWriteOperation: An operation that writes a single, contiguous array of bytes (usually `write`).
    ///     - fileWriteOperation: An operation that writes a region of a file descriptor.
    private func triggerSingleWrite(singleWriteOperation: (UnsafeRawBufferPointer) throws -> IOResult<Int>,
                                    fileWriteOperation: (Int32, Int, Int) throws -> IOResult<Int>) rethrows -> WriteResult {
        if self.state.isFlushPending && !self.state.isEmpty {
            for _ in 0..<writeSpinCount {
                assert(!closed,
                       "Channel got closed during the spinning of a single write operation which should be impossible as we don't call out")
                let pending = self.state[0]
                switch pending.data {
                case .byteBuffer(let buffer):
                    switch self.didWrite(try buffer.withUnsafeReadableBytes(singleWriteOperation)) {
                    case .writtenPartially:
                        continue
                    case let other:
                        return other
                    }
                case .fileRegion(let file):
                    switch self.didWrite(try file.withMutableReader(fileWriteOperation)) {
                    case .writtenPartially:
                        continue
                    case let other:
                        return other
                    }
                }
            }
            return .writtenPartially
        }

        return .nothingToBeWritten
    }

    /// Trigger a vector write operation. In other words: Write multiple contiguous arrays of bytes.
    ///
    /// - parameters:
    ///     - vectorWriteOperation: The vector write operation to use. Usually `writev`.
    private func triggerVectorWrite(vectorWriteOperation: (UnsafeBufferPointer<IOVector>) throws -> IOResult<Int>) throws -> WriteResult {
        assert(self.state.isFlushPending && !self.state.isEmpty,
               "vector write called in state flush pending: \(self.state.isFlushPending), empty: \(self.state.isEmpty)")
        for _ in 0..<writeSpinCount {
            if closed {
                return .closed
            }
            switch self.didWrite(try doPendingWriteVectorOperation(pending: self.state,
                                                                   iovecs: self.iovecs,
                                                                   storageRefs: self.storageRefs,
                                                                   vectorWriteOperation)) {
            case .writtenPartially:
                continue
            case let other:
                return other
            }
        }
        return .writtenPartially
    }

    /// Fail all the outstanding writes. This is useful if for example the `Channel` is closed.
    func failAll(error: Error) {
        self.closed = true

        self.state.failAll(error: error)()

        assert(self.state.isEmpty)
    }

    /// Initialize with a pre-allocated array of IO vectors and storage references. We pass in these pre-allocated
    /// objects to save allocations. They can be safely be re-used for all `Channel`s on a given `EventLoop` as an
    /// `EventLoop` always runs on one and the same thread. That means that there can't be any writes of more than
    /// one `Channel` on the same `EventLoop` at the same time.
    ///
    /// - parameters:
    ///     - iovecs: A pre-allocated array of `IOVector` elements
    ///     - storageRefs: A pre-allocated array of storage management tokens used to keep storage elements alive during a vector write operation
    init(iovecs: UnsafeMutableBufferPointer<IOVector>, storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>) {
        self.iovecs = iovecs
        self.storageRefs = storageRefs
    }
}

// MARK: Compatibility
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

private extension FileRegion {
    func withMutableReader(_ body: (Int32, Int, Int) throws -> IOResult<Int>) rethrows -> IOResult<Int>  {
        var writeResult: IOResult<Int>!

        _ = try self.withMutableReader { (fd, offset, limit) -> Int in
            let localWriteResult = try body(fd, offset, limit)
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

/// A `Channel` for a client socket.
///
/// - note: All operations on `SocketChannel` are thread-safe.
final class SocketChannel: BaseSocketChannel<Socket> {

    private var connectTimeout = TimeAmount.seconds(10)
    private var connectTimeoutScheduled: Scheduled<Void>?

    init(eventLoop: SelectableEventLoop, protocolFamily: Int32) throws {
        let socket = try Socket(protocolFamily: protocolFamily)
        do {
            try socket.setNonBlocking()
        } catch let err {
            let _ = try? socket.close()
            throw err
        }
        try super.init(socket: socket, eventLoop: eventLoop)
    }

    override fileprivate func setOption0<T: ChannelOption>(option: T, value: T.OptionType) throws {
        assert(eventLoop.inEventLoop)
        switch option {
        case _ as ConnectTimeoutOption:
            connectTimeout = value as! TimeAmount
        default:
            try super.setOption0(option: option, value: value)
        }
    }
    
    override fileprivate func getOption0<T: ChannelOption>(option: T) throws -> T.OptionType {
        assert(eventLoop.inEventLoop)
        switch option {
        case _ as ConnectTimeoutOption:
            return connectTimeout as! T.OptionType
        default:
            return try super.getOption0(option: option)
        }
    }
    
    public override func registrationFor(interested: IOEvent) -> NIORegistration {
        return .socketChannel(self, interested)
    }

    fileprivate override init(socket: Socket, eventLoop: SelectableEventLoop) throws {
        try socket.setNonBlocking()
        try super.init(socket: socket, eventLoop: eventLoop)
    }

    fileprivate convenience init(socket: Socket, eventLoop: SelectableEventLoop, parent: Channel) throws {
        try self.init(socket: socket, eventLoop: eventLoop)
        self.parent = parent
    }

    override fileprivate func readFromSocket() throws {
        // Just allocate one time for the while read loop. This is fine as ByteBuffer is a struct and uses COW.
        var buffer = recvAllocator.buffer(allocator: allocator)
        for i in 1...maxMessagesPerRead {
            if closed {
                return
            }
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
                    } else {
                        // Reset reader and writerIndex and so allow to have the buffer filled again
                        buffer.clear()
                    }
                } else {
                    // end-of-file
                    throw ChannelError.eof
                }
            case .wouldBlock(let bytesRead):
                assert(bytesRead == 0)
                return
            }
        }
    }

    override fileprivate func writeToSocket(pendingWrites: PendingWritesManager) throws -> WriteResult {
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
        let timeout = connectTimeout
        connectTimeoutScheduled = eventLoop.scheduleTask(in: timeout) { () -> (Void) in
            if self.pendingConnect != nil {
                // The connection was still not established, close the Channel which will also fail the pending promise.
                self.close0(error: ChannelError.connectTimeout(timeout), promise: nil)
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
    
    override func close0(error: Error, promise: EventLoopPromise<Void>?) {
        if let timeout = connectTimeoutScheduled {
            connectTimeoutScheduled = nil
            timeout.cancel()
        }
        super.close0(error: error, promise: promise)
    }
}

/// A `Channel` for a server socket.
///
/// - note: All operations on `ServerSocketChannel` are thread-safe.
final class ServerSocketChannel : BaseSocketChannel<ServerSocket> {

    private var backlog: Int32 = 128
    private let group: EventLoopGroup

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
        do {
            try socket.bind(to: address)
            try self.socket.listen(backlog: backlog)
            promise?.succeed(result: ())
            becomeActive0()
            readIfNeeded0()
        } catch let err {
            promise?.fail(error: err)
        }
    }

    override fileprivate func connectSocket(to address: SocketAddress) throws -> Bool {
        throw ChannelError.operationUnsupported
    }

    override fileprivate func finishConnectSocket() throws {
        throw ChannelError.operationUnsupported
    }

    override fileprivate func readFromSocket() throws {
        for _ in 1...maxMessagesPerRead {
            if closed {
                return
            }
            if let accepted =  try self.socket.accept() {
                readPending = false

                do {
                    let chan = try SocketChannel(socket: accepted, eventLoop: group.next() as! SelectableEventLoop, parent: self)
                    pipeline.fireChannelRead0(data: NIOAny(chan))
                } catch let err {
                    let _ = try? accepted.close()
                    throw err
                }
            } else {
                return
            }
        }
    }

    override fileprivate func writeToSocket(pendingWrites: PendingWritesManager) throws -> WriteResult {
        pendingWrites.failAll(error: ChannelError.operationUnsupported)
        return .writtenCompletely
    }

    override public func channelRead0(data: NIOAny) {
        assert(eventLoop.inEventLoop)

        let ch = data.forceAsOther() as SocketChannel
        let f = ch.register()
        f.whenComplete(callback: { v in
            switch v {
            case .failure(_):
                ch.close(promise: nil)
            case .success(_):
                ch.becomeActive0()
                ch.readIfNeeded0()
            }
        })
    }
}


/// The core `Channel` methods for NIO-internal use only.
///
/// - note: All methods must be called from the EventLoop thread
public protocol ChannelCore : class {
    func register0(promise: EventLoopPromise<Void>?)
    func bind0(to: SocketAddress, promise: EventLoopPromise<Void>?)
    func connect0(to: SocketAddress, promise: EventLoopPromise<Void>?)
    func write0(data: IOData, promise: EventLoopPromise<Void>?)
    func flush0(promise: EventLoopPromise<Void>?)
    func read0(promise: EventLoopPromise<Void>?)
    func close0(error: Error, promise: EventLoopPromise<Void>?)
    func triggerUserOutboundEvent0(event: Any, promise: EventLoopPromise<Void>?)
    func channelRead0(data: NIOAny)
    func errorCaught0(error: Error)
}

/// A `Channel` is easiest thought of as a network socket. But it can be anything that is capable of I/O operations such
/// as read, write, connect, and bind.
///
/// - note: All operations on `Channel` are thread-safe.
///
/// In SwiftNIO, all I/O operations are asynchronous and hence all operations on `Channel` are asynchronous too. This means
/// that all I/O operations will return immediately, usually before the work has been completed. The `EventLoopPromise`s
/// passed to or returned by the operations are used to retrieve the result of an operation after it has completed.
///
/// A `Channel` owns its `ChannelPipeline` which handles all I/O events and requests associated with the `Channel`.
public protocol Channel : class, ChannelOutboundInvoker {
    /// The `Channel`'s `ByteBuffer` allocator. This is _the only_ supported way of allocating `ByteBuffer`s to be used with this `Channel`.
    var allocator: ByteBufferAllocator { get }

    /// The `closeFuture` will fire when the `Channel` has been closed.
    var closeFuture: EventLoopFuture<Void> { get }

    /// The `ChannelPipeline` which handles all I/O events and requests associated with this `Channel`.
    var pipeline: ChannelPipeline { get }
    
    /// The local `SocketAddress`.
    var localAddress: SocketAddress? { get }
    
    /// The remote peer's `SocketAddress`.
    var remoteAddress: SocketAddress? { get }

    /// `Channel`s are hierarchical and might have a parent `Channel`. `Channel` hierarchies are in use for certain
    /// protocols such as HTTP/2.
    var parent: Channel? { get }

    /// Set `option` to `value` on this `Channel`.
    func setOption<T: ChannelOption>(option: T, value: T.OptionType) throws
    
    /// Get the value of `option` for this `Channel`.
    func getOption<T: ChannelOption>(option: T) throws -> T.OptionType

    /// Returns if this `Channel` is currently writable.
    var isWritable: Bool { get }
    
    /// Returns if this `Channel` is currently active. Active is defined as the period of time after the
    /// `channelActive` and before `channelInactive` has fired. The main use for this is to know if `channelActive`
    /// or `channelInactive` can be expected next when `handlerAdded` was received.
    var isActive: Bool { get }

    /// Reach out to the `ChannelCore`.
    ///
    /// - warning: Unsafe, this is for use in NIO's core only.
    var _unsafe: ChannelCore { get }
}

/// A `SelectableChannel` is a `Channel` that can be used with a `Selector` which notifies a user when certain events
/// before possible. On UNIX a `Selector` is usually an abstraction of `select`, `poll`, `epoll` or `kqueue`.
protocol SelectableChannel : Channel {
    /// The type of the `Selectable`. A `Selectable` is usually wrapping a file descriptor that can be registered in a
    /// `Selector`.
    associatedtype SelectableType: Selectable

    /// Returns the `Selectable` which usually contains the file descriptor for the socket.
    var selectable: SelectableType { get }
    
    /// The event(s) of interest.
    var interestedEvent: IOEvent { get }

    /// Called when the `SelectableChannel` is ready to be written.
    func writable()
    
    /// Called when the `SelectableChannel` is ready to be read.
    func readable()

    /// Creates a registration for the `interested` `IOEvent` suitable for this `Channel`.
    ///
    /// - parameters:
    ///     - interested: The event(s) of interest.
    /// - returns: A suitable registration for the `IOEvent` of interest.
    func registrationFor(interested: IOEvent) -> NIORegistration
}

extension Channel {
    public var open: Bool {
        return !closeFuture.fulfilled
    }

    public func bind(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        pipeline.bind(to: address, promise: promise)
    }

    // Methods invoked from the HeadHandler of the ChannelPipeline
    // By default, just pass through to pipeline

    public func connect(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        pipeline.connect(to: address, promise: promise)
    }

    public func write(data: NIOAny, promise: EventLoopPromise<Void>?) {
        pipeline.write(data: data, promise: promise)
    }

    public func flush(promise: EventLoopPromise<Void>?) {
        pipeline.flush(promise: promise)
    }
    
    public func writeAndFlush(data: NIOAny, promise: EventLoopPromise<Void>?) {
        pipeline.writeAndFlush(data: data, promise: promise)
    }

    public func read(promise: EventLoopPromise<Void>?) {
        pipeline.read(promise: promise)
    }

    public func close(promise: EventLoopPromise<Void>?) {
        pipeline.close(promise: promise)
    }

    public func register(promise: EventLoopPromise<Void>?) {
        pipeline.register(promise: promise)
    }
    
    public func triggerUserOutboundEvent(event: Any, promise: EventLoopPromise<Void>?) {
        pipeline.triggerUserOutboundEvent(event: event, promise: promise)
    }
}

class BaseSocketChannel<T : BaseSocket> : SelectableChannel, ChannelCore {
    typealias SelectableType = T

    func registrationFor(interested: IOEvent) -> NIORegistration {
        fatalError("must override")
    }

    var selectable: T {
        return self.socket
    }

    public final var _unsafe: ChannelCore { return self }

    // Visible to access from EventLoop directly
    let socket: T
    public var interestedEvent: IOEvent = .none

    public final var closed: Bool {
        return pendingWrites.closed
    }

    private let pendingWrites: PendingWritesManager
    fileprivate var readPending = false
    private var neverRegistered = true
    fileprivate var pendingConnect: EventLoopPromise<Void>?
    private let closePromise: EventLoopPromise<Void>
    private var active: Atomic<Bool> = Atomic(value: false)
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

    public final var isWritable: Bool {
        return pendingWrites.isWritable
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

    public final func setOption<T: ChannelOption>(option: T, value: T.OptionType) throws {
        if eventLoop.inEventLoop {
            try setOption0(option: option, value: value)
        } else {
            let _ = try eventLoop.submit { try self.setOption0(option: option, value: value)}.wait()
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
        case _ as WriteSpinOption:
            pendingWrites.writeSpinCount = value as! UInt
        case _ as WriteBufferWaterMarkOption:
            pendingWrites.waterMark = value as! WriteBufferWaterMark
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
        case _ as WriteSpinOption:
            return pendingWrites.writeSpinCount as! T.OptionType
        case _ as WriteBufferWaterMarkOption:
            return pendingWrites.waterMark as! T.OptionType
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

    final func readIfNeeded0() {
        if autoRead {
            pipeline.read0(promise: nil)
        }
    }

    // Methods invoked from the HeadHandler of the ChannelPipeline
    public func bind0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)

        do {
            try socket.bind(to: address)
            promise?.succeed(result: ())
        } catch let err {
            promise?.fail(error: err)
        }
    }

    public func write0(data: IOData, promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)

        if closed {
            // Channel was already closed, fail the promise and not even queue it.
            promise?.fail(error: ChannelError.ioOnClosedChannel)
            return
        }
        if !self.pendingWrites.add(data: data, promise: promise) {
            pipeline.fireChannelWritabilityChanged0()
        }
    }
    
    private func registerForWritable() {
        switch interestedEvent {
        case .read:
            safeReregister(interested: .all)
        case .none:
            safeReregister(interested: .write)
        default:
            break
        }
    }

    private func unregisterForWritable() {
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
        // Even if writable() will be called later by the EventLoop we still need to mark the flush checkpoint so we are sure all the flushed messages
        // are actually written once writable() is called.
        self.pendingWrites.markFlushCheckpoint(promise: promise)
        
        if !isWritePending() && !flushNow() && !closed {
            registerForWritable()
        }
    }

    public final func read0(promise: EventLoopPromise<Void>?) {
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
        switch interestedEvent {
        case .write:
            safeReregister(interested: .all)
        case .none:
            safeReregister(interested: .read)
        default:
            break
        }
    }

    private func unregisterForReadable() {
        switch interestedEvent {
        case .read:
            safeReregister(interested: .none)
        case .all:
            safeReregister(interested: .write)
        default:
            break
        }
    }

    public func close0(error: Error, promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)

        if closed {
            promise?.fail(error: ChannelError.alreadyClosed)
            return
        }

        interestedEvent = .none
        do {
            try selectableEventLoop.deregister(channel: self)
        } catch let err {
            pipeline.fireErrorCaught0(error: err)
        }

        do {
            try socket.close()
            promise?.succeed(result: ())
        } catch let err {
            promise?.fail(error: err)
        }

        // Fail all pending writes and so ensure all pending promises are notified
        self.pendingWrites.failAll(error: error)

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

        // Was not registered yet so do it now.
        if safeRegister(interested: .read) {
            neverRegistered = false
            promise?.succeed(result: ())
            pipeline.fireChannelRegistered0()
        } else {
            promise?.succeed(result: ())
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
        if let connectPromise = pendingConnect {
            pendingConnect = nil
            do {
                try finishConnectSocket()
                connectPromise.succeed(result: ())
            } catch let error {
                connectPromise.fail(error: error)
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
            if let channelErr = err as? ChannelError {
                // EOF is not really an error that should be forwarded to the user
                if channelErr != ChannelError.eof {
                    pipeline.fireErrorCaught0(error: err)
                }
            } else {
                pipeline.fireErrorCaught0(error: err)
            }

            // Call before triggering the close of the Channel.
            pipeline.fireChannelReadComplete0()
            close0(error: err, promise: nil)

            return
        }
        pipeline.fireChannelReadComplete0()
        readIfNeeded0()
    }

    fileprivate func connectSocket(to address: SocketAddress) throws -> Bool {
        fatalError("this must be overridden by sub class")
    }

    fileprivate func finishConnectSocket() throws {
        fatalError("this must be overridden by sub class")
    }

    public final func connect0(to address: SocketAddress, promise: EventLoopPromise<Void>?) {
        assert(eventLoop.inEventLoop)

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

    fileprivate func readFromSocket() throws {
        fatalError("this must be overridden by sub class")
    }


    fileprivate func writeToSocket(pendingWrites: PendingWritesManager) throws -> WriteResult {
        fatalError("this must be overridden by sub class")
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
            close0(error: err, promise: nil)
        }
    }

    private func safeRegister(interested: IOEvent) -> Bool {
        if closed {
            interestedEvent = .none
            return false
        }
        interestedEvent = interested
        do {
            try selectableEventLoop.register(channel: self)
            return true
        } catch let err {
            pipeline.fireErrorCaught0(error: err)
            close0(error: err, promise: nil)
            return false
        }
    }

    private func flushNow() -> Bool {
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
                close0(error: err, promise: nil)

                // we handled all writes
                return true
            }
        }
        return true
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
        self.pendingWrites = PendingWritesManager(iovecs: eventLoop.iovecs, storageRefs: eventLoop.storageRefs)
        active.store(false)
        self._pipeline = ChannelPipeline(channel: self)
    }

    deinit {
        // We should never have any pending writes left as otherwise we may leak callbacks
        assert(pendingWrites.isEmpty)
    }
}

/// An error that can occur on `Channel` operations.
public enum ChannelError: Error {
    /// Tried to connect on a `Channel` that is already connecting.
    case connectPending

    /// Connect operation timed out
    case connectTimeout(TimeAmount)

    /// Unsupported operation triggered on a `Channel`. For example `connect` on a `ServerSocketChannel`.
    case operationUnsupported
    
    /// An I/O operation (e.g. read/write/flush) called on a channel that is already closed.
    case ioOnClosedChannel
    
    /// Close was called on a channel that is already closed.
    case alreadyClosed
    
    /// A read operation reached end-of-file. This usually means the remote peer closed the socket but it's still
    /// open locally.
    case eof
}

extension ChannelError: Equatable {
    public static func ==(lhs: ChannelError, rhs: ChannelError) -> Bool {
        switch (lhs, rhs) {
        case (.connectPending, .connectPending):
            return true
        case (.connectTimeout(_), .connectTimeout(_)):
            return true
        case (.operationUnsupported, .operationUnsupported):
            return true
        case (.ioOnClosedChannel, .ioOnClosedChannel):
            return true
        case (.alreadyClosed, .alreadyClosed):
            return true
        case (.eof, .eof):
            return true
        default:
            return false
        }
    }
}

