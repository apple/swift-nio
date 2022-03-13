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

#if SWIFTNIO_USE_IO_URING
#if os(Linux) || os(Android)

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
        try ring.io_uring_queue_init()
        self.selectorFD = ring.fd

        // eventfd are always singleshot and re-register each time around
        // as certain use cases of nio seems to generate superfluous wakeups.
        // (at least its tested for that in some of the performance tests
        // e.g. future_whenallsucceed_100k_deferred_off_loop, future_whenallcomplete_100k_deferred_off_loop
        // ) - if using normal ET multishots, we would get 100k events to handle basically.
        // so using single shot for wakeups makes those tests run 30-35% faster approx.

        self.eventFD = try EventFd.eventfd(initval: 0, flags: Int32(EventFd.EFD_CLOEXEC | EventFd.EFD_NONBLOCK))

        ring.io_uring_prep_poll_add(fileDescriptor: self.eventFD,
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
        _debugPrint("register interested \(interested) uringEventSet [\(interested.uringEventSet)] registrationID[\(registrationID)]")
        self.deferredReregistrationsPending = true
        ring.io_uring_prep_poll_add(fileDescriptor: fileDescriptor,
                                    pollMask: interested.uringEventSet,
                                    registrationID: registrationID,
                                    submitNow: !deferReregistrations,
                                    multishot: multishot)
    }

    func reregister0<S: Selectable>(selectable: S,
                                    fileDescriptor: CInt,
                                    oldInterested: SelectorEventSet,
                                    newInterested: SelectorEventSet,
                                    registrationID: SelectorRegistrationID) throws {
        _debugPrint("Re-register old \(oldInterested) new \(newInterested) uringEventSet [\(oldInterested.uringEventSet)] reg.uringEventSet [\(newInterested.uringEventSet)]")

        self.deferredReregistrationsPending = true
        if multishot {
            ring.io_uring_poll_update(fileDescriptor: fileDescriptor,
                                      newPollmask: newInterested.uringEventSet,
                                      oldPollmask: oldInterested.uringEventSet,
                                      registrationID: registrationID,
                                      submitNow: !deferReregistrations,
                                      multishot: true)
        } else {
            ring.io_uring_prep_poll_remove(fileDescriptor: fileDescriptor,
                                           pollMask: oldInterested.uringEventSet,
                                           registrationID: registrationID,
                                           submitNow:!deferReregistrations,
                                           link: true) // next event linked will cancel if this event fails

            ring.io_uring_prep_poll_add(fileDescriptor: fileDescriptor,
                                        pollMask: newInterested.uringEventSet,
                                        registrationID: registrationID,
                                        submitNow: !deferReregistrations,
                                        multishot: false)
        }
    }

    func deregister0<S: Selectable>(selectable: S, fileDescriptor: CInt, oldInterested: SelectorEventSet, registrationID: SelectorRegistrationID) throws {
        _debugPrint("deregister interested \(selectable) reg.interested.uringEventSet [\(oldInterested.uringEventSet)]")

        self.deferredReregistrationsPending = true
        ring.io_uring_prep_poll_remove(fileDescriptor: fileDescriptor,
                                       pollMask: oldInterested.uringEventSet,
                                       registrationID: registrationID,
                                       submitNow:!deferReregistrations)
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

        var ready: Int = 0

        // flush reregistration of pending modifications if needed (nop in SQPOLL mode)
        // basically this elides all reregistrations and deregistrations into a single
        // syscall instead of one for each. Future improvement would be to also merge
        // the pending pollmasks (now each change will be queued, but we could also
        // merge the masks for reregistrations) - but the most important thing is to
        // only trap into the kernel once for the set of changes, so needs to be measured.
        if deferReregistrations && self.deferredReregistrationsPending {
            self.deferredReregistrationsPending = false
            ring.io_uring_flush()
        }

        switch strategy {
        case .now:
            _debugPrint("whenReady.now")
            ready = Int(ring.io_uring_peek_batch_cqe(events: events, maxevents: UInt32(eventsCapacity), multishot:multishot))
        case .blockUntilTimeout(let timeAmount):
            _debugPrint("whenReady.blockUntilTimeout")
            ready = try Int(ring.io_uring_wait_cqe_timeout(events: events, maxevents: UInt32(eventsCapacity), timeout:timeAmount, multishot:multishot))
        case .block:
            _debugPrint("whenReady.block")
            ready = Int(ring.io_uring_peek_batch_cqe(events: events, maxevents: UInt32(eventsCapacity), multishot:multishot)) // first try to consume any existing

            if (ready <= 0)   // otherwise block (only single supported, but we will use batch peek cqe next run around...
            {
                ready = try ring.io_uring_wait_cqe(events: events, maxevents: UInt32(eventsCapacity), multishot:multishot)
            }
        }

        loopStart()

        for i in 0..<ready {
            let event = events[i]

            switch event.fd {
            case self.eventFD: // we don't run these as multishots to avoid tons of events when many wakeups are done
                    _debugPrint("wakeup successful for event.fd [\(event.fd)]")
                    var val = EventFd.eventfd_t()
                    ring.io_uring_prep_poll_add(fileDescriptor: self.eventFD,
                                                pollMask: URing.POLLIN,
                                                registrationID: SelectorRegistrationID(rawValue: 0),
                                                submitNow: false,
                                                multishot: false)
                    do {
                        _ = try EventFd.eventfd_read(fd: self.eventFD, value: &val) // consume wakeup event
                        _debugPrint("read val [\(val)] from event.fd [\(event.fd)]")
                    } catch  {
                    }
            default:
                if let registration = registrations[Int(event.fd)] {

                    _debugPrint("We found a registration for event.fd [\(event.fd)]") // \(registration)

                    // The io_uring backend only has 16 bits available for the registration id
                    guard event.registrationID == UInt16(truncatingIfNeeded:registration.registrationID.rawValue) else {
                        _debugPrint("The event.registrationID [\(event.registrationID)] !=  registration.selectableregistrationID [\(registration.registrationID)], skipping to next event")
                        continue
                    }

                    var selectorEvent = SelectorEventSet(uringEvent: event.pollMask)

                    _debugPrint("selectorEvent [\(selectorEvent)] registration.interested [\(registration.interested)]")

                    // we only want what the user is currently registered for & what we got
                    selectorEvent = selectorEvent.intersection(registration.interested)

                    _debugPrint("intersection [\(selectorEvent)]")

                    if selectorEvent.contains(.readEOF) {
                       _debugPrint("selectorEvent.contains(.readEOF) [\(selectorEvent.contains(.readEOF))]")
                    }

                    if multishot == false { // must be before guard, otherwise lost wake
                        ring.io_uring_prep_poll_add(fileDescriptor: event.fd,
                                                    pollMask: registration.interested.uringEventSet,
                                                    registrationID: registration.registrationID,
                                                    submitNow: false,
                                                    multishot: false)

                        if event.pollCancelled {
                            _debugPrint("Received event.pollCancelled")
                        }
                    }

                    guard selectorEvent != ._none else {
                        _debugPrint("selectorEvent != ._none / [\(selectorEvent)] [\(registration.interested)] [\(SelectorEventSet(uringEvent: event.pollMask))] [\(event.pollMask)] [\(event.fd)]")
                        continue
                    }

                    // This is only needed due to the edge triggered nature of liburing, possibly
                    // we can get away with only updating (force triggering an event if available) for
                    // partial reads (where we currently give up after N iterations)
                    if multishot && self.shouldRefreshPollForEvent(selectorEvent:selectorEvent) { // can be after guard as it is multishot
                        ring.io_uring_poll_update(fileDescriptor: event.fd,
                                                  newPollmask: registration.interested.uringEventSet,
                                                  oldPollmask: registration.interested.uringEventSet,
                                                  registrationID: registration.registrationID,
                                                  submitNow: false)
                    }

                    _debugPrint("running body [\(NIOThread.current)] \(selectorEvent) \(SelectorEventSet(uringEvent: event.pollMask))")

                    try body((SelectorEvent(io: selectorEvent, registration: registration)))

               } else { // remove any polling if we don't have a registration for it
                    _debugPrint("We had no registration for event.fd [\(event.fd)] event.pollMask [\(event.pollMask)] event.registrationID [\(event.registrationID)], it should be deregistered already")
                    if multishot == false {
                        ring.io_uring_prep_poll_remove(fileDescriptor: event.fd,
                                                       pollMask: event.pollMask,
                                                       registrationID: SelectorRegistrationID(rawValue: UInt32(event.registrationID)),
                                                       submitNow: false)
                    }
                }
            }
        }

        self.deferredReregistrationsPending = false // none pending as we will flush here
        ring.io_uring_flush() // flush reregisteration of the polls if needed (nop in SQPOLL mode)
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

            ring.io_uring_queue_exit() // This closes the ring selector fd for us
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

#endif
