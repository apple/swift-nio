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

        let server = Client(
            host: "localhost",
            port: 8765,
            eventLoopGroup: eventLoopGroup
        )
        try await server.run()

        print("Done sending requests; exiting in 5 seconds")
        try await Task.sleep(for: .seconds(5))
    }

    /// This method starts the server and handles incoming connections.
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
            .connect(
                host: self.host,
                port: self.port,
                channelConfiguration: .init(
                    inboundType: ByteBuffer.self,
                    outboundType: ByteBuffer.self
                )
            )

        print("Connection(\(number)): Writing request")
        try await channel.outboundWriter.write(ByteBuffer(string: "Hello on connection \(number)"))

        for try await inboundData in channel.inboundStream {
            print("Connection(\(number)): Received response (\(String(buffer: inboundData)))")

            // We only expect a single response so we can exit here
            break
        }
    }
}#else
@main
struct Client {
    static func main() {
        fatalError("Requires at least Swift 5.9")
    }
}
#endif
