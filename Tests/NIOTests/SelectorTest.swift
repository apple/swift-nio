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

@testable import NIO
import XCTest

class SelectorTest: XCTestCase {

    func testDeregisterWhileProcessingEvents() throws {
        struct TestRegistration: Registration {
            var interested: IOEvent
            let socket: Socket
        }

        let selector = try NIO.Selector<TestRegistration>()
        defer {
            XCTAssertNoThrow(try selector.close())
        }

        let socket1 = try Socket(protocolFamily: PF_INET, type: Posix.SOCK_STREAM)
        defer {
            XCTAssertNoThrow(try socket1.close())
        }
        try socket1.setNonBlocking()

        let socket2 = try Socket(protocolFamily: PF_INET, type: Posix.SOCK_STREAM)
        defer {
            XCTAssertNoThrow(try socket2.close())
        }
        try socket2.setNonBlocking()

        let serverSocket = try ServerSocket.bootstrap(protocolFamily: PF_INET, host: "127.0.0.1", port: 0)
        defer {
            XCTAssertNoThrow(try serverSocket.close())
        }
        _ = try socket1.connect(to: serverSocket.localAddress())
        _ = try socket2.connect(to: serverSocket.localAddress())

        let accepted1 = try serverSocket.accept()!
        defer {
            XCTAssertNoThrow(try accepted1.close())
        }
        let accepted2 = try serverSocket.accept()!
        defer {
            XCTAssertNoThrow(try accepted2.close())
        }

        // Register both sockets with .write. This will ensure both are ready when calling selector.whenReady.
        try selector.register(selectable: socket1 , interested: .write, makeRegistration: { ev in
            TestRegistration(interested: ev, socket: socket1)
        })

        try selector.register(selectable: socket2 , interested: .write, makeRegistration: { ev in
            TestRegistration(interested: ev, socket: socket2)
        })

        var readyCount = 0
        try selector.whenReady(strategy: .block) { ev in
            readyCount += 1
            if socket1 === ev.registration.socket {
                try selector.deregister(selectable: socket2)
            } else if socket2 === ev.registration.socket {
                try selector.deregister(selectable: socket1)
            } else {
                XCTFail("ev.registration.socket was neither \(socket1) or \(socket2) but \(ev.registration.socket)")
            }
        }
        XCTAssertEqual(1, readyCount)
    }
}

