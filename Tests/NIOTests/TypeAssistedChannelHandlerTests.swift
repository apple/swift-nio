//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
@testable import NIO

class TypeAssistedChannelHandlerTest: XCTestCase {
    func testOptionalInboundIn() throws {
        class TestClass: ChannelInboundHandler {
            public typealias InboundIn = String
            
            func canUnwrap(_ data: IOData) -> Bool {
                return tryUnwrapInboundIn(data) != nil
            }
        }
        
        let c = TestClass()
        let goodIOData = IOData("Hello, world!")
        let badIOData = IOData(42)
        XCTAssertTrue(c.canUnwrap(goodIOData))
        XCTAssertFalse(c.canUnwrap(badIOData))
    }

    func testCanDefineBothInboundAndOutbound() throws {
        class TestClass: ChannelInboundHandler, ChannelOutboundHandler {
            public typealias OutboundIn = ByteBuffer
            public typealias OutboundOut = ByteBuffer
            public typealias InboundIn = ByteBuffer
            public typealias InboundOut = ByteBuffer
        }
        
        // This test really just confirms that compilation works: no need to run any code.
        XCTAssert(true)
    }
}
