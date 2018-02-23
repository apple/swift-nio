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

private struct PendingDatagramWrite {
    var data: ByteBuffer
    var promise: EventLoopPromise<Void>?
    let address: SocketAddress

    /// A helper function that copies the underlying sockaddr structure into temporary storage,
    /// and then returns the length.
    ///
    /// This copying is an annoyance, but one way or another this copy will have to happen as
    /// we do not want to expose the backing socket address to libc in case it mutates it. Becuase
    /// we are using a box to store the underlying sockaddr, if libc ever did mess with that data
    /// it will screw any other values pointing to that box. That would be a pretty bad scene. And
    /// in most cases we're not copying large values here: only for UDS does this become a problem.
    func copySocketAddress(_ target: UnsafeMutablePointer<sockaddr_storage>) -> socklen_t {
        switch address {
        case .v4(let innerAddress):
            return target.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee = innerAddress.address
                return socklen_t(MemoryLayout.size(ofValue: innerAddress.address))
            }
        case .v6(let innerAddress):
            return target.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                $0.pointee = innerAddress.address
                return socklen_t(MemoryLayout.size(ofValue: innerAddress.address))
            }
        case .unixDomainSocket:
            fatalError("UDS with datagrams is currently not supported")
        }
    }
}

/// This enum is used to keep track of flushes separate from writes for the datagram
/// channels. This is necessary to handle the richer flush promise notifications that
/// datagrams provide: specifically, some fraction of writes to datagram sockets may fail
/// for "recoverable" reasons, and those errors need to be reported on the flush promises.
/// That means it's vital we keep track of where the flushes were, which `MarkedCircularBuffer`
/// cannot do for us.
private enum PendingDatagramOperation {
    case write(PendingDatagramWrite)
    case flush(EventLoopPromise<Void>)
}

fileprivate extension Error {
    /// Returns whether the error is "recoverable" from the perspective of datagram sending.
    ///
    /// - returns: `true` if the error is recoverable, `false` otherwise.
    fileprivate func isRecoverable() -> Bool {
        switch self {
        case let e as IOError where e.errnoCode == EMSGSIZE,
             let e as IOError where e.errnoCode == EHOSTUNREACH:
            return true
        default:
            return false
        }
    }
}

/// Does the setup required to trigger a `sendmmsg`.
private func doPendingDatagramWriteVectorOperation(pending: PendingDatagramWritesState,
                                                   iovecs: UnsafeMutableBufferPointer<IOVector>,
                                                   msgs: UnsafeMutableBufferPointer<MMsgHdr>,
                                                   addresses: UnsafeMutableBufferPointer<sockaddr_storage>,
                                                   storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>,
                                                   _ fn: (UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int>) throws -> IOResult<Int> {
    assert(msgs.count >= Socket.writevLimitIOVectors, "Insufficiently sized buffer for a maximal sendmmsg")

    // the numbers of storage refs that we need to decrease later.
    var c = 0
    var toWrite: Int = 0

    for p in pending.flushedWrites {
        // Must not write more than Int32.max in one go.
        // TODO(cory): I can't see this limit documented in a man page anywhere, but it seems
        // plausible given that a similar limit exists for TCP. For now we assume it's present
        // in UDP until I can do some research to validate the existence of this limit.
        guard (Socket.writevLimitBytes - toWrite >= p.data.readableBytes) else {
            if c == 0 {
                // The first buffer is larger than the writev limit. Let's throw, and fall back to linear processing.
                throw IOError(errnoCode: EMSGSIZE, reason: "synthetic error for overlarge write")
            } else {
                break
            }
        }

        // Must not write more than writevLimitIOVectors in one go
        guard c < Socket.writevLimitIOVectors else {
            break
        }

        let toWriteForThisBuffer = p.data.readableBytes
        toWrite += toWriteForThisBuffer

        p.data.withUnsafeReadableBytesWithStorageManagement { ptr, storageRef in
            storageRefs[c] = storageRef.retain()
            let addressLen = p.copySocketAddress(addresses.baseAddress! + c)
            iovecs[c] = iovec(iov_base: UnsafeMutableRawPointer(mutating: ptr.baseAddress!), iov_len: toWriteForThisBuffer)

            var msg = msghdr(msg_name: addresses.baseAddress! + c,
                             msg_namelen: addressLen,
                             msg_iov: iovecs.baseAddress! + c,
                             msg_iovlen: 1,
                             msg_control: nil,
                             msg_controllen: 0,
                             msg_flags: 0)
            msgs[c] = MMsgHdr(msg_hdr: msg, msg_len: CUnsignedInt(toWriteForThisBuffer))
        }
        c += 1
    }
    defer {
        for i in 0..<c {
            storageRefs[i].release()
        }
    }
    return try fn(UnsafeMutableBufferPointer(start: msgs.baseAddress!, count: c))
}

/// This holds the states of the currently pending datagram writes. The core is a `MarkedCircularBuffer` which holds all the
/// writes and a mark up until the point the data is flushed. This struct has several behavioural differences from the
/// `PendingStreamWritesState`, most notably that it handles partial writes differently.
///
/// The most important operations on this object are:
///  - `append` to add a `ByteBuffer` to the list of pending writes.
///  - `markFlushCheckpoint` which sets a flush mark on the current position of the `MarkedCircularBuffer`. All the items before the checkpoint will be written eventually.
///  - `didWrite` when a number of bytes have been written.
///  - `failAll` if for some reason all outstanding writes need to be discarded and the corresponding `EventLoopPromise` needs to be failed.
private struct PendingDatagramWritesState {
    fileprivate typealias DatagramWritePromiseFiller = (EventLoopPromise<Void>, Error?)

    private var pendingWrites = MarkedCircularBuffer<PendingDatagramOperation>(initialRingCapacity: 16)
    private var chunks: Int = 0
    private var toBeFlushedErrors: [Error] = []
    public private(set) var bytes: Int = 0

    public var nextWrite: PendingDatagramWrite? {
        guard case .some(.write(let w)) = self.pendingWrites.first else {
            return nil
        }

        return w
    }

    /// Subtract `bytes` from the number of outstanding bytes to write.
    private mutating func subtractOutstanding(bytes: Int) {
        assert(self.bytes >= bytes, "allegedly written more bytes (\(bytes)) than outstanding (\(self.bytes))")
        self.bytes -= bytes
    }

    /// Indicates that the first outstanding write was written.
    ///
    /// - returns: The promise that the caller must fire, along with an error to fire it with if it needs one.
    ///
    private mutating func wroteFirst(error: Error? = nil) -> DatagramWritePromiseFiller? {
        guard case .write(let first) = self.pendingWrites.removeFirst() else {
            fatalError("First pending write is actually a flush")
        }

        self.chunks -= 1
        self.subtractOutstanding(bytes: first.data.readableBytes)
        if let promise = first.promise {
            return (promise, error)
        }

        return nil
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
    public mutating func append(_ chunk: PendingDatagramWrite) {
        self.pendingWrites.append(.write(chunk))
        self.chunks += 1
        self.bytes += chunk.data.readableBytes
    }

    /// Mark the flush checkpoint.
    ///
    /// All writes before this checkpoint will eventually be written to the socket.
    ///
    /// - parameters:
    ///     - The flush promise.
    public mutating func markFlushCheckpoint(promise: EventLoopPromise<Void>?) {
        guard self.pendingWrites.count > 0 else {
            // No writes mean this is a flush on empty, so we can satisfy this immediately.
            promise?.succeed(result: ())
            return
        }

        if let promise = promise {
            self.pendingWrites.append(.flush(promise))
        }
        self.pendingWrites.mark()
    }

    /// Indicate that a write has happened, this may be a write of multiple outstanding writes (using for example `sendmmsg`).
    ///
    /// - warning: The closure will simply fulfill all the promises in order. If one of those promises does for example close the `Channel` we might see subsequent writes fail out of order. Example: Imagine the user issues three writes: `A`, `B` and `C`. Imagine that `A` and `B` both get successfully written in one write operation but the user closes the `Channel` in `A`'s callback. Then overall the promises will be fulfilled in this order: 1) `A`: success 2) `C`: error 3) `B`: success. Note how `B` and `C` get fulfilled out of order.
    ///
    /// - parameters:
    ///     - data: The result of the write operation: namely, for each datagram we attempted to write, the number of bytes we wrote.
    ///     - messages: The vector messages written, if any.
    /// - returns: A list of promises and the error that should be sent to themn, if any, and a `WriteResult` which indicates if we could write everything or not.
    public mutating func didWrite(_ data: IOResult<Int>, messages: UnsafeMutableBufferPointer<MMsgHdr>?) -> ([DatagramWritePromiseFiller], OneWriteOperationResult) {
        switch data {
        case .processed(let written):
            if let messages = messages {
                return didVectorWrite(written: written, messages: messages)
            } else {
                return didScalarWrite(written: written)
            }
        case .wouldBlock:
            return ([], .wouldBlock)
        }
    }

    public mutating func recoverableError(_ error: Error) -> ([DatagramWritePromiseFiller], OneWriteOperationResult) {
        // When we've hit an error we treat it like fully writing the first datagram. We aren't going to try to
        // send it again.
        var pendingPromises: [DatagramWritePromiseFiller] = []
        self.toBeFlushedErrors.append(error)
        if let promiseFiller = self.wroteFirst(error: error) {
            pendingPromises.append(promiseFiller)
        }
        pendingPromises.append(contentsOf: self.processPendingFlushes())
        let result: OneWriteOperationResult = self.pendingWrites.hasMark() ? .writtenPartially : .writtenCompletely

        return (pendingPromises, result)
    }

    /// Indicates that a vector write succeeded.
    ///
    /// - parameters:
    ///     - written: The number of messages successfully written.
    ///     - messages: The list of message objects.
    /// - returns: A closure that the caller _needs_ to run which will fulfill the promises of the writes, and a `WriteResult` that indicates if we could write
    ///     everything or not.
    private mutating func didVectorWrite(written: Int, messages: UnsafeMutableBufferPointer<MMsgHdr>) -> ([DatagramWritePromiseFiller], OneWriteOperationResult) {
        var fillers: [DatagramWritePromiseFiller] = []

        // This was a vector write. We wrote `written` number of messages.
        let writes = messages[messages.startIndex...messages.index(messages.startIndex, offsetBy: written - 1)]

        for write in writes {
            let written = write.msg_len
            fillers.append(contentsOf: didScalarWrite(written: Int(written)).0)
        }

        // If we no longer have a mark, we wrote everything.
        let result: OneWriteOperationResult = self.pendingWrites.hasMark() ? .writtenPartially : .writtenCompletely
        return (fillers, result)
    }

    /// Indicates that a scalar write succeeded.
    ///
    /// - parameters:
    ///     - written: The number of bytes successfully written.
    /// - returns: All the promises that must be fired, and a `WriteResult` that indicates if we could write
    ///     everything or not.
    private mutating func didScalarWrite(written: Int) -> ([DatagramWritePromiseFiller], OneWriteOperationResult) {
        guard case .write(let write) = self.pendingWrites[0] else {
            fatalError("First write in queue is actually a flush")
        }

        precondition(written <= write.data.readableBytes,
                     "Appeared to write more bytes (\(written)) than the datagram contained (\(write.data.readableBytes))")
        var fillers: [DatagramWritePromiseFiller] = []
        if let writeFiller = self.wroteFirst() {
            fillers.append(writeFiller)
        }

        fillers.append(contentsOf: self.processPendingFlushes())

        // If we no longer have a mark, we wrote everything.
        let result: OneWriteOperationResult = self.pendingWrites.hasMark() ? .writtenPartially : .writtenCompletely
        return (fillers, result)
    }

    /// Returns any pending flush promises that need to be fired, along with (if needed) a composite error
    /// to fire them with.
    private mutating func processPendingFlushes() -> [DatagramWritePromiseFiller] {
        var results: [DatagramWritePromiseFiller] = []

        while case .some(.flush(let promise)) = self.pendingWrites.first {
            _ = self.pendingWrites.removeFirst()
            if self.toBeFlushedErrors.count > 0 {
                results.append((promise, NIOCompositeError(comprising: self.toBeFlushedErrors)))
            } else {
                results.append((promise, nil))
            }
        }

        if results.count > 0 {
            self.toBeFlushedErrors = []
        }

        return results
    }

    /// Is there a pending flush?
    public var isFlushPending: Bool {
        return self.pendingWrites.hasMark()
    }

    /// Fail all the outstanding writes.
    ///
    /// - warning: See the warning for `didWrite`.
    ///
    /// - returns: Nothing
    public mutating func failAll(error: Error) {
        var promises: [EventLoopPromise<Void>] = []
        promises.reserveCapacity(self.pendingWrites.count)

        while !self.pendingWrites.isEmpty {
            switch self.pendingWrites.removeFirst() {
            case .write(let w):
                self.chunks -= 1
                self.bytes -= w.data.readableBytes
                w.promise.map { promises.append($0) }
            case .flush(let p):
                promises.append(p)
            }
        }

        promises.forEach { $0.fail(error: error) }
    }

    /// Returns the best mechanism to write pending data at the current point in time.
    var currentBestWriteMechanism: WriteMechanism {
        var flushedWrites = self.flushedWrites

        if flushedWrites.next() == nil {
            return .nothingToBeWritten
        } else if flushedWrites.next() == nil {
            return .scalarBufferWrite
        } else {
            return .vectorBufferWrite
        }
    }
}

// This extension contains a lazy sequence that makes other parts of the code work better.
extension PendingDatagramWritesState {
    struct FlushedDatagramWriteSequence: Sequence, IteratorProtocol {
        private let pendingWrites: PendingDatagramWritesState
        private var index: Int
        private let markedIndex: Int

        init(_ pendingWrites: PendingDatagramWritesState) {
            self.pendingWrites = pendingWrites
            self.index = pendingWrites.pendingWrites.startIndex
            self.markedIndex = pendingWrites.pendingWrites.markedElementIndex() ?? -1
        }

        mutating func next() -> PendingDatagramWrite? {
            while self.index <= self.markedIndex {
                let element = self.pendingWrites.pendingWrites[index]
                index += 1
                switch element {
                case .write(let w):
                    return w
                case .flush:
                    continue
                }
            }

            return nil
        }
    }

    var flushedWrites: FlushedDatagramWriteSequence {
        return FlushedDatagramWriteSequence(self)
    }
}

/// This class manages the writing of pending writes to datagram sockets. The state is held in a `PendingWritesState`
/// value. The most important purpose of this object is to call `sendto` or `sendmmsg` depending on the writes held and
/// the availability of the functions.
final class PendingDatagramWritesManager: PendingWritesManager {
    /// Storage for mmsghdr strutures. Only present on Linux becuase Darwin does not support
    /// gathering datagram writes.
    private var msgs: UnsafeMutableBufferPointer<MMsgHdr>

    /// Storage for the references to the buffers used when we perform gathering writes. Only present
    /// on Linux because Darwin does not support gathering datagram writes.
    private var storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>

    /// Storage for iovec structures. Only present on Linux because this is only needed when we call
    /// sendmmsg: sendto doesn't require any iovecs.
    private var iovecs: UnsafeMutableBufferPointer<IOVector>

    /// Storage for sockaddr structures. Only present on Linux because Darwin does not support gathering
    /// writes.
    private var addresses: UnsafeMutableBufferPointer<sockaddr_storage>

    private var state = PendingDatagramWritesState()

    internal var waterMark: WriteBufferWaterMark = WriteBufferWaterMark(low: 32 * 1024, high: 64 * 1024)
    internal let channelWritabilityFlag: Atomic<Bool> = Atomic(value: true)
    internal var writeSpinCount: UInt = 16
    private(set) var isOpen = true

    /// Initialize with a pre-allocated array of message headers and storage references. We pass in these pre-allocated
    /// objects to save allocations. They can be safely be re-used for all `Channel`s on a given `EventLoop` as an
    /// `EventLoop` always runs on one and the same thread. That means that there can't be any writes of more than
    /// one `Channel` on the same `EventLoop` at the same time.
    ///
    /// - parameters:
    ///     - msgs: A pre-allocated array of `MMsgHdr` elements
    ///     - iovecs: A pre-allocated array of `IOVector` elements
    ///     - addresses: A pre-allocated array of `sockaddr_storage` elements
    ///     - storageRefs: A pre-allocated array of storage management tokens used to keep storage elements alive during a vector write operation
    init(msgs: UnsafeMutableBufferPointer<MMsgHdr>,
         iovecs: UnsafeMutableBufferPointer<IOVector>,
         addresses: UnsafeMutableBufferPointer<sockaddr_storage>,
         storageRefs: UnsafeMutableBufferPointer<Unmanaged<AnyObject>>) {
        self.msgs = msgs
        self.iovecs = iovecs
        self.addresses = addresses
        self.storageRefs = storageRefs
    }

    /// Mark the flush checkpoint.
    ///
    /// - parameters:
    ///     - The flush promise.
    func markFlushCheckpoint(promise: EventLoopPromise<Void>?) {
        self.state.markFlushCheckpoint(promise: promise)
    }

    /// Is there a flush pending?
    var isFlushPending: Bool {
        return self.state.isFlushPending
    }

    /// Are there any outstanding writes currently?
    var isEmpty: Bool {
        return self.state.isEmpty
    }

    /// Add a pending write.
    ///
    /// - parameters:
    ///     - envelope: The `AddressedEnvelope<IOData>` to write.
    ///     - promise: Optionally an `EventLoopPromise` that will get the write operation's result
    /// - result: If the `Channel` is still writable after adding the write of `data`.
    func add(envelope: AddressedEnvelope<ByteBuffer>, promise: EventLoopPromise<Void>?) -> Bool {
        assert(self.isOpen)
        self.state.append(.init(data: envelope.data, promise: promise, address: envelope.remoteAddress))

        if self.state.bytes > waterMark.high && channelWritabilityFlag.compareAndExchange(expected: true, desired: false) {
            // Returns false to signal the Channel became non-writable and we need to notify the user
            return false
        }
        return true
    }

    /// Returns the best mechanism to write pending data at the current point in time.
    var currentBestWriteMechanism: WriteMechanism {
        return self.state.currentBestWriteMechanism
    }

    /// Triggers the appropriate write operation. This is a fancy way of saying trigger either `sendto` or `sendmmsg`.
    /// On platforms that do not support a gathering write operation,
    ///
    /// - parameters:
    ///     - scalarWriteOperation: An operation that writes a single, contiguous array of bytes (usually `sendto`).
    ///     - vectorWriteOperation: An operation that writes multiple contiguous arrays of bytes (usually `sendmmsg`).
    /// - returns: The `WriteResult` and whether the `Channel` is now writable.
    func triggerAppropriateWriteOperations(scalarWriteOperation: (UnsafeRawBufferPointer, UnsafePointer<sockaddr>, socklen_t) throws -> IOResult<Int>,
                                           vectorWriteOperation: (UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int>) throws -> (writeResult: OverallWriteResult, writable: Bool) {
        return try self.triggerWriteOperations { writeMechanism in
            switch writeMechanism {
            case .scalarBufferWrite:
                return try triggerScalarBufferWrite(scalarWriteOperation: scalarWriteOperation)
            case .vectorBufferWrite:
                do {
                    return try triggerVectorBufferWrite(vectorWriteOperation: vectorWriteOperation)
                } catch {
                    // If the error we just hit is recoverable, we fall back to single write mode to
                    // isolate exactly which write triggered the problem.
                    guard error.isRecoverable() else {
                        throw error
                    }

                    return try triggerScalarBufferWrite(scalarWriteOperation: scalarWriteOperation)
                }
            case .scalarFileWrite:
                preconditionFailure("PendingDatagramWritesManager was handed a file write")
            case .nothingToBeWritten:
                assertionFailure("called \(#function) with nothing available to be written")
                return OneWriteOperationResult.writtenCompletely
            }
        }
    }

    /// To be called after a write operation (usually selected and run by `triggerAppropriateWriteOperation`) has
    /// completed.
    ///
    /// - parameters:
    ///     - data: The result of the write operation.
    private func didWrite(_ data: IOResult<Int>, messages: UnsafeMutableBufferPointer<MMsgHdr>?) -> OneWriteOperationResult {
        let (promises, result) = self.state.didWrite(data, messages: messages)

        if self.state.bytes < waterMark.low {
            channelWritabilityFlag.store(true)
        }

        self.fulfillPromises(promises)
        return result
    }

    /// Called after a scalar write operation has hit an error. Attempts to map some tolerable datagram errors to
    /// useful errors and fail the individual write, rather than fail the entire connection. If the error cannot
    /// be tolerated by a datagram application, will rethrow the error.
    ///
    /// - parameters:
    ///     - error: The error we hit.
    /// - returns: A `WriteResult` indicating whether the writes should continue.
    /// - throws: Any error that cannot be ignored by a datagram write.
    private func handleError(_ error: Error) throws -> OneWriteOperationResult {
        switch error {
        case let e as IOError where e.errnoCode == EMSGSIZE:
            let (promises, result) = self.state.recoverableError(ChannelError.writeMessageTooLarge)
            self.fulfillPromises(promises)
            return result
        case let e as IOError where e.errnoCode == EHOSTUNREACH:
            let (promises, result) = self.state.recoverableError(ChannelError.writeHostUnreachable)
            self.fulfillPromises(promises)
            return result
        default:
            throw error
        }
    }

    /// Trigger a write of a single object where an object can either be a contiguous array of bytes or a region of a file.
    ///
    /// - parameters:
    ///     - scalarWriteOperation: An operation that writes a single, contiguous array of bytes (usually `sendto`).
    private func triggerScalarBufferWrite(scalarWriteOperation: (UnsafeRawBufferPointer, UnsafePointer<sockaddr>, socklen_t) throws -> IOResult<Int>) rethrows -> OneWriteOperationResult {
        assert(self.state.isFlushPending && self.isOpen && !self.state.isEmpty,
               "illegal state for scalar datagram write operation: flushPending: \(self.state.isFlushPending), isOpen: \(self.isOpen), empty: \(self.state.isEmpty)")
        let pending = self.state.nextWrite!
        do {
            let writeResult = try pending.address.withSockAddr { (addrPtr, addrSize) in
                try pending.data.withUnsafeReadableBytes { try scalarWriteOperation($0, addrPtr, socklen_t(addrSize)) }
            }
            return self.didWrite(writeResult, messages: nil)
        } catch {
            return try self.handleError(error)
        }
    }

    /// Trigger a vector write operation. In other words: Write multiple contiguous arrays of bytes.
    ///
    /// - parameters:
    ///     - vectorWriteOperation: The vector write operation to use. Usually `sendmmsg`.
    private func triggerVectorBufferWrite(vectorWriteOperation: (UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int>) throws -> OneWriteOperationResult {
        assert(self.state.isFlushPending && self.isOpen && !self.state.isEmpty,
               "illegal state for vector datagram write operation: flushPending: \(self.state.isFlushPending), isOpen: \(self.isOpen), empty: \(self.state.isEmpty)")
        return self.didWrite(try doPendingDatagramWriteVectorOperation(pending: self.state,
                                                                       iovecs: self.iovecs,
                                                                       msgs: self.msgs,
                                                                       addresses: self.addresses,
                                                                       storageRefs: self.storageRefs,
                                                                       vectorWriteOperation),
                             messages: self.msgs)
    }

    private func fulfillPromises(_ results: [PendingDatagramWritesState.DatagramWritePromiseFiller]) {
        for result in results {
            if let error = result.1 {
                result.0.fail(error: error)
            } else {
                result.0.succeed(result: ())
            }
        }
    }

    /// Fail all the outstanding writes. This is useful if for example the `Channel` is closed.
    func failAll(error: Error, close: Bool) {
        if close {
            assert(self.isOpen)
            self.isOpen = false
        }

        self.state.failAll(error: error)

        assert(self.state.isEmpty)
    }
}
