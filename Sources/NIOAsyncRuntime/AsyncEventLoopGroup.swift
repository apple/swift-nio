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

import struct Synchronization.Atomic
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
///
/// - note: AsyncEventLoopGroup and similar classes in NIOAsyncRuntime are not intended
///         to be used for I/O use cases. They are meant solely to provide an off-ramp
///         for code currently using only NIOPosix.MTELG to transition away from NIOPosix
///         and use Swift Concurrency instead.
/// - note: If downstream packages are able to use the dependencies in NIOAsyncRuntime
///         without using NIOPosix, they have definitive proof that their package can transition
///         to Swift Concurrency and eliminate the swift-nio dependency altogether. NIOAsyncRuntime
///         provides a convenient stepping stone to that end.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
public final class AsyncEventLoopGroup: EventLoopGroup, Sendable {
    /// Task‑local key that stores a boolean that helps AsyncEventLoop know
    /// if shutdown calls are being made from this event loop group, or external
    ///
    /// Safety mechanisms prevent calling shutdown direclty on a loop.
    enum _GroupContextKey { @TaskLocal static var isFromAsyncEventLoopGroup: Bool = false }

    private let loops: [AsyncEventLoop]
    private let counter = Atomic<Int>(0)

    public init(numberOfThreads: Int = System.coreCount) {
        precondition(numberOfThreads > 0, "thread count must be positive")
        self.loops = (0..<numberOfThreads).map { _ in
            AsyncEventLoop()
        }
    }

    // EventLoopGroup --------------------------------------------------------
    public func next() -> EventLoop {
        loops[counter.wrappingAdd(1, ordering: .sequentiallyConsistent).oldValue % loops.count]
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
        await _GroupContextKey.$isFromAsyncEventLoopGroup.withValue(true) {
            for loop in loops { await loop.closeGracefully() }
        }
    }

    public static let singleton = AsyncEventLoopGroup()

    #if !canImport(Dispatch)
    public func _preconditionSafeToSyncShutdown(file: StaticString, line: UInt) {
        assertionFailure(
            "Synchronous shutdown API's are not currently supported by AsyncEventLoopGroup"
        )
    }
    #endif
}

#endif  // os(WASI) || canImport(Testing)
