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

#if !os(WASI)

#if os(Windows)

import WinSDK

typealias ThreadOpsSystem = ThreadOpsWindows
enum ThreadOpsWindows: ThreadOps {
    /// A Windows kernel thread handle wrapped to make NIO's cross-thread plumbing happy.
    ///
    /// `HANDLE` is an opaque pointer (`LPVOID`) imported from WinSDK, so the compiler can't
    /// auto-conform it to `Sendable`. We mark this wrapper `@unchecked Sendable` because:
    ///
    /// * The Windows kernel handle table is fully thread-safe — referencing, waiting on, and
    ///   closing a HANDLE from any thread is documented as safe (the kernel ref-counts are
    ///   atomic). That's the whole point of using a real, owning HANDLE produced by
    ///   `DuplicateHandle` here, instead of the per-thread pseudo-handle returned by
    ///   `GetCurrentThread`.
    /// * The stored `handle` is `let`, so the wrapper itself has no mutable state for races
    ///   to observe. Each handle is also owned by exactly one `NIOThread`; we hand the wrapper
    ///   between threads (e.g. spawn → join, current-thread queries) but never share the same
    ///   raw HANDLE between multiple owners.
    struct ThreadHandle: @unchecked Sendable {
        let handle: HANDLE
    }
    typealias ThreadSpecificKey = DWORD
    typealias ThreadSpecificKeyDestructor = @convention(c) (UnsafeMutableRawPointer?) -> Void

    static func threadName(_ thread: ThreadOpsSystem.ThreadHandle) -> String? {
        var pszBuffer: PWSTR?
        GetThreadDescription(thread.handle, &pszBuffer)
        guard let buffer = pszBuffer else { return nil }
        let string: String = String(decodingCString: buffer, as: UTF16.self)
        LocalFree(buffer)
        return string
    }

    static func run(
        handle: inout ThreadOpsSystem.ThreadHandle?,
        args: Box<NIOThread.ThreadBoxValue>
    ) {
        let argv0 = Unmanaged.passRetained(args).toOpaque()

        // FIXME(compnerd) this should use the `stdcall` calling convention
        let routine: @convention(c) (UnsafeMutableRawPointer?) -> CUnsignedInt = {
            let boxed = Unmanaged<NIOThread.ThreadBox>.fromOpaque($0!).takeRetainedValue()
            let (body, name) = (boxed.value.body, boxed.value.name)

            // GetCurrentThread() returns a pseudo-handle that is only valid in the
            // current thread's context, so it can't be safely shared with — or used
            // by — any other thread (e.g. for join, WaitForSingleObject, setting the
            // thread description, comparing for equality, etc.). DuplicateHandle
            // promotes the pseudo-handle to a real, owning HANDLE that other threads
            // (and, later, `joinThread`) can use.
            var realHandle: HANDLE? = nil
            let success = DuplicateHandle(
                GetCurrentProcess(),  // Source process
                GetCurrentThread(),  // Source handle (pseudo-handle)
                GetCurrentProcess(),  // Target process
                &realHandle,  // Target handle (real, owning HANDLE)
                0,  // Desired access (0 = same access as source)
                false,  // Inherit handle
                DWORD(DUPLICATE_SAME_ACCESS)  // Options
            )

            guard success, let realHandle else {
                fatalError("DuplicateHandle failed: \(GetLastError())")
            }
            let hThread = ThreadOpsSystem.ThreadHandle(handle: realHandle)

            if let name = name {
                _ = name.withCString(encodedAs: UTF16.self) {
                    SetThreadDescription(hThread.handle, $0)
                }
            }

            body(NIOThread(handle: hThread, desiredName: name))

            return 0
        }
        let hThread: HANDLE =
            HANDLE(bitPattern: _beginthreadex(nil, 0, routine, argv0, 0, nil))!
    }

    static func isCurrentThread(_ thread: ThreadOpsSystem.ThreadHandle) -> Bool {
        CompareObjectHandles(thread.handle, GetCurrentThread())
    }

    static var currentThread: ThreadOpsSystem.ThreadHandle {
        var realHandle: HANDLE? = nil
        let success = DuplicateHandle(
            GetCurrentProcess(),
            GetCurrentThread(),
            GetCurrentProcess(),
            &realHandle,
            0,
            false,
            DWORD(DUPLICATE_SAME_ACCESS)
        )
        guard success, let realHandle else {
            fatalError("DuplicateHandle failed: \(GetLastError())")
        }
        return ThreadHandle(handle: realHandle)
    }

    static func joinThread(_ thread: ThreadOpsSystem.ThreadHandle) {
        let dwResult: DWORD = WaitForSingleObject(thread.handle, INFINITE)
        assert(dwResult == WAIT_OBJECT_0, "WaitForSingleObject: \(GetLastError())")
        // `thread.handle` is a real, owning handle produced by `DuplicateHandle`
        // (in `run`). The kernel keeps the thread object alive until every such
        // handle is closed, so we must release ours now that the join is done.
        CloseHandle(thread.handle)
    }

    static func allocateThreadSpecificValue(destructor: @escaping ThreadSpecificKeyDestructor) -> ThreadSpecificKey {
        FlsAlloc(destructor)
    }

    static func deallocateThreadSpecificValue(_ key: ThreadSpecificKey) {
        let dwResult: Bool = FlsFree(key)
        precondition(dwResult, "FlsFree: \(GetLastError())")
    }

    static func getThreadSpecificValue(_ key: ThreadSpecificKey) -> UnsafeMutableRawPointer? {
        FlsGetValue(key)
    }

    static func setThreadSpecificValue(key: ThreadSpecificKey, value: UnsafeMutableRawPointer?) {
        FlsSetValue(key, value)
    }

    static func compareThreads(_ lhs: ThreadOpsSystem.ThreadHandle, _ rhs: ThreadOpsSystem.ThreadHandle) -> Bool {
        CompareObjectHandles(lhs.handle, rhs.handle)
    }
}

#endif
#endif  // !os(WASI)
