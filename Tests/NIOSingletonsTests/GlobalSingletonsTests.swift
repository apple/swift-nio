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

import Foundation
import NIOCore
import NIOPosix
import XCTest

final class NIOSingletonsTests: XCTestCase {
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    func testSingletonMultiThreadedEventLoopWorks() async throws {
        let works = try await MultiThreadedEventLoopGroup.singleton.any().submit { "yes" }.get()
        XCTAssertEqual(works, "yes")
    }

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    func testSingletonBlockingPoolWorks() async throws {
        let works = try await NIOThreadPool.singleton.runIfActive(
            eventLoop: MultiThreadedEventLoopGroup.singleton.any()
        ) {
            "yes"
        }.get()
        XCTAssertEqual(works, "yes")
    }

    func testCannotShutdownMultiGroup() {
        XCTAssertThrowsError(try MultiThreadedEventLoopGroup.singleton.syncShutdownGracefully()) { error in
            XCTAssertEqual(.unsupportedOperation, error as? EventLoopError)
        }
    }

    func testCannotShutdownBlockingPool() {
        XCTAssertThrowsError(try NIOThreadPool.singleton.syncShutdownGracefully()) { error in
            XCTAssert(error is NIOThreadPoolError.UnsupportedOperation)
        }
    }

    func testMultiGroupThreadPrefix() {
        XCTAssert(
            MultiThreadedEventLoopGroup.singleton.description.contains("NIO-SGLTN-"),
            "\(MultiThreadedEventLoopGroup.singleton.description)"
        )

        for _ in 0..<100 {
            let someEL = MultiThreadedEventLoopGroup.singleton.next()
            XCTAssert(someEL.description.contains("NIO-SGLTN-"), "\(someEL.description)")
        }
    }

    func testSingletonsAreEnabledAndCanBeReadMoreThanOnce() {
        XCTAssertTrue(NIOSingletons.singletonsEnabledSuggestion)
        XCTAssertTrue(NIOSingletons.singletonsEnabledSuggestion)
        XCTAssertTrue(NIOSingletons.singletonsEnabledSuggestion)
    }

    func testCanCreateClientBootstrapWithoutSpecifyingTypeName() {
        _ = ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
    }
}
