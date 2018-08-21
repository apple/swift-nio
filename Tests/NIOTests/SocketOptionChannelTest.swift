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

import NIO
import XCTest

final class SocketOptionChannelTest: XCTestCase {
    var group: MultiThreadedEventLoopGroup!
    var serverChannel: Channel!
    var clientChannel: Channel!

    struct CastError: Error { }

    private func convertedChannel(file: StaticString = #file, line: UInt = #line) throws -> SocketOptionProvider {
        guard let provider = self.clientChannel as? SocketOptionProvider else {
            XCTFail("Unable to cast \(String(describing: self.clientChannel)) to SocketOptionProvider", file: file, line: line)
            throw CastError()
        }
        return provider
    }

    override func setUp() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.serverChannel = try? assertNoThrowWithValue(ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).wait())
        self.clientChannel = try? assertNoThrowWithValue(ClientBootstrap(group: group).connect(to: serverChannel.localAddress!).wait())
    }

    override func tearDown() {
        XCTAssertNoThrow(try clientChannel.close().wait())
        XCTAssertNoThrow(try serverChannel.close().wait())
        XCTAssertNoThrow(try group.syncShutdownGracefully())
    }

    func testSettingAndGettingComplexSocketOption() throws {
        let provider = try assertNoThrowWithValue(self.convertedChannel())

        let newTimeout = timeval(tv_sec: 5, tv_usec: 0)
        let retrievedTimeout = try assertNoThrowWithValue(provider.unsafeSetSocketOption(level: SocketOptionLevel(SOL_SOCKET), name: SO_RCVTIMEO, value: newTimeout).then {
            provider.unsafeGetSocketOption(level: SocketOptionLevel(SOL_SOCKET), name: SO_RCVTIMEO) as EventLoopFuture<timeval>
        }.wait())

        XCTAssertEqual(retrievedTimeout.tv_sec, newTimeout.tv_sec)
        XCTAssertEqual(retrievedTimeout.tv_usec, newTimeout.tv_usec)
    }

    func testObtainingDefaultValueOfComplexSocketOption() throws {
        let provider = try assertNoThrowWithValue(self.convertedChannel())

        let retrievedTimeout: timeval = try assertNoThrowWithValue(provider.unsafeGetSocketOption(level: SocketOptionLevel(SOL_SOCKET), name: SO_RCVTIMEO).wait())
        XCTAssertEqual(retrievedTimeout.tv_sec, 0)
        XCTAssertEqual(retrievedTimeout.tv_usec, 0)
    }

    func testSettingAndGettingSimpleSocketOption() throws {
        let provider = try assertNoThrowWithValue(self.convertedChannel())

        let newReuseAddr = 1 as CInt
        let retrievedReuseAddr = try assertNoThrowWithValue(provider.unsafeSetSocketOption(level: SocketOptionLevel(SOL_SOCKET), name: SO_REUSEADDR, value: newReuseAddr).then {
            provider.unsafeGetSocketOption(level: SocketOptionLevel(SOL_SOCKET), name: SO_REUSEADDR) as EventLoopFuture<CInt>
        }.wait())

        XCTAssertNotEqual(retrievedReuseAddr, 0)
    }

    func testObtainingDefaultValueOfSimpleSocketOption() throws {
        let provider = try assertNoThrowWithValue(self.convertedChannel())

        let reuseAddr: CInt = try assertNoThrowWithValue(provider.unsafeGetSocketOption(level: SocketOptionLevel(SOL_SOCKET), name: SO_REUSEADDR).wait())
        XCTAssertEqual(reuseAddr, 0)
    }

    func testPassingInvalidSizeToSetComplexSocketOptionFails() throws {
        // You'll notice that there are no other size mismatch tests in this file. The reason for that is that
        // setsockopt is pretty dumb, and getsockopt is dumber. Specifically, setsockopt checks only that the length
        // of the option value is *at least as large* as the expected struct (which is why this test will actually
        // work), and getsockopt will happily return without error even in the buffer is too small. Either way,
        // we just abandon the other tests: this is sufficient to prove that the error path works.
        let provider = try assertNoThrowWithValue(self.convertedChannel())

        do {
            try provider.unsafeSetSocketOption(level: SocketOptionLevel(SOL_SOCKET), name: SO_RCVTIMEO, value: CInt(1)).wait()
            XCTFail("Did not throw")
        } catch let err as IOError where err.errnoCode == EINVAL {
            // Acceptable error
        } catch {
            XCTFail("Invalid error: \(error)")
        }
    }


    // MARK: Tests for the safe helper functions.
    func testLinger() throws {
        let newLingerValue = linger(l_onoff: 1, l_linger: 64)

        let provider = try self.convertedChannel()
        XCTAssertNoThrow(try provider.setSoLinger(newLingerValue).then {
            provider.getSoLinger()
        }.map {
            XCTAssertEqual($0.l_linger, newLingerValue.l_linger)
            XCTAssertEqual($0.l_onoff, newLingerValue.l_onoff)
        }.wait())
    }
}
