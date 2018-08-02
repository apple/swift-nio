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

import CNIOLinux

private typealias ThreadBoxValue = (body: (Thread) -> Void, name: String?)
private typealias ThreadBox = Box<ThreadBoxValue>


#if os(Linux)
private let sys_pthread_getname_np = CNIOLinux_pthread_getname_np
private let sys_pthread_setname_np = CNIOLinux_pthread_setname_np
#else
private let sys_pthread_getname_np = pthread_getname_np
// Emulate the same method signature as pthread_setname_np on Linux.
private func sys_pthread_setname_np(_ p: pthread_t, _ pointer: UnsafePointer<Int8>) -> Int32 {
    assert(pthread_equal(pthread_self(), p) != 0)
    pthread_setname_np(pointer)
    // Will never fail on macOS so just return 0 which will be used on linux to signal it not failed.
    return 0
}
#endif

/// A Thread that executes some runnable block.
///
/// All methods exposed are thread-safe.
final class Thread {

    /// The pthread_t used by this instance.
    private let pthread: pthread_t

    /// Create a new instance
    ///
    /// - arguments:
    ///     - pthread: The `pthread_t` that is wrapped and used by the `Thread`.
    private init(pthread: pthread_t) {
        self.pthread = pthread
    }

    /// Execute the given body with the `pthread_t` that is used by this `Thread` as argument.
    ///
    /// - warning: Do not escape `pthread_t` from the closure for later use.
    ///
    /// - parameters:
    ///     - body: The closure that will accept the `pthread_t`.
    /// - returns: The value returned by `fn`.
    func withUnsafePthread<T>(_ body: (pthread_t) throws -> T) rethrows -> T {
        return try body(self.pthread)
    }

    /// Get current name of the `Thread` or `nil` if not set.
    var name: String? {
        get {
            // 64 bytes should be good enough as on Linux the limit is usually 16 and it's very unlikely a user will ever set something longer anyway.
            var chars: [CChar] = Array(repeating: 0, count: 64)
            guard sys_pthread_getname_np(pthread, &chars, chars.count) == 0 else {
                return nil
            }
            return String(cString: chars)
        }
    }

    /// Spawns and runs some task in a `Thread`.
    ///
    /// - arguments:
    ///     - name: The name of the `Thread` or `nil` if no specific name should be set.
    ///     - body: The function to execute within the spawned `Thread`.
    static func spawnAndRun(name: String? = nil, body: @escaping (Thread) -> Void) {
        // Unfortunately the pthread_create method take a different first argument depending on if it's on Linux or macOS, so ensure we use the correct one.
        #if os(Linux)
            var pt: pthread_t = pthread_t()
        #else
            var pt: pthread_t? = nil
        #endif

        // Store everything we want to pass into the c function in a Box so we can hand-over the reference.
        let tuple: ThreadBoxValue = (body: body, name: name)
        let box = ThreadBox(tuple)
        let res = pthread_create(&pt, nil, { p in
            // Cast to UnsafeMutableRawPointer? and force unwrap to make the same code work on macOS and Linux.
            let b = Unmanaged<ThreadBox>.fromOpaque((p as UnsafeMutableRawPointer?)!).takeRetainedValue()

            let body = b.value.body
            let name = b.value.name

            let pt = pthread_self()

            if let threadName = name {
                let res = sys_pthread_setname_np(pt, threadName)
                // This should only happen in case of a too-long name.
                precondition(res == 0, "pthread_setname_np failed for '\(threadName)': \(res)")
            }

            body(Thread(pthread: pt))
            return nil
        }, Unmanaged.passRetained(box).toOpaque())

        precondition(res == 0, "Unable to create thread: \(res)")

        let detachError = pthread_detach((pt as pthread_t?)!)
        precondition(detachError == 0, "pthread_detach failed with error \(detachError)")
    }

    /// Returns `true` if the calling thread is the same as this one.
    var isCurrent: Bool {
        return pthread_equal(pthread, pthread_self()) != 0
    }

    /// Returns the current running `Thread`.
    static var current: Thread {
        return Thread(pthread: pthread_self())
    }
}

/// A `ThreadSpecificVariable` is a variable that can be read and set like a normal variable except that it holds
/// different variables per thread.
///
/// `ThreadSpecificVariable` is thread-safe so it can be used with multiple threads at the same time but the value
/// returned by `currentValue` is defined per thread.
///
/// - note: `ThreadSpecificVariable` has reference semantics.
public struct ThreadSpecificVariable<T: AnyObject> {
    private let key: pthread_key_t

    /// Initialize a new `ThreadSpecificVariable` without a current value (`currentValue == nil`).
    public init() {
        var key = pthread_key_t()
        let pthreadErr = pthread_key_create(&key) { ptr in
            Unmanaged<AnyObject>.fromOpaque((ptr as UnsafeMutableRawPointer?)!).release()
        }
        precondition(pthreadErr == 0, "pthread_key_create failed, error \(pthreadErr)")
        self.key = key
    }

    /// Initialize a new `ThreadSpecificVariable` with `value` for the calling thread. After calling this, the calling
    /// thread will see `currentValue == value` but on all other threads `currentValue` will be `nil` until changed.
    ///
    /// - parameters:
    ///   - value: The value to set for the calling thread.
    public init(value: T) {
        self.init()
        self.currentValue = value
    }

    /// The value for the current thread.
    public var currentValue: T? {
        /// Get the current value for the calling thread.
        get {
            guard let raw = pthread_getspecific(self.key) else {
                return nil
            }
            return Unmanaged<T>.fromOpaque(raw).takeUnretainedValue()
        }

        /// Set the current value for the calling threads. The `currentValue` for all other threads remains unchanged.
        nonmutating set {
            if let raw = pthread_getspecific(self.key) {
                Unmanaged<T>.fromOpaque(raw).release()
            }
            let pthreadErr = pthread_setspecific(self.key, newValue.map { v -> UnsafeMutableRawPointer in
                Unmanaged.passRetained(v).toOpaque()
            })
            precondition(pthreadErr == 0, "pthread_setspecific failed, error \(pthreadErr)")
        }
    }
}

extension Thread: Equatable {
    public static func ==(lhs: Thread, rhs: Thread) -> Bool {
        return pthread_equal(lhs.pthread, rhs.pthread) != 0
    }
}
