//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore  // NOTE: Not @testable import here -- testing public API surface.
import NIOEmbedded
import NIOPosix  // NOTE: Not @testable import here -- testing public API surface.
import Testing

@Suite struct NIOTransportAccessibleChannelCoreTests {
    @Test func testUnderlyingSocketAccessForSocketBasedChannel() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { #expect(throws: Never.self) { try group.syncShutdownGracefully() } }
        let channel = try DatagramBootstrap(group: group).bind(host: "127.0.0.1", port: 0).wait()
        defer { #expect(throws: Never.self) { try channel.close().wait() } }

        // We don't expect users to do this runtime check, but test the channel we got back from bootstrap conforms.
        #expect(channel is any NIOTransportAccessibleChannelCore)
        #expect(channel is any NIOTransportAccessibleChannelCore<NIOBSDSocket.Handle>)
        #expect(channel is any NIOTransportAccessibleChannelCore<Any> == false)

        // Here we try the public API use, in various flavours.
        try channel.eventLoop.submit {
            let syncOps = channel.pipeline.syncOperations

            // Calling without explicit transport type runs closure if body inefers correct transport type.
            try #expect(syncOps.withUnsafeTransportIfAvailable { fd in fd != NIOBSDSocket.invalidHandle } == true)
            try #expect(syncOps.withUnsafeTransportIfAvailable { $0 != NIOBSDSocket.invalidHandle } == true)

            // Calling with explicit correct transport type runs closure.
            try #expect(syncOps.withUnsafeTransportIfAvailable(of: NIOBSDSocket.Handle.self) { _ in 42 } == 42)
            try #expect(syncOps.withUnsafeTransportIfAvailable { (_: NIOBSDSocket.Handle) in 42 } == 42)

            // Calling with explicit incorrect transport type does not run closure.
            try #expect(syncOps.withUnsafeTransportIfAvailable(of: String.self) { _ in 42 } == nil)
            try #expect(syncOps.withUnsafeTransportIfAvailable { (_: String) in 42 } == nil)

            // Calling with explicit Any transport type does not run closure.
            try #expect(syncOps.withUnsafeTransportIfAvailable(of: Any.self) { _ in 42 } == nil)
            try #expect(syncOps.withUnsafeTransportIfAvailable { (_: Any) in 42 } == nil)

            // Calling without explicit transport type does not run closure, even if body doesn't use transport.
            try #expect(syncOps.withUnsafeTransportIfAvailable { 42 } == nil)

            // Fun aside: What is the resolved type of the above function and why does it allow ignoring closure param?
            try #expect(syncOps.withUnsafeTransportIfAvailable { $0.self } == nil)
            // Answer: `$0: any (~Copyable & ~Escapable).Type`

            // Calling without explicit transport type does not run closure, even if body uses compatible literal value.
            try #expect(syncOps.withUnsafeTransportIfAvailable { transport in transport != -1 } == nil)
        }.wait()
    }

    @Test func testUnderlyingTransportForUnsupportedChannels() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { #expect(throws: Never.self) { try group.syncShutdownGracefully() } }
        let channel = EmbeddedChannel()
        defer { #expect(throws: Never.self) { try channel.close().wait() } }

        #expect(channel is any NIOTransportAccessibleChannelCore == false)

        // Calling the public API will never run the closure -- we cannot specify a type to pass the runtime check.
        let syncOps = channel.pipeline.syncOperations
        try #expect(syncOps.withUnsafeTransportIfAvailable { 42 } == nil)
        try #expect(syncOps.withUnsafeTransportIfAvailable(of: Any.self) { _ in 42 } == nil)
        try #expect(syncOps.withUnsafeTransportIfAvailable(of: CInt.self) { _ in 42 } == nil)
        try #expect(syncOps.withUnsafeTransportIfAvailable(of: type(of: STDOUT_FILENO).self) { _ in 42 } == nil)
    }

    @Test func testUnderlyingTransportConformanceForExpectedChannels() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { #expect(throws: Never.self) { try group.syncShutdownGracefully() } }

        // SeverSocketChannel -- yep.
        let serverChannel = try ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).wait()
        defer { #expect(throws: Never.self) { try serverChannel.close().wait() } }
        #expect(serverChannel is any NIOTransportAccessibleChannelCore)
        #expect(serverChannel is any NIOTransportAccessibleChannelCore<NIOBSDSocket.Handle>)

        // SocketChannel -- yep.
        let clientChannel = try ClientBootstrap(group: group).connect(to: serverChannel.localAddress!).wait()
        defer { #expect(throws: Never.self) { try clientChannel.close().wait() } }
        #expect(clientChannel is any NIOTransportAccessibleChannelCore)
        #expect(clientChannel is any NIOTransportAccessibleChannelCore<NIOBSDSocket.Handle>)

        // DatagramChannel -- yep.
        let datagramChannel = try DatagramBootstrap(group: group).bind(host: "127.0.0.1", port: 0).wait()
        defer { #expect(throws: Never.self) { try datagramChannel.close().wait() } }
        #expect(datagramChannel is any NIOTransportAccessibleChannelCore)
        #expect(datagramChannel is any NIOTransportAccessibleChannelCore<NIOBSDSocket.Handle>)

        // PipeChannel -- yep.
        let pipeChannel = try NIOPipeBootstrap(group: group).takingOwnershipOfDescriptor(output: STDOUT_FILENO).wait()
        defer { #expect(throws: Never.self) { try pipeChannel.close().wait() } }
        #expect(pipeChannel is any NIOTransportAccessibleChannelCore)
        #expect(pipeChannel is any NIOTransportAccessibleChannelCore<NIOBSDSocket.PipeHandle>)

        // EmbeddedChannel -- nope.
        let embeddedChannel = EmbeddedChannel()
        defer { #expect(throws: Never.self) { try embeddedChannel.close().wait() } }
        #expect(embeddedChannel is any NIOTransportAccessibleChannelCore == false)
    }
}
