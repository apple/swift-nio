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

import NIOCore

#if SWIFTNIO_USE_IO_URING && os(Linux)

import CNIOLinux

/// Represents the `poll` filters/events we might use from io_uring:
///
///  - `hangup` corresponds to `POLLHUP`
///  - `readHangup` corresponds to `POLLRDHUP`
///  - `input` corresponds to `POLLIN`
///  - `output` corresponds to `POLLOUT`
///  - `error` corresponds to `POLLERR`
private struct URingFilterSet: OptionSet, Equatable {
    typealias RawValue = UInt8

    let rawValue: RawValue

    static let _none = URingFilterSet([])
    static let hangup = URingFilterSet(rawValue: 1 << 0)
    static let readHangup = URingFilterSet(rawValue: 1 << 1)
    static let input = URingFilterSet(rawValue: 1 << 2)
    static let output = URingFilterSet(rawValue: 1 << 3)
    static let error = URingFilterSet(rawValue: 1 << 4)

    init(rawValue: RawValue) {
        self.rawValue = rawValue
    }
}

extension URingFilterSet {
    /// Convert NIO's `SelectorEventSet` set to a `URingFilterSet`
    init(selectorEventSet: SelectorEventSet) {
        var thing: URingFilterSet = [.error, .hangup]
        if selectorEventSet.contains(.read) {
            thing.formUnion(.input)
        }
        if selectorEventSet.contains(.write) {
            thing.formUnion(.output)
        }
        if selectorEventSet.contains(.readEOF) {
            thing.formUnion(.readHangup)
        }
        self = thing
    }
}

extension SelectorEventSet {
    var uringEventSet: UInt32 {
        assert(self != ._none)
        // POLLERR | POLLHUP is always set unconditionally anyway but it's easier to understand if we explicitly ask.
        var filter: UInt32 = URing.POLLERR | URing.POLLHUP
        let uringFilters = URingFilterSet(selectorEventSet: self)
        if uringFilters.contains(.input) {
            filter |= URing.POLLIN
        }
        if uringFilters.contains(.output) {
            filter |= URing.POLLOUT
        }
        if uringFilters.contains(.readHangup) {
            filter |= URing.POLLRDHUP
        }
        assert(filter & URing.POLLHUP != 0) // both of these are reported
        assert(filter & URing.POLLERR != 0) // always and can't be masked.
        return filter
    }

    fileprivate init(uringEvent: UInt32) {
        var selectorEventSet: SelectorEventSet = ._none
        if uringEvent & URing.POLLIN != 0 {
            selectorEventSet.formUnion(.read)
        }
        if uringEvent & URing.POLLOUT != 0 {
            selectorEventSet.formUnion(.write)
        }
        if uringEvent & URing.POLLRDHUP != 0 {
            selectorEventSet.formUnion(.readEOF)
        }
        if uringEvent & URing.POLLHUP != 0 || uringEvent & URing.POLLERR != 0 {
            selectorEventSet.formUnion(.reset)
        }
        self = selectorEventSet
    }
}

extension Selector: _SelectorBackendProtocol {
    internal func _debugPrint(_ s: @autoclosure () -> String) {
        #if SWIFTNIO_IO_URING_DEBUG_SELECTOR
        print("S [\(NIOThread.current)] " + s())
        #endif
    }

    func initialiseState0() throws {
        try ring.queue_init()
        self.selectorFD = ring.fd

        // eventfd are always singleshot and re-register each time around
        // as certain use cases of nio seems to generate superfluous wakeups.
        // (at least its tested for that in some of the performance tests
        // e.g. future_whenallsucceed_100k_deferred_off_loop, future_whenallcomplete_100k_deferred_off_loop
        // ) - if using normal ET multishots, we would get 100k events to handle basically.
        // so using single shot for wakeups makes those tests run 30-35% faster approx.

        self.eventFD = try EventFd.eventfd(initval: 0, flags: Int32(EventFd.EFD_CLOEXEC | EventFd.EFD_NONBLOCK))

        ring.prep_poll_add(fileDescriptor: self.eventFD,
                           pollMask: URing.POLLIN,
                           registrationID:SelectorRegistrationID(rawValue: 0),
                           multishot:false) // wakeups

        self.lifecycleState = .open
        _debugPrint("URingSelector up and running fd [\(self.selectorFD)] wakeups on event_fd [\(self.eventFD)]")
    }

    func deinitAssertions0() {
        assert(self.eventFD == -1, "self.eventFD == \(self.eventFD) on deinitAssertions0 deinit, forgot close?")
    }

    func register0<S: Selectable>(selectable: S,
                                  fileDescriptor: CInt,
                                  interested: SelectorEventSet,
                                  registrationID: SelectorRegistrationID) throws {
        _debugPrint("register0: interested \(interested) uringEventSet [\(interested.uringEventSet)] registrationID[\(registrationID)]")
        ring.prep_poll_add(fileDescriptor: fileDescriptor,
                           pollMask: interested.uringEventSet,
                           registrationID: registrationID,
                           multishot: multishot)
    }

    func reregister0<S: Selectable>(selectable: S,
                                    fileDescriptor: CInt,
                                    oldInterested: SelectorEventSet,
                                    newInterested: SelectorEventSet,
                                    registrationID: SelectorRegistrationID) throws {
        _debugPrint("Re-register0: old \(oldInterested) new \(newInterested) uringEventSet [\(oldInterested.uringEventSet)] reg.uringEventSet [\(newInterested.uringEventSet)]")
        if multishot {
            ring.poll_update(fileDescriptor: fileDescriptor,
                             newPollMask: newInterested.uringEventSet,
                             oldPollMask: oldInterested.uringEventSet,
                             registrationID: registrationID,
                             multishot: true)
        } else {
            ring.prep_poll_remove(fileDescriptor: fileDescriptor,
                                  pollMask: oldInterested.uringEventSet,
                                  registrationID: registrationID,
                                  link: true) // next event linked will cancel if this event fails

            ring.prep_poll_add(fileDescriptor: fileDescriptor,
                               pollMask: newInterested.uringEventSet,
                               registrationID: registrationID,
                               multishot: false)
        }
    }

    func deregister0<S: Selectable>(selectable: S, fileDescriptor: CInt, oldInterested: SelectorEventSet, registrationID: SelectorRegistrationID) throws {
        _debugPrint("deregister0: interested \(selectable) reg.interested.uringEventSet [\(oldInterested.uringEventSet)]")
        ring.prep_poll_remove(fileDescriptor: fileDescriptor,
                              pollMask: oldInterested.uringEventSet,
                              registrationID: registrationID)
    }

    func writeAsync0(fileDescriptor: CInt, pointer: UnsafeRawBufferPointer, registrationID: SelectorRegistrationID) throws {
        ring.prep_write(fileDescriptor: fileDescriptor,
                        pointer: pointer,
                        registrationID: registrationID)
    }

    func writeAsync0(fileDescriptor: CInt, iovecs: UnsafeBufferPointer<IOVector>, registrationID: SelectorRegistrationID) throws {
        ring.prep_writev(fileDescriptor: fileDescriptor,
                         iovecs: iovecs,
                         registrationID: registrationID)
    }

    func sendFileAsync0(fileDescriptor: CInt, src: CInt, offset: Int64, count: UInt32, registrationID: SelectorRegistrationID) throws {
        let pipe = try pipeCache.get()
        ring.prep_sendfile(fileDescriptor, src, offset, count, registrationID, pipe)
    }

    func sendmsgAsync0(fileDescriptor: CInt, msghdr: UnsafePointer<msghdr>, registrationID: SelectorRegistrationID) throws {
        ring.prep_sendmsg(fileDescriptor, msghdr, registrationID)
    }

    private func shouldRefreshPollForEvent(selectorEvent:SelectorEventSet) -> Bool {
        if selectorEvent.contains(.read) {
            // as we don't do exhaustive reads, we need to prod the kernel for
            // new events, would be even better if we knew if we had read all there is
            return true
        }
        // If the event is fully handled, we can return false to avoid reregistration for multishot polls.
        return false
    }

    /// Apply the given `SelectorStrategy` and execute `body` once it's complete (which may produce `SelectorEvent`s to handle).
    ///
    /// - parameters:
    ///     - strategy: The `SelectorStrategy` to apply
    ///     - body: The function to execute for each `SelectorEvent` that was produced.
    func whenReady0(strategy: SelectorStrategy, onLoopBegin loopStart: () -> Void, _ body: (SelectorEvent<R>) throws -> Void) throws -> Void {
        assert(self.myThread == NIOThread.current)
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't call whenReady for selector as it's \(self.lifecycleState).")
        }

        ring.flush()

        var ready: Int = 0
        switch strategy {
        case .now:
            _debugPrint(#function + ": now")
            var pendingSQEs = 0
            ready = ring.peekBatchCQE(events: events, maxEvents: eventsCapacity, pendingSQEs: &pendingSQEs, multishot: self.multishot)
        case .blockUntilTimeout(let timeAmount):
            _debugPrint(#function + ": until \(timeAmount)")
            ready = try ring.waitCQE(events: events, timeout: timeAmount, multishot: multishot)
        case .block:
            _debugPrint(#function + ": block")
            var pendingSQEs = 0
            ready = ring.peekBatchCQE(events: events, maxEvents: eventsCapacity, pendingSQEs: &pendingSQEs, multishot: self.multishot) // first try to consume any existing
            if (ready <= 0) {
                // otherwise block (only single supported, but we will use batch peek cqe next run around...
                if pendingSQEs > 0 {
                    ring.flush()
                }
                ready = try ring.waitCQE(events: events, multishot: multishot)
            }
        }

        loopStart()

        for i in 0..<ready {
            let event = events[i]

            if event.fd == self.eventFD {

                _debugPrint("wakeup successful for event.fd [\(event.fd)]")
                var val = EventFd.eventfd_t()
                ring.prep_poll_add(fileDescriptor: self.eventFD,
                                   pollMask: URing.POLLIN,
                                   registrationID: SelectorRegistrationID(rawValue: 0),
                                   multishot: false)
                do {
                    _ = try EventFd.eventfd_read(fd: self.eventFD, value: &val) // consume wakeup event
                    _debugPrint("read val [\(val)] from event.fd [\(event.fd)]")
                } catch  {
                }
            }
            else if let registration = registrations[Int(event.fd)] {

                _debugPrint("We found a registration for event.fd [\(event.fd)]") // \(registration)

                // The io_uring backend only has 16 bits available for the registration id
                guard event.registrationID == UInt16(truncatingIfNeeded: registration.registrationID.rawValue) else {
                    _debugPrint("The event.registrationID [\(event.registrationID)] !=  registration.selectableregistrationID [\(registration.registrationID)], skipping to next event")
                    continue
                }

                switch event.type {
                    case ._none:
                        assert(false)
                        _debugPrint("internal error")
                    case .poll(let pollMask, let pollCancelled):
                        var selectorEventSet = SelectorEventSet(uringEvent: pollMask)

                        _debugPrint("selectorEventSet[\(selectorEventSet)] registration.interested [\(registration.interested)]")

                        // we only want what the user is currently registered for & what we got
                        selectorEventSet = selectorEventSet.intersection(registration.interested)

                        _debugPrint("intersection[\(selectorEventSet)]")

                        if selectorEventSet.contains(.readEOF) {
                            _debugPrint("selectorEventSet.contains(.readEOF) [\(selectorEventSet.contains(.readEOF))]")
                        }

                        if multishot == false { // must be before guard, otherwise lost wake
                            ring.prep_poll_add(fileDescriptor: event.fd,
                                               pollMask: registration.interested.uringEventSet,
                                               registrationID: registration.registrationID,
                                               multishot: false)

                            if pollCancelled {
                                _debugPrint("Received event.pollCancelled")
                            }
                        }

                        guard selectorEventSet != ._none else {
                            _debugPrint("selectorEvent != ._none / [\(selectorEventSet)] [\(registration.interested)] [\(selectorEventSet)]")
                            continue
                        }

                        // This is only needed due to the edge triggered nature of liburing, possibly
                        // we can get away with only updating (force triggering an event if available) for
                        // partial reads (where we currently give up after N iterations)
                        if multishot && self.shouldRefreshPollForEvent(selectorEvent: selectorEventSet) { // can be after guard as it is multishot
                            ring.poll_update(fileDescriptor: event.fd,
                                             newPollMask: registration.interested.uringEventSet,
                                             oldPollMask: registration.interested.uringEventSet,
                                             registrationID: registration.registrationID)
                        }

                        let selectorEvent = SelectorEvent(registration: registration, type: .io(selectorEventSet))
                        _debugPrint("running body \(selectorEvent)")
                        try body(selectorEvent)

                    case .write(let result):
                        let selectorEvent = SelectorEvent(registration: registration, type: .asyncWriteResult(result))
                        _debugPrint("running body \(selectorEvent)")
                        try body(selectorEvent)
                }
            }
            else { // remove any polling if we don't have a registration for it
                _debugPrint("We had no registration for event [\(event)]")
                if multishot == false {
                    switch event.type {
                        case .poll(let pollMask, _):
                            ring.prep_poll_remove(fileDescriptor: event.fd,
                                                        pollMask: pollMask,
                                                  registrationID: SelectorRegistrationID(rawValue: UInt32(event.registrationID)))
                        default:
                            break
                    }
                }
            }
        }

        growEventArrayIfNeeded(ready: ready)
    }

    /// Close the `Selector`.
    ///
    /// After closing the `Selector` it's no longer possible to use it.
    public func close0() throws {
        self.externalSelectorFDLock.withLock {
            // We try! all of the closes because close can only fail in the following ways:
            // - EINTR, which we eat in Posix.close
            // - EIO, which can only happen for on-disk files
            // - EBADF, which can't happen here because we would crash as EBADF is marked unacceptable
            // Therefore, we assert here that close will always succeed and if not, that's a NIO bug we need to know
            // about.

            ring.queue_exit() // This closes the ring selector fd for us
            self.selectorFD = -1

            try! Posix.close(descriptor: self.eventFD)
            self.eventFD = -1
        }
        return
    }

    /* attention, this may (will!) be called from outside the event loop, ie. can't access mutable shared state (such as `self.open`) */
    func wakeup0() throws {
        assert(NIOThread.current != self.myThread)
        try self.externalSelectorFDLock.withLock {
                guard self.eventFD >= 0 else {
                    throw EventLoopError.shutdown
                }
                _ = try EventFd.eventfd_write(fd: self.eventFD, value: 1)
        }
    }
}

#endif
