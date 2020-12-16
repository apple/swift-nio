//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(Linux) || os(FreeBSD) || os(Android)
import CNIOLinux
#endif

enum LowLevelThreadOperations {
    
}

protocol ThreadOps {
    associatedtype ThreadHandle
    associatedtype ThreadSpecificKey
    associatedtype ThreadSpecificKeyDestructor

    static func threadName(_ thread: ThreadHandle) -> String?
    static func run(handle: inout ThreadHandle?, args: Box<NIOThread.ThreadBoxValue>, detachThread: Bool)
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
final class NIOThread {
    internal typealias ThreadBoxValue = (body: (NIOThread) -> Void, name: String?)
    internal typealias ThreadBox = Box<ThreadBoxValue>

    private let desiredName: String?

    /// The thread handle used by this instance.
    private let handle: ThreadOpsSystem.ThreadHandle

    /// Create a new instance
    ///
    /// - arguments:
    ///     - handle: The `ThreadOpsSystem.ThreadHandle` that is wrapped and used by the `NIOThread`.
    internal init(handle: ThreadOpsSystem.ThreadHandle, desiredName: String?) {
        self.handle = handle
        self.desiredName = desiredName
    }

    /// Execute the given body with the `pthread_t` that is used by this `NIOThread` as argument.
    ///
    /// - warning: Do not escape `pthread_t` from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the `pthread_t`.
    /// - returns: The value returned by `body`.
    internal func withUnsafeThreadHandle<T>(_ body: (ThreadOpsSystem.ThreadHandle) throws -> T) rethrows -> T {
        return try body(self.handle)
    }

    /// Get current name of the `NIOThread` or `nil` if not set.
    var currentName: String? {
        return ThreadOpsSystem.threadName(self.handle)
    }

    func join() {
        ThreadOpsSystem.joinThread(self.handle)
    }

    /// Spawns and runs some task in a `NIOThread`.
    ///
    /// - arguments:
    ///     - name: The name of the `NIOThread` or `nil` if no specific name should be set.
    ///     - body: The function to execute within the spawned `NIOThread`.
    ///     - detach: Whether to detach the thread. If the thread is not detached it must be `join`ed.
    static func spawnAndRun(name: String? = nil, detachThread: Bool = true,
                            body: @escaping (NIOThread) -> Void) {
        var handle: ThreadOpsSystem.ThreadHandle? = nil

        // Store everything we want to pass into the c function in a Box so we
        // can hand-over the reference.
        let tuple: ThreadBoxValue = (body: body, name: name)
        let box = ThreadBox(tuple)

        ThreadOpsSystem.run(handle: &handle, args: box, detachThread: detachThread)
    }

    /// Returns `true` if the calling thread is the same as this one.
    var isCurrent: Bool {
        return ThreadOpsSystem.isCurrentThread(self.handle)
    }

    /// Returns the current running `NIOThread`.
    static var current: NIOThread {
        let handle = ThreadOpsSystem.currentThread
        return NIOThread(handle: handle, desiredName: nil)
    }
}

extension NIOThread: CustomStringConvertible {
    var description: String {
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

/// A `ThreadSpecificVariable` is a variable that can be read and set like a normal variable except that it holds
/// different variables per thread.
///
/// `ThreadSpecificVariable` is thread-safe so it can be used with multiple threads at the same time but the value
/// returned by `currentValue` is defined per thread.
public final class ThreadSpecificVariable<Value: AnyObject> {
    /* the actual type in there is `Box<(ThreadSpecificVariable<T>, T)>` but we can't use that as C functions can't capture (even types) */
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
            return ThreadOpsSystem.getThreadSpecificValue(self.underlyingKey)
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
    /// - parameters:
    ///   - value: The value to set for the calling thread.
    public convenience init(value: Value) {
        self.init()
        self.currentValue = value
    }

    /// The value for the current thread.
    public var currentValue: Value? {
        /// Get the current value for the calling thread.
        get {
            guard let raw = self.key.get() else { return nil }
          // parenthesize the return value to silence the cast warning
          return (Unmanaged<BoxedType>
                   .fromOpaque(raw)
                   .takeUnretainedValue()
                   .value.1 as! Value)
        }

        /// Set the current value for the calling threads. The `currentValue` for all other threads remains unchanged.
        set {
            if let raw = self.key.get() {
                Unmanaged<BoxedType>.fromOpaque(raw).release()
            }
            self.key.set(value: newValue.map { Unmanaged.passRetained(Box((self, $0))).toOpaque() })
        }
    }
}

extension NIOThread: Equatable {
    static func ==(lhs: NIOThread, rhs: NIOThread) -> Bool {
        return lhs.withUnsafeThreadHandle { lhs in
            rhs.withUnsafeThreadHandle { rhs in
                ThreadOpsSystem.compareThreads(lhs, rhs)
            }
        }
    }
}
