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

import Atomics
import NIOCore

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FileSystem {
    func removeConcurrently(
        at path: FilePath
    ) async throws -> Int {
        try await withThrowingTaskGroup(of: Void.self) { group in
            let deletedFilesCounter: ManagedAtomic<Int> = .init(0)
            // Start recursion into the directories in this tree.
            group.addTask {
                try await self.walkTreeForRemovalConcurrently(at: path, counter: deletedFilesCounter)
            }

            try await group.next()
            // Remove root directory itself
            let numberOfDeletedFiles = try await self.removeOneItem(at: path)
            deletedFilesCounter.wrappingIncrement(by: numberOfDeletedFiles, ordering: .relaxed)

            return deletedFilesCounter.load(ordering: .relaxed)
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FileSystem {
    func walkTreeForRemovalConcurrently(
        at path: FilePath,
        counter atomicCounter: ManagedAtomic<Int>
    ) async throws {
        try await self.withDirectoryHandle(atPath: path) { directory in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for try await batch in directory.listContents().batched() {
                    for entry in batch {
                        switch entry.type {
                        case .directory:
                            // Recurse into ourself on a separate thread.
                            group.addTask {
                                try await walkTreeForRemovalConcurrently(
                                    at: entry.path,
                                    counter: atomicCounter
                                )

                                // Remove the directory once we have deleted all
                                // dependants.
                                let numberOfDeletedFiles = try await self.removeOneItem(at: entry.path)
                                atomicCounter.wrappingIncrement(by: numberOfDeletedFiles, ordering: .relaxed)
                            }
                        default:
                            // Delete anything that is not a directory.
                            group.addTask {
                                let numberOfDeletedFiles = try await self.removeOneItem(at: entry.path)
                                atomicCounter.wrappingIncrement(by: numberOfDeletedFiles, ordering: .relaxed)
                            }
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
    }
}
