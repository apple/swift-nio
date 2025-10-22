//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics
import CNIOLinux
import CNIOOpenBSD
import NIOCore

private struct PendingStreamWrite {
    var data: IOData
    var promise: Optional<EventLoopPromise<Void>>
}

/// Write result is `.couldNotWriteEverything` but we have no more writes to perform.
public struct NIOReportedIncompleteWritesWhenNoMoreToPerform: Error {}

/// Close result is `.open`.
public struct NIOReportedOpenAfterClose: Error {}

/// There are buffered writes after it should have been cleared, `.readyForClose` or `.closed` state
public struct NIOReportedPendingWritesInInvalidState: Error {}

/// Does the setup required to issue a writev.
///
/// - Parameters:
///    - pending: The currently pending writes.
///    - bufferPool: Pool of buffers to use for iovecs and storageRefs
///    - body: The function that actually does the vector write (usually `writev`).
/// - Returns: A tuple of the number of items attempted to write and the result of the write operation.
private func doPendingWriteVectorOperation(
    pending: PendingStreamWritesState,
    bufferPool: Pool<PooledBuffer>,
    _ body: (UnsafeBufferPointer<IOVector>) throws -> IOResult<Int>
) throws -> (itemCount: Int, writeResult: IOResult<Int>) {
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
                guard (numberOfUsedStorageSlots == 0) || (Socket.writevLimitBytes - toWrite >= buffer.readableBytes)
                else {
                    break loop
                }
                let toWriteForThisBuffer = min(Socket.writevLimitBytes, buffer.readableBytes)
                toWrite += numericCast(toWriteForThisBuffer)

                buffer.withUnsafeReadableBytesWithStorageManagement { ptr, storageRef in
                    storageRefs[i] = storageRef.retain()
                    iovecs[i] = IOVector(
                        iov_base: UnsafeMutableRawPointer(mutating: ptr.baseAddress!),
                        iov_len: numericCast(toWriteForThisBuffer)
                    )
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
        // if we hit a limit, we really wanted to write more than we have so the caller should retry us
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
    enum WriteOutcome: Equatable {
        /// Wrote all the data that was flushed. When receiving this result, we can unsubscribe from 'writable' notification.
        case writtenCompletely(WrittenCompletelyResult)

        /// Could not write everything. Before attempting further writes the eventing system should send a 'writable' notification.
        case couldNotWriteEverything

        /// The resulting status of a `PendingWritesManager` after a completely-written write
        ///
        /// This type is subtly different to `CloseState` so that it only surfaces the close promise when the caller
        /// is expected to fulfill it
        internal enum WrittenCompletelyResult: Equatable {
            case open
            case readyForClose(EventLoopPromise<Void>?)
            case closed(EventLoopPromise<Void>?)

            init(_ closeState: CloseState) {
                switch closeState {
                case .open:
                    self = .open
                case .pending(let closePromise), .readyForClose(let closePromise):
                    self = .readyForClose(closePromise)
                case .closed:
                    self = .closed(nil)
                }
            }
        }
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
        self.pendingWrites.markedElementIndex.map {
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
    /// - Returns: The `EventLoopPromise` of the write or `nil` if none was provided. The promise needs to be fulfilled by the caller.
    ///
    private mutating func fullyWrittenFirst() -> EventLoopPromise<Void>? {
        let first = self.pendingWrites.removeFirst()
        self.subtractOutstanding(bytes: first.data.readableBytes)
        return first.promise
    }

    /// Indicates that the first outstanding object has been partially written.
    ///
    /// - Parameters:
    ///   - bytes: How many bytes of the item were written.
    private mutating func partiallyWrittenFirst(bytes: Int) {
        self.pendingWrites[self.pendingWrites.startIndex].data.moveReaderIndex(forwardBy: bytes)
        self.subtractOutstanding(bytes: bytes)
    }

    /// Initialize a new, empty `PendingWritesState`.
    public init() {}

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
        self.pendingWrites[self.pendingWrites.index(self.pendingWrites.startIndex, offsetBy: index)]
    }

    /// Mark the flush checkpoint.
    ///
    /// All writes before this checkpoint will eventually be written to the socket.
    public mutating func markFlushCheckpoint() {
        self.pendingWrites.mark()
    }

    /// Indicate that a write has happened, this may be a write of multiple outstanding writes (using for example `writev`).
    ///
    /// - warning: The promises will be returned in order. If one of those promises does for example close the `Channel` we might see subsequent writes fail out of order. Example: Imagine the user issues three writes: `A`, `B` and `C`. Imagine that `A` and `B` both get successfully written in one write operation but the user closes the `Channel` in `A`'s callback. Then overall the promises will be fulfilled in this order: 1) `A`: success 2) `C`: error 3) `B`: success. Note how `B` and `C` get fulfilled out of order.
    ///
    /// - Parameters:
    ///   - writeResult: The result of the write operation.
    /// - Returns: A tuple of a promise and a `OneWriteResult`. The promise is the first promise that needs to be notified of the write result.
    ///            This promise will cascade the result to all other promises that need notifying. If no promises need to be notified, will be `nil`.
    ///            The write result will indicate whether we were able to write everything or not.
    public mutating func didWrite(
        itemCount: Int,
        result writeResult: IOResult<Int>
    ) -> (EventLoopPromise<Void>?, OneWriteOperationResult) {
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
                    // we wrote at least the whole head item, so drop it and succeed the promise
                    if let promise = self.fullyWrittenFirst() {
                        if let p = promise0 {
                            p.futureResult.cascade(to: promise)
                        } else {
                            promise0 = promise
                        }
                    }
                } else {
                    // we could only write a part of the head item, so don't drop it but remember what we wrote
                    self.partiallyWrittenFirst(bytes: unaccountedWrites)

                    // may try again depending on the writeSpinCount
                    return (promise0, .writtenPartially)
                }
            }
            assert(
                unaccountedWrites == 0,
                "after doing all the accounting for the byte written, \(unaccountedWrites) bytes of unaccounted writes remain."
            )
            return (promise0, .writtenCompletely)
        }
    }

    /// Is there a pending flush?
    public var isFlushPending: Bool {
        self.pendingWrites.hasMark
    }

    /// Remove all pending writes and return a `EventLoopPromise` which will cascade notifications to all.
    ///
    /// - warning: See the warning for `didWrite`.
    ///
    /// - Returns: promise that needs to be failed, or `nil` if there were no pending writes.
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
            switch (
                self.pendingWrites[startIndex].data,
                self.pendingWrites[self.pendingWrites.index(after: startIndex)].data
            ) {
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

    internal var waterMark: ChannelOptions.Types.WriteBufferWaterMark = ChannelOptions.Types.WriteBufferWaterMark(
        low: 32 * 1024,
        high: 64 * 1024
    )
    internal let channelWritabilityFlag = ManagedAtomic(true)
    internal var publishedWritability = true

    internal var writeSpinCount: UInt = 16

    private(set) var isOpen = true

    private(set) var outboundCloseState: CloseState = .open

    /// Mark the flush checkpoint.
    func markFlushCheckpoint() {
        self.state.markFlushCheckpoint()
    }

    /// Is there a flush pending?
    var isFlushPending: Bool {
        self.state.isFlushPending
    }

    /// Are there any outstanding writes currently?
    var isEmpty: Bool {
        self.state.isEmpty
    }

    var bufferedBytes: Int64 {
        self.state.bytes
    }

    /// Add a pending write alongside its promise.
    ///
    /// - Parameters:
    ///   - data: The `IOData` to write.
    ///   - promise: Optionally an `EventLoopPromise` that will get the write operation's result
    /// - result: If the `Channel` is still writable after adding the write of `data`.
    func add(data: IOData, promise: EventLoopPromise<Void>?) -> Bool {
        assert(self.isOpen)
        self.state.append(PendingStreamWrite(data: data, promise: promise))

        if self.state.bytes > waterMark.high
            && channelWritabilityFlag.compareExchange(expected: true, desired: false, ordering: .relaxed).exchanged
        {
            // Returns false to signal the Channel became non-writable and we need to notify the user.
            self.publishedWritability = false
            return false
        }
        return true
    }

    /// Returns the best mechanism to write pending data at the current point in time.
    var currentBestWriteMechanism: WriteMechanism {
        self.state.currentBestWriteMechanism
    }

    /// Triggers the appropriate write operation. This is a fancy way of saying trigger either `write`, `writev` or
    /// `sendfile`.
    ///
    /// - Parameters:
    ///   - scalarBufferWriteOperation: An operation that writes a single, contiguous array of bytes (usually `write`).
    ///   - vectorBufferWriteOperation: An operation that writes multiple contiguous arrays of bytes (usually `writev`).
    ///   - scalarFileWriteOperation: An operation that writes a region of a file descriptor (usually `sendfile`).
    /// - Returns: The `OneWriteOperationResult` and whether the `Channel` is now writable.
    func triggerAppropriateWriteOperations(
        scalarBufferWriteOperation: (UnsafeRawBufferPointer) throws -> IOResult<Int>,
        vectorBufferWriteOperation: (UnsafeBufferPointer<IOVector>) throws -> IOResult<Int>,
        scalarFileWriteOperation: (CInt, Int, Int) throws -> IOResult<Int>
    ) throws -> OverallWriteResult {
        try self.triggerWriteOperations { writeMechanism in
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
    /// - Parameters:
    ///   - itemCount: The number of items we tried to write.
    ///   - result: The result of the write operation.
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
    /// - Parameters:
    ///   - operation: An operation that writes a single, contiguous array of bytes (usually `write`).
    private func triggerScalarBufferWrite(
        _ operation: (UnsafeRawBufferPointer) throws -> IOResult<Int>
    ) throws -> OneWriteOperationResult {
        assert(
            self.state.isFlushPending && !self.state.isEmpty && self.isOpen,
            "single write called in illegal state: flush pending: \(self.state.isFlushPending), empty: \(self.state.isEmpty), isOpen: \(self.isOpen)"
        )

        switch self.state[0].data {
        case .byteBuffer(let buffer):
            return self.didWrite(itemCount: 1, result: try buffer.withUnsafeReadableBytes({ try operation($0) }))
        case .fileRegion:
            preconditionFailure("called \(#function) but first item to write was a FileRegion")
        }
    }

    /// Trigger a write of a single `FileRegion` (usually using `sendfile(2)`).
    ///
    /// - Parameters:
    ///   - operation: An operation that writes a region of a file descriptor.
    private func triggerScalarFileWrite(
        _ operation: (CInt, Int, Int) throws -> IOResult<Int>
    ) throws -> OneWriteOperationResult {
        assert(
            self.state.isFlushPending && !self.state.isEmpty && self.isOpen,
            "single write called in illegal state: flush pending: \(self.state.isFlushPending), empty: \(self.state.isEmpty), isOpen: \(self.isOpen)"
        )

        switch self.state[0].data {
        case .fileRegion(let file):
            let readerIndex = file.readerIndex
            let endIndex = file.endIndex
            let writeResult = try file.fileHandle.withUnsafeFileDescriptor { fd in
                try operation(fd, readerIndex, endIndex)
            }
            return self.didWrite(itemCount: 1, result: writeResult)
        case .byteBuffer:
            preconditionFailure("called \(#function) but first item to write was a ByteBuffer")
        }
    }

    /// Trigger a vector write operation. In other words: Write multiple contiguous arrays of bytes.
    ///
    /// - Parameters:
    ///   - operation: The vector write operation to use. Usually `writev`.
    private func triggerVectorBufferWrite(
        _ operation: (UnsafeBufferPointer<IOVector>) throws -> IOResult<Int>
    ) throws -> OneWriteOperationResult {
        assert(
            self.state.isFlushPending && !self.state.isEmpty && self.isOpen,
            "vector write called in illegal state: flush pending: \(self.state.isFlushPending), empty: \(self.state.isEmpty), isOpen: \(self.isOpen)"
        )
        let result = try doPendingWriteVectorOperation(
            pending: self.state,
            bufferPool: bufferPool,
            { try operation($0) }
        )
        return self.didWrite(itemCount: result.itemCount, result: result.writeResult)
    }

    /// Fail all the outstanding writes.
    func failAll(error: Error) -> EventLoopPromise<Void>? {
        let promise: EventLoopPromise<Void>?
        self.isOpen = false
        switch self.outboundCloseState {
        case .open, .closed:
            self.outboundCloseState = .closed
            promise = nil
        case .pending(let closePromise), .readyForClose(let closePromise):
            self.outboundCloseState = .closed
            promise = closePromise
        }

        self.state.removeAll()?.fail(error)

        assert(self.state.isEmpty)
        return promise
    }

    // The result of calling `closeOutbound`
    enum CloseOutboundResult {
        case pending
        case readyForClose(EventLoopPromise<Void>?)
        case closed(EventLoopPromise<Void>?)
        case errored(Error, EventLoopPromise<Void>?)

        init(_ closeState: CloseState, _ isEmpty: Bool, _ promise: EventLoopPromise<Void>?) {
            switch closeState {
            case .open:
                assertionFailure(
                    "We are in .open state after being asked to close. This should never happen."
                )
                self = .errored(NIOReportedOpenAfterClose(), promise)
            case .pending:
                // `promise` has already been taken care of in the pending state for later completion
                self = .pending
            case .readyForClose(let closePromise):
                if isEmpty {
                    self = .readyForClose(closePromise)
                } else {
                    assertionFailure(
                        "We are in .readyForClose state but we still have pending writes. This should never happen."
                    )
                    // `promise` has already been cascaded off `closePromise`
                    self = .errored(NIOReportedPendingWritesInInvalidState(), closePromise)
                }
            case .closed:
                if isEmpty {
                    self = .closed(promise)
                } else {
                    assertionFailure(
                        "We are in .closed state but we still have pending writes. This should never happen."
                    )
                    self = .errored(NIOReportedPendingWritesInInvalidState(), promise)
                }
            }
        }
    }

    /// Signal the intention to close. Takes a promise which will be returned for completing when pending writes are dealt with
    ///
    /// - Parameters:
    ///   - promise: Optionally an `EventLoopPromise` which is stored and is returned to be completed by the caller once
    ///              all outstanding writes have been dealt with or an error condition is encountered.
    func closeOutbound(_ promise: EventLoopPromise<Void>?) -> CloseOutboundResult {
        // Update our internal state
        switch self.outboundCloseState {
        case .open:
            if self.isEmpty {
                self.outboundCloseState = .readyForClose(promise)
            } else {
                self.outboundCloseState = .pending(promise)
            }
        case .readyForClose(var closePromise):
            closePromise.setOrCascade(to: promise)
            self.outboundCloseState = .readyForClose(closePromise)
        case .pending(var closePromise):
            closePromise.setOrCascade(to: promise)
            if self.isEmpty {
                self.outboundCloseState = .readyForClose(closePromise)
            } else {
                self.outboundCloseState = .pending(closePromise)
            }
        case .closed:
            ()
        }

        // Decide on the result
        let result = CloseOutboundResult(self.outboundCloseState, self.isEmpty, promise)
        switch result {
        case .pending, .readyForClose:
            ()
        case .closed, .errored:
            self.isOpen = false
        }

        return result
    }

    /// Initialize with a pre-allocated array of IO vectors and storage references. We pass in these pre-allocated
    /// objects to save allocations. They can be safely be re-used for all `Channel`s on a given `EventLoop` as an
    /// `EventLoop` always runs on one and the same thread. That means that there can't be any writes of more than
    /// one `Channel` on the same `EventLoop` at the same time.
    ///
    /// - Parameters:
    ///   - bufferPool: Pool of buffers to be used for iovecs and storage references
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
    var isEmpty: Bool { get }
    var outboundCloseState: CloseState { get }
    var isFlushPending: Bool { get }
    var writeSpinCount: UInt { get }
    var currentBestWriteMechanism: WriteMechanism { get }
    var channelWritabilityFlag: ManagedAtomic<Bool> { get }

    /// Represents the writability state the last time we published a writability change to the `Channel`.
    /// This is used in `triggerWriteOperations` to determine whether we need to trigger a writability
    /// change.
    var publishedWritability: Bool { get set }
}

/// Describes the state that a `PendingWritesManager` closure state machine will step through when instructed to close
internal enum CloseState {
    /// The manager will accept new writes
    case open
    /// The manager has been asked to close but cannot because its write buffer is not empty
    case pending(EventLoopPromise<Void>?)
    /// The manager has been asked to close and is ready to be closed because its write buffer is empty
    case readyForClose(EventLoopPromise<Void>?)
    /// The manager is closed
    case closed
}

extension PendingWritesManager {
    // This is called from `Channel` API so must be thread-safe.
    var isWritable: Bool {
        self.channelWritabilityFlag.load(ordering: .relaxed)
    }

    internal func triggerWriteOperations(
        triggerOneWriteOperation: (WriteMechanism) throws -> OneWriteOperationResult
    ) throws -> OverallWriteResult {
        var result = OverallWriteResult(writeResult: .couldNotWriteEverything, writabilityChange: false)

        writeSpinLoop: for _ in 0...self.writeSpinCount {
            var oneResult: OneWriteOperationResult
            repeat {
                guard self.isOpen && self.isFlushPending else {
                    result.writeResult = .writtenCompletely(.init(self.outboundCloseState))
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
        "PendingStreamWritesManager { isFlushPending: \(self.isFlushPending), "
            + "writabilityFlag: \(self.channelWritabilityFlag.load(ordering: .relaxed))), state: \(self.state) }"
    }
}
