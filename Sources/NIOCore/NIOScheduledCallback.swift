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

    /// This function is called if the scheduled callback is cancelled.
    ///
    /// The callback could be cancelled explictily, by the user calling ``NIOScheduledCallback/cancel()``, or
    /// implicitly, if it was still pending when the event loop was shut down.
    ///
    /// - Parameter eventLoop: The event loop on which the callback was scheduled.
    func didCancelScheduledCallback(eventLoop: some EventLoop)
}

extension NIOScheduledCallbackHandler {
    /// Default implementation of `didCancelScheduledCallback(eventLoop:)`: does nothing.
    public func didCancelScheduledCallback(eventLoop: some EventLoop) {}
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
    @preconcurrency
    /// This method is not part of the public API
    ///
    /// Should use `package` not `public` but then it won't compile in
    /// Xcode 15.4 if you run `swift build --arch x86_64 --arch arm64`.
    public func _scheduleCallback(
        at deadline: NIODeadline,
        handler: some (NIOScheduledCallbackHandler & Sendable)
    ) -> NIOScheduledCallback {
        let task = self.scheduleTask(deadline: deadline) { handler.handleScheduledCallback(eventLoop: self) }
        task.futureResult.whenFailure { error in
            if case .cancelled = error as? EventLoopError {
                handler.didCancelScheduledCallback(eventLoop: self)
            }
        }
        return NIOScheduledCallback(self, task)
    }

    /// Default implementation of `scheduleCallback(at deadline:handler:)`: backed by `EventLoop.scheduleTask`.
    ///
    /// Ideally the scheduled callback handler should be called exactly once for each call to `scheduleCallback`:
    /// either the callback handler, or the cancellation handler.
    ///
    /// In order to support cancellation in the default implementation, we hook the future of the scheduled task
    /// backing the scheduled callback. This requires two calls to the event loop: `EventLoop.scheduleTask`, and
    /// `EventLoopFuture.whenFailure`, both of which queue onto the event loop if called from off the event loop.
    ///
    /// This can present a challenge during event loop shutdown, where typically:
    /// 1. Scheduled work that is past its deadline gets run.
    /// 2. Scheduled future work gets cancelled.
    /// 3. New work resulting from (1) and (2) gets handled differently depending on the EL:
    ///   a. `SelectableEventLoop` runs new work recursively and crashes if not quiesced in some number of ticks.
    ///   b. `EmbeddedEventLoop` and `NIOAsyncTestingEventLoop` will fail incoming work.
    ///
    /// `SelectableEventLoop` has a custom implementation for scheduled callbacks so warrants no further discussion.
    ///
    /// As a practical matter, the `EmbeddedEventLoop` is OK because it shares the thread of the caller, but for
    /// other event loops (including any outside this repo), it's possible that the call to shutdown interleaves
    /// with the call to create the scheduled task and the call to hook the task future.
    ///
    /// Because this API is synchronous and we cannot block the calling thread, users of event loops with this
    /// default implementation will have cancellation callbacks delivered on a best-effort basis when the event loop
    /// is shutdown and depends on how the event loop deals with newly scheduled tasks during shutdown.
    ///
    /// The implementation of this default conformance has been further factored out so we can use it in
    /// `NIOAsyncTestingEventLoop`, where the use of `wait()` is _less bad_.
    @preconcurrency
    @discardableResult
    public func scheduleCallback(
        at deadline: NIODeadline,
        handler: some (NIOScheduledCallbackHandler & Sendable)
    ) -> NIOScheduledCallback {
        self._scheduleCallback(at: deadline, handler: handler)
    }

    /// Default implementation of `scheduleCallback(in amount:handler:)`: calls `scheduleCallback(at deadline:handler:)`.
    @preconcurrency
    @discardableResult
    @inlinable
    public func scheduleCallback(
        in amount: TimeAmount,
        handler: some (NIOScheduledCallbackHandler & Sendable)
    ) throws -> NIOScheduledCallback {
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
            preconditionFailure("EventLoop missing custom implementation of cancelScheduledCallback(_:)")
        }
    }
}

@usableFromInline
struct LoopBoundScheduledCallbackHandlerWrapper<Handler: NIOScheduledCallbackHandler>:
    NIOScheduledCallbackHandler, Sendable
{
    private let box: NIOLoopBound<Handler>

    @usableFromInline
    init(wrapping handler: Handler, eventLoop: some EventLoop) {
        self.box = .init(handler, eventLoop: eventLoop)
    }

    @usableFromInline
    func handleScheduledCallback(eventLoop: some EventLoop) {
        self.box.value.handleScheduledCallback(eventLoop: eventLoop)
    }

    @usableFromInline
    func didCancelScheduledCallback(eventLoop: some EventLoop) {
        self.box.value.didCancelScheduledCallback(eventLoop: eventLoop)
    }
}
