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

#if os(WASI) || canImport(Testing)

import class Atomics.ManagedAtomic
import protocol NIOCore.EventLoop
import protocol NIOCore.EventLoopGroup
import struct NIOCore.EventLoopIterator
import enum NIOCore.System

#if canImport(Dispatch)
import Dispatch
#endif

/// An `EventLoopGroup` which will create multiple `EventLoop`s, each tied to its own task pool.
///
/// This implementation relies on SwiftConcurrency and does not directly instantiate any actual threads.
/// This reduces risk and fallout if the event loop group is not shutdown gracefully, compared to the NIOPosix
/// `MultiThreadedEventLoopGroup` implementation.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public final class MultiThreadedEventLoopGroup: EventLoopGroup, @unchecked Sendable {
    /// Task‑local key that stores a boolean that helps AsyncEventLoop know
    /// if shutdown calls are being made from this event loop group, or external
    ///
    /// Safety mechanisms prevent calling shutdown direclty on a loop.
    enum _GroupContextKey { @TaskLocal static var isFromMultiThreadedEventLoopGroup: Bool = false }

    private let loops: [AsyncEventLoop]
    private let counter = ManagedAtomic<Int>(0)

    public init(numberOfThreads: Int = System.coreCount) {
        precondition(numberOfThreads > 0, "thread count must be positive")
        self.loops = (0..<numberOfThreads).map { _ in
            AsyncEventLoop()
        }
    }

    // EventLoopGroup --------------------------------------------------------
    public func next() -> EventLoop {
        loops[counter.loadThenWrappingIncrement(ordering: .sequentiallyConsistent) % loops.count]
    }

    public func any() -> EventLoop { loops[0] }

    public func makeIterator() -> NIOCore.EventLoopIterator {
        .init(self.loops.map { $0 as EventLoop })
    }

    #if canImport(Dispatch)
    public func shutdownGracefully(
        queue: DispatchQueue,
        _ onCompletion: @escaping @Sendable (Error?) -> Void
    ) {
        Task {
            do {
                try await shutdownGracefully()
                queue.async {
                    onCompletion(nil)
                }
            } catch {
                queue.async {
                    onCompletion(error)
                }
            }
        }
    }
    #endif  // canImport(Dispatch)

    public func shutdownGracefully() async throws {
        await _GroupContextKey.$isFromMultiThreadedEventLoopGroup.withValue(true) {
            for loop in loops { await loop.closeGracefully() }
        }
    }

    public static let singleton = MultiThreadedEventLoopGroup()

    #if !canImport(Dispatch)
    public func _preconditionSafeToSyncShutdown(file: StaticString, line: UInt) {
        assertionFailure(
            "Synchronous shutdown API's are not currently supported by MultiThreadedEventLoopGroup"
        )
    }
    #endif
}

#endif  // os(WASI) || canImport(Testing)
