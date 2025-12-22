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

import Atomics
import NIOCore

private protocol SilenceWarning {
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func enqueue(_ job: UnownedJob)
}
@available(macOS 14, *)
extension SelectableEventLoop: SilenceWarning {}

private let _haveWeTakenOverTheConcurrencyPool = ManagedAtomic(false)
extension NIOSingletons {
    /// Install ``MultiThreadedEventLoopGroup/singleton`` as Swift Concurrency's global executor.
    ///
    /// This allows to use Swift Concurrency and retain high-performance I/O alleviating the otherwise necessary thread switches between
    /// Swift Concurrency's own global pool and a place (like an `EventLoop`) that allows to perform I/O
    ///
    /// This method uses an atomic compare and exchange to install the hook (and makes sure it's not already set). This unilateral atomic memory
    /// operation doesn't guarantee anything because another piece of code could have done the same without using atomic operations. But we
    /// do our best.
    ///
    /// - Returns: If ``MultiThreadedEventLoopGroup/singleton`` was successfully installed as Swift Concurrency's global executor or not.
    ///
    /// - warning: You may only call this method from the main thread.
    /// - warning: You may only call this method once.
    /// - warning: This method is currently not supported on Windows and will return false.
    @discardableResult
    public static func unsafeTryInstallSingletonPosixEventLoopGroupAsConcurrencyGlobalExecutor() -> Bool {
        #if os(Windows)
        return false
        #else
        // Guard between the minimum and maximum supported version for the hook
        #if compiler(<6.4)
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) else {
            return false
        }

        typealias ConcurrencyEnqueueGlobalHook =
            @convention(thin) (
                UnownedJob, @convention(thin) (UnownedJob) -> Void
            ) -> Void

        guard
            _haveWeTakenOverTheConcurrencyPool.compareExchange(
                expected: false,
                desired: true,
                ordering: .relaxed
            ).exchanged
        else {
            fatalError("Must be called only once")
        }

        #if canImport(Darwin)
        guard pthread_main_np() == 1 else {
            fatalError("Must be called from the main thread")
        }
        #endif

        // Unsafe 1: We pretend that the hook's type is actually fully equivalent to `ConcurrencyEnqueueGlobalHook`
        //   @convention(thin) (UnownedJob, @convention(thin) (UnownedJob) -> Void) -> Void
        // which isn't formally guaranteed.
        let concurrencyEnqueueGlobalHookPtr = dlsym(
            dlopen(nil, RTLD_NOW),
            "swift_task_enqueueGlobal_hook"
        )?.assumingMemoryBound(to: UnsafeRawPointer?.AtomicRep.self)
        guard let concurrencyEnqueueGlobalHookPtr = concurrencyEnqueueGlobalHookPtr else {
            return false
        }

        // We will use an atomic operation to swap the pointers aiming to protect against other code that attempts
        // to swap the pointer. This isn't guaranteed to work as we can't be sure that the other code will actually
        // use atomic compares and exchanges to. Nevertheless, we're doing our best.
        let concurrencyEnqueueGlobalHookAtomic = UnsafeAtomic<UnsafeRawPointer?>(at: concurrencyEnqueueGlobalHookPtr)
        // note: We don't need to destroy this atomic as we're borrowing the storage from `dlsym`.

        return withUnsafeTemporaryAllocation(
            of: ConcurrencyEnqueueGlobalHook.self,
            capacity: 1
        ) { enqueueOnNIOPtr -> Bool in
            // Unsafe 2: We mandate that we're actually getting _the_ function pointer to the closure below which
            // isn't formally guaranteed by Swift.
            enqueueOnNIOPtr.baseAddress!.initialize(to: { job, _ in
                // This formally picks a random EventLoop from the singleton group. However, `EventLoopGroup.any()`
                // attempts to be sticky. So if we're already in an `EventLoop` that's part of the singleton
                // `EventLoopGroup`, we'll get that one and be very fast (avoid a thread switch).
                let targetEL = MultiThreadedEventLoopGroup.singleton.any()

                (targetEL.executor as! any SilenceWarning).enqueue(job)
            })

            // Unsafe 3: We mandate that the function pointer can be reinterpreted as `UnsafeRawPointer` which isn't
            // formally guaranteed by Swift
            return enqueueOnNIOPtr.baseAddress!.withMemoryRebound(
                to: UnsafeRawPointer.self,
                capacity: 1
            ) { enqueueOnNIOPtr in
                // Unsafe 4: We just pretend that we're the only ones in the world pulling this trick (or at least
                // that the others also use a `compareExchange`)...
                guard
                    concurrencyEnqueueGlobalHookAtomic.compareExchange(
                        expected: nil,
                        desired: enqueueOnNIOPtr.pointee,
                        ordering: .relaxed
                    ).exchanged
                else {
                    return false
                }

                // nice, everything worked.
                return true
            }
        }
        #else
        return false
        #endif
        #endif  // windows unimplemented
    }
}

// Workaround for https://github.com/apple/swift-nio/issues/2893
extension Optional
where
    Wrapped: AtomicOptionalWrappable,
    Wrapped.AtomicRepresentation.Value == Wrapped
{
    typealias AtomicRep = Wrapped.AtomicOptionalRepresentation
}
