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
import NIOPosix  // NOTE: Not @testable import here -- testing public API surface.
import Testing

@Suite struct NIOTransportAccessibleChannelTests {
    @Test func testUnderlyingSocketAccessForSocketBasedChannel() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { #expect(throws: Never.self) { try group.syncShutdownGracefully() } }
        let channel = try DatagramBootstrap(group: group).bind(host: "127.0.0.1", port: 0).wait()
        defer { #expect(throws: Never.self) { try channel.close().wait() } }

        // Cast to protocol with unknown associated type.
        try #require(channel as? any NIOTransportAccessibleChannel).withUnsafeTransport { transport in
            #expect(type(of: transport) == NIOBSDSocket.Handle.self)
        }

        // Cast to protocol with known associated type.
        try #require(channel as? any NIOTransportAccessibleChannel<NIOBSDSocket.Handle>).withUnsafeTransport { fd in
            #if os(Windows)
            #expect(fd != INVALID_SOCKET)
            #else
            #expect(fd != -1)
            #endif
        }

        // Use bound socket from the bootstrap with the prebound-socket bootstrap to test the actual FD is returned.
        try #require(channel as? any NIOTransportAccessibleChannel<NIOBSDSocket.Handle>).withUnsafeTransport { fd in
            let fd_ = dup(fd)
            let channel_ = try DatagramBootstrap(group: group).withBoundSocket(fd_).wait()
            try #require(channel_ as? any NIOTransportAccessibleChannel<NIOBSDSocket.Handle>).withUnsafeTransport {
                fd__ in
                #expect(fd__ == fd_)
            }
        }

        // But this is how we want people to use the API -- via sync operations.
        try channel.eventLoop.submit {
            try channel.pipeline.syncOperations.withUnsafeTransportIfAvailable(of: NIOBSDSocket.Handle.self) { transport in
                #expect(type(of: transport) == NIOBSDSocket.Handle.self)
            }
        }.wait()
    }
}
