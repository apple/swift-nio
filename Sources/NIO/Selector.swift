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

import NIOConcurrencyHelpers

private enum SelectorLifecycleState {
    case open
    case closing
    case closed
}

private extension timespec {
    init(timeAmount amount: TimeAmount) {
        let nsecPerSec: Int64 = 1_000_000_000
        let ns = amount.nanoseconds
        let sec = ns / nsecPerSec
        self = timespec(tv_sec: Int(sec), tv_nsec: Int(ns - sec * nsecPerSec))
    }
}

private extension Optional {
    func withUnsafeOptionalPointer<T>(_ body: (UnsafePointer<Wrapped>?) throws -> T) rethrows -> T {
        if var this = self {
            return try withUnsafePointer(to: &this) { x in
                try body(x)
            }
        } else {
            return try body(nil)
        }
    }
}

/// Represents IO events NIO might be interested in. `SelectorEventSet` is used for two purposes:
///  1. To express interest in a given event set and
///  2. for notifications about an IO event set that has occured.
///
/// For example, if you were interested in reading and writing data from/to a socket and also obviously if the socket
/// receives a connection reset, express interest with `[.read, .write, .reset]`.
/// If then suddenly the socket becomes both readable and writable, the eventing mechanism will tell you about that
/// fact using `[.read, .write]`.
struct SelectorEventSet: OptionSet, Equatable {

    typealias RawValue = UInt8

    let rawValue: RawValue

    /// It's impossible to actually register for no events, therefore `_none` should only be used to bootstrap a set
    /// of flags or to compare against spurious wakeups.
    static let _none = SelectorEventSet([])

    /// Connection reset or other errors.
    static let reset = SelectorEventSet(rawValue: 1 << 0)

    /// EOF at the read/input end of a `Selectable`.
    static let readEOF = SelectorEventSet(rawValue: 1 << 1)

    /// Interest in/availability of data to be read
    static let read = SelectorEventSet(rawValue: 1 << 2)

    /// Interest in/availability of data to be written
    static let write = SelectorEventSet(rawValue: 1 << 3)

    /// EOF at the write/output end of a `Selectable`.
    ///
    /// - note: This is rarely used because in many cases, there is no signal that this happened.
    static let writeEOF = SelectorEventSet(rawValue: 1 << 4)

    init(rawValue: SelectorEventSet.RawValue) {
        self.rawValue = rawValue
    }
}

/// Represents the `kqueue` filters we might use:
///
///  - `except` corresponds to `EVFILT_EXCEPT`
///  - `read` corresponds to `EVFILT_READ`
///  - `write` corresponds to `EVFILT_WRITE`
private struct KQueueEventFilterSet: OptionSet, Equatable {
    typealias RawValue = UInt8

    let rawValue: RawValue

    static let _none = KQueueEventFilterSet([])
    // skipping `1 << 0` because kqueue doesn't have a direct match for `.reset` (`EPOLLHUP` for epoll)
    static let except = KQueueEventFilterSet(rawValue: 1 << 1)
    static let read = KQueueEventFilterSet(rawValue: 1 << 2)
    static let write = KQueueEventFilterSet(rawValue: 1 << 3)

    init(rawValue: RawValue) {
        self.rawValue = rawValue
    }
}

/// Represents the `epoll` filters/events we might use:
///
///  - `hangup` corresponds to `EPOLLHUP`
///  - `readHangup` corresponds to `EPOLLRDHUP`
///  - `input` corresponds to `EPOLLIN`
///  - `output` corresponds to `EPOLLOUT`
///  - `error` corresponds to `EPOLLERR`
private struct EpollFilterSet: OptionSet, Equatable {
    typealias RawValue = UInt8

    let rawValue: RawValue

    static let _none = EpollFilterSet([])
    static let hangup = EpollFilterSet(rawValue: 1 << 0)
    static let readHangup = EpollFilterSet(rawValue: 1 << 1)
    static let input = EpollFilterSet(rawValue: 1 << 2)
    static let output = EpollFilterSet(rawValue: 1 << 3)
    static let error = EpollFilterSet(rawValue: 1 << 4)

    init(rawValue: RawValue) {
        self.rawValue = rawValue
    }
}

/// Represents the `poll` filters/events we might use from io_uring:
///
///  - `hangup` corresponds to `POLLHUP`
///  - `readHangup` corresponds to `POLLRDHUP`
///  - `input` corresponds to `POLLIN`
///  - `output` corresponds to `POLLOUT`
///  - `error` corresponds to `POLLERR`
private struct UringFilterSet: OptionSet, Equatable {
    typealias RawValue = UInt8

    let rawValue: RawValue

    static let _none = UringFilterSet([])
    static let hangup = UringFilterSet(rawValue: 1 << 0)
    static let readHangup = UringFilterSet(rawValue: 1 << 1)
    static let input = UringFilterSet(rawValue: 1 << 2)
    static let output = UringFilterSet(rawValue: 1 << 3)
    static let error = UringFilterSet(rawValue: 1 << 4)

    init(rawValue: RawValue) {
        self.rawValue = rawValue
    }
}

internal let isEarlyEOFDeliveryWorkingOnThisOS: Bool = {
    #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
    return false // rdar://53656794 , once fixed we need to do an OS version check here.
    #else
    return true
    #endif
}()

extension KQueueEventFilterSet {
    /// Convert NIO's `SelectorEventSet` set to a `KQueueEventFilterSet`
    init(selectorEventSet: SelectorEventSet) {
        var kqueueFilterSet: KQueueEventFilterSet = .init(rawValue: 0)
        if selectorEventSet.contains(.read) {
            kqueueFilterSet.formUnion(.read)
        }

        if selectorEventSet.contains(.write) {
            kqueueFilterSet.formUnion(.write)
        }

        if isEarlyEOFDeliveryWorkingOnThisOS && selectorEventSet.contains(.readEOF) {
            kqueueFilterSet.formUnion(.except)
        }
        self = kqueueFilterSet
    }

    #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
    /// Calculate the kqueue filter changes that are necessary to transition from `previousKQueueFilterSet` to `self`.
    /// The `body` closure is then called with the changes necessary expressed as a number of `kevent`.
    ///
    /// - parameters:
    ///    - previousKQueueFilterSet: The previous filter set that is currently registered with kqueue.
    ///    - fileDescriptor: The file descriptor the `kevent`s should be generated to.
    ///    - body: The closure that will then apply the change set.
    func calculateKQueueFilterSetChanges(previousKQueueFilterSet: KQueueEventFilterSet,
                                         fileDescriptor: CInt,
                                         _ body: (UnsafeMutableBufferPointer<kevent>) throws -> Void) rethrows {
        // we only use three filters (EVFILT_READ, EVFILT_WRITE and EVFILT_EXCEPT) so the number of changes would be 3.
        var keventsHopefullyOnStack = (kevent(), kevent(), kevent())
        try withUnsafeMutableBytes(of: &keventsHopefullyOnStack) { rawPtr in
            assert(MemoryLayout<kevent>.size * 3 == rawPtr.count)
            let keventBuffer = rawPtr.baseAddress!.bindMemory(to: kevent.self, capacity: 3)

            let differences = previousKQueueFilterSet.symmetricDifference(self) // contains all the events that need a change (either need to be added or removed)

            func calculateKQueueChange(event: KQueueEventFilterSet) -> UInt16? {
                guard differences.contains(event) else {
                    return nil
                }
                return UInt16(self.contains(event) ? EV_ADD : EV_DELETE)
            }

            var index: Int = 0
            for (event, filter) in [(KQueueEventFilterSet.read, EVFILT_READ), (.write, EVFILT_WRITE), (.except, EVFILT_EXCEPT)] {
                if let flags = calculateKQueueChange(event: event) {
                    keventBuffer[index].setEvent(fileDescriptor: fileDescriptor, filter: filter, flags: flags)
                    index += 1
                }
            }
            try body(UnsafeMutableBufferPointer(start: keventBuffer, count: index))
        }
    }
    #endif
}

extension EpollFilterSet {
    /// Convert NIO's `SelectorEventSet` set to a `EpollFilterSet`
    init(selectorEventSet: SelectorEventSet) {
        var thing: EpollFilterSet = [.error, .hangup]
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

extension UringFilterSet {
    /// Convert NIO's `SelectorEventSet` set to a `UringFilterSet`
    init(selectorEventSet: SelectorEventSet) {
        var thing: UringFilterSet = [.error, .hangup]
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

#if os(Linux) || os(Android)
    extension SelectorEventSet {
        var epollEventSet: UInt32 {
            assert(self != ._none)
            // EPOLLERR | EPOLLHUP is always set unconditionally anyway but it's easier to understand if we explicitly ask.
            var filter: UInt32 = Epoll.EPOLLERR | Epoll.EPOLLHUP
            let epollFilters = EpollFilterSet(selectorEventSet: self)
            if epollFilters.contains(.input) {
                filter |= Epoll.EPOLLIN
            }
            if epollFilters.contains(.output) {
                filter |= Epoll.EPOLLOUT
            }
            if epollFilters.contains(.readHangup) {
                filter |= Epoll.EPOLLRDHUP
            }
            assert(filter & Epoll.EPOLLHUP != 0) // both of these are reported
            assert(filter & Epoll.EPOLLERR != 0) // always and can't be masked.
            return filter
        }

        fileprivate init(epollEvent: Epoll.epoll_event) {
            var selectorEventSet: SelectorEventSet = ._none
            if epollEvent.events & Epoll.EPOLLIN != 0 {
                selectorEventSet.formUnion(.read)
            }
            if epollEvent.events & Epoll.EPOLLOUT != 0 {
                selectorEventSet.formUnion(.write)
            }
            if epollEvent.events & Epoll.EPOLLRDHUP != 0 {
                selectorEventSet.formUnion(.readEOF)
            }
            if epollEvent.events & Epoll.EPOLLHUP != 0 || epollEvent.events & Epoll.EPOLLERR != 0 {
                selectorEventSet.formUnion(.reset)
            }
            self = selectorEventSet
        }
    }
#endif

#if os(Linux)
    extension SelectorEventSet {
        var uringEventSet: UInt32 {
            assert(self != ._none)
            // POLLERR | POLLHUP is always set unconditionally anyway but it's easier to understand if we explicitly ask.
            var filter: UInt32 = Uring.POLLERR | Uring.POLLHUP
            let uringFilters = UringFilterSet(selectorEventSet: self)
            if uringFilters.contains(.input) {
                filter |= Uring.POLLIN
            }
            if uringFilters.contains(.output) {
                filter |= Uring.POLLOUT
            }
            if uringFilters.contains(.readHangup) {
                filter |= Uring.POLLRDHUP
            }
            assert(filter & Uring.POLLHUP != 0) // both of these are reported
            assert(filter & Uring.POLLERR != 0) // always and can't be masked.
            return filter
        }

        fileprivate init(uringEvent: UInt32) {
            var selectorEventSet: SelectorEventSet = ._none
            if uringEvent & Uring.POLLIN != 0 {
                selectorEventSet.formUnion(.read)
            }
            if uringEvent & Uring.POLLOUT != 0 {
                selectorEventSet.formUnion(.write)
            }
            if uringEvent & Uring.POLLRDHUP != 0 {
                selectorEventSet.formUnion(.readEOF)
            }
            if uringEvent & Uring.POLLHUP != 0 || uringEvent & Uring.POLLERR != 0 {
                selectorEventSet.formUnion(.reset)
            }
            self = selectorEventSet
        }
    }
#endif

///  A `Selector` allows a user to register different `Selectable` sources to an underlying OS selector, and for that selector to notify them once IO is ready for them to process.
///
/// This implementation offers an consistent API over epoll/liburing (for linux) and kqueue (for Darwin, BSD).
/// There are specific subclasses  per API type with a shared common superclass providing overall scaffolding.

/* this is deliberately not thread-safe, only the wakeup() function may be called unprotectedly */
internal class Selector<R: Registration> {
    fileprivate var lifecycleState: SelectorLifecycleState

    fileprivate var registrations = [Int: R]()
    // temporary workaround to stop us delivering outdated events; read in `whenReady`, set in `deregister`
    fileprivate var deregistrationsHappened: Bool = false

    fileprivate let externalSelectorFDLock = Lock()
    // The rules for `self.selectorFD`, `self.eventFD`, and `self.timerFD`:
    // reads: `self.externalSelectorFDLock` OR access from the EventLoop thread
    // writes: `self.externalSelectorFDLock` AND access from the EventLoop thread
    fileprivate var selectorFD: CInt = -1 // -1 == we're closed
    fileprivate let myThread: NIOThread
    fileprivate var currentSelectableSequenceIdentifier : SelectableSequenceIdentifier = 1

    internal func testsOnly_withUnsafeSelectorFD<T>(_ body: (CInt) throws -> T) throws -> T {
        assert(self.myThread != NIOThread.current)
        return try self.externalSelectorFDLock.withLock {
            guard self.selectorFD != -1 else {
                throw EventLoopError.shutdown
            }
            return try body(self.selectorFD)
        }
    }

    internal func _testsOnly_init () { // needed for SAL, don't want to open access for lifecycleState, normal subclasses of Selector sets this in init after calling super.init() and finishing initializing, but SAL can't access due to fileprivate.
        self.lifecycleState = .open
    }

    init() throws {
        self.myThread = NIOThread.current
        self.lifecycleState = .closed
    }
    
    deinit {
        assert(self.registrations.count == 0, "left-over registrations: \(self.registrations)")
        assert(self.lifecycleState == .closed, "Selector \(self.lifecycleState) (expected .closed) on deinit")
        assert(self.selectorFD == -1, "self.selectorFD == \(self.selectorFD) on Selector deinit, forgot close?")
    }
  
    // hooks for platform specific registration activity (ie. kqueue, epoll, uring)
    func _register<S: Selectable>(selectable: S, fd: Int, interested: SelectorEventSet, sequenceIdentifier : UInt32 = 0) throws {
        fatalError("must override")
    }
    
    func _reregister<S: Selectable>(selectable: S, fd: Int, oldInterested: SelectorEventSet, newInterested: SelectorEventSet , sequenceIdentifier : UInt32 = 0) throws {
        fatalError("must override")
    }
    
    func _deregister<S: Selectable>(selectable: S, fd: Int, oldInterested: SelectorEventSet, sequenceIdentifier : UInt32 = 0) throws {
        fatalError("must override")
    }
    
    /// Register `Selectable` on the `Selector`.
    ///
    /// - parameters:
    ///     - selectable: The `Selectable` to register.
    ///     - interested: The `SelectorEventSet` in which we are interested and want to be notified about.
    ///     - makeRegistration: Creates the registration data for the given `SelectorEventSet`.
    func register<S: Selectable>(selectable: S, interested: SelectorEventSet, makeRegistration: (SelectorEventSet) -> R) throws {
        assert(self.myThread == NIOThread.current)
        assert(interested.contains(.reset))
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't register on selector as it's \(self.lifecycleState).")
        }

        try selectable.withUnsafeHandle { fd in
            assert(registrations[Int(fd)] == nil)
            try self._register(selectable : selectable, fd: Int(fd), interested: interested, sequenceIdentifier: currentSelectableSequenceIdentifier)
            var registration = makeRegistration(interested)
            registration.selectableSequenceIdentifier = currentSelectableSequenceIdentifier
            registrations[Int(fd)] = registration
            currentSelectableSequenceIdentifier &+= 1 // we are ok to overflow
        }
    }

    /// Re-register `Selectable`, must be registered via `register` before.
    ///
    /// - parameters:
    ///     - selectable: The `Selectable` to re-register.
    ///     - interested: The `SelectorEventSet` in which we are interested and want to be notified about.
    func reregister<S: Selectable>(selectable: S, interested: SelectorEventSet) throws {
        assert(self.myThread == NIOThread.current)
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't re-register on selector as it's \(self.lifecycleState).")
        }
        assert(interested.contains(.reset), "must register for at least .reset but tried registering for \(interested)")
        try selectable.withUnsafeHandle { fd in
            var reg = registrations[Int(fd)]!
            try self._reregister(selectable : selectable, fd: Int(fd), oldInterested: reg.interested, newInterested: interested, sequenceIdentifier: reg.selectableSequenceIdentifier)
            reg.interested = interested
            registrations[Int(fd)] = reg
        }
    }

    /// Deregister `Selectable`, must be registered via `register` before.
    ///
    /// After the `Selectable is deregistered no `SelectorEventSet` will be produced anymore for the `Selectable`.
    ///
    /// - parameters:
    ///     - selectable: The `Selectable` to deregister.
    func deregister<S: Selectable>(selectable: S) throws {
        assert(self.myThread == NIOThread.current)
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't deregister from selector as it's \(self.lifecycleState).")
        }
        // temporary workaround to stop us delivering outdated events
        self.deregistrationsHappened = true
        try selectable.withUnsafeHandle { fd in
            guard let reg = registrations.removeValue(forKey: Int(fd)) else {
                return
            }
            try self._deregister(selectable: selectable, fd: Int(fd), oldInterested: reg.interested, sequenceIdentifier: reg.selectableSequenceIdentifier)
        }
    }

    /// Apply the given `SelectorStrategy` and execute `body` once it's complete (which may produce `SelectorEvent`s to handle).
    ///
    /// - parameters:
    ///     - strategy: The `SelectorStrategy` to apply
    ///     - body: The function to execute for each `SelectorEvent` that was produced.
    func whenReady(strategy: SelectorStrategy, _ body: (SelectorEvent<R>) throws -> Void) throws -> Void {
        fatalError("must override")
    }

    /// Close the `Selector`.
    ///
    /// After closing the `Selector` it's no longer possible to use it.
    public func close() throws {
        assert(self.myThread == NIOThread.current)
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't close selector as it's \(self.lifecycleState).")
        }
        self.lifecycleState = .closed

        self.registrations.removeAll()
    }

    /* attention, this may (will!) be called from outside the event loop, ie. can't access mutable shared state (such as `self.open`) */
    func wakeup() throws {
        fatalError("must override")
    }
}

/* this is deliberately not thread-safe, only the wakeup() function may be called unprotectedly */
final internal class KqueueSelector<R: Registration>: Selector<R> {
    #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)

    private typealias EventType = kevent
    private var events: UnsafeMutablePointer<EventType>
    private var eventsCapacity = 64

    private static func allocateEventsArray(capacity: Int) -> UnsafeMutablePointer<EventType> {
        let events: UnsafeMutablePointer<EventType> = UnsafeMutablePointer.allocate(capacity: capacity)
        events.initialize(to: EventType())
        return events
    }

    private static func deallocateEventsArray(events: UnsafeMutablePointer<EventType>, capacity: Int) {
        events.deinitialize(count: capacity)
        events.deallocate()
    }

    private func growEventArrayIfNeeded(ready: Int) {
        assert(self.myThread == NIOThread.current)
        guard ready == eventsCapacity else {
            return
        }
        KqueueSelector.deallocateEventsArray(events: events, capacity: eventsCapacity)
        eventsCapacity = ready << 1 // double capacity
        events = KqueueSelector.allocateEventsArray(capacity: eventsCapacity)
    }
    
    override init() throws {
        events = KqueueSelector.allocateEventsArray(capacity: eventsCapacity)

        try super.init()
        
        self.selectorFD = try KQueue.kqueue()
        self.lifecycleState = .open

        var event = kevent()
        event.ident = 0
        event.filter = Int16(EVFILT_USER)
        event.fflags = UInt32(NOTE_FFNOP)
        event.data = 0
        event.udata = nil
        event.flags = UInt16(EV_ADD | EV_ENABLE | EV_CLEAR)
        try withUnsafeMutablePointer(to: &event) { ptr in
            try kqueueApplyEventChangeSet(keventBuffer: UnsafeMutableBufferPointer(start: ptr, count: 1))
        }
    }

    deinit {
        KqueueSelector.deallocateEventsArray(events: events, capacity: eventsCapacity)
    }

    private static func toKQueueTimeSpec(strategy: SelectorStrategy) -> timespec? {
        switch strategy {
        case .block:
            return nil
        case .now:
            return timespec(tv_sec: 0, tv_nsec: 0)
        case .blockUntilTimeout(let nanoseconds):
            // A scheduledTask() specified with a zero or negative timeAmount, will be scheduled immediately
            // and therefore SHOULD NOT result in a kevent being created with a negative or zero timespec.
            precondition(nanoseconds.nanoseconds > 0, "\(nanoseconds) is invalid (0 < nanoseconds)")

            var ts = timespec(timeAmount: nanoseconds)
            // Check that the timespec tv_nsec field conforms to the definition in the C11 standard (ISO/IEC 9899:2011).
            assert((0..<1_000_000_000).contains(ts.tv_nsec), "\(ts) is invalid (0 <= tv_nsec < 1_000_000_000)")

            // The maximum value in seconds supported by the Darwin-kernel interval timer (kern_time.c:itimerfix())
            // (note that - whilst unlikely - this value *could* change).
            let sysIntervalTimerMaxSec = 100_000_000

            // Clamp the timespec tv_sec value to the maximum supported by the Darwin-kernel.
            // Whilst this schedules the event far into the future (several years) it will still be triggered provided
            // the system stays up.
            ts.tv_sec = min(ts.tv_sec, sysIntervalTimerMaxSec)

            return ts
        }
    }

    /// Apply a kqueue changeset by calling the `kevent` function with the `kevent`s supplied in `keventBuffer`.
    private func kqueueApplyEventChangeSet(keventBuffer: UnsafeMutableBufferPointer<kevent>) throws {
        // WARNING: This is called on `self.myThread` OR with `self.externalSelectorFDLock` held.
        // So it MUST NOT touch anything on `self.` apart from constants and `self.selectorFD`.
        guard keventBuffer.count > 0 else {
            // nothing to do
            return
        }
        do {
            try KQueue.kevent(kq: self.selectorFD,
                              changelist: keventBuffer.baseAddress!,
                              nchanges: CInt(keventBuffer.count),
                              eventlist: nil,
                              nevents: 0,
                              timeout: nil)
        } catch let err as IOError {
            if err.errnoCode == EINTR {
                // See https://www.freebsd.org/cgi/man.cgi?query=kqueue&sektion=2
                // When kevent() call fails with EINTR error, all changes in the changelist have been applied.
                return
            }
            throw err
        }
    }

    private func kqueueUpdateEventNotifications<S: Selectable>(selectable: S, interested: SelectorEventSet, oldInterested: SelectorEventSet?) throws {
        assert(self.myThread == NIOThread.current)
        let oldKQueueFilters = KQueueEventFilterSet(selectorEventSet: oldInterested ?? ._none)
        let newKQueueFilters = KQueueEventFilterSet(selectorEventSet: interested)
        assert(interested.contains(.reset))
        assert(oldInterested?.contains(.reset) ?? true)

        try selectable.withUnsafeHandle {
            try newKQueueFilters.calculateKQueueFilterSetChanges(previousKQueueFilterSet: oldKQueueFilters,
                                                                 fileDescriptor: $0,
                                                                 kqueueApplyEventChangeSet)
        }
    }
    
    override func _register<S: Selectable>(selectable: S, fd: Int, interested: SelectorEventSet, sequenceIdentifier : UInt32 = 0) throws {
        try kqueueUpdateEventNotifications(selectable: selectable, interested: interested, oldInterested: nil)
    }

    override func _reregister<S: Selectable>(selectable: S, fd: Int, oldInterested: SelectorEventSet, newInterested: SelectorEventSet, sequenceIdentifier : UInt32 = 0) throws {
        try kqueueUpdateEventNotifications(selectable: selectable, interested: newInterested, oldInterested: oldInterested)
    }
    
    override func _deregister<S: Selectable>(selectable: S, fd: Int, oldInterested: SelectorEventSet, sequenceIdentifier : UInt32 = 0) throws {
        try kqueueUpdateEventNotifications(selectable: selectable, interested: .reset, oldInterested: oldInterested)
    }

    /// Apply the given `SelectorStrategy` and execute `body` once it's complete (which may produce `SelectorEvent`s to handle).
    ///
    /// - parameters:
    ///     - strategy: The `SelectorStrategy` to apply
    ///     - body: The function to execute for each `SelectorEvent` that was produced.
    override func whenReady(strategy: SelectorStrategy, _ body: (SelectorEvent<R>) throws -> Void) throws -> Void {
        assert(self.myThread == NIOThread.current)
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't call whenReady for selector as it's \(self.lifecycleState).")
        }


        let timespec = KqueueSelector.toKQueueTimeSpec(strategy: strategy)
        let ready = try timespec.withUnsafeOptionalPointer { ts in
            Int(try KQueue.kevent(kq: self.selectorFD, changelist: nil, nchanges: 0, eventlist: events, nevents: Int32(eventsCapacity), timeout: ts))
        }

        // start with no deregistrations happened
        self.deregistrationsHappened = false
        // temporary workaround to stop us delivering outdated events; possibly set in `deregister`
        for i in 0..<ready where !self.deregistrationsHappened {
            let ev = events[i]
            let filter = Int32(ev.filter)
            guard Int32(ev.flags) & EV_ERROR == 0 else {
                throw IOError(errnoCode: Int32(ev.data), reason: "kevent returned with EV_ERROR set: \(String(describing: ev))")
            }
            guard filter != EVFILT_USER, let registration = registrations[Int(ev.ident)] else {
                continue
            }
            var selectorEvent: SelectorEventSet = ._none
            switch filter {
            case EVFILT_READ:
                selectorEvent.formUnion(.read)
                fallthrough // falling through here as `EVFILT_READ` also delivers `EV_EOF` (meaning `.readEOF`)
            case EVFILT_EXCEPT:
                if Int32(ev.flags) & EV_EOF != 0 && registration.interested.contains(.readEOF) {
                    // we only add `.readEOF` if it happened and the user asked for it
                    selectorEvent.formUnion(.readEOF)
                }
            case EVFILT_WRITE:
                selectorEvent.formUnion(.write)
            default:
                // We only use EVFILT_USER, EVFILT_READ, EVFILT_EXCEPT and EVFILT_WRITE.
                fatalError("unexpected filter \(ev.filter)")
            }
            if ev.fflags != 0 {
                selectorEvent.formUnion(.reset)
            }
            // we can only verify the events for i == 0 as for i > 0 the user might have changed the registrations since then.
            assert(i != 0 || selectorEvent.isSubset(of: registration.interested), "selectorEvent: \(selectorEvent), registration: \(registration)")

            // in any case we only want what the user is currently registered for & what we got
            selectorEvent = selectorEvent.intersection(registration.interested)

            guard selectorEvent != ._none else {
                continue
            }
            try body((SelectorEvent(io: selectorEvent, registration: registration)))
        }

        growEventArrayIfNeeded(ready: ready)
    }

    /// Close the `Selector`.
    ///
    /// After closing the `Selector` it's no longer possible to use it.
    override public func close() throws {
        try super.close()

        self.externalSelectorFDLock.withLock {
            // We try! all of the closes because close can only fail in the following ways:
            // - EINTR, which we eat in Posix.close
            // - EIO, which can only happen for on-disk files
            // - EBADF, which can't happen here because we would crash as EBADF is marked unacceptable
            // Therefore, we assert here that close will always succeed and if not, that's a NIO bug we need to know
            // about.
            // We limit close to only be for positive FD:s though, as subclasses (e.g. uring)
            // may already have closed some of these FD:s in their close function.
    
            
            try! Posix.close(descriptor: self.selectorFD)
            self.selectorFD = -1
        }
    }

    /* attention, this may (will!) be called from outside the event loop, ie. can't access mutable shared state (such as `self.open`) */
    override func wakeup() throws {
        assert(NIOThread.current != self.myThread)
        try self.externalSelectorFDLock.withLock {
                guard self.selectorFD >= 0 else {
                    throw EventLoopError.shutdown
                }
                var event = kevent()
                event.ident = 0
                event.filter = Int16(EVFILT_USER)
                event.fflags = UInt32(NOTE_TRIGGER | NOTE_FFNOP)
                event.data = 0
                event.udata = nil
                event.flags = 0
                try withUnsafeMutablePointer(to: &event) { ptr in
                    try self.kqueueApplyEventChangeSet(keventBuffer: UnsafeMutableBufferPointer(start: ptr, count: 1))
                }
        }
    }
    #endif
}

final internal class EpollSelector<R: Registration>: Selector<R> {
    #if os(Linux) || os(Android)

    private typealias EventType = Epoll.epoll_event
    private var earliestTimer: NIODeadline = .distantFuture

    private var events: UnsafeMutablePointer<EventType>
    private var eventsCapacity = 64

    // The rules for `self.selectorFD`, `self.eventFD`, and `self.timerFD`:
    // reads: `self.externalSelectorFDLock` OR access from the EventLoop thread
    // writes: `self.externalSelectorFDLock` AND access from the EventLoop thread
    private var eventFD: CInt = -1 // -1 == we're closed
    private var timerFD: CInt = -1 // -1 == we're closed

    private static func allocateEventsArray(capacity: Int) -> UnsafeMutablePointer<EventType> {
        let events: UnsafeMutablePointer<EventType> = UnsafeMutablePointer.allocate(capacity: capacity)
        events.initialize(to: EventType())
        return events
    }

    private static func deallocateEventsArray(events: UnsafeMutablePointer<EventType>, capacity: Int) {
        events.deinitialize(count: capacity)
        events.deallocate()
    }

    private func growEventArrayIfNeeded(ready: Int) {
        assert(self.myThread == NIOThread.current)
        guard ready == eventsCapacity else {
            return
        }
        EpollSelector.deallocateEventsArray(events: events, capacity: eventsCapacity)
        eventsCapacity = ready << 1 // double capacity
        events = EpollSelector.allocateEventsArray(capacity: eventsCapacity)
    }
    
    override init() throws {
        events = EpollSelector.allocateEventsArray(capacity: eventsCapacity)

        try super.init()

        self.selectorFD = try Epoll.epoll_create(size: 128)
        self.eventFD = try EventFd.eventfd(initval: 0, flags: Int32(EventFd.EFD_CLOEXEC | EventFd.EFD_NONBLOCK))
        self.timerFD = try TimerFd.timerfd_create(clockId: CLOCK_MONOTONIC, flags: Int32(TimerFd.TFD_CLOEXEC | TimerFd.TFD_NONBLOCK))

        self.lifecycleState = .open

        var ev = Epoll.epoll_event()
        ev.events = SelectorEventSet.read.epollEventSet
        ev.data.fd = self.eventFD

        try Epoll.epoll_ctl(epfd: self.selectorFD, op: Epoll.EPOLL_CTL_ADD, fd: self.eventFD, event: &ev)

        var timerev = Epoll.epoll_event()
        timerev.events = Epoll.EPOLLIN | Epoll.EPOLLERR | Epoll.EPOLLRDHUP
        timerev.data.fd = self.timerFD
        try Epoll.epoll_ctl(epfd: self.selectorFD, op: Epoll.EPOLL_CTL_ADD, fd: self.timerFD, event: &timerev)
    }

    deinit {
        EpollSelector.deallocateEventsArray(events: events, capacity: eventsCapacity)

        assert(self.eventFD == -1, "self.eventFD == \(self.eventFD) on EpollSelector deinit, forgot close?")
        assert(self.timerFD == -1, "self.timerFD == \(self.timerFD) on EpollSelector deinit, forgot close?")
    }

    override func _register<S: Selectable>(selectable : S, fd: Int, interested: SelectorEventSet, sequenceIdentifier : UInt32 = 0) throws {
        var ev = Epoll.epoll_event()
        ev.events = interested.epollEventSet
        ev.data.fd = Int32(fd)

        try Epoll.epoll_ctl(epfd: self.selectorFD, op: Epoll.EPOLL_CTL_ADD, fd: ev.data.fd, event: &ev)
    }

    override func _reregister<S: Selectable>(selectable : S, fd: Int, oldInterested: SelectorEventSet, newInterested: SelectorEventSet, sequenceIdentifier : UInt32 = 0) throws {
        var ev = Epoll.epoll_event()
        ev.events = newInterested.epollEventSet
        ev.data.fd = Int32(fd)

        _ = try Epoll.epoll_ctl(epfd: self.selectorFD, op: Epoll.EPOLL_CTL_MOD, fd: ev.data.fd, event: &ev)
    }

    override func _deregister<S: Selectable>(selectable: S, fd: Int, oldInterested: SelectorEventSet, sequenceIdentifier : UInt32 = 0) throws {
        var ev = Epoll.epoll_event()
        _ = try Epoll.epoll_ctl(epfd: self.selectorFD, op: Epoll.EPOLL_CTL_DEL, fd: Int32(fd), event: &ev)
    }
    
    /// Apply the given `SelectorStrategy` and execute `body` once it's complete (which may produce `SelectorEvent`s to handle).
    ///
    /// - parameters:
    ///     - strategy: The `SelectorStrategy` to apply
    ///     - body: The function to execute for each `SelectorEvent` that was produced.
    override func whenReady(strategy: SelectorStrategy, _ body: (SelectorEvent<R>) throws -> Void) throws -> Void {
        assert(self.myThread == NIOThread.current)
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't call whenReady for selector as it's \(self.lifecycleState).")
        }
        let ready: Int

        switch strategy {
        case .now:
            ready = Int(try Epoll.epoll_wait(epfd: self.selectorFD, events: events, maxevents: Int32(eventsCapacity), timeout: 0))
        case .blockUntilTimeout(let timeAmount):
            // Only call timerfd_settime if we're not already scheduled one that will cover it.
            // This guards against calling timerfd_settime if not needed as this is generally speaking
            // expensive.
            let next = NIODeadline.now() + timeAmount
            if next < self.earliestTimer {
                self.earliestTimer = next

                var ts = itimerspec()
                ts.it_value = timespec(timeAmount: timeAmount)
                try TimerFd.timerfd_settime(fd: self.timerFD, flags: 0, newValue: &ts, oldValue: nil)
            }
            fallthrough
        case .block:
            ready = Int(try Epoll.epoll_wait(epfd: self.selectorFD, events: events, maxevents: Int32(eventsCapacity), timeout: -1))
        }

        // start with no deregistrations happened
        self.deregistrationsHappened = false
        // temporary workaround to stop us delivering outdated events; possibly set in `deregister`
        for i in 0..<ready where !self.deregistrationsHappened {
            let ev = events[i]
            switch ev.data.fd {
            case self.eventFD:
                var val = EventFd.eventfd_t()
                // Consume event
                _ = try EventFd.eventfd_read(fd: self.eventFD, value: &val)
            case self.timerFD:
                // Consume event
                var val: UInt64 = 0
                // We are not interested in the result
                _ = try! Posix.read(descriptor: self.timerFD, pointer: &val, size: MemoryLayout.size(ofValue: val))

                // Processed the earliest set timer so reset it.
                self.earliestTimer = .distantFuture
            default:
                // If the registration is not in the Map anymore we deregistered it during the processing of whenReady(...). In this case just skip it.
                if let registration = registrations[Int(ev.data.fd)] {
                    var selectorEvent = SelectorEventSet(epollEvent: ev)
                    // we can only verify the events for i == 0 as for i > 0 the user might have changed the registrations since then.
                    assert(i != 0 || selectorEvent.isSubset(of: registration.interested), "selectorEvent: \(selectorEvent), registration: \(registration)")

                    // in any case we only want what the user is currently registered for & what we got
                    selectorEvent = selectorEvent.intersection(registration.interested)

                    guard selectorEvent != ._none else {
                        continue
                    }

                    try body((SelectorEvent(io: selectorEvent, registration: registration)))
                }
            }
        }
        growEventArrayIfNeeded(ready: ready)
    }

    /// Close the `Selector`.
    ///
    /// After closing the `Selector` it's no longer possible to use it.
    override public func close() throws {
        try super.close()

        self.externalSelectorFDLock.withLock {
            // We try! all of the closes because close can only fail in the following ways:
            // - EINTR, which we eat in Posix.close
            // - EIO, which can only happen for on-disk files
            // - EBADF, which can't happen here because we would crash as EBADF is marked unacceptable
            // Therefore, we assert here that close will always succeed and if not, that's a NIO bug we need to know
            // about.
            
            try! Posix.close(descriptor: self.timerFD)
            self.timerFD = -1
            
            try! Posix.close(descriptor: self.eventFD)
            self.eventFD = -1
            
            try! Posix.close(descriptor: self.selectorFD)
            self.selectorFD = -1
        }
    }

    /* attention, this may (will!) be called from outside the event loop, ie. can't access mutable shared state (such as `self.open`) */
    override func wakeup() throws {
        assert(NIOThread.current != self.myThread)
        try self.externalSelectorFDLock.withLock {
                guard self.eventFD >= 0 else {
                    throw EventLoopError.shutdown
                }
                _ = try EventFd.eventfd_write(fd: self.eventFD, value: 1)
        }
    }
    #endif
}

internal func getEnvironmentVar(_ name: String) -> String? {
    guard let rawValue = getenv(name) else { return nil }
    return String(cString: rawValue)
}

struct UringSelectorDebug {
    internal static let _debugPrintEnabled: Bool = {
        getEnvironmentVar("NIO_SELECTOR") != nil
    }()
}

final internal class UringSelector<R: Registration>: Selector<R> {
    #if os(Linux)
    private typealias EventType = UringEvent

    // The rules for `self.selectorFD`, `self.eventFD`, and `self.timerFD`:
    // reads: `self.externalSelectorFDLock` OR access from the EventLoop thread
    // writes: `self.externalSelectorFDLock` AND access from the EventLoop thread
    private var eventFD: CInt = -1 // -1 == we're closed

    private var events: UnsafeMutablePointer<EventType>
    private var eventsCapacity = 64

    var ring = Uring()
    
    // some compile time configurations for testing different approaches
    let multishot = Uring.io_uring_use_multishot_poll() // if true, we run with streaming multishot polls
    let deferReregistrations = true // if true we only flush once at reentring whenReady() - saves syscalls

    var deferredReregistrationsPending = false // true if flush needed when reentring whenReady()

    private static func allocateEventsArray(capacity: Int) -> UnsafeMutablePointer<EventType> {
        let events: UnsafeMutablePointer<EventType> = UnsafeMutablePointer.allocate(capacity: capacity)
        events.initialize(to: EventType(fd:0, pollMask: 0, sequenceIdentifier:0))
        return events
    }

    private static func deallocateEventsArray(events: UnsafeMutablePointer<EventType>, capacity: Int) {
        events.deinitialize(count: capacity)
        events.deallocate()
    }

    private func growEventArrayIfNeeded(ready: Int) {
        assert(self.myThread == NIOThread.current)
        guard ready == eventsCapacity else {
            return
        }
        UringSelector.deallocateEventsArray(events: events, capacity: eventsCapacity)
        eventsCapacity = ready << 1 // double capacity
        events = UringSelector.allocateEventsArray(capacity: eventsCapacity)
    }

    internal func _debugPrint(_ s : @autoclosure () -> String)
    {
        if UringSelectorDebug._debugPrintEnabled {
            print("S [\(NIOThread.current)] " + s())
        }
    }
    
    override init() throws {
        // fail using uring unless it was successfully initialized
        if Uring.initializedUring == false {
            throw UringError.loadFailure
        }
        events = UringSelector.allocateEventsArray(capacity: eventsCapacity)

        try super.init()

        try ring.io_uring_queue_init()
        self.selectorFD = ring.fd()
        self.eventFD = try EventFd.eventfd(initval: 0, flags: Int32(EventFd.EFD_CLOEXEC | EventFd.EFD_NONBLOCK))

        ring.io_uring_prep_poll_add(fd: Int32(self.eventFD), pollMask: Uring.POLLIN, sequenceIdentifier:0, multishot:false) // wakeups

        self.lifecycleState = .open
        _debugPrint("UringSelector up and running fd [\(self.selectorFD)] wakeups on event_fd [\(self.eventFD)]")
    }

    deinit {
        UringSelector.deallocateEventsArray(events: events, capacity: eventsCapacity)

        assert(self.eventFD == -1, "self.eventFD == \(self.eventFD) on UringSelector deinit, forgot close?")
    }

    override func _register<S: Selectable>(selectable : S, fd: Int, interested: SelectorEventSet, sequenceIdentifier : UInt32 = 0) throws {
        _debugPrint("register interested \(interested) uringEventSet [\(interested.uringEventSet)] sequenceIdentifier[\(sequenceIdentifier)]")
        deferredReregistrationsPending = true
        ring.io_uring_prep_poll_add(fd: Int32(fd),
                                    pollMask: interested.uringEventSet,
                                    sequenceIdentifier: sequenceIdentifier,
                                    submitNow: !deferReregistrations,
                                    multishot: multishot)
    }

    override func _reregister<S: Selectable>(selectable : S, fd: Int, oldInterested: SelectorEventSet, newInterested: SelectorEventSet, sequenceIdentifier : UInt32 = 0) throws {
        _debugPrint("Re-register old \(oldInterested) new \(newInterested) uringEventSet [\(oldInterested.uringEventSet)] reg.uringEventSet [\(newInterested.uringEventSet)]")

        deferredReregistrationsPending = true
        if multishot {
            ring.io_uring_poll_update(fd: Int32(fd),
                                      newPollmask: newInterested.uringEventSet,
                                      oldPollmask: oldInterested.uringEventSet,
                                      sequenceIdentifier: sequenceIdentifier,
                                      submitNow: !deferReregistrations,
                                      multishot: true)
        } else {
            ring.io_uring_prep_poll_remove(fd: Int32(fd),
                                           pollMask: oldInterested.uringEventSet,
                                           sequenceIdentifier: sequenceIdentifier,
                                           submitNow:!deferReregistrations,
                                           link: true)
  
            ring.io_uring_prep_poll_add(fd: Int32(fd),
                                        pollMask: newInterested.uringEventSet,
                                        sequenceIdentifier: sequenceIdentifier,
                                        submitNow: !deferReregistrations,
                                        multishot: false)
        }
    }

    override func _deregister<S: Selectable>(selectable: S, fd: Int, oldInterested: SelectorEventSet, sequenceIdentifier : UInt32 = 0) throws {
        _debugPrint("deregister interested \(selectable) reg.interested.uringEventSet [\(oldInterested.uringEventSet)]")

        deferredReregistrationsPending = true
        ring.io_uring_prep_poll_remove(fd: Int32(fd),
                                       pollMask: oldInterested.uringEventSet,
                                       sequenceIdentifier: sequenceIdentifier,
                                       submitNow:!deferReregistrations)
    }

    private func shouldRefreshPollForEvent(selectorEvent:SelectorEventSet) -> Bool {
        if selectorEvent.contains(.read) {
            // as we don't do exhaustive reads, we need to prod the kernel for
            // new events, would be even better if we knew if we had read all there is
            return true
        }
// FIXME: Need to verify that SwiftNIO writes until blocking (exhaustive writing)
        return false
    }

    /// Apply the given `SelectorStrategy` and execute `body` once it's complete (which may produce `SelectorEvent`s to handle).
    ///
    /// - parameters:
    ///     - strategy: The `SelectorStrategy` to apply
    ///     - body: The function to execute for each `SelectorEvent` that was produced.
    override func whenReady(strategy: SelectorStrategy, _ body: (SelectorEvent<R>) throws -> Void) throws -> Void {
        assert(self.myThread == NIOThread.current)
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't call whenReady for selector as it's \(self.lifecycleState).")
        }

        var ready: Int = 0
        
        // flush reregisteration of pending modifications if needed (nop in SQPOLL mode)
        // basically this elides all reregistrations and deregistrations into a single
        // syscall instead of one for each. Future improvement would be to even merge
        // the pending pollmasks (now each change will be queued, but we could also
        // merge the masks for reregistrations) - but the most important thing is to
        // only trap into the kernel once for the set of changes, so needs to be measured.
        if deferReregistrations && deferredReregistrationsPending {
            deferredReregistrationsPending = false
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

        for i in 0..<ready { // we don't use deregistrationsHappened, we use the sequenceIdentifier instead.
            let event = events[i]

            switch event.fd {
            case self.eventFD: // we don't run these as multishots to avoid tons of events when many wakeups are done
                    _debugPrint("wakeup successful for event.fd [\(event.fd)]")
                    var val = EventFd.eventfd_t()
                    ring.io_uring_prep_poll_add(fd: Int32(self.eventFD),
                                                pollMask: Uring.POLLIN,
                                                sequenceIdentifier: 0,
                                                submitNow: false,
                                                multishot: false)
                    do {
                        _ = try EventFd.eventfd_read(fd: self.eventFD, value: &val) // consume wakeup event
                        _debugPrint("read val [\(val)] from event.fd [\(event.fd)]")
                    } catch  { // let errorReturn
                        // FIXME: Add assertion that only EAGAIN is expected here.
                        // assert(errorReturn == EAGAIN, "eventfd_read return unexpected errno \(errorReturn)")
                    }
            default:
                if let registration = registrations[Int(event.fd)] {
                    _debugPrint("We found a registration for event.fd [\(event.fd)]") // \(registration)


                    var selectorEvent = SelectorEventSet(uringEvent: event.pollMask)
                    // let socketClosing = (event.pollMask & (Uring.POLLRDHUP | Uring.POLLHUP | Uring.POLLERR)) > 0 ? true : false

                    // we can only verify the events for i == 0 as for i > 0 the user might have changed the registrations since then.
                    // we can't assert this for uring, as we possibly can get an old pollmask update as the
                    // modifications of registrations are async. the intersection() below handles that case too.
                    // assert(i != 0 || selectorEvent.isSubset(of: registration.interested), "selectorEvent: \(selectorEvent), registration: \(registration)")

                    // in any case we only want what the user is currently registered for & what we got
                    _debugPrint("selectorEvent [\(selectorEvent)] registration.interested [\(registration.interested)]")
                    selectorEvent = selectorEvent.intersection(registration.interested)
                    _debugPrint("intersection [\(selectorEvent)]")

                    if selectorEvent.contains(.readEOF) {
                       _debugPrint("selectorEvent.contains(.readEOF) [\(selectorEvent.contains(.readEOF))]")
                    }
                    
                    if multishot == false { // must be before guard, otherwise lost wake
                        ring.io_uring_prep_poll_add(fd: event.fd,
                                                    pollMask: registration.interested.uringEventSet,
                                                    sequenceIdentifier: registration.selectableSequenceIdentifier,
                                                    submitNow: false,
                                                    multishot: false)

                        if event.pollMask == Uring.POLLCANCEL {
                            _debugPrint("Received Uring.POLLCANCEL")
                        }
                    }

                    if event.sequenceIdentifier != registration.selectableSequenceIdentifier {
                        _debugPrint("The event.sequenceIdentifier [\(event.sequenceIdentifier)] !=  registration.selectableSequenceIdentifier [\(registration.selectableSequenceIdentifier)], skipping to next event")
                        continue
                    }

                    guard selectorEvent != ._none else {
                        _debugPrint("selectorEvent != ._none / [\(selectorEvent)] [\(registration.interested)] [\(SelectorEventSet(uringEvent: event.pollMask))] [\(event.pollMask)] [\(event.fd)]")
                        continue
                    }

                    // FIXME: This is only needed due to the edge triggered nature of liburing, possibly
                    // we can get away with only updating (force triggering an event if available) for
                    // partial reads (where we currently give up after 4 iterations)
                    if multishot && shouldRefreshPollForEvent(selectorEvent:selectorEvent) { // can be after guard as it is multishot
                        ring.io_uring_poll_update(fd: event.fd,
                                                  newPollmask: registration.interested.uringEventSet,
                                                  oldPollmask: registration.interested.uringEventSet,
                                                  sequenceIdentifier: registration.selectableSequenceIdentifier,
                                                  submitNow: false)
                    }
                    
                    _debugPrint("running body [\(NIOThread.current)] \(selectorEvent) \(SelectorEventSet(uringEvent: event.pollMask))")

                    try body((SelectorEvent(io: selectorEvent, registration: registration)))
                    
               } else { // remove any polling if we don't have a registration for it
                    _debugPrint("We had no registration for event.fd [\(event.fd)] event.pollMask [\(event.pollMask)] event.sequenceIdentifier [\(event.sequenceIdentifier)], it should be deregistered already")
                    if multishot == false {
                        ring.io_uring_prep_poll_remove(fd: event.fd,
                                                       pollMask: event.pollMask,
                                                       sequenceIdentifier: event.sequenceIdentifier,
                                                       submitNow: false)
                    }
                }
            }
        }

        deferredReregistrationsPending = false // none pending as we will flush here
        ring.io_uring_flush() // flush reregisteration of the polls if needed (nop in SQPOLL mode)
        growEventArrayIfNeeded(ready: ready)
    }

    /// Close the `Selector`.
    ///
    /// After closing the `Selector` it's no longer possible to use it.
    override public func close() throws {
        try super.close()
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
    override func wakeup() throws {
        assert(NIOThread.current != self.myThread)
        _debugPrint("wakeup()")
        try self.externalSelectorFDLock.withLock {
                guard self.eventFD >= 0 else {
                    throw EventLoopError.shutdown
                }
                _ = try EventFd.eventfd_write(fd: self.eventFD, value: 1)
        }
    }

#endif // os(Linux)
}

extension Selector: CustomStringConvertible {
    var description: String {
        func makeDescription() -> String {
            return "Selector { descriptor = \(self.selectorFD) }"
        }

        if NIOThread.current == self.myThread {
            return makeDescription()
        } else {
            return self.externalSelectorFDLock.withLock {
                makeDescription()
            }
        }
    }
}

/// An event that is triggered once the `Selector` was able to select something.
struct SelectorEvent<R> {
    public let registration: R
    public var io: SelectorEventSet

    /// Create new instance
    ///
    /// - parameters:
    ///     - io: The `SelectorEventSet` that triggered this event.
    ///     - registration: The registration that belongs to the event.
    init(io: SelectorEventSet, registration: R) {
        self.io = io
        self.registration = registration
    }
}

extension Selector where R == NIORegistration {
    /// Gently close the `Selector` after all registered `Channel`s are closed.
    func closeGently(eventLoop: EventLoop) -> EventLoopFuture<Void> {
        assert(self.myThread == NIOThread.current)
        guard self.lifecycleState == .open else {
            return eventLoop.makeFailedFuture(IOError(errnoCode: EBADF, reason: "can't close selector gently as it's \(self.lifecycleState)."))
        }

        let futures: [EventLoopFuture<Void>] = self.registrations.map { (_, reg: NIORegistration) -> EventLoopFuture<Void> in
            // The futures will only be notified (of success) once also the closeFuture of each Channel is notified.
            // This only happens after all other actions on the Channel is complete and all events are propagated through the
            // ChannelPipeline. We do this to minimize the risk to left over any tasks / promises that are tied to the
            // EventLoop itself.
            func closeChannel(_ chan: Channel) -> EventLoopFuture<Void> {
                chan.close(promise: nil)
                return chan.closeFuture
            }

            switch reg {
            case .serverSocketChannel(let chan, _, _):
                return closeChannel(chan)
            case .socketChannel(let chan, _, _):
                return closeChannel(chan)
            case .datagramChannel(let chan, _, _):
                return closeChannel(chan)
            case .pipeChannel(let chan, _, _, _):
                return closeChannel(chan)
            }
        }.map { future in
            future.flatMapErrorThrowing { error in
                if let error = error as? ChannelError, error == .alreadyClosed {
                    return ()
                } else {
                    throw error
                }
            }
        }

        guard futures.count > 0 else {
            return eventLoop.makeSucceededFuture(())
        }

        return .andAllSucceed(futures, on: eventLoop)
    }
}

/// The strategy used for the `Selector`.
enum SelectorStrategy {
    /// Block until there is some IO ready to be processed or the `Selector` is explicitly woken up.
    case block

    /// Block until there is some IO ready to be processed, the `Selector` is explicitly woken up or the given `TimeAmount` elapsed.
    case blockUntilTimeout(TimeAmount)

    /// Try to select all ready IO at this point in time without blocking at all.
    case now
}

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
extension kevent {
    /// Update a kevent for a given filter, file descriptor, and set of flags.
    mutating func setEvent(fileDescriptor fd: CInt, filter: CInt, flags: UInt16) {
        self.ident = UInt(fd)
        self.filter = Int16(filter)
        self.flags = flags
        self.udata = nil

        // On macOS, EVFILT_EXCEPT will fire whenever there is unread data in the socket receive
        // buffer. This is not a behaviour we want from EVFILT_EXCEPT: we only want it to tell us
        // about actually exceptional conditions. For this reason, when we set EVFILT_EXCEPT
        // we do it with NOTE_LOWAT set to Int.max, which will ensure that there is never enough data
        // in the send buffer to trigger EVFILT_EXCEPT. Thanks to the sensible design of kqueue,
        // this only affects our EXCEPT filter: EVFILT_READ behaves separately.
        if filter == EVFILT_EXCEPT {
            self.fflags = CUnsignedInt(NOTE_LOWAT)
            self.data = Int.max
        } else {
            self.fflags = 0
            self.data = 0
        }
    }
}
#endif
