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
import NIOFS
import XCTest

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class FileChunksTests: XCTestCase {
    func testFileChunksWrapsAsyncStream() async throws {
        let stream = AsyncThrowingStream<ByteBuffer, Error> {
            $0.yield(ByteBuffer(bytes: [0, 1, 2]))
            $0.yield(ByteBuffer(bytes: [3, 4, 5]))
            $0.yield(ByteBuffer(bytes: [6, 7, 8]))
            $0.finish()
        }

        let fileChunks = FileChunks(wrapping: stream)
        var iterator = fileChunks.makeAsyncIterator()
        let chunk0 = try await iterator.next()
        XCTAssertEqual(chunk0, ByteBuffer(bytes: [0, 1, 2]))
        let chunk1 = try await iterator.next()
        XCTAssertEqual(chunk1, ByteBuffer(bytes: [3, 4, 5]))
        let chunk2 = try await iterator.next()
        XCTAssertEqual(chunk2, ByteBuffer(bytes: [6, 7, 8]))
        let end = try await iterator.next()
        XCTAssertNil(end)
    }
}
