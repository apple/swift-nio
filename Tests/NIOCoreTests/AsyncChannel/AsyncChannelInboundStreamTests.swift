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

import XCTest

@testable import NIOCore

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class AsyncChannelInboundStreamTests: XCTestCase {
    func testTestingStream() async throws {
        let (stream, source) = NIOAsyncChannelInboundStream<Int>.makeTestingStream()

        try await withThrowingTaskGroup(of: [Int].self) { group in
            group.addTask {
                var elements = [Int]()
                for try await element in stream {
                    elements.append(element)
                }
                return elements
            }

            for element in 0...10 {
                source.yield(element)
            }
            source.finish()

            let result = try await group.next()
            XCTAssertEqual(result, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        }
    }

    func testTestingStream_whenThrowing() async throws {
        let (stream, source) = NIOAsyncChannelInboundStream<Int>.makeTestingStream()

        await withThrowingTaskGroup(of: [Int].self) { group in
            group.addTask {
                var elements = [Int]()
                for try await element in stream {
                    elements.append(element)
                }
                return elements
            }
            source.finish(throwing: ChannelError.alreadyClosed)

            do {
                _ = try await group.next()
                XCTFail("Expected an error to be thrown")
            } catch {
                XCTAssertEqual(error as? ChannelError, .alreadyClosed)
            }
        }
    }
}
