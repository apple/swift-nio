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

#if SWIFTNIO_USE_IO_URING
#if os(Linux)

import CNIOLinux
import NIOCore

@usableFromInline
enum CQEEventType: UInt8 {
    case poll = 1, pollModify, pollDelete // start with 1 to not get zero bit patterns for stdin
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

// URingUserData supports (un)packing into an `UInt64` as io_uring has a user_data 64-bit payload which is set in the SQE
// and returned in the CQE. We're using 56 of those 64 bits, 32 for the file descriptor, 16 for a "registration ID" and 8
// for the type of event issued (poll/modify/delete).
@usableFromInline struct URingUserData {
    @usableFromInline var fileDescriptor: CInt
    @usableFromInline var registrationID: UInt16 // SelectorRegistrationID truncated, only have room for bottom 16 bits (could be expanded to 24 if required)
    @usableFromInline var eventType: CQEEventType
    @usableFromInline var padding: Int8 // reserved for future use

    @inlinable init(registrationID: SelectorRegistrationID, fileDescriptor: CInt, eventType: CQEEventType) {
        assert(MemoryLayout<UInt64>.size == MemoryLayout<URingUserData>.size)
        self.registrationID = UInt16(truncatingIfNeeded: registrationID.rawValue)
        self.fileDescriptor = fileDescriptor
        self.eventType = eventType
        self.padding = 0
    }

    @inlinable init(rawValue: UInt64) {
        let unpacked = IntegerBitPacking.unpackUInt32UInt16UInt8(rawValue)
        self = .init(registrationID: SelectorRegistrationID(rawValue: UInt32(unpacked.1)),
                     fileDescriptor: CInt(unpacked.0),
                     eventType: CQEEventType(rawValue:unpacked.2)!)
    }
}

extension UInt64 {
    init(_ uringUserData: URingUserData) {
        let fd = uringUserData.fileDescriptor
        let eventType = uringUserData.eventType.rawValue
        assert(fd >= 0, "\(fd) is not a valid file descriptor")
        assert(eventType >= 0, "\(eventType) is not a valid eventType")

        self = IntegerBitPacking.packUInt32UInt16UInt8(UInt32(truncatingIfNeeded: fd),
                                                       uringUserData.registrationID,
                                                       eventType)
    }
}

// These are the events returned up to the selector
internal struct URingEvent {
    var fd: CInt
    var pollMask: UInt32
    var registrationID: UInt16 // we just have the truncated lower 16 bits of the registrationID
    var pollCancelled: Bool
    init () {
        self.fd = -1
        self.pollMask = 0
        self.registrationID = 0
        self.pollCancelled = false
    }
}

// This is the key we use for merging events in our internal hashtable
struct FDEventKey: Hashable {
    var fileDescriptor: CInt
    var registrationID: UInt16 // we just have the truncated lower 16 bits of the registrationID

    init(_ f: CInt, _ s: UInt16) {
        self.fileDescriptor = f
        self.registrationID = s
    }
}

final internal class URing {
    internal static let POLLIN: CUnsignedInt = numericCast(CNIOLinux.POLLIN)
    internal static let POLLOUT: CUnsignedInt = numericCast(CNIOLinux.POLLOUT)
    internal static let POLLERR: CUnsignedInt = numericCast(CNIOLinux.POLLERR)
    internal static let POLLRDHUP: CUnsignedInt = CNIOLinux_POLLRDHUP() // numericCast(CNIOLinux.POLLRDHUP) 
    internal static let POLLHUP: CUnsignedInt = numericCast(CNIOLinux.POLLHUP)
    internal static let POLLCANCEL: CUnsignedInt = 0xF0000000 // Poll cancelled, need to reregister for singleshot polls

    private var ring = io_uring()
    private let ringEntries: CUnsignedInt = 8192
    private let cqeMaxCount: UInt32 = 8192 // this is the max chunk of CQE we take.

    var cqes: UnsafeMutablePointer<UnsafeMutablePointer<io_uring_cqe>?>
    var fdEvents = [FDEventKey : UInt32]() // fd, sequence_identifier : merged event_poll_return
    var emptyCqe = io_uring_cqe()

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

    func _dumpCqes(_ header:String, count: Int = 1) {
        #if SWIFTNIO_IO_URING_DEBUG_DUMP_CQE
        func _debugPrintCQE(_ s: String) {
            print("Q [\(NIOThread.current)] " + s)
        }

        if count < 0 {
            return
        }

        _debugPrintCQE(header + " CQE:s [\(cqes)] - ring flags are [\(ring.flags)]")
        for i in 0..<count {
            let c = cqes[i]!.pointee

            let bitPattern = UInt(bitPattern:io_uring_cqe_get_data(cqes[i]))
            let uringUserData = URingUserData(rawValue: UInt64(bitPattern))

            _debugPrintCQE("\(i) = fd[\(uringUserData.fileDescriptor)] eventType[\(String(describing:uringUserData.eventType))] registrationID[\(uringUserData.registrationID)] res [\(c.res)] flags [\(c.flags)]")
        }
        #endif
    }

    init() {
        cqes = UnsafeMutablePointer<UnsafeMutablePointer<io_uring_cqe>?>.allocate(capacity: Int(cqeMaxCount))
        cqes.initialize(repeating:&emptyCqe, count:Int(cqeMaxCount))
    }

    deinit {
        cqes.deallocate()
    }

    internal func io_uring_queue_init() throws -> () {
        if (CNIOLinux.io_uring_queue_init(ringEntries, &ring, 0 ) != 0)
         {
             throw URingError.uringSetupFailure
         }

        _debugPrint("io_uring_queue_init \(self.ring.ring_fd)")
     }

    internal func io_uring_queue_exit() {
        _debugPrint("io_uring_queue_exit \(self.ring.ring_fd)")
        CNIOLinux.io_uring_queue_exit(&ring)
    }

    // Adopting some retry code from queue.c from liburing with slight
    // modifications - we never want to have to handle retries of
    // SQE allocation in all places it could possibly occur.
    // If the SQ ring is full, we may need to submit IO first
    func withSQE<R>(_ body: (UnsafeMutablePointer<io_uring_sqe>?) throws -> R) rethrows -> R
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
            if let sqe = CNIOLinux.io_uring_get_sqe(&ring) {
               return try body(sqe)
            }
            self.io_uring_flush()
        }
    }

    // Ok, this was a bummer - turns out that flushing multiple SQE:s
    // can fail midflight and this will actually happen for real when e.g. a socket
    // has gone down and we are re-registering polls this means we will silently lose any
    // entries after the failed fd. Ouch. Proper approach is to use io_uring_sq_ready() in a loop.
    // See: https://github.com/axboe/liburing/issues/309
    internal func io_uring_flush() {         // When using SQPOLL this is basically a NOP
        var waitingSubmissions: UInt32 = 0
        var submissionCount = 0
        var retval: CInt

        waitingSubmissions = CNIOLinux.io_uring_sq_ready(&ring)

        loop: while (waitingSubmissions > 0)
        {
            retval = CNIOLinux.io_uring_submit(&ring)
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
                _debugPrint("io_uring_flush io_uring_submit -EBUSY/-EAGAIN waitingSubmissions[\(waitingSubmissions)] submissionCount[\(submissionCount)]. Breaking out and resubmitting later (whenReady() end).")
                break loop
            // -ENOMEM when there is not enough memory to do internal allocations on the kernel side.
            // Right nog we just loop with a sleep trying to buy time, but could also possibly fatalError here.
            // See: https://github.com/axboe/liburing/issues/309
            case -ENOMEM:
                usleep(10_000) // let's not busy loop to give the kernel some time to recover if possible
                _debugPrint("io_uring_flush io_uring_submit -ENOMEM \(submissionCount)")
            case 0:
                _debugPrint("io_uring_flush io_uring_submit submitted 0, so far needed submissionCount[\(submissionCount)] waitingSubmissions[\(waitingSubmissions)] submitted [\(retval)] SQE:s this iteration")
                break
            case 1...:
                _debugPrint("io_uring_flush io_uring_submit needed [\(submissionCount)] submission(s), submitted [\(retval)] SQE:s out of [\(waitingSubmissions)] possible")
                break
            default: // other errors
                fatalError("Unexpected error [\(retval)] from io_uring_submit ")
            }

            waitingSubmissions = CNIOLinux.io_uring_sq_ready(&ring)
        }
    }

    // we stuff event type into the upper byte, the next 3 bytes gives us the sequence number (16M before wrap) and final 4 bytes are fd.
    internal func io_uring_prep_poll_add(fileDescriptor: CInt, pollMask: UInt32, registrationID: SelectorRegistrationID, submitNow: Bool = true, multishot: Bool = true) -> () {
        let bitPattern = UInt64(URingUserData(registrationID: registrationID, fileDescriptor: fileDescriptor, eventType:CQEEventType.poll))
        let bitpatternAsPointer = UnsafeMutableRawPointer.init(bitPattern: UInt(bitPattern))

        _debugPrint("io_uring_prep_poll_add fileDescriptor[\(fileDescriptor)] pollMask[\(pollMask)] bitpatternAsPointer[\(String(describing:bitpatternAsPointer))] submitNow[\(submitNow)] multishot[\(multishot)]")

        self.withSQE { sqe in
            CNIOLinux.io_uring_prep_poll_add(sqe, fileDescriptor, pollMask)
            CNIOLinux.io_uring_sqe_set_data(sqe, bitpatternAsPointer) // must be done after prep_poll_add, otherwise zeroed out.

            if multishot {
                sqe!.pointee.len |= IORING_POLL_ADD_MULTI; // turn on multishots, set through environment variable
            }
        }
        
        if submitNow {
            self.io_uring_flush()
        }
    }

    internal func io_uring_prep_poll_remove(fileDescriptor: CInt, pollMask: UInt32, registrationID: SelectorRegistrationID, submitNow: Bool = true, link: Bool = false) -> () {
        let bitPattern = UInt64(URingUserData(registrationID: registrationID,
                                              fileDescriptor: fileDescriptor,
                                              eventType:CQEEventType.poll))
        let userbitPattern = UInt64(URingUserData(registrationID: registrationID,
                                                  fileDescriptor: fileDescriptor,
                                                  eventType:CQEEventType.pollDelete))

        _debugPrint("io_uring_prep_poll_remove fileDescriptor[\(fileDescriptor)] pollMask[\(pollMask)] bitpatternAsPointer[\(String(describing: bitPattern))] userBitpatternAsPointer[\(String(describing: userbitPattern))] submitNow[\(submitNow)] link[\(link)]")

        self.withSQE { sqe in
            CNIOLinux.io_uring_prep_poll_remove(sqe, .init(userData: bitPattern))
            CNIOLinux.io_uring_sqe_set_data(sqe, .init(userData: userbitPattern)) // must be done after prep_poll_add, otherwise zeroed out.

            if link {
                CNIOLinux_io_uring_set_link_flag(sqe)
            }
        }
        
        if submitNow {
            self.io_uring_flush()
        }
    }
    
    // the update/multishot polls are
    internal func io_uring_poll_update(fileDescriptor: CInt, newPollmask: UInt32, oldPollmask: UInt32, registrationID: SelectorRegistrationID, submitNow: Bool = true, multishot: Bool = true) -> () {
        
        let bitpattern = UInt64(URingUserData(registrationID: registrationID,
                                              fileDescriptor: fileDescriptor,
                                              eventType:CQEEventType.poll))
        let userbitPattern = UInt64(URingUserData(registrationID: registrationID,
                                              fileDescriptor: fileDescriptor,
                                              eventType:CQEEventType.pollModify))

        _debugPrint("io_uring_poll_update fileDescriptor[\(fileDescriptor)] oldPollmask[\(oldPollmask)] newPollmask[\(newPollmask)]  userBitpatternAsPointer[\(String(describing: userbitPattern))]")

        self.withSQE { sqe in
            // "Documentation" for multishot polls and updates here:
            // https://git.kernel.dk/cgit/linux-block/commit/?h=poll-multiple&id=33021a19e324fb747c2038416753e63fd7cd9266
            var flags = IORING_POLL_UPDATE_EVENTS | IORING_POLL_UPDATE_USER_DATA
            if multishot {
                flags |= IORING_POLL_ADD_MULTI       // ask for multiple updates
            }

            CNIOLinux.io_uring_prep_poll_update(sqe, .init(userData: bitpattern), .init(userData: bitpattern), newPollmask, flags)
            CNIOLinux.io_uring_sqe_set_data(sqe, .init(userData: userbitPattern))
        }
        
        if submitNow {
            self.io_uring_flush()
        }
    }

    internal func _debugPrint(_ s: @autoclosure () -> String)
    {
        #if SWIFTNIO_IO_URING_DEBUG_URING
        print("L [\(NIOThread.current)] " + s())
        #endif
    }

    // We merge results into fdEvents on (fd, registrationID) for the given CQE
    // this minimizes amount of events propagating up and allows Selector to discard
    // events with an old sequence identifier.
    internal func _process_cqe(events: UnsafeMutablePointer<URingEvent>, cqeIndex: Int, multishot: Bool) {
        let bitPattern = UInt(bitPattern:io_uring_cqe_get_data(cqes[cqeIndex]))
        let uringUserData = URingUserData(rawValue: UInt64(bitPattern))
        let result = cqes[cqeIndex]!.pointee.res

        switch uringUserData.eventType {
        case .poll:
            switch result {
            case -ECANCELED:
                var pollError: UInt32 = 0
                assert(uringUserData.fileDescriptor >= 0, "fd must be zero or greater")
                if multishot { // -ECANCELED for streaming polls, should signal error
                    pollError = URing.POLLERR | URing.POLLHUP
                } else {       // this just signals that Selector just should resubmit a new fresh poll
                    pollError = URing.POLLCANCEL
                }
                if let current = fdEvents[FDEventKey(uringUserData.fileDescriptor, uringUserData.registrationID)] {
                    fdEvents[FDEventKey(uringUserData.fileDescriptor, uringUserData.registrationID)] = current | pollError
                } else {
                    fdEvents[FDEventKey(uringUserData.fileDescriptor, uringUserData.registrationID)] = pollError
                }
                break
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
                _debugPrint("Failed poll with -EBADF for cqeIndex[\(cqeIndex)]")
                break
            case ..<0: // other errors
                fatalError("Failed poll with unexpected error (\(result) for cqeIndex[\(cqeIndex)]")
                break
            case 0: // successfull chained add for singleshots, not an event
                break
            default: // positive success
                assert(uringUserData.fileDescriptor >= 0, "fd must be zero or greater")
                let uresult = UInt32(result)

                if let current = fdEvents[FDEventKey(uringUserData.fileDescriptor, uringUserData.registrationID)] {
                    fdEvents[FDEventKey(uringUserData.fileDescriptor, uringUserData.registrationID)] =  current | uresult
                } else {
                    fdEvents[FDEventKey(uringUserData.fileDescriptor, uringUserData.registrationID)] = uresult
                }
            }
        case .pollModify: // we only get this for multishot modifications
            switch result {
            case -ECANCELED: // -ECANCELED for streaming polls, should signal error
                assert(uringUserData.fileDescriptor >= 0, "fd must be zero or greater")

                let pollError = URing.POLLERR // URing.POLLERR // (URing.POLLHUP | URing.POLLERR)
                if let current = fdEvents[FDEventKey(uringUserData.fileDescriptor, uringUserData.registrationID)] {
                    fdEvents[FDEventKey(uringUserData.fileDescriptor, uringUserData.registrationID)] = current | pollError
                } else {
                    fdEvents[FDEventKey(uringUserData.fileDescriptor, uringUserData.registrationID)] = pollError
                }
                break
            case -EALREADY:
                _debugPrint("Failed pollModify with -EALREADY for cqeIndex[\(cqeIndex)]")
                break
            case -ENOENT:
                _debugPrint("Failed pollModify with -ENOENT for cqeIndex [\(cqeIndex)]")
                break
            // See the description for EBADF handling above in the poll case for rationale of allowing EBADF.
            case -EBADF:
                _debugPrint("Failed pollModify with -EBADF for cqeIndex[\(cqeIndex)]")
                break
            case ..<0: // other errors
                fatalError("Failed pollModify with unexpected error (\(result) for cqeIndex[\(cqeIndex)]")
                break
            case 0: // successfull chained add, not an event
                break
            default: // positive success
                fatalError("pollModify returned > 0")
            }
            break
        case .pollDelete:
            break
        }
    }

    internal func io_uring_peek_batch_cqe(events: UnsafeMutablePointer<URingEvent>, maxevents: UInt32, multishot: Bool = true) -> Int {
        var eventCount = 0
        var currentCqeCount = CNIOLinux.io_uring_peek_batch_cqe(&ring, cqes, cqeMaxCount)

        if currentCqeCount == 0 {
            _debugPrint("io_uring_peek_batch_cqe found zero events, breaking out")
            return 0
        }

        _debugPrint("io_uring_peek_batch_cqe found [\(currentCqeCount)] events")

        self._dumpCqes("io_uring_peek_batch_cqe", count: Int(currentCqeCount))

        assert(currentCqeCount >= 0, "currentCqeCount should never be negative")
        assert(maxevents > 0, "maxevents should be a positive number")

        for cqeIndex in 0 ..< currentCqeCount
        {
            self._process_cqe(events: events, cqeIndex: Int(cqeIndex), multishot:multishot)

            if (fdEvents.count == maxevents) // ensure we don't generate more events than maxevents
            {
                _debugPrint("io_uring_peek_batch_cqe breaking loop early, currentCqeCount [\(currentCqeCount)] maxevents [\(maxevents)]")
                currentCqeCount = maxevents // to make sure we only cq_advance the correct amount
                break
            }
        }

        io_uring_cq_advance(&ring, currentCqeCount) // bulk variant of io_uring_cqe_seen(&ring, dataPointer)

        //  we just return single event per fd, sequencenumber pair
        eventCount = 0
        for (eventKey, pollMask) in fdEvents {
            assert(eventCount < maxevents)
            assert(eventKey.fileDescriptor >= 0)

            events[eventCount].fd = eventKey.fileDescriptor
            events[eventCount].pollMask = pollMask
            events[eventCount].registrationID = eventKey.registrationID
            if (pollMask & URing.POLLCANCEL) != 0 {
                events[eventCount].pollMask &= ~URing.POLLCANCEL
                events[eventCount].pollCancelled = true
            }
            eventCount += 1
        }

        fdEvents.removeAll(keepingCapacity: true) // reused for next batch

        _debugPrint("io_uring_peek_batch_cqe returning [\(eventCount)] events, fdEvents.count [\(fdEvents.count)]")

        return eventCount
    }

    internal func _io_uring_wait_cqe_shared(events: UnsafeMutablePointer<URingEvent>, error: Int32, multishot: Bool) throws -> Int {
        var eventCount = 0

        switch error {
        case 0:
            break
        case -CNIOLinux.EINTR:
            _debugPrint("_io_uring_wait_cqe_shared got CNIOLinux.EINTR")
            return eventCount
        case -CNIOLinux.ETIME:
            _debugPrint("_io_uring_wait_cqe_shared timed out with -CNIOLinux.ETIME")
            CNIOLinux.io_uring_cqe_seen(&ring, cqes[0])
            return eventCount
        default:
            _debugPrint("URingError.uringWaitCqeFailure \(error)")
            throw URingError.uringWaitCqeFailure
        }

        self._dumpCqes("_io_uring_wait_cqe_shared")

        self._process_cqe(events: events, cqeIndex: 0, multishot:multishot)

        CNIOLinux.io_uring_cqe_seen(&ring, cqes[0])

        if let firstEvent = fdEvents.first {
            events[0].fd = firstEvent.key.fileDescriptor
            events[0].pollMask = firstEvent.value
            events[0].registrationID = firstEvent.key.registrationID
            eventCount = 1
        } else {
            _debugPrint("_io_uring_wait_cqe_shared if let firstEvent = fdEvents.first failed")
        }

        fdEvents.removeAll(keepingCapacity: true) // reused for next batch

        return eventCount
    }

    internal func io_uring_wait_cqe(events: UnsafeMutablePointer<URingEvent>, maxevents: UInt32, multishot: Bool = true) throws -> Int {
        _debugPrint("io_uring_wait_cqe")

        let error = CNIOLinux.io_uring_wait_cqe(&ring, cqes)

        return try self._io_uring_wait_cqe_shared(events: events, error: error, multishot:multishot)
    }

    internal func io_uring_wait_cqe_timeout(events: UnsafeMutablePointer<URingEvent>, maxevents: UInt32, timeout: TimeAmount, multishot: Bool = true) throws -> Int {
        var ts = timeout.kernelTimespec()

        _debugPrint("io_uring_wait_cqe_timeout.ETIME milliseconds \(ts)")

        let error = CNIOLinux.io_uring_wait_cqe_timeout(&ring, cqes, &ts)

        return try self._io_uring_wait_cqe_shared(events: events, error: error, multishot:multishot)
    }
}

// MARK: Conversion helpers
// Newer versions of liburing changed one of the method arguments from UnsafeMutableRawPointer
// to UInt64 in order to allow 32-bit systems to work properly. We therefore need a way to
// transform a UInt64 into either of these types. These two initializers help us do that in
// a way that supports both the old and new format in source.
extension UInt64 {
    init(userData: UInt64) {
        self = userData
    }
}

extension Optional where Wrapped == UnsafeMutableRawPointer {
    init(userData: UInt64) {
        // This will crash on 32-bit systems: that's fine, our liburing support
        // never worked on 32-bit for older libraries anyway.
        self = .init(bitPattern: UInt(userData))
    }
}

#endif

#endif
