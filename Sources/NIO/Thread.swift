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
#if os(Windows)
import WinSDK
#endif


#if os(Linux)
private let sys_pthread_getname_np = CNIOLinux_pthread_getname_np
private let sys_pthread_setname_np = CNIOLinux_pthread_setname_np
#elseif os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
private let sys_pthread_getname_np = pthread_getname_np
// Emulate the same method signature as pthread_setname_np on Linux.
private func sys_pthread_setname_np(_ p: pthread_t, _ pointer: UnsafePointer<Int8>) -> Int32 {
    assert(pthread_equal(pthread_self(), p) != 0)
    pthread_setname_np(pointer)
    // Will never fail on macOS so just return 0 which will be used on linux to signal it not failed.
    return 0
}
#endif

fileprivate extension NIOThread.NIOThreadHandle {
  static var invalid: NIOThread.NIOThreadHandle {
#if os(Windows)
      return INVALID_HANDLE_VALUE
#elseif os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
      return nil
#else
      return pthread_t()
#endif
  }
}

/// A Thread that executes some runnable block.
///
/// All methods exposed are thread-safe.
final class NIOThread {
#if os(Windows)
    internal typealias NIOThreadHandle = HANDLE
#elseif os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
    internal typealias NIOThreadHandle = pthread_t?
#else
    internal typealias NIOThreadHandle = pthread_t
#endif

    private typealias ThreadBoxValue = (body: (NIOThread) -> Void, name: String?)
    private typealias ThreadBox = Box<ThreadBoxValue>

    private let desiredName: String?

    /// The thread handle used by this instance.
    private let handle: NIOThreadHandle

    /// Create a new instance
    ///
    /// - arguments:
    ///     - handle: The `NIOThreadHandle` that is wrapped and used by the `NIOThread`.
    private init(handle: NIOThreadHandle, desiredName: String?) {
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
#if !os(Windows)
    internal func withUnsafePthread<T>(_ body: (pthread_t) throws -> T) rethrows -> T {
        return try body((self.handle as pthread_t?)!)
    }
#endif

    /// Get current name of the `NIOThread` or `nil` if not set.
    var currentName: String? {
#if os(Windows)
        var pszBuffer: PWSTR?
        GetThreadDescription(self.handle, &pszBuffer)
        guard let buffer = pszBuffer else { return nil }
        let string: String = String(decodingCString: buffer, as: UTF16.self)
        LocalFree(buffer)
        return string
#else
        // 64 bytes should be good enough as on Linux the limit is usually 16
        // and it's very unlikely a user will ever set something longer
        // anyway.
        var chars: [CChar] = Array(repeating: 0, count: 64)
        return chars.withUnsafeMutableBufferPointer { ptr in
            guard sys_pthread_getname_np((self.handle as pthread_t?)!, ptr.baseAddress!, ptr.count) == 0 else {
                return nil
            }

            let buffer: UnsafeRawBufferPointer =
                UnsafeRawBufferPointer(UnsafeBufferPointer<CChar>(rebasing: ptr.prefix { $0 != 0 }))
            return String(decoding: buffer, as: Unicode.UTF8.self)
        }
#endif
    }

    func join() {
#if os(Windows)
        let dwResult: DWORD = WaitForSingleObject(self.handle, INFINITE)
        assert(dwResult == WAIT_OBJECT_0, "WaitForSingleObject: \(GetLastError())")
#else
        let err = pthread_join((self.handle as pthread_t?)!, nil)
        assert(err == 0, "pthread_join failed with \(err)")
#endif
    }

    /// Spawns and runs some task in a `NIOThread`.
    ///
    /// - arguments:
    ///     - name: The name of the `NIOThread` or `nil` if no specific name should be set.
    ///     - body: The function to execute within the spawned `NIOThread`.
    ///     - detach: Whether to detach the thread. If the thread is not detached it must be `join`ed.
    static func spawnAndRun(name: String? = nil, detachThread: Bool = true,
                            body: @escaping (NIOThread) -> Void) {
        var handle: NIOThreadHandle = .invalid

        // Store everything we want to pass into the c function in a Box so we
        // can hand-over the reference.
        let tuple: ThreadBoxValue = (body: body, name: name)
        let box = ThreadBox(tuple)

        let argv0 = Unmanaged.passRetained(box).toOpaque()

#if os(Windows)
        // FIXME(compnerd) this should use the `stdcall` calling convention
        let routine: @convention(c) (UnsafeMutableRawPointer?) -> CUnsignedInt = {
            let boxed = Unmanaged<ThreadBox>.fromOpaque($0!).takeRetainedValue()
            let (body, name) = (boxed.value.body, boxed.value.name)
            let hThread: NIOThreadHandle = GetCurrentThread()

            if let name = name {
                _ = name.withCString(encodedAs: UTF16.self) {
                    SetThreadDescription(hThread, $0)
                }
            }

            body(NIOThread(handle: hThread, desiredName: name))

            return 0
        }
        let hThread: HANDLE =
            HANDLE(bitPattern: _beginthreadex(nil, 0, routine, argv0, 0, nil))!

        if detachThread {
            CloseHandle(hThread)
        }
#else
        let res = pthread_create(&handle, nil, {
            // Cast to UnsafeMutableRawPointer? and force unwrap to make the
            // same code work on macOS and Linux.
            let boxed = Unmanaged<ThreadBox>
                          .fromOpaque(($0 as UnsafeMutableRawPointer?)!)
                          .takeRetainedValue()
            let (body, name) = (boxed.value.body, boxed.value.name)
            let hThread: NIOThreadHandle = pthread_self()

            if let name = name {
                // this is non-critical so we ignore the result here, we've seen
                // EPERM in containers.
                _ = sys_pthread_setname_np((hThread as pthread_t?)!, name)
            }

            body(NIOThread(handle: hThread, desiredName: name))

            return nil
        }, argv0)
        precondition(res == 0, "Unable to create thread: \(res)")

        if detachThread {
            let detachError = pthread_detach((handle as pthread_t?)!)
            precondition(detachError == 0, "pthread_detach failed with error \(detachError)")
        }
#endif
    }

    /// Returns `true` if the calling thread is the same as this one.
    var isCurrent: Bool {
#if os(Windows)
        return CompareObjectHandles(self.handle, GetCurrentThread())
#else
        return pthread_equal(self.handle, pthread_self()) != 0
#endif
    }

    /// Returns the current running `NIOThread`.
    static var current: NIOThread {
#if os(Windows)
        let hThread: NIOThreadHandle = GetCurrentThread()
#else
        let hThread: NIOThreadHandle = pthread_self()
#endif
        return NIOThread(handle: hThread, desiredName: nil)
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

    private class Key {
#if os(Windows)
        private var value: DWORD
#else
        private var value: pthread_key_t
#endif

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        public typealias KeyDestructor =
            @convention(c) (UnsafeMutableRawPointer) -> Void
#else
        public typealias KeyDestructor =
            @convention(c) (UnsafeMutableRawPointer?) -> Void
#endif

        public init(destructor: KeyDestructor?) {
#if os(Windows)
            self.value = FlsAlloc(destructor)
#else
            self.value = pthread_key_t()
            let result = pthread_key_create(&self.value, destructor)
            precondition(result == 0, "pthread_key_create failed: \(result)")
#endif
        }

        deinit {
#if os(Windows)
            let dwResult: Bool = FlsFree(self.value)
            precondition(dwResult, "FlsFree: \(GetLastError())")
#else
            let result = pthread_key_delete(self.value)
            precondition(result == 0, "pthread_key_delete failed: \(result)")
#endif
        }

        public static func get(for key: Key) -> UnsafeMutableRawPointer? {
#if os(Windows)
            return FlsGetValue(key.value)
#else
            return pthread_getspecific(key.value)
#endif
        }

        public static func set(value: UnsafeMutableRawPointer?, for key: Key) {
#if os(Windows)
            FlsSetValue(key.value, value)
#else
            let result = pthread_setspecific(key.value, value)
            precondition(result == 0, "pthread_setspecific failed: \(result)")
#endif
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
          guard let raw = Key.get(for: self.key) else { return nil }
          // parenthesize the return value to silence the cast warning
          return (Unmanaged<BoxedType>
                   .fromOpaque(raw)
                   .takeUnretainedValue()
                   .value.1 as! Value)
        }

        /// Set the current value for the calling threads. The `currentValue` for all other threads remains unchanged.
        set {
            if let raw = Key.get(for: self.key) {
                Unmanaged<BoxedType>.fromOpaque(raw).release()
            }
            Key.set(value: newValue.map { Unmanaged.passRetained(Box((self, $0))).toOpaque() },
                    for: self.key)
        }
    }
}

extension NIOThread: Equatable {
    static func ==(lhs: NIOThread, rhs: NIOThread) -> Bool {
#if os(Windows)
        return CompareObjectHandles(lhs.handle, rhs.handle)
#else
        return pthread_equal(lhs.handle, rhs.handle) != 0
#endif
    }
}
