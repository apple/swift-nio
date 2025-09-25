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
@_spi(StructuredConcurrencyNIOAsyncChannel) import NIOPosix

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
        try await ServerBootstrap(group: self.eventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(
                target: .hostAndPort(self.host, self.port)
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
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
            } handleChildChannel: { channel in
                print("Handling new connection")
                await self.handleConnection(channel: channel)
                print("Done handling connection")
            } handleServerChannel: { serverChannel in
                // you can access the server channel here. You must not use call
                // `inbound` or `outbound` on it.
            }
    }

    /// This method handles a single connection by echoing back all inbound data.
    private func handleConnection(channel: NIOAsyncChannel<String, String>) async {
        // Note that this method is non-throwing and we are catching any error.
        // We do this since we don't want to tear down the whole server when a single connection
        // encounters an error.
        do {
            for try await inboundData in channel.inbound {
                print("Received request (\(inboundData))")
                try await channel.outbound.write(inboundData)
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
