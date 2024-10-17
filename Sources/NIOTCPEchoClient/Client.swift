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
struct Client {
    /// The host to connect to.
    private let host: String
    /// The port to connect to.
    private let port: Int
    /// The client's event loop group.
    private let eventLoopGroup: MultiThreadedEventLoopGroup

    static func main() async throws {
        let client = Client(
            host: "localhost",
            port: 8765,
            eventLoopGroup: .singleton
        )
        try await client.run()
    }

    /// This method sends a bunch of requests.
    func run() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0...20 {
                group.addTask {
                    try await self.sendRequest(number: i)
                }
            }

            try await group.waitForAll()
        }
    }

    private func sendRequest(number: Int) async throws {
        let channel = try await ClientBootstrap(group: self.eventLoopGroup)
            .connect(
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

        try await channel.executeThenClose { inbound, outbound in
            print("Connection(\(number)): Writing request")
            try await outbound.write("Hello on connection \(number)")

            for try await inboundData in inbound {
                print("Connection(\(number)): Received response (\(inboundData))")

                // We only expect a single response so we can exit here.
                // Once, we exit out of this loop and the references to the `NIOAsyncChannel` are dropped
                // the connection is going to close itself.
                break
            }
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
