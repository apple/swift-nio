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
struct Client {
    /// The host to connect to.
    private let host: String
    /// The port to connect to.
    private let port: Int
    /// The client's event loop group.
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

        let client = Client(
            host: "localhost",
            port: 8765,
            eventLoopGroup: eventLoopGroup
        )
        try await client.run()

        print("Done sending requests; exiting in 5 seconds")
        // We are only sleeping here to keep the terminal output visible a bit longer in Xcode
        // so that users can see that something happened. This should normally not be done!
        try await Task.sleep(for: .seconds(5))
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
        let channel = try await ClientBootstrap(group: eventLoopGroup)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    // We are using two simple handlers here to frame our messages with "\n"
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(NewlineDelimiterCoder()))
                    try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(NewlineDelimiterCoder()))
                }
            }
            .connect(
                host: self.host,
                port: self.port,
                channelConfiguration: .init(
                    inboundType: String.self,
                    outboundType: String.self
                )
            )

        print("Connection(\(number)): Writing request")
        try await channel.outboundWriter.write("Hello on connection \(number)")

        for try await inboundData in channel.inboundStream {
            print("Connection(\(number)): Received response (\(inboundData))")

            // We only expect a single response so we can exit here
            break
        }
    }
}

/// A simple newline based encoder and decoder.
private final class NewlineDelimiterCoder: ByteToMessageDecoder, MessageToByteEncoder {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = String

    private let newLine = "\n".utf8.first!

    init() {}

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let readable = buffer.withUnsafeReadableBytes { $0.firstIndex(of: self.newLine) }
        if let readable = readable {
            context.fireChannelRead(self.wrapInboundOut(buffer.readString(length: readable)!))
            buffer.moveReaderIndex(forwardBy: 1)
            return .continue
        }
        return .needMoreData
    }

    func encode(data: String, out: inout ByteBuffer) throws {
        out.writeString(data)
        out.writeString("\n")
    }
}
#else
@main
struct Client {
    static func main() {
        fatalError("Requires at least Swift 5.9")
    }
}
#endif
