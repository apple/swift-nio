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

/// An object that manages issuing vector reads for datagram channels.
///
/// Datagram channels have slightly complex read semantics, as high-throughput datagram
/// channels would like to use gathering reads to minimise syscall overhead. This requires
/// managing memory carefully, as well as includes some complex logic that needs to be
/// carefully arranged. For this reason, we store this logic on this separate struct
/// that makes understanding the code a lot simpler.
struct DatagramVectorReadManager {
    enum ReadResult {
        case some(reads: [AddressedEnvelope<ByteBuffer>], totalSize: Int)
        case none
    }

    /// The number of messages that will be read in each syscall.
    var messageCount: Int {
        get {
            return self.messageVector.count
        }
        set {
            precondition(newValue >= 0)
            self.messageVector.deinitializeAndDeallocate()
            self.ioVector.deinitializeAndDeallocate()
            self.sockaddrVector.deinitializeAndDeallocate()
            self.controlMessageStorage.deallocate()

            self.messageVector = .allocateAndInitialize(repeating: MMsgHdr(msg_hdr: msghdr(), msg_len: 0), count: newValue)
            self.ioVector = .allocateAndInitialize(repeating: IOVector(), count: newValue)
            self.sockaddrVector = .allocateAndInitialize(repeating: sockaddr_storage(), count: newValue)
            self.controlMessageStorage = UnsafeControlMessageStorage.allocate(msghdrCount: newValue)
        }
    }

    /// The vector of MMsgHdrs that are used for the gathering reads.
    private var messageVector: UnsafeMutableBufferPointer<MMsgHdr>

    /// The vector of iovec structures needed by msghdr structures.
    private var ioVector: UnsafeMutableBufferPointer<IOVector>

    /// The vector of sockaddr structures used for saving addresses.
    private var sockaddrVector: UnsafeMutableBufferPointer<sockaddr_storage>

    /// Storage to use for `cmsghdr` data when reading messages.
    private var controlMessageStorage: UnsafeControlMessageStorage

    // FIXME(cory): Right now there's no good API for specifying the various parameters of multi-read, especially how
    // it should interact with RecvByteBufferAllocator. For now I'm punting on this to see if I can get it working,
    // but we should design it back.
    fileprivate init(messageVector: UnsafeMutableBufferPointer<MMsgHdr>,
                     ioVector: UnsafeMutableBufferPointer<IOVector>,
                     sockaddrVector: UnsafeMutableBufferPointer<sockaddr_storage>,
                     controlMessageStorage: UnsafeControlMessageStorage) {
        self.messageVector = messageVector
        self.ioVector = ioVector
        self.sockaddrVector = sockaddrVector
        self.controlMessageStorage = controlMessageStorage
    }

    /// Performs a socket vector read.
    ///
    /// This method takes a single byte buffer and segments it into `messageCount` pieces. It then
    /// prepares and issues a single recvmmsg syscall, instructing the kernel to write multiple datagrams
    /// into that single buffer. Assuming that some datagrams have been successfully read, it then slices
    /// that large buffer up into multiple buffers, prepares a series of AddressedEnvelope structures
    /// appropriately, and then returns that result to the caller.
    ///
    /// - warning: If buffer is not at least 1.5kB times `messageCount`, this will almost certainly lead to
    ///     dropped data. Caution should be taken to ensure that the RecvByteBufferAllocator is allocating an
    ///     appropriate amount of memory.
    /// - warning: Unlike most of the rest of SwiftNIO, the read managers use withVeryUnsafeMutableBytes to
    ///     obtain a pointer to the entire buffer storage. This is because they assume they own the entire
    ///     buffer.
    ///
    /// - parameters:
    ///     - socket: The underlying socket from which to read.
    ///     - buffer: The single large buffer into which reads will be written.
    ///     - reportExplicitCongestionNotifications: Should explicit congestion notifications be reported up using metadata.
    func readFromSocket(socket: Socket,
                        buffer: inout ByteBuffer,
                        reportExplicitCongestionNotifications: Bool) throws -> ReadResult {
        assert(buffer.readerIndex == 0, "Buffer was not cleared between calls to readFromSocket!")

        let messageSize = buffer.capacity / self.messageCount

        let result = try buffer.withVeryUnsafeMutableBytes { bufferPointer -> IOResult<Int> in
            for i in 0..<self.messageCount {
                // TODO(cory): almost all of this except for the iovec could be done at allocation time. Maybe we should?

                // First we set up the iovec and save it off.
                self.ioVector[i] = IOVector(iov_base: bufferPointer.baseAddress! + (i * messageSize), iov_len: numericCast(messageSize))
                
                let controlBytes: UnsafeMutableRawBufferPointer
                if reportExplicitCongestionNotifications {
                    // This will be used in buildMessages below but should not be used beyond return of this function.
                    controlBytes = self.controlMessageStorage[i]
                } else {
                    controlBytes = UnsafeMutableRawBufferPointer(start: nil, count: 0)
                }

                // Next we set up the msghdr structure. This points into the other vectors.
                let msgHdr = msghdr(msg_name: self.sockaddrVector.baseAddress! + i ,
                                    msg_namelen: socklen_t(MemoryLayout<sockaddr_storage>.size),
                                    msg_iov: self.ioVector.baseAddress! + i,
                                    msg_iovlen: 1,  // This is weird, but each message gets only one array. Duh.
                                    msg_control: controlBytes.baseAddress,
                                    msg_controllen: .init(controlBytes.count),
                                    msg_flags: 0)
                self.messageVector[i] = MMsgHdr(msg_hdr: msgHdr, msg_len: 0)

                // Note that we don't set up the sockaddr vector: that's because it needs no initialization,
                // it's written into by the kernel.
            }

            // We've set up our pointers, it's time to get going. We now issue the call.
            return try socket.recvmmsg(msgs: self.messageVector)
        }

        switch result {
        case .wouldBlock(let messagesProcessed):
            assert(messagesProcessed == 0)
            return .none
        case .processed(let messagesProcessed):
            buffer.moveWriterIndex(to: messageSize * messagesProcessed)
            return self.buildMessages(messageCount: messagesProcessed,
                                      sliceSize: messageSize,
                                      buffer: &buffer,
                                      reportExplicitCongestionNotifications: reportExplicitCongestionNotifications)
        }
    }

    /// Destroys this vector read manager, rendering it impossible to re-use. Use of the vector read manager after this is called is not possible.
    mutating func deallocate() {
        self.messageVector.deinitializeAndDeallocate()
        self.ioVector.deinitializeAndDeallocate()
        self.sockaddrVector.deinitializeAndDeallocate()
        self.controlMessageStorage.deallocate()
    }

    private func buildMessages(messageCount: Int,
                               sliceSize: Int,
                               buffer: inout ByteBuffer,
                               reportExplicitCongestionNotifications: Bool) -> ReadResult {
        var sliceOffset = buffer.readerIndex
        var totalReadSize = 0

        var results = Array<AddressedEnvelope<ByteBuffer>>()
        results.reserveCapacity(messageCount)

        for i in 0..<messageCount {
            // We force-unwrap here because we should not have been able to write past the end of the buffer.
            var slice = buffer.getSlice(at: sliceOffset, length: sliceSize)!
            sliceOffset += sliceSize

            // Now we move the writer index backwards to where the end of the read was. Note that 0 is not an
            // error for datagrams, zero-length datagrams are permitted.
            let readBytes = Int(self.messageVector[i].msg_len)
            slice.moveWriterIndex(to: readBytes)
            totalReadSize += readBytes

            // Next we extract the remote peer address.
            precondition(self.messageVector[i].msg_hdr.msg_namelen != 0, "Unexpected zero length peer name")
            let address: SocketAddress = self.sockaddrVector[i].convert()
            
            // Extract congestion information if requested.
            let metadata: AddressedEnvelope<ByteBuffer>.Metadata?
            if reportExplicitCongestionNotifications {
                let controlMessagesReceived =
                    UnsafeControlMessageCollection(messageHeader: self.messageVector[i].msg_hdr)
                metadata = .init(from: controlMessagesReceived)
            } else {
                metadata = nil
            }

            // Now we've finally constructed a useful AddressedEnvelope. We can store it in the results array temporarily.
            results.append(AddressedEnvelope(remoteAddress: address, data: slice, metadata: metadata))
        }

        // Ok, all built. Now we can return these values to the caller.
        return .some(reads: results, totalSize: totalReadSize)
    }
}

extension DatagramVectorReadManager {
    /// Allocates and initializes a new DatagramVectorReadManager.
    ///
    /// - parameters:
    ///     - messageCount: The number of vector reads to support initially.
    static func allocate(messageCount: Int) -> DatagramVectorReadManager {
        let messageVector = UnsafeMutableBufferPointer.allocateAndInitialize(repeating: MMsgHdr(msg_hdr: msghdr(), msg_len: 0), count: messageCount)
        let ioVector = UnsafeMutableBufferPointer.allocateAndInitialize(repeating: IOVector(), count: messageCount)
        let sockaddrVector = UnsafeMutableBufferPointer.allocateAndInitialize(repeating: sockaddr_storage(), count: messageCount)
        let controlMessageStorage = UnsafeControlMessageStorage.allocate(msghdrCount: messageCount)

        return DatagramVectorReadManager(messageVector: messageVector,
                                         ioVector: ioVector,
                                         sockaddrVector: sockaddrVector,
                                         controlMessageStorage: controlMessageStorage)
    }
}


extension Optional where Wrapped == DatagramVectorReadManager {
    /// Updates the message count of the wrapped `DatagramVectorReadManager` to the new value.
    ///
    /// If the new value is 0 or negative, will destroy the contained vector read manager and set
    /// self to `nil`.
    mutating func updateMessageCount(_ newCount: Int) {
        if newCount > 0 {
            if self != nil {
                self!.messageCount = newCount
            } else {
                self = DatagramVectorReadManager.allocate(messageCount: newCount)
            }
        } else {
            if self != nil {
                self!.deallocate()
            }
            self = nil
        }
    }
}


extension UnsafeMutableBufferPointer {
    /// Safely creates an UnsafeMutableBufferPointer that can be used by the rest of the code. It ensures that
    /// the memory has been bound, allocated, and initialized, such that other Swift code can use it safely without
    /// worrying.
    fileprivate static func allocateAndInitialize(repeating element: Element, count: Int) -> UnsafeMutableBufferPointer<Element> {
        let newPointer = UnsafeMutableBufferPointer.allocate(capacity: count)
        newPointer.initialize(repeating: element)
        return newPointer
    }

    /// This safely destroys an UnsafeMutableBufferPointer by deinitializing and deallocating
    /// the underlying memory. This ensures that if the pointer contains non-trivial Swift
    /// types that no accidental memory leaks will occur, as can happen if UnsafeMutableBufferPointer.deallocate()
    /// is used.
    fileprivate func deinitializeAndDeallocate() {
        guard let basePointer = self.baseAddress else {
            // If there's no base address, who cares?
            return
        }

        // This is the safe way to do things: the moment that deinitialize
        // is called, we deallocate.
        let rawPointer = basePointer.deinitialize(count: self.count)
        rawPointer.deallocate()
    }
}
