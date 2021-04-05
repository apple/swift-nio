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

// This is a companion to System.swift that provides only Linux specials: either things that exist
// only on Linux, or things that have Linux-specific extensions.

#if os(Linux)

import CNIOLinux

// we stuff the event type into the user data for the sqe together with
// the fd to match the events without needing any memory allocations or
// references. Just shift in the event type in the upper 32 bits.

internal enum CqeEventType : Int {
    case poll = 1, pollModify, pollDelete // start with 1 to not get zero bit patterns for stdin
}

internal enum UringError: Error {
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

internal struct UringEvent {
    var fd : Int32
    var pollMask : UInt32
    var sequenceIdentifier : UInt32
}

// FIXME: Current significant malloc regressions vs epoll:
// These seem to all be due to debugg logging (I updated debugging-allocations.md)
// Should verify again, but should be ok after debug logs are eliminated. 
// info: 1000_autoReadGetAndSet: total number of mallocs: 60994 (epoll 29000, 2x)
// info: 1000_autoReadGetAndSet_sync: total number of mallocs: 5000
// info: 1000_autoReadGetAndSet_sync: total number of mallocs: 5000
// info: 1000_reqs_1_conn: total number of mallocs: 60760
// info: 1000_tcpconnections: total number of mallocs: 337244
// info: 1000_udp_reqs: total number of mallocs: 46054
// info: 1000_udpconnections: total number of mallocs: 172523
// info: 1_reqs_1000_conn: total number of mallocs: 812225
// info: ping_pong_1000_reqs_1_conn: total number of mallocs: 34709
// info: read_10000_chunks_from_file: total number of mallocs: 320000
// info: udp_1000_reqs_1_conn: total number of mallocs: 46285
// info: udp_1_reqs_1000_conn: total number of mallocs: 338095

struct fdEventKey: Hashable {
    var fileDescriptor : Int32
    var sequenceIdentifier : UInt32

    init(_ f: Int32, _ s : UInt32) {
        self.fileDescriptor = f
        self.sequenceIdentifier = s
    }
}

final internal class Uring {
    internal static let POLLIN: CUnsignedInt = numericCast(CNIOLinux.POLLIN)
    internal static let POLLOUT: CUnsignedInt = numericCast(CNIOLinux.POLLOUT)
    internal static let POLLERR: CUnsignedInt = numericCast(CNIOLinux.POLLERR)
    internal static let POLLRDHUP: CUnsignedInt = numericCast(CNIOLinux.EPOLLRDHUP.rawValue) // FIXME: - POLLRDHUP not in ubuntu headers?!
    internal static let POLLHUP: CUnsignedInt = numericCast(CNIOLinux.POLLHUP)

    private var ring = io_uring()
    // FIXME: These should be tunable somewhere, somehow. Maybe environment vars are ok, need to discuss with SwiftNIO team.
    private let ringEntries: CUnsignedInt = 4096 // this is fairly large number due to some of the test that does 1K registration mods
    private let cqeMaxCount : UInt32 = 4096 // shouldn't be more than ringEntries, this is the max chunk of CQE we take.
        
    var cqes : UnsafeMutablePointer<UnsafeMutablePointer<io_uring_cqe>?>
    let mergeCQE = true // merge all events for same fd, sequence_identifier
    var fdEvents = [fdEventKey : UInt32]() // fd, sequence_identifier : event_poll_return
    var emptyCqe = io_uring_cqe()

    internal static let initializedUring: Bool = {
        CNIOLinux.CNIOLinux_io_uring_load() == 0
    }()

    internal static let _debugPrintEnabled: Bool = {
        getEnvironmentVar("NIO_LINUX") != nil
    }()

    internal static let _debugPrintEnabledCQE: Bool = {
        getEnvironmentVar("NIO_DUMPCQE") != nil
    }()

    func dumpCqes(_ header:String, count: Int = 1)
    {
        func _debugPrintCQE(_ s : String) {
            print("Q [\(NIOThread.current)] " + s)
        }
        
        if count < 0 || Uring._debugPrintEnabledCQE == false {
            return
        }

        _debugPrintCQE(header + " CQE:s [\(cqes)] - ring flags are [\(ring.flags)]")
        for i in 0..<count {
            let c = cqes[i]!.pointee

            let dp = io_uring_cqe_get_data(cqes[i])
            let bitPattern : UInt = UInt(bitPattern:dp)
            let fd = Int32(bitPattern & 0x00000000FFFFFFFF)
            let sequenceNumber : UInt32 = UInt32((Int(bitPattern) >> 32) & 0x00FFFFFF)
            let eventType = CqeEventType(rawValue:((Int(bitPattern) >> 32) & 0xFF000000) >> 24) // shift out the fd

            let bitpatternAsPointer = UnsafeMutableRawPointer.init(bitPattern: bitPattern)

            _debugPrintCQE("\(i) = fd[\(fd)] eventType[\(String(describing:eventType))] sequenceNumber[\(sequenceNumber)] res [\(c.res)] flags [\(c.flags)]  bitpattern[\(String(describing:bitpatternAsPointer))]")
        }
    }

    init() {
        cqes = UnsafeMutablePointer<UnsafeMutablePointer<io_uring_cqe>?>.allocate(capacity: Int(cqeMaxCount))
        cqes.initialize(repeating:&emptyCqe, count:Int(cqeMaxCount))
    }
    
    deinit {
        cqes.deallocate()
    }

    internal func fd() -> Int32 {
       return ring.ring_fd
    }

    static let _sqpollEnabled: Bool = {
        getEnvironmentVar("IORING_SETUP_SQPOLL") != nil // set this env. var to enable SQPOLL
    }()

    internal func io_uring_queue_init() throws -> () {
        // IORING_SETUP_SQPOLL will be fundamentally useful in 5.13, as we no longer need elevated privileges as previously
        // and CNIOLinux_io_uring_queue_init will setup a shared uring instance which allows us to use a single
        // kernel sqpoll thread that is shared amongst all loops. NB, each process will have it's own polling thread
        // if SQPOLL is enabled, so for hosts running multiple processes using it, some care should be taken to not overload.
        if (CNIOLinux.CNIOLinux_io_uring_queue_init(ringEntries, &ring, Uring._sqpollEnabled ? IORING_SETUP_SQPOLL : 0 ) != 0)
         {
             throw UringError.uringSetupFailure
         }
        
      //  _debugPrint"io_uring_queue_init \(self.ring.ring_fd)")
     }
  
    internal func io_uring_queue_exit() {
      //  _debugPrint"io_uring_queue_exit \(self.ring.ring_fd)")
        CNIOLinux_io_uring_queue_exit(&ring)
    }

    //   Ok, this was a real bummer - turns out that flushing multiple SQE:s
    //   can fail midflight and this will actually happen for real when e.g. a socket
    //   has gone down and we are re-registering polls this means we will silently lose any
    //   entries after the failed fd. Ouch. Proper approach is to use io_uring_sq_ready() in a loop.
    //   See: https://github.com/axboe/liburing/issues/309
            
    //   FIXME: NB we can get stuck in this flush for synthetic test that does a massive
    //   amount of registration modifications. Basically, this is due to back pressure from uring
    //   to make us reap CQE:s as the CQE queue would be full with responses. To avoid this
    //   we should either limit the amount of outbound operations we generate before reaping
    //   CQE:S, or run with IORING_SETUP_SQPOLL (then we would not get stuck here, as the kernel
    //   would simply stop reading SQE:s if the CQE queue is full, we would then instead get
    //   stuck trying to get a new SQE, which also would be a problem.). So, better limit amount
    //   of generated outbound operations sent and allow us to reap CQE:s somehow.
    //   Current workaround is to set up a fairly big ring size to avoid getting stuck, but
    //   that gives us worse locality of reference for the memory used by the ring, so worse
    //   cache behavior. Should be revisited, probably a more reasonable size of the ring
    //   would be in the hundreds rather than thousands.
    
    internal func io_uring_flush() {         // When using SQPOLL this is just a NOP
        var waitingSubmissions : UInt32 = 0
        var submissionCount = 0
        var retval : Int32
        
        waitingSubmissions = CNIOLinux_io_uring_sq_ready(&ring)
        
        loop: while (waitingSubmissions > 0)
        {
            retval = CNIOLinux_io_uring_submit(&ring)
            submissionCount += 1

            // FIXME: We will fail here if the rings ar too small, one of the allocation
            // tests required 1K ring size minimum to run as it was doing registration
            // mask notification repeatedly in a loop...
            switch retval {
                case -EBUSY: // same as EAGAIN practically
                    fallthrough
                // We can get -EAGAIN if the CQE queue is full and we get back pressure from
                // the kernel to start processing CQE:s. If we break here with unsubmitted
                // SQE:s, they will stay pending on the user-level side and be flushed
                // to the kernel after we had the opportunity to reap more CQE:s
                // In practice it will be at the end of whenReady the next
                // time around. Given the async nature, this is fine, we will not
                // lose any submissions. We could possibly still get stuck
                // trying to get  new SQE if the actual SQE queue is full, but
                // that would be due to user error in usage IMHO and we should fatalError there.
                case -EAGAIN:
                  //  _debugPrint"io_uring_flush io_uring_submit -EAGAIN waitingSubmissions[\(waitingSubmissions)] submissionCount[\(submissionCount)]. Breaking out and resubmitting later (whenReady() end).")
                    break loop
                // FIXME: -ENOMEM when there is not enough memory to do internal allocations on the kernel side.
                // Right nog we just loop with a sleep trying to buy time, but could also possibly fatalError here.
                //   See: https://github.com/axboe/liburing/issues/309
                case -ENOMEM:
                    usleep(1_000_000) // let's not busy loop to give the kernel some time to recover if possible
                  //  _debugPrint"io_uring_flush io_uring_submit -ENOMEM \(submissionCount)")
                case 0:
                  //  _debugPrint"io_uring_flush io_uring_submit submitted 0, so far needed submissionCount[\(submissionCount)] waitingSubmissions[\(waitingSubmissions)] submitted [\(retval)] SQE:s this iteration")
                    break
                case 1...:
                  //  _debugPrint"io_uring_flush io_uring_submit needed [\(submissionCount)] submission(s), submitted [\(retval)] SQE:s out of [\(waitingSubmissions)] possible")
                    break
                default: // other errors
                    fatalError("Unexpected error [\(retval)] from io_uring_submit ")
            }
            
            waitingSubmissions = CNIOLinux_io_uring_sq_ready(&ring)
        }
    }

    // we stuff event type into the upper byte, the next 3 bytes gives us the sequence number (16M before wrap) and final 4 bytes are fd.
    internal func io_uring_prep_poll_add(fd: Int32, pollMask: UInt32, sequenceIdentifier: UInt32, submitNow: Bool = true, multishot: Bool = true) -> () {
        let sqe = CNIOLinux_io_uring_get_sqe(&ring)
        let upperQuad : Int = Int(CqeEventType.poll.rawValue) << 24 + (Int(sequenceIdentifier) & 0x00FFFFFF)
        let bitPattern : Int = upperQuad << 32 + Int(fd)
        let bitpatternAsPointer = UnsafeMutableRawPointer.init(bitPattern: bitPattern)

      //  _debugPrint"io_uring_prep_poll_add fd[\(fd)] pollMask[\(pollMask)] bitpatternAsPointer[\(String(describing:bitpatternAsPointer))] submitNow[\(submitNow)] multishot[\(multishot)] upperQuad [\(upperQuad)]")

        CNIOLinux.io_uring_prep_poll_add(sqe, fd, pollMask)
        CNIOLinux.io_uring_sqe_set_data(sqe, bitpatternAsPointer) // must be done after prep_poll_add, otherwise zeroed out.

        // basically all polls will be multishot, except for the eventfd
        // which we keep at singleshot and re-register each time around
        // as certain use cases of nio seems to generate tons of wakeups
        // (at least its tested for that in some of the performance tests
        // e.g. future_whenallsucceed_100k_deferred_off_loop, future_whenallcomplete_100k_deferred_off_loop
        // ) - if using normal ET multishots, we would get 100k events to handle basically.
        // so using single shot for wakeups makes those tests run 30-35% faster approx.
        if multishot {
            sqe!.pointee.len |= IORING_POLL_ADD_MULTI; // turn on multishots
        }
        
        if submitNow {
            io_uring_flush()
        }
    }
    
    internal func io_uring_prep_poll_remove(fd: Int32, pollMask: UInt32, sequenceIdentifier: UInt32, submitNow: Bool = true) -> () {
        let sqe = CNIOLinux_io_uring_get_sqe(&ring)
        let upperQuad : Int = Int(CqeEventType.poll.rawValue) << 24 + (Int(sequenceIdentifier) & 0x00FFFFFF)
        let bitPattern : Int = upperQuad << 32 + Int(fd)
        let upperQuadDelete : Int = Int(CqeEventType.pollDelete.rawValue) << 24 + (Int(sequenceIdentifier) & 0x00FFFFFF)
        let userbitPattern : Int = upperQuadDelete << 32 + Int(fd)
        let bitpatternAsPointer = UnsafeMutableRawPointer.init(bitPattern: bitPattern)
        let userBitpatternAsPointer = UnsafeMutableRawPointer.init(bitPattern: userbitPattern)

      //  _debugPrint"io_uring_prep_poll_remove fd[\(fd)] pollMask[\(pollMask)] bitpatternAsPointer[\(String(describing:bitpatternAsPointer))] userBitpatternAsPointer[\(String(describing:userBitpatternAsPointer))] submitNow[\(submitNow)] upperQuad[\(upperQuad)] upperQuadDelete[\(upperQuadDelete)]")

        CNIOLinux.io_uring_prep_poll_remove(sqe, bitpatternAsPointer)
        CNIOLinux.io_uring_sqe_set_data(sqe, userBitpatternAsPointer) // must be done after prep_poll_add, otherwise zeroed out.

        if submitNow {
            io_uring_flush()
        }
    }

    internal func io_uring_poll_update(fd: Int32, newPollmask: UInt32, oldPollmask: UInt32, sequenceIdentifier: UInt32, submitNow: Bool = true, multishot : Bool = true) -> () {
        let sqe = CNIOLinux_io_uring_get_sqe(&ring)
        let upperQuad : Int = Int(CqeEventType.poll.rawValue) << 24 + (Int(sequenceIdentifier) & 0x00FFFFFF)
        let upperQuadModify : Int = Int(CqeEventType.pollModify.rawValue) << 24 + (Int(sequenceIdentifier) & 0x00FFFFFF)
        let oldBitpattern : Int = upperQuad << 32 + Int(fd)
        let newBitpattern : Int = upperQuad << 32 + Int(fd)
        let userbitPattern : Int = upperQuadModify << 32 + Int(fd)
        let userBitpatternAsPointer = UnsafeMutableRawPointer.init(bitPattern: userbitPattern)

      //  _debugPrint"io_uring_poll_update fd[\(fd)] oldPollmask[\(oldPollmask)] newPollmask[\(newPollmask)]  userBitpatternAsPointer[\(String(describing:userBitpatternAsPointer))] upperQuad[\(upperQuad)] upperQuadModify[\(upperQuadModify)]")
        
        // Documentation here:
        // https://git.kernel.dk/cgit/linux-block/commit/?h=poll-multiple&id=33021a19e324fb747c2038416753e63fd7cd9266
        CNIOLinux.io_uring_prep_poll_add(sqe, fd, 0)
        CNIOLinux.io_uring_sqe_set_data(sqe, userBitpatternAsPointer)
        if multishot {
            sqe!.pointee.len |= IORING_POLL_ADD_MULTI       // ask for multiple updates
        }
        sqe!.pointee.len |= IORING_POLL_UPDATE_EVENTS   // update existing mask
        sqe!.pointee.len |= IORING_POLL_UPDATE_USER_DATA // and update user data
        sqe!.pointee.addr = UInt64(oldBitpattern) // old user_data
        sqe!.pointee.off = UInt64(newBitpattern) // new user_data
        sqe!.pointee.poll_events = UInt16(newPollmask) // new poll mask

        if submitNow {
            io_uring_flush()
        }
    }

    internal func _debugPrint(_ s : @autoclosure () -> String)
    {
        if Uring._debugPrintEnabled {
            print("L [\(NIOThread.current)] " + s())
        }
    }

    // Merge results into fdEvents on fd, sequenceIdentifier for the given CQE
    internal func _process_cqe(events: UnsafeMutablePointer<UringEvent>, cqeIndex: Int) {
        let bitPattern : UInt = UInt(bitPattern:io_uring_cqe_get_data(cqes[cqeIndex]))
        let fd = Int32(bitPattern & 0x00000000FFFFFFFF)
        let sequenceNumber : UInt32 = UInt32((Int(bitPattern) >> 32) & 0x00FFFFFF)
        let eventType = CqeEventType(rawValue:((Int(bitPattern) >> 32) & 0xFF000000) >> 24) // shift out the fd
        let result = cqes[cqeIndex]!.pointee.res

        // FIXME: asserts here

        switch eventType {
            case .poll?:
                switch result {
                    case -ECANCELED: // -ECANCELED for streaming polls, should signal error
                        assert(fd >= 0, "fd must be greater than zero")

                        let pollError = Uring.POLLERR | Uring.POLLHUP
                        if let current = fdEvents[fdEventKey(fd, sequenceNumber)] {
                            fdEvents[fdEventKey(fd, sequenceNumber)] = current | pollError
                        } else {
                            fdEvents[fdEventKey(fd, sequenceNumber)] = pollError
                        }
                        break
                    case -EINVAL:
                      //  _debugPrint"Failed with -EINVAL for cqeIndex[\(cqeIndex)]")
                        break
                    case -EBADF:
                      //  _debugPrint"Failed with -EBADF for cqeIndex[\(cqeIndex)]")
                        break
                    case ..<0: // other errors
                      //  _debugPrint"Failed with unexpected error (\(result) for cqeIndex[\(cqeIndex)]")
                        break
                    case 0: // successfull chained add, not an event
                        break
                    default: // positive success
                        assert(bitPattern > 0, "Bitpattern should never be zero")
                        assert(fd >= 0, "fd must be greater than zero")
                        let uresult = UInt32(result)

                        if let current = fdEvents[fdEventKey(fd, sequenceNumber)] {
                            fdEvents[fdEventKey(fd, sequenceNumber)] =  current | uresult
                        } else {
                            fdEvents[fdEventKey(fd, sequenceNumber)] = uresult
                        }
                }
            case .pollModify?:
                switch result {
                    case -EALREADY:
                        break
                    case -ECANCELED: // -ECANCELED for streaming polls, should signal error
                        assert(fd >= 0, "fd must be greater than zero")

                        let pollError = Uring.POLLERR // Uring.POLLERR // (Uring.POLLHUP | Uring.POLLERR)
                        if let current = fdEvents[fdEventKey(fd, sequenceNumber)] {
                            fdEvents[fdEventKey(fd, sequenceNumber)] = current | pollError
                        } else {
                            fdEvents[fdEventKey(fd, sequenceNumber)] = pollError
                        }
                        break
                    case -ENOENT:
                      //  _debugPrint"Failed with -ENOENT for cqeIndex [\(cqeIndex)]")
                        break
                    case -EINVAL:
                      //  _debugPrint"Failed with -EINVAL for cqeIndex[\(cqeIndex)]")
                        break
                    case -EBADF:
                        break
                    case ..<0: // other errors
                        break
                    case 0: // successfull chained add, not an event
                        break
                    default: // positive success
                        fatalError("pollModify returned > 0")
                }
                break
            case .pollDelete?:
                break
            default:
                assertionFailure("Unknown type")
        }
    }

    internal func io_uring_peek_batch_cqe(events: UnsafeMutablePointer<UringEvent>, maxevents: UInt32) -> Int {
        var eventCount = 0
        var currentCqeCount = CNIOLinux_io_uring_peek_batch_cqe(&ring, cqes, cqeMaxCount)

        if currentCqeCount == 0 {
          //  _debugPrint"io_uring_peek_batch_cqe found zero events, breaking out")
            return 0
        }
        
      //  _debugPrint"io_uring_peek_batch_cqe found [\(currentCqeCount)] events")

        dumpCqes("io_uring_peek_batch_cqe", count: Int(currentCqeCount))

        assert(currentCqeCount >= 0, "currentCqeCount should never be negative")
        assert(maxevents > 0, "maxevents should be a positive number")

        for cqeIndex in 0 ..< currentCqeCount
        {
            _process_cqe(events: events, cqeIndex: Int(cqeIndex))

            if (fdEvents.count == maxevents) // ensure we don't generate more events than maxevents
            {
              //  _debugPrint"io_uring_peek_batch_cqe breaking loop early, currentCqeCount [\(currentCqeCount)] maxevents [\(maxevents)]")
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
            events[eventCount].sequenceIdentifier = eventKey.sequenceIdentifier
            eventCount += 1
        }

        fdEvents.removeAll(keepingCapacity: true) // reused for next batch

      //  _debugPrint"io_uring_peek_batch_cqe returning [\(eventCount)] events, fdEvents.count [\(fdEvents.count)]")

        return eventCount
    }

    internal func _io_uring_wait_cqe_shared(events: UnsafeMutablePointer<UringEvent>, error: Int32) throws -> Int {
        var eventCount = 0

        switch error {
            case 0:
                break
            case -CNIOLinux.EINTR:
              //  _debugPrint"_io_uring_wait_cqe_shared got CNIOLinux.EINTR")
                return eventCount
            case -CNIOLinux.ETIME:
              //  _debugPrint"_io_uring_wait_cqe_shared timed out with -CNIOLinux.ETIME")
                CNIOLinux.io_uring_cqe_seen(&ring, cqes[0])
                return eventCount
            default:
              //  _debugPrint"UringError.uringWaitCqeFailure \(error)")
                throw UringError.uringWaitCqeFailure
        }

        dumpCqes("_io_uring_wait_cqe_shared")

        _process_cqe(events: events, cqeIndex: 0)

        CNIOLinux.io_uring_cqe_seen(&ring, cqes[0])

        if let firstEvent = fdEvents.first {
            events[0].fd = firstEvent.key.fileDescriptor
            events[0].pollMask = firstEvent.value
            events[0].sequenceIdentifier = firstEvent.key.sequenceIdentifier
            eventCount = 1
        } else {
          //  _debugPrint"_io_uring_wait_cqe_shared if let firstEvent = fdEvents.first failed")
        }

        fdEvents.removeAll(keepingCapacity: true) // reused for next batch
        
        return eventCount
    }

    internal func io_uring_wait_cqe(events: UnsafeMutablePointer<UringEvent>, maxevents: UInt32) throws -> Int {
      //  _debugPrint"io_uring_wait_cqe")

        let error = CNIOLinux_io_uring_wait_cqe(&ring, cqes)
        
        return try _io_uring_wait_cqe_shared(events: events, error: error)
    }

    internal func io_uring_wait_cqe_timeout(events: UnsafeMutablePointer<UringEvent>, maxevents: UInt32, timeout: TimeAmount) throws -> Int {
        var ts = timeout.kernelTimespec()

      //  _debugPrint"io_uring_wait_cqe_timeout.ETIME milliseconds \(ts)")

        let error = CNIOLinux_io_uring_wait_cqe_timeout(&ring, cqes, &ts)

        return try _io_uring_wait_cqe_shared(events: events, error: error)
    }
}

#endif
