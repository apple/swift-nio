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

import CNIOOpenSSL

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    import Darwin
#else
    import Glibc
#endif

private let callbackLock: UnsafeMutablePointer<pthread_mutex_t> =  {
    var ptr = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    let err = pthread_mutex_init(ptr, nil)
    precondition(err == 0)
    return ptr
}()

private var sslLocks: UnsafeMutablePointer<pthread_mutex_t>!

func initializeOpenSSL() -> Bool {
    // Initializing OpenSSL is made up of two steps. First, we need to load all the various crypto bits.
    SSL_library_init()
    OPENSSL_add_all_algorithms_conf()
    SSL_load_error_strings()
    ERR_load_crypto_strings()
    OPENSSL_config(nil)
    
    // Then, we need to set up the OpenSSL locking callbacks. This is pretty annoying, and also requires synchronization in case
    // we're doing this from multiple threads concurrently. Sadly this means we can block the I/O thread on this activity:
    // there's not much that can be done about that, sadly.
    var err = pthread_mutex_lock(callbackLock)
    precondition(err == 0)
    if CRYPTO_get_locking_callback() == nil { setupLockingCallbacks() }
    err = pthread_mutex_unlock(callbackLock)
    precondition(err == 0)
    return true
}

private func setupLockingCallbacks() {
    // The default OpenSSL locking callback structure requires an array of locks
    // that can be locked by index. Is this insane? Yes, yes it is. But here we are,
    // so let's reimplement this in Swift. Because if we have to do stupid insane things
    // to keep OpenSSL happy, the least we can do is do those stupid insane things in
    // a *type-safe* way.
    let lockCount = Int(CRYPTO_num_locks())
    sslLocks = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: lockCount)

    // An enterprising developer looking at this code may note that we technically loop over
    // our array twice: once to copy an unitialized pthread_mutex_t into each element of the
    // array, and then once again to call pthread_mutex_init. Such a developer might get it
    // into their head that this could be optimized by instead calling pthread_mutex_init
    // just once and then using sslLocks.initialize to copy that init-ed mutex into each
    // element of the array.
    //
    // This developer, much like Icarus, has flown too close to the sun. You see,
    // IEEE Std 1003.1-2001 doesn't define assignment or equality for pthread_mutex_t. This
    // means that, for example, a pthread_mutex_t could be just a reference to a heap-allocated
    // structure that handles the actual locking. If this were the case, copying the init-ed
    // mutex would lead us to have an array of "locks" all of which are actually aliased copies
    // of the same lock. It seems to me that this would be unlikely to go well. For this reason
    // we play it safe and do the loop twice.
    sslLocks.initialize(to: pthread_mutex_t())
    for index in 0..<lockCount {
        let err = pthread_mutex_init(&sslLocks[index], nil)
        precondition(err == 0)
    }
    
    CRYPTO_set_id_callback(getThreadID)
    CRYPTO_set_locking_callback(opensslLockingCallback)
}

private func opensslLockingCallback(mode: Int32, index: Int32, callingFile: UnsafePointer<Int8>?, callingLine: Int32) {
    if (mode & CRYPTO_LOCK) != 0 {
        let err = pthread_mutex_lock(&sslLocks[Int(index)])
        precondition(err == 0)
    } else {
        let err = pthread_mutex_unlock(&sslLocks[Int(index)])
        precondition(err == 0)
    }
}

private func getThreadID() -> UInt {
    #if os(Linux)
    return UInt(pthread_self())
    #else  // Darwin
    return UInt(bitPattern:pthread_self())
    #endif
}
