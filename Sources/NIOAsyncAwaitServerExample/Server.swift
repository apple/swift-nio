//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
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

#if canImport(_Concurrency) && compiler(>=5.5.2)

/// `Server` is the top-level object, responsible for running our
/// TCP echo server.
///
/// This object owns the configuration and manages the setup and
/// teardown of the server state.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class Server {
    private let host: String
    private let port: Int

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    func run() async throws {
        // This is the main run function: it starts the server.
        //
        // Note that this does not spawn a background Task in order to do this:
        // it takes over whatever Task it is spawned on. This is an important
        // property: it allows the user to decide which Task tree is responsible
        // for running the server, and therefore responsible for cancelling it.
        //
        // In here we create a task group of our own: the way we intend to use it
        // is discussed below.

        // Note that we start this group with 1 thread. In general, most NIO programs
        // should use 1 thread as a default unless they're planning to be a network
        // proxy or something that is expecting to be dominated by packet parsing. Most
        // servers aren't, and NIO is very fast, so 1 NIO thread is quite capable of
        // saturating the average small to medium sized machine.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let serverChannelAndStream: ChannelAndStream<Channel>
        do {
            // Inside this do block we want to catch any errors from creating the bootstrap.
            // We still have to tidy up, so we can't just let this throw from here.
            serverChannelAndStream = try await self.makeServerChannel(group: group)
        } catch {
            // Couldn't create the server channel. We're done here. Shut down the loop and go home.
            try await group.shutdownGracefully()
            throw error
        }

        print("Server listening on \(self.host):\(self.port)")

        // We split these two apart here to avoid capturing more than we want to
        // in any given closure.
        let serverChannel = serverChannelAndStream.channel
        let serverChannelStream = serverChannelAndStream.stream

        // We now have the server channel and the stream, we can start our work. First, though,
        // we need to prepare to handle cancellation.
        //
        // If this Task is cancelled, the first thing to do is to shut down the server channel.
        // This will have the effect of terminating the async loop that makes up the rest of this Task,
        // which will naturally bring it to a close.

        // TODO: error handling!
        try await withTaskCancellationHandler {
            // Now we accept new connections in a loop. Each of these is going to be dispatched
            // to a new child Task in a TaskGroup. These Tasks will be responsible for running the
            // child connections.
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                for try await childChannel in serverChannelStream {
                    taskGroup.addTask {
                        print("handling new child channel")
                        await Self.handleChildChannel(childChannel)
                    }
                }
            }
        } onCancel: {
            print("Cancelled the parent task")
            // This is a nice property of NIO: we can do this without actually
            // awaiting it.
            serverChannel.close(promise: nil)
        }

        // In our final step, we shut the loop down gracefully. This isn't necessary at
        // program exit, but we demonstrate it here in case you have a need to do it in
        // your own program.
        try await group.shutdownGracefully()
    }

    private func makeServerChannel(group: EventLoopGroup) async throws -> ChannelAndStream<Channel> {
        // We create a server bootstrap, as normal. Note that we don't add any
        // application handlers using the channel initializers. If we had protocol
        // handlers (such as the HTTP encoders and decoders) we would add them here,
        // but we don't.
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        let channel = try await bootstrap.bind(host: self.host, port: self.port).get()

        // We have an extra do-catch here because in principle adding the NIOInboundChannelStream
        // can fail. It's unlikely, but if it does we want to clean up the server channel. This
        // gives this method the nice property that either it entirely succeeds or entirely fails.
        do {
            // We set the buffer size to maxMessagesPerRead. This is a nice middle ground: it ensures a
            // full read will fit in an empty buffer nicely.
            let maxMessagesPerRead = try await channel.getOption(ChannelOptions.maxMessagesPerRead).get()
            let config = NIOInboundChannelStreamConfig(bufferSize: Int(maxMessagesPerRead))
            let stream = try await channel.makeAsyncStream(of: Channel.self, config: config)

            return ChannelAndStream(channel: channel, stream: stream)
        } catch {
            // If creating the stream fails, we have to clean up the server channel here. We suppress any errors
            // from close: they will just obscure the real problem.
            try? await channel.close()
            throw error
        }
    }

    private static func handleChildChannel(_ channel: Channel) async {
        // This function defines the "main loop" for each child channel. This is where our
        // business logic goes! As this is just a TCP echo server our business logic is pretty
        // dang simple, but it's good to see it nonetheless.
        //
        // You'll notice that this function is not marked "throws". That's because there is no
        // action for our caller to take if we hit an error: we're just going to log it and drop
        // the connection. Easy!

        // Once again, we set a cancellation handler, and once again it just drops this channel.
        await withTaskCancellationHandler {
            do {
                // Again, we wrap the channel in a stream, and again, we use maxMessagesPerRead as our buffer
                // size.
                let bufferSize = try await channel.getOption(ChannelOptions.maxMessagesPerRead).get()
                let config = NIOInboundChannelStreamConfig(bufferSize: Int(bufferSize))
                let inboundMessageStream = try await channel.makeAsyncStream(of: ByteBuffer.self, config: config)

                // And here's our business logic! As we're a TCP echo server, we just echo the bytes back
                // to the client.
                //
                // For extra credit, let me pose an interview question I once received: with the pattern
                // below, it's possible for us to accidentally livelock the connection. How, and how could
                // we change our business logic to fix it?
                for try await message in inboundMessageStream {
                    print("did receive message")
                    try await channel.writeAndFlush(message)
                }
            } catch {
                // In a real server we'd log the error here, but I didn't want to add swift-log
                // to the mix because I figured it'd just confuse matters and obscure what this
                // program was really doing. You should log here!
                //
                // Additionally, we close the channel. We don't care about any errors we hit
                // while doing that: they aren't material.
                print("Errored child channel: \(error)")
                try? await channel.close()
            }
        } onCancel: {
            print("cancelled child channel")
            channel.close(promise: nil)
        }
    }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
fileprivate struct ChannelAndStream<InboundIn> {
    var channel: Channel
    var stream: NIOInboundChannelStream<InboundIn>
}

#endif
