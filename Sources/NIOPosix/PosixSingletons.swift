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

extension NIOSingletons {
    /// A globally shared, lazily initialized ``MultiThreadedEventLoopGroup``  that uses `epoll`/`kqueue` as the
    /// selector mechanism.
    ///
    /// The number of threads is determined by `NIOSingletons/groupLoopCountSuggestion`.
    public static var posixEventLoopGroup: MultiThreadedEventLoopGroup {
        singletonMTELG
    }

    /// A globally shared, lazily initialized ``NIOThreadPool`` that can be used for blocking I/O and other blocking operations.
    ///
    /// The number of threads is determined by `NIOSingletons/blockingPoolThreadCountSuggestion`.
    public static var posixBlockingThreadPool: NIOThreadPool {
        globalPosixBlockingPool
    }
}

extension MultiThreadedEventLoopGroup {
    /// A globally shared, singleton ``MultiThreadedEventLoopGroup``.
    ///
    /// SwiftNIO allows and encourages the precise management of all operating system resources such as threads and file descriptors.
    /// Certain resources (such as the main `EventLoopGroup`) however are usually globally shared across the program. This means
    /// that many programs have to carry around an `EventLoopGroup` despite the fact they don't require the ability to fully return
    /// all the operating resources which would imply shutting down the `EventLoopGroup`. This type is the global handle for singleton
    /// resources that applications (and some libraries) can use to obtain never-shut-down singleton resources.
    ///
    /// Programs and libraries that do not use these singletons will not incur extra resource usage, these resources are lazily initialized on
    /// first use.
    ///
    /// The loop count of this group is determined by `NIOSingletons/groupLoopCountSuggestion`.
    ///
    /// - Note: Users who do not want any code to spawn global singleton resources may set
    ///         `NIOSingletons/singletonsEnabledSuggestion` to `false` which will lead to a forced crash
    ///         if any code attempts to use the global singletons.
    ///
    public static var singleton: MultiThreadedEventLoopGroup {
        NIOSingletons.posixEventLoopGroup
    }
}

// swift-format-ignore: DontRepeatTypeInStaticProperties
extension EventLoopGroup where Self == MultiThreadedEventLoopGroup {
    /// A globally shared, singleton ``MultiThreadedEventLoopGroup``.
    ///
    /// This provides the same object as ``MultiThreadedEventLoopGroup/singleton``.
    public static var singletonMultiThreadedEventLoopGroup: Self {
        MultiThreadedEventLoopGroup.singleton
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
    /// The thread count of this pool is determined by `NIOSingletons/suggestedBlockingPoolThreadCount`.
    ///
    /// - Note: Users who do not want any code to spawn global singleton resources may set
    ///         `NIOSingletons/singletonsEnabledSuggestion` to `false` which will lead to a forced crash
    ///         if any code attempts to use the global singletons.
    public static var singleton: NIOThreadPool {
        NIOSingletons.posixBlockingThreadPool
    }
}

private let singletonMTELG: MultiThreadedEventLoopGroup = {
    guard NIOSingletons.singletonsEnabledSuggestion else {
        fatalError(
            """
            Cannot create global singleton MultiThreadedEventLoopGroup because the global singletons have been \
            disabled by setting  `NIOSingletons.singletonsEnabledSuggestion = false`
            """
        )
    }
    let threadCount = NIOSingletons.groupLoopCountSuggestion
    let group = MultiThreadedEventLoopGroup._makePerpetualGroup(
        threadNamePrefix: "NIO-SGLTN-",
        numberOfThreads: threadCount
    )
    _ = Unmanaged.passUnretained(group).retain()  // Never gonna give you up,
    return group
}()

private let globalPosixBlockingPool: NIOThreadPool = {
    guard NIOSingletons.singletonsEnabledSuggestion else {
        fatalError(
            """
            Cannot create global singleton NIOThreadPool because the global singletons have been \
            disabled by setting `NIOSingletons.singletonsEnabledSuggestion = false`
            """
        )
    }
    let pool = NIOThreadPool._makePerpetualStartedPool(
        numberOfThreads: NIOSingletons.blockingPoolThreadCountSuggestion,
        threadNamePrefix: "SGLTN-TP-#"
    )
    _ = Unmanaged.passRetained(pool)  // never gonna let you down.
    return pool
}()
