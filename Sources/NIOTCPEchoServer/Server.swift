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

import NIOCore
import NIOPosix

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
@main
struct Server {
    /// The server's host.
    private let host: String
    /// The server's port.
    private let port: Int
    /// The server's event loop group.
    private let eventLoopGroup: MultiThreadedEventLoopGroup

    static func main() async throws {
        let server = Server(
            host: "localhost",
            port: 8765,
            eventLoopGroup: .singleton
        )
        try await server.run()
    }

    /// This method starts the server and handles incoming connections.
    func run() async throws {
        let channel = try await ServerBootstrap(group: self.eventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(
                host: self.host,
                port: self.port
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    // We are using two simple handlers here to frame our messages with "\n"
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(NewlineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(NewlineDelimiterCoder()))

                    return try NIOAsyncChannel(
                        wrappingChannelSynchronously: channel,
                        configuration: NIOAsyncChannel.Configuration(
                            inboundType: String.self,
                            outboundType: String.self
                        )
                    )
                }
            }

        // We are handling each incoming connection in a separate child task. It is important
        // to use a discarding task group here which automatically discards finished child tasks.
        // A normal task group retains all child tasks and their outputs in memory until they are
        // consumed by iterating the group or by exiting the group. Since, we are never consuming
        // the results of the group we need the group to automatically discard them; otherwise, this
        // would result in a memory leak over time.
        try await withThrowingDiscardingTaskGroup { group in
            try await channel.executeThenClose { inbound in
                for try await connectionChannel in inbound {
                    group.addTask {
                        print("Handling new connection")
                        await self.handleConnection(channel: connectionChannel)
                        print("Done handling connection")
                    }
                }
            }
        }
    }

    /// This method handles a single connection by echoing back all inbound data.
    private func handleConnection(channel: NIOAsyncChannel<String, String>) async {
        // Note that this method is non-throwing and we are catching any error.
        // We do this since we don't want to tear down the whole server when a single connection
        // encounters an error.
        do {
            try await channel.executeThenClose { inbound, outbound in
                for try await inboundData in inbound {
                    print("Received request (\(inboundData))")
                    try await outbound.write(inboundData)
                }
            }
        } catch {
            print("Hit error: \(error)")
        }
    }
}

/// A simple newline based encoder and decoder.
private final class NewlineDelimiterCoder: ByteToMessageDecoder, MessageToByteEncoder {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = String

    private let newLine = UInt8(ascii: "\n")

    init() {}

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let readableBytes = buffer.readableBytesView

        if let firstLine = readableBytes.firstIndex(of: self.newLine).map({ readableBytes[..<$0] }) {
            buffer.moveReaderIndex(forwardBy: firstLine.count + 1)
            // Fire a read without a newline
            context.fireChannelRead(Self.wrapInboundOut(String(buffer: ByteBuffer(firstLine))))
            return .continue
        } else {
            return .needMoreData
        }
    }

    func encode(data: String, out: inout ByteBuffer) throws {
        out.writeString(data)
        out.writeInteger(self.newLine)
    }
}
