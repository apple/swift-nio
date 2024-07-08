//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// A type that handles timer callbacks scheduled with ``EventLoop/setTimer(for:_:)-5e37g``.
///
/// - Seealso: ``EventLoop/setTimer(for:_:)-5e37g``.
public protocol NIOTimerHandler {
    func timerFired(eventLoop: any EventLoop)
}

/// An opaque handle that can be used to cancel a timer.
///
/// Users cannot create an instance of this type; it is returned by ``EventLoop/setTimer(for:_:)-5e37g``.
///
/// - Seealso: ``EventLoop/setTimer(for:_:)-5e37g``.
public struct NIOTimer: Sendable {
    @usableFromInline
    enum Backing: Sendable {
        /// A task created using `EventLoop.scheduleTask(deadline:_:)` by the default event loop timer implementation.
        case `default`(_ task: Scheduled<Void>)
        /// A custom timer identifier, used by event loops that want to provide a custom timer implementation.
        case custom(id: UInt64)
    }

    @usableFromInline
    var eventLoop: any EventLoop

    @usableFromInline
    var backing: Backing

    /// This initializer is only for the default implementations and is fileprivate to avoid tempting EL implementations.
    fileprivate init(_ eventLoop: any EventLoop, _ task: Scheduled<Void>) {
        self.eventLoop = eventLoop
        self.backing = .default(task)
    }

    /// This initializer is for event loop implementations. End users should use ``EventLoop/setTimer(for:_:)-5e37g``.
    ///
    /// - Seealso: ``EventLoop/setTimer(for:_:)-5e37g``.
    @inlinable
    public init(_ eventLoop: any EventLoop, id: UInt64) {
        self.eventLoop = eventLoop
        self.backing = .custom(id: id)
    }

    /// Cancel the timer associated with this handle.
    @inlinable
    public func cancel() {
        self.eventLoop.cancelTimer(self)
    }

    /// The custom timer identifier, if this timer uses a custom timer implementation; nil otherwise.
    @inlinable
    public var customTimerID: UInt64? {
        guard case .custom(let id) = backing else { return nil }
        return id
    }
}

extension EventLoop {
    /// Default implementation of `setTimer(for deadline:_:)`, backed by `EventLoop.scheduleTask`.
    @discardableResult
    public func setTimer(for deadline: NIODeadline, _ handler: any NIOTimerHandler) -> NIOTimer {
        let task = self.scheduleTask(deadline: deadline) { handler.timerFired(eventLoop: self) }
        return NIOTimer(self, task)
    }

    /// Default implementation of `setTimer(for duration:_:)`, delegating to `setTimer(for deadline:_:)`.
    @discardableResult
    @inlinable
    public func setTimer(for duration: TimeAmount, _ handler: any NIOTimerHandler) -> NIOTimer {
        self.setTimer(for: .now() + duration, handler)
    }

    /// Default implementation of `cancelTimer(_:)`, for cancelling timers set with the default timer implementation.
    @inlinable
    public func cancelTimer(_ timer: NIOTimer) {
        switch timer.backing {
        case .default(let task):
            task.cancel()
        case .custom:
            preconditionFailure("EventLoop missing custom implementation of cancelTimer(_:)")
        }
    }
}
