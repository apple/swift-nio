//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore
import XCTest

private struct TestCase {
    var buffers: [[UInt8]]
    var file: StaticString
    var line: UInt
    init(_ buffers: [[UInt8]], file: StaticString = #filePath, line: UInt = #line) {
        self.buffers = buffers
        self.file = file
        self.line = line
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class AsyncSequenceCollectTests: XCTestCase {
    func testAsyncSequenceCollect() async throws {
        let testCases = [
            TestCase([
                []
            ]),
            TestCase([
                [],
                [],
            ]),
            TestCase([
                [0],
                [],
            ]),
            TestCase([
                [],
                [0],
            ]),
            TestCase([
                [0],
                [1],
            ]),
            TestCase([
                [0],
                [1],
            ]),
            TestCase([
                [0],
                [1],
                [2],
            ]),
            TestCase([
                [],
                [0],
                [],
                [1],
                [],
                [2],
                [],
            ]),
            TestCase([
                [0],
                [1],
                [2],
                [],
                [],
            ]),
            TestCase([
                Array(0..<10)
            ]),
            TestCase([
                Array(0..<10),
                Array(10..<20),
            ]),
            TestCase([
                Array(0..<10),
                Array(10..<20),
                Array(20..<30),
            ]),
            TestCase([
                Array(0..<10),
                Array(10..<20),
                Array(20..<30),
                Array(repeating: 99, count: 1000),
            ]),
        ]
        for testCase in testCases {
            let expectedBytes = testCase.buffers.flatMap({ $0 })

            // happy case where maxBytes is exactly the same as number of buffers received

            // test for the generic version
            let accumulatedBytes1 = try await testCase.buffers
                .asAsyncSequence()
                .collect(upTo: expectedBytes.count, using: .init())
            XCTAssertEqual(
                accumulatedBytes1,
                ByteBuffer(bytes: expectedBytes),
                file: testCase.file,
                line: testCase.line
            )

            // test for the `ByteBuffer` optimised version
            let accumulatedBytes2 = try await testCase.buffers
                .map(ByteBuffer.init(bytes:))
                .asAsyncSequence()
                .collect(upTo: expectedBytes.count)
            XCTAssertEqual(
                accumulatedBytes2,
                ByteBuffer(bytes: expectedBytes),
                file: testCase.file,
                line: testCase.line
            )

            // unhappy case where maxBytes is one byte less than actually received
            guard expectedBytes.count >= 1 else {
                continue
            }

            // test for the generic version
            let maxBytes = max(expectedBytes.count - 1, 0)
            await XCTAssertThrowsError(
                try await testCase.buffers
                    .asAsyncSequence()
                    .collect(upTo: maxBytes, using: .init()),
                file: testCase.file,
                line: testCase.line
            ) { error in
                XCTAssertTrue(
                    error is NIOTooManyBytesError,
                    file: testCase.file,
                    line: testCase.line
                )
                guard let tooManyBytesErr = error as? NIOTooManyBytesError else {
                    XCTFail(
                        "Error was not an NIOTooManyBytesError",
                        file: testCase.file,
                        line: testCase.line
                    )
                    return
                }

                XCTAssertEqual(
                    maxBytes,
                    tooManyBytesErr.maxBytes,
                    file: testCase.file,
                    line: testCase.line
                )
            }

            // test for the `ByteBuffer` optimised version
            await XCTAssertThrowsError(
                try await testCase.buffers
                    .map(ByteBuffer.init(bytes:))
                    .asAsyncSequence()
                    .collect(upTo: maxBytes),
                file: testCase.file,
                line: testCase.line
            ) { error in
                XCTAssertTrue(
                    error is NIOTooManyBytesError,
                    file: testCase.file,
                    line: testCase.line
                )
                guard let tooManyBytesErr = error as? NIOTooManyBytesError else {
                    XCTFail(
                        "Error was not an NIOTooManyBytesError",
                        file: testCase.file,
                        line: testCase.line
                    )
                    return
                }

                // Sometimes the max bytes is subtracted from the header size
                XCTAssertTrue(
                    tooManyBytesErr.maxBytes != nil && tooManyBytesErr.maxBytes! <= maxBytes,
                    file: testCase.file,
                    line: testCase.line
                )
            }
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
struct AsyncSequenceFromSyncSequence<Wrapped: Sequence>: AsyncSequence {
    typealias Element = Wrapped.Element
    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate var iterator: Wrapped.Iterator
        mutating func next() async throws -> Wrapped.Element? {
            self.iterator.next()
        }
    }

    fileprivate let wrapped: Wrapped

    func makeAsyncIterator() -> AsyncIterator {
        .init(iterator: self.wrapped.makeIterator())
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Sequence {
    /// Turns `self` into an `AsyncSequence` by wending each element of `self` asynchronously.
    func asAsyncSequence() -> AsyncSequenceFromSyncSequence<Self> {
        .init(wrapped: self)
    }
}
