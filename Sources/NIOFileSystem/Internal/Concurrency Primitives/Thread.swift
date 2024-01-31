//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux) || os(Android)
#if os(Linux) || os(FreeBSD) || os(Android)
import CNIOLinux
#endif

protocol ThreadOps {
    associatedtype ThreadHandle
    associatedtype ThreadSpecificKey
    associatedtype ThreadSpecificKeyDestructor

    static func run(
        handle: inout ThreadHandle?,
        args: Ref<Thread.ThreadBoxValue>,
        detachThread: Bool
    )
    static func joinThread(_ thread: ThreadHandle)
    static func threadName(_ thread: ThreadHandle) -> String?
    static func compareThreads(_ lhs: ThreadHandle, _ rhs: ThreadHandle) -> Bool
}

/// A Thread that executes some runnable block.
///
/// All methods exposed are thread-safe.
final class Thread {
    internal typealias ThreadBoxValue = (body: (Thread) -> Void, name: String?)
    internal typealias ThreadBox = Ref<ThreadBoxValue>

    private let desiredName: String?

    /// The thread handle used by this instance.
    private let handle: ThreadOpsSystem.ThreadHandle

    /// Create a new instance
    ///
    /// - arguments:
    ///     - handle: The `ThreadOpsSystem.ThreadHandle` that is wrapped and used by the `Thread`.
    internal init(handle: ThreadOpsSystem.ThreadHandle, desiredName: String?) {
        self.handle = handle
        self.desiredName = desiredName
    }

    /// Execute the given body with the `pthread_t` that is used by this `Thread` as argument.
    ///
    /// - warning: Do not escape `pthread_t` from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the `pthread_t`.
    /// - returns: The value returned by `body`.
    internal func withUnsafeThreadHandle<T>(
        _ body: (ThreadOpsSystem.ThreadHandle) throws -> T
    ) rethrows -> T {
        return try body(self.handle)
    }

    /// Get current name of the `Thread` or `nil` if not set.
    var currentName: String? {
        return ThreadOpsSystem.threadName(self.handle)
    }

    func join() {
        ThreadOpsSystem.joinThread(self.handle)
    }

    /// Spawns and runs some task in a `Thread`.
    ///
    /// - arguments:
    ///     - name: The name of the `Thread` or `nil` if no specific name should be set.
    ///     - body: The function to execute within the spawned `Thread`.
    ///     - detach: Whether to detach the thread. If the thread is not detached it must be `join`ed.
    static func spawnAndRun(
        name: String? = nil,
        detachThread: Bool = true,
        body: @escaping (Thread) -> Void
    ) {
        var handle: ThreadOpsSystem.ThreadHandle? = nil

        // Store everything we want to pass into the c function in a Box so we
        // can hand-over the reference.
        let tuple: ThreadBoxValue = (body: body, name: name)
        let box = ThreadBox(tuple)

        ThreadOpsSystem.run(handle: &handle, args: box, detachThread: detachThread)
    }
}
#endif
