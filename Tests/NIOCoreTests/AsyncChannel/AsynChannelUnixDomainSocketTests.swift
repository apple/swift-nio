//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2025 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
#if canImport(Testing)
import NIOPosix
import Testing

@testable import NIOCore

@Suite
private enum AsynChannelUnixDomainSocketTests {
    /// This is a end-to-end async channel based test.
    ///
    /// The server side listens on a UNIX domain socket, and the client connects to this socket.
    ///
    /// The server and client exchange simple, line based messages.
    @available(macOS 10.15, iOS 17, tvOS 13, watchOS 6, *)
    @Test()
    static func runServer() async throws {
        try await confirmation("Client did receive message") { clientDidReceive in
            try await confirmation("Server did receive message") { serverDidReceive in
                try await check(
                    clientDidReceive: clientDidReceive,
                    serverDidReceive: serverDidReceive
                )
            }
        }
    }
}

@available(iOS 17.0, *)
private func check(
    clientDidReceive: Confirmation,
    serverDidReceive: Confirmation
) async throws {
    // This uses a hard-coded path.
    //
    // The path of a UNIX domain socket has a relatively low limit on its total
    // length, and we thus can not put this inside some (potentially) deeply
    // nested directory hierarchy.
    let path = "/tmp/9ac7750dc22a066066871aadf481e31a"
    let serverChannel = try await makeServerChannel(path: path)

    try await withThrowingDiscardingTaskGroup { group in
        try await serverChannel.executeThenClose { inbound in
            group.addTask {
                // Create a client connection to the server:
                let clientChannel = try await makeClientChannel(path: path)
                print("Executing client channel")
                try await clientChannel.executeThenClose { inbound, outbound in
                    print("C: Sending hello")
                    try await outbound.write("Hello")

                    var inboundIterator = inbound.makeAsyncIterator()
                    guard let messageA = try await inboundIterator.next() else { return }
                    print("C: Did receive '\(messageA)'")
                    clientDidReceive.confirm()
                    #expect(messageA == "Hello")

                    try await outbound.write("QUIT")
                }
            }

            for try await connectionChannel in inbound {
                group.addTask {
                    print("Handling new connection")
                    await handleConnection(
                        channel: connectionChannel,
                        serverDidReceive: serverDidReceive
                    )
                    print("Done handling connection")
                }
                break
            }
        }
    }
}

private func makeServerChannel(
    path: String
) async throws -> NIOAsyncChannel<NIOAsyncChannel<String, String>, Never> {
    try await ServerBootstrap(
        group: NIOSingletons.posixEventLoopGroup
    ).bind(
        unixDomainSocketPath: path,
        cleanupExistingSocketFile: true,
        serverBackPressureStrategy: nil
    ) { childChannel in
        childChannel.eventLoop.makeCompletedFuture {
            try childChannel.pipeline.syncOperations.addHandler(ByteToMessageHandler(NewlineDelimiterCoder()))
            try childChannel.pipeline.syncOperations.addHandler(MessageToByteHandler(NewlineDelimiterCoder()))
            return try NIOAsyncChannel<String, String>(
                wrappingChannelSynchronously: childChannel
            )
        }
    }
}

private func makeClientChannel(
    path: String
) async throws -> NIOAsyncChannel<String, String> {
    try await ClientBootstrap(group: NIOSingletons.posixEventLoopGroup)
        .connect(unixDomainSocketPath: path)
        .flatMap { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(NewlineDelimiterCoder()))
                try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(NewlineDelimiterCoder()))
                return try NIOAsyncChannel<String, String>(wrappingChannelSynchronously: channel)
            }
        }
        .get()
}

private func handleConnection(
    channel: NIOAsyncChannel<String, String>,
    serverDidReceive: Confirmation
) async {
    do {
        print("S: New channel")
        try await channel.executeThenClose { inbound, outbound in
            for try await message in inbound {
                print("S: Did receive '\(message)'")
                guard message != "QUIT" else { return }
                serverDidReceive.confirm()
                try await outbound.write(message)
            }
            print("S: Bye")
        }
    } catch {
        print("Error: \(error)")
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
#endif  // canImport(Testing)
