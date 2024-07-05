//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore
import Atomics

private struct PendingStreamWrite {
    var data: IOData
    var promise: Optional<EventLoopPromise<Void>>
}

/// Does the setup required to issue a writev.
///
/// - parameters:
///    - pending: The currently pending writes.
///    - bufferPool: Pool of buffers to use for iovecs and storageRefs
///    - body: The function that actually does the vector write (usually `writev`).
/// - returns: A tuple of the number of items attempted to write and the result of the write operation.
private func doPendingWriteVectorOperation(pending: PendingStreamWritesState,
                                           bufferPool: Pool<PooledBuffer>,
                                           _ body: (UnsafeBufferPointer<IOVector>) throws -> IOResult<Int>) throws -> (itemCount: Int, writeResult: IOResult<Int>) {
    let buffer = bufferPool.get()
    defer { bufferPool.put(buffer) }

    return try buffer.withUnsafePointers { iovecs, storageRefs in
        // Clamp the number of writes we're willing to issue to the limit for writev.
        var count = min(iovecs.count, storageRefs.count)
        count = min(pending.flushedChunks, count)

        // the numbers of storage refs that we need to decrease later.
        var numberOfUsedStorageSlots = 0
        var toWrite: Int = 0

        loop: for i in 0..<count {
            let p = pending[i]
            switch p.data {
            case .byteBuffer(let buffer):
                // Must not write more than Int32.max in one go.
                guard (numberOfUsedStorageSlots == 0) || (Socket.writevLimitBytes - toWrite >= buffer.readableBytes) else {
                    break loop
                }
                let toWriteForThisBuffer = min(Socket.writevLimitBytes, buffer.readableBytes)
                toWrite += numericCast(toWriteForThisBuffer)

                buffer.withUnsafeReadableBytesWithStorageManagement { ptr, storageRef in
                    storageRefs[i] = storageRef.retain()
                    iovecs[i] = IOVector(iov_base: UnsafeMutableRawPointer(mutating: ptr.baseAddress!), iov_len: numericCast(toWriteForThisBuffer))
                }
                numberOfUsedStorageSlots += 1
            case .fileRegion:
                assert(numberOfUsedStorageSlots != 0, "first item in doPendingWriteVectorOperation was a FileRegion")
                // We found a FileRegion so stop collecting
                break loop
            }
        }
        defer {
            for i in 0..<numberOfUsedStorageSlots {
                storageRefs[i].release()
            }
        }
        let result = try body(UnsafeBufferPointer(start: iovecs.baseAddress!, count: numberOfUsedStorageSlots))
        /* if we hit a limit, we really wanted to write more than we have so the caller should retry us */
        return (numberOfUsedStorageSlots, result)
    }
}

/// The result of a single write operation, usually `write`, `sendfile` or `writev`.
internal enum OneWriteOperationResult {
    /// Wrote everything asked.
    case writtenCompletely

    /// Wrote some portion of what was asked.
    case writtenPartially

    /// Could not write as doing that would have blocked.
    case wouldBlock
}

/// The result of trying to write all the outstanding flushed data. That naturally includes all `ByteBuffer`s and
/// `FileRegions` and the individual writes have potentially been retried (see `WriteSpinOption`).
internal struct OverallWriteResult {
    enum WriteOutcome {
        /// Wrote all the data that was flushed. When receiving this result, we can unsubscribe from 'writable' notification.
        case writtenCompletely

        /// Could not write everything. Before attempting further writes the eventing system should send a 'writable' notification.
        case couldNotWriteEverything
    }

    internal var writeResult: WriteOutcome
    internal var writabilityChange: Bool
}

/// This holds the states of the currently pending stream writes. The core is a `MarkedCircularBuffer` which holds all the
/// writes and a mark up until the point the data is flushed.
///
/// The most important operations on this object are:
///  - `append` to add an `IOData` to the list of pending writes.
///  - `markFlushCheckpoint` which sets a flush mark on the current position of the `MarkedCircularBuffer`. All the items before the checkpoint will be written eventually.
///  - `didWrite` when a number of bytes have been written.
///  - `failAll` if for some reason all outstanding writes need to be discarded and the corresponding `EventLoopPromise` needs to be failed.
private struct PendingStreamWritesState {
    private var pendingWrites = MarkedCircularBuffer<PendingStreamWrite>(initialCapacity: 16)
    public private(set) var bytes: Int64 = 0

    public var flushedChunks: Int {
        return self.pendingWrites.markedElementIndex.map {
            self.pendingWrites.distance(from: self.pendingWrites.startIndex, to: $0) + 1
        } ?? 0
    }

    /// Subtract `bytes` from the number of outstanding bytes to write.
    private mutating func subtractOutstanding(bytes: Int) {
        assert(self.bytes >= bytes, "allegedly written more bytes (\(bytes)) than outstanding (\(self.bytes))")
        self.bytes -= numericCast(bytes)
    }

    /// Indicates that the first outstanding write was written in its entirety.
    ///
    /// - returns: The `EventLoopPromise` of the write or `nil` if none was provided. The promise needs to be fulfilled by the caller.
    ///
    private mutating func fullyWrittenFirst() -> EventLoopPromise<Void>? {
        let first = self.pendingWrites.removeFirst()
        self.subtractOutstanding(bytes: first.data.readableBytes)
        return first.promise
    }

    /// Indicates that the first outstanding object has been partially written.
    ///
    /// - parameters:
    ///     - bytes: How many bytes of the item were written.
    private mutating func partiallyWrittenFirst(bytes: Int) {
        self.pendingWrites[self.pendingWrites.startIndex].data.moveReaderIndex(forwardBy: bytes)
        self.subtractOutstanding(bytes: bytes)
    }

    /// Initialise a new, empty `PendingWritesState`.
    public init() { }

    /// Check if there are no outstanding writes.
    public var isEmpty: Bool {
        if self.pendingWrites.isEmpty {
            assert(self.bytes == 0)
            assert(!self.pendingWrites.hasMark)
            return true
        } else {
            assert(self.bytes >= 0)
            return false
        }
    }

    /// Add a new write and optionally the corresponding promise to the list of outstanding writes.
    public mutating func append(_ chunk: PendingStreamWrite) {
        self.pendingWrites.append(chunk)
        switch chunk.data {
        case .byteBuffer(let buffer):
            self.bytes += numericCast(buffer.readableBytes)
        case .fileRegion(let fileRegion):
            self.bytes += numericCast(fileRegion.readableBytes)
        }
    }

    /// Get the outstanding write at `index`.
    public subscript(index: Int) -> PendingStreamWrite {
        return self.pendingWrites[self.pendingWrites.index(self.pendingWrites.startIndex, offsetBy: index)]
    }

    /// Mark the flush checkpoint.
    ///
    /// All writes before this checkpoint will eventually be written to the socket.
    public mutating func markFlushCheckpoint() {
        self.pendingWrites.mark()
    }

    mutating func didAsyncWrite(_ written: Int, _ buffer: PooledBuffer?) -> (EventLoopPromise<Void>?, Bool) {
        var promise0: EventLoopPromise<Void>?
        var unaccountedWrites = written
        var idx: Int = 0

        while unaccountedWrites > 0 {
            let pw = self.pendingWrites.first!
            let headItemReadableBytes = pw.data.readableBytes

            if headItemReadableBytes > 0 {
                if unaccountedWrites < headItemReadableBytes {
                    self.partiallyWrittenFirst(bytes: unaccountedWrites)
                    return (promise0, self.pendingWrites.hasMark)
                }
                unaccountedWrites -= headItemReadableBytes

                if case .byteBuffer = pw.data {
                    buffer!.withUnsafePointers { _, storageRefs in
                        storageRefs[idx].release()
                    }
                    idx += 1
                }
            }

            if let promise = self.fullyWrittenFirst() {
                if let p = promise0 {
                    p.futureResult.cascade(to: promise)
                }
                else {
                    promise0 = promise
                }
            }
        }

        return removeEmptyFlushedChunks(promise0)
    }

    mutating func removeEmptyFlushedChunks(_ promise0: EventLoopPromise<Void>?) -> (EventLoopPromise<Void>?, Bool) {
        let flushedChunks = self.flushedChunks
        var promise0 = promise0
        for _ in 0..<flushedChunks {
            let pw = self.pendingWrites.first!
            let headItemReadableBytes = pw.data.readableBytes
            if headItemReadableBytes > 0 {
                break
            }

            if let promise = self.fullyWrittenFirst() {
                if let p = promise0 {
                    p.futureResult.cascade(to: promise)
                }
                else {
                    promise0 = promise
                }
            }
        }
        return (promise0, self.pendingWrites.hasMark)
    }

    func releaseData(_ buffer: PooledBuffer) {
        buffer.withUnsafePointers { iovecs, storageRefs in
            let count = min(iovecs.count, storageRefs.count)
            for idx in 0..<count {
                if iovecs[idx].iov_len == 0 {
                    break
                }
                storageRefs[idx].release()
            }
        }
    }

    func prepareIOVectors(to buffer: inout PooledBuffer) -> UnsafeBufferPointer<IOVector> {
        buffer.withUnsafePointers { iovecs, storageRefs in
            var count = min(Socket.writevLimitIOVectors, iovecs.count)
            count = min(count, storageRefs.count)
            count = min(count, self.flushedChunks)

            // the numbers of storage refs that we need to decrease later.
            var numberOfUsedSlots = 0
            var toWrite: Int = 0

            loop: for idx in 0..<count {
                let p = self[idx]
                switch p.data {
                case .byteBuffer(let buffer):
                    // Must not write more than Int32.max in one go.
                    /* FIXME: probably worth to split that buffer
                    guard (numberOfUsedStorageSlots == 0) || (Socket.writevLimitBytes - toWrite >= buffer.readableBytes) else {
                        break loop
                    }
                    */
                    let toWriteForThisBuffer = min(Socket.writevLimitBytes, buffer.readableBytes)
                    if toWriteForThisBuffer > 0 {
                        toWrite += numericCast(toWriteForThisBuffer)
                        buffer.withUnsafeReadableBytesWithStorageManagement { ptr, storageRef in
                            iovecs[numberOfUsedSlots] = IOVector(
                                iov_base: UnsafeMutableRawPointer(mutating: ptr.baseAddress!),
                                iov_len: numericCast(toWriteForThisBuffer))
                            storageRefs[numberOfUsedSlots] = storageRef.retain()
                        }
                        numberOfUsedSlots += 1
                    }
                case .fileRegion:
                    assert(numberOfUsedSlots != 0, "first item in doPendingWriteVectorOperation was a FileRegion")
                    // We found a FileRegion so stop collecting
                    break loop
                }
            }

            count = min(iovecs.count, storageRefs.count)
            if numberOfUsedSlots < count {
                iovecs[numberOfUsedSlots].iov_len = 0
            }

            return UnsafeBufferPointer(start: iovecs.baseAddress!, count: numberOfUsedSlots)
        }
    }

    /// Indicate that a write has happened, this may be a write of multiple outstanding writes (using for example `writev`).
    ///
    /// - warning: The promises will be returned in order. If one of those promises does for example close the `Channel` we might see subsequent writes fail out of order. Example: Imagine the user issues three writes: `A`, `B` and `C`. Imagine that `A` and `B` both get successfully written in one write operation but the user closes the `Channel` in `A`'s callback. Then overall the promises will be fulfilled in this order: 1) `A`: success 2) `C`: error 3) `B`: success. Note how `B` and `C` get fulfilled out of order.
    ///
    /// - parameters:
    ///     - writeResult: The result of the write operation.
    /// - returns: A tuple of a promise and a `OneWriteResult`. The promise is the first promise that needs to be notified of the write result.
    ///            This promise will cascade the result to all other promises that need notifying. If no promises need to be notified, will be `nil`.
    ///            The write result will indicate whether we were able to write everything or not.
    mutating func didWrite(itemCount: Int, result writeResult: IOResult<Int>) -> (EventLoopPromise<Void>?, OneWriteOperationResult) {
        switch writeResult {
        case .wouldBlock(0):
            return (nil, .wouldBlock)
        case .processed(let written), .wouldBlock(let written):
            var promise0: EventLoopPromise<Void>?
            assert(written >= 0, "allegedly written a negative amount of bytes: \(written)")
            var unaccountedWrites = written
            for _ in 0..<itemCount {
                let headItemReadableBytes = self.pendingWrites.first!.data.readableBytes
                if unaccountedWrites >= headItemReadableBytes {
                    unaccountedWrites -= headItemReadableBytes
                    /* we wrote at least the whole head item, so drop it and succeed the promise */
                    if let promise = self.fullyWrittenFirst() {
                        if let p = promise0 {
                            p.futureResult.cascade(to: promise)
                        } else {
                            promise0 = promise
                        }
                    }
                } else {
                    /* we could only write a part of the head item, so don't drop it but remember what we wrote */
                    self.partiallyWrittenFirst(bytes: unaccountedWrites)

                    // may try again depending on the writeSpinCount
                    return (promise0, .writtenPartially)
                }
            }
            assert(unaccountedWrites == 0, "after doing all the accounting for the byte written, \(unaccountedWrites) bytes of unaccounted writes remain.")
            return (promise0, .writtenCompletely)
        }
    }

    /// Is there a pending flush?
    public var isFlushPending: Bool {
        return self.pendingWrites.hasMark
    }

    /// Remove all pending writes and return a `EventLoopPromise` which will cascade notifications to all.
    ///
    /// - warning: See the warning for `didWrite`.
    ///
    /// - returns: promise that needs to be failed, or `nil` if there were no pending writes.
    public mutating func removeAll() -> EventLoopPromise<Void>? {
        var promise0: EventLoopPromise<Void>?

        while !self.pendingWrites.isEmpty {
            if let p = self.fullyWrittenFirst() {
                if let promise = promise0 {
                    promise.futureResult.cascade(to: p)
                } else {
                    promise0 = p
                }
            }
        }
        return promise0
    }

    /// Returns the best mechanism to write pending data at the current point in time.
    var currentBestWriteMechanism: WriteMechanism {
        switch self.flushedChunks {
        case 0:
            return .nothingToBeWritten
        case 1:
            switch self.pendingWrites.first!.data {
            case .byteBuffer:
                return .scalarBufferWrite
            case .fileRegion:
                return .scalarFileWrite
            }
        default:
            let startIndex = self.pendingWrites.startIndex
            switch (self.pendingWrites[startIndex].data,
                    self.pendingWrites[self.pendingWrites.index(after: startIndex)].data) {
            case (.byteBuffer, .byteBuffer):
                return .vectorBufferWrite
            case (.byteBuffer, .fileRegion):
                return .scalarBufferWrite
            case (.fileRegion, _):
                return .scalarFileWrite
            }
        }
    }
}

/// This class manages the writing of pending writes to stream sockets. The state is held in a `PendingWritesState`
/// value. The most important purpose of this object is to call `write`, `writev` or `sendfile` depending on the
/// currently pending writes.
final class PendingStreamWritesManager: PendingWritesManager {
    private var state = PendingStreamWritesState()
    private let bufferPool: Pool<PooledBuffer>
    private var buffer: PooledBuffer?

    internal var waterMark: ChannelOptions.Types.WriteBufferWaterMark = ChannelOptions.Types.WriteBufferWaterMark(low: 32 * 1024, high: 64 * 1024)
    internal let channelWritabilityFlag = ManagedAtomic(true)
    internal var publishedWritability = true

    internal var writeSpinCount: UInt = 16

    private(set) var isOpen = true

    /// Mark the flush checkpoint.
    func markFlushCheckpoint() {
        self.state.markFlushCheckpoint()
    }

    /// Is there a flush pending?
    var isFlushPending: Bool {
        return self.state.isFlushPending
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
        assert(self.isOpen)
        self.state.append(.init(data: data, promise: promise))

        if self.state.bytes > waterMark.high &&
            channelWritabilityFlag.compareExchange(expected: true, desired: false, ordering: .relaxed).exchanged {
            // Returns false to signal the Channel became non-writable and we need to notify the user.
            self.publishedWritability = false
            return false
        }
        return true
    }

    /// Returns the best mechanism to write pending data at the current point in time.
    var currentBestWriteMechanism: WriteMechanism {
        return self.state.currentBestWriteMechanism
    }

    /// To be used with asynch IO, like URing
    func triggerAppropriateAsyncWriteOperations(scalarBufferAsyncWriteOperation: (UnsafeRawBufferPointer) throws -> Void,
                                                vectorBufferAsyncWriteOperation: (UnsafeBufferPointer<IOVector>) throws -> Void,
                                                scalarFileAsyncWriteOperation: (CInt, Int, Int) throws -> Void) throws {
        let writeMechanism = self.currentBestWriteMechanism
        switch writeMechanism {
        case .scalarBufferWrite:
            switch self.state[0].data {
            case .byteBuffer(let byteBuffer):
                let toWrite = min(Socket.writevLimitBytes, byteBuffer.readableBytes)
                if toWrite > 0 {
                    assert(self.buffer == nil)
                    self.buffer = self.bufferPool.get()
                    try self.buffer!.withUnsafePointers { _ , storageRefs in 
                        try byteBuffer.withUnsafeReadableBytesWithStorageManagement { ptr, storageRef in
                            storageRefs[0] = storageRef.retain()
                            try scalarBufferAsyncWriteOperation(ptr)
                        }
                    }
                }
                else {
                    // can happen if empty buffer sent
                    let (promise, flushAgain) = self.state.removeEmptyFlushedChunks(nil)
                    assert(!flushAgain)
                    promise?.succeed(())
                }
            case .fileRegion:
                preconditionFailure("called \(#function) but first item to write was a FileRegion")
            }
        case .vectorBufferWrite:
            assert(self.buffer == nil)
            self.buffer = self.bufferPool.get()
            let iovecs = self.state.prepareIOVectors(to: &self.buffer!)
            try vectorBufferAsyncWriteOperation(iovecs)
        case .scalarFileWrite:
            switch self.state[0].data {
            case .byteBuffer:
                preconditionFailure("called \(#function) but first item to write was a FileRegion")
            case .fileRegion(let file):
                let toWrite = min(Socket.writevLimitBytes, file.readableBytes)
                if toWrite > 0 {
                    let readerIndex = file.readerIndex
                    let endIndex = file.endIndex
                    try file.fileHandle.withUnsafeFileDescriptor { fd in
                        try scalarFileAsyncWriteOperation(fd, readerIndex, endIndex)
                    }
                }
                else {
                    let (promise, flushAgain) = self.state.removeEmptyFlushedChunks(nil)
                    assert(!flushAgain)
                    promise?.succeed(())
                }
            }
        case .nothingToBeWritten:
            // can happen,
            // if for example writeAndFlush() has been called for the closed channel
            break
        }
    }

    func didAsyncWrite(written: Int) -> (Bool, Bool) {
        let (promise, flushAgain) = self.state.didAsyncWrite(written, self.buffer)
        if let buffer = self.buffer {
            self.bufferPool.put(buffer)
            self.buffer = nil
        }

        var writabilityChange = false
        if self.state.bytes < waterMark.low {
            if self.channelWritabilityFlag.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged {
                writabilityChange = true
            }
        }

        promise?.succeed(())
        return (writabilityChange, flushAgain)
    }

    func releaseData() {
        self.state.releaseData(self.buffer!)
        self.bufferPool.put(self.buffer!)
        self.buffer = nil
    }

    /// Triggers the appropriate write operation. This is a fancy way of saying trigger either `write`, `writev` or
    /// `sendfile`.
    ///
    /// - parameters:
    ///     - scalarBufferWriteOperation: An operation that writes a single, contiguous array of bytes (usually `write`).
    ///     - vectorBufferWriteOperation: An operation that writes multiple contiguous arrays of bytes (usually `writev`).
    ///     - scalarFileWriteOperation: An operation that writes a region of a file descriptor (usually `sendfile`).
    /// - returns: The `OneWriteOperationResult` and whether the `Channel` is now writable.
    func triggerAppropriateWriteOperations(scalarBufferWriteOperation: (UnsafeRawBufferPointer) throws -> IOResult<Int>,
                                           vectorBufferWriteOperation: (UnsafeBufferPointer<IOVector>) throws -> IOResult<Int>,
                                           scalarFileWriteOperation: (CInt, Int, Int) throws -> IOResult<Int>) throws -> OverallWriteResult {
        return try self.triggerWriteOperations { writeMechanism in
            switch writeMechanism {
            case .scalarBufferWrite:
                return try triggerScalarBufferWrite({ try scalarBufferWriteOperation($0) })
            case .vectorBufferWrite:
                return try triggerVectorBufferWrite({ try vectorBufferWriteOperation($0) })
            case .scalarFileWrite:
                return try triggerScalarFileWrite({ try scalarFileWriteOperation($0, $1, $2) })
            case .nothingToBeWritten:
                assertionFailure("called \(#function) with nothing available to be written")
                return .writtenCompletely
            }
        }
    }

    /// To be called after a write operation (usually selected and run by `triggerAppropriateWriteOperation`) has
    /// completed.
    ///
    /// - parameters:
    ///     - itemCount: The number of items we tried to write.
    ///     - result: The result of the write operation.
    private func didWrite(itemCount: Int, result: IOResult<Int>) -> OneWriteOperationResult {
        let (promise, result) = self.state.didWrite(itemCount: itemCount, result: result)

        if self.state.bytes < waterMark.low {
            channelWritabilityFlag.store(true, ordering: .relaxed)
        }

        promise?.succeed(())
        return result
    }

    /// Trigger a write of a single `ByteBuffer` (usually using `write(2)`).
    ///
    /// - parameters:
    ///     - operation: An operation that writes a single, contiguous array of bytes (usually `write`).
    private func triggerScalarBufferWrite(_ operation: (UnsafeRawBufferPointer) throws -> IOResult<Int>) throws -> OneWriteOperationResult {
        assert(self.state.isFlushPending && !self.state.isEmpty && self.isOpen,
               "single write called in illegal state: flush pending: \(self.state.isFlushPending), empty: \(self.state.isEmpty), isOpen: \(self.isOpen)")

        switch self.state[0].data {
        case .byteBuffer(let buffer):
            return self.didWrite(itemCount: 1, result: try buffer.withUnsafeReadableBytes({ try operation($0) }))
        case .fileRegion:
            preconditionFailure("called \(#function) but first item to write was a FileRegion")
        }
    }

    /// Trigger a write of a single `FileRegion` (usually using `sendfile(2)`).
    ///
    /// - parameters:
    ///     - operation: An operation that writes a region of a file descriptor.
    private func triggerScalarFileWrite(_ operation: (CInt, Int, Int) throws -> IOResult<Int>) throws -> OneWriteOperationResult {
        assert(self.state.isFlushPending && !self.state.isEmpty && self.isOpen,
               "single write called in illegal state: flush pending: \(self.state.isFlushPending), empty: \(self.state.isEmpty), isOpen: \(self.isOpen)")

        switch self.state[0].data {
        case .fileRegion(let file):
            let readerIndex = file.readerIndex
            let endIndex = file.endIndex
            return try file.fileHandle.withUnsafeFileDescriptor { fd in
                self.didWrite(itemCount: 1, result: try operation(fd, readerIndex, endIndex))
            }
        case .byteBuffer:
            preconditionFailure("called \(#function) but first item to write was a ByteBuffer")
        }
    }

    /// Trigger a vector write operation. In other words: Write multiple contiguous arrays of bytes.
    ///
    /// - parameters:
    ///     - operation: The vector write operation to use. Usually `writev`.
    private func triggerVectorBufferWrite(_ operation: (UnsafeBufferPointer<IOVector>) throws -> IOResult<Int>) throws -> OneWriteOperationResult {
        assert(self.state.isFlushPending && !self.state.isEmpty && self.isOpen,
               "vector write called in illegal state: flush pending: \(self.state.isFlushPending), empty: \(self.state.isEmpty), isOpen: \(self.isOpen)")
        let result = try doPendingWriteVectorOperation(pending: self.state,
                                                       bufferPool: bufferPool,
                                                       { try operation($0) })
        return self.didWrite(itemCount: result.itemCount, result: result.writeResult)
    }

    /// Fail all the outstanding writes. This is useful if for example the `Channel` is closed.
    func failAll(error: Error, close: Bool) {
        if close {
            assert(self.isOpen)
            self.isOpen = false
        }

        self.state.removeAll()?.fail(error)

        assert(self.state.isEmpty)
    }

    func flushedChunks() -> Int {
        return self.state.flushedChunks
    }

    /// Initialize with a pre-allocated array of IO vectors and storage references.
    /// With default demultiplexor (like epoll) we pass in these pre-allocated
    /// objects to save allocations. They can be safely be re-used for all `Channel`s on a given `EventLoop` as an
    /// `EventLoop` always runs on one and the same thread. That means that there can't be any writes of more than
    /// one `Channel` on the same `EventLoop` at the same time.
    /// With URing the data stored in the 'iovecs' and 'storageRefs' is required while the write operation
    /// will not complete, so each PendingWritesManager has own vector becoming an owner of the provided.
    ///
    /// - parameters:
    ///     - bufferPool: Pool of buffers to be used for iovecs and storage references
    init(bufferPool: Pool<PooledBuffer>) {
        self.bufferPool = bufferPool
    }
}

internal enum WriteMechanism {
    case scalarBufferWrite
    case vectorBufferWrite
    case scalarFileWrite
    case nothingToBeWritten
}

internal protocol PendingWritesManager: AnyObject {
    var isOpen: Bool { get }
    var isFlushPending: Bool { get }
    var writeSpinCount: UInt { get }
    var currentBestWriteMechanism: WriteMechanism { get }
    var channelWritabilityFlag: ManagedAtomic<Bool> { get }

    /// Represents the writability state the last time we published a writability change to the `Channel`.
    /// This is used in `triggerWriteOperations` to determine whether we need to trigger a writability
    /// change.
    var publishedWritability: Bool { get set }
}

extension PendingWritesManager {
    // This is called from `Channel` API so must be thread-safe.
    var isWritable: Bool {
        return self.channelWritabilityFlag.load(ordering: .relaxed)
    }

    internal func triggerWriteOperations(triggerOneWriteOperation: (WriteMechanism) throws -> OneWriteOperationResult) throws -> OverallWriteResult {
        var result = OverallWriteResult(writeResult: .couldNotWriteEverything, writabilityChange: false)

        writeSpinLoop: for _ in 0...self.writeSpinCount {
            var oneResult: OneWriteOperationResult
            repeat {
                guard self.isOpen && self.isFlushPending else {
                    result.writeResult = .writtenCompletely
                    break writeSpinLoop
                }

                oneResult = try triggerOneWriteOperation(self.currentBestWriteMechanism)
                if oneResult == .wouldBlock {
                    break writeSpinLoop
                }
            } while oneResult == .writtenCompletely
        }

        // Please note that the re-entrancy protection in `flushNow` expects this code to try to write _all_ the data
        // that is flushed. If we receive a `flush` whilst processing a previous `flush`, we won't do anything because
        // we expect this loop to attempt to attempt all writes, even ones that arrive after this method begins to run.
        //
        // In other words, don't return `.writtenCompletely` unless you've written everything the PendingWritesManager
        // knows to be flushed.
        //
        // Also, it is very important to not do any outcalls to user code outside of the loop until the `flushNow`
        // re-entrancy protection is off again.

        if !self.publishedWritability {
            // When we last published a writability change the `Channel` wasn't writable, signal back to the caller
            // whether we should emit a writability change.
            result.writabilityChange = self.isWritable
            self.publishedWritability = result.writabilityChange
        }
        return result
    }
}

extension PendingStreamWritesManager: CustomStringConvertible {
    var description: String {
        return "PendingStreamWritesManager { isFlushPending: \(self.isFlushPending), " +
        /*  */ "writabilityFlag: \(self.channelWritabilityFlag.load(ordering: .relaxed))), state: \(self.state) }"
    }
}
