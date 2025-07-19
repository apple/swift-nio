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

import Atomics
import NIOConcurrencyHelpers
import NIOCore
import XCTest

@testable import NIOPosix

class SelectorTest: XCTestCase {

    func testDeregisterWhileProcessingEvents() throws {
        try assertDeregisterWhileProcessingEvents(closeAfterDeregister: false)
    }

    func testDeregisterAndCloseWhileProcessingEvents() throws {
        try assertDeregisterWhileProcessingEvents(closeAfterDeregister: true)
    }

    private func assertDeregisterWhileProcessingEvents(closeAfterDeregister: Bool) throws {
        struct TestRegistration: Registration {

            let socket: Socket
            var interested: SelectorEventSet
            var registrationID: SelectorRegistrationID
        }

        let thread = NIOThread(handle: .init(handle: pthread_self()), desiredName: nil)
        let selector = try NIOPosix.Selector<TestRegistration>(thread: thread)
        defer {
            XCTAssertNoThrow(try selector.close())
            thread.takeOwnership()
        }

        let socket1 = try Socket(protocolFamily: .inet, type: .stream, protocolSubtype: .default)
        defer {
            if socket1.isOpen {
                XCTAssertNoThrow(try socket1.close())
            }
        }
        try socket1.setNonBlocking()

        let socket2 = try Socket(protocolFamily: .inet, type: .stream, protocolSubtype: .default)
        defer {
            if socket2.isOpen {
                XCTAssertNoThrow(try socket2.close())
            }
        }
        try socket2.setNonBlocking()

        let serverSocket = try assertNoThrowWithValue(
            ServerSocket.bootstrap(
                protocolFamily: .inet,
                host: "127.0.0.1",
                port: 0
            )
        )
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
        try selector.register(
            selectable: socket1,
            interested: [.reset, .error, .write],
            makeRegistration: { ev, regID in
                TestRegistration(socket: socket1, interested: ev, registrationID: regID)
            }
        )

        try selector.register(
            selectable: socket2,
            interested: [.reset, .error, .write],
            makeRegistration: { ev, regID in
                TestRegistration(socket: socket2, interested: ev, registrationID: regID)
            }
        )

        var readyCount = 0
        try selector.whenReady(strategy: .block) {
        } _: { ev in
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
    func testWeDoNotDeliverEventsForPreviouslyClosedChannels() throws {
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
            private let hasReConnectEventLoopTickFinished: NIOLoopBoundBox<Bool>
            private var didRead: Bool = false

            init(hasReConnectEventLoopTickFinished: NIOLoopBoundBox<Bool>, didReadPromise: EventLoopPromise<Void>) {
                self.didReadPromise = didReadPromise
                self.hasReConnectEventLoopTickFinished = hasReConnectEventLoopTickFinished
            }

            func channelActive(context: ChannelHandlerContext) {
                // we expect these channels to be connected within the re-connect event loop tick
                XCTAssertFalse(self.hasReConnectEventLoopTickFinished.value)
            }

            func channelInactive(context: ChannelHandlerContext) {
                // we expect these channels to be close a while after the re-connect event loop tick
                XCTAssertTrue(self.hasReConnectEventLoopTickFinished.value)
                XCTAssertTrue(self.didRead)
                if !self.didRead {
                    self.didReadPromise.fail(DidNotReadError.didNotReadGotInactive)
                    context.close(promise: nil)
                }
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                // we expect these channels to get data only a while after the re-connect event loop tick as it's
                // impossible to get a read notification in the very same event loop tick that you got registered
                XCTAssertTrue(self.hasReConnectEventLoopTickFinished.value)

                XCTAssertFalse(self.didRead)
                var buf = Self.unwrapInboundIn(data)
                XCTAssertEqual(1, buf.readableBytes)
                XCTAssertEqual("H", buf.readString(length: 1)!)
                self.didRead = true
                self.didReadPromise.succeed(())
            }

            func channelReadComplete(context: ChannelHandlerContext) {
                // we expect these channels to get data only a while after the re-connect event loop tick as it's
                // impossible to get a read notification in the very same event loop tick that you got registered
                XCTAssertTrue(self.hasReConnectEventLoopTickFinished.value)
                XCTAssertTrue(self.didRead)
                if !self.didRead {
                    self.didReadPromise.fail(DidNotReadError.didNotReadGotReadComplete)
                    context.close(promise: nil)
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

            private let allChannels: NIOLoopBoundBox<[Channel]>
            private let serverAddress: SocketAddress
            private let everythingWasReadPromise: EventLoopPromise<Void>
            private let hasReConnectEventLoopTickFinished: NIOLoopBoundBox<Bool>

            init(
                allChannels: NIOLoopBoundBox<[Channel]>,
                hasReConnectEventLoopTickFinished: NIOLoopBoundBox<Bool>,
                serverAddress: SocketAddress,
                everythingWasReadPromise: EventLoopPromise<Void>
            ) {
                self.allChannels = allChannels
                self.serverAddress = serverAddress
                self.everythingWasReadPromise = everythingWasReadPromise
                self.hasReConnectEventLoopTickFinished = hasReConnectEventLoopTickFinished
            }

            func channelActive(context: ChannelHandlerContext) {
                // collect all the channels
                context.channel.getOption(.allowRemoteHalfClosure).whenSuccess { halfClosureAllowed in
                    precondition(
                        halfClosureAllowed,
                        "the test configuration is bogus: half-closure is dis-allowed which breaks the setup of this test"
                    )
                }
                self.allChannels.value.append(context.channel)
            }

            func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
                // this is the `.readEOF` that is triggered by the `ServerHandler`'s `close` calls because our channel
                // supports half-closure
                guard
                    self.allChannels.value.count
                        == SelectorTest.testWeDoNotDeliverEventsForPreviouslyClosedChannels_numberOfChannelsToUse
                else {
                    return
                }
                // all channels are up, so let's construct the situation we want to be in:
                // 1. let's close half the channels
                // 2. then re-connect (must be synchronous) the same number of channels and we'll get fd number re-use

                context.channel.eventLoop.execute { [hasReConnectEventLoopTickFinished] in
                    // this will be run immediately after we processed all `Selector` events so when
                    // `self.hasReConnectEventLoopTickFinished.value` becomes true, we're out of the event loop
                    // tick that is interesting.
                    XCTAssertFalse(hasReConnectEventLoopTickFinished.value)
                    hasReConnectEventLoopTickFinished.value = true
                }
                XCTAssertFalse(self.hasReConnectEventLoopTickFinished.value)

                let everyOtherIndex = stride(
                    from: 0,
                    to: SelectorTest.testWeDoNotDeliverEventsForPreviouslyClosedChannels_numberOfChannelsToUse,
                    by: 2
                )
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
                    let hasBeenAdded = NIOLockedValueBox(false)
                    let p = context.channel.eventLoop.makePromise(of: Void.self)
                    reconnectedChannelsHaveRead.append(p.futureResult)
                    let newChannel = ClientBootstrap(group: context.eventLoop)
                        .channelInitializer { [hasReConnectEventLoopTickFinished] channel in
                            channel.eventLoop.assumeIsolated().makeCompletedFuture {
                                let sync = channel.pipeline.syncOperations
                                try sync.addHandler(
                                    HappyWhenReadHandler(
                                        hasReConnectEventLoopTickFinished: hasReConnectEventLoopTickFinished,
                                        didReadPromise: p
                                    )
                                )
                                hasBeenAdded.withLockedValue { $0 = true }
                            }
                        }
                        .connect(to: self.serverAddress)
                        .map { [hasReConnectEventLoopTickFinished] (channel: Channel) -> Void in
                            XCTAssertFalse(
                                hasReConnectEventLoopTickFinished.value,
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
                                """
                            )
                        }
                    // just to make sure we got `newChannel` synchronously and we could add our handler to the
                    // pipeline synchronously too.
                    XCTAssertTrue(newChannel.isFulfilled)
                    XCTAssertTrue(hasBeenAdded.withLockedValue { $0 })
                }

                // if all the new re-connected channels have read, then we're happy here.
                EventLoopFuture.andAllSucceed(reconnectedChannelsHaveRead, on: context.eventLoop)
                    .cascade(to: self.everythingWasReadPromise)
                // let's also remove all the channels so this code will not be triggered again.
                self.allChannels.value.removeAll()
            }

        }

        /// This spawns a server, always send a character immediately and after the first
        /// `SelectorTest.numberOfChannelsToUse` have been established, we'll close them all. That will trigger
        /// an `.readEOF` in the connected client channels which will then trigger other interesting things (see above).
        class ServerHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            private var number: Int = 0
            private let allServerChannels: NIOLoopBoundBox<[Channel]>
            private let numberOfConnectedChannels: NIOLoopBoundBox<Int>

            init(allServerChannels: NIOLoopBoundBox<[Channel]>, numberOfConnectedChannels: NIOLoopBoundBox<Int>) {
                self.allServerChannels = allServerChannels
                self.numberOfConnectedChannels = numberOfConnectedChannels
            }

            func channelActive(context: ChannelHandlerContext) {
                var buf = context.channel.allocator.buffer(capacity: 1)
                buf.writeString("H")
                context.channel.writeAndFlush(buf, promise: nil)
                self.number += 1
                self.allServerChannels.value.append(context.channel)
                if self.allServerChannels.value.count
                    == SelectorTest.testWeDoNotDeliverEventsForPreviouslyClosedChannels_numberOfChannelsToUse
                {
                    // just to be sure all of the client channels have connected
                    XCTAssertEqual(
                        SelectorTest.testWeDoNotDeliverEventsForPreviouslyClosedChannels_numberOfChannelsToUse,
                        numberOfConnectedChannels.value
                    )
                    for channel in self.allServerChannels.value {
                        channel.close(promise: nil)
                    }
                }
            }
        }

        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let el = elg.next()
        defer {
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }

        // all of the following are boxed as we need mutable references to them, they can only be read/written on the
        // event loop `el`.
        let loopBounds = try el.submit {
            let allServerChannels = NIOLoopBoundBox([Channel](), eventLoop: el)
            let allChannels = NIOLoopBoundBox([Channel](), eventLoop: el)
            let hasReConnectEventLoopTickFinished = NIOLoopBoundBox(false, eventLoop: el)
            let numberOfConnectedChannels = NIOLoopBoundBox(0, eventLoop: el)
            return (allServerChannels, allChannels, hasReConnectEventLoopTickFinished, numberOfConnectedChannels)
        }.wait()
        let allServerChannels = loopBounds.0
        let allChannels = loopBounds.1
        let hasReConnectEventLoopTickFinished = loopBounds.2
        let numberOfConnectedChannels = loopBounds.3

        XCTAssertNoThrow(
            try withTemporaryUnixDomainSocketPathName { udsPath in
                let secondServerChannel = try! ServerBootstrap(group: el)
                    .childChannelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(
                                ServerHandler(
                                    allServerChannels: allServerChannels,
                                    numberOfConnectedChannels: numberOfConnectedChannels
                                )
                            )
                        }
                    }
                    .bind(to: SocketAddress(unixDomainSocketPath: udsPath))
                    .wait()

                let everythingWasReadPromise = el.makePromise(of: Void.self)
                let futures = try el.submit { () -> [EventLoopFuture<Channel>] in
                    (0..<SelectorTest.testWeDoNotDeliverEventsForPreviouslyClosedChannels_numberOfChannelsToUse).map {
                        (_: Int) in
                        ClientBootstrap(group: el)
                            .channelOption(.allowRemoteHalfClosure, value: true)
                            .channelInitializer { channel in
                                channel.eventLoop.makeCompletedFuture {
                                    try channel.pipeline.syncOperations.addHandler(
                                        CloseEveryOtherAndOpenNewOnesHandler(
                                            allChannels: allChannels,
                                            hasReConnectEventLoopTickFinished: hasReConnectEventLoopTickFinished,
                                            serverAddress: secondServerChannel.localAddress!,
                                            everythingWasReadPromise: everythingWasReadPromise
                                        )
                                    )
                                }
                            }
                            .connect(to: secondServerChannel.localAddress!)
                            .map { channel in
                                numberOfConnectedChannels.value += 1
                                return channel
                            }
                    }
                }.wait()
                for future in futures {
                    XCTAssertNoThrow(try future.wait())
                }

                XCTAssertNoThrow(try everythingWasReadPromise.futureResult.wait())
            }
        )
    }

    func testTimerFDIsLevelTriggered() throws {
        // this is a regression test for https://github.com/apple/swift-nio/issues/872
        let delayToUseInMicroSeconds: Int64 = 100_000  // needs to be much greater than time it takes to EL.execute

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        class FakeSocket: Socket {
            private let hasBeenClosedPromise: EventLoopPromise<Void>
            init(hasBeenClosedPromise: EventLoopPromise<Void>, socket: NIOBSDSocket.Handle) throws {
                self.hasBeenClosedPromise = hasBeenClosedPromise
                try super.init(socket: socket)
            }
            override func close() throws {
                self.hasBeenClosedPromise.succeed(())
                try super.close()
            }
        }
        var socketFDs: [CInt] = [-1, -1]
        XCTAssertNoThrow(
            try Posix.socketpair(
                domain: .local,
                type: .stream,
                protocolSubtype: .default,
                socketVector: &socketFDs
            )
        )

        let numberFires = ManagedAtomic(0)
        let el = group.next() as! SelectableEventLoop
        let channelHasBeenClosedPromise = el.makePromise(of: Void.self)
        let channel = try SocketChannel(
            socket: FakeSocket(
                hasBeenClosedPromise: channelHasBeenClosedPromise,
                socket: socketFDs[0]
            ),
            eventLoop: el
        )
        let sched = el.scheduleRepeatedTask(
            initialDelay: .microseconds(delayToUseInMicroSeconds),
            delay: .microseconds(delayToUseInMicroSeconds)
        ) { (_: RepeatedTask) in
            numberFires.wrappingIncrement(ordering: .relaxed)
        }
        XCTAssertNoThrow(
            try el.submit {
                // EL tick 1: this is used to
                //   - actually arm the timer (timerfd_settime)
                //   - set the channel registration up
                if numberFires.load(ordering: .relaxed) > 0 {
                    print(
                        "WARNING: This test hit a race and this result doesn't mean it actually worked."
                            + " This should really only ever happen in very bizarre conditions."
                    )
                }
                channel.interestedEvent = [.readEOF, .reset, .error]
                func workaroundSR9815() {
                    channel.registerAlreadyConfigured0(promise: nil)
                }
                workaroundSR9815()
            }.wait()
        )
        usleep(10_000)  // this makes this repro very stable
        el.execute {
            // EL tick 2: this is used to
            //   - close one end of the socketpair so that in EL tick 3, we'll see a EPOLLHUP
            //   - sleep `delayToUseInMicroSeconds + 10` so in EL tick 3, we'll also see timerfd fire
            close(socketFDs[1])
            usleep(.init(delayToUseInMicroSeconds))
        }

        // EL tick 3: happens in the background here. We will likely lose the timer signal because of the
        // `deregistrationsHappened` workaround in `Selector.swift` and we expect to pick it up again when we enter
        // `epoll_wait`/`kevent` next. This however only works if the timer event is level triggered.
        assert(
            numberFires.load(ordering: .relaxed) > 5,
            within: .seconds(1),
            "timer only fired \(numberFires.load(ordering: .relaxed)) times"
        )
        sched.cancel()
        XCTAssertNoThrow(try channelHasBeenClosedPromise.futureResult.wait())
    }
}
