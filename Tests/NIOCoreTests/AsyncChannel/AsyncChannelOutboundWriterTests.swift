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

@_spi(AsyncChannel) @testable import NIOCore
import XCTest

final class AsyncChannelOutboundWriterTests: XCTestCase {
    func testTestingWriter() async throws {
        let (writer, sink) = NIOAsyncChannelOutboundWriter<Int>.makeTestingWriter()

        try await withThrowingTaskGroup(of: [Int].self) { group in
            group.addTask {
                var elements = [Int]()
                for try await element in sink {
                    elements.append(element)
                }
                return elements
            }

            for element in 0...10 {
                try await writer.write(element)
            }
            writer.finish()

            let result = try await group.next()
            XCTAssertEqual(result, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        }
    }
}
