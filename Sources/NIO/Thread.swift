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

/// A Thread that executes some runnable block.
///
/// All methods exposed are thread-safe.
final class Thread {
    
    /// The pthread_t used by this instance.
    let pthread: pthread_t
    
    /// Create a new instance
    ///
    /// - arguments:
    ///     - pthread: The `pthread_t` that is wrapped and used by the `Thread`.
    private init(pthread: pthread_t) {
        self.pthread = pthread
    }
    
    /// Get current name of the `Thread` or `nil` if not set.
    var name: String? {
        get {
            // 64 bytes should be good enough as on linux the limit is usually 16 and its very unlikely a user will ever set something longer anyway.
            var chars: [CChar] = Array(repeating: 0, count: 64)
            #if os(Linux)
                guard CNIOLinux_pthread_getname_np(pthread, &chars, chars.count) == 0 else {
                    return nil
                }
            #else
                guard pthread_getname_np(pthread, &chars, chars.count) == 0 else {
                    return nil
                }
            #endif
            return String(cString: chars)
        }
    }
    
    /// Spawns and runs some task in a `Thread`.
    ///
    /// - arguments:
    ///     - name: The name of the `Thread` or `nil` if no specific name should be set.
    ///     - body: The function to execute within the spawned `Thread`.
    class func spawnAndRun(name: String? = nil, body: @escaping (Thread) -> Void) {
        // Unfortunally the pthread_create method take a different first argument depending on if its on linux or macOS, so ensure we use the correct one.
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
            let b = Unmanaged<ThreadBox>.fromOpaque((p as UnsafeMutableRawPointer?)!.assumingMemoryBound(to: ThreadBox.self)).takeRetainedValue()
            
            let fn = b.value.body
            let name = b.value.name
            
            let pt = pthread_self()
            
            if let threadName = name {
                #if os(Linux)
                    let res = CNIOLinux_pthread_setname_np(pt, threadName)
                    guard res == 0 else {
                        // This should only happen in case of a too-long name.
                        fatalError("Unable to set thread name '\(threadName)': \(res)")
                    }
                #else
                    // On macOS this will never fail.
                    pthread_setname_np(threadName)
                #endif
            }

            fn(Thread(pthread: pt))
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

extension Thread : Equatable {
    public static func ==(lhs: Thread, rhs: Thread) -> Bool {
        return pthread_equal(lhs.pthread, rhs.pthread) != 0
    }
}
