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
import XCTest
@testable import NIO
import Dispatch
import NIOConcurrencyHelpers

public final class EventLoopTest : XCTestCase {

    public func testSchedule() throws {
        let nanos: NIODeadline = .now()
        let amount: TimeAmount = .seconds(1)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }
        let value = try eventLoopGroup.next().scheduleTask(in: amount) {
            true
        }.futureResult.wait()

        XCTAssertTrue(NIODeadline.now() - nanos >= amount)
        XCTAssertTrue(value)
    }

    public func testScheduleWithDelay() throws {
        let smallAmount: TimeAmount = .milliseconds(100)
        let longAmount: TimeAmount = .seconds(1)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }

        // First, we create a server and client channel, but don't connect them.
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "127.0.0.1", port: 0).wait())
        let clientBootstrap = ClientBootstrap(group: eventLoopGroup)

        // Now, schedule two tasks: one that takes a while, one that doesn't.
        let nanos: NIODeadline = .now()
        let longFuture = eventLoopGroup.next().scheduleTask(in: longAmount) {
            true
        }.futureResult

        XCTAssertTrue(try assertNoThrowWithValue(try eventLoopGroup.next().scheduleTask(in: smallAmount) {
            true
        }.futureResult.wait()))

        // Ok, the short one has happened. Now we should try connecting them. This connect should happen
        // faster than the final task firing.
        _ = try assertNoThrowWithValue(clientBootstrap.connect(to: serverChannel.localAddress!).wait()) as Channel
        XCTAssertTrue(NIODeadline.now() - nanos < longAmount)

        // Now wait for the long-delayed task.
        XCTAssertTrue(try assertNoThrowWithValue(try longFuture.wait()))
        // Now we're ok.
        XCTAssertTrue(NIODeadline.now() - nanos >= longAmount)
    }

    public func testScheduleCancelled() throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }
        let ran = Atomic<Bool>(value: false)
        let scheduled = eventLoopGroup.next().scheduleTask(in: .seconds(2)) {
            ran.store(true)
        }

        scheduled.cancel()

        let nanos = NIODeadline.now()
        let amount: TimeAmount = .seconds(2)
        let value = try eventLoopGroup.next().scheduleTask(in: amount) {
            true
        }.futureResult.wait()

        XCTAssertTrue(NIODeadline.now() - nanos >= amount)
        XCTAssertTrue(value)
        XCTAssertFalse(ran.load())
    }

    public func testScheduleRepeatedTask() throws {
        let nanos: NIODeadline = .now()
        let initialDelay: TimeAmount = .milliseconds(5)
        let delay: TimeAmount = .milliseconds(10)
        let count = 5
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }

        let expect = expectation(description: "Is cancelling RepatedTask")
        let counter = Atomic<Int>(value: 0)
        let loop = eventLoopGroup.next()
        loop.scheduleRepeatedTask(initialDelay: initialDelay, delay: delay) { repeatedTask -> Void in
            XCTAssertTrue(loop.inEventLoop)
            let initialValue = counter.load()
            _ = counter.add(1)
            if initialValue == 0 {
                XCTAssertTrue(NIODeadline.now() - nanos >= initialDelay)
            } else if initialValue == count {
                expect.fulfill()
                repeatedTask.cancel()
            }
        }

        waitForExpectations(timeout: 1) { error in
            XCTAssertNil(error)
            XCTAssertEqual(counter.load(), count + 1)
            XCTAssertTrue(NIODeadline.now() - nanos >= initialDelay + Int64(count) * delay)
        }
    }

    public func testScheduledTaskThatIsImmediatelyCancelledNeverFires() throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }

        let loop = eventLoopGroup.next()
        loop.execute {
            let task = loop.scheduleTask(in: .milliseconds(0)) {
                XCTFail()
            }
            task.cancel()
        }
        Thread.sleep(until: .init(timeIntervalSinceNow: 0.1))
    }

    public func testRepeatedTaskThatIsImmediatelyCancelledNeverFires() throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }

        let loop = eventLoopGroup.next()
        loop.execute {
            let task = loop.scheduleRepeatedTask(initialDelay: .milliseconds(0), delay: .milliseconds(0)) { task in
                XCTFail()
            }
            task.cancel()
        }
        Thread.sleep(until: .init(timeIntervalSinceNow: 0.1))
    }

    public func testScheduleRepeatedTaskCancelFromDifferentThread() throws {
        let nanos: NIODeadline = .now()
        let initialDelay: TimeAmount = .milliseconds(5)
        let delay: TimeAmount = .milliseconds(0) // this will actually force the race from issue #554 to happen frequently
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }

        let expect = expectation(description: "Is cancelling RepatedTask")
        let group = DispatchGroup()
        let loop = eventLoopGroup.next()
        group.enter()
        var isAllowedToFire = true // read/write only on `loop`
        var hasFired = false // read/write only on `loop`
        let repeatedTask = loop.scheduleRepeatedTask(initialDelay: initialDelay, delay: delay) { (_: RepeatedTask) -> Void in
            XCTAssertTrue(loop.inEventLoop)
            if !hasFired {
                // we can only do this once as we can only leave the DispatchGroup once but we might lose a race and
                // the timer might fire more than once (until `shouldNoLongerFire` becomes true).
                hasFired = true
                group.leave()
                expect.fulfill()
            }
            XCTAssertTrue(isAllowedToFire)
        }
        group.notify(queue: DispatchQueue.global()) {
            repeatedTask.cancel()
            loop.execute {
                // only now do we know that the `cancel` must have gone through
                isAllowedToFire = false
            }
        }

        waitForExpectations(timeout: 1) { error in
            XCTAssertNil(error)
            XCTAssertTrue(NIODeadline.now() - nanos >= initialDelay)
        }
    }

    public func testScheduleRepeatedTaskToNotRetainRepeatedTask() throws {
        let initialDelay: TimeAmount = .milliseconds(5)
        let delay: TimeAmount = .milliseconds(10)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        weak var weakRepeated: RepeatedTask?
        try { () -> Void in
            let repeated = eventLoopGroup.next().scheduleRepeatedTask(initialDelay: initialDelay, delay: delay) { (_: RepeatedTask) -> Void in }
            weakRepeated = repeated
            XCTAssertNotNil(weakRepeated)
            repeated.cancel()
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }()
        assert(weakRepeated == nil, within: .seconds(1))
    }

    public func testScheduleRepeatedTaskToNotRetainEventLoop() throws {
        weak var weakEventLoop: EventLoop? = nil
        try {
            let initialDelay: TimeAmount = .milliseconds(5)
            let delay: TimeAmount = .milliseconds(10)
            let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            weakEventLoop = eventLoopGroup.next()
            XCTAssertNotNil(weakEventLoop)

            eventLoopGroup.next().scheduleRepeatedTask(initialDelay: initialDelay, delay: delay) { (_: RepeatedTask) -> Void in }
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }()
        assert(weakEventLoop == nil, within: .seconds(1))
    }

    func testScheduledRepeatedAsyncTask() {
        let eventLoop = EmbeddedEventLoop()
        var counter = 0
        let repeatedTask = eventLoop.scheduleRepeatedAsyncTask(initialDelay: .milliseconds(10),
                                                               delay: .milliseconds(10)) { (_: RepeatedTask) in
            counter += 1
            let p = eventLoop.makePromise(of: Void.self)
            eventLoop.scheduleTask(in: .milliseconds(10)) {
                p.succeed(())
            }
            return p.futureResult
        }
        for _ in 0..<10 {
            // just running shouldn't do anything
            eventLoop.run()
        }
        // t == 0: nothing
        XCTAssertEqual(0, counter)

        // t == 5: nothing
        eventLoop.advanceTime(by: .milliseconds(5))
        eventLoop.run()
        XCTAssertEqual(0, counter)

        // t == 10: once
        eventLoop.advanceTime(by: .milliseconds(5))
        eventLoop.run()
        XCTAssertEqual(1, counter)

        // t == 15: still once
        eventLoop.advanceTime(by: .milliseconds(5))
        eventLoop.run()
        XCTAssertEqual(1, counter)

        // t == 20: still once (because the task takes 10ms to execute)
        eventLoop.advanceTime(by: .milliseconds(5))
        eventLoop.run()
        XCTAssertEqual(1, counter)

        // t == 25: still once (because the task takes 10ms to execute)
        eventLoop.advanceTime(by: .milliseconds(5))
        eventLoop.run()
        XCTAssertEqual(1, counter)

        // t == 30: twice
        eventLoop.advanceTime(by: .milliseconds(5))
        eventLoop.run()
        XCTAssertEqual(2, counter)

        // t == 40: twice
        eventLoop.advanceTime(by: .milliseconds(10))
        eventLoop.run()
        XCTAssertEqual(2, counter)

        // t == 50: three times
        eventLoop.advanceTime(by: .milliseconds(10))
        eventLoop.run()
        XCTAssertEqual(3, counter)

        // t == 60: three times
        eventLoop.advanceTime(by: .milliseconds(10))
        eventLoop.run()
        XCTAssertEqual(3, counter)

        // t == 89: four times
        eventLoop.advanceTime(by: .milliseconds(29))
        eventLoop.run()
        XCTAssertEqual(4, counter)

        // t == 90: five times
        eventLoop.advanceTime(by: .milliseconds(1))
        eventLoop.run()
        XCTAssertEqual(5, counter)

        repeatedTask.cancel()

        eventLoop.run()
        XCTAssertEqual(5, counter)

        eventLoop.advanceTime(by: .hours(10))
        eventLoop.run()
        XCTAssertEqual(5, counter)
    }

    public func testEventLoopGroupMakeIterator() throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        defer {
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }

        var counter = 0
        var innerCounter = 0
        eventLoopGroup.makeIterator().forEach { loop in
            counter += 1
            loop.makeIterator().forEach { _ in
                innerCounter += 1
            }
        }

        XCTAssertEqual(counter, System.coreCount)
        XCTAssertEqual(innerCounter, System.coreCount)
    }

    public func testEventLoopMakeIterator() throws {
        let eventLoop = EmbeddedEventLoop()
        let iterator = eventLoop.makeIterator()
        defer {
            XCTAssertNoThrow(try eventLoop.syncShutdownGracefully())
        }

        var counter = 0
        iterator.forEach { loop in
            XCTAssertTrue(loop === eventLoop)
            counter += 1
        }

        XCTAssertEqual(counter, 1)
    }

    public func testMultipleShutdown() throws {
        // This test catches a regression that causes it to intermittently fail: it reveals bugs in synchronous shutdown.
        // Do not ignore intermittent failures in this test!
        let threads = 8
        let numBytes = 256
        let group = MultiThreadedEventLoopGroup(numberOfThreads: threads)

        // Create a server channel.
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "127.0.0.1", port: 0).wait())

        // We now want to connect to it. To try to slow this stuff down, we're going to use a multiple of the number
        // of event loops.
        for _ in 0..<(threads * 5) {
            let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!)
                .wait())

            var buffer = clientChannel.allocator.buffer(capacity: numBytes)
            for i in 0..<numBytes {
                buffer.writeInteger(UInt8(i % 256))
            }

            try clientChannel.writeAndFlush(NIOAny(buffer)).wait()
        }

        // We should now shut down gracefully.
        try group.syncShutdownGracefully()
    }

    public func testShuttingDownFailsRegistration() throws {
        // This test catches a regression where the selectable event loop would allow a socket registration while
        // it was nominally "shutting down". To do this, we take advantage of the fact that the event loop attempts
        // to cleanly shut down all the channels before it actually closes. We add a custom channel that we can use
        // to wedge the event loop in the "shutting down" state, ensuring that we have plenty of time to attempt the
        // registration.
        class WedgeOpenHandler: ChannelDuplexHandler {
            typealias InboundIn = Any
            typealias OutboundIn = Any
            typealias OutboundOut = Any

            private let promiseRegisterCallback: (EventLoopPromise<Void>) -> Void

            var closePromise: EventLoopPromise<Void>? = nil
            private let channelActivePromise: EventLoopPromise<Void>?

            init(channelActivePromise: EventLoopPromise<Void>? = nil, _ promiseRegisterCallback: @escaping (EventLoopPromise<Void>) -> Void) {
                self.promiseRegisterCallback = promiseRegisterCallback
                self.channelActivePromise = channelActivePromise
            }

            func channelActive(context: ChannelHandlerContext) {
                self.channelActivePromise?.succeed(())
            }

            func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
                guard self.closePromise == nil else {
                    XCTFail("Attempted to create duplicate close promise")
                    return
                }
                XCTAssertTrue(context.channel.isActive)
                self.closePromise = context.eventLoop.makePromise()
                self.closePromise!.futureResult.whenSuccess {
                    context.close(mode: mode, promise: promise)
                }
                promiseRegisterCallback(self.closePromise!)
            }
        }

        let promiseQueue = DispatchQueue(label: "promiseQueue")
        var promises: [EventLoopPromise<Void>] = []

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            do {
                try group.syncShutdownGracefully()
            } catch EventLoopError.shutdown {
                // Fine, that's expected if the test completed.
            } catch {
                XCTFail("Unexpected error on close: \(error)")
            }
        }
        let loop = group.next() as! SelectableEventLoop

        let serverChannelUp = group.next().makePromise(of: Void.self)
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(WedgeOpenHandler(channelActivePromise: serverChannelUp) { promise in
                    promiseQueue.sync { promises.append(promise) }
                })
            }
            .bind(host: "127.0.0.1", port: 0).wait())
        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }
        let connectPromise = loop.makePromise(of: Void.self)

        // We're going to create and register a channel, but not actually attempt to do anything with it.
        let wedgeHandler = WedgeOpenHandler { promise in
            promiseQueue.sync { promises.append(promise) }
        }
        let channel = try SocketChannel(eventLoop: loop, protocolFamily: AF_INET)
        try channel.eventLoop.submit {
            channel.pipeline.addHandler(wedgeHandler).flatMap {
                channel.register()
            }.flatMap {
                // connecting here to stop epoll from throwing EPOLLHUP at us
                channel.connect(to: serverChannel.localAddress!)
            }.cascade(to: connectPromise)
        }.wait()

        // Wait for the connect to complete.
        XCTAssertNoThrow(try connectPromise.futureResult.wait())

        XCTAssertNoThrow(try serverChannelUp.futureResult.wait())

        // Now we're going to start closing the event loop. This should not immediately succeed.
        let loopCloseFut = loop.closeGently()

        // Now we're going to attempt to register a new channel. This should immediately fail.
        let newChannel = try SocketChannel(eventLoop: loop, protocolFamily: AF_INET)

        do {
            try newChannel.register().wait()
            XCTFail("Register did not throw")
        } catch EventLoopError.shutdown {
            // All good
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Confirm that the loop still hasn't closed.
        XCTAssertFalse(loopCloseFut.isFulfilled)

        // Now let it close.
        promiseQueue.sync {
            promises.forEach { $0.succeed(()) }
        }
        XCTAssertNoThrow(try loopCloseFut.wait())
    }

    public func testEventLoopThreads() throws {
        var counter = 0
        let body: ThreadInitializer = { t in
            counter += 1
        }
        let threads: [ThreadInitializer] = [body, body]

        let group = MultiThreadedEventLoopGroup(threadInitializers: threads)

        XCTAssertEqual(2, counter)
        XCTAssertNoThrow(try group.syncShutdownGracefully())
    }

    public func testEventLoopPinned() throws {
        #if os(Linux)
            let body: ThreadInitializer = { t in
                let set = LinuxCPUSet(0)
                t.affinity = set
                XCTAssertEqual(set, t.affinity)
            }
            let threads: [ThreadInitializer] = [body, body]

            let group = MultiThreadedEventLoopGroup(threadInitializers: threads)

            XCTAssertNoThrow(try group.syncShutdownGracefully())
        #endif
    }

    public func testEventLoopPinnedCPUIdsConstructor() throws {
        #if os(Linux)
            let group = MultiThreadedEventLoopGroup(pinnedCPUIds: [0])
            let eventLoop = group.next()
            let set = try eventLoop.submit {
                NIOThread.current.affinity
            }.wait()

            XCTAssertEqual(LinuxCPUSet(0), set)
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        #endif
    }

    public func testCurrentEventLoop() throws {
        class EventLoopHolder {
            weak var loop: EventLoop?
            init(_ loop: EventLoop) {
                self.loop = loop
            }
        }

        func assertCurrentEventLoop0() throws -> EventLoopHolder {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

            let loop1 = group.next()
            let currentLoop1 = try loop1.submit {
                MultiThreadedEventLoopGroup.currentEventLoop
            }.wait()
            XCTAssertTrue(loop1 === currentLoop1)

            let loop2 = group.next()
            let currentLoop2 = try loop2.submit {
                MultiThreadedEventLoopGroup.currentEventLoop
            }.wait()
            XCTAssertTrue(loop2 === currentLoop2)
            XCTAssertFalse(loop1 === loop2)

            let holder = EventLoopHolder(loop2)
            XCTAssertNotNil(holder.loop)
            XCTAssertNil(MultiThreadedEventLoopGroup.currentEventLoop)
            XCTAssertNoThrow(try group.syncShutdownGracefully())
            return holder
        }

        let holder = try assertCurrentEventLoop0()

        // We loop as the Thread used by SelectableEventLoop may not be gone yet.
        // In the next major version we should ensure to join all threads and so be sure all are gone when
        // syncShutdownGracefully returned.
        var tries = 0
        while holder.loop != nil {
            XCTAssertTrue(tries < 5, "Reference to EventLoop still alive after 5 seconds")
            sleep(1)
            tries += 1
        }
    }

    public func testShutdownWhileScheduledTasksNotReady() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        _ = eventLoop.scheduleTask(in: .hours(1)) { }
        try group.syncShutdownGracefully()
    }

    public func testCloseFutureNotifiedBeforeUnblock() throws {
        class AssertHandler: ChannelInboundHandler {
            typealias InboundIn = Any

            let groupIsShutdown = Atomic(value: false)
            let removed = Atomic(value: false)

            public func handlerRemoved(context: ChannelHandlerContext) {
                XCTAssertFalse(groupIsShutdown.load())
                XCTAssertTrue(removed.compareAndExchange(expected: false, desired: true))
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let assertHandler = AssertHandler()
        let serverSocket = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .bind(host: "localhost", port: 0).wait())
        let channel = try assertNoThrowWithValue(SocketChannel(eventLoop: eventLoop as! SelectableEventLoop,
                                                               protocolFamily: serverSocket.localAddress!.protocolFamily))
        XCTAssertNoThrow(try channel.pipeline.addHandler(assertHandler).wait() as Void)
        XCTAssertNoThrow(try channel.eventLoop.submit {
            channel.register().flatMap {
                channel.connect(to: serverSocket.localAddress!)
            }
        }.wait().wait() as Void)
        XCTAssertFalse(channel.closeFuture.isFulfilled)
        XCTAssertNoThrow(try group.syncShutdownGracefully())
        XCTAssertTrue(assertHandler.groupIsShutdown.compareAndExchange(expected: false, desired: true))
        XCTAssertTrue(assertHandler.removed.load())
        XCTAssertTrue(channel.closeFuture.isFulfilled)
        XCTAssertFalse(channel.isActive)
    }

    public func testFlatSubmitCloseFutureNotifiedBeforeUnblock() throws {
        class AssertHandler: ChannelInboundHandler {
            typealias InboundIn = Any

            let groupIsShutdown = Atomic(value: false)
            let removed = Atomic(value: false)

            public func handlerRemoved(context: ChannelHandlerContext) {
                XCTAssertFalse(groupIsShutdown.load())
                XCTAssertTrue(removed.compareAndExchange(expected: false, desired: true))
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let assertHandler = AssertHandler()
        let serverSocket = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .bind(host: "localhost", port: 0).wait())
        let channel = try assertNoThrowWithValue(SocketChannel(eventLoop: eventLoop as! SelectableEventLoop,
                                                               protocolFamily: serverSocket.localAddress!.protocolFamily))
        XCTAssertNoThrow(try channel.pipeline.addHandler(assertHandler).wait() as Void)
        XCTAssertNoThrow(try channel.eventLoop.flatSubmit {
            channel.register().flatMap {
                channel.connect(to: serverSocket.localAddress!)
            }
        }.wait() as Void)
        XCTAssertFalse(channel.closeFuture.isFulfilled)
        XCTAssertNoThrow(try group.syncShutdownGracefully())
        XCTAssertTrue(assertHandler.groupIsShutdown.compareAndExchange(expected: false, desired: true))
        XCTAssertTrue(assertHandler.removed.load())
        XCTAssertTrue(channel.closeFuture.isFulfilled)
        XCTAssertFalse(channel.isActive)
    }

    public func testScheduleMultipleTasks() throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }
        var array = Array<(Int, NIODeadline)>()
        let scheduled1 = eventLoopGroup.next().scheduleTask(in: .milliseconds(500)) {
            array.append((1, .now()))
        }

        let scheduled2 = eventLoopGroup.next().scheduleTask(in: .milliseconds(100)) {
            array.append((2, .now()))
        }

        let scheduled3 = eventLoopGroup.next().scheduleTask(in: .milliseconds(1000)) {
            array.append((3, .now()))
        }

        var result = try eventLoopGroup.next().scheduleTask(in: .milliseconds(1000)) {
            array
        }.futureResult.wait()

        XCTAssertTrue(scheduled1.futureResult.isFulfilled)
        XCTAssertTrue(scheduled2.futureResult.isFulfilled)
        XCTAssertTrue(scheduled3.futureResult.isFulfilled)

        let first = result.removeFirst()
        XCTAssertEqual(2, first.0)
        let second = result.removeFirst()
        XCTAssertEqual(1, second.0)
        let third = result.removeFirst()
        XCTAssertEqual(3, third.0)

        XCTAssertTrue(first.1 < second.1)
        XCTAssertTrue(second.1 < third.1)

        XCTAssertTrue(result.isEmpty)

    }
    
    public func testRepeatedTaskThatIsImmediatelyCancelledNotifies() throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }

        let loop = eventLoopGroup.next()
        let promise1: EventLoopPromise<Void> = loop.makePromise()
        let promise2: EventLoopPromise<Void> = loop.makePromise()
        let expect1 = XCTestExpectation(description: "Initializer promise was fulfilled")
        let expect2 = XCTestExpectation(description: "Cancellation-specific promise was fulfilled")
        promise1.futureResult.whenSuccess { expect1.fulfill() }
        promise2.futureResult.whenSuccess { expect2.fulfill() }
        loop.execute {
            let task = loop.scheduleRepeatedTask(initialDelay: .milliseconds(0), delay: .milliseconds(0), notifying: promise1) { task in
                XCTFail()
            }
            task.cancel(promise: promise2)
        }
        Thread.sleep(until: .init(timeIntervalSinceNow: 0.1))
        let res = XCTWaiter.wait(for: [expect1, expect2], timeout: 1.0)
        XCTAssertEqual(res, .completed)
    }

    public func testRepeatedTaskThatIsCancelledAfterRunningAtLeastTwiceNotifies() throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }

        let loop = eventLoopGroup.next()
        let promise1: EventLoopPromise<Void> = loop.makePromise()
        let promise2: EventLoopPromise<Void> = loop.makePromise()
        let expectRuns = XCTestExpectation(description: "Repeated task has run")
        expectRuns.expectedFulfillmentCount = 2
        let task = loop.scheduleRepeatedTask(initialDelay: .milliseconds(0), delay: .milliseconds(10), notifying: promise1) { task in
            expectRuns.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [expectRuns], timeout: 0.05), .completed)
        let expect1 = XCTestExpectation(description: "Initializer promise was fulfilled")
        let expect2 = XCTestExpectation(description: "Cancellation-specific promise was fulfilled")
        promise1.futureResult.whenSuccess { expect1.fulfill() }
        promise2.futureResult.whenSuccess { expect2.fulfill() }
        task.cancel(promise: promise2)
        XCTAssertEqual(XCTWaiter.wait(for: [expect1, expect2], timeout: 1.0), .completed)
    }

    public func testRepeatedTaskThatCancelsItselfNotifiesOnlyWhenFinished() throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }

        let loop = eventLoopGroup.next()
        let promise1: EventLoopPromise<Void> = loop.makePromise()
        let promise2: EventLoopPromise<Void> = loop.makePromise()
        let semaphore = DispatchSemaphore(value: 0)
        loop.scheduleRepeatedTask(initialDelay: .milliseconds(0), delay: .milliseconds(0), notifying: promise1) { task -> Void in
            task.cancel(promise: promise2)
            semaphore.wait()
        }
        let expectFail1 = XCTestExpectation(description: "Initializer promise was wrongly fulfilled")
        let expectFail2 = XCTestExpectation(description: "Cancellation-specific promise was wrongly fulfilled")
        let expect1 = XCTestExpectation(description: "Initializer promise was fulfilled")
        let expect2 = XCTestExpectation(description: "Cancellation-specific promise was fulfilled")
        promise1.futureResult.whenSuccess { expectFail1.fulfill(); expect1.fulfill() }
        promise2.futureResult.whenSuccess { expectFail2.fulfill(); expect2.fulfill() }
        XCTAssertEqual(XCTWaiter.wait(for: [expectFail1, expectFail2], timeout: 0.5), .timedOut)
        semaphore.signal()
        XCTAssertEqual(XCTWaiter.wait(for: [expect1, expect2], timeout: 0.5), .completed)
    }

    func testAndAllCompleteWithZeroFutures() {
        let eventLoop = EmbeddedEventLoop()
        let done = DispatchWorkItem {}
        EventLoopFuture<Void>.andAllComplete([], on: eventLoop).whenComplete { (result: Result<Void, Error>) in
            _ = result.mapError { error -> Error in
                XCTFail("unexpected error \(error)")
                return error
            }
            done.perform()
        }
        done.wait()
    }

    func testAndAllSucceedWithZeroFutures() {
        let eventLoop = EmbeddedEventLoop()
        let done = DispatchWorkItem {}
        EventLoopFuture<Void>.andAllSucceed([], on: eventLoop).whenComplete { result in
            _ = result.mapError { error -> Error in
                XCTFail("unexpected error \(error)")
                return error
            }
            done.perform()
        }
        done.wait()
    }

    func testCancelledScheduledTasksDoNotHoldOnToRunClosure() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        class Thing {}

        weak var weakThing: Thing? = nil

        func make() -> Scheduled<Never> {
            let aThing = Thing()
            weakThing = aThing
            return group.next().scheduleTask(in: .hours(1)) {
                preconditionFailure("this should definitely not run: \(aThing)")
            }
        }

        let scheduled = make()
        scheduled.cancel()
        assert(weakThing == nil, within: .seconds(1))
        XCTAssertThrowsError(try scheduled.futureResult.wait()) { error in
            XCTAssertEqual(EventLoopError.cancelled, error as? EventLoopError)
        }
    }

    func testIllegalCloseOfEventLoopFails() {
        // Vapor 3 closes EventLoops directly which is illegal and makes the `shutdownGracefully` of the owning
        // MultiThreadedEventLoopGroup never succeed.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        XCTAssertThrowsError(try group.next().syncShutdownGracefully()) { error in
            switch error {
            case EventLoopError.unsupportedOperation:
                () // expected
            default:
                XCTFail("illegal shutdown threw wrong error \(error)")
            }
        }
    }

    func testSubtractingDeadlineFromPastAndFuturesDeadlinesWorks() {
        let older = NIODeadline.now()
        Thread.sleep(until: Date().addingTimeInterval(0.02))
        let newer = NIODeadline.now()

        XCTAssertLessThan(older - newer, .nanoseconds(0))
        XCTAssertGreaterThan(newer - older, .nanoseconds(0))
    }

    func testCallingSyncShutdownGracefullyMultipleTimesShouldNotHang() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        try elg.syncShutdownGracefully()
        try elg.syncShutdownGracefully()
        try elg.syncShutdownGracefully()
    }

    func testCallingShutdownGracefullyMultipleTimesShouldExecuteAllCallbacks() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        let condition: ConditionLock<Int> = ConditionLock(value: 0)
        elg.shutdownGracefully { _ in
            if condition.lock(whenValue: 0, timeoutSeconds: 1) {
                condition.unlock(withValue: 1)
            }
        }
        elg.shutdownGracefully { _ in
            if condition.lock(whenValue: 1, timeoutSeconds: 1) {
                condition.unlock(withValue: 2)
            }
        }
        elg.shutdownGracefully { _ in
            if condition.lock(whenValue: 2, timeoutSeconds: 1) {
                condition.unlock(withValue: 3)
            }
        }

        guard condition.lock(whenValue: 3, timeoutSeconds: 1) else {
            XCTFail("Not all shutdown callbacks have been executed")
            return
        }
        condition.unlock()
    }

    func testEdgeCasesNIODeadlineMinusNIODeadline() {
        let smallestPossibleDeadline = NIODeadline.uptimeNanoseconds(.min)
        let largestPossibleDeadline = NIODeadline.uptimeNanoseconds(.max)
        let distantFuture = NIODeadline.distantFuture
        let distantPast = NIODeadline.distantPast
        let zeroDeadline = NIODeadline.uptimeNanoseconds(0)
        let nowDeadline = NIODeadline.now()

        let allDeadlines = [smallestPossibleDeadline, largestPossibleDeadline, distantPast, distantFuture,
                            zeroDeadline, nowDeadline]

        for deadline1 in allDeadlines {
            for deadline2 in allDeadlines {
                if deadline1 > deadline2 {
                    XCTAssertGreaterThan(deadline1 - deadline2, TimeAmount.nanoseconds(0))
                } else if deadline1 < deadline2 {
                    XCTAssertLessThan(deadline1 - deadline2, TimeAmount.nanoseconds(0))
                } else {
                    // they're equal.
                    XCTAssertEqual(deadline1 - deadline2, TimeAmount.nanoseconds(0))
                }
            }
        }
    }

    func testEdgeCasesNIODeadlinePlusTimeAmount() {
        let smallestPossibleTimeAmount = TimeAmount.nanoseconds(.min)
        let largestPossibleTimeAmount = TimeAmount.nanoseconds(.max)
        let zeroTimeAmount = TimeAmount.nanoseconds(0)

        let smallestPossibleDeadline = NIODeadline.uptimeNanoseconds(.min)
        let largestPossibleDeadline = NIODeadline.uptimeNanoseconds(.max)
        let distantFuture = NIODeadline.distantFuture
        let distantPast = NIODeadline.distantPast
        let zeroDeadline = NIODeadline.uptimeNanoseconds(0)
        let nowDeadline = NIODeadline.now()

        for timeAmount in [smallestPossibleTimeAmount, largestPossibleTimeAmount, zeroTimeAmount] {
            for deadline in [smallestPossibleDeadline, largestPossibleDeadline, distantPast, distantFuture,
                             zeroDeadline, nowDeadline] {
                let (partial, overflow) = Int64(deadline.uptimeNanoseconds).addingReportingOverflow(timeAmount.nanoseconds)
                let expectedValue: UInt64
                if overflow {
                    XCTAssertGreaterThanOrEqual(timeAmount.nanoseconds, 0)
                    XCTAssertGreaterThanOrEqual(deadline.uptimeNanoseconds, 0)
                    // we cap at distantFuture torwards +inf
                    expectedValue = NIODeadline.distantFuture.uptimeNanoseconds
                } else if partial < 0 {
                    // we cap at 0 towards -inf
                    expectedValue = 0
                } else {
                    // otherwise we have a result
                    expectedValue = .init(partial)
                }
                XCTAssertEqual((deadline + timeAmount).uptimeNanoseconds, expectedValue)
            }
        }
    }

    func testEdgeCasesNIODeadlineMinusTimeAmount() {
        let smallestPossibleTimeAmount = TimeAmount.nanoseconds(.min)
        let largestPossibleTimeAmount = TimeAmount.nanoseconds(.max)
        let zeroTimeAmount = TimeAmount.nanoseconds(0)

        let smallestPossibleDeadline = NIODeadline.uptimeNanoseconds(.min)
        let largestPossibleDeadline = NIODeadline.uptimeNanoseconds(.max)
        let distantFuture = NIODeadline.distantFuture
        let distantPast = NIODeadline.distantPast
        let zeroDeadline = NIODeadline.uptimeNanoseconds(0)
        let nowDeadline = NIODeadline.now()

        for timeAmount in [smallestPossibleTimeAmount, largestPossibleTimeAmount, zeroTimeAmount] {
            for deadline in [smallestPossibleDeadline, largestPossibleDeadline, distantPast, distantFuture,
                             zeroDeadline, nowDeadline] {
                let (partial, overflow) = Int64(deadline.uptimeNanoseconds).subtractingReportingOverflow(timeAmount.nanoseconds)
                let expectedValue: UInt64
                if overflow {
                    XCTAssertLessThan(timeAmount.nanoseconds, 0)
                    XCTAssertGreaterThanOrEqual(deadline.uptimeNanoseconds, 0)
                    // we cap at distantFuture torwards +inf
                    expectedValue = NIODeadline.distantFuture.uptimeNanoseconds
                } else if partial < 0 {
                    // we cap at 0 towards -inf
                    expectedValue = 0
                } else {
                    // otherwise we have a result
                    expectedValue = .init(partial)
                }
                XCTAssertEqual((deadline - timeAmount).uptimeNanoseconds, expectedValue)
            }
        }
    }
}
