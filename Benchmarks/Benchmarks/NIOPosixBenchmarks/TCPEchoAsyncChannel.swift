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

func runTCPEchoAsyncChannel(numberOfWrites: Int, eventLoop: EventLoop) async throws {
    let serverChannel = try await ServerBootstrap(group: eventLoop)
        .bind(
            host: "127.0.0.1",
            port: 0
        ) { channel in
            channel.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel(
                    wrappingChannelSynchronously: channel,
                    configuration: .init(
                        inboundType: ByteBuffer.self,
                        outboundType: ByteBuffer.self
                    )
                )
            }
        }

    let clientChannel = try await ClientBootstrap(group: eventLoop)
        .connect(
            host: "127.0.0.1",
            port: serverChannel.channel.localAddress!.port!
        ) { channel in
            channel.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel(
                    wrappingChannelSynchronously: channel,
                    configuration: .init(
                        inboundType: ByteBuffer.self,
                        outboundType: ByteBuffer.self
                    )
                )
            }
        }

    let messageSize = 10000

    try await withThrowingTaskGroup(of: Void.self) { group in
        // This child task is echoing back the data on the server.
        group.addTask {
            try await serverChannel.executeThenClose { serverChannelInbound in
                for try await connectionChannel in serverChannelInbound {
                    try await connectionChannel.executeThenClose {
                        connectionChannelInbound,
                        connectionChannelOutbound in
                        for try await inboundData in connectionChannelInbound {
                            try await connectionChannelOutbound.write(inboundData)
                        }
                    }
                }
            }
        }

        try await clientChannel.executeThenClose { inbound, outbound in
            // This child task is collecting the echoed back responses.
            group.addTask {
                var receivedData = 0
                for try await inboundData in inbound {
                    receivedData += inboundData.readableBytes

                    if receivedData == numberOfWrites * messageSize {
                        return
                    }
                }
            }

            // Let's start sending data.
            let data = ByteBuffer(repeating: 0, count: messageSize)
            for _ in 0..<numberOfWrites {
                try await outbound.write(data)
            }

            // Waiting for the child task that collects the responses to finish.
            try await group.next()

            // Cancelling the server child task.
            group.cancelAll()
            try await serverChannel.channel.closeFuture.get()
            try await clientChannel.channel.closeFuture.get()
        }
    }
}
