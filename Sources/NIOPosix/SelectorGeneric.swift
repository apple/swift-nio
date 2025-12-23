//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers
import NIOCore

#if os(Linux)
import CNIOLinux
#elseif os(Windows)
import WinSDK
#endif

@usableFromInline
internal enum SelectorLifecycleState: Sendable {
    case open
    case closing
    case closed
}

extension Optional {
    @inlinable
    internal func withUnsafeOptionalPointer<T>(_ body: (UnsafePointer<Wrapped>?) throws -> T) rethrows -> T {
        if var this = self {
            return try withUnsafePointer(to: &this) { x in
                try body(x)
            }
        } else {
            return try body(nil)
        }
    }
}

#if !os(Windows)
extension timespec {
    @inlinable
    init(timeAmount amount: TimeAmount) {
        let nsecPerSec: Int64 = 1_000_000_000
        let ns = amount.nanoseconds
        let sec = ns / nsecPerSec
        self = timespec(tv_sec: time_t(sec), tv_nsec: Int(ns - sec * nsecPerSec))
    }
}
#endif

/// Represents IO events NIO might be interested in. `SelectorEventSet` is used for two purposes:
///  1. To express interest in a given event set and
///  2. for notifications about an IO event set that has occurred.
///
/// For example, if you were interested in reading and writing data from/to a socket and also obviously if the socket
/// receives a connection reset, express interest with `[.read, .write, .reset]`.
/// If then suddenly the socket becomes both readable and writable, the eventing mechanism will tell you about that
/// fact using `[.read, .write]`.
@usableFromInline
struct SelectorEventSet: OptionSet, Equatable, Sendable {

    @usableFromInline
    typealias RawValue = UInt8

    @usableFromInline
    let rawValue: RawValue

    /// It's impossible to actually register for no events, therefore `_none` should only be used to bootstrap a set
    /// of flags or to compare against spurious wakeups.
    @usableFromInline
    static let _none = SelectorEventSet([])

    /// Connection reset.
    @usableFromInline
    static let reset = SelectorEventSet(rawValue: 1 << 0)

    /// EOF at the read/input end of a `Selectable`.
    @usableFromInline
    static let readEOF = SelectorEventSet(rawValue: 1 << 1)

    /// Interest in/availability of data to be read
    @usableFromInline
    static let read = SelectorEventSet(rawValue: 1 << 2)

    /// Interest in/availability of data to be written
    @usableFromInline
    static let write = SelectorEventSet(rawValue: 1 << 3)

    /// EOF at the write/output end of a `Selectable`.
    ///
    /// - Note: This is rarely used because in many cases, there is no signal that this happened.
    @usableFromInline
    static let writeEOF = SelectorEventSet(rawValue: 1 << 4)

    /// Error encountered.
    @usableFromInline
    static let error = SelectorEventSet(rawValue: 1 << 5)

    @inlinable
    init(rawValue: SelectorEventSet.RawValue) {
        self.rawValue = rawValue
    }
}

internal let isEarlyEOFDeliveryWorkingOnThisOS: Bool = {
    #if canImport(Darwin)
    return false  // rdar://53656794 , once fixed we need to do an OS version check here.
    #else
    return true
    #endif
}()

/// This protocol defines the methods that are expected to be found on
/// `Selector`. While defined as a protocol there is no expectation that any
/// object other than `Selector` will implement this protocol: instead, this
/// protocol acts as a reference for what new supported selector backends
/// must implement.
protocol _SelectorBackendProtocol {
    associatedtype R: Registration
    func initialiseState0() throws
    func deinitAssertions0()  // allows actual implementation to run some assertions as part of the class deinit
    func register0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        interested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws
    func reregister0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        oldInterested: SelectorEventSet,
        newInterested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws
    func deregister0(
        selectableFD: NIOBSDSocket.Handle,
        fileDescriptor: NIOBSDSocket.Handle,
        oldInterested: SelectorEventSet,
        registrationID: SelectorRegistrationID
    ) throws

    // attention, this may (will!) be called from outside the event loop, ie. can't access mutable shared state (such as `self.open`)
    func wakeup0() throws

    /// Apply the given `SelectorStrategy` and execute `body` once it's complete (which may produce `SelectorEvent`s to handle).
    ///
    /// - Parameters:
    ///   - strategy: The `SelectorStrategy` to apply
    ///   - body: The function to execute for each `SelectorEvent` that was produced.
    func whenReady0(
        strategy: SelectorStrategy,
        onLoopBegin: () -> Void,
        _ body: (SelectorEvent<R>) throws -> Void
    ) throws
    func close0() throws
}

///  A `Selector` allows a user to register different `Selectable` sources to an underlying OS selector, and for that selector to notify them once IO is ready for them to process.
///
/// This implementation offers an consistent API over epoll/liburing (for linux) and kqueue (for Darwin, BSD).
/// There are specific subclasses  per API type with a shared common superclass providing overall scaffolding.

// this is deliberately not thread-safe, only the wakeup() function may be called unprotectedly
@usableFromInline
internal class Selector<R: Registration> {
    @usableFromInline
    var lifecycleState: SelectorLifecycleState
    @usableFromInline
    var registrations = [Int: R]()
    @usableFromInline
    var registrationID: SelectorRegistrationID = .initialRegistrationID

    @usableFromInline
    let myThread: NIOThread
    // The rules for `self.selectorFD`, `self.eventFD`, and `self.timerFD`:
    // reads: `self.externalSelectorFDLock` OR access from the EventLoop thread
    // writes: `self.externalSelectorFDLock` AND access from the EventLoop thread
    let externalSelectorFDLock = NIOLock()
    @usableFromInline
    var selectorFD: CInt = -1  // -1 == we're closed

    // Here we add the stored properties that are used by the specific backends
    #if canImport(Darwin) || os(OpenBSD)
    @usableFromInline
    typealias EventType = kevent
    #elseif os(Linux) || os(Android)
    #if !SWIFTNIO_USE_IO_URING
    @usableFromInline
    typealias EventType = Epoll.epoll_event
    @usableFromInline
    var earliestTimer: NIODeadline = .distantFuture
    @usableFromInline
    var eventFD: CInt = -1  // -1 == we're closed
    @usableFromInline
    var timerFD: CInt = -1  // -1 == we're closed
    #else
    @usableFromInline
    typealias EventType = URingEvent
    @usableFromInline
    var eventFD: CInt = -1  // -1 == we're closed
    @usableFromInline
    var ring = URing()
    @usableFromInline
    let multishot = URing.io_uring_use_multishot_poll  // if true, we run with streaming multishot polls
    @usableFromInline
    let deferReregistrations = true  // if true we only flush once at reentring whenReady() - saves syscalls
    @usableFromInline
    var deferredReregistrationsPending = false  // true if flush needed when reentring whenReady()
    #endif
    #elseif os(Windows)
    @usableFromInline
    typealias EventType = WinSDK.pollfd
    @usableFromInline
    var pollFDs = [WinSDK.pollfd]()
    #else
    #error("Unsupported platform, no suitable selector backend (we need kqueue or epoll support)")
    #endif

    @usableFromInline
    var events: UnsafeMutablePointer<EventType>
    @usableFromInline
    var eventsCapacity = 64

    internal func testsOnly_withUnsafeSelectorFD<T>(_ body: (CInt) throws -> T) throws -> T {
        assert(!self.myThread.isCurrentSlow)
        return try self.externalSelectorFDLock.withLock {
            guard self.selectorFD != -1 else {
                throw EventLoopError._shutdown
            }
            return try body(self.selectorFD)
        }
    }

    init(thread: NIOThread) throws {
        precondition(thread.isCurrentSlow)
        self.myThread = thread
        self.lifecycleState = .closed
        self.events = Selector.allocateEventsArray(capacity: self.eventsCapacity)
        try self.initialiseState0()
    }

    deinit {
        self.deinitAssertions0()
        assert(self.registrations.count == 0, "left-over registrations: \(self.registrations)")
        assert(self.lifecycleState == .closed, "Selector \(self.lifecycleState) (expected .closed) on deinit")
        assert(self.selectorFD == -1, "self.selectorFD == \(self.selectorFD) on Selector deinit, forgot close?")
        Selector.deallocateEventsArray(events: self.events, capacity: self.eventsCapacity)
    }

    @inlinable
    internal static func allocateEventsArray(capacity: Int) -> UnsafeMutablePointer<EventType> {
        let events: UnsafeMutablePointer<EventType> = UnsafeMutablePointer.allocate(capacity: capacity)
        events.initialize(to: EventType())
        return events
    }

    @inlinable
    internal static func deallocateEventsArray(events: UnsafeMutablePointer<EventType>, capacity: Int) {
        events.deinitialize(count: capacity)
        events.deallocate()
    }

    @inlinable
    func growEventArrayIfNeeded(ready: Int) {
        assert(self.myThread.isCurrentSlow)
        guard ready == self.eventsCapacity else {
            return
        }
        Selector.deallocateEventsArray(events: self.events, capacity: self.eventsCapacity)

        // double capacity
        self.eventsCapacity = ready << 1
        self.events = Selector.allocateEventsArray(capacity: self.eventsCapacity)
    }

    /// Register `Selectable` on the `Selector`.
    ///
    /// - Parameters:
    ///   - selectable: The `Selectable` to register.
    ///   - interested: The `SelectorEventSet` in which we are interested and want to be notified about.
    ///   - makeRegistration: Creates the registration data for the given `SelectorEventSet`.
    func register<S: Selectable>(
        selectable: S,
        interested: SelectorEventSet,
        makeRegistration: (SelectorEventSet, SelectorRegistrationID) -> R
    ) throws {
        assert(self.myThread.isCurrentSlow)
        assert(interested.contains([.reset, .error]))
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't register on selector as it's \(self.lifecycleState).")
        }

        try selectable.withUnsafeHandle { fd in
            assert(registrations[Int(fd)] == nil)
            try self.register0(
                selectableFD: fd,
                fileDescriptor: fd,
                interested: interested,
                registrationID: self.registrationID
            )
            let registration = makeRegistration(interested, self.registrationID.nextRegistrationID())
            registrations[Int(fd)] = registration
        }
    }

    /// Re-register `Selectable`, must be registered via `register` before.
    ///
    /// - Parameters:
    ///   - selectable: The `Selectable` to re-register.
    ///   - interested: The `SelectorEventSet` in which we are interested and want to be notified about.
    func reregister<S: Selectable>(selectable: S, interested: SelectorEventSet) throws {
        assert(self.myThread.isCurrentSlow)
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't re-register on selector as it's \(self.lifecycleState).")
        }
        assert(
            interested.contains([.reset, .error]),
            "must register for at least .reset & .error but tried registering for \(interested)"
        )
        try selectable.withUnsafeHandle { fd in
            var reg = registrations[Int(fd)]!
            try self.reregister0(
                selectableFD: fd,
                fileDescriptor: fd,
                oldInterested: reg.interested,
                newInterested: interested,
                registrationID: reg.registrationID
            )
            reg.interested = interested
            self.registrations[Int(fd)] = reg
        }
    }

    /// Deregister `Selectable`, must be registered via `register` before.
    ///
    /// After the `Selectable is deregistered no `SelectorEventSet` will be produced anymore for the `Selectable`.
    ///
    /// - Parameters:
    ///   - selectable: The `Selectable` to deregister.
    func deregister<S: Selectable>(selectable: S) throws {
        assert(self.myThread.isCurrentSlow)
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't deregister from selector as it's \(self.lifecycleState).")
        }

        try selectable.withUnsafeHandle { fd in
            guard let reg = registrations.removeValue(forKey: Int(fd)) else {
                return
            }
            try self.deregister0(
                selectableFD: fd,
                fileDescriptor: fd,
                oldInterested: reg.interested,
                registrationID: reg.registrationID
            )
        }
    }

    /// Apply the given `SelectorStrategy` and execute `body` once it's complete (which may produce `SelectorEvent`s to handle).
    ///
    /// - Parameters:
    ///   - strategy: The `SelectorStrategy` to apply
    ///   - onLoopBegin: A function executed after the selector returns, just before the main loop begins..
    ///   - body: The function to execute for each `SelectorEvent` that was produced.
    @inlinable
    func whenReady(
        strategy: SelectorStrategy,
        onLoopBegin loopStart: () -> Void,
        _ body: (SelectorEvent<R>) throws -> Void
    ) throws {
        try self.whenReady0(strategy: strategy, onLoopBegin: loopStart, body)
    }

    /// Close the `Selector`.
    ///
    /// After closing the `Selector` it's no longer possible to use it.
    public func close() throws {
        assert(self.myThread.isCurrentSlow)
        guard self.lifecycleState == .open else {
            throw IOError(errnoCode: EBADF, reason: "can't close selector as it's \(self.lifecycleState).")
        }
        try self.close0()
        self.lifecycleState = .closed
        self.registrations.removeAll()
    }

    // attention, this may (will!) be called from outside the event loop, ie. can't access mutable shared state (such as `self.open`)
    func wakeup() throws {
        try self.wakeup0()
    }
}

extension Selector: CustomStringConvertible {
    @usableFromInline
    var description: String {
        func makeDescription() -> String {
            "Selector { descriptor = \(self.selectorFD) }"
        }

        if self.myThread.isCurrentSlow {
            return makeDescription()
        } else {
            return self.externalSelectorFDLock.withLock {
                makeDescription()
            }
        }
    }
}

@available(*, unavailable)
extension Selector: Sendable {}

/// An event that is triggered once the `Selector` was able to select something.
@usableFromInline
struct SelectorEvent<R> {
    public let registration: R
    public var io: SelectorEventSet

    /// Create new instance
    ///
    /// - Parameters:
    ///   - io: The `SelectorEventSet` that triggered this event.
    ///   - registration: The registration that belongs to the event.
    @inlinable
    init(io: SelectorEventSet, registration: R) {
        self.io = io
        self.registration = registration
    }
}

@available(*, unavailable)
extension SelectorEvent: Sendable {}

extension Selector where R == NIORegistration {
    /// Gently close the `Selector` after all registered `Channel`s are closed.
    func closeGently(eventLoop: EventLoop) -> EventLoopFuture<Void> {
        assert(self.myThread.isCurrentSlow)
        guard self.lifecycleState == .open else {
            return eventLoop.makeFailedFuture(
                IOError(errnoCode: EBADF, reason: "can't close selector gently as it's \(self.lifecycleState).")
            )
        }

        let futures: [EventLoopFuture<Void>] = self.registrations.map {
            (_, reg: NIORegistration) -> EventLoopFuture<Void> in
            // The futures will only be notified (of success) once also the closeFuture of each Channel is notified.
            // This only happens after all other actions on the Channel is complete and all events are propagated through the
            // ChannelPipeline. We do this to minimize the risk to left over any tasks / promises that are tied to the
            // EventLoop itself.
            func closeChannel(_ chan: Channel) -> EventLoopFuture<Void> {
                chan.close(promise: nil)
                return chan.closeFuture
            }

            switch reg.channel {
            case .serverSocketChannel(let chan):
                return closeChannel(chan)
            case .socketChannel(let chan):
                return closeChannel(chan)
            case .datagramChannel(let chan):
                return closeChannel(chan)
            case .pipeChannel(let chan, _):
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
@usableFromInline
enum SelectorStrategy: Sendable {
    /// Block until there is some IO ready to be processed or the `Selector` is explicitly woken up.
    case block

    /// Block until there is some IO ready to be processed, the `Selector` is explicitly woken up or the given `TimeAmount` elapsed.
    case blockUntilTimeout(TimeAmount)

    /// Try to select all ready IO at this point in time without blocking at all.
    case now
}

/// A Registration on a `Selector`, which is interested in an `SelectorEventSet`.
/// `registrationID` is used by the event notification backends (kqueue, epoll, ...)
/// to mark events to allow for filtering of received return values to not be delivered to a
/// new `Registration` instance that receives the same file descriptor. Ok if it wraps.
/// Needed for i.e. testWeDoNotDeliverEventsForPreviouslyClosedChannels to succeed.
@usableFromInline struct SelectorRegistrationID: Hashable, Sendable {
    @usableFromInline var _rawValue: UInt32

    @inlinable var rawValue: UInt32 {
        self._rawValue
    }

    @inlinable static var initialRegistrationID: SelectorRegistrationID {
        SelectorRegistrationID(rawValue: .max)
    }

    @inlinable mutating func nextRegistrationID() -> SelectorRegistrationID {
        let current = self
        // Overflow is okay here, this is just for very short-term disambiguation
        self._rawValue = self._rawValue &+ 1
        return current
    }

    @inlinable init(rawValue: UInt32) {
        self._rawValue = rawValue
    }

    @inlinable static func == (_ lhs: SelectorRegistrationID, _ rhs: SelectorRegistrationID) -> Bool {
        lhs._rawValue == rhs._rawValue
    }

    @inlinable func hash(into hasher: inout Hasher) {
        hasher.combine(self._rawValue)
    }
}
