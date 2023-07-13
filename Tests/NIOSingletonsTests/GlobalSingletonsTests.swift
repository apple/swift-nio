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
import NIOCore
import NIOPosix
import Foundation

final class NIOGlobalSingletonsTests: XCTestCase {
    func testSingletonMultiThreadedEventLoopWorks() async throws {
        let works = try await MultiThreadedEventLoopGroup.globalSingleton.any().submit { "yes" }.get()
        XCTAssertEqual(works, "yes")
    }

    func testSingletonBlockingPoolWorks() async throws {
        let works = try await NIOThreadPool.globalSingleton.runIfActive(
            eventLoop: MultiThreadedEventLoopGroup.globalSingleton.any()
        ) {
            "yes"
        }.get()
        XCTAssertEqual(works, "yes")
    }

    func testCannotShutdownMultiGroup() {
        XCTAssertThrowsError(try MultiThreadedEventLoopGroup.globalSingleton.syncShutdownGracefully()) { error in
            XCTAssertEqual(.unsupportedOperation, error as? EventLoopError)
        }
    }

    func testCannotShutdownBlockingPool() {
        XCTAssertThrowsError(try NIOThreadPool.globalSingleton.syncShutdownGracefully()) { error in
            XCTAssert(error is NIOThreadPoolError.UnsupportedOperation)
        }
    }

    func testMultiGroupThreadPrefix() {
        XCTAssert(MultiThreadedEventLoopGroup.globalSingleton.description.contains("NIO-SGLTN-"),
                  "\(MultiThreadedEventLoopGroup.globalSingleton.description)")

        for _ in 0..<100 {
            let someEL = MultiThreadedEventLoopGroup.globalSingleton.next()
            XCTAssert(someEL.description.contains("NIO-SGLTN-"), "\(someEL.description)")
        }
    }

    func testSingletonsAreEnabledAndCanBeReadMoreThanOnce() {
        XCTAssertTrue(NIOGlobalSingletons.globalSingletonsEnabledSuggestion)
        XCTAssertTrue(NIOGlobalSingletons.globalSingletonsEnabledSuggestion)
        XCTAssertTrue(NIOGlobalSingletons.globalSingletonsEnabledSuggestion)
    }

    func testCanCreateClientBootstrapWithoutSpecifyingTypeName() {
        _ = ClientBootstrap(group: .globalSingletonMultiThreadedEventLoopGroup)
    }
}
