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
#if swift(>=5.9)
@_spi(AsyncChannel) import NIOCore
@_spi(AsyncChannel) import NIOPosix

@available(macOS 14, *)
@main
struct Server {
    /// The server's host.
    private let host: String
    /// The server's port.
    private let port: Int
    /// The server's event loop group.
    private let eventLoopGroup: any EventLoopGroup

    static func main() async throws {
        // We are creating this event loop group at the top level and it will live until
        // the process exits. This means we also don't have to shut it down.
        //
        // Note that we start this group with 1 thread. In general, most NIO programs
        // should use 1 thread as a default unless they're planning to be a network
        // proxy or something that is expecting to be dominated by packet parsing. Most
        // servers aren't, and NIO is very fast, so 1 NIO thread is quite capable of
        // saturating the average small to medium sized machine.
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let server = Server(
            host: "localhost",
            port: 8765,
            eventLoopGroup: eventLoopGroup
        )
        try await server.run()
    }

    /// This method starts the server and handles incoming connections.
    func run() async throws {
        let channel = try await ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(
                host: self.host,
                port: self.port,
                childChannelConfiguration: .init(
                    inboundType: ByteBuffer.self,
                    outboundType: ByteBuffer.self
                )
            )

        // We are handling each incoming connection in a separate child task. It is important
        // to use a discarding task group here which automatically discards finished child tasks
        // otherwise this task group would end up leaking memory of all finished connection tasks.
        try await withThrowingDiscardingTaskGroup { group in
            for try await connectionChannel in channel.inboundStream {
                group.addTask {
                    print("Handling new connection")
                    await self.handleConnection(channel: connectionChannel)
                    print("Done handling connection")
                }
            }
        }
    }

    /// This method handles a single connection by echoing back all inbound data.
    private func handleConnection(channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async {
        // Note that this method is non-throwing and we are catching any error.
        // We do this since we don't want to tear down the whole server when a single connection
        // encounters an error.
        do {
            for try await inboundData in channel.inboundStream {
                print("Received request (\(String(buffer: inboundData)))")
                try await channel.outboundWriter.write(inboundData)
            }
        } catch {
            print("Hit error: \(error)")
        }
    }
}
#else
@main
struct Server {
    static func main() {
        fatalError("Requires at least Swift 5.9")
    }
}
#endif
