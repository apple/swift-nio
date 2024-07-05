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

private struct PendingDatagramWrite {
    var data: ByteBuffer
    var promise: Optional<EventLoopPromise<Void>>
    let address: SocketAddress?
    var metadata: AddressedEnvelope<ByteBuffer>.Metadata?

    /// A helper function that copies the underlying sockaddr structure into temporary storage,
    /// and then returns the length.
    ///
    /// This copying is an annoyance, but one way or another this copy will have to happen as
    /// we do not want to expose the backing socket address to libc in case it mutates it. Because
    /// we are using a box to store the underlying sockaddr, if libc ever did mess with that data
    /// it will screw any other values pointing to that box. That would be a pretty bad scene. And
    /// in most cases we're not copying large values here: only for UDS does this become a problem.
    func copySocketAddress(_ target: UnsafeMutablePointer<sockaddr_storage>) -> socklen_t {
        let erased = UnsafeMutableRawPointer(target)

        switch self.address {
        case .none:
            preconditionFailure("copySocketAddress called on write that has no address")
        case .v4(let innerAddress):
            erased.storeBytes(of: innerAddress.address, as: sockaddr_in.self)
            //return socklen_t(MemoryLayout.size(ofValue: innerAddress.address))
            return socklen_t(MemoryLayout<sockaddr_in>.size)
        case .v6(let innerAddress):
            erased.storeBytes(of: innerAddress.address, as: sockaddr_in6.self)
            return socklen_t(MemoryLayout.size(ofValue: innerAddress.address))
        case .unixDomainSocket:
            fatalError("UDS with datagrams is currently not supported")
        }
    }
}

fileprivate extension Error {
    /// Returns whether the error is "recoverable" from the perspective of datagram sending.
    ///
    /// - returns: `true` if the error is recoverable, `false` otherwise.
    var isRecoverable: Bool {
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
                                                   bufferPool: Pool<PooledBuffer>,
                                                   msgs: UnsafeMutableBufferPointer<MMsgHdr>,
                                                   addresses: UnsafeMutableBufferPointer<sockaddr_storage>,
                                                   controlMessageStorage: UnsafeControlMessageStorage,
                                                   _ body: (UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int>) throws -> IOResult<Int> {
    assert(msgs.count >= Socket.writevLimitIOVectors, "Insufficiently sized buffer for a maximal sendmmsg")
    assert(controlMessageStorage.count >= Socket.writevLimitIOVectors,
           "Insufficiently sized control message storage for a maximal sendmmsg")

    // the numbers of storage refs that we need to decrease later.
    var c = 0
    var toWrite: Int = 0

    let buffer = bufferPool.get()
    defer { bufferPool.put(buffer) }

    return try buffer.withUnsafePointers { iovecs, storageRefs in
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
            toWrite += numericCast(toWriteForThisBuffer)

            p.data.withUnsafeReadableBytesWithStorageManagement { ptr, storageRef in
                storageRefs[c] = storageRef.retain()

                /// From man page of `sendmsg(2)`:
                ///
                /// > The `msg_name` field is used on an unconnected socket to specify
                /// > the target address for a datagram.  It points to a buffer
                /// > containing the address; the `msg_namelen` field should be set to
                /// > the size of the address.  For a connected socket, these fields
                /// > should be specified as `NULL` and 0, respectively.
                let address: UnsafeMutablePointer<sockaddr_storage>?
                let addressLen: socklen_t
                let protocolFamily: NIOBSDSocket.ProtocolFamily
                if let envelopeAddress = p.address {
                    precondition(pending.remoteAddress == nil, "Pending write with address on connected socket.")
                    address = addresses.baseAddress! + c
                    addressLen = p.copySocketAddress(address!)
                    protocolFamily = envelopeAddress.protocol
                } else {
                    guard let connectedRemoteAddress = pending.remoteAddress else {
                        preconditionFailure("Pending write without address on unconnected socket.")
                    }
                    address = nil
                    addressLen = 0
                    protocolFamily = connectedRemoteAddress.protocol
                }

                iovecs[c] = iovec(iov_base: UnsafeMutableRawPointer(mutating: ptr.baseAddress!), iov_len: numericCast(toWriteForThisBuffer))

                var controlBytes = UnsafeOutboundControlBytes(controlBytes: controlMessageStorage[c])
                controlBytes.appendExplicitCongestionState(metadata: p.metadata, protocolFamily: protocolFamily)
                let controlMessageBytePointer = controlBytes.validControlBytes

                var msg = msghdr()
                msg.msg_name = .init(address)
                msg.msg_namelen = addressLen
                msg.msg_iov = iovecs.baseAddress! + c
                msg.msg_iovlen = 1
                msg.msg_control = controlMessageBytePointer.baseAddress
                msg.msg_controllen = .init(controlMessageBytePointer.count)
                msg.msg_flags = 0
                msgs[c] = MMsgHdr(msg_hdr: msg, msg_len: 0)
            }
            c += 1
        }
        defer {
            for i in 0..<c {
                storageRefs[i].release()
            }
        }
        return try body(UnsafeMutableBufferPointer(start: msgs.baseAddress!, count: c))
    }
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

    private var pendingWrites = MarkedCircularBuffer<PendingDatagramWrite>(initialCapacity: 16)
    private var chunks: Int = 0
    public private(set) var bytes: Int64 = 0
    private(set) var remoteAddress: SocketAddress? = nil

    public var nextWrite: PendingDatagramWrite? {
        return self.pendingWrites.first
    }

    /// Subtract `bytes` from the number of outstanding bytes to write.
    private mutating func subtractOutstanding(bytes: Int) {
        assert(self.bytes >= bytes, "allegedly written more bytes (\(bytes)) than outstanding (\(self.bytes))")
        self.bytes -= numericCast(bytes)
    }

    /// Indicates that the first outstanding write was written.
    ///
    /// - returns: The promise that the caller must fire, along with an error to fire it with if it needs one.
    private mutating func wroteFirst(error: Error? = nil) -> DatagramWritePromiseFiller? {
        let first = self.pendingWrites.removeFirst()
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
            assert(!self.pendingWrites.hasMark)
            return true
        } else {
            assert(self.chunks > 0 && self.bytes >= 0)
            return false
        }
    }

    /// Add a new write and optionally the corresponding promise to the list of outstanding writes.
    public mutating func append(_ chunk: PendingDatagramWrite) {
        self.pendingWrites.append(chunk)
        self.chunks += 1
        self.bytes += numericCast(chunk.data.readableBytes)
    }

    /// Mark the flush checkpoint.
    ///
    /// All writes before this checkpoint will eventually be written to the socket.
    public mutating func markFlushCheckpoint() {
        self.pendingWrites.mark()
    }

    mutating func markConnected(to remoteAddress: SocketAddress) {
        self.remoteAddress = remoteAddress
    }

    /// Indicate that a write has happened, this may be a write of multiple outstanding writes (using for example `sendmmsg`).
    ///
    /// - warning: The closure will simply fulfill all the promises in order. If one of those promises does for example close the `Channel` we might see subsequent writes fail out of order. Example: Imagine the user issues three writes: `A`, `B` and `C`. Imagine that `A` and `B` both get successfully written in one write operation but the user closes the `Channel` in `A`'s callback. Then overall the promises will be fulfilled in this order: 1) `A`: success 2) `C`: error 3) `B`: success. Note how `B` and `C` get fulfilled out of order.
    ///
    /// - parameters:
    ///     - data: The result of the write operation: namely, for each datagram we attempted to write, the number of bytes we wrote.
    ///     - messages: The vector messages written, if any.
    /// - returns: A promise and the error that should be sent to it, if any, and a `WriteResult` which indicates if we could write everything or not.
    public mutating func didWrite(_ data: IOResult<Int>, messages: UnsafeMutableBufferPointer<MMsgHdr>?) -> (DatagramWritePromiseFiller?, OneWriteOperationResult) {
        switch data {
        case .processed(let written):
            if let messages = messages {
                return didVectorWrite(written: written, messages: messages)
            } else {
                return didScalarWrite(written: written)
            }
        case .wouldBlock:
            return (nil, .wouldBlock)
        }
    }

    public mutating func recoverableError(_ error: Error) -> (DatagramWritePromiseFiller?, OneWriteOperationResult) {
        // When we've hit an error we treat it like fully writing the first datagram. We aren't going to try to
        // send it again.
        let promiseFiller = self.wroteFirst(error: error)
        let result: OneWriteOperationResult = self.pendingWrites.hasMark ? .writtenPartially : .writtenCompletely
        return (promiseFiller, result)
    }

    /// Indicates that a vector write succeeded.
    ///
    /// - parameters:
    ///     - written: The number of messages successfully written.
    ///     - messages: The list of message objects.
    /// - returns: A closure that the caller _needs_ to run which will fulfill the promises of the writes, and a `WriteResult` that indicates if we could write
    ///     everything or not.
    private mutating func didVectorWrite(written: Int, messages: UnsafeMutableBufferPointer<MMsgHdr>) -> (DatagramWritePromiseFiller?, OneWriteOperationResult) {
        // This was a vector write. We wrote `written` number of messages.
        let writes = messages[messages.startIndex...messages.index(messages.startIndex, offsetBy: written - 1)]
        var promiseFiller: DatagramWritePromiseFiller?

        for write in writes {
            let written = write.msg_len
            let thisWriteFiller = didScalarWrite(written: Int(written)).0
            assert(thisWriteFiller?.1 == nil, "didVectorWrite called with errors on single writes!")

            switch (promiseFiller, thisWriteFiller) {
            case (.some(let all), .some(let this)):
                all.0.futureResult.cascade(to: this.0)
            case (.none, .some(let this)):
                promiseFiller = this
            case (.some, .none),
                 (.none, .none):
                break
            }
        }

        // If we no longer have a mark, we wrote everything.
        let result: OneWriteOperationResult = self.pendingWrites.hasMark ? .writtenPartially : .writtenCompletely
        return (promiseFiller, result)
    }

    /// Indicates that a scalar write succeeded.
    ///
    /// - parameters:
    ///     - written: The number of bytes successfully written.
    /// - returns: All the promises that must be fired, and a `WriteResult` that indicates if we could write
    ///     everything or not.
    internal mutating func didScalarWrite(written: Int) -> (DatagramWritePromiseFiller?, OneWriteOperationResult) {
        precondition(written <= self.pendingWrites.first!.data.readableBytes,
                     "Appeared to write more bytes (\(written)) than the datagram contained (\(self.pendingWrites.first!.data.readableBytes))")
        let writeFiller = self.wroteFirst()
        // If we no longer have a mark, we wrote everything.
        let result: OneWriteOperationResult = self.pendingWrites.hasMark ? .writtenPartially : .writtenCompletely
        return (writeFiller, result)
    }

    /// Is there a pending flush?
    public var isFlushPending: Bool {
        return self.pendingWrites.hasMark
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
            let w = self.pendingWrites.removeFirst()
            self.chunks -= 1
            self.bytes -= numericCast(w.data.readableBytes)
            w.promise.map { promises.append($0) }
        }

        promises.forEach { $0.fail(error) }
    }

    /// Returns the best mechanism to write pending data at the current point in time.
    var currentBestWriteMechanism: WriteMechanism {
        switch self.pendingWrites.markedElementIndex {
        case .some(let e) where self.pendingWrites.distance(from: self.pendingWrites.startIndex, to: e) > 0:
            return .vectorBufferWrite
        case .some(let e):
            // The compiler can't prove this, but it must be so.
            assert(self.pendingWrites.distance(from: e, to: self.pendingWrites.startIndex)  == 0)
            return .scalarBufferWrite
        default:
            return .nothingToBeWritten
        }
    }
}

// This extension contains a lazy sequence that makes other parts of the code work better.
extension PendingDatagramWritesState {
    struct FlushedDatagramWriteSequence: Sequence, IteratorProtocol {
        private let pendingWrites: PendingDatagramWritesState
        private var index: CircularBuffer<PendingDatagramWrite>.Index
        private let markedIndex: CircularBuffer<PendingDatagramWrite>.Index?

        init(_ pendingWrites: PendingDatagramWritesState) {
            self.pendingWrites = pendingWrites
            self.index = pendingWrites.pendingWrites.startIndex
            self.markedIndex = pendingWrites.pendingWrites.markedElementIndex
        }

        mutating func next() -> PendingDatagramWrite? {
            while let markedIndex = self.markedIndex, self.pendingWrites.pendingWrites.distance(from: self.index,
                                                                                                to: markedIndex) >= 0 {
                let element = self.pendingWrites.pendingWrites[index]
                index = self.pendingWrites.pendingWrites.index(after: index)
                return element
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

    /// storage for IOVector and the references to the buffers used when we perform gathering writes. Only present
    /// on Linux because Darwin does not support gathering datagram writes.
    private var bufferPool: Pool<PooledBuffer>
    private var buffer: PooledBuffer?

    /// Storage for mmsghdr and sockaddr structures.
    /// Only present on Linux because Darwin does not support gathering datagram writes.
    private var msgBufferPool: Pool<PooledMsgBuffer>
    private var msgBuffer: PooledMsgBuffer?

    private var state = PendingDatagramWritesState()

    internal var waterMark: ChannelOptions.Types.WriteBufferWaterMark = ChannelOptions.Types.WriteBufferWaterMark(low: 32 * 1024, high: 64 * 1024)
    internal let channelWritabilityFlag = ManagedAtomic<Bool>(true)
    internal var publishedWritability = true
    internal var writeSpinCount: UInt = 16
    private(set) var isOpen = true

    /// Initialize with a pre-allocated array of message headers and storage references. We pass in these pre-allocated
    /// objects to save allocations. They can be safely be re-used for all `Channel`s on a given `EventLoop` as an
    /// `EventLoop` always runs on one and the same thread. That means that there can't be any writes of more than
    /// one `Channel` on the same `EventLoop` at the same time.
    ///
    /// - parameters:
    ///     - bufferPool: a pool of buffers to be used for IOVector and storage references
    ///     - msgBufferPool: a pool of buffers to be usded for `MMsgHdr`, `sockaddr_storage` and cmsghdr elements
    init(bufferPool: Pool<PooledBuffer>, msgBufferPool: Pool<PooledMsgBuffer>) {
        self.bufferPool = bufferPool
        self.msgBufferPool = msgBufferPool
    }

    /// Mark the flush checkpoint.
    func markFlushCheckpoint() {
        self.state.markFlushCheckpoint()
    }

    /// Mark that the socket is connected.
    func markConnected(to remoteAddress: SocketAddress) {
        self.state.markConnected(to: remoteAddress)
    }

    /// Is there a flush pending?
    var isFlushPending: Bool {
        return self.state.isFlushPending
    }

    /// Are there any outstanding writes currently?
    var isEmpty: Bool {
        return self.state.isEmpty
    }

    private func add(_ pendingWrite: PendingDatagramWrite) -> Bool {
        assert(self.isOpen)
        self.state.append(pendingWrite)

        if self.state.bytes > waterMark.high &&
            channelWritabilityFlag.compareExchange(expected: true, desired: false, ordering: .relaxed).exchanged {
            // Returns false to signal the Channel became non-writable and we need to notify the user.
            self.publishedWritability = false
            return false
        }
        return true
    }

    /// Add a pending write, with an `AddressedEnvelope`, usually on an unconnected socket.
    ///
    /// - parameters:
    ///     - envelope: The `AddressedEnvelope<ByteBuffer>` to write.
    ///     - promise: Optionally an `EventLoopPromise` that will get the write operation's result
    /// - returns: If the `Channel` is still writable after adding the write of `data`.
    ///
    /// - warning: If the socket is connected, then the `envelope.remoteAddress` _must_ match the
    /// address of the connected peer, otherwise this function will throw a fatal error.
    func add(envelope: AddressedEnvelope<ByteBuffer>, promise: EventLoopPromise<Void>?) -> Bool {
        if let remoteAddress = self.state.remoteAddress {
            precondition(envelope.remoteAddress == remoteAddress, """
                Remote address of AddressedEnvelope does not match remote address of connected socket.
                """)
            return self.add(PendingDatagramWrite(
                data: envelope.data,
                promise: promise,
                address: nil,
                metadata: envelope.metadata))
        } else {
            return self.add(PendingDatagramWrite(
                data: envelope.data,
                promise: promise,
                address: envelope.remoteAddress,
                metadata: envelope.metadata))
        }
    }

    /// Add a pending write, without an `AddressedEnvelope`, on a connected socket.
    ///
    /// - parameters:
    ///     - data: The `ByteBuffer` to write.
    ///     - promise: Optionally an `EventLoopPromise` that will get the write operation's result
    /// - returns: If the `Channel` is still writable after adding the write of `data`.
    func add(data: ByteBuffer, promise: EventLoopPromise<Void>?) -> Bool {
        return self.add(PendingDatagramWrite(
            data: data,
            promise: promise,
            address: nil,
            metadata: nil))
    }

    /// Returns the best mechanism to write pending data at the current point in time.
    var currentBestWriteMechanism: WriteMechanism {
        return self.state.currentBestWriteMechanism
    }

    func triggerAsnycWriteOperation(asyncWriteOperation: (UnsafePointer<msghdr>) throws -> Void) throws -> Void {
        let pdw = self.state.nextWrite
        if let pdw = pdw {
            self.buffer = self.bufferPool.get()
            self.msgBuffer = self.msgBufferPool.get()
            try self.buffer!.withUnsafePointers { iovecs, storageRefs in
                try self.msgBuffer!.withUnsafePointers { msgs, addresses, controlMessageStorage in
                    try pdw.data.withUnsafeReadableBytesWithStorageManagement { ptr, storageRef in
                        storageRefs[0] = storageRef.retain()

                        let address: UnsafeMutablePointer<sockaddr_storage>?
                        let addressLen: socklen_t
                        let protocolFamily: NIOBSDSocket.ProtocolFamily
                        if let envelopeAddress = pdw.address {
                            precondition(self.state.remoteAddress == nil, "Pending write with address on connected socket.")
                            address = addresses.baseAddress
                            addressLen = pdw.copySocketAddress(address!)
                            protocolFamily = envelopeAddress.protocol
                        }
                        else {
                            guard let connectedRemoteAddress = self.state.remoteAddress else {
                                preconditionFailure("Pending write without address on unconnected socket.")
                            }
                            address = nil
                            addressLen = 0
                            protocolFamily = connectedRemoteAddress.protocol
                        }

                        iovecs[0] = iovec(iov_base: UnsafeMutableRawPointer(mutating: ptr.baseAddress!), iov_len: ptr.count)

                        var controlBytes = UnsafeOutboundControlBytes(controlBytes: controlMessageStorage[0])
                        controlBytes.appendExplicitCongestionState(metadata: pdw.metadata, protocolFamily: protocolFamily)
                        let controlMessageBytePointer = controlBytes.validControlBytes

                        let msg = msghdr(msg_name: address,
                                                 msg_namelen: addressLen,
                                                 msg_iov: iovecs.baseAddress,
                                                 msg_iovlen: 1,
                                                 msg_control: controlMessageBytePointer.baseAddress,
                                                 msg_controllen: .init(controlMessageBytePointer.count),
                                                 msg_flags: 0)
                        msgs[0] = MMsgHdr(msg_hdr: msg, msg_len: 0)

                        // Uring has no analogue to sendmmsg(), so we can send only single message at once
                        var ptr = UnsafeRawBufferPointer(msgs).baseAddress!
                        ptr += MemoryLayout<MMsgHdr>.offset(of: \MMsgHdr.msg_hdr)!
                        try asyncWriteOperation(ptr.bindMemory(to: msghdr.self, capacity: 1))
                    }
                }
            }
        }
    }

    func didAsyncWrite(written: Int32) throws -> (Bool, Bool) {
        self.buffer!.withUnsafePointers { _, storageRefs in
            storageRefs[0].release()
        }
        self.bufferPool.put(self.buffer!)
        self.buffer = nil

        self.msgBufferPool.put(self.msgBuffer!)
        self.msgBuffer = nil

        if (written >= 0) {
            let (writeFiller, result) = self.state.didScalarWrite(written: Int(written))

            var writabilityChange = false
            if self.state.bytes < waterMark.low {
                if self.channelWritabilityFlag.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged {
                    writabilityChange = true
                }
            }

            self.fulfillPromise(writeFiller)

            let flushAgain = (result == .writtenPartially)
            return (writabilityChange, flushAgain)
        }
        else {
            let errnoCode = -written
            let result = try self.handleError(IOError(errnoCode: errnoCode, reason:"async write failed"))
            return (false, (result == .writtenPartially))
        }
    }

    /// Triggers the appropriate write operation. This is a fancy way of saying trigger either `sendto` or `sendmmsg`.
    /// On platforms that do not support a gathering write operation,
    ///
    /// - parameters:
    ///     - scalarWriteOperation: An operation that writes a single, contiguous array of bytes (usually `sendmsg`).
    ///     - vectorWriteOperation: An operation that writes multiple contiguous arrays of bytes (usually `sendmmsg`).
    /// - returns: The `WriteResult` and whether the `Channel` is now writable.
    func triggerAppropriateWriteOperations(scalarWriteOperation: (UnsafeRawBufferPointer, UnsafePointer<sockaddr>?, socklen_t, AddressedEnvelope<ByteBuffer>.Metadata?) throws -> IOResult<Int>,
                                           vectorWriteOperation: (UnsafeMutableBufferPointer<MMsgHdr>) throws -> IOResult<Int>) throws -> OverallWriteResult {
        return try self.triggerWriteOperations { writeMechanism in
            switch writeMechanism {
            case .scalarBufferWrite:
                return try triggerScalarBufferWrite(scalarWriteOperation: { try scalarWriteOperation($0, $1, $2, $3) })
            case .vectorBufferWrite:
                do {
                    return try triggerVectorBufferWrite(vectorWriteOperation: { try vectorWriteOperation($0) })
                } catch {
                    // If the error we just hit is recoverable, we fall back to single write mode to
                    // isolate exactly which write triggered the problem.
                    guard error.isRecoverable else {
                        throw error
                    }

                    return try triggerScalarBufferWrite(scalarWriteOperation: { try scalarWriteOperation($0, $1, $2, $3) })
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
        let (promise, result) = self.state.didWrite(data, messages: messages)

        if self.state.bytes < waterMark.low {
            channelWritabilityFlag.store(true, ordering: .relaxed)
        }

        self.fulfillPromise(promise)
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
            let (promise, result) = self.state.recoverableError(ChannelError.writeMessageTooLarge)
            self.fulfillPromise(promise)
            return result
        case let e as IOError where e.errnoCode == EHOSTUNREACH:
            let (promise, result) = self.state.recoverableError(ChannelError.writeHostUnreachable)
            self.fulfillPromise(promise)
            return result
        default:
            throw error
        }
    }

    /// Trigger a write of a single object where an object can either be a contiguous array of bytes or a region of a file.
    ///
    /// - parameters:
    ///     - scalarWriteOperation: An operation that writes a single, contiguous array of bytes (usually `sendto`).
    private func triggerScalarBufferWrite(scalarWriteOperation: (UnsafeRawBufferPointer, UnsafePointer<sockaddr>?, socklen_t, AddressedEnvelope<ByteBuffer>.Metadata?) throws -> IOResult<Int>) rethrows -> OneWriteOperationResult {
        assert(self.state.isFlushPending && self.isOpen && !self.state.isEmpty,
               "illegal state for scalar datagram write operation: flushPending: \(self.state.isFlushPending), isOpen: \(self.isOpen), empty: \(self.state.isEmpty)")
        let pending = self.state.nextWrite!
        do {
            let writeResult: IOResult<Int>

            if let address = pending.address {
                assert(self.state.remoteAddress == nil, "Pending write with address on connected socket.")
                writeResult = try address.withSockAddr { (addrPtr, addrSize) in
                    try pending.data.withUnsafeReadableBytes {
                        try scalarWriteOperation($0, addrPtr, socklen_t(addrSize), pending.metadata)
                    }
                }
            } else {
                /// From man page of `sendmsg(2)`:
                ///
                /// > The `msg_name` field is used on an unconnected socket to specify
                /// > the target address for a datagram.  It points to a buffer
                /// > containing the address; the `msg_namelen` field should be set to
                /// > the size of the address.  For a connected socket, these fields
                /// > should be specified as `NULL` and 0, respectively.
                assert(self.state.remoteAddress != nil, "Pending write without address on unconnected socket.")
                writeResult = try pending.data.withUnsafeReadableBytes {
                    try scalarWriteOperation($0, nil, 0, pending.metadata)
                }
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

        let msgBuffer = self.msgBufferPool.get()
        defer { self.msgBufferPool.put(msgBuffer) }

        return try msgBuffer.withUnsafePointers { msgs, addresses, controlMessageStorage in
            return self.didWrite(try doPendingDatagramWriteVectorOperation(pending: self.state,
                                                                           bufferPool: self.bufferPool,
                                                                           msgs: msgs,
                                                                           addresses: addresses,
                                                                           controlMessageStorage: controlMessageStorage,
                                                                           { try vectorWriteOperation($0) }),
                                 messages: msgs)
        }
    }

    private func fulfillPromise(_ promise: PendingDatagramWritesState.DatagramWritePromiseFiller?) {
        if let promise = promise, let error = promise.1 {
            promise.0.fail(error)
        } else if let promise = promise {
            promise.0.succeed(())
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
