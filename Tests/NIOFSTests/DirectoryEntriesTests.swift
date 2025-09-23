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

import NIOFS
import XCTest

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class DirectoryEntriesTests: XCTestCase {
    func testDirectoryEntriesWrapsAsyncStream() async throws {
        let stream = AsyncThrowingStream<[DirectoryEntry], Error> {
            $0.yield([DirectoryEntry(path: "foo", type: .regular)!])
            $0.yield(
                [
                    DirectoryEntry(path: "bar", type: .block)!,
                    DirectoryEntry(path: "baz", type: .character)!,
                ]
            )
            $0.finish()
        }

        let directoryEntries = DirectoryEntries(wrapping: stream)
        var iterator = directoryEntries.makeAsyncIterator()
        let entry0 = try await iterator.next()
        XCTAssertEqual(entry0, DirectoryEntry(path: "foo", type: .regular))
        let entry1 = try await iterator.next()
        XCTAssertEqual(entry1, DirectoryEntry(path: "bar", type: .block))
        let entry2 = try await iterator.next()
        XCTAssertEqual(entry2, DirectoryEntry(path: "baz", type: .character))
        let end = try await iterator.next()
        XCTAssertNil(end)
    }

    func testDirectoryEntriesBatchesWrapsAsyncStream() async throws {
        let stream = AsyncThrowingStream<[DirectoryEntry], Error> {
            $0.yield([DirectoryEntry(path: "foo", type: .regular)!])
            $0.yield(
                [
                    DirectoryEntry(path: "bar", type: .block)!,
                    DirectoryEntry(path: "baz", type: .character)!,
                ]
            )
            $0.finish()
        }

        let directoryEntries = DirectoryEntries(wrapping: stream)
        var iterator = directoryEntries.batched().makeAsyncIterator()
        let entry0 = try await iterator.next()
        XCTAssertEqual(entry0, [DirectoryEntry(path: "foo", type: .regular)!])

        let entry1 = try await iterator.next()
        XCTAssertEqual(
            entry1,
            [
                DirectoryEntry(path: "bar", type: .block)!,
                DirectoryEntry(path: "baz", type: .character)!,
            ]
        )
        let end = try await iterator.next()
        XCTAssertNil(end)
    }
}
