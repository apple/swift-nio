//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if SWIFTNIO_USE_IO_URING && os(Linux)

import CNIOLinux
import NIOCore

@usableFromInline
enum CQEEventType: UInt8 {
    case poll = 1, // start with 1 to not get zero bit patterns for stdin
    pollModify,
    pollDelete,
    write
}

internal enum URingError: Error {
    case loadFailure
    case uringSetupFailure
    case uringWaitCqeFailure
}

internal extension TimeAmount {
    func kernelTimespec() -> __kernel_timespec {
        var ts = __kernel_timespec()
        ts.tv_sec = self.nanoseconds / 1_000_000_000
        ts.tv_nsec = self.nanoseconds % 1_000_000_000
        return ts
    }
}

// These are the events returned up to the selector
internal struct URingEvent {
    enum EventType {
        case _none
        case poll(UInt32, Bool) // poll mask, poll cancelled
        case write(Int32)
    }

    var fd: CInt
    var registrationID: UInt16 // we just have the truncated lower 16 bits of the registrationID
    var type: EventType

    init() {
        fd = 0
        registrationID = 0
        type = ._none
    }

    init(_ fd: CInt, _ registrationID: UInt16, _ type: EventType) {
        self.fd = fd
        self.registrationID = registrationID
        self.type = type
    }
}

// This is the key we use for merging events in our internal hashtable
private struct EventKey: Hashable {
    let fileDescriptor: CInt
    let registrationID: UInt16 // we just have the truncated lower 16 bits of the registrationID

    init(_ fileDescriptor: CInt, _ registrationID: UInt16) {
        self.fileDescriptor = fileDescriptor
        self.registrationID = registrationID
    }
}

private func _debugPrint(_ s: @autoclosure () -> String) {
    #if SWIFTNIO_IO_URING_DEBUG
    print("L \(s())")
    #endif
}

final internal class URing {

    // a user_data 64-bit payload which is set in the SQE and returned in the CQE.
    // We're using 56 of those 64 bits, 32 for the file descriptor, 16 for a "registration ID" and 8
    // for the type of event issued (poll/modify/delete).
    private struct UserData {
        let fileDescriptor: CInt
        let registrationID: UInt16 // SelectorRegistrationID truncated, only have room for bottom 16 bits (could be expanded to 24 if required)
        let eventType: CQEEventType
        let padding: Int8 // reserved for future use

        @inlinable init(_ fileDescriptor: CInt, _ registrationID: SelectorRegistrationID, _ eventType: CQEEventType) {
            assert(MemoryLayout<UInt64>.size == MemoryLayout<UserData>.size)
            self.fileDescriptor = fileDescriptor
            self.registrationID = UInt16(truncatingIfNeeded: registrationID.rawValue)
            self.eventType = eventType
            self.padding = 0
        }

        @inlinable init(rawValue: UInt64) {
            let unpacked = IntegerBitPacking.unpackUInt32UInt16UInt8(rawValue >> 1)
            self = .init(CInt(unpacked.0),
                        SelectorRegistrationID(rawValue: UInt32(unpacked.1)),
                        CQEEventType(rawValue:unpacked.2)!)
        }

        @inlinable func asUInt64() -> UInt64 {
            let rawValue = IntegerBitPacking.packUInt32UInt16UInt8(
                UInt32(truncatingIfNeeded: self.fileDescriptor),
                self.registrationID,
                self.eventType.rawValue)
            return ((rawValue << 1) + 1)
        }
    }

    private class SendFileRequest {
        let fileDescriptor: CInt
        let src: CInt
        let registrationID: UInt16
        let bytes: UInt32
        let pipe: Pipe
        var opsDone: Int

        init(_ fileDescriptor: CInt, _ src: CInt, _ registrationID: SelectorRegistrationID, _ bytes: UInt32, _ pipe: Pipe) {
            self.fileDescriptor = fileDescriptor
            self.src = src
            self.registrationID = UInt16(truncatingIfNeeded: registrationID.rawValue)
            self.pipe = pipe
            self.bytes = bytes
            self.opsDone = 0
        }

        deinit {
            pipe.release()
        }

        func opDone() -> Bool {
            opsDone += 1
            assert(opsDone <= 2)
            return (opsDone == 2)
        }
    }

    private struct SendFileUserData {
        let request: SendFileRequest
        var offs: Int64
        var bytesProcessed: UInt32

        init(_ request: SendFileRequest, _ offs: Int64) {
            self.request = request
            self.offs = offs
            self.bytesProcessed = 0
        }
    }

    internal static let POLLIN: CUnsignedInt = numericCast(CNIOLinux.POLLIN)
    internal static let POLLOUT: CUnsignedInt = numericCast(CNIOLinux.POLLOUT)
    internal static let POLLERR: CUnsignedInt = numericCast(CNIOLinux.POLLERR)
    internal static let POLLRDHUP: CUnsignedInt = CNIOLinux_POLLRDHUP() // numericCast(CNIOLinux.POLLRDHUP) 
    internal static let POLLHUP: CUnsignedInt = numericCast(CNIOLinux.POLLHUP)

    private var ring = io_uring()
    private let ringEntries: CUnsignedInt = 8192
    private let cqeMaxCount: UInt32 = 8192 // this is the max chunk of CQE we take.

    private var cqes: UnsafeMutablePointer<UnsafeMutablePointer<io_uring_cqe>?>
    private var pollIdx = [EventKey : Int]()

    var fd: CInt {
        return ring.ring_fd
    }

    static var io_uring_use_multishot_poll: Bool {
        #if SWIFTNIO_IO_URING_MULTISHOT
        return true
        #else
        return false
        #endif
    }

    init() {
        cqes = UnsafeMutablePointer<UnsafeMutablePointer<io_uring_cqe>?>.allocate(capacity: Int(cqeMaxCount))
        var emptyCqe = io_uring_cqe()
        cqes.initialize(repeating: &emptyCqe, count: Int(cqeMaxCount))
    }

    deinit {
        cqes.deallocate()
    }

    internal func queue_init() throws -> () {
        if (io_uring_queue_init(ringEntries, &ring, 0 ) != 0) {
            throw URingError.uringSetupFailure
        }
        _debugPrint("URing.queue_init: \(self.ring.ring_fd)")
    }

    internal func queue_exit() {
        _debugPrint("URing.queue_exit: \(self.ring.ring_fd)")
        io_uring_queue_exit(&ring)
    }

    // Adopting some retry code from queue.c from liburing with slight
    // modifications - we never want to have to handle retries of
    // SQE allocation in all places it could possibly occur.
    // If the SQ ring is full, we may need to submit IO first
    private func withSQE<R>(_ body: (UnsafeMutablePointer<io_uring_sqe>?) throws -> R) rethrows -> R
    {
        // io_uring_submit can fail here due to backpressure from kernel for not reaping CQE:s.
        //
        // I think we should consider handling that as a fatalError, as fundamentally the ring size is too small
        // compared to the amount of events the user tries to push through in a single eventloop tick.
        //
        // This is mostly a problem for synthetic tests that e.g. do a huge amount of registration modifications.
        //
        // This is a slight design issue with SwiftNIO in general that should be discussed.
        //
        while true {
            if let sqe = io_uring_get_sqe(&ring) {
               return try body(sqe)
            }
            self.flush()
        }
    }

    // Ok, this was a bummer - turns out that flushing multiple SQE:s
    // can fail midflight and this will actually happen for real when e.g. a socket
    // has gone down and we are re-registering polls this means we will silently lose any
    // entries after the failed fd. Ouch. Proper approach is to use io_uring_sq_ready() in a loop.
    // See: https://github.com/axboe/liburing/issues/309
    func flush() {         // When using SQPOLL this is basically a NOP
        var submissionCount = 0
        var waitingSubmissions = io_uring_sq_ready(&ring)

        loop: while (waitingSubmissions > 0)
        {
            let retval = io_uring_submit(&ring)
            submissionCount += 1

            switch retval {
            // We can get -EAGAIN if the CQE queue is full and we get back pressure from
            // the kernel to start processing CQE:s. If we break here with unsubmitted
            // SQE:s, they will stay pending on the user-level side and be flushed
            // to the kernel after we had the opportunity to reap more CQE:s
            // In practice it will be at the end of whenReady the next
            // time around. Given the async nature, this is fine, we will not
            // lose any submissions. We could possibly still get stuck
            // trying to get new SQE if the actual SQE queue is full, but
            // that would be due to user error in usage IMHO and we should fatalError there.
            case -EAGAIN, -EBUSY:
                _debugPrint("URing.flush: io_uring_submit -EBUSY/-EAGAIN waitingSubmissions[\(waitingSubmissions)] submissionCount[\(submissionCount)]. Breaking out and resubmitting later (whenReady() end).")
                break loop
            // -ENOMEM when there is not enough memory to do internal allocations on the kernel side.
            // Right nog we just loop with a sleep trying to buy time, but could also possibly fatalError here.
            // See: https://github.com/axboe/liburing/issues/309
            case -ENOMEM:
                usleep(10_000) // let's not busy loop to give the kernel some time to recover if possible
                _debugPrint("URing.flush: io_uring_submit -ENOMEM \(submissionCount)")
            case 0:
                _debugPrint("URing.flush: io_uring_submit submitted 0, so far needed submissionCount[\(submissionCount)] waitingSubmissions[\(waitingSubmissions)] submitted [\(retval)] SQE:s this iteration")
                break
            case 1...:
                _debugPrint("URing.flush: io_uring_submit needed [\(submissionCount)] submission(s), submitted [\(retval)] SQE:s out of [\(waitingSubmissions)] possible")
                break
            default: // other errors
                fatalError("Unexpected error [\(retval)] from io_uring_submit ")
            }

            waitingSubmissions = io_uring_sq_ready(&ring)
        }
    }

    // we stuff event type into the upper byte, the next 3 bytes gives us the sequence number (16M before wrap) and final 4 bytes are fd.
    func prep_poll_add(fileDescriptor: CInt, pollMask: UInt32, registrationID: SelectorRegistrationID, multishot: Bool = true) -> () {
        let userData = UserData(fileDescriptor, registrationID, CQEEventType.poll).asUInt64()

        _debugPrint("URing.prep_poll_add: " +
            "fd[\(fileDescriptor)] " +
            "pollMask[0x\(String(pollMask, radix: 16))] " +
            "userData[0x\(String(userData>>1, radix: 16))] " +
            "multishot[\(multishot)]")

        self.withSQE { sqe in
            io_uring_prep_poll_add(sqe, fileDescriptor, pollMask)
            io_uring_sqe_set_data64(sqe, userData) // must be done after prep_poll_add, otherwise zeroed out.

            if multishot {
                sqe!.pointee.len |= IORING_POLL_ADD_MULTI; // turn on multishots, set through environment variable
            }
        }
    }

    func prep_poll_remove(fileDescriptor: CInt, pollMask: UInt32, registrationID: SelectorRegistrationID, link: Bool = false) -> () {
        let pollUserData = UserData(fileDescriptor, registrationID, CQEEventType.poll).asUInt64()
        let reqUserData = UserData(fileDescriptor,  registrationID, CQEEventType.pollDelete).asUInt64()

        _debugPrint("URing.prep_poll_remove: " +
            "fd[\(fileDescriptor)] " +
            "pollMask[0x\(String(pollMask, radix: 16))] " +
            "pollUserData[0x\(String(pollUserData>>1, radix: 16))] " +
            "reqUserData[0x\(String(reqUserData>>1, radix: 16))] " +
            "link[\(link)]")

        self.withSQE { sqe in
            io_uring_prep_poll_remove(sqe, pollUserData)
            io_uring_sqe_set_data64(sqe, reqUserData) // must be done after prep_poll_add, otherwise zeroed out.

            if link {
                CNIOLinux_io_uring_set_link_flag(sqe)
            }
        }
    }

    // the update/multishot polls are
    func poll_update(fileDescriptor: CInt, newPollMask: UInt32, oldPollMask: UInt32, registrationID: SelectorRegistrationID, multishot: Bool = true) {
        
        let oldUserData = UserData(fileDescriptor, registrationID, CQEEventType.poll).asUInt64()
        let newUserData = UserData(fileDescriptor, registrationID, CQEEventType.pollModify).asUInt64()

        _debugPrint("URing.poll_update: " +
            "fd[\(fileDescriptor)] " +
            "newPollMask[\(newPollMask)] " +
            "oldUserData[0x\(String(oldUserData>>1, radix: 16)))] " +
            "newUserData[0x\(String(newUserData>>1, radix: 16))]")

        self.withSQE { sqe in
            // "Documentation" for multishot polls and updates here:
            // https://git.kernel.dk/cgit/linux-block/commit/?h=poll-multiple&id=33021a19e324fb747c2038416753e63fd7cd9266
            var flags = IORING_POLL_UPDATE_EVENTS | IORING_POLL_UPDATE_USER_DATA
            if multishot {
                flags |= IORING_POLL_ADD_MULTI       // ask for multiple updates
            }

            CNIOLinux.io_uring_prep_poll_update(sqe, oldUserData, newUserData, newPollMask, flags)
            //CNIOLinux.io_uring_sqe_set_data64(sqe, newUserData) ??
        }
    }

    func prep_write(fileDescriptor: CInt, pointer: UnsafeRawBufferPointer, registrationID: SelectorRegistrationID) {
        let userData = UserData(fileDescriptor, registrationID, CQEEventType.write).asUInt64()

        _debugPrint("URing.prep_write: " +
            "fd[\(fileDescriptor)] " +
            "pointer[\(pointer)] " +
            "userData=[0x\(String(userData>>1, radix: 16))]")

        assert(pointer.count > 0)

        self.withSQE { sqe in
            io_uring_prep_write(sqe, fileDescriptor, pointer.baseAddress, UInt32(pointer.count), 0)
            io_uring_sqe_set_data64(sqe, userData)
        }
    }

    func prep_writev(fileDescriptor: CInt, iovecs: UnsafeBufferPointer<IOVector>, registrationID: SelectorRegistrationID) {
        let userData = UserData(fileDescriptor, registrationID, CQEEventType.write).asUInt64()

        func bytesToWrite(_ iovecs: UnsafeBufferPointer<IOVector>) -> Int {
            var bytes = 0
            for idx in 0..<iovecs.count {
                bytes += iovecs[idx].iov_len
            }
            return bytes
        }

        _debugPrint("URing.prep_writev: " +
            "fd[\(fileDescriptor)] " +
            "iovecs[\(iovecs)] " +
            "bytesToWrite[\(bytesToWrite(iovecs))] " +
            "userData=[0x\(String(userData>>1, radix: 16))]")

        assert(bytesToWrite(iovecs) > 0)

        self.withSQE { sqe in
            io_uring_prep_writev(sqe, fileDescriptor, iovecs.baseAddress, UInt32(iovecs.count), 0)
            io_uring_sqe_set_data64(sqe, userData)
        }
    }

    func prep_splice(_ fdIn: CInt, _ offsIn: Int64, _ fdOut: CInt, _ offsOut: Int64, _ count: UInt32, _ flags: UInt32) {
        _debugPrint("URing.prep_splice: " +
            "in[fd=\(fdIn), offs=\(offsIn)] " +
            "out[fd=\(fdOut), offs=\(offsOut)] " +
            "count=\(count)")

        //let _offs = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        //_offs.pointee = offsIn
        self.withSQE { sqe in
            io_uring_prep_splice(sqe, fdIn, offsIn, fdOut, offsOut, count, flags)
        }
    }

    func prep_sendfile(_ fileDescriptor: CInt, _ src: CInt, _ offs: Int64, _ count: UInt32, _ registrationID: SelectorRegistrationID, _ pipe: Pipe) {

        _debugPrint("URing.prep_sendfile: fileDescriptor=\(fileDescriptor) src[\(src)] offs[\(offs)] count[\(count)]")
        let request = SendFileRequest(fileDescriptor, src, registrationID, count, pipe)

        self.withSQE { sqe in
            let userData = UnsafeMutablePointer<SendFileUserData>.allocate(capacity: 1)
            userData.initialize(to: SendFileUserData(request, offs))
            io_uring_prep_splice(sqe, src, offs, pipe.write, -1, count, 0)
            io_uring_sqe_set_data(sqe, userData)
        }

        self.withSQE { sqe in
            let userData = UnsafeMutablePointer<SendFileUserData>.allocate(capacity: 1)
            userData.initialize(to: SendFileUserData(request, -1))
            io_uring_prep_splice(sqe, pipe.read, -1, fileDescriptor, -1, count, 0)
            io_uring_sqe_set_data(sqe, userData)
        }
    }

    func prep_sendmsg(_ fileDescriptor: CInt, _ msghdr: UnsafePointer<msghdr>, _ registrationID: SelectorRegistrationID) {
        let userData = UserData(fileDescriptor, registrationID, CQEEventType.write).asUInt64()

        _debugPrint("URing.prep_sendmsg: " +
            "fd[\(fileDescriptor)] msghdr[\(msghdr)] " +
            "msg_iovlen[\(msghdr.pointee.msg_iovlen)] iovlen[\(msghdr.pointee.msg_iov[0].iov_len)] " +
            "userData[0x\(String(userData>>1, radix: 16))]")

        self.withSQE { sqe in
            io_uring_prep_sendmsg(sqe, fileDescriptor, msghdr, 0)
            io_uring_sqe_set_data64(sqe, userData)
        }
    }

    private func _processPollCQE(_ events: UnsafeMutablePointer<URingEvent>, _ count: inout Int, _ eventKey: EventKey, _ pollMask: UInt32, _ pollCancelled: Bool) {
        if let idx = pollIdx[eventKey] {
            switch events[idx].type {
                case .poll(let current, let pollCancelled):
                    let pollMask = (current | pollMask)
                    events[idx].type = .poll(pollMask, pollCancelled)
                default:
                    assert(false)
            }
        }
        else {
            let idx = count
            count += 1
            events[idx] = URingEvent(eventKey.fileDescriptor, eventKey.registrationID, .poll(pollMask, pollCancelled))
            pollIdx[eventKey] = idx
        }
    }

    private func _processCQE(events: UnsafeMutablePointer<URingEvent>, count: inout Int, pendingSQEs: inout Int, multishot: Bool, cqe: UnsafeMutablePointer<io_uring_cqe>) {
        let userData64 : UInt64 = io_uring_cqe_get_data64(cqe)
        let result = cqe.pointee.res
        if (userData64 & 1) != 0 {
            let userData = UserData(rawValue: userData64)

            switch userData.eventType {
            case .poll:
                _debugPrint("URing: CQE/poll, fd[\(userData.fileDescriptor)] userData[0x\(String(userData64, radix: 16))] result[\(result)]")
                switch result {
                case -ECANCELED:
                    var pollError: UInt32 = 0
                    assert(userData.fileDescriptor >= 0, "fd must be zero or greater")
                    var pollCancelled = false
                    if multishot { // -ECANCELED for streaming polls, should signal error
                        pollError = URing.POLLERR | URing.POLLHUP
                    } else {       // this just signals that Selector just should resubmit a new fresh poll
                        pollCancelled = true
                    }
                    let eventKey = EventKey(userData.fileDescriptor, userData.registrationID)
                    _processPollCQE(events, &count, eventKey, pollError, pollCancelled)
                // We can validly receive an EBADF as a close() can race vis-a-vis pending SQE:s
                // with polls / pollModifications - in that case, we should just discard the result.
                // This is similar to the assert in BaseSocketChannel and is due to the lack
                // of implicit synchronization with regard to registration changes for io_uring
                // - we simply can't know when the kernel will process our SQE without
                // heavy-handed synchronization which would dump performance.
                // Discussion here:
                // https://github.com/apple/swift-nio/pull/1804#discussion_r621304055
                // including clarifications from @isilence (one of the io_uring developers)
                case -EBADF:
                    _debugPrint("Failed poll with -EBADF for cqe[\(cqe)]")
                case ..<0: // other errors
                    fatalError("Failed poll with unexpected error (\(result) for cqe[\(cqe)]")
                case 0: // successfull chained add for singleshots, not an event
                    break
                default: // positive success
                    assert(userData.fileDescriptor >= 0, "fd must be zero or greater")
                    let eventKey = EventKey(userData.fileDescriptor, userData.registrationID)
                    _processPollCQE(events, &count, eventKey, UInt32(result), false)
                }

            case .pollModify: // we only get this for multishot modifications
                _debugPrint("URing: CQE/pollModify, fd[\(userData.fileDescriptor)] userData=[0x\(String(userData64, radix: 16))] result[\(result)]")
                switch result {
                case -ECANCELED: // -ECANCELED for streaming polls, should signal error
                    assert(userData.fileDescriptor >= 0, "fd must be zero or greater")
                    let eventKey = EventKey(userData.fileDescriptor, userData.registrationID)
                    _processPollCQE(events, &count, eventKey, URing.POLLERR, false)
                case -EALREADY:
                    _debugPrint("Failed pollModify with -EALREADY for cqe[\(cqe)]")
                case -ENOENT:
                    _debugPrint("Failed pollModify with -ENOENT for cqe[\(cqe)]")
                // See the description for EBADF handling above in the poll case for rationale of allowing EBADF.
                case -EBADF:
                    _debugPrint("Failed pollModify with -EBADF for cqe[\(cqe)]")
                case ..<0: // other errors
                    fatalError("Failed pollModify with unexpected error (\(result) for cqe[\(cqe)]")
                case 0: // successfull chained add, not an event
                    break
                default: // positive success
                    fatalError("pollModify returned > 0")
                }

            case .write:
                _debugPrint("URing: CQE/write, fd[\(userData.fileDescriptor)] result[\(result)]")
                let idx = count
                count += 1
                events[idx] = URingEvent(userData.fileDescriptor, userData.registrationID, .write(result))

            default:
                break
            }
        }
        else {
            let userData = UnsafeMutablePointer<SendFileUserData>(bitPattern: Int(userData64))!
            let request = userData.pointee.request
            if result > 0 {
                userData.pointee.bytesProcessed += UInt32(result)
                assert(userData.pointee.bytesProcessed <= request.bytes)
                if userData.pointee.bytesProcessed >= request.bytes {
                    request.opsDone += 1
                    let opsDone = request.opsDone
                    _debugPrint("URing: CQE/sendFile, result[\(result)] offs[\(userData.pointee.offs)] opsDone[\(opsDone)]")
                    if opsDone == 2 {
                        let idx = count
                        count += 1
                        events[idx] = URingEvent(request.fileDescriptor, request.registrationID, .write(Int32(request.bytes)))
                    }
                    userData.deallocate()
                }
                else {
                    let pipe = request.pipe
                    var offs = userData.pointee.offs
                    let bytes = (request.bytes - userData.pointee.bytesProcessed)
                    _debugPrint("URing: CQE/sendFile, result[\(result)] offs[\(userData.pointee.offs)] bytes[\(bytes)]")
                    if offs >= 0 {
                        // source file -> write side of the pipe
                        offs += Int64(userData.pointee.bytesProcessed)
                        self.withSQE { sqe in
                            io_uring_prep_splice(sqe, request.src, offs, pipe.write, -1, bytes, 0)
                            io_uring_sqe_set_data(sqe, userData)
                        }
                    }
                    else {
                        // read side of the pipe -> destination socket
                        self.withSQE { sqe in
                            io_uring_prep_splice(sqe, pipe.read, -1, request.fileDescriptor, -1, bytes, 0)
                            io_uring_sqe_set_data(sqe, userData)
                        }
                    }
                    pendingSQEs += 1
                }
            }
            else {
                request.opsDone += 1
                if request.opsDone == 2 {
                    let idx = count
                    count += 1
                    events[idx] = URingEvent(request.fileDescriptor, request.registrationID, .write(Int32(request.bytes)))
                }
                userData.deallocate()
            }
        }
    }

    func peekBatchCQE(events: UnsafeMutablePointer<URingEvent>, maxEvents: Int, pendingSQEs: inout Int, multishot: Bool) -> Int {
        assert(maxEvents > 0, "maxEvents should be a positive number")

        let currentCqeCount = io_uring_peek_batch_cqe(&ring, cqes, cqeMaxCount)
        if currentCqeCount == 0 {
            _debugPrint("URing.peekBatchCQE: found zero events, breaking out")
            return 0
        }
        assert(currentCqeCount >= 0, "currentCqeCount should never be negative")

        _debugPrint("URing.peekBatchCQE: found [\(currentCqeCount)] events")

        var eventCount : Int = 0
        for cqeIndex in 0 ..< Int(currentCqeCount) {
            let cqe = cqes[cqeIndex]!
            self._processCQE(events: events, count: &eventCount, pendingSQEs: &pendingSQEs, multishot: multishot, cqe: cqe)

            if (eventCount == maxEvents) {
                _debugPrint("io_uring_peek_batch_cqe: breaking loop early, currentCqeCount=\(currentCqeCount) maxEvents=\(maxEvents)")
                break
            }
        }

        io_uring_cq_advance(&ring, currentCqeCount) // bulk variant of io_uring_cqe_seen(&ring, dataPointer)
        pollIdx.removeAll(keepingCapacity: true)

        _debugPrint("URing.peekBatchCQE: [\(eventCount)] events")

        return eventCount
    }

    private func _waitCQE(_ events: UnsafeMutablePointer<URingEvent>, _ error: Int32, _ multishot: Bool) throws -> Int {
        var eventCount = 0

        switch error {
        case 0:
            break
        case -CNIOLinux.EINTR:
            _debugPrint("_io_uring_wait_cqe_shared: EINTR")
            return eventCount
        case -CNIOLinux.ETIME:
            _debugPrint("_io_uring_wait_cqe_shared: ETIME")
            CNIOLinux.io_uring_cqe_seen(&ring, cqes[0])
            return eventCount
        default:
            _debugPrint("URingError.uringWaitCqeFailure \(error)")
            throw URingError.uringWaitCqeFailure
        }

        let cqe = cqes[0]!
        var pendingSQEs = 0
        self._processCQE(events: events, count: &eventCount, pendingSQEs: &pendingSQEs, multishot: multishot, cqe: cqe)

        io_uring_cqe_seen(&ring, cqes[0])
        pollIdx.removeAll(keepingCapacity: true) // reused for next batch

        return eventCount
    }

    func waitCQE(events: UnsafeMutablePointer<URingEvent>, multishot: Bool) throws -> Int {
        _debugPrint("URing.wait_cqe")
        let error = io_uring_wait_cqe(&ring, cqes)
        return try self._waitCQE(events, error, multishot)
    }

    func waitCQE(events: UnsafeMutablePointer<URingEvent>, timeout: TimeAmount, multishot: Bool = true) throws -> Int {
        var ts = timeout.kernelTimespec()
        _debugPrint("URing.wait_cqe_timeout: \(ts)ms")
        let error = io_uring_wait_cqe_timeout(&ring, cqes, &ts)
        return try self._waitCQE(events, error, multishot)
    }
}

#endif
