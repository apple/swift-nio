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

fileprivate struct TestCase {
    var buffers: [[UInt8]]
    var file: StaticString
    var line: UInt
    init(_ buffers: [[UInt8]], file: StaticString = #filePath, line: UInt = #line) {
        self.buffers = buffers
        self.file = file
        self.line = line
    }
}

final class AsyncSequenceCollectTests: XCTestCase {
    func testAsyncSequenceCollect() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let testCases = [
                TestCase([
                    [],
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
                    Array(0..<10),
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
                await XCTAssertThrowsError(
                    try await testCase.buffers
                        .asAsyncSequence()
                        .collect(upTo: max(expectedBytes.count - 1, 0), using: .init()),
                    file: testCase.file,
                    line: testCase.line
                ) { error in
                    XCTAssertTrue(
                        error is NIOTooManyBytesError,
                        file: testCase.file,
                        line: testCase.line
                    )
                }
                
                // test for the `ByteBuffer` optimised version
                await XCTAssertThrowsError(
                    try await testCase.buffers
                        .map(ByteBuffer.init(bytes:))
                        .asAsyncSequence()
                        .collect(upTo: max(expectedBytes.count - 1, 0)),
                    file: testCase.file,
                    line: testCase.line
                ) { error in
                    XCTAssertTrue(
                        error is NIOTooManyBytesError,
                        file: testCase.file,
                        line: testCase.line
                    )
                }
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
