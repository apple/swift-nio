//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import NIO
import NIOConcurrencyHelpers
import XCTest

class SelectorTest: XCTestCase {

    func testDeregisterWhileProcessingEvents() throws {
        try assertDeregisterWhileProcessingEvents(closeAfterDeregister: false)
    }

    func testDeregisterAndCloseWhileProcessingEvents() throws {
        try assertDeregisterWhileProcessingEvents(closeAfterDeregister: true)
    }

    private func assertDeregisterWhileProcessingEvents(closeAfterDeregister: Bool) throws {
        struct TestRegistration: Registration {
            var interested: SelectorEventSet
            let socket: Socket
        }

        let selector = try NIO.Selector<TestRegistration>()
        defer {
            XCTAssertNoThrow(try selector.close())
        }

        let socket1 = try Socket(protocolFamily: PF_INET, type: Posix.SOCK_STREAM)
        defer {
            if socket1.isOpen {
                XCTAssertNoThrow(try socket1.close())
            }
        }
        try socket1.setNonBlocking()

        let socket2 = try Socket(protocolFamily: PF_INET, type: Posix.SOCK_STREAM)
        defer {
            if socket2.isOpen {
                XCTAssertNoThrow(try socket2.close())
            }
        }
        try socket2.setNonBlocking()

        let serverSocket = try assertNoThrowWithValue(ServerSocket.bootstrap(protocolFamily: PF_INET,
                                                                             host: "127.0.0.1",
                                                                             port: 0))
        defer {
            XCTAssertNoThrow(try serverSocket.close())
        }
        _ = try socket1.connect(to: serverSocket.localAddress())
        _ = try socket2.connect(to: serverSocket.localAddress())

        let accepted1 = try serverSocket.accept()!
        defer {
            XCTAssertNoThrow(try accepted1.close())
        }
        let accepted2 = try serverSocket.accept()!
        defer {
            XCTAssertNoThrow(try accepted2.close())
        }

        // Register both sockets with .write. This will ensure both are ready when calling selector.whenReady.
        try selector.register(selectable: socket1 , interested: [.reset, .write], makeRegistration: { ev in
            TestRegistration(interested: ev, socket: socket1)
        })

        try selector.register(selectable: socket2 , interested: [.reset, .write], makeRegistration: { ev in
            TestRegistration(interested: ev, socket: socket2)
        })

        var readyCount = 0
        try selector.whenReady(strategy: .block) { ev in
            readyCount += 1
            if socket1 === ev.registration.socket {
                try selector.deregister(selectable: socket2)
                if closeAfterDeregister {
                    try socket2.close()
                }
            } else if socket2 === ev.registration.socket {
                try selector.deregister(selectable: socket1)
                if closeAfterDeregister {
                    try socket1.close()
                }
            } else {
                XCTFail("ev.registration.socket was neither \(socket1) or \(socket2) but \(ev.registration.socket)")
            }
        }
        XCTAssertEqual(1, readyCount)
    }

    private static let testWeDoNotDeliverEventsForPreviouslyClosedChannels_numberOfChannelsToUse = 10
    func testWeDoNotDeliverEventsForPreviouslyClosedChannels() {
        /// We use this class to box mutable values, generally in this test anything boxed should only be read/written
        /// on the event loop `el`.
        class Box<T> {
            init(_ value: T) {
                self._value = value
            }
            private var _value: T
            var value: T {
                get {
                    XCTAssertNotNil(MultiThreadedEventLoopGroup.currentEventLoop)
                    return self._value
                }
                set {
                    XCTAssertNotNil(MultiThreadedEventLoopGroup.currentEventLoop)
                    self._value = newValue
                }
            }
        }
        enum DidNotReadError: Error {
            case didNotReadGotInactive
            case didNotReadGotReadComplete
        }

        /// This handler is inserted in the `ChannelPipeline` that are re-connected. So we're closing a bunch of
        /// channels and (in the same event loop tick) we then connect the same number for which I'm using the
        /// terminology 're-connect' here.
        /// These re-connected channels will re-use the fd numbers of the just closed channels. The interesting thing
        /// is that the `Selector` will still have events buffered for the _closed fds_. Note: the re-connected ones
        /// will end up using the _same_ fds and this test ensures that we're not getting the outdated events. In this
        /// case the outdated events are all `.readEOF`s which manifest as `channelReadComplete`s. If we're delivering
        /// outdated events, they will also happen in the _same event loop tick_ and therefore we do quite a few
        /// assertions that we're either in or not in that interesting event loop tick.
        class HappyWhenReadHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            private let didReadPromise: EventLoopPromise<Void>
            private let hasReConnectEventLoopTickFinished: Box<Bool>
            private var didRead: Bool = false

            init(hasReConnectEventLoopTickFinished: Box<Bool>, didReadPromise: EventLoopPromise<Void>) {
                self.didReadPromise = didReadPromise
                self.hasReConnectEventLoopTickFinished = hasReConnectEventLoopTickFinished
            }

            func channelActive(ctx: ChannelHandlerContext) {
                // we expect these channels to be connected within the re-connect event loop tick
                XCTAssertFalse(self.hasReConnectEventLoopTickFinished.value)
            }

            func channelInactive(ctx: ChannelHandlerContext) {
                // we expect these channels to be close a while after the re-connect event loop tick
                XCTAssertTrue(self.hasReConnectEventLoopTickFinished.value)
                XCTAssertTrue(self.didRead)
                if !self.didRead {
                    self.didReadPromise.fail(error: DidNotReadError.didNotReadGotInactive)
                    ctx.close(promise: nil)
                }
            }

            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                // we expect these channels to get data only a while after the re-connect event loop tick as it's
                // impossible to get a read notification in the very same event loop tick that you got registered
                XCTAssertTrue(self.hasReConnectEventLoopTickFinished.value)

                XCTAssertFalse(self.didRead)
                var buf = self.unwrapInboundIn(data)
                XCTAssertEqual(1, buf.readableBytes)
                XCTAssertEqual("H", buf.readString(length: 1)!)
                self.didRead = true
                self.didReadPromise.succeed(result: ())
            }

            func channelReadComplete(ctx: ChannelHandlerContext) {
                // we expect these channels to get data only a while after the re-connect event loop tick as it's
                // impossible to get a read notification in the very same event loop tick that you got registered
                XCTAssertTrue(self.hasReConnectEventLoopTickFinished.value)
                XCTAssertTrue(self.didRead)
                if !self.didRead {
                    self.didReadPromise.fail(error: DidNotReadError.didNotReadGotReadComplete)
                    ctx.close(promise: nil)
                }
            }
        }

        /// This handler will wait for all client channels to have come up and for one of them to have received EOF.
        /// (We will see the EOF as they're set to support half-closure). Then, it'll close half of those file
        /// descriptors and open the same number of new ones. The new ones (called re-connected) will share the same
        /// fd numbers as the recently closed ones. That brings us in an interesting situation: There will (very likely)
        /// be `.readEOF` events enqueued for the just closed ones and because the re-connected channels share the same
        /// fd numbers danger looms. The `HappyWhenReadHandler` above makes sure nothing bad happens.
        class CloseEveryOtherAndOpenNewOnesHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            private let allChannels: Box<[Channel]>
            private let serverAddress: SocketAddress
            private let everythingWasReadPromise: EventLoopPromise<Void>
            private let hasReConnectEventLoopTickFinished: Box<Bool>

            init(allChannels: Box<[Channel]>,
                 hasReConnectEventLoopTickFinished: Box<Bool>,
                 serverAddress: SocketAddress,
                 everythingWasReadPromise: EventLoopPromise<Void>) {
                self.allChannels = allChannels
                self.serverAddress = serverAddress
                self.everythingWasReadPromise = everythingWasReadPromise
                self.hasReConnectEventLoopTickFinished = hasReConnectEventLoopTickFinished
            }

            func channelActive(ctx: ChannelHandlerContext) {
                // collect all the channels
                ctx.channel.getOption(option: ChannelOptions.allowRemoteHalfClosure).whenSuccess { halfClosureAllowed in
                    precondition(halfClosureAllowed,
                                 "the test configuration is bogus: half-closure is dis-allowed which breaks the setup of this test")
                }
                self.allChannels.value.append(ctx.channel)
            }

            func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
                // this is the `.readEOF` that is triggered by the `ServerHandler`'s `close` calls because our channel
                // supports half-closure
                guard self.allChannels.value.count == SelectorTest.testWeDoNotDeliverEventsForPreviouslyClosedChannels_numberOfChannelsToUse else {
                    return
                }
                // all channels are up, so let's construct the situation we want to be in:
                // 1. let's close half the channels
                // 2. then re-connect (must be synchronous) the same number of channels and we'll get fd number re-use

                ctx.channel.eventLoop.execute {
                    // this will be run immediately after we processed all `Selector` events so when
                    // `self.hasReConnectEventLoopTickFinished.value` becomes true, we're out of the event loop
                    // tick that is interesting.
                    XCTAssertFalse(self.hasReConnectEventLoopTickFinished.value)
                    self.hasReConnectEventLoopTickFinished.value = true
                }
                XCTAssertFalse(self.hasReConnectEventLoopTickFinished.value)

                let everyOtherIndex = stride(from: 0, to: SelectorTest.testWeDoNotDeliverEventsForPreviouslyClosedChannels_numberOfChannelsToUse, by: 2)
                for f in everyOtherIndex {
                    XCTAssertTrue(self.allChannels.value[f].isActive)
                    // close will succeed synchronously as we're on the right event loop.
                    self.allChannels.value[f].close(promise: nil)
                    XCTAssertFalse(self.allChannels.value[f].isActive)
                }

                // now we have completed stage 1: we freed up a bunch of file descriptor numbers, so let's open
                // some new ones
                var reconnectedChannelsHaveRead: [EventLoopFuture<Void>] = []
                for _ in everyOtherIndex {
                    var hasBeenAdded: Bool = false
                    let p: EventLoopPromise<Void> = ctx.channel.eventLoop.newPromise()
                    reconnectedChannelsHaveRead.append(p.futureResult)
                    let newChannel = ClientBootstrap(group: ctx.eventLoop)
                        .channelInitializer { channel in
                            channel.pipeline.add(handler: HappyWhenReadHandler(hasReConnectEventLoopTickFinished: self.hasReConnectEventLoopTickFinished,
                                                                               didReadPromise: p)).map {
                                                                                hasBeenAdded = true
                            }
                        }
                        .connect(to: self.serverAddress)
                        .map { (channel: Channel) -> Void in
                            XCTAssertFalse(self.hasReConnectEventLoopTickFinished.value,
                                           """
                                               This is bad: the connect of the channels to be re-connected has not
                                               completed synchronously.
                                               We assumed that on all platform a UNIX Domain Socket connect is
                                               synchronous but we must be wrong :(.
                                               The good news is: Not everything is lost, this test should also work
                                               if you instead open a regular file (in O_RDWR) and just use this file's
                                               fd with `ClientBootstrap(group: group).withConnectedSocket(fileFD)`.
                                               Sure, a file is not a socket but it's always readable and writable and
                                               that fulfills the requirements we have here.
                                               I still hope this change will never have to be done.
                                               Note: if you changed anything about the pipeline's handler adding/removal
                                               you might also have a bug there.
                                               """)
                    }
                    // just to make sure we got `newChannel` synchronously and we could add our handler to the
                    // pipeline synchronously too.
                    XCTAssertTrue(newChannel.isFulfilled)
                    XCTAssertTrue(hasBeenAdded)
                }

                // if all the new re-connected channels have read, then we're happy here.
                EventLoopFuture<Void>.andAll(reconnectedChannelsHaveRead,
                                             eventLoop: ctx.eventLoop).cascade(promise: self.everythingWasReadPromise)
                // let's also remove all the channels so this code will not be triggered again.
                self.allChannels.value.removeAll()
            }

        }

        // all of the following are boxed as we need mutable references to them, they can only be read/written on the
        // event loop `el`.
        let allServerChannels: Box<[Channel]> = Box([])
        var allChannels: Box<[Channel]> = Box([])
        let hasReConnectEventLoopTickFinished: Box<Bool> = Box(false)
        let numberOfConnectedChannels: Box<Int> = Box(0)

        /// This spawns a server, always send a character immediately and after the first
        /// `SelectorTest.numberOfChannelsToUse` have been established, we'll close them all. That will trigger
        /// an `.readEOF` in the connected client channels which will then trigger other interesting things (see above).
        class ServerHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            private var number: Int = 0
            private let allServerChannels: Box<[Channel]>
            private let numberOfConnectedChannels: Box<Int>

            init(allServerChannels: Box<[Channel]>, numberOfConnectedChannels: Box<Int>) {
                self.allServerChannels = allServerChannels
                self.numberOfConnectedChannels = numberOfConnectedChannels
            }

            func channelActive(ctx: ChannelHandlerContext) {
                var buf = ctx.channel.allocator.buffer(capacity: 1)
                buf.write(string: "H")
                ctx.channel.writeAndFlush(buf, promise: nil)
                self.number += 1
                self.allServerChannels.value.append(ctx.channel)
                if self.allServerChannels.value.count == SelectorTest.testWeDoNotDeliverEventsForPreviouslyClosedChannels_numberOfChannelsToUse {
                    // just to be sure all of the client channels have connected
                    XCTAssertEqual(SelectorTest.testWeDoNotDeliverEventsForPreviouslyClosedChannels_numberOfChannelsToUse, numberOfConnectedChannels.value)
                    self.allServerChannels.value.forEach { c in
                        c.close(promise: nil)
                    }
                }
            }
        }
        let el = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
        defer {
            XCTAssertNoThrow(try el.syncShutdownGracefully())
        }
        let tempDir = createTemporaryDirectory()
        let secondServerChannel = try! ServerBootstrap(group: el)
            .childChannelInitializer { channel in
                channel.pipeline.add(handler: ServerHandler(allServerChannels: allServerChannels,
                                                            numberOfConnectedChannels: numberOfConnectedChannels))
            }
            .bind(to: SocketAddress(unixDomainSocketPath: "\(tempDir)/server-sock.uds"))
            .wait()

        let everythingWasReadPromise: EventLoopPromise<Void> = el.newPromise()
        XCTAssertNoThrow(try el.submit { () -> [EventLoopFuture<Channel>] in
            (0..<SelectorTest.testWeDoNotDeliverEventsForPreviouslyClosedChannels_numberOfChannelsToUse).map { (_: Int) in
                ClientBootstrap(group: el)
                    .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    .channelInitializer { channel in
                        channel.pipeline.add(handler: CloseEveryOtherAndOpenNewOnesHandler(allChannels: allChannels,
                                                                                           hasReConnectEventLoopTickFinished: hasReConnectEventLoopTickFinished,
                                                                                           serverAddress: secondServerChannel.localAddress!,
                                                                                           everythingWasReadPromise: everythingWasReadPromise))
                    }
                    .connect(to: secondServerChannel.localAddress!)
                    .map { channel in
                        numberOfConnectedChannels.value += 1
                        return channel
                    }
                }
        }.wait().forEach { XCTAssertNoThrow(try $0.wait()) } as Void)
        XCTAssertNoThrow(try everythingWasReadPromise.futureResult.wait())
        XCTAssertNoThrow(try FileManager.default.removeItem(at: URL(fileURLWithPath: tempDir)))
    }
}
