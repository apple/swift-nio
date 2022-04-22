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

import NIOEmbedded
import XCTest

class EventLoopFutureAsyncAwaitSupportTest : XCTestCase {
    func testAsyncGetHappyPath() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let eventLoop = EmbeddedEventLoop()
            let p = eventLoop.makePromise(of: Void.self)

            p.completeWithTask {
                try await Task.sleep(nanoseconds: 1000)
            }

            await XCTAssertNoThrowWithResult(try await p.futureResult.get())
        }
        #endif
    }

    func testAsyncGetCancellation() throws {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let eventLoop = EmbeddedEventLoop()
            let p = eventLoop.makePromise(of: Void.self)

            p.completeWithTask {
                try await Task.sleep(nanoseconds: 1000)
            }

            let task = Task {
                await XCTAssertThrowsError(try await p.futureResult.get()) { error in
                    XCTAssert(error is CancellationError)
                }
            }
            task.cancel()

            await XCTAssertNoThrowWithResult(try await task.value)
        }
        #endif
    }
}
