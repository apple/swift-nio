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
import XCTest
@testable import NIOCore
import NIOEmbedded
@testable import NIOPosix
import Atomics
import Dispatch
import NIOConcurrencyHelpers

public final class EventLoopTest : XCTestCase {

    public func testSchedule() throws {
        let eventLoop = EmbeddedEventLoop()

        let scheduled = eventLoop.scheduleTask(in: .seconds(1)) { true }

        var result: Bool?
        scheduled.futureResult.whenSuccess { result = $0 }

        eventLoop.run() // run without time advancing should do nothing
        XCTAssertFalse(scheduled.futureResult.isFulfilled)
        XCTAssertNil(result)

        eventLoop.advanceTime(by: .seconds(1)) // should fire now
        XCTAssertTrue(scheduled.futureResult.isFulfilled)

        XCTAssertNotNil(result)
        XCTAssertTrue(result == true)
    }

    public func testFlatSchedule() throws {
        let eventLoop = EmbeddedEventLoop()

        let scheduled = eventLoop.flatScheduleTask(in: .seconds(1)) {
            eventLoop.makeSucceededFuture(true)
        }

        var result: Bool?
        scheduled.futureResult.whenSuccess { result = $0 }

        eventLoop.run() // run without time advancing should do nothing
        XCTAssertFalse(scheduled.futureResult.isFulfilled)
        XCTAssertNil(result)

        eventLoop.advanceTime(by: .seconds(1)) // should fire now
        XCTAssertTrue(scheduled.futureResult.isFulfilled)

        XCTAssertNotNil(result)
        XCTAssertTrue(result == true)
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
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
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
        let eventLoop = EmbeddedEventLoop()

        let scheduled = eventLoop.scheduleTask(in: .seconds(1)) { true }

        var result: Bool?
        var error: Error?
        scheduled.futureResult.whenSuccess { result = $0 }
        scheduled.futureResult.whenFailure { error = $0 }

        eventLoop.advanceTime(by: .milliseconds(500)) // advance halfway to firing time
        scheduled.cancel()
        eventLoop.advanceTime(by: .milliseconds(500)) // advance the rest of the way

        XCTAssertTrue(scheduled.futureResult.isFulfilled)
        XCTAssertNil(result)
        XCTAssertEqual(error as? EventLoopError, .cancelled)
    }

    public func testFlatScheduleCancelled() throws {
        let eventLoop = EmbeddedEventLoop()

        let scheduled = eventLoop.flatScheduleTask(in: .seconds(1)) {
            eventLoop.makeSucceededFuture(true)
        }

        var result: Bool?
        var error: Error?
        scheduled.futureResult.whenSuccess { result = $0 }
        scheduled.futureResult.whenFailure { error = $0 }

        eventLoop.advanceTime(by: .milliseconds(500)) // advance halfway to firing time
        scheduled.cancel()
        eventLoop.advanceTime(by: .milliseconds(500)) // advance the rest of the way

        XCTAssertTrue(scheduled.futureResult.isFulfilled)
        XCTAssertNil(result)
        XCTAssertEqual(error as? EventLoopError, .cancelled)
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

        let counter = ManagedAtomic<Int>(0)
        let loop = eventLoopGroup.next()
        let allDone = DispatchGroup()
        allDone.enter()
        loop.scheduleRepeatedTask(initialDelay: initialDelay, delay: delay) { repeatedTask -> Void in
            XCTAssertTrue(loop.inEventLoop)
            let initialValue = counter.load(ordering: .relaxed)
            counter.wrappingIncrement(ordering: .relaxed)
            if initialValue == 0 {
                XCTAssertTrue(NIODeadline.now() - nanos >= initialDelay)
            } else if initialValue == count {
                repeatedTask.cancel()
                allDone.leave()
            }
        }

        allDone.wait()

        XCTAssertEqual(counter.load(ordering: .relaxed), count + 1)
        XCTAssertTrue(NIODeadline.now() - nanos >= initialDelay + Int64(count) * delay)
    }

    public func testScheduledTaskThatIsImmediatelyCancelledNeverFires() throws {
        let eventLoop = EmbeddedEventLoop()
        let scheduled = eventLoop.scheduleTask(in: .seconds(1)) { true }

        var result: Bool?
        var error: Error?
        scheduled.futureResult.whenSuccess { result = $0 }
        scheduled.futureResult.whenFailure { error = $0 }

        scheduled.cancel()
        eventLoop.advanceTime(by: .seconds(1))

        XCTAssertTrue(scheduled.futureResult.isFulfilled)
        XCTAssertNil(result)
        XCTAssertEqual(error as? EventLoopError, .cancelled)
    }

    public func testScheduledTasksAreOrdered() throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }

        let eventLoop = eventLoopGroup.next()
        let now = NIODeadline.now()

        var result = [Int]()
        var lastScheduled: Scheduled<Void>?
        for i in 0...100 {
            lastScheduled = eventLoop.scheduleTask(deadline: now) {
                result.append(i)
            }
        }
        try lastScheduled?.futureResult.wait()
        XCTAssertEqual(result, Array(0...100))
    }

    public func testFlatScheduledTaskThatIsImmediatelyCancelledNeverFires() throws {
        let eventLoop = EmbeddedEventLoop()
        let scheduled = eventLoop.flatScheduleTask(in: .seconds(1)) {
            eventLoop.makeSucceededFuture(true)
        }

        var result: Bool?
        var error: Error?
        scheduled.futureResult.whenSuccess { result = $0 }
        scheduled.futureResult.whenFailure { error = $0 }

        scheduled.cancel()
        eventLoop.advanceTime(by: .seconds(1))

        XCTAssertTrue(scheduled.futureResult.isFulfilled)
        XCTAssertNil(result)
        XCTAssertEqual(error as? EventLoopError, .cancelled)
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

        let hasFiredGroup = DispatchGroup()
        let isCancelledGroup = DispatchGroup()
        let loop = eventLoopGroup.next()
        hasFiredGroup.enter()
        isCancelledGroup.enter()
        var isAllowedToFire = true // read/write only on `loop`
        var hasFired = false // read/write only on `loop`
        let repeatedTask = loop.scheduleRepeatedTask(initialDelay: initialDelay, delay: delay) { (_: RepeatedTask) -> Void in
            XCTAssertTrue(loop.inEventLoop)
            if !hasFired {
                // we can only do this once as we can only leave the DispatchGroup once but we might lose a race and
                // the timer might fire more than once (until `shouldNoLongerFire` becomes true).
                hasFired = true
                hasFiredGroup.leave()
            }
            XCTAssertTrue(isAllowedToFire)
        }
        hasFiredGroup.notify(queue: DispatchQueue.global()) {
            repeatedTask.cancel()
            loop.execute {
                // only now do we know that the `cancel` must have gone through
                isAllowedToFire = false
                isCancelledGroup.leave()
            }
        }

        hasFiredGroup.wait()
        XCTAssertTrue(NIODeadline.now() - nanos >= initialDelay)
        isCancelledGroup.wait()
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
        XCTAssertEqual(0, counter)

        // t == 10: once
        eventLoop.advanceTime(by: .milliseconds(5))
        XCTAssertEqual(1, counter)

        // t == 15: still once
        eventLoop.advanceTime(by: .milliseconds(5))
        XCTAssertEqual(1, counter)

        // t == 20: still once (because the task takes 10ms to execute)
        eventLoop.advanceTime(by: .milliseconds(5))
        XCTAssertEqual(1, counter)

        // t == 25: still once (because the task takes 10ms to execute)
        eventLoop.advanceTime(by: .milliseconds(5))
        XCTAssertEqual(1, counter)

        // t == 30: twice
        eventLoop.advanceTime(by: .milliseconds(5))
        XCTAssertEqual(2, counter)

        // t == 40: twice
        eventLoop.advanceTime(by: .milliseconds(10))
        XCTAssertEqual(2, counter)

        // t == 50: three times
        eventLoop.advanceTime(by: .milliseconds(10))
        XCTAssertEqual(3, counter)

        // t == 60: three times
        eventLoop.advanceTime(by: .milliseconds(10))
        XCTAssertEqual(3, counter)

        // t == 89: four times
        eventLoop.advanceTime(by: .milliseconds(29))
        XCTAssertEqual(4, counter)

        // t == 90: five times
        eventLoop.advanceTime(by: .milliseconds(1))
        XCTAssertEqual(5, counter)

        repeatedTask.cancel()

        eventLoop.run()
        XCTAssertEqual(5, counter)

        eventLoop.advanceTime(by: .hours(10))
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
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
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
            XCTAssertThrowsError(try group.syncShutdownGracefully()) { error in
                XCTAssertEqual(.shutdown, error as? EventLoopError)
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
            XCTAssertFalse(serverChannel.isActive)
        }
        let connectPromise = loop.makePromise(of: Void.self)

        // We're going to create and register a channel, but not actually attempt to do anything with it.
        let wedgeHandler = WedgeOpenHandler { promise in
            promiseQueue.sync { promises.append(promise) }
        }
        let channel = try SocketChannel(eventLoop: loop, protocolFamily: .inet)
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

        let g = DispatchGroup()
        let q = DispatchQueue(label: "\(#filePath)/\(#line)")
        g.enter()
        // Now we're going to start closing the event loop. This should not immediately succeed.
        loop.initiateClose(queue: q) { result in
            func workaroundSR9815() {
                XCTAssertNoThrow(try result.get())
            }
            workaroundSR9815()
            g.leave()
        }

        // Now we're going to attempt to register a new channel. This should immediately fail.
        let newChannel = try SocketChannel(eventLoop: loop, protocolFamily: .inet)

        XCTAssertThrowsError(try newChannel.register().wait()) { error in
            XCTAssertEqual(.shutdown, error as? EventLoopError)
        }

        // Confirm that the loop still hasn't closed.
        XCTAssertEqual(.timedOut, g.wait(timeout: .now()))

        // Now let it close.
        promiseQueue.sync {
            promises.forEach { $0.succeed(()) }
        }
        XCTAssertNoThrow(g.wait())
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
        #if os(Linux) || os(Android)
            let target = NIOThread.current.affinity.cpuIds.first!
            let body: ThreadInitializer = { t in
                let set = LinuxCPUSet(target)
                t.affinity = set
                XCTAssertEqual(set, t.affinity)
            }
            let threads: [ThreadInitializer] = [body, body]

            let group = MultiThreadedEventLoopGroup(threadInitializers: threads)

            XCTAssertNoThrow(try group.syncShutdownGracefully())
        #endif
    }

    public func testEventLoopPinnedCPUIdsConstructor() throws {
        #if os(Linux) || os(Android)
            let target = NIOThread.current.affinity.cpuIds.first!
            let group = MultiThreadedEventLoopGroup(pinnedCPUIds: [target])
            let eventLoop = group.next()
            let set = try eventLoop.submit {
                NIOThread.current.affinity
            }.wait()

            XCTAssertEqual(LinuxCPUSet(target), set)
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

            let groupIsShutdown = ManagedAtomic(false)
            let removed = ManagedAtomic(false)

            public func handlerRemoved(context: ChannelHandlerContext) {
                XCTAssertFalse(groupIsShutdown.load(ordering: .relaxed))
                XCTAssertTrue(removed.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged)
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let assertHandler = AssertHandler()
        let serverSocket = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .bind(host: "localhost", port: 0).wait())
        let channel = try assertNoThrowWithValue(SocketChannel(eventLoop: eventLoop as! SelectableEventLoop,
                                                               protocolFamily: serverSocket.localAddress!.protocol))
        XCTAssertNoThrow(try channel.pipeline.addHandler(assertHandler).wait() as Void)
        XCTAssertNoThrow(try channel.eventLoop.flatSubmit {
            channel.register().flatMap {
                channel.connect(to: serverSocket.localAddress!)
            }
        }.wait() as Void)
        let closeFutureFulfilledEventually = ManagedAtomic(false)
        XCTAssertFalse(channel.closeFuture.isFulfilled)
        channel.closeFuture.whenSuccess {
            XCTAssertTrue(closeFutureFulfilledEventually.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged)
        }
        XCTAssertNoThrow(try group.syncShutdownGracefully())
        XCTAssertTrue(assertHandler.groupIsShutdown.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged)
        XCTAssertTrue(assertHandler.removed.load(ordering: .relaxed))
        XCTAssertFalse(channel.isActive)
        XCTAssertTrue(closeFutureFulfilledEventually.load(ordering: .relaxed))
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
        XCTAssertEqual(XCTWaiter.wait(for: [expectRuns], timeout: 0.1), .completed)
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

    func testCancelledScheduledTasksDoNotHoldOnToRunClosure() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        class Thing: @unchecked Sendable {
            private let deallocated: ConditionLock<Int>

            init(_ deallocated: ConditionLock<Int>) {
                self.deallocated = deallocated
            }

            deinit {
                self.deallocated.lock()
                self.deallocated.unlock(withValue: 1)
            }
        }

        func make(deallocated: ConditionLock<Int>) -> Scheduled<Never> {
            let aThing = Thing(deallocated)
            return group.next().scheduleTask(in: .hours(1)) {
                preconditionFailure("this should definitely not run: \(aThing)")
            }
        }

        let deallocated = ConditionLock(value: 0)
        let scheduled = make(deallocated: deallocated)
        scheduled.cancel()
        if deallocated.lock(whenValue: 1, timeoutSeconds: 60) {
            deallocated.unlock()
        } else {
            XCTFail("Timed out waiting for lock")
        }
        XCTAssertThrowsError(try scheduled.futureResult.wait()) { error in
            XCTAssertEqual(EventLoopError.cancelled, error as? EventLoopError)
        }
    }

    func testCancelledScheduledTasksDoNotHoldOnToRunClosureEvenIfTheyWereTheNextTaskToExecute() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        class Thing {
            private let deallocated: ConditionLock<Int>

            init(_ deallocated: ConditionLock<Int>) {
                self.deallocated = deallocated
            }

            deinit {
                self.deallocated.lock()
                self.deallocated.unlock(withValue: 1)
            }
        }

        func make(deallocated: ConditionLock<Int>) -> Scheduled<Never> {
            let aThing = Thing(deallocated)
            return group.next().scheduleTask(in: .hours(1)) {
                preconditionFailure("this should definitely not run: \(aThing)")
            }
        }

        // What the heck are we doing here?
        //
        // Our goal is to arrange for our scheduled task to become "nextReadyTask" in SelectableEventLoop, so that
        // when we cancel it there is still a copy aliasing it. This reproduces a subtle correctness bug that
        // existed in NIO 2.48.0 and earlier.
        //
        // This will happen if:
        //
        // 1. We schedule a task for the future
        // 2. The event loop begins a tick.
        // 3. The event loop finds our scheduled task in the future.
        //
        // We can make that happen by scheduling our task and then waiting for a tick to pass, which we can
        // achieve using `submit`.
        //
        // However, if there are no _other_, _even later_ tasks, we'll free the reference. This is
        // because the nextReadyTask is cleared if the list of scheduled tasks ends up empty, so we don't want that to happen.
        //
        // So the order of operations is:
        //
        // 1. Schedule the task for the future.
        // 2. Schedule another, even later, task.
        // 3. Wait for a tick to pass.
        // 4. Cancel our scheduled.
        //
        // In the correct code, this should invoke deinit. In the buggy code, it does not.
        //
        // Unfortunately, this window is very hard to hit. Cancelling the scheduled task wakes the loop up, and if it is
        // still awake by the time we run the cancellation handler it'll notice the change. So we have to tolerate
        // a somewhat flaky test.
        let deallocated = ConditionLock(value: 0)
        let scheduled = make(deallocated: deallocated)
        scheduled.futureResult.eventLoop.scheduleTask(in: .hours(2)) { }
        try! scheduled.futureResult.eventLoop.submit { }.wait()
        scheduled.cancel()
        if deallocated.lock(whenValue: 1, timeoutSeconds: 60) {
            deallocated.unlock()
        } else {
            XCTFail("Timed out waiting for lock")
        }
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
                    // we cap at distantFuture towards +inf
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
                    // we cap at distantFuture towards +inf
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

    func testSuccessfulFlatSubmit() {
        let eventLoop = EmbeddedEventLoop()
        let future = eventLoop.flatSubmit {
            eventLoop.makeSucceededFuture(1)
        }
        eventLoop.run()
        XCTAssertNoThrow(XCTAssertEqual(1, try future.wait()))
    }

    func testFailingFlatSubmit() {
        enum TestError: Error { case failed }

        let eventLoop = EmbeddedEventLoop()
        let future = eventLoop.flatSubmit { () -> EventLoopFuture<Int> in
            eventLoop.makeFailedFuture(TestError.failed)
        }
        eventLoop.run()
        XCTAssertThrowsError(try future.wait()) { error in
            XCTAssertEqual(.failed, error as? TestError)
        }
    }

    func testSchedulingTaskOnTheEventLoopWithinTheEventLoopsOnlyTask() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }

        let el = elg.next()
        let g = DispatchGroup()
        g.enter()
        el.execute {
            // We're the last and only task running, scheduling another task here makes sure that despite not waking
            // up the selector, we will still run this task.
            el.execute {
                g.leave()
            }
        }
        g.wait()
    }

    func testSchedulingTaskOnTheEventLoopWithinTheEventLoopsOnlyIOOperation() {
        final class ExecuteSomethingOnEventLoop: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            static let numberOfInstances = ManagedAtomic<Int>(0)
            let groupToNotify: DispatchGroup

            init(groupToNotify: DispatchGroup) {
                XCTAssertEqual(0, ExecuteSomethingOnEventLoop.numberOfInstances.loadThenWrappingIncrement(ordering: .relaxed))
                self.groupToNotify = groupToNotify
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                context.eventLoop.execute {
                    self.groupToNotify.leave()
                }
            }
        }

        let elg1 = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let elg2 = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try elg1.syncShutdownGracefully())
            XCTAssertNoThrow(try elg2.syncShutdownGracefully())
        }

        let g = DispatchGroup()
        g.enter()
        var maybeServer: Channel?
        XCTAssertNoThrow(maybeServer = try ServerBootstrap(group: elg2)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .serverChannelOption(ChannelOptions.autoRead, value: false)
            .serverChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ExecuteSomethingOnEventLoop(groupToNotify: g))
            }
            .bind(to: .init(ipAddress: "127.0.0.1", port: 0))
            .wait())
        maybeServer?.read() // this should accept one client

        var maybeClient: Channel?
        XCTAssertNoThrow(maybeClient = try ClientBootstrap(group: elg1)
            .connect(to: maybeServer?.localAddress ?? SocketAddress(unixDomainSocketPath: "/dev/null/does/not/exist"))
            .wait())

        guard let client = maybeClient else {
            XCTFail("couldn't connect")
            return
        }

        var buffer = client.allocator.buffer(capacity: 1)
        buffer.writeString("X")

        // Now let's trigger a channelRead in the accepted channel which should schedule running an EventLoop task
        // with no outstanding operations on the EventLoop (no IO, nor tasks left to do).
        XCTAssertNoThrow(try client.writeAndFlush(buffer).wait())

        // The executed task should've notified this DispatchGroup
        g.wait()
    }

    func testCancellingTheLastOutstandingTask() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }

        let el = elg.next()
        let task = el.scheduleTask(in: .milliseconds(10)) {}
        task.cancel()
        // sleep for 10ms which should have the above scheduled (and cancelled) task have caused an unnecessary wakeup.
        Thread.sleep(forTimeInterval: 0.015 /* 15 ms */)
    }

    func testSchedulingTaskOnTheEventLoopWithinTheEventLoopsOnlyScheduledTask() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }

        let el = elg.next()
        let g = DispatchGroup()
        g.enter()
        el.scheduleTask(in: .nanoseconds(10) /* something non-0 */) {
            el.execute {
                g.leave()
            }
        }
        g.wait()
    }

    func testSelectableEventLoopDescription() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }

        let el: EventLoop = elg.next()
        let expectedPrefix = "SelectableEventLoop { selector = Selector { descriptor ="
        let expectedContains = "thread = NIOThread(name = NIO-ELT-"
        let expectedSuffix = " }"
        let desc = el.description
        XCTAssert(el.description.starts(with: expectedPrefix), desc)
        XCTAssert(el.description.reversed().starts(with: expectedSuffix.reversed()), desc)
        // let's check if any substring contains the `expectedContains`
        XCTAssert(desc.indices.contains { startIndex in
            desc[startIndex...].starts(with: expectedContains)
        }, desc)
    }

    func testMultiThreadedEventLoopGroupDescription() {
        let elg: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }

        XCTAssert(elg.description.starts(with: "MultiThreadedEventLoopGroup { threadPattern = NIO-ELT-"),
                  elg.description)
    }

    func testSafeToExecuteTrue() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }
        let loop = elg.next() as! SelectableEventLoop
        XCTAssertTrue(loop.testsOnly_validExternalStateToScheduleTasks)
        XCTAssertTrue(loop.testsOnly_validExternalStateToScheduleTasks)
    }

    func testSafeToExecuteFalse() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = elg.next() as! SelectableEventLoop
        try? elg.syncShutdownGracefully()
        XCTAssertFalse(loop.testsOnly_validExternalStateToScheduleTasks)
        XCTAssertFalse(loop.testsOnly_validExternalStateToScheduleTasks)
    }

    func testTakeOverThreadAndAlsoTakeItBack() {
        let currentNIOThread = NIOThread.current
        let currentNSThread = Thread.current
        let lock = NIOLock()
        var hasBeenShutdown = false
        let allDoneGroup = DispatchGroup()
        allDoneGroup.enter()
        MultiThreadedEventLoopGroup.withCurrentThreadAsEventLoop { loop in
            XCTAssertEqual(currentNIOThread, NIOThread.current)
            XCTAssertEqual(currentNSThread, Thread.current)
            XCTAssert(loop === MultiThreadedEventLoopGroup.currentEventLoop)
            loop.shutdownGracefully(queue: DispatchQueue.global()) { error in
                XCTAssertNil(error)
                lock.withLock {
                    hasBeenShutdown = error == nil
                }
                allDoneGroup.leave()
            }
        }
        allDoneGroup.wait()
        XCTAssertTrue(lock.withLock { hasBeenShutdown })
    }

    func testThreadTakeoverUnsetsCurrentEventLoop() {
        XCTAssertNil(MultiThreadedEventLoopGroup.currentEventLoop)

        MultiThreadedEventLoopGroup.withCurrentThreadAsEventLoop { el in
            XCTAssert(el === MultiThreadedEventLoopGroup.currentEventLoop)
            el.shutdownGracefully { error in
                XCTAssertNil(error)
            }
        }

        XCTAssertNil(MultiThreadedEventLoopGroup.currentEventLoop)
    }

    func testWeCanDoTrulySingleThreadedNetworking() {
        final class SaveReceivedByte: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            // For once, we don't need thread-safety as we're taking the calling thread :)
            var received: UInt8? = nil
            var readCalls: Int = 0
            var allDonePromise: EventLoopPromise<Void>? = nil

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                self.readCalls += 1
                XCTAssertEqual(1, self.readCalls)

                var data = self.unwrapInboundIn(data)
                XCTAssertEqual(1, data.readableBytes)

                XCTAssertNil(self.received)
                self.received = data.readInteger()

                self.allDonePromise?.succeed(())

                context.close(promise: nil)
            }
        }

        let receiveHandler = SaveReceivedByte() // There'll be just one connection, we can share.
        MultiThreadedEventLoopGroup.withCurrentThreadAsEventLoop { loop in
            ServerBootstrap(group: loop)
                .serverChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
                .childChannelInitializer { accepted in
                    accepted.pipeline.addHandler(receiveHandler)
                }
                .bind(host: "127.0.0.1", port: 0)
                .flatMap { serverChannel in
                    ClientBootstrap(group: loop).connect(to: serverChannel.localAddress!).flatMap { clientChannel in
                        var buffer = clientChannel.allocator.buffer(capacity: 1)
                        buffer.writeString("J")
                        return clientChannel.writeAndFlush(buffer)
                    }.flatMap {
                        XCTAssertNil(receiveHandler.allDonePromise)
                        receiveHandler.allDonePromise = loop.makePromise()
                        return receiveHandler.allDonePromise!.futureResult
                    }.flatMap {
                        serverChannel.close()
                    }
                }.whenComplete { (result: Result<Void, Error>) -> Void in
                    func workaroundSR9815withAUselessFunction() {
                        XCTAssertNoThrow(try result.get())
                    }
                    workaroundSR9815withAUselessFunction()

                    // All done, let's return back into the calling thread.
                    loop.shutdownGracefully { error in
                        XCTAssertNil(error)
                    }
                }
        }

        // All done, the EventLoop is terminated so we should be able to check the results.
        XCTAssertEqual(UInt8(ascii: "J"), receiveHandler.received)
    }

    func testWeFailOutstandingScheduledTasksOnELShutdown() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let scheduledTask = group.next().scheduleTask(in: .hours(24)) {
            XCTFail("We lost the 24 hour race and aren't even in Le Mans.")
        }
        let waiter = DispatchGroup()
        waiter.enter()
        scheduledTask.futureResult.map {
            XCTFail("didn't expect success")
        }.whenFailure { error in
            XCTAssertEqual(.shutdown, error as? EventLoopError)
            waiter.leave()
        }

        XCTAssertNoThrow(try group.syncShutdownGracefully())
        waiter.wait()
    }

    func testSchedulingTaskOnFutureFailedByELShutdownDoesNotMakeUsExplode() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let scheduledTask = group.next().scheduleTask(in: .hours(24)) {
            XCTFail("Task was scheduled in 24 hours, yet it executed.")
        }
        let waiter = DispatchGroup()
        waiter.enter() // first scheduled task
        waiter.enter() // scheduled task in the first task's whenFailure.
        scheduledTask.futureResult.map {
            XCTFail("didn't expect success")
        }.whenFailure { error in
            XCTAssertEqual(.shutdown, error as? EventLoopError)
            group.next().execute {} // This previously blew up
            group.next().scheduleTask(in: .hours(24)) {
                XCTFail("Task was scheduled in 24 hours, yet it executed.")
            }.futureResult.map {
                XCTFail("didn't expect success")
            }.whenFailure { error in
                XCTAssertEqual(.shutdown, error as? EventLoopError)
                waiter.leave()
            }
            waiter.leave()
        }

        XCTAssertNoThrow(try group.syncShutdownGracefully())
        waiter.wait()
    }

    func testEventLoopGroupProvider() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully())
        }

        let provider = NIOEventLoopGroupProvider.shared(eventLoopGroup)

        if case .shared(let sharedEventLoopGroup) = provider {
            XCTAssertTrue(sharedEventLoopGroup is MultiThreadedEventLoopGroup)
            XCTAssertTrue(sharedEventLoopGroup === eventLoopGroup)
        } else {
            XCTFail("Not the same")
        }
    }

    // Test that scheduling a task at the maximum value doesn't crash.
    // (Crashing resulted from an EINVAL/IOException thrown by the kevent
    // syscall when the timeout value exceeded the maximum supported by
    // the Darwin kernel #1056).
    public func testScheduleMaximum() {
        let eventLoop = EmbeddedEventLoop()
        let maxAmount: TimeAmount = .nanoseconds(.max)
        let scheduled = eventLoop.scheduleTask(in: maxAmount) { true }

        var result: Bool?
        var error: Error?
        scheduled.futureResult.whenSuccess { result = $0 }
        scheduled.futureResult.whenFailure { error = $0 }

        scheduled.cancel()

        XCTAssertTrue(scheduled.futureResult.isFulfilled)
        XCTAssertNil(result)
        XCTAssertEqual(error as? EventLoopError, .cancelled)
    }

    func testEventLoopsWithPreSucceededFuturesCacheThem() {
        let el = EventLoopWithPreSucceededFuture()
        defer {
            XCTAssertNoThrow(try el.syncShutdownGracefully())
        }

        let future1 = el.makeSucceededFuture(())
        let future2 = el.makeSucceededFuture(())
        let future3 = el.makeSucceededVoidFuture()

        XCTAssert(future1 === future2)
        XCTAssert(future2 === future3)
    }

    func testEventLoopsWithoutPreSucceededFuturesDoNotCacheThem() {
        let el = EventLoopWithoutPreSucceededFuture()
        defer {
            XCTAssertNoThrow(try el.syncShutdownGracefully())
        }

        let future1 = el.makeSucceededFuture(())
        let future2 = el.makeSucceededFuture(())
        let future3 = el.makeSucceededVoidFuture()

        XCTAssert(future1 !== future2)
        XCTAssert(future2 !== future3)
        XCTAssert(future1 !== future3)
    }

    func testSelectableEventLoopHasPreSucceededFuturesOnlyOnTheEventLoop() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }

        let el = elg.next()

        let futureOutside1 = el.makeSucceededVoidFuture()
        let futureOutside2 = el.makeSucceededFuture(())
        XCTAssert(futureOutside1 !== futureOutside2)

        XCTAssertNoThrow(try el.submit {
            let futureInside1 = el.makeSucceededVoidFuture()
            let futureInside2 = el.makeSucceededFuture(())

            XCTAssert(futureOutside1 !== futureInside1)
            XCTAssert(futureInside1 === futureInside2)
        }.wait())
    }

    func testMakeCompletedFuture() {
        let eventLoop = EmbeddedEventLoop()
        defer {
            XCTAssertNoThrow(try eventLoop.syncShutdownGracefully())
        }

        XCTAssertEqual(try eventLoop.makeCompletedFuture(.success("foo")).wait(), "foo")

        struct DummyError: Error {}
        let future = eventLoop.makeCompletedFuture(Result<String, Error>.failure(DummyError()))
        XCTAssertThrowsError(try future.wait()) { error in
            XCTAssertTrue(error is DummyError)
        }
    }

    func testMakeCompletedFutureWithResultOf() {
        let eventLoop = EmbeddedEventLoop()
        defer {
            XCTAssertNoThrow(try eventLoop.syncShutdownGracefully())
        }

        XCTAssertEqual(try eventLoop.makeCompletedFuture(withResultOf: { "foo" }).wait(), "foo")

        struct DummyError: Error {}
        func throwError() throws {
            throw DummyError()
        }

        let future = eventLoop.makeCompletedFuture(withResultOf: throwError)
        XCTAssertThrowsError(try future.wait()) { error in
            XCTAssertTrue(error is DummyError)
        }
    }

    func testMakeCompletedVoidFuture() {
        let eventLoop = EventLoopWithPreSucceededFuture()
        defer {
            XCTAssertNoThrow(try eventLoop.syncShutdownGracefully())
        }

        let future1 = eventLoop.makeCompletedFuture(.success(()))
        let future2 = eventLoop.makeSucceededVoidFuture()
        let future3 = eventLoop.makeSucceededFuture(())
        XCTAssert(future1 === future2)
        XCTAssert(future2 === future3)
    }

    func testEventLoopGroupsWithoutAnyImplementationAreValid() {
        let group = EventLoopGroupOf3WithoutAnAnyImplementation()
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let submitDone = group.any().submit {
            let el1 = group.any()
            let el2 = group.any()
            XCTAssert(el1 !== el2) // our group doesn't support `any()` and will fall back to `next()`.
        }
        group.makeIterator().forEach { el in
            (el as! EmbeddedEventLoop).run()
        }
        XCTAssertNoThrow(try submitDone.wait())
    }

    func testCallingAnyOnAnMTELGThatIsNotSelfDoesNotReturnItself() {
        let group1 = MultiThreadedEventLoopGroup(numberOfThreads: 3)
        let group2 = MultiThreadedEventLoopGroup(numberOfThreads: 3)
        defer {
            XCTAssertNoThrow(try group2.syncShutdownGracefully())
            XCTAssertNoThrow(try group1.syncShutdownGracefully())
        }

        XCTAssertNoThrow(try group1.any().submit {
            let el1_1 = group1.any()
            let el1_2 = group1.any()
            let el2_1 = group2.any()
            let el2_2 = group2.any()

            XCTAssert(el1_1 === el1_2) // MTELG _does_ supprt `any()` so all these `EventLoop`s should be the same.
            XCTAssert(el2_1 !== el2_2) // MTELG _does_ supprt `any()` but this `any()` call went across `group`s.
            XCTAssert(el1_1 !== el2_1) // different groups...
            XCTAssert(el1_1 !== el2_2) // different groups...

            XCTAssert(el1_1 === MultiThreadedEventLoopGroup.currentEventLoop!)
        }.wait())
    }

    func testMultiThreadedEventLoopGroupSupportsStickyAnyImplementation() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 3)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        XCTAssertNoThrow(try group.any().submit {
            let el1 = group.any()
            let el2 = group.any()
            XCTAssert(el1 === el2) // MTELG _does_ supprt `any()` so all these `EventLoop`s should be the same.
            XCTAssert(el1 === MultiThreadedEventLoopGroup.currentEventLoop!)
        }.wait())
    }

    func testAsyncToFutureConversionSuccess() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        XCTAssertEqual("hello from async",
                       try group.next().makeFutureWithTask {
            try await Task.sleep(nanoseconds: 37)
            return "hello from async"
        }.wait())
    }

    func testAsyncToFutureConversionFailure() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        struct DummyError: Error {}

        XCTAssertThrowsError(try group.next().makeFutureWithTask {
            try await Task.sleep(nanoseconds: 37)
            throw DummyError()
        }.wait()) { error in
            XCTAssert(error is DummyError)
        }
    }
}

fileprivate class EventLoopWithPreSucceededFuture: EventLoop {
    var inEventLoop: Bool {
        return true
    }

    func execute(_ task: @escaping () -> Void) {
        preconditionFailure("not implemented")
    }

    func submit<T>(_ task: @escaping () throws -> T) -> EventLoopFuture<T> {
        preconditionFailure("not implemented")
    }

    @discardableResult
    func scheduleTask<T>(deadline: NIODeadline, _ task: @escaping () throws -> T) -> Scheduled<T> {
        preconditionFailure("not implemented")
    }

    @discardableResult
    func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws -> T) -> Scheduled<T> {
        preconditionFailure("not implemented")
    }

    func preconditionInEventLoop(file: StaticString, line: UInt) {
        preconditionFailure("not implemented")
    }

    func preconditionNotInEventLoop(file: StaticString, line: UInt) {
        preconditionFailure("not implemented")
    }

    var _succeededVoidFuture: EventLoopFuture<Void>?
    func makeSucceededVoidFuture() -> EventLoopFuture<Void> {
        guard self.inEventLoop, let voidFuture = self._succeededVoidFuture else {
            return self.makeSucceededFuture(())
        }
        return voidFuture
    }

    init() {
        self._succeededVoidFuture = EventLoopFuture(eventLoop: self, value: ())
    }

    func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        self._succeededVoidFuture = nil
        queue.async {
            callback(nil)
        }
    }
}

fileprivate class EventLoopWithoutPreSucceededFuture: EventLoop {
    var inEventLoop: Bool {
        return true
    }

    func execute(_ task: @escaping () -> Void) {
        preconditionFailure("not implemented")
    }

    func submit<T>(_ task: @escaping () throws -> T) -> EventLoopFuture<T> {
        preconditionFailure("not implemented")
    }

    @discardableResult
    func scheduleTask<T>(deadline: NIODeadline, _ task: @escaping () throws -> T) -> Scheduled<T> {
        preconditionFailure("not implemented")
    }

    @discardableResult
    func scheduleTask<T>(in: TimeAmount, _ task: @escaping () throws -> T) -> Scheduled<T> {
        preconditionFailure("not implemented")
    }

    func preconditionInEventLoop(file: StaticString, line: UInt) {
        preconditionFailure("not implemented")
    }

    func preconditionNotInEventLoop(file: StaticString, line: UInt) {
        preconditionFailure("not implemented")
    }

    func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        queue.async {
            callback(nil)
        }
    }
}

final class EventLoopGroupOf3WithoutAnAnyImplementation: EventLoopGroup {
    private let eventloops = [EmbeddedEventLoop(), EmbeddedEventLoop(), EmbeddedEventLoop()]
    private let nextID = ManagedAtomic<UInt64>(0)

    func next() -> EventLoop {
        return self.eventloops[Int(self.nextID.loadThenWrappingIncrement(ordering: .relaxed) % UInt64(self.eventloops.count))]
    }

    func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        let g = DispatchGroup()


        self.eventloops.forEach { el in
            g.enter()
            el.shutdownGracefully(queue: queue) { error in
                XCTAssertNil(error)
                g.leave()
            }
        }

        g.notify(queue: queue) {
            callback(nil)
        }
    }

    func makeIterator() -> EventLoopIterator {
        return .init(self.eventloops)
    }
}
