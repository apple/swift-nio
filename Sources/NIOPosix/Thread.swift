//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2014 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers

#if os(Linux) || os(FreeBSD) || os(Android)
import CNIOLinux
#elseif os(OpenBSD)
import CNIOOpenBSD
#elseif os(Windows)
import WinSDK
#endif

enum LowLevelThreadOperations {

}

protocol ThreadOps {
    associatedtype ThreadHandle: Sendable
    associatedtype ThreadSpecificKey
    associatedtype ThreadSpecificKeyDestructor

    static func threadName(_ thread: ThreadHandle) -> String?
    static func run(handle: inout ThreadHandle?, args: Box<NIOThread.ThreadBoxValue>)
    static func isCurrentThread(_ thread: ThreadHandle) -> Bool
    static func compareThreads(_ lhs: ThreadHandle, _ rhs: ThreadHandle) -> Bool
    static var currentThread: ThreadHandle { get }
    static func joinThread(_ thread: ThreadHandle)
    static func allocateThreadSpecificValue(destructor: ThreadSpecificKeyDestructor) -> ThreadSpecificKey
    static func deallocateThreadSpecificValue(_ key: ThreadSpecificKey)
    static func getThreadSpecificValue(_ key: ThreadSpecificKey) -> UnsafeMutableRawPointer?
    static func setThreadSpecificValue(key: ThreadSpecificKey, value: UnsafeMutableRawPointer?)
}

/// A Thread that executes some runnable block.
///
/// All methods exposed are thread-safe.
@usableFromInline
final class NIOThread: Sendable {
    internal typealias ThreadBoxValue = (body: (NIOThread) -> Void, name: String?)
    internal typealias ThreadBox = Box<ThreadBoxValue>

    private let desiredName: String?

    /// The thread handle used by this instance.
    private let handle: NIOLockedValueBox<ThreadOpsSystem.ThreadHandle?>

    enum Error: Swift.Error {
        case threadAlreadyJoinedOrDetached
    }

    deinit {
        assert(
            self.handle.withLockedValue { $0 } == nil,
            "Thread leak! NIOThread released without having been .join()ed"
        )
    }

    func withHandleUnderLock<Return>(_ body: (ThreadOpsSystem.ThreadHandle) throws -> Return) throws -> Return {
        try self.handle.withLockedValue { handle in
            guard let handle else {
                throw Error.threadAlreadyJoinedOrDetached
            }
            return try body(handle)
        }
    }

    /// Create a new instance
    ///
    /// - arguments:
    ///   - handle: The `ThreadOpsSystem.ThreadHandle` that is wrapped and used by the `NIOThread`.
    internal init(handle: ThreadOpsSystem.ThreadHandle, desiredName: String?) {
        self.handle = NIOLockedValueBox(handle)
        self.desiredName = desiredName
    }

    /// Get current name of the `NIOThread` or `nil` if not set.
    var currentName: String? {
        try? self.withHandleUnderLock { handle in
            ThreadOpsSystem.threadName(handle)
        }
    }

    static var currentThreadName: String? {
        #if os(Windows)
        ThreadOpsSystem.threadName(.init(GetCurrentThread()))
        #else
        ThreadOpsSystem.threadName(.init(handle: pthread_self()))
        #endif
    }

    static var currentThreadID: UInt {
        #if os(Windows)
        UInt(bitPattern: .init(bitPattern: ThreadOpsSystem.currentThread))
        #else
        UInt(bitPattern: .init(bitPattern: ThreadOpsSystem.currentThread.handle))
        #endif
    }

    @discardableResult
    func takeOwnership() -> ThreadOpsSystem.ThreadHandle {
        try! self.handle.withLockedValue { handle in
            guard let originalHandle = handle else {
                throw Error.threadAlreadyJoinedOrDetached
            }
            handle = nil
            return originalHandle
        }
    }

    func join() {
        let handle = try! self.withHandleUnderLock { $0 }
        ThreadOpsSystem.joinThread(handle)
        self.handle.withLockedValue { handle in
            precondition(handle != nil, "double NIOThread.join() disallowed")
            handle = nil
        }
    }

    /// Spawns and runs some task in a `NIOThread`.
    ///
    /// - arguments:
    ///   - name: The name of the `NIOThread` or `nil` if no specific name should be set.
    ///   - body: The function to execute within the spawned `NIOThread`.
    static func spawnAndRun(
        name: String? = nil,
        body: @escaping (NIOThread) -> Void
    ) {
        var handle: ThreadOpsSystem.ThreadHandle? = nil

        // Store everything we want to pass into the c function in a Box so we
        // can hand-over the reference.
        let tuple: ThreadBoxValue = (body: body, name: name)
        let box = ThreadBox(tuple)

        ThreadOpsSystem.run(handle: &handle, args: box)
    }

    /// Returns `true` if the calling thread.
    ///
    /// - warning: Do not use in the performance path, this takes a lock and is slow.
    @usableFromInline
    var isCurrentSlow: Bool {
        (try? self.withHandleUnderLock { handle in
            ThreadOpsSystem.isCurrentThread(handle)
        }) ?? false
    }

    internal static func withCurrentThread<Return>(_ body: (NIOThread) throws -> Return) rethrows -> Return {
        let thread = NIOThread(handle: ThreadOpsSystem.currentThread, desiredName: nil)
        defer {
            thread.takeOwnership()
        }
        return try body(thread)
    }
}

extension NIOThread: CustomStringConvertible {
    public var description: String {
        let desiredName = self.desiredName
        let actualName = self.currentName

        switch (desiredName, actualName) {
        case (.some(let desiredName), .some(desiredName)):
            // We know the current, actual name and the desired name and they match. This is hopefully the most common
            // situation.
            return "NIOThread(name = \(desiredName))"
        case (.some(let desiredName), .some(let actualName)):
            // We know both names but they're not equal. That's odd but not impossible, some misbehaved library might
            // have changed the name.
            return "NIOThread(desiredName = \(desiredName), actualName = \(actualName))"
        case (.some(let desiredName), .none):
            // We only know the desired name and can't get the actual thread name. The OS might not be able to provide
            // the name to us.
            return "NIOThread(desiredName = \(desiredName))"
        case (.none, .some(let actualName)):
            // We only know the actual name. This can happen when we don't have a reference to the actually spawned
            // thread but rather ask for the current thread and then print it.
            return "NIOThread(actualName = \(actualName))"
        case (.none, .none):
            // We know nothing, sorry.
            return "NIOThread(n/a)"
        }
    }
}

/// A ``ThreadSpecificVariable`` is a variable that can be read and set like a normal variable except that it holds
/// different variables per thread.
///
/// ``ThreadSpecificVariable`` is thread-safe so it can be used with multiple threads at the same time but the value
/// returned by ``currentValue`` is defined per thread.
///
/// - Note: Though ``ThreadSpecificVariable`` is thread-safe, it is not `Sendable` unless `Value` is `Sendable`.
///     If ``ThreadSpecificVariable`` were unconditionally `Sendable`, it could be used to "smuggle"
///     non-`Sendable` state out of an actor or other isolation domain without triggering warnings. If you
///     are attempting to use ``ThreadSpecificVariable`` with non-`Sendable` data, consider using a dynamic
///     enforcement tool like `NIOLoopBoundBox` to police the access.
public final class ThreadSpecificVariable<Value: AnyObject> {
    // the actual type in there is `Box<(ThreadSpecificVariable<T>, T)>` but we can't use that as C functions can't capture (even types)
    private typealias BoxedType = Box<(AnyObject, AnyObject)>

    internal class Key {
        private var underlyingKey: ThreadOpsSystem.ThreadSpecificKey

        internal init(destructor: @escaping ThreadOpsSystem.ThreadSpecificKeyDestructor) {
            self.underlyingKey = ThreadOpsSystem.allocateThreadSpecificValue(destructor: destructor)
        }

        deinit {
            ThreadOpsSystem.deallocateThreadSpecificValue(self.underlyingKey)
        }

        public func get() -> UnsafeMutableRawPointer? {
            ThreadOpsSystem.getThreadSpecificValue(self.underlyingKey)
        }

        public func set(value: UnsafeMutableRawPointer?) {
            ThreadOpsSystem.setThreadSpecificValue(key: self.underlyingKey, value: value)
        }
    }

    private let key: Key

    /// Initialize a new `ThreadSpecificVariable` without a current value (`currentValue == nil`).
    public init() {
        self.key = Key(destructor: {
            Unmanaged<BoxedType>.fromOpaque(($0 as UnsafeMutableRawPointer?)!).release()
        })
    }

    /// Initialize a new `ThreadSpecificVariable` with `value` for the calling thread. After calling this, the calling
    /// thread will see `currentValue == value` but on all other threads `currentValue` will be `nil` until changed.
    ///
    /// - Parameters:
    ///   - value: The value to set for the calling thread.
    public convenience init(value: Value) {
        self.init()
        self.currentValue = value
    }

    /// The value for the current thread.
    @available(
        *,
        noasync,
        message: "threads can change between suspension points and therefore the thread specific value too"
    )
    public var currentValue: Value? {
        get {
            self.get()
        }
        set {
            self.set(newValue)
        }
    }

    /// Get the current value for the calling thread.
    func get() -> Value? {
        guard let raw = self.key.get() else { return nil }
        // parenthesize the return value to silence the cast warning
        return
            (Unmanaged<BoxedType>
            .fromOpaque(raw)
            .takeUnretainedValue()
            .value.1 as! Value)
    }

    /// Set the current value for the calling threads. The `currentValue` for all other threads remains unchanged.
    func set(_ newValue: Value?) {
        if let raw = self.key.get() {
            Unmanaged<BoxedType>.fromOpaque(raw).release()
        }
        self.key.set(value: newValue.map { Unmanaged.passRetained(Box((self, $0))).toOpaque() })
    }
}

extension ThreadSpecificVariable: @unchecked Sendable where Value: Sendable {}
