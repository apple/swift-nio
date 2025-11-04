//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FileSystem {
    /// Iterative implementation of a recursive parallel copy of the directory from `sourcePath` to
    /// `destinationPath`.
    ///
    /// The parallelism is solely at the level of individual items (files, symbolic links and
    /// directories). A larger file is not 'split' into concurrent reads or writes.
    ///
    /// If a symbolic link is encountered, then only the link is copied. If supported by the file
    /// system, the copied items will preserve permissions and any extended attributes.
    ///
    /// Note: `maxConcurrentOperations` is used as a hard (conservative) limit on the number of open
    /// file descriptors at any point. Operations are assumed to consume 2 descriptors, so the
    /// maximum open descriptors are `maxConcurrentOperations * 2`
    @usableFromInline
    func copyDirectoryParallel(
        from sourcePath: FilePath,
        to destinationPath: FilePath,
        maxConcurrentOperations: Int,
        shouldProceedAfterError:
            @escaping @Sendable (
                _ entry: DirectoryEntry,
                _ error: Error
            ) async throws -> Void,
        shouldCopyItem:
            @escaping @Sendable (
                _ source: DirectoryEntry,
                _ destination: FilePath
            ) async -> Bool
    ) async throws {
        // Implemented with NIOAsyncSequenceProducer rather than AsyncStream. It is approximately
        // the same speed in the best case, but has significantly less variance.
        // NIOAsyncSequenceProducer also enforces a multi-producer, single-consumer access pattern.
        let copyRequiredQueue = NIOAsyncSequenceProducer.makeSequence(
            elementType: DirCopyItem.self,
            backPressureStrategy: NoBackPressureStrategy(),
            finishOnDeinit: false,
            delegate: DirCopyDelegate()
        )

        // We ignore the result of yield in all cases, because we are not implementing back
        // pressure, and cancellation is dealt with separately.
        @Sendable func yield(_ contentsOf: [DirCopyItem]) {
            _ = copyRequiredQueue.source.yield(contentsOf: contentsOf)
        }

        // Kick-start the procees by enqueuing the root entry. The calling function already
        // validated the root needed copying, so it is safe to force unwrap the value.
        _ = copyRequiredQueue.source.yield(
            .toCopy(from: .init(path: NIOFilePath(sourcePath), type: .directory)!, to: destinationPath)
        )

        // The processing of the very first item (the root) will increment this counter. Processing
        // will finish when the counter hits zero again.
        //
        // This does not need to be a ManagedAtomic or similar because:
        // - All state maintenance is done within the withThrowingTaskGroup closure
        // - All actual file system work is done by tasks created on the `taskGroup`
        var activeDirCount = 0

        // Despite there being no 'result' for each operation, we cannot use a discarding task group,
        // because we use the 'drain results' queue as a concurrency limiting side effect.
        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            // Process each item in the current task.
            //
            // Side Effects:
            // - Updates activeDirCount and finishes the stream if required.
            // - Might add a task to `taskGroup`.
            //
            // Returns true if it added a task, false otherwise.
            func onNextItem(_ item: DirCopyItem) -> Bool {
                switch item {
                case .endOfDir:
                    activeDirCount -= 1
                    if activeDirCount == 0 {
                        copyRequiredQueue.source.finish()
                    }
                    return false
                case let .toCopy(from: from, to: to):
                    if from.type == .directory {
                        activeDirCount += 1
                    }
                    taskGroup.addTask {
                        try await copySelfAndEnqueueChildren(
                            from: from,
                            to: to,
                            yield: yield,
                            shouldProceedAfterError: shouldProceedAfterError,
                            shouldCopyItem: shouldCopyItem
                        )
                    }
                    return true
                }
            }

            let iter = copyRequiredQueue.sequence.makeAsyncIterator()

            // inProgress counts the number of tasks we have added to the task group.
            // Get up to the maximum concurrency first.
            // We haven't started monitoring for task completion, so inProgress is 'worst case'.
            var inProgress = 0
            while inProgress <= maxConcurrentOperations {
                let item = await iter.next()
                if let item = item {
                    if onNextItem(item) {
                        inProgress += 1
                    }
                } else {
                    // Either we completed things before we hit the limit or we were cancelled. In
                    // the latter case we choose to propagate the cancellation clearly. This makes
                    // testing for it more reliable.
                    try Task.checkCancellation()

                    // If any child tasks failed throw up an error.
                    try await taskGroup.waitForAll()

                    return
                }
            }

            // One in (finish) -> one out (start another), but only for items that trigger a task.
            while let _ = try await taskGroup.next() {
                var keepConsuming = true
                while keepConsuming {
                    let item = await iter.next()
                    if let item = item {
                        keepConsuming = !onNextItem(item)
                    } else {
                        // We must check here, to accurately propagate the cancellation.
                        try Task.checkCancellation()
                        keepConsuming = false
                    }
                }
            }
        }
    }
}

/// An 'always ask for more' no back-pressure strategy for a ``NIOAsyncSequenceProducer``.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
private struct NoBackPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategy {
    mutating func didYield(bufferDepth: Int) -> Bool { true }

    mutating func didConsume(bufferDepth: Int) -> Bool { true }
}

/// We ignore back pressure, the inherent handle limiting in copyDirectoryParallel means it is unnecessary.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
private struct DirCopyDelegate: NIOAsyncSequenceProducerDelegate, Sendable {
    @inlinable
    func produceMore() {}

    @inlinable
    func didTerminate() {}
}
