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
    /// Iterative implementation of a recursive parallel removal of objects
    /// found within `path`.
    func removeConcurrently(
        at path: FilePath
    ) async throws -> Int {
        try await self.discoverItemsInTree(at: path)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension FileSystem {
    /// Recursively walk all objects found in `path`. Call ourselves recursively
    /// when a directory is found. Delete anything else immediately.
    private func discoverItemsInTree(
        at path: FilePath
    ) async throws -> Int {
        var directoriesToRecurseInto: [DirectoryEntry] = []
        var itemsToDelete: [DirectoryEntry] = []

        // 1. Discover current directory and find all files/directories. Free up
        // the handle as fast as possible.
        try await self.withDirectoryHandle(atPath: path) { directory in
            for try await batch in directory.listContents().batched() {
                for entry in batch {
                    switch entry.type {
                    case .directory:
                        directoriesToRecurseInto.append(entry)
                    default:
                        itemsToDelete.append(entry)
                    }
                }
            }
        }

        return try await withThrowingTaskGroup(of: Int.self) { group in
            // 2. Delete all files we found in the current directory
            for item in itemsToDelete {
                group.addTask {
                    try await self.removeOneItem(at: item.path)
                }
            }

            // 3. Now that the handle is closed, we can recurse into all newly found subdirectories
            for directory in directoriesToRecurseInto {
                group.addTask {
                    try await self.discoverItemsInTree(at: directory.path)
                }
            }

            // 4. Sum items deleted so far
            var numberOfDeletedItems: Int = 0
            for try await result in group {
                numberOfDeletedItems += result
            }

            // 5. Remove top level directory
            numberOfDeletedItems += try await self.removeOneItem(at: path)

            return numberOfDeletedItems
        }
    }
}
