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
#if canImport(Glibc) || canImport(Musl)
import CNIOLinux

private let sys_pthread_getname_np = CNIOLinux_pthread_getname_np
private let sys_pthread_setname_np = CNIOLinux_pthread_setname_np
private typealias ThreadDestructor = @convention(c) (UnsafeMutableRawPointer?) ->
    UnsafeMutableRawPointer?
#elseif canImport(Darwin)
import Darwin

private let sys_pthread_getname_np = pthread_getname_np
// Emulate the same method signature as pthread_setname_np on Linux.
private func sys_pthread_setname_np(_ p: pthread_t, _ pointer: UnsafePointer<Int8>) -> Int32 {
    assert(pthread_equal(pthread_self(), p) != 0)
    pthread_setname_np(pointer)
    // Will never fail on macOS so just return 0 which will be used on linux to signal it not failed.
    return 0
}
private typealias ThreadDestructor = @convention(c) (UnsafeMutableRawPointer) ->
    UnsafeMutableRawPointer?
#endif

private func sysPthread_create(
    handle: UnsafeMutablePointer<pthread_t?>,
    destructor: @escaping ThreadDestructor,
    args: UnsafeMutableRawPointer?
) -> CInt {
    #if canImport(Darwin)
    return pthread_create(handle, nil, destructor, args)
    #elseif canImport(Glibc) || canImport(Musl)
    #if canImport(Glibc)
    var handleLinux = pthread_t()
    #else
    var handleLinux = pthread_t(bitPattern: 0)
    #endif
    let result = pthread_create(
        &handleLinux,
        nil,
        destructor,
        args
    )
    handle.pointee = handleLinux
    return result
    #endif
}

typealias ThreadOpsSystem = ThreadOpsPosix

enum ThreadOpsPosix: ThreadOps {
    typealias ThreadHandle = pthread_t
    typealias ThreadSpecificKey = pthread_key_t
    #if canImport(Darwin)
    typealias ThreadSpecificKeyDestructor = @convention(c) (UnsafeMutableRawPointer) -> Void
    #elseif canImport(Glibc) || canImport(Musl)
    typealias ThreadSpecificKeyDestructor = @convention(c) (UnsafeMutableRawPointer?) -> Void
    #endif

    static func threadName(_ thread: ThreadOpsSystem.ThreadHandle) -> String? {
        // 64 bytes should be good enough as on Linux the limit is usually 16
        // and it's very unlikely a user will ever set something longer
        // anyway.
        var chars: [CChar] = Array(repeating: 0, count: 64)
        return chars.withUnsafeMutableBufferPointer { ptr in
            guard sys_pthread_getname_np(thread, ptr.baseAddress!, ptr.count) == 0 else {
                return nil
            }

            let buffer: UnsafeRawBufferPointer =
                UnsafeRawBufferPointer(UnsafeBufferPointer<CChar>(rebasing: ptr.prefix { $0 != 0 }))
            return String(decoding: buffer, as: Unicode.UTF8.self)
        }
    }

    static func run(
        handle: inout ThreadOpsSystem.ThreadHandle?,
        args: Ref<Thread.ThreadBoxValue>,
        detachThread: Bool
    ) {
        let argv0 = Unmanaged.passRetained(args).toOpaque()
        let res = sysPthread_create(
            handle: &handle,
            destructor: {
                // Cast to UnsafeMutableRawPointer? and force unwrap to make the
                // same code work on macOS and Linux.
                let boxed = Unmanaged<Thread.ThreadBox>
                    .fromOpaque(($0 as UnsafeMutableRawPointer?)!)
                    .takeRetainedValue()
                let (body, name) = (boxed.value.body, boxed.value.name)
                let hThread: ThreadOpsSystem.ThreadHandle = pthread_self()

                if let name = name {
                    let maximumThreadNameLength: Int
                    #if canImport(Glibc) || canImport(Musl)
                    maximumThreadNameLength = 15
                    #elseif canImport(Darwin)
                    maximumThreadNameLength = .max
                    #endif
                    name.prefix(maximumThreadNameLength).withCString { namePtr in
                        // this is non-critical so we ignore the result here, we've seen
                        // EPERM in containers.
                        _ = sys_pthread_setname_np(hThread, namePtr)
                    }
                }

                body(Thread(handle: hThread, desiredName: name))

                return nil
            },
            args: argv0
        )
        precondition(res == 0, "Unable to create thread: \(res)")

        if detachThread {
            let detachError = pthread_detach(handle!)
            precondition(detachError == 0, "pthread_detach failed with error \(detachError)")
        }

    }

    static func joinThread(_ thread: ThreadOpsSystem.ThreadHandle) {
        let err = pthread_join(thread, nil)
        assert(err == 0, "pthread_join failed with \(err)")
    }

    static func compareThreads(
        _ lhs: ThreadOpsSystem.ThreadHandle,
        _ rhs: ThreadOpsSystem.ThreadHandle
    ) -> Bool {
        return pthread_equal(lhs, rhs) != 0
    }
}
#endif
