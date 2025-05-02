//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
@main
struct Client {
    /// The host to connect to.
    private let host: String
    /// The port to connect to.
    private let port: Int
    /// The client's event loop group.
    private let eventLoopGroup: MultiThreadedEventLoopGroup

    enum UpgradeResult {
        case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
        case notUpgraded
    }

    static func main() async throws {
        let client = Client(
            host: "localhost",
            port: 8888,
            eventLoopGroup: .singleton
        )
        try await client.run()
    }

    /// This method starts the client and tries to setup a WebSocket connection.
    func run() async throws {
        let upgradeResult: EventLoopFuture<UpgradeResult> = try await ClientBootstrap(group: self.eventLoopGroup)
            .connect(
                host: self.host,
                port: self.port
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    let upgrader = NIOTypedWebSocketClientUpgrader<UpgradeResult>(
                        upgradePipelineHandler: { (channel, _) in
                            channel.eventLoop.makeCompletedFuture {
                                let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
                                    wrappingChannelSynchronously: channel
                                )
                                return UpgradeResult.websocket(asyncChannel)
                            }
                        }
                    )

                    var headers = HTTPHeaders()
                    headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
                    headers.add(name: "Content-Length", value: "0")

                    let requestHead = HTTPRequestHead(
                        version: .http1_1,
                        method: .GET,
                        uri: "/",
                        headers: headers
                    )

                    let clientUpgradeConfiguration = NIOTypedHTTPClientUpgradeConfiguration(
                        upgradeRequestHead: requestHead,
                        upgraders: [upgrader],
                        notUpgradingCompletionHandler: { channel in
                            channel.eventLoop.makeCompletedFuture {
                                UpgradeResult.notUpgraded
                            }
                        }
                    )

                    let negotiationResultFuture = try channel.pipeline.syncOperations
                        .configureUpgradableHTTPClientPipeline(
                            configuration: .init(upgradeConfiguration: clientUpgradeConfiguration)
                        )

                    return negotiationResultFuture
                }
            }

        // We are awaiting and handling the upgrade result now.
        try await self.handleUpgradeResult(upgradeResult)
    }

    /// This method handles the upgrade result.
    private func handleUpgradeResult(_ upgradeResult: EventLoopFuture<UpgradeResult>) async throws {
        switch try await upgradeResult.get() {
        case .websocket(let websocketChannel):
            print("Handling websocket connection")
            try await self.handleWebsocketChannel(websocketChannel)
            print("Done handling websocket connection")
        case .notUpgraded:
            // The upgrade to websocket did not succeed. We are just exiting in this case.
            print("Upgrade declined")
        }
    }

    private func handleWebsocketChannel(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) async throws {
        // We are sending a ping frame and then
        // start to handle all inbound frames.

        let pingFrame = WebSocketFrame(fin: true, opcode: .ping, data: ByteBuffer(string: "Hello!"))
        try await channel.executeThenClose { inbound, outbound in
            try await outbound.write(pingFrame)

            for try await frame in inbound {
                switch frame.opcode {
                case .pong:
                    print("Received pong: \(String(buffer: frame.data))")

                case .text:
                    print("Received: \(String(buffer: frame.data))")

                case .connectionClose:
                    // Handle a received close frame. We're just going to close by returning from this method.
                    print("Received Close instruction from server")
                    return
                case .binary, .continuation, .ping:
                    // We ignore these frames.
                    break
                default:
                    // Unknown frames are errors.
                    return
                }
            }
        }
    }
}
