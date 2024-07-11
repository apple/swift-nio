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

/// A type that handles callbacks scheduled with `EventLoop.scheduleCallback(at:handler:)`.
///
/// - Seealso: `EventLoop.scheduleCallback(at:handler:)`.
public protocol NIOScheduledCallbackHandler {
    /// This function is called at the scheduled time, unless the scheduled callback is cancelled.
    ///
    /// - Parameter eventLoop: The event loop on which the callback was scheduled.
    func handleScheduledCallback(eventLoop: some EventLoop)
}

/// An opaque handle that can be used to cancel a scheduled callback.
///
/// Users should not create an instance of this type; it is returned by `EventLoop.scheduleCallback(at:handler:)`.
///
/// - Seealso: `EventLoop.scheduleCallback(at:handler:)`.
public struct NIOScheduledCallback: Sendable {
    @usableFromInline
    enum Backing: Sendable {
        /// A task created using `EventLoop.scheduleTask(deadline:_:)` by the default implementation.
        case `default`(_ task: Scheduled<Void>)
        /// A custom callback identifier, used by event loops that provide a custom implementation.
        case custom(id: UInt64)
    }

    @usableFromInline
    var eventLoop: any EventLoop

    @usableFromInline
    var backing: Backing

    /// This initializer is only for the default implementation and is fileprivate to avoid use in EL implementations.
    fileprivate init(_ eventLoop: any EventLoop, _ task: Scheduled<Void>) {
        self.eventLoop = eventLoop
        self.backing = .default(task)
    }

    /// Create a handle for the scheduled callback with an opaque identifier managed by the event loop.
    ///
    /// - NOTE: This initializer is for event loop implementors only, end users should use `EventLoop.scheduleCallback`.
    ///
    /// - Seealso: `EventLoop.scheduleCallback(at:handler:)`.
    @inlinable
    public init(_ eventLoop: any EventLoop, id: UInt64) {
        self.eventLoop = eventLoop
        self.backing = .custom(id: id)
    }

    /// Cancel the scheduled callback associated with this handle.
    @inlinable
    public func cancel() {
        self.eventLoop.cancelScheduledCallback(self)
    }

    /// The callback identifier, if the event loop uses a custom scheduled callback implementation; nil otherwise.
    ///
    /// - NOTE: This property is for event loop implementors only.
    @inlinable
    public var customCallbackID: UInt64? {
        guard case .custom(let id) = self.backing else { return nil }
        return id
    }
}

extension EventLoop {
    /// Default implementation of `scheduleCallback(at deadline:handler:)`: backed by `EventLoop.scheduleTask`.
    @discardableResult
    public func scheduleCallback(at deadline: NIODeadline, handler: some NIOScheduledCallbackHandler) -> NIOScheduledCallback {
        let task = self.scheduleTask(deadline: deadline) { handler.handleScheduledCallback(eventLoop: self) }
        return NIOScheduledCallback(self, task)
    }

    /// Default implementation of `scheduleCallback(in amount:handler:)`: calls `scheduleCallback(at deadline:handler:)`.
    @discardableResult
    @inlinable
    public func scheduleCallback(in amount: TimeAmount, handler: some NIOScheduledCallbackHandler) throws -> NIOScheduledCallback {
        try self.scheduleCallback(at: .now() + amount, handler: handler)
    }

    /// Default implementation of `cancelScheduledCallback(_:)`: only cancels callbacks scheduled by the default implementation of `scheduleCallback`.
    ///
    /// - NOTE: Event loops that provide a custom scheduled callback implementation **must** implement _both_
    ///         `sheduleCallback(at deadline:handler:)` _and_ `cancelScheduledCallback(_:)`. Failure to do so will
    ///         result in a runtime error.
    @inlinable
    public func cancelScheduledCallback(_ scheduledCallback: NIOScheduledCallback) {
        switch scheduledCallback.backing {
        case .default(let task):
            task.cancel()
        case .custom:
            preconditionFailure("EventLoop missing custom implementation of cancelTimer(_:)")
        }
    }
}
