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

// The purpose of this example is to demonstrate our recommended pattern for structuring
// NIO-using applications that want to take full advantage of async/await, while operating
// as a server.
//
// This pattern is not necessarily entirely obvious. The goal is to ensure that the business
// logic can fully take advantage of structured concurrency, ensuring that all the work tasks
// have appropriate parent tasks that will be able to cancel and monitor them as needed. This
// is not so difficult with a client, but with a server it requires substantial extra thought.
// In addition, you need to bridge the async/await world with the NIO world, which can make
// a somewhat difficult problem even more subtle.
//
// This example program implements a basic TCP echo server, with the business logic in
// async/await code. The reason to keep the logic so simple is to allow us to focus on the
// structure of the program, including the way it manages tasks.

#if canImport(_Concurrency) && compiler(>=5.5.2)

/// `Server` is the top-level object, responsible for running our
/// TCP echo server.
///
/// This object owns the configuration and manages the setup and
/// teardown of the server state.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
@main
final class Server {
    private let host: String
    private let port: Int

    static func main() async {
        let server = Server(host: "localhost", port: 8765)
        try! await server.run()
    }

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

        // Next, create our server channel. We need this to be a NIOAsyncChannel.
        let serverChannel = try! await self.makeServerChannel(group: group)

        // We now have the server channel, we can start our work.

        // TODO: error handling!
        // Now we accept new connections in a loop. Each of these is going to be dispatched
        // to a new child Task in a TaskGroup. These Tasks will be responsible for running the
        // child connections.
        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            for try await childChannel in serverChannel.inboundStream {
                taskGroup.addTask {
                    await Self.handleChildChannel(childChannel)
                }
            }
        }

        // In our final step, we shut the loop down gracefully. This isn't necessary at
        // program exit, but we demonstrate it here in case you have a need to do it in
        // your own program.
        try await group.shutdownGracefully()
    }

    private func makeServerChannel(group: EventLoopGroup) async throws -> NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never> {
        // We create a server bootstrap, as normal. Note that we don't add any
        // application handlers using the channel initializers. If we had protocol
        // handlers (such as the HTTP encoders and decoders) we would add them here,
        // but we don't.
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        return try await bootstrap.bind(host: self.host, port: self.port)
    }

    private static func handleChildChannel(_ asyncChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async {
        // This function defines the "main loop" for each child channel. This is where our
        // business logic goes! As this is just a TCP echo server our business logic is pretty
        // dang simple, but it's good to see it nonetheless.
        //
        // You'll notice that this function is not marked "throws". That's because there is no
        // action for our caller to take if we hit an error: we're just going to log it and drop
        // the connection. Easy!
        do {
            // And here's our business logic! As we're a TCP echo server, we just echo the bytes back
            // to the client.
            //
            // For extra credit, let me pose an interview question I once received: with the pattern
            // below, it's possible for us to accidentally livelock the connection. How, and how could
            // we change our business logic to fix it?
            for try await message in asyncChannel.inboundStream {
                try await asyncChannel.writeAndFlush(message)
            }
        } catch {
            // In a real server we'd log the error here, but I didn't want to add swift-log
            // to the mix because I figured it'd just confuse matters and obscure what this
            // program was really doing. You should log here!
            print("Hit error: \(error)")
        }
    }
}
#endif
