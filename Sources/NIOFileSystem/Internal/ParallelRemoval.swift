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
        at path: FilePath,
        _ maxDescriptors: Int
    ) async throws -> Int {
        let bucket: TokenBucket = .init(tokens: maxDescriptors)
        return try await self.discoverItemsInTree(at: path, bucket)
    }

    /// Recursively walk all objects found in `path`. Call ourselves recursively
    /// on each directory that we find, as soon as the file descriptor for
    /// `path` has been closed; also delete all files that we come across.
    private func discoverItemsInTree(
        at path: FilePath,
        _ bucket: TokenBucket
    ) async throws -> Int {
        // Discover current directory and find all files/directories. Free up
        // the handle as fast as possible.
        let (directoriesToRecurseInto, itemsToDelete) = try await bucket.withToken {
            try await self.withDirectoryHandle(atPath: path) { directory in
                var subdirectories: [DirectoryEntry] = []
                var itemsInDirectory: [DirectoryEntry] = []

                for try await batch in directory.listContents().batched() {
                    for entry in batch {
                        switch entry.type {
                        case .directory:
                            subdirectories.append(entry)
                        default:
                            itemsInDirectory.append(entry)
                        }
                    }
                }

                return (subdirectories, itemsInDirectory)
            }
        }

        return try await withThrowingTaskGroup(of: Int.self) { group in
            // Delete all items we found in the current directory.
            for item in itemsToDelete {
                group.addTask {
                    try await self.removeOneItem(at: item.path)
                }
            }

            // Recurse into all newly found subdirectories.
            for directory in directoriesToRecurseInto {
                group.addTask {
                    try await self.discoverItemsInTree(at: directory.path, bucket)
                }
            }

            // Await task groups to finish and sum all items deleted so far.
            var numberOfDeletedItems: Int = 0
            for try await result in group {
                numberOfDeletedItems += result
            }

            // Remove top level directory.
            numberOfDeletedItems += try await self.removeOneItem(at: path)

            return numberOfDeletedItems
        }
    }
}
