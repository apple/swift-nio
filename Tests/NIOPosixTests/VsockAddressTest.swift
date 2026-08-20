//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
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
@testable import NIOPosix

class VsockAddressTest: XCTestCase {

    func testDescriptionWorks() throws {
        XCTAssertEqual(VsockAddress(cid: .host, port: 12345).description, "[VSOCK]2:12345")
        XCTAssertEqual(VsockAddress(cid: .any, port: 12345).description, "[VSOCK]-1:12345")
        XCTAssertEqual(VsockAddress(cid: .host, port: .any).description, "[VSOCK]2:-1")
        XCTAssertEqual(VsockAddress(cid: .any, port: .any).description, "[VSOCK]-1:-1")
    }

    func testInitializeFromIntegerLiteral() throws {
        XCTAssertEqual(VsockAddress.ContextID(integerLiteral: 0), 0)
        XCTAssertEqual(VsockAddress.Port(integerLiteral: 0), 0)
        XCTAssertEqual(VsockAddress.ContextID(integerLiteral: 4_294_967_295), 4_294_967_295)
        XCTAssertEqual(VsockAddress.Port(integerLiteral: 4_294_967_295), 4_294_967_295)
    }

    func testInitializeFromInt() throws {
        XCTAssertEqual(VsockAddress.ContextID(0), 0)
        XCTAssertEqual(VsockAddress.ContextID(4_294_967_295), 4_294_967_295)
        XCTAssertEqual(VsockAddress.Port(0), 0)
        XCTAssertEqual(VsockAddress.Port(4_294_967_295), 4_294_967_295)
    }

    func testSocketAddressEqualitySpecialValues() throws {
        XCTAssertEqual(
            VsockAddress(cid: .any, port: 12345),
            .init(cid: .init(rawValue: UInt32(bitPattern: -1)), port: 12345)
        )
        XCTAssertEqual(VsockAddress(cid: .hypervisor, port: 12345), .init(cid: 0, port: 12345))
        XCTAssertEqual(VsockAddress(cid: .host, port: 12345), .init(cid: 2, port: 12345))
    }

    func testSocketAddressEquality() throws {
        XCTAssertEqual(VsockAddress(cid: 0, port: 0), .init(cid: 0, port: 0))
        XCTAssertEqual(VsockAddress(cid: 1, port: 0), .init(cid: 1, port: 0))
        XCTAssertEqual(VsockAddress(cid: 0, port: 1), .init(cid: 0, port: 1))

        XCTAssertNotEqual(VsockAddress(cid: 0, port: 0), .init(cid: 1, port: 0))
        XCTAssertNotEqual(VsockAddress(cid: 0, port: 0), .init(cid: 0, port: 1))
    }

    // Getting the local vsock context ID is not available on Windows.
    #if !os(Windows)
    func testGetLocalCID() throws {
        try XCTSkipUnless(System.supportsVsockLoopback, "No vsock loopback transport available")

        let socket = try ServerSocket(protocolFamily: .vsock, setNonBlocking: true)
        defer { try? socket.close() }

        // Check we can get the local CID using the static property on ContextID.
        let localCID = try socket.withUnsafeHandle(VsockAddress.ContextID.getLocalContextID)

        // Check the local CID from the socket matches.
        XCTAssertEqual(try socket.getLocalVsockContextID(), localCID)

        // Check the local CID from the channel option matches.
        let singleThreadedELG = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try singleThreadedELG.syncShutdownGracefully()) }
        let eventLoop = singleThreadedELG.next()
        let channel = try ServerSocketChannel(
            serverSocket: socket,
            eventLoop: eventLoop as! SelectableEventLoop,
            group: singleThreadedELG
        )
        XCTAssertEqual(try channel.getOption(.localVsockContextID).wait(), localCID)
    }
    #endif

    // Getting the local vsock address is not available on Windows.
    #if !os(Windows)
    /// A listener bound to `Port/any` reports the port the kernel actually chose.
    ///
    /// This is what ``ChannelOptions/Types/LocalVsockContextID`` can't do: it reports the context ID
    /// only, so a caller which binds `.any` has no way to learn where to connect.
    func testGetLocalVsockAddressReportsBoundPort() throws {
        try XCTSkipUnless(System.supportsVsockLoopback, "No vsock loopback transport available")

        let socket = try ServerSocket(protocolFamily: .vsock, setNonBlocking: true)
        defer { try? socket.close() }
        try socket.bind(to: VsockAddress(cid: .any, port: .any))

        let address = try socket.getLocalVsockAddress()
        XCTAssertNotEqual(address.port, .any, "The kernel should have assigned a concrete port")
        XCTAssertEqual(address.cid, try socket.getLocalVsockContextID())
        XCTAssertEqual(address.cid, .any)

        // Check the address from the channel option matches.
        let singleThreadedELG = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try singleThreadedELG.syncShutdownGracefully()) }
        let eventLoop = singleThreadedELG.next()
        let channel = try ServerSocketChannel(
            serverSocket: socket,
            eventLoop: eventLoop as! SelectableEventLoop,
            group: singleThreadedELG
        )
        XCTAssertEqual(try channel.getOption(.localVsockAddress).wait(), address)
    }

    /// A non-vsock socket must not report a vsock local address, for the same reason
    /// ``testGetRemoteVsockAddressRejectsNonVsockSocket()`` covers on the peer side.
    func testGetLocalVsockAddressRejectsNonVsockSocket() throws {
        let socket = try ServerSocket(protocolFamily: .unix, setNonBlocking: false)
        defer { try? socket.close() }

        XCTAssertThrowsError(try socket.getLocalVsockAddress()) { error in
            XCTAssertEqual(error as? SocketAddressError, .unsupported)
        }
    }
    #endif

    // Getting the remote vsock address is not available on Windows.
    #if !os(Windows)
    /// A non-vsock socket must not report a vsock peer address.
    ///
    /// `getpeername` on a UDS socket fills a `sockaddr_un`; if those bytes were reinterpreted as a
    /// `sockaddr_vm` the option would return a context ID derived from unrelated memory. Callers use
    /// the CID to make trust decisions, so this must fail instead.
    func testGetRemoteVsockAddressRejectsNonVsockSocket() throws {
        // A socketpair gives us an already-connected non-vsock socket without binding anything.
        var fds: [CInt] = [-1, -1]
        try fds.withUnsafeMutableBufferPointer { ptr in
            try Posix.socketpair(
                domain: .unix,
                type: .stream,
                protocolSubtype: .default,
                socketVector: ptr.baseAddress
            )
        }
        let peer = try Socket(socket: fds[1], setNonBlocking: false)
        defer { try? peer.close() }

        let socket = try Socket(socket: fds[0], setNonBlocking: false)
        defer { try? socket.close() }

        XCTAssertThrowsError(try socket.getRemoteVsockAddress()) { error in
            XCTAssertEqual(error as? SocketAddressError, .unsupported)
        }
    }

    /// Both ends of a real vsock connection report the peer's address.
    ///
    /// This is the path the option exists for, so it needs a live connection: it exercises
    /// `getpeername` on an `AF_VSOCK` socket and the reinterpretation of the resulting
    /// `sockaddr_vm`.
    func testGetRemoteVsockAddressOverLoopback() throws {
        try XCTSkipUnless(System.supportsVsockLoopback, "No vsock loopback transport available")

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let port = VsockAddress.Port(5678)

        // Read the peer address on the accepted channel. Sending the address rather than the
        // channel through the promise keeps this Sendable-clean.
        let acceptedPeer = group.next().makePromise(of: VsockAddress.self)

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    acceptedPeer.completeWith(channel.getOption(.remoteVsockAddress))
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                .bind(to: VsockAddress(cid: .any, port: port))
                .wait()
        )
        defer { XCTAssertNoThrow(try serverChannel.close().wait()) }

        #if canImport(Darwin)
        let connectAddress = VsockAddress(cid: .any, port: port)
        #elseif os(Linux) || os(Android)
        let connectAddress = VsockAddress(cid: .local, port: port)
        #endif

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group).connect(to: connectAddress).wait()
        )
        defer { XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed()) }

        // Client side: the peer is the listener, so the port must be the one we bound. This is the
        // assertion that catches a misread `sockaddr_vm` -- wrong field offsets could not happen to
        // produce the port we chose.
        let clientPeer = try assertNoThrowWithValue(
            clientChannel.getOption(.remoteVsockAddress).wait()
        )
        XCTAssertEqual(clientPeer.port, port)

        // Server side: reading the accepted channel's peer must succeed, and because both ends of a
        // loopback connection live in the same context it reports the same CID the client saw.
        let serverPeer = try assertNoThrowWithValue(acceptedPeer.futureResult.wait())
        XCTAssertEqual(serverPeer.cid, clientPeer.cid)
    }
    #endif
}
