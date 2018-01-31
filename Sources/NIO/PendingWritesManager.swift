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

private struct PendingStreamWrite {
    var data: IOData
    var promise: EventLoopPromise<Void>?
}

/// Does the setup required to issue a writev.
private func doPendingWriteVectorOperation(pending: PendingStreamWritesState,
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

/// This holds the states of the currently pending stream writes. The core is a `MarkedCircularBuffer` which holds all the
/// writes and a mark up until the point the data is flushed.
///
/// The most important operations on this object are:
///  - `append` to add an `IOData` to the list of pending writes.
///  - `markFlushCheckpoint` which sets a flush mark on the current position of the `MarkedCircularBuffer`. All the items before the checkpoint will be written eventually.
///  - `didWrite` when a number of bytes have been written.
///  - `failAll` if for some reason all outstanding writes need to be discarded and the corresponding `EventLoopPromise` needs to be failed.
private struct PendingStreamWritesState {
    private var pendingWrites = MarkedCircularBuffer<PendingStreamWrite>(initialRingCapacity: 16)
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
        let first = self.pendingWrites.removeFirst()
        switch first.data {
        case .byteBuffer(let buffer):
            self.subtractOutstanding(bytes: buffer.readableBytes)
        case .fileRegion(_):
            () /* not accounting for file region sizes */
        }
        return first.promise
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
        self.pendingWrites[0].data = .byteBuffer(buffer)
    }

    /// Initialise a new, empty `PendingWritesState`.
    public init() { }

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
    public mutating func append(_ chunk: PendingStreamWrite) {
        self.pendingWrites.append(chunk)
        self.chunks += 1
        switch chunk.data {
        case .byteBuffer(let buffer):
            self.bytes += buffer.readableBytes
        case .fileRegion(_):
            () /* not accounting for file region sizes */
        }
    }

    /// Get the outstanding write at `index`.
    public subscript(index: Int) -> PendingStreamWrite {
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

/// This class manages the writing of pending writes to stream sockets. The state is held in a `PendingWritesState`
/// value. The most important purpose of this object is to call `write`, `writev` or `sendfile` depending on the
/// currently pending writes.
final class PendingStreamWritesManager {
    private var state = PendingStreamWritesState()
    private var iovecs: UnsafeMutableBufferPointer<IOVector>
    private var storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>

    internal var waterMark: WriteBufferWaterMark = WriteBufferWaterMark(32 * 1024..<64 * 1024)
    private var writable: Atomic<Bool> = Atomic(value: true)

    internal var writeSpinCount: UInt = 16

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
        self.state.append(.init(data: data, promise: promise))

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
    func failAll(error: Error, close: Bool) {
        if close {
            assert(!self.closed)
            self.closed = true
        }

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
