//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
import WinSDK
#elseif canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Bionic)
@preconcurrency import Bionic
#elseif canImport(WASILibc)
@preconcurrency import WASILibc
#if canImport(wasi_pthread)
import wasi_pthread
#endif
#else
#error("The NIOThreadPoolWorkAvailable module was unable to identify your C library.")
#endif

/// A specialized synchronization primitive for ``NIOThreadPool`` that uses
/// `pthread_cond_signal` (wake-one) instead of `pthread_cond_broadcast` (wake-all)
/// when work is enqueued, eliminating the thundering-herd problem.
///
/// This type manages a `workAvailable` counter under a mutex, paired with a
/// condition variable. Threads waiting for work block until `workAvailable > 0`.
@usableFromInline
package struct NIOThreadPoolWorkAvailable: @unchecked Sendable {
    @usableFromInline
    final class _Storage {
        @usableFromInline
        let lock: NIOLock

        @usableFromInline
        var workAvailable: Int

        #if os(Windows)
        @usableFromInline
        let cond: UnsafeMutablePointer<CONDITION_VARIABLE> =
            UnsafeMutablePointer.allocate(capacity: 1)
        #elseif os(OpenBSD)
        @usableFromInline
        let cond: UnsafeMutablePointer<pthread_cond_t?> =
            UnsafeMutablePointer.allocate(capacity: 1)
        #elseif (compiler(<6.1) && !os(WASI)) || (compiler(>=6.1) && _runtime(_multithreaded))
        @usableFromInline
        let cond: UnsafeMutablePointer<pthread_cond_t> =
            UnsafeMutablePointer.allocate(capacity: 1)
        #endif

        @usableFromInline
        init() {
            self.lock = NIOLock()
            self.workAvailable = 0
            #if os(Windows)
            InitializeConditionVariable(self.cond)
            #elseif (compiler(<6.1) && !os(WASI)) || (compiler(>=6.1) && _runtime(_multithreaded))
            let err = pthread_cond_init(self.cond, nil)
            precondition(err == 0, "\(#function) failed in pthread_cond_init with error \(err)")
            #endif
        }

        deinit {
            #if os(Windows)
            // condition variables do not need to be explicitly destroyed
            self.cond.deallocate()
            #elseif (compiler(<6.1) && !os(WASI)) || (compiler(>=6.1) && _runtime(_multithreaded))
            let err = pthread_cond_destroy(self.cond)
            precondition(err == 0, "\(#function) failed in pthread_cond_destroy with error \(err)")
            self.cond.deallocate()
            #endif
        }
    }

    @usableFromInline
    let _storage: _Storage

    @usableFromInline
    package enum Signal: Sendable {
        /// No signal after unlock.
        case none
        /// Wake one waiting thread (``pthread_cond_signal``).
        case signalOne
        /// Wake all waiting threads (``pthread_cond_broadcast``).
        case broadcastAll
    }

    @inlinable
    package init() {
        self._storage = _Storage()
    }

    /// Lock, run `body` with access to the `workAvailable` counter,
    /// unlock, then signal as indicated by the return value.
    @inlinable
    package func withLock<Result>(
        _ body: (inout Int) -> (signal: Signal, result: Result)
    ) -> Result {
        self._storage.lock.lock()
        let (signal, result) = body(&self._storage.workAvailable)
        self._storage.lock.unlock()
        self._signal(signal)
        return result
    }

    /// Lock, wait while `workAvailable <= 0`, run `body` with access to the
    /// `workAvailable` counter, unlock, then signal as indicated.
    @inlinable
    package func withLockWaitingForWork<Result>(
        _ body: (inout Int) -> (signal: Signal, result: Result)
    ) -> Result {
        self._storage.lock.lock()
        while self._storage.workAvailable <= 0 {
            self._storage.lock.withLockPrimitive { mutex in
                #if os(Windows)
                let ok = SleepConditionVariableSRW(self._storage.cond, mutex, INFINITE, 0)
                precondition(
                    ok,
                    "\(#function) failed in SleepConditionVariableSRW with error \(GetLastError())"
                )
                #elseif (compiler(<6.1) && !os(WASI)) || (compiler(>=6.1) && _runtime(_multithreaded))
                let err = pthread_cond_wait(self._storage.cond, mutex)
                precondition(err == 0, "\(#function) failed in pthread_cond_wait with error \(err)")
                #endif
            }
        }
        let (signal, result) = body(&self._storage.workAvailable)
        self._storage.lock.unlock()
        self._signal(signal)
        return result
    }

    @inlinable
    func _signal(_ signal: Signal) {
        switch signal {
        case .none:
            break
        case .signalOne:
            #if os(Windows)
            WakeConditionVariable(self._storage.cond)
            #elseif (compiler(<6.1) && !os(WASI)) || (compiler(>=6.1) && _runtime(_multithreaded))
            let err = pthread_cond_signal(self._storage.cond)
            precondition(err == 0, "\(#function) failed in pthread_cond_signal with error \(err)")
            #endif
        case .broadcastAll:
            #if os(Windows)
            WakeAllConditionVariable(self._storage.cond)
            #elseif (compiler(<6.1) && !os(WASI)) || (compiler(>=6.1) && _runtime(_multithreaded))
            let err = pthread_cond_broadcast(self._storage.cond)
            precondition(err == 0, "\(#function) failed in pthread_cond_broadcast with error \(err)")
            #endif
        }
    }
}
