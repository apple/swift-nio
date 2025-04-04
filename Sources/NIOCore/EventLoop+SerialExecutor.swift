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

/// A helper protocol that can be mixed in to a NIO ``EventLoop`` to provide an
/// automatic conformance to `SerialExecutor`.
///
/// Implementers of `EventLoop` should consider conforming to this protocol as
/// well on Swift 5.9 and later.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
public protocol NIOSerialEventLoopExecutor: EventLoop, SerialExecutor {}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension NIOSerialEventLoopExecutor {
    @inlinable
    public func enqueue(_ job: consuming ExecutorJob) {
        // By default we are just going to use execute to run the job
        // this is quite heavy since it allocates the closure for
        // every single job.
        let unownedJob = UnownedJob(job)
        self.execute {
            unownedJob.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    @inlinable
    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(complexEquality: self)
    }

    @inlinable
    public var executor: any SerialExecutor {
        self
    }

    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @inlinable
    public func isSameExclusiveExecutionContext(other: Self) -> Bool {
        other === self
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, *)
    @inlinable
    public func checkIsolated() {
        self.preconditionInEventLoop()
    }
}

/// A type that wraps a NIO ``EventLoop`` into a `SerialExecutor`
/// for use with Swift concurrency.
///
/// This type is not recommended for use because it risks problems with unowned
/// executors. Adopters are recommended to conform their own event loop
/// types to `SerialExecutor`.
package final class NIODefaultEventLoopExecutor {
    @usableFromInline
    let loop: EventLoop

    @inlinable
    package init(_ loop: EventLoop) {
        self.loop = loop
    }
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension NIODefaultEventLoopExecutor: SerialExecutor {
    @inlinable
    package func enqueue(_ job: consuming ExecutorJob) {
        self.loop.enqueue(job)
    }

    @inlinable
    package func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(complexEquality: self)
    }

    @inlinable
    package func isSameExclusiveExecutionContext(other: NIODefaultEventLoopExecutor) -> Bool {
        self.loop === other.loop
    }
}

#if compiler(>=6.0)
/// A helper protocol that can be mixed in to a NIO ``EventLoop`` to provide an
/// automatic conformance to `TaskExecutor`.
///
/// Implementers of `EventLoop` should consider conforming to this protocol as
/// well on Swift 6.0 and later.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public protocol NIOTaskEventLoopExecutor: NIOSerialEventLoopExecutor & TaskExecutor {}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension NIOTaskEventLoopExecutor {
    @inlinable
    func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }

    @inlinable
    public var taskExecutor: any TaskExecutor {
        self
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension NIODefaultEventLoopExecutor: TaskExecutor {
    @inlinable
    public func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}
#endif
