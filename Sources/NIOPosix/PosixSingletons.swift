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

import NIOCore

extension NIOGlobalSingletons {
    /// A globally shared, lazily initialized ``MultiThreadedEventLoopGroup``  that uses `epoll`/`kqueue` as the
    /// selector mechanism.
    ///
    /// The number of threads is determined by ``NIOGlobalSingletons/suggestedGlobalSingletonGroupLoopCount``.
    public static var posixEventLoopGroup: MultiThreadedEventLoopGroup {
        return globalSingletonMTELG
    }

    /// A globally shared, lazily initialized ``NIOThreadPool`` that can be used for blocking I/O and other blocking operations.
    ///
    /// The number of threads is determined by ``NIOGlobalSingletons/suggestedBlockingPoolThreadCount``.
    public static var posixBlockingThreadPool: NIOThreadPool {
        return globalPosixBlockingPool
    }
}

extension MultiThreadedEventLoopGroup {
    /// A globally shared, singleton ``MultiThreadedEventLoopGroup``.
    ///
    /// SwiftNIO allows and encourages the precise management of all operating system resources such as threads and file descriptors.
    /// Certain resources (such as the main ``EventLoopGroup``) however are usually globally shared across the program. This means
    /// that many programs have to carry around an ``EventLoopGroup`` despite the fact they don't require the ability to fully return
    /// all the operating resources which would imply shutting down the ``EventLoopGroup``. This type is the global handle for singleton
    /// resources that applications (and some libraries) can use to obtain never-shut-down singleton resources.
    ///
    /// Programs and libraries that do not use these singletons will not incur extra resource usage, these resources are lazily initialized on
    /// first use.
    ///
    /// The loop count of this group is determined by ``NIOGlobalSingletons/suggestedGlobalSingletonGroupLoopCount``.
    ///
    /// - note: Users who do not want any code to spawn global singleton resources may set
    ///         ``NIOGlobalSingletons/globalSingletonsEnabledSuggestion`` to `false` which will lead to a forced crash
    ///         if any code attempts to use the global singletons.
    ///
    public static var globalSingleton: MultiThreadedEventLoopGroup {
        return NIOGlobalSingletons.posixEventLoopGroup
    }
}

extension EventLoopGroup where Self == MultiThreadedEventLoopGroup {
    /// A globally shared, singleton ``MultiThreadedEventLoopGroup``.
    ///
    /// This provides the same object as ``MultiThreadedEventLoopGroup/globalSingletonMultiThreadedEventLoopGroup``.
    public static var globalSingletonMultiThreadedEventLoopGroup: Self {
        return MultiThreadedEventLoopGroup.globalSingleton
    }
}

extension NIOThreadPool {
    /// A globally shared, singleton ``NIOThreadPool``.
    ///
    /// SwiftNIO allows and encourages the precise management of all operating system resources such as threads and file descriptors.
    /// Certain resources (such as the main ``NIOThreadPool``) however are usually globally shared across the program. This means
    /// that many programs have to carry around an ``NIOThreadPool`` despite the fact they don't require the ability to fully return
    /// all the operating resources which would imply shutting down the ``NIOThreadPool``. This type is the global handle for singleton
    /// resources that applications (and some libraries) can use to obtain never-shut-down singleton resources.
    ///
    /// Programs and libraries that do not use these singletons will not incur extra resource usage, these resources are lazily initialized on
    /// first use.
    ///
    /// The thread count of this pool is determined by ``NIOGlobalSingletons/suggestedBlockingPoolThreadCount``.
    ///
    /// - note: Users who do not want any code to spawn global singleton resources may set
    ///         ``NIOGlobalSingletons/globalSingletonsEnabledSuggestion`` to `false` which will lead to a forced crash
    ///         if any code attempts to use the global singletons.
    public static var globalSingleton: NIOThreadPool {
        return NIOGlobalSingletons.posixBlockingThreadPool
    }
}

private let globalSingletonMTELG: MultiThreadedEventLoopGroup = {
    guard NIOGlobalSingletons.globalSingletonsEnabledSuggestion else {
        fatalError("""
                   Cannot create global singleton MultiThreadedEventLoopGroup because the global singletons have been \
                   disabled by setting  `NIOGlobalSingletons.globalSingletonsEnabledSuggestion = false`
                   """)
    }
    let threadCount = NIOGlobalSingletons.suggestedGlobalSingletonGroupLoopCount
    let group = MultiThreadedEventLoopGroup._makePerpetualGroup(threadNamePrefix: "NIO-SGLTN-",
                                                                numberOfThreads: threadCount)
    _ = Unmanaged.passUnretained(group).retain() // Never gonna give you up,
    return group
}()

private let globalPosixBlockingPool: NIOThreadPool = {
    guard NIOGlobalSingletons.globalSingletonsEnabledSuggestion else {
        fatalError("""
                   Cannot create global singleton NIOThreadPool because the global singletons have been \
                   disabled by setting `NIOGlobalSingletons.globalSingletonsEnabledSuggestion = false`
                   """)
    }
    let pool = NIOThreadPool._makePerpetualStartedPool(
        numberOfThreads: NIOGlobalSingletons.suggestedBlockingPoolThreadCount,
        threadNamePrefix: "SGLTN-TP-#"
    )
    _ = Unmanaged.passUnretained(pool).retain() // never gonna let you down.
    return pool
}()


