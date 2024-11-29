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
    enum RemoveItem: Hashable, Sendable {
        // A directory with dependent objects inside of it. We need to delete all of the objects (and
        // their nested objects), before we can tackle deleting the directory itself.
        case directory(entry: DirectoryEntry, numberOfObjects: UInt64)
        // An object that can be removed right away (i.e., symlink, file, empty directory). We need
        // this special case to do the accounting of dependent files for the parent directory.
        case immediatelyRemovableObject(entry: DirectoryEntry)
        // An object that has been identified to be deletable now. This is used as a signal to
        // actually perform the deletion. This case will be sent after all accounting for the parent
        // has been completed.
        case deleteObject(entry: DirectoryEntry)
    }

    fileprivate struct DirectoryReferences {
        var root: FilePath
        var state: [FilePath: Int64] = [:]
        var yield: @Sendable ([RemoveItem]) -> Void

        mutating func act(on item: RemoveItem) {
            switch item {
            case .directory(let directoryEntry, let numberOfObjects):
                // Initialize accounting for directory.
                if !self.state.keys.contains(directoryEntry.path) {
                    self.state[directoryEntry.path] = Int64(numberOfObjects)
                    break
                }

                // Directory was initialized earlier by other objects. Add numbers of dependent
                // files we found for acounting purposes.
                self.state[directoryEntry.path]! += Int64(numberOfObjects)

                // Send directory off for deletion (and accounting) if its empty now.
                if self.state[directoryEntry.path] == 0 {
                    yield([.immediatelyRemovableObject(entry: .init(path: directoryEntry.path, type: .directory)!)])
                }

            case .immediatelyRemovableObject(let directoryEntry):
                // We are actually deleting the root directory, and we're done. No need to look
                // at the parent directory.
                if directoryEntry.path == root {
                    yield([.deleteObject(entry: directoryEntry)])
                    break
                }

                // Need to do accounting for the parent directory, and not the current object we are
                // looking at.
                let parent = directoryEntry.path.removingLastComponent()

                // If we have not started accounting for the parent directory, lets initialize it.
                if !self.state.keys.contains(parent) {
                    self.state[parent] = 0
                }

                // Signal deletion of directory, and account for the parent not having one less
                // dependent.
                yield([.deleteObject(entry: directoryEntry)])
                self.state[parent]! -= 1

                // Accounting. Send parent for deletion if its empty.
                if self.state[parent] == 0 {
                    yield([.immediatelyRemovableObject(entry: .init(path: parent, type: .directory)!)])
                }
            case .deleteObject:
                // This should not happen, because we handle this case outside this function call.
                // Why does the Swift compiler not notice that we handle this case in the only place
                // that this function is called, such that we should not be forced to handle this
                // inside here as well.
                //
                // TODO: something better to do here than break?
                break
            }
        }
    }

    func removeConcurrently(
        at path: FilePath
    ) async throws -> Int {
        let removalQueue = NIOAsyncSequenceProducer.makeSequence(
            elementType: RemoveItem.self,
            backPressureStrategy: NoBackPressureStrategy(),
            finishOnDeinit: false,
            delegate: DirCopyDelegate()
        )

        @Sendable func yield(_ contentsOf: [RemoveItem]) {
            _ = removalQueue.source.yield(contentsOf: contentsOf)
        }

        // Keep track of how many references are found to a directory (files, subdirectories, etc
        // contained within a directory). At the end of processing, all of these should be zero.
        // When any directory arrives at zero, we intend to delete it. This should then allow us to
        // eventually cascade all the way up and delete the root directory.
        var references: DirectoryReferences = .init(root: path, yield: yield)

        var deletedFiles: Int = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Seed discovery of directories. We will recursively call this function from within.
            group.addTask {
                try await self.walkTreeForRemovalConcurrently(at: path, yield: yield)
            }

            // Sequentially process stream of discovered objects. Kicks off more tasks if needed,
            // all producing into this same sequence.
            let iter = removalQueue.sequence.makeAsyncIterator()
            var continueConsuming: Bool = true
            while continueConsuming {
                let item = await iter.next()
                if let item = item {
                    switch item {
                    case .deleteObject(let directoryEntry):
                        deletedFiles += try await self.removeOneItem(at: directoryEntry.path)

                        // We just deleted the root directry. Lets close the queue.
                        if directoryEntry.path == path {
                            removalQueue.source.finish()
                        }

                    default: references.act(on: item)
                    }
                } else {
                    continueConsuming = false
                }
            }

            try await group.waitForAll()
        }

        return deletedFiles
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FileSystem {
    func walkTreeForRemovalConcurrently(
        at path: FilePath,
        yield: @escaping @Sendable ([RemoveItem]) -> Void
    ) async throws {
        try await self.withDirectoryHandle(atPath: path) { directory in
            var numberOfObjectsInDirectory: UInt64 = 0
            try await withThrowingTaskGroup(of: Void.self) { group in
                for try await batch in directory.listContents().batched() {
                    for entry in batch {
                        numberOfObjectsInDirectory += 1
                        switch entry.type {
                        case .directory:
                            // Recurse into ourself to discover the next subdirectory, but do that
                            // on a separate thread.
                            group.addTask {
                                try await walkTreeForRemovalConcurrently(
                                    at: entry.path,
                                    yield: yield
                                )
                            }
                        default:
                            // Fire deletion events for anything that is not a directory with files in it.
                            yield([.immediatelyRemovableObject(entry: entry)])
                        }
                    }
                }
            }

            if numberOfObjectsInDirectory == 0 {
                // Directory is empty, so we can immediately send it off for deletion.
                yield([.immediatelyRemovableObject(entry: .init(path: path, type: .directory)!)])
            } else {
                // Once we have seen the number of objects inside this directory, dispatch an event
                // with that information.
                yield([
                    .directory(entry: .init(path: path, type: .directory)!, numberOfObjects: numberOfObjectsInDirectory)
                ])
            }
        }
    }
}

// TODO: the following two are verbatim copies from ParallelDirCopy.swift.
//
// An 'always ask for more' no  back-pressure strategy for a ``NIOAsyncSequenceProducer``.
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
