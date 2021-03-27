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
    case uringWaitCqeTimeoutFailure
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
}

internal class Uring {
    internal static let POLLIN: CUnsignedInt = numericCast(CNIOLinux.POLLIN)
    internal static let POLLOUT: CUnsignedInt = numericCast(CNIOLinux.POLLOUT)
    internal static let POLLERR: CUnsignedInt = numericCast(CNIOLinux.POLLERR)
    internal static let POLLRDHUP: CUnsignedInt = numericCast(CNIOLinux.EPOLLRDHUP.rawValue) // FIXME: - POLLRDHUP not in ubuntu headers?!
    internal static let POLLHUP: CUnsignedInt = numericCast(CNIOLinux.POLLHUP)

    private var ring = io_uring()
    // FIXME: These should be tunable somewhere, somehow. Maybe environment vars are ok, need to discuss with SwiftNIO team.
    private let ringEntries: CUnsignedInt = 8192 // this is a very large number due to some of the test that does 1K registration mods
    private let cqeMaxCount : UInt32 = 4096 // shouldn't be more than ringEntries, this is the max chunk of CQE we take.
        
    var cqes : UnsafeMutablePointer<UnsafeMutablePointer<io_uring_cqe>?>
    var fdEvents = [Int32: UInt32]() // fd : event_poll_return
    var emptyCqe = io_uring_cqe()

    internal static let initializedUring: Bool = {
        CNIOLinux.CNIOLinux_io_uring_load() == 0
    }()

    func dumpCqes(_ header:String, count: Int = 1)
    {
        if count < 0 {
            return
        }
        
        if getEnvironmentVar("NIO_DUMPCQE") == nil {
            return
        }

        _debugPrint(header + " CQE:s [\(cqes)] - ring flags are [\(ring.flags)]")
        for i in 0..<count {
            let c = cqes[i]!.pointee

            let dp = io_uring_cqe_get_data(cqes[i])
            let bitPattern : UInt = UInt(bitPattern:dp)

            let fd = Int(bitPattern & 0x00000000FFFFFFFF)
            let eventType = Int(bitPattern >> 32) // shift out the fd

            let bitpatternAsPointer = UnsafeMutableRawPointer.init(bitPattern: bitPattern)

            _debugPrint("\(i) = fd[\(fd)] eventType[\(String(describing:CqeEventType(rawValue:eventType)))] res [\(c.res)] flags [\(c.flags)]  bitpattern[\(String(describing:bitpatternAsPointer))]")
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

    internal func io_uring_queue_init() throws -> () {
        // FIXME: IORING_SETUP_SQPOLL is currently basically useless in default configuraiton as it starts one kernel
        // poller thread per ring. It is possible to regulate this by sharing a kernel thread for the polling
        // with IORING_SETUP_ATTACH_WQ, but it requires the first ring to be setup with polling and then the
        // fd shared with later rings. Not very convenient or easy to use really.
        // A New setup option is in the works IORING_SETUP_SQPOLL_PERCPU which together with IORING_SETUP_SQ_AFF
        // will be possible to use to bind the kernel poller thread to a given cpu (and share one amongst all rings)
        // - not yet in the kernel and work in progress, but should be a better fit and worth trying.
        // Alternatively we could look at limiting number of threads created to numcpu / 2 or so
        // instead of starting one thread per core in the multithreaded event loop
        // or allowing customization of whether to use SQPOLL somewhere higher up.
        // Also, current IORING_SETUP_SQPOLL requires correct privileges to run (root or specific privs set)
        if (CNIOLinux.CNIOLinux_io_uring_queue_init(ringEntries, &ring, 0 ) != 0) // IORING_SETUP_SQPOLL
         {
             throw UringError.uringSetupFailure
         }
        
        _debugPrint("io_uring_queue_init \(self.ring.ring_fd)")
     }
  
    internal func io_uring_queue_exit() {
        _debugPrint("io_uring_queue_exit \(self.ring.ring_fd)")
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
        var submissions = 0
        var retval : Int32
        
        _debugPrint("io_uring_flush")

        // FIXME:  it may return -EAGAIN or -ENOMEM when there is not enough memory to do internal allocations.
        //   See: https://github.com/axboe/liburing/issues/309
        while (CNIOLinux_io_uring_sq_ready(&ring) > 0)
        {
            retval = CNIOLinux_io_uring_submit(&ring)
            submissions += 1

            // FIXME: We will fail here if the rings ar too small, one of the allocation
            // tests required 1K ring size minimum to run as it was doing registration
            // mask notification repeatedly in a loop...
            if submissions > 1 {
                if (retval == -EAGAIN)
                {
                    _debugPrint("io_uring_flush io_uring_submit -EAGAIN \(submissions)")

                }
                if (retval == -ENOMEM)
                {
                    _debugPrint("io_uring_flush io_uring_submit -ENOMEM \(submissions)")
                }
                _debugPrint("io_uring_flush io_uring_submit needed \(submissions)")
            }
        }
        _debugPrint("io_uring_flush done")
    }

    internal func io_uring_prep_poll_add(fd: Int32, pollMask: UInt32, submitNow: Bool = true) -> () {
        let sqe = CNIOLinux_io_uring_get_sqe(&ring)
        let bitPattern : Int = CqeEventType.poll.rawValue << 32 + Int(fd)
        let bitpatternAsPointer = UnsafeMutableRawPointer.init(bitPattern: bitPattern)

        _debugPrint("io_uring_prep_poll_add fd[\(fd)] pollMask[\(pollMask)] bitpatternAsPointer[\(String(describing:bitpatternAsPointer))] submitNow[\(submitNow)]")

        CNIOLinux.io_uring_prep_poll_add(sqe, fd, pollMask)
        CNIOLinux.io_uring_sqe_set_data(sqe, bitpatternAsPointer) // must be done after prep_poll_add, otherwise zeroed out.

        sqe!.pointee.len |= IORING_POLL_ADD_MULTI; // turn on multishots

        if submitNow {
            io_uring_flush()
        }
    }
    
    internal func io_uring_prep_poll_remove(fd: Int32, pollMask: UInt32, submitNow: Bool = true) -> () {
        let sqe = CNIOLinux_io_uring_get_sqe(&ring)
        let bitPattern : Int = CqeEventType.poll.rawValue << 32 + Int(fd) // must be same as the poll for liburing to match
        let userbitPattern : Int = CqeEventType.pollDelete.rawValue << 32 + Int(fd)
        let bitpatternAsPointer = UnsafeMutableRawPointer.init(bitPattern: bitPattern)
        let userBitpatternAsPointer = UnsafeMutableRawPointer.init(bitPattern: userbitPattern)

        _debugPrint("io_uring_prep_poll_remove fd[\(fd)] pollMask[\(pollMask)] bitpatternAsPointer[\(String(describing:bitpatternAsPointer))] userBitpatternAsPointer[\(String(describing:userBitpatternAsPointer))] submitNow[\(submitNow)]")

        CNIOLinux.io_uring_prep_poll_remove(sqe, bitpatternAsPointer)
        CNIOLinux.io_uring_sqe_set_data(sqe, userBitpatternAsPointer) // must be done after prep_poll_add, otherwise zeroed out.

        if submitNow {
            io_uring_flush()
        }
    }

    internal func io_uring_poll_update(fd: Int32, newPollmask: UInt32, oldPollmask: UInt32, submitNow: Bool = true) -> () {
        let sqe = CNIOLinux_io_uring_get_sqe(&ring)
        let oldBitpattern : Int = CqeEventType.poll.rawValue << 32 + Int(fd)
        let newBitpattern : Int = CqeEventType.poll.rawValue << 32 + Int(fd)
        let userbitPattern : Int = CqeEventType.pollModify.rawValue << 32 + Int(fd)
        let userBitpatternAsPointer = UnsafeMutableRawPointer.init(bitPattern: userbitPattern)

        _debugPrint("io_uring_poll_update fd[\(fd)] oldPollmask[\(oldPollmask)] newPollmask[\(newPollmask)]  userBitpatternAsPointer[\(String(describing:userBitpatternAsPointer))]")
        
        // Documentation here:
        // https://git.kernel.dk/cgit/linux-block/commit/?h=poll-multiple&id=33021a19e324fb747c2038416753e63fd7cd9266
        CNIOLinux.io_uring_prep_poll_add(sqe, fd, 0)
        CNIOLinux.io_uring_sqe_set_data(sqe, userBitpatternAsPointer)

        sqe!.pointee.len |= IORING_POLL_ADD_MULTI       // ask for multiple updates
        sqe!.pointee.len |= IORING_POLL_UPDATE_EVENTS   // update existing mask
        sqe!.pointee.len |= IORING_POLL_UPDATE_USER_DATA // and update user data
        sqe!.pointee.addr = UInt64(oldBitpattern) // old user_data
        sqe!.pointee.off = UInt64(newBitpattern) // new user_data
        sqe!.pointee.poll_events = UInt16(newPollmask) // new poll mask

        if submitNow {
            io_uring_flush()
        }
    }

    internal func getEnvironmentVar(_ name: String) -> String? {
        guard let rawValue = getenv(name) else { return nil }
        return String(cString: rawValue)
    }

    internal func _debugPrint(_ s : @autoclosure () -> String)
    {
        if getEnvironmentVar("NIO_LINUX") != nil {
            print("L [\(NIOThread.current)] " + s())
        }
    }

    internal func io_uring_peek_batch_cqe(events: UnsafeMutablePointer<UringEvent>, maxevents: UInt32) -> Int {
        _debugPrint("io_uring_peek_batch_cqe")
        var currentCqeCount = CNIOLinux_io_uring_peek_batch_cqe(&ring, cqes, cqeMaxCount)
        if currentCqeCount == 0 {
            return 0
        }
        
        dumpCqes("io_uring_peek_batch_cqe", count: Int(currentCqeCount))

        assert(currentCqeCount >= 0, "currentCqeCount should never be negative")
        assert(maxevents > 0, "maxevents should be a positive number")

        for i in 0 ..< currentCqeCount
        {
            let bitPattern : UInt = UInt(bitPattern:io_uring_cqe_get_data(cqes[Int(i)]))
            let fd = Int32(bitPattern & 0x00000000FFFFFFFF)
            let eventType = CqeEventType(rawValue:Int(bitPattern) >> 32) // shift out the fd
            let result = cqes[Int(i)]!.pointee.res

            switch eventType {
                case .poll?:
                    switch result {
                        case -ECANCELED: // -ECANCELED for streaming polls, should signal error
                            assert(fd >= 0, "fd must be greater than zero")
                            let pollError = (Uring.POLLHUP | Uring.POLLERR)
                            if let current = fdEvents[fd] {
                                fdEvents[fd] = current | pollError
                            } else {
                                fdEvents[fd] = pollError
                            }
                            break
                        case -ENOENT:    // -ENOENT returned for failed poll remove
                            break
                        case -EINVAL:
                            _debugPrint("Failed with -EINVAL for i[\(i)]")
                            break
                        case -EBADF:
                            break
                        case ..<0: // other errors
                            break
                        case 0: // successfull chained add, not an event
                            break
                        default: // positive success
                            assert(bitPattern > 0, "Bitpattern should never be zero")
                            assert(fd >= 0, "fd must be greater than zero")

                            let uresult = UInt32(result)
                            if let current = fdEvents[fd] {
                                fdEvents[fd] =  current | uresult
                            } else {
                                fdEvents[fd] = uresult
                            }
                    }
                case .pollModify?:
                    break
                case .pollDelete?:
                    break
                default:
                    assertionFailure("Unknown type")
            }
            if (fdEvents.count == maxevents)
            {
                _debugPrint("io_uring_peek_batch_cqe breaking loop early, currentCqeCount [\(currentCqeCount)] maxevents [\(maxevents)]")
                currentCqeCount = maxevents // to make sure we only cq_advance the correct amount
                break
            }
        }

        io_uring_cq_advance(&ring, currentCqeCount) // bulk variant of io_uring_cqe_seen(&ring, dataPointer)

        //  return single event per fd,
        var count = 0
        for (fd, result_mask) in fdEvents {
            assert(count < maxevents)
            assert(fd >= 0)

            events[count].fd = fd
            events[count].pollMask = result_mask
            count+=1

            let socketClosing = (result_mask & (Uring.POLLRDHUP | Uring.POLLHUP | Uring.POLLERR)) > 0 ? true : false

            if (socketClosing == true) {
                _debugPrint("socket is going down [\(fd)] [\(result_mask)] [\((result_mask & (Uring.POLLRDHUP | Uring.POLLHUP | Uring.POLLERR)))]")
            }
        }

        if count > 0 {
            _debugPrint("io_uring_peek_batch_cqe returning [\(count)] events")
        } else if fdEvents.count > 0 {
            _debugPrint("fdEvents.count > 0 but 0 event.count returning [\(count)]")
        }

        fdEvents.removeAll(keepingCapacity: true) // reused for next batch
    
        return count
    }

    internal func io_uring_wait_cqe(events: UnsafeMutablePointer<UringEvent>, maxevents: UInt32) throws -> Int {
        _debugPrint("io_uring_wait_cqe")
        let error = CNIOLinux_io_uring_wait_cqe(&ring, cqes)
        var count = 0
        
        if (error == 0)
        {
            dumpCqes("io_uring_wait_cqe")
            let bitPattern : UInt = UInt(bitPattern:io_uring_cqe_get_data(cqes[0]))
            let fd = Int32(bitPattern & 0x00000000FFFFFFFF)
            let eventType = CqeEventType(rawValue:Int(bitPattern) >> 32) // shift out the fd
            let result = cqes[0]!.pointee.res

            if (result > 0) {
                assert(bitPattern > 0, "Bitpattern should never be zero")

                _debugPrint("io_uring_wait_cqe fd[\(fd)] eventType[\(String(describing:eventType))] bitPattern[\(bitPattern)]  cqes[0]!.pointee.res[\(String(describing:cqes[0]!.pointee.res))]")

                count = 1
                events[0].fd = fd
                events[0].pollMask = UInt32(cqes[0]!.pointee.res)
            } else {
                _debugPrint("io_uring_wait_cqe non-positive result fd[\(fd)] eventType[\(String(describing:eventType))] bitPattern[\(bitPattern)] cqes[0]!.pointee.res[\(String(describing:cqes[0]!.pointee.res))]")
            }
            CNIOLinux.io_uring_cqe_seen(&ring, cqes[0])
        }
        else
        {
            if (error == -CNIOLinux.EINTR) // we can get EINTR normally
            {
                _debugPrint("UringError.error \(error)")
            } else
            {
                _debugPrint("UringError.uringWaitCqeFailure \(error)")
                throw UringError.uringWaitCqeFailure
            }
        }
        
        return count
    }

    internal func io_uring_wait_cqe_timeout(events: UnsafeMutablePointer<UringEvent>, maxevents: UInt32, timeout: TimeAmount) throws -> Int {
        var ts = timeout.kernelTimespec()
        var count = 0

        _debugPrint("io_uring_wait_cqe_timeout.ETIME milliseconds \(ts)")

        let error = CNIOLinux_io_uring_wait_cqe_timeout(&ring, cqes, &ts)

        switch error {
            case 0:
                dumpCqes("io_uring_wait_cqe_timeout")
                let bitPattern : UInt = UInt(bitPattern:io_uring_cqe_get_data(cqes[0]))
                let fd = Int32(bitPattern & 0x00000000FFFFFFFF)
                let eventType = CqeEventType(rawValue:Int(bitPattern) >> 32) // shift out the fd
                let result = cqes[0]!.pointee.res

                if (result > 0) {
                    _debugPrint("io_uring_wait_cqe_timeout fd[\(fd)] eventType[\(String(describing:eventType))] bitPattern[\(bitPattern)] cqes[0]!.pointee.res[\(String(describing:cqes[0]!.pointee.res))]")

                    count = 1
                    events[0].fd = fd
                    events[0].pollMask = UInt32(cqes[0]!.pointee.res)
                } else {
                    _debugPrint("io_uring_wait_cqe_timeout non-positive result fd[\(fd)] eventType[\(String(describing:eventType))]  bitPattern[\(bitPattern)] cqes[0]!.pointee.res[\(String(describing:cqes[0]!.pointee.res))]")
                }
                
                CNIOLinux.io_uring_cqe_seen(&ring, cqes[0])
            case -CNIOLinux.ETIME: // timed out
                _debugPrint("io_uring_wait_cqe_timeout timed out with -CNIOLinux.ETIME")
                CNIOLinux.io_uring_cqe_seen(&ring, cqes[0])
            case -CNIOLinux.EINTR:
                break
            default:
                throw UringError.uringWaitCqeTimeoutFailure
        }
        
        return count
    }
}

#endif
