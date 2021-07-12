//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch

extension DispatchQueue {
    /// Schedules a work item for immediate execution and immediately returns with an `EventLoopFuture` providing the
    /// result. For example:
    ///
    ///     let futureResult = DispatchQueue.main.asyncWithFuture(eventLoop: myEventLoop) { () -> String in
    ///         callbackMayBlock()
    ///     }
    ///     try let value = futureResult.wait()
    ///
    /// - parameters:
    ///     - eventLoop: the `EventLoop` on which to proceses the IO / task specified by `callbackMayBlock`.
    ///     - callbackMayBlock: The scheduled callback for the IO / task.
    /// - returns a new `EventLoopFuture<ReturnType>` with value returned by the `block` parameter.
    @inlinable
    public func asyncWithFuture<NewValue>(
        eventLoop: EventLoop,
        _ callbackMayBlock: @escaping () throws -> NewValue
    ) -> EventLoopFuture<NewValue> {
        let promise = eventLoop.makePromise(of: NewValue.self)

        self.async {
            do {
                let result = try callbackMayBlock()
                promise.succeed(result)
            } catch {
                promise.fail(error)
            }
        }
        return promise.futureResult
    }
}
