//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics
import Dispatch
import Foundation
import NIOConcurrencyHelpers
import NIOEmbedded
import Testing

@testable import NIOCore
@testable import NIOPosix

@Suite("MultiThreadedEventLoopGroupTests", .serialized, .timeLimit(.minutes(1)))
final class MultiThreadedEventLoopGroupTests {
    @Test
    func testSchedule() throws {
        let eventLoop = EmbeddedEventLoop()

        let scheduled = eventLoop.scheduleTask(in: .seconds(1)) { true }

        var result: Bool?
        scheduled.futureResult.assumeIsolated().whenSuccess { result = $0 }
        eventLoop.run()  // run without time advancing should do nothing
        #expect(scheduled.futureResult.isFulfilled == false)
        #expect(result == nil)

        eventLoop.advanceTime(by: .seconds(1))  // should fire now

        #expect(scheduled.futureResult.isFulfilled)
        #expect(result != nil)
        #expect(result == true)
    }

    @Test
    func testFlatSchedule() throws {
        let eventLoop = EmbeddedEventLoop()

        let scheduled = eventLoop.flatScheduleTask(in: .seconds(1)) {
            eventLoop.makeSucceededFuture(true)
        }

        var result: Bool?
        scheduled.futureResult.assumeIsolated().whenSuccess { result = $0 }

        eventLoop.run()  // run without time advancing should do nothing
        #expect(scheduled.futureResult.isFulfilled == false)
        #expect(result == nil)

        eventLoop.advanceTime(by: .seconds(1))  // should fire now
        #expect(scheduled.futureResult.isFulfilled)

        #expect(result != nil)
        #expect(result == true)
    }

    func testScheduleWithDelay() throws {
        let smallAmount: TimeAmount = .milliseconds(100)
        let longAmount: TimeAmount = .seconds(1)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        // First, we create a server and client channel, but don't connect them.
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: eventLoopGroup)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: 0).wait()
        )
        let clientBootstrap = ClientBootstrap(group: eventLoopGroup)

        // Now, schedule two tasks: one that takes a while, one that doesn't.
        let nanos: NIODeadline = .now()
        let longFuture = eventLoopGroup.next().scheduleTask(in: longAmount) {
            true
        }.futureResult

        #expect(
            try assertNoThrowWithValue(
                try eventLoopGroup.next().scheduleTask(in: smallAmount) {
                    true
                }.futureResult.wait()
            )
        )

        // Ok, the short one has happened. Now we should try connecting them. This connect should happen
        // faster than the final task firing.
        _ = try assertNoThrowWithValue(clientBootstrap.connect(to: serverChannel.localAddress!).wait()) as Channel
        #expect((NIODeadline.now() - nanos < longAmount))

        // Now wait for the long-delayed task.
        #expect(try assertNoThrowWithValue(try longFuture.wait()))
        // Now we're ok.
        #expect((NIODeadline.now() - nanos >= longAmount))
    }

    @Test
    func testScheduleCancelled() throws {
        let eventLoop = EmbeddedEventLoop()

        let scheduled = eventLoop.scheduleTask(in: .seconds(1)) { true }

        var result: Bool?
        var error: Error?
        scheduled.futureResult.assumeIsolated().whenSuccess { result = $0 }
        scheduled.futureResult.assumeIsolated().whenFailure { error = $0 }

        eventLoop.advanceTime(by: .milliseconds(500))  // advance halfway to firing time
        scheduled.cancel()
        eventLoop.advanceTime(by: .milliseconds(500))  // advance the rest of the way

        #expect(scheduled.futureResult.isFulfilled)
        #expect(result == nil)
        #expect(error as? EventLoopError == .cancelled)
    }

    @Test
    func testFlatScheduleCancelled() throws {
        let eventLoop = EmbeddedEventLoop()

        let scheduled = eventLoop.flatScheduleTask(in: .seconds(1)) {
            eventLoop.makeSucceededFuture(true)
        }

        var result: Bool?
        var error: Error?
        scheduled.futureResult.assumeIsolated().whenSuccess { result = $0 }
        scheduled.futureResult.assumeIsolated().whenFailure { error = $0 }

        eventLoop.advanceTime(by: .milliseconds(500))  // advance halfway to firing time
        scheduled.cancel()
        eventLoop.advanceTime(by: .milliseconds(500))  // advance the rest of the way

        #expect(scheduled.futureResult.isFulfilled)
        #expect(result == nil)
        #expect(error as? EventLoopError == .cancelled)
    }

    @Test
    func testScheduleRepeatedTask() throws {
        let nanos: NIODeadline = .now()
        let initialDelay: TimeAmount = .milliseconds(5)
        let delay: TimeAmount = .milliseconds(10)
        let count = 5
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        let counter = ManagedAtomic<Int>(0)
        let loop = eventLoopGroup.next()
        let allDone = DispatchGroup()
        allDone.enter()
        loop.scheduleRepeatedTask(initialDelay: initialDelay, delay: delay) { repeatedTask -> Void in
            #expect(loop.inEventLoop)
            let initialValue = counter.load(ordering: .relaxed)
            counter.wrappingIncrement(ordering: .relaxed)
            if initialValue == 0 {
                #expect(NIODeadline.now() - nanos >= initialDelay)
            } else if initialValue == count {
                repeatedTask.cancel()
                allDone.leave()
            }
        }

        allDone.wait()

        #expect(counter.load(ordering: .relaxed) == count + 1)
        #expect(NIODeadline.now() - nanos >= initialDelay + Int64(count) * delay)
    }

    @Test
    func testScheduledTaskThatIsImmediatelyCancelledNeverFires() throws {
        let eventLoop = EmbeddedEventLoop()
        let scheduled = eventLoop.scheduleTask(in: .seconds(1)) { true }

        var result: Bool?
        var error: Error?
        scheduled.futureResult.assumeIsolated().whenSuccess { result = $0 }
        scheduled.futureResult.assumeIsolated().whenFailure { error = $0 }

        scheduled.cancel()
        eventLoop.advanceTime(by: .seconds(1))

        #expect(scheduled.futureResult.isFulfilled)
        #expect(result == nil)
        #expect(error as? EventLoopError == .cancelled)
    }

    @Test
    func testScheduledTasksAreOrdered() throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        let eventLoop = eventLoopGroup.next()
        let now = NIODeadline.now()

        let result = NIOLockedValueBox([Int]())
        var lastScheduled: Scheduled<Void>?
        for i in 0...100 {
            lastScheduled = eventLoop.scheduleTask(deadline: now) {
                result.withLockedValue { $0.append(i) }
            }
        }
        try lastScheduled?.futureResult.wait()
        #expect(result.withLockedValue { $0 } == Array(0...100))
    }

    @Test
    func testFlatScheduledTaskThatIsImmediatelyCancelledNeverFires() throws {
        let eventLoop = EmbeddedEventLoop()
        let scheduled = eventLoop.flatScheduleTask(in: .seconds(1)) {
            eventLoop.makeSucceededFuture(true)
        }

        var result: Bool?
        var error: Error?
        scheduled.futureResult.assumeIsolated().whenSuccess { result = $0 }
        scheduled.futureResult.assumeIsolated().whenFailure { error = $0 }

        scheduled.cancel()
        eventLoop.advanceTime(by: .seconds(1))

        #expect(scheduled.futureResult.isFulfilled)
        #expect(result == nil)
        #expect(error as? EventLoopError == .cancelled)
    }

    @Test
    func testRepeatedTaskThatIsImmediatelyCancelledNeverFires() throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        let loop = eventLoopGroup.next()
        loop.execute {
            let task = loop.scheduleRepeatedTask(initialDelay: .milliseconds(0), delay: .milliseconds(0)) { task in
                Issue.record()
            }
            task.cancel()
        }
        Thread.sleep(until: .init(timeIntervalSinceNow: 0.1))
    }

    @Test
    func testScheduleRepeatedTaskCancelFromDifferentThread() throws {
        let nanos: NIODeadline = .now()
        let initialDelay: TimeAmount = .milliseconds(5)
        // this will actually force the race from issue #554 to happen frequently
        let delay: TimeAmount = .milliseconds(0)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        let hasFiredGroup = DispatchGroup()
        let isCancelledGroup = DispatchGroup()
        let loop = eventLoopGroup.next()
        hasFiredGroup.enter()
        isCancelledGroup.enter()

        let (isAllowedToFire, hasFired) = try! loop.submit {
            let isAllowedToFire = NIOLoopBoundBox(true, eventLoop: loop)
            let hasFired = NIOLoopBoundBox(false, eventLoop: loop)
            return (isAllowedToFire, hasFired)
        }.wait()

        let repeatedTask = loop.scheduleRepeatedTask(initialDelay: initialDelay, delay: delay) {
            (_: RepeatedTask) -> Void in
            #expect(loop.inEventLoop)
            if !hasFired.value {
                // we can only do this once as we can only leave the DispatchGroup once but we might lose a race and
                // the timer might fire more than once (until `shouldNoLongerFire` becomes true).
                hasFired.value = true
                hasFiredGroup.leave()
            }
            #expect(isAllowedToFire.value)
        }
        hasFiredGroup.notify(queue: DispatchQueue.global()) {
            repeatedTask.cancel()
            loop.execute {
                // only now do we know that the `cancel` must have gone through
                isAllowedToFire.value = false
                isCancelledGroup.leave()
            }
        }

        hasFiredGroup.wait()
        #expect(NIODeadline.now() - nanos >= initialDelay)
        isCancelledGroup.wait()
    }

    @Test
    func testScheduleRepeatedTaskToNotRetainRepeatedTask() throws {
        let initialDelay: TimeAmount = .milliseconds(5)
        let delay: TimeAmount = .milliseconds(10)
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        weak var weakRepeated: RepeatedTask?
        do {
            let repeated = eventLoopGroup.next().scheduleRepeatedTask(
                initialDelay: initialDelay,
                delay: delay
            ) {
                (_: RepeatedTask) -> Void in
            }
            weakRepeated = repeated
            #expect(weakRepeated != nil)
            repeated.cancel()
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }
        assert(weakRepeated == nil, within: .seconds(1))
    }

    @Test
    func testScheduleRepeatedTaskToNotRetainEventLoop() throws {
        weak var weakEventLoop: EventLoop? = nil
        do {
            let initialDelay: TimeAmount = .milliseconds(5)
            let delay: TimeAmount = .milliseconds(10)
            let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            weakEventLoop = eventLoopGroup.next()
            #expect(weakEventLoop != nil)

            eventLoopGroup.next().scheduleRepeatedTask(initialDelay: initialDelay, delay: delay) {
                (_: RepeatedTask) -> Void in
            }

            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }
        assert(weakEventLoop == nil, within: .seconds(1))
    }

    @Test
    func testScheduledRepeatedAsyncTask() throws {
        let eventLoop = EmbeddedEventLoop()
        let counter = NIOLoopBoundBox(0, eventLoop: eventLoop)

        let repeatedTask = eventLoop.scheduleRepeatedAsyncTask(
            initialDelay: .milliseconds(10),
            delay: .milliseconds(10)
        ) { (_: RepeatedTask) in
            counter.value += 1
            let p = eventLoop.makePromise(of: Void.self)
            _ = eventLoop.scheduleTask(in: .milliseconds(10)) {

                p.succeed(())
            }
            return p.futureResult
        }
        for _ in 0..<10 {
            // just running shouldn't do anything
            eventLoop.run()
        }

        // t == 0: nothing
        #expect(0 == counter.value)

        // t == 5: nothing
        eventLoop.advanceTime(by: .milliseconds(5))
        #expect(0 == counter.value)

        // t == 10: once
        eventLoop.advanceTime(by: .milliseconds(5))
        #expect(1 == counter.value)

        // t == 15: still once
        eventLoop.advanceTime(by: .milliseconds(5))
        #expect(1 == counter.value)

        // t == 20: still once (because the task takes 10ms to execute)
        eventLoop.advanceTime(by: .milliseconds(5))
        #expect(1 == counter.value)

        // t == 25: still once (because the task takes 10ms to execute)
        eventLoop.advanceTime(by: .milliseconds(5))
        #expect(1 == counter.value)

        // t == 30: twice
        eventLoop.advanceTime(by: .milliseconds(5))
        #expect(2 == counter.value)

        // t == 40: twice
        eventLoop.advanceTime(by: .milliseconds(10))
        #expect(2 == counter.value)

        // t == 50: three times
        eventLoop.advanceTime(by: .milliseconds(10))
        #expect(3 == counter.value)

        // t == 60: three times
        eventLoop.advanceTime(by: .milliseconds(10))
        #expect(3 == counter.value)

        // t == 89: four times
        eventLoop.advanceTime(by: .milliseconds(29))
        #expect(4 == counter.value)

        // t == 90: five times
        eventLoop.advanceTime(by: .milliseconds(1))
        #expect(5 == counter.value)

        repeatedTask.cancel()

        eventLoop.run()
        #expect(5 == counter.value)

        eventLoop.advanceTime(by: .hours(10))
        #expect(5 == counter.value)
    }

    @Test
    func testScheduledRepeatedAsyncTaskIsJittered() throws {
        let initialDelay = TimeAmount.minutes(5)
        let delay = TimeAmount.minutes(2)
        let maximumAllowableJitter = TimeAmount.minutes(1)
        let counter = ManagedAtomic<Int64>(0)
        let loop = EmbeddedEventLoop()

        _ = loop.scheduleRepeatedAsyncTask(
            initialDelay: initialDelay,
            delay: delay,
            maximumAllowableJitter: maximumAllowableJitter,
            { _ in
                counter.wrappingIncrement(ordering: .relaxed)
                let p = loop.makePromise(of: Void.self)
                _ = loop.scheduleTask(in: .milliseconds(10)) {
                    p.succeed(())
                }
                return p.futureResult
            }
        )

        for _ in 0..<10 {
            // just running shouldn't do anything
            loop.run()
        }

        let timeRange = TimeAmount.hours(1)
        // Due to jittered delays is not possible to exactly know how many tasks will be executed in a given time range,
        // instead calculate a range representing an estimate of the number of tasks executed during that given time range.
        let minNumberOfExecutedTasks =
            (timeRange.nanoseconds - initialDelay.nanoseconds)
            / (delay.nanoseconds + maximumAllowableJitter.nanoseconds)
        let maxNumberOfExecutedTasks =
            (timeRange.nanoseconds - initialDelay.nanoseconds) / delay.nanoseconds + 1

        loop.advanceTime(by: timeRange)
        #expect(
            (minNumberOfExecutedTasks...maxNumberOfExecutedTasks).contains(
                counter.load(ordering: .relaxed)
            )
        )
    }

    @Test
    func testEventLoopGroupMakeIterator() throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        var counter = 0
        var innerCounter = 0
        for loop in eventLoopGroup.makeIterator() {
            counter += 1
            for _ in loop.makeIterator() {
                innerCounter += 1
            }
        }

        #expect(counter == System.coreCount)
        #expect(innerCounter == System.coreCount)
    }

    @Test
    func testEventLoopMakeIterator() throws {
        let eventLoop = EmbeddedEventLoop()
        let iterator = eventLoop.makeIterator()
        defer {
            #expect(throws: Never.self) {
                try eventLoop.syncShutdownGracefully()
            }
        }

        var counter = 0
        for loop in iterator {
            #expect(loop === eventLoop)
            counter += 1
        }

        #expect(counter == 1)
    }

    @Test
    func testMultipleShutdown() throws {
        // This test catches a regression that causes it to intermittently fail: it reveals bugs in synchronous shutdown.
        // Do not ignore intermittent failures in this test!
        let threads = 8
        let numBytes = 256
        let group = MultiThreadedEventLoopGroup(numberOfThreads: threads)

        // Create a server channel.
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: 0).wait()
        )

        // We now want to connect to it. To try to slow this stuff down, we're going to use a multiple of the number
        // of event loops.
        for _ in 0..<(threads * 5) {
            let clientChannel = try assertNoThrowWithValue(
                ClientBootstrap(group: group)
                    .connect(to: serverChannel.localAddress!)
                    .wait()
            )

            var buffer = clientChannel.allocator.buffer(capacity: numBytes)
            for i in 0..<numBytes {
                buffer.writeInteger(UInt8(i % 256))
            }

            try clientChannel.writeAndFlush(buffer).wait()
        }

        // We should now shut down gracefully.
        try group.syncShutdownGracefully()
    }

    @Test
    func testShuttingDownFailsRegistration() throws {
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

            init(
                channelActivePromise: EventLoopPromise<Void>? = nil,
                _ promiseRegisterCallback: @escaping (EventLoopPromise<Void>) -> Void
            ) {
                self.promiseRegisterCallback = promiseRegisterCallback
                self.channelActivePromise = channelActivePromise
            }

            func channelActive(context: ChannelHandlerContext) {
                self.channelActivePromise?.succeed(())
            }

            func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
                guard self.closePromise == nil else {
                    Issue.record("Attempted to create duplicate close promise")
                    return
                }
                #expect(context.channel.isActive)
                self.closePromise = context.eventLoop.makePromise()
                let loopBoundContext = context.loopBound
                self.closePromise!.futureResult.whenSuccess {
                    let context = loopBoundContext.value
                    context.close(mode: mode, promise: promise)
                }
                promiseRegisterCallback(self.closePromise!)
            }
        }

        let promises = NIOLockedValueBox<[EventLoopPromise<Void>]>([])

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: EventLoopError.self) {
                do {
                    try group.syncShutdownGracefully()
                } catch {
                    #expect(.shutdown == error as? EventLoopError)
                    // re-throw error if caught to satisfy expectation that error is thrown
                    throw error
                }
            }
        }
        let loop = group.next() as! SelectableEventLoop

        let serverChannelUp = group.next().makePromise(of: Void.self)
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            WedgeOpenHandler(channelActivePromise: serverChannelUp) { promise in
                                promises.withLockedValue { $0.append(promise) }
                            }
                        )
                    }
                }
                .bind(host: "127.0.0.1", port: 0).wait()
        )
        defer {
            #expect(serverChannel.isActive == false)
        }
        let connectPromise = loop.makePromise(of: Void.self)

        // We're going to create and register a channel, but not actually attempt to do anything with it.
        let channel = try SocketChannel(eventLoop: loop, protocolFamily: .inet)
        try channel.eventLoop.submit {
            channel.eventLoop.makeCompletedFuture {
                let wedgeHandler = WedgeOpenHandler { promise in
                    promises.withLockedValue { $0.append(promise) }
                }
                try channel.pipeline.syncOperations.addHandler(wedgeHandler)
            }.flatMap {
                channel.register()
            }.flatMap {
                // connecting here to stop epoll from throwing EPOLLHUP at us
                channel.connect(to: serverChannel.localAddress!)
            }.cascade(to: connectPromise)
        }.wait()

        // Wait for the connect to complete.
        #expect(throws: Never.self) {
            try connectPromise.futureResult.wait()
            try serverChannelUp.futureResult.wait()
        }

        let g = DispatchGroup()
        let q = DispatchQueue(label: "\(#filePath)/\(#line)")
        g.enter()
        // Now we're going to start closing the event loop. This should not immediately succeed.
        loop.initiateClose(queue: q) { result in
            func workaroundSR9815() {
                #expect(throws: Never.self) {
                    try result.get()
                }
            }
            workaroundSR9815()
            g.leave()
        }

        // Now we're going to attempt to register a new channel. This should immediately fail.
        let newChannel = try SocketChannel(eventLoop: loop, protocolFamily: .inet)

        #expect(throws: EventLoopError.self) {
            do {
                try newChannel.register().wait()
            } catch {
                #expect(.shutdown == error as? EventLoopError)
                throw error
            }
        }

        // Confirm that the loop still hasn't closed.
        #expect(.timedOut == g.wait(timeout: .now()))

        // Now let it close.
        let promisesToSucceed = promises.withLockedValue { $0 }
        for promise in promisesToSucceed {
            promise.succeed(())
        }
        #expect(throws: Never.self) {
            g.wait()
        }
    }

    @Test
    func testEventLoopThreads() throws {
        var counter = 0
        let body: ThreadInitializer = { t in
            counter += 1
        }
        let threads: [ThreadInitializer] = [body, body]

        let group = MultiThreadedEventLoopGroup(threadInitializers: threads, metricsDelegate: nil)

        #expect(2 == counter)
        #expect(throws: Never.self) {
            try group.syncShutdownGracefully()
        }
    }

    @Test
    func testEventLoopPinned() throws {
        #if os(Linux) || os(Android)
        let target = NIOThread.currentAffinity.cpuIds.first!
        let body: ThreadInitializer = { t in
            let set = LinuxCPUSet(target)
            precondition(t.isCurrentSlow)
            NIOThread.currentAffinity = set
            #expect(set == NIOThread.currentAffinity)
        }
        let threads: [ThreadInitializer] = [body, body]

        let group = MultiThreadedEventLoopGroup(threadInitializers: threads, metricsDelegate: nil)

        #expect(throws: Never.self) {
            try group.syncShutdownGracefully()
        }
        #endif
    }

    @Test
    func testEventLoopPinnedCPUIdsConstructor() throws {
        #if os(Linux) || os(Android)
        let target = NIOThread.currentAffinity.cpuIds.first!
        let group = MultiThreadedEventLoopGroup(pinnedCPUIds: [target])
        let eventLoop = group.next()
        let set = try eventLoop.submit {
            NIOThread.currentAffinity
        }.wait()

        #expect(LinuxCPUSet(target) == set)
        #expect(throws: Never.self) {
            try group.syncShutdownGracefully()
        }
        #endif
    }

    @Test
    func testCurrentEventLoop() throws {
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
            #expect(loop1 === currentLoop1)

            let loop2 = group.next()
            let currentLoop2 = try loop2.submit {
                MultiThreadedEventLoopGroup.currentEventLoop
            }.wait()
            #expect(loop2 === currentLoop2)
            #expect((loop1 === loop2) == false)

            let holder = EventLoopHolder(loop2)
            #expect(holder.loop != nil)
            #expect(MultiThreadedEventLoopGroup.currentEventLoop == nil)
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
            return holder
        }

        let holder = try assertCurrentEventLoop0()

        // We loop as the Thread used by SelectableEventLoop may not be gone yet.
        // In the next major version we should ensure to join all threads and so be sure all are gone when
        // syncShutdownGracefully returned.
        var tries = 0
        while holder.loop != nil {
            #expect(tries < 5, "Reference to EventLoop still alive after 5 seconds")
            sleep(1)
            tries += 1
        }
    }

    @Test
    func testShutdownWhileScheduledTasksNotReady() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        _ = eventLoop.scheduleTask(in: .hours(1)) {}
        try group.syncShutdownGracefully()
    }

    @Test
    func testCloseFutureNotifiedBeforeUnblock() throws {
        final class AssertHandler: ChannelInboundHandler, Sendable {
            typealias InboundIn = Any

            let groupIsShutdown = ManagedAtomic(false)
            let removed = ManagedAtomic(false)

            func handlerRemoved(context: ChannelHandlerContext) {
                #expect(groupIsShutdown.load(ordering: .relaxed) == false)
                #expect(removed.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged)
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let assertHandler = AssertHandler()
        let serverSocket = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .bind(host: "localhost", port: 0).wait()
        )
        let channel = try assertNoThrowWithValue(
            SocketChannel(
                eventLoop: eventLoop as! SelectableEventLoop,
                protocolFamily: serverSocket.localAddress!.protocol
            )
        )
        #expect(throws: Never.self) {
            try channel.pipeline.addHandler(assertHandler).wait() as Void
            try channel.eventLoop.flatSubmit {
                channel.register().flatMap {
                    channel.connect(to: serverSocket.localAddress!)
                }
            }.wait() as Void
        }
        let closeFutureFulfilledEventually = ManagedAtomic(false)
        #expect(channel.closeFuture.isFulfilled == false)
        channel.closeFuture.whenSuccess {
            #expect(
                closeFutureFulfilledEventually.compareExchange(expected: false, desired: true, ordering: .relaxed)
                    .exchanged
            )
        }
        #expect(throws: Never.self) {
            try group.syncShutdownGracefully()
        }
        #expect(
            assertHandler.groupIsShutdown.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged
        )
        #expect(assertHandler.removed.load(ordering: .relaxed) == true)
        #expect(channel.isActive == false)
        #expect(closeFutureFulfilledEventually.load(ordering: .relaxed) == true)
    }

    @Test
    func testScheduleMultipleTasks() throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        let eventLoop = eventLoopGroup.next()
        let array = try! eventLoop.submit {
            NIOLoopBoundBox([(Int, NIODeadline)](), eventLoop: eventLoop)
        }.wait()
        let scheduled1 = eventLoop.scheduleTask(in: .milliseconds(500)) {
            array.value.append((1, .now()))
        }

        let scheduled2 = eventLoop.scheduleTask(in: .milliseconds(100)) {
            array.value.append((2, .now()))
        }

        let scheduled3 = eventLoop.scheduleTask(in: .milliseconds(1000)) {
            array.value.append((3, .now()))
        }

        var result = try eventLoop.scheduleTask(in: .milliseconds(1000)) {
            array.value
        }.futureResult.wait()

        #expect(scheduled1.futureResult.isFulfilled)
        #expect(scheduled2.futureResult.isFulfilled)
        #expect(scheduled3.futureResult.isFulfilled)

        let first = result.removeFirst()
        #expect(2 == first.0)
        let second = result.removeFirst()
        #expect(1 == second.0)
        let third = result.removeFirst()
        #expect(3 == third.0)

        #expect(first.1 < second.1)
        #expect(second.1 < third.1)

        #expect(result.isEmpty)
    }

    @Test
    func testRepeatedTaskThatIsImmediatelyCancelledNotifies() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        let loop = eventLoopGroup.next()
        let promise1: EventLoopPromise<Void> = loop.makePromise()
        let promise2: EventLoopPromise<Void> = loop.makePromise()
        try await confirmation(expectedCount: 2) { confirmation in
            promise1.futureResult.whenSuccess { confirmation() }
            promise2.futureResult.whenSuccess { confirmation() }
            loop.execute {
                let task = loop.scheduleRepeatedTask(
                    initialDelay: .milliseconds(0),
                    delay: .milliseconds(0),
                    notifying: promise1
                ) { task in
                    Issue.record()
                }
                task.cancel(promise: promise2)
            }

            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test
    func testRepeatedTaskThatIsCancelledAfterRunningAtLeastTwiceNotifies() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        let loop = eventLoopGroup.next()
        let promise1: EventLoopPromise<Void> = loop.makePromise()
        let promise2: EventLoopPromise<Void> = loop.makePromise()

        // Wait for task to notify twice
        var task: RepeatedTask?
        let initialConfirmCount = ManagedAtomic<Int>(0)
        let minimumExpectedCount = 2
        try await confirmation(expectedCount: minimumExpectedCount) { confirm in
            task = loop.scheduleRepeatedTask(
                initialDelay: .milliseconds(0),
                delay: .milliseconds(10),
                notifying: promise1
            ) { task in
                // We need to confirm two or more occur
                if initialConfirmCount.loadThenWrappingIncrement(ordering: .sequentiallyConsistent) < minimumExpectedCount {
                    confirm()
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let cancellationHandle = try #require(task)

        try await confirmation(expectedCount: 2) { confirmation in
            promise1.futureResult.whenSuccess { confirmation() }
            promise2.futureResult.whenSuccess { confirmation() }
            cancellationHandle.cancel(promise: promise2)
            try await Task.sleep(for: .seconds(1))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func testRepeatedTaskThatCancelsItselfNotifiesOnlyWhenFinished() async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        let loop = eventLoopGroup.next()
        let promise1: EventLoopPromise<Void> = loop.makePromise()
        let promise2: EventLoopPromise<Void> = loop.makePromise()
        let semaphore = DispatchSemaphore(value: 0)

        loop.scheduleRepeatedTask(
            initialDelay: .milliseconds(0),
            delay: .milliseconds(0),
            notifying: promise1
        ) { task in
            task.cancel(promise: promise2)
            semaphore.wait()
        }

        // Phase 1 — promises must NOT complete within 0.5s
        try await confirmation(expectedCount: 0) { confirm in
            promise1.futureResult.whenSuccess {
                confirm() // would fail the test if called, because we expect 0 confirmations
            }
            promise2.futureResult.whenSuccess {
                confirm() // would fail the test if called, because we expect 0 confirmations
            }

            // Allow 0.5 seconds for promises to incorrectly fulfill
            try await Task.sleep(for: .milliseconds(500))
        }

        // Phase 2 — now allow completion and verify they DO complete

        semaphore.signal()

        try await confirmation(expectedCount: 2) { confirm in
            promise1.futureResult.whenSuccess {
                confirm()
            }
            promise2.futureResult.whenSuccess {
                confirm()
            }

            // Allow 0.5 seconds for promises to correctly fulfill
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    @Test
    func testRepeatedTaskIsJittered() throws {
        let initialDelay = TimeAmount.minutes(5)
        let delay = TimeAmount.minutes(2)
        let maximumAllowableJitter = TimeAmount.minutes(1)
        let counter = ManagedAtomic<Int64>(0)
        let loop = EmbeddedEventLoop()

        _ = loop.scheduleRepeatedTask(
            initialDelay: initialDelay,
            delay: delay,
            maximumAllowableJitter: maximumAllowableJitter,
            { _ in
                counter.wrappingIncrement(ordering: .relaxed)
            }
        )

        let timeRange = TimeAmount.hours(1)
        // Due to jittered delays is not possible to exactly know how many tasks will be executed in a given time range,
        // instead calculate a range representing an estimate of the number of tasks executed during that given time range.
        let minNumberOfExecutedTasks =
            (timeRange.nanoseconds - initialDelay.nanoseconds)
            / (delay.nanoseconds + maximumAllowableJitter.nanoseconds)
        let maxNumberOfExecutedTasks =
            (timeRange.nanoseconds - initialDelay.nanoseconds) / delay.nanoseconds + 1

        loop.advanceTime(by: timeRange)
        #expect(
            (minNumberOfExecutedTasks...maxNumberOfExecutedTasks).contains(
                counter.load(ordering: .relaxed)
            )
        )
    }

    @Test
    func testCancelledScheduledTasksDoNotHoldOnToRunClosure() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
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
            Issue.record("Timed out waiting for lock")
        }

        #expect(throws: EventLoopError.cancelled) {
            try scheduled.futureResult.wait()
        }
    }

    @Test
    func testCancelledScheduledTasksDoNotHoldOnToRunClosureEvenIfTheyWereTheNextTaskToExecute()
        throws
    {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        final class Thing: Sendable {
            private let deallocated: ConditionLock<Int>

            init(_ deallocated: ConditionLock<Int>) {
                self.deallocated = deallocated
            }

            deinit {
                self.deallocated.lock()
                self.deallocated.unlock(withValue: 1)
            }
        }

        func make(deallocated: ConditionLock<Int>) -> Scheduled<Void> {
            let aThing = Thing(deallocated)
            return group.next().scheduleTask(in: .hours(1)) {
                preconditionFailure("this should definitely not run: \(aThing)")
            }
        }

        // What are we doing here?
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
        scheduled.futureResult.eventLoop.scheduleTask(in: .hours(2)) {}
        try! scheduled.futureResult.eventLoop.submit {}.wait()
        scheduled.cancel()
        if deallocated.lock(whenValue: 1, timeoutSeconds: 60) {
            deallocated.unlock()
        } else {
            Issue.record("Timed out waiting for lock")
        }

        #expect(throws: EventLoopError.cancelled) {
            try scheduled.futureResult.wait()
        }
    }

    @Test
    func testIllegalCloseOfEventLoopFails() {
        // Vapor 3 closes EventLoops directly which is illegal and makes the `shutdownGracefully` of the owning
        // MultiThreadedEventLoopGroup never succeed.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        #expect(throws: EventLoopError.unsupportedOperation) {
            try group.next().syncShutdownGracefully()
        }
    }

    @Test
    func testSubtractingDeadlineFromPastAndFuturesDeadlinesWorks() throws {
        let older = NIODeadline.now()
        Thread.sleep(until: Date().addingTimeInterval(0.02))
        let newer = NIODeadline.now()

        #expect(older - newer < .nanoseconds(0))
        #expect(newer - older > .nanoseconds(0))
    }

    @Test
    func testCallingSyncShutdownGracefullyMultipleTimesShouldNotHang() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        try elg.syncShutdownGracefully()
        try elg.syncShutdownGracefully()
        try elg.syncShutdownGracefully()
    }

    @Test
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
            Issue.record("Not all shutdown callbacks have been executed")
            return
        }
        condition.unlock()
    }

    @Test
    func testEdgeCasesNIODeadlineMinusNIODeadline() {
        let smallestPossibleDeadline = NIODeadline.uptimeNanoseconds(.min)
        let largestPossibleDeadline = NIODeadline.uptimeNanoseconds(.max)
        let distantFuture = NIODeadline.distantFuture
        let distantPast = NIODeadline.distantPast
        let zeroDeadline = NIODeadline.uptimeNanoseconds(0)
        let nowDeadline = NIODeadline.now()

        let allDeadlines = [
            smallestPossibleDeadline, largestPossibleDeadline, distantPast, distantFuture,
            zeroDeadline, nowDeadline,
        ]

        for deadline1 in allDeadlines {
            for deadline2 in allDeadlines {
                if deadline1 > deadline2 {
                    #expect(deadline1 - deadline2 > TimeAmount.nanoseconds(0))
                } else if deadline1 < deadline2 {
                    #expect(deadline1 - deadline2 < TimeAmount.nanoseconds(0))
                } else {
                    // they're equal.
                    #expect(deadline1 - deadline2 == TimeAmount.nanoseconds(0))
                }
            }
        }
    }

    @Test
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
            for deadline in [
                smallestPossibleDeadline, largestPossibleDeadline, distantPast, distantFuture,
                zeroDeadline, nowDeadline,
            ] {
                let (partial, overflow) = Int64(deadline.uptimeNanoseconds).addingReportingOverflow(
                    timeAmount.nanoseconds
                )
                let expectedValue: UInt64
                if overflow {
                    #expect(timeAmount.nanoseconds >= 0)
                    #expect(deadline.uptimeNanoseconds >= 0)
                    // we cap at distantFuture towards +inf
                    expectedValue = NIODeadline.distantFuture.uptimeNanoseconds
                } else if partial < 0 {
                    // we cap at 0 towards -inf
                    expectedValue = 0
                } else {
                    // otherwise we have a result
                    expectedValue = .init(partial)
                }
                #expect((deadline + timeAmount).uptimeNanoseconds == expectedValue)
            }
        }
    }

    @Test
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
            for deadline in [
                smallestPossibleDeadline, largestPossibleDeadline, distantPast, distantFuture,
                zeroDeadline, nowDeadline,
            ] {
                let (partial, overflow) = Int64(deadline.uptimeNanoseconds).subtractingReportingOverflow(
                    timeAmount.nanoseconds
                )
                let expectedValue: UInt64
                if overflow {
                    #expect(timeAmount.nanoseconds < 0)
                    #expect(deadline.uptimeNanoseconds >= 0)
                    // we cap at distantFuture towards +inf
                    expectedValue = NIODeadline.distantFuture.uptimeNanoseconds
                } else if partial < 0 {
                    // we cap at 0 towards -inf
                    expectedValue = 0
                } else {
                    // otherwise we have a result
                    expectedValue = .init(partial)
                }
                #expect((deadline - timeAmount).uptimeNanoseconds == expectedValue)
            }
        }
    }

    @Test
    func testSuccessfulFlatSubmit() throws {
        let eventLoop = EmbeddedEventLoop()
        let future = eventLoop.flatSubmit {
            eventLoop.makeSucceededFuture(1)
        }
        eventLoop.run()
        #expect(throws: Never.self) {
            let result = try future.wait()
            #expect(result == 1)
        }
    }

    @Test
    func testFailingFlatSubmit() throws {
        enum TestError: Error { case failed }

        let eventLoop = EmbeddedEventLoop()
        let future = eventLoop.flatSubmit { () -> EventLoopFuture<Int> in
            eventLoop.makeFailedFuture(TestError.failed)
        }
        eventLoop.run()
        #expect(throws: TestError.failed) {
            try future.wait()
        }
    }

    @Test
    func testSchedulingTaskOnTheEventLoopWithinTheEventLoopsOnlyTask() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try elg.syncShutdownGracefully()
            }
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

    @Test
    func testSchedulingTaskOnTheEventLoopWithinTheEventLoopsOnlyIOOperation() {
        final class ExecuteSomethingOnEventLoop: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            static let numberOfInstances = ManagedAtomic<Int>(0)
            let groupToNotify: DispatchGroup

            init(groupToNotify: DispatchGroup) {
                #expect(
                    0
                        == ExecuteSomethingOnEventLoop.numberOfInstances.loadThenWrappingIncrement(ordering: .relaxed)
                )
                self.groupToNotify = groupToNotify
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                context.eventLoop.assumeIsolated().execute {
                    self.groupToNotify.leave()
                }
            }
        }

        let elg1 = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let elg2 = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try elg1.syncShutdownGracefully()
                try elg2.syncShutdownGracefully()
            }
        }

        let g = DispatchGroup()
        g.enter()
        var maybeServer: Channel?
        #expect(throws: Never.self) {
            maybeServer = try ServerBootstrap(group: elg2)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .serverChannelOption(.autoRead, value: false)
                .serverChannelOption(.maxMessagesPerRead, value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(ExecuteSomethingOnEventLoop(groupToNotify: g))
                    }
                }
                .bind(to: .init(ipAddress: "127.0.0.1", port: 0))
                .wait()
        }
        maybeServer?.read()  // this should accept one client

        var maybeClient: Channel?
        #expect(throws: Never.self) {
            maybeClient = try ClientBootstrap(group: elg1)
                .connect(
                    to: maybeServer?.localAddress ?? SocketAddress(unixDomainSocketPath: "/dev/null/does/not/exist")
                )
                .wait()
        }

        guard let client = maybeClient else {
            Issue.record("couldn't connect")
            return
        }

        var buffer = client.allocator.buffer(capacity: 1)
        buffer.writeString("X")

        // Now let's trigger a channelRead in the accepted channel which should schedule running an EventLoop task
        // with no outstanding operations on the EventLoop (no IO, nor tasks left to do).
        #expect(throws: Never.self) {
            try client.writeAndFlush(buffer).wait()
        }

        // The executed task should've notified this DispatchGroup
        g.wait()
    }

    @Test
    func testCancellingTheLastOutstandingTask() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try elg.syncShutdownGracefully()
            }
        }

        let el = elg.next()
        let task = el.scheduleTask(in: .milliseconds(10)) {}
        task.cancel()
        // sleep for 15ms which should have the above scheduled (and cancelled) task have caused an unnecessary wakeup.
        Thread.sleep(forTimeInterval: 0.015)  // 15 ms
    }

    @Test
    func testSchedulingTaskOnTheEventLoopWithinTheEventLoopsOnlyScheduledTask() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try elg.syncShutdownGracefully()
            }
        }

        let el = elg.next()
        let g = DispatchGroup()
        g.enter()
        el.scheduleTask(in: .nanoseconds(10)) {  // something non-0
            el.execute {
                g.leave()
            }
        }
        g.wait()
    }

    @Test
    func testSelectableEventLoopDescription() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try elg.syncShutdownGracefully()
            }
        }

        let el: EventLoop = elg.next()
        let expectedPrefix = "SelectableEventLoop { "
        let expectedContains = "thread = NIOThread(name = NIO-ELT-"
        let expectedSuffix = " }"
        let desc = el.description
        #expect(el.description.starts(with: expectedPrefix), Comment(rawValue: desc))
        #expect(el.description.reversed().starts(with: expectedSuffix.reversed()), Comment(rawValue: desc))
        // let's check if any substring contains the `expectedContains`
        #expect(
            desc.indices.contains { startIndex in
                desc[startIndex...].starts(with: expectedContains)
            },
            Comment(rawValue: desc)
        )
    }

    @Test
    func testMultiThreadedEventLoopGroupDescription() {
        let elg: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try elg.syncShutdownGracefully()
            }
        }

        #expect(
            elg.description.starts(with: "MultiThreadedEventLoopGroup { threadPattern = NIO-ELT-"),
            Comment(rawValue: elg.description)
        )
    }

    @Test
    func testSafeToExecuteTrue() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try elg.syncShutdownGracefully()
            }
        }
        let loop = elg.next() as! SelectableEventLoop
        #expect(loop.testsOnly_validExternalStateToScheduleTasks)
        #expect(loop.testsOnly_validExternalStateToScheduleTasks)
    }

    @Test
    func testSafeToExecuteFalse() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = elg.next() as! SelectableEventLoop
        try? elg.syncShutdownGracefully()
        #expect(loop.testsOnly_validExternalStateToScheduleTasks == false)
        #expect(loop.testsOnly_validExternalStateToScheduleTasks == false)
    }

    @Test
    func testTakeOverThreadAndAlsoTakeItBack() {
        let currentNIOThread = NIOThread.currentThreadID
        let currentNSThread = Thread.current
        let hasBeenShutdown = NIOLockedValueBox(false)
        let allDoneGroup = DispatchGroup()
        allDoneGroup.enter()
        MultiThreadedEventLoopGroup.withCurrentThreadAsEventLoop { loop in
            #expect(currentNIOThread == NIOThread.currentThreadID)
            #expect(currentNSThread == Thread.current)
            #expect(loop === MultiThreadedEventLoopGroup.currentEventLoop)
            loop.shutdownGracefully(queue: DispatchQueue.global()) { error in
                #expect(error == nil)
                hasBeenShutdown.withLockedValue {
                    $0 = error == nil
                }
                allDoneGroup.leave()
            }
        }
        allDoneGroup.wait()
        #expect(hasBeenShutdown.withLockedValue { $0 })
    }

    @Test
    func testThreadTakeoverUnsetsCurrentEventLoop() {
        #expect(MultiThreadedEventLoopGroup.currentEventLoop == nil)

        MultiThreadedEventLoopGroup.withCurrentThreadAsEventLoop { el in
            #expect(el === MultiThreadedEventLoopGroup.currentEventLoop)
            el.shutdownGracefully { error in
                #expect(error == nil)
            }
        }

        #expect(MultiThreadedEventLoopGroup.currentEventLoop == nil)
    }

    @Test
    func testWeCanDoTrulySingleThreadedNetworking() {
        final class SaveReceivedByte: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            init(received: NIOLockedValueBox<UInt8?>) {
                self.received = received
            }

            // For once, we don't need thread-safety as we're taking the calling thread :)
            let received: NIOLockedValueBox<UInt8?>
            var readCalls: Int = 0
            var allDonePromise: EventLoopPromise<Void>? = nil

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                self.readCalls += 1
                #expect(1 == self.readCalls)

                var data = Self.unwrapInboundIn(data)
                #expect(1 == data.readableBytes)

                #expect(self.received.withLockedValue { $0 } == nil)
                self.received.withLockedValue { $0 = data.readInteger() }

                self.allDonePromise?.succeed(())

                context.close(promise: nil)
            }
        }

        let received = NIOLockedValueBox<UInt8?>(nil)
        MultiThreadedEventLoopGroup.withCurrentThreadAsEventLoop { loop in
            // There'll be just one connection, we can share.
            let receiveHandler = NIOLoopBound(SaveReceivedByte(received: received), eventLoop: loop)

            ServerBootstrap(group: loop)
                .serverChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
                .childChannelInitializer { accepted in
                    accepted.eventLoop.makeCompletedFuture {
                        try accepted.pipeline.syncOperations.addHandler(receiveHandler.value)
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .flatMap { serverChannel in
                    ClientBootstrap(group: loop).connect(to: serverChannel.localAddress!).flatMap { clientChannel in
                        var buffer = clientChannel.allocator.buffer(capacity: 1)
                        buffer.writeString("J")
                        return clientChannel.writeAndFlush(buffer)
                    }.flatMap {
                        #expect(receiveHandler.value.allDonePromise == nil)
                        receiveHandler.value.allDonePromise = loop.makePromise()
                        return receiveHandler.value.allDonePromise!.futureResult
                    }.flatMap {
                        serverChannel.close()
                    }
                }.whenComplete { (result: Result<Void, Error>) -> Void in
                    func workaroundSR9815withAUselessFunction() {
                        #expect(throws: Never.self) {
                            try result.get()
                        }
                    }
                    workaroundSR9815withAUselessFunction()

                    // All done, let's return back into the calling thread.
                    loop.shutdownGracefully { error in
                        #expect(error == nil)
                    }
                }
        }

        // All done, the EventLoop is terminated so we should be able to check the results.
        #expect(UInt8(ascii: "J") == received.withLockedValue { $0 })
    }

    @Test
    func testWeFailOutstandingScheduledTasksOnELShutdown() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let scheduledTask = group.next().scheduleTask(in: .hours(24)) {
            Issue.record("We lost the 24 hour race and aren't even in Le Mans.")
        }
        let waiter = DispatchGroup()
        waiter.enter()
        scheduledTask.futureResult.map { _ in
            Issue.record("didn't expect success")
        }.whenFailure { error in
            #expect(.shutdown == error as? EventLoopError)
            waiter.leave()
        }

        #expect(throws: Never.self) {
            try group.syncShutdownGracefully()
        }
        waiter.wait()
    }

    @Test
    func testSchedulingTaskOnFutureFailedByELShutdownDoesNotMakeUsExplode() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let scheduledTask = group.next().scheduleTask(in: .hours(24)) {
            Issue.record("Task was scheduled in 24 hours, yet it executed.")
        }
        let waiter = DispatchGroup()
        waiter.enter()  // first scheduled task
        waiter.enter()  // scheduled task in the first task's whenFailure.
        scheduledTask.futureResult
            .map { _ in
                Issue.record("didn't expect success")
            }
            .whenFailure { error in
                #expect(.shutdown == error as? EventLoopError)
                group.next().execute {}  // This previously blew up
                group.next().scheduleTask(in: .hours(24)) {
                    Issue.record("Task was scheduled in 24 hours, yet it executed.")
                }.futureResult.map {
                    Issue.record("didn't expect success")
                }.whenFailure { error in
                    #expect(.shutdown == error as? EventLoopError)
                    waiter.leave()
                }
                waiter.leave()
            }

        #expect(throws: Never.self) {
            try group.syncShutdownGracefully()
        }
        waiter.wait()
    }

    @Test
    func testEventLoopGroupProvider() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try eventLoopGroup.syncShutdownGracefully()
            }
        }

        let provider = NIOEventLoopGroupProvider.shared(eventLoopGroup)

        if case .shared(let sharedEventLoopGroup) = provider {
            #expect(sharedEventLoopGroup is MultiThreadedEventLoopGroup)
            #expect(sharedEventLoopGroup === eventLoopGroup)
        } else {
            Issue.record("Not the same")
        }
    }

    // Test that scheduling a task at the maximum value doesn't crash.
    // (Crashing resulted from an EINVAL/IOException thrown by the kevent
    // syscall when the timeout value exceeded the maximum supported by
    // the Darwin kernel #1056).
    @Test
    func testScheduleMaximum() throws {
        let eventLoop = EmbeddedEventLoop()
        let maxAmount: TimeAmount = .nanoseconds(.max)
        let scheduled = eventLoop.scheduleTask(in: maxAmount) { true }

        var result: Bool?
        var error: Error?
        scheduled.futureResult.assumeIsolated().whenSuccess { result = $0 }
        scheduled.futureResult.assumeIsolated().whenFailure { error = $0 }

        scheduled.cancel()

        #expect(scheduled.futureResult.isFulfilled)
        #expect(result == nil)
        #expect(error as? EventLoopError == .cancelled)
    }

    @Test
    func testEventLoopsWithPreSucceededFuturesCacheThem() {
        let el = EventLoopWithPreSucceededFuture()
        defer {
            #expect(throws: Never.self) {
                try el.syncShutdownGracefully()
            }
        }

        let future1 = el.makeSucceededFuture(())
        let future2 = el.makeSucceededFuture(())
        let future3 = el.makeSucceededVoidFuture()

        #expect(future1 === future2)
        #expect(future2 === future3)
    }

    @Test
    func testEventLoopsWithoutPreSucceededFuturesDoNotCacheThem() {
        let el = EventLoopWithoutPreSucceededFuture()
        defer {
            #expect(throws: Never.self) {
                try el.syncShutdownGracefully()
            }
        }

        let future1 = el.makeSucceededFuture(())
        let future2 = el.makeSucceededFuture(())
        let future3 = el.makeSucceededVoidFuture()

        #expect(future1 !== future2)
        #expect(future2 !== future3)
        #expect(future1 !== future3)
    }

    @Test
    func testSelectableEventLoopHasPreSucceededFuturesOnlyOnTheEventLoop() throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try elg.syncShutdownGracefully()
            }
        }

        let el = elg.next()

        let futureOutside1 = el.makeSucceededVoidFuture()
        let futureOutside2 = el.makeSucceededFuture(())
        #expect(futureOutside1 !== futureOutside2)

        #expect(throws: Never.self) {
            try el.submit {
                let futureInside1 = el.makeSucceededVoidFuture()
                let futureInside2 = el.makeSucceededFuture(())

                #expect(futureOutside1 !== futureInside1)
                #expect(futureInside1 === futureInside2)
            }.wait()
        }
    }

    @Test
    func testMakeCompletedFuture() throws {
        let eventLoop = EmbeddedEventLoop()
        defer {
            #expect(throws: Never.self) {
                try eventLoop.syncShutdownGracefully()
            }
        }

        #expect(try eventLoop.makeCompletedFuture(.success("foo")).wait() == "foo")

        struct DummyError: Error {}
        let future = eventLoop.makeCompletedFuture(Result<String, Error>.failure(DummyError()))
        #expect(throws: DummyError.self) {
            try future.wait()
        }
    }

    @Test
    func testMakeCompletedFutureWithResultOf() throws {
        let eventLoop = EmbeddedEventLoop()
        defer {
            #expect(throws: Never.self) {
                try eventLoop.syncShutdownGracefully()
            }
        }

        #expect(try eventLoop.makeCompletedFuture(withResultOf: { "foo" }).wait() == "foo")

        struct DummyError: Error {}
        func throwError() throws {
            throw DummyError()
        }

        let future = eventLoop.makeCompletedFuture(withResultOf: throwError)
        #expect(throws: DummyError.self) {
            try future.wait()
        }
    }

    @Test
    func testMakeCompletedVoidFuture() {
        let eventLoop = EventLoopWithPreSucceededFuture()
        defer {
            #expect(throws: Never.self) {
                try eventLoop.syncShutdownGracefully()
            }
        }

        let future1 = eventLoop.makeCompletedFuture(.success(()))
        let future2 = eventLoop.makeSucceededVoidFuture()
        let future3 = eventLoop.makeSucceededFuture(())
        #expect(future1 === future2)
        #expect(future2 === future3)
    }

    @Test
    func testEventLoopGroupsWithoutAnyImplementationAreValid() throws {
        let group = EventLoopGroupOf3WithoutAnAnyImplementation()
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        let submitDone = group.any().submit {
            let el1 = group.any()
            let el2 = group.any()
            // our group doesn't support `any()` and will fall back to `next()`.
            #expect(el1 !== el2)
        }
        for el in group.makeIterator() {
            (el as! EmbeddedEventLoop).run()
        }
        #expect(throws: Never.self) {
            try submitDone.wait()
        }
    }

    @Test
    func testCallingAnyOnAnMTELGThatIsNotSelfDoesNotReturnItself() {
        let group1 = MultiThreadedEventLoopGroup(numberOfThreads: 3)
        let group2 = MultiThreadedEventLoopGroup(numberOfThreads: 3)
        defer {
            #expect(throws: Never.self) {
                try group2.syncShutdownGracefully()
                try group1.syncShutdownGracefully()
            }
        }

        #expect(throws: Never.self) {
            try group1.any().submit {
                let el1_1 = group1.any()
                let el1_2 = group1.any()
                let el2_1 = group2.any()
                let el2_2 = group2.any()

                // MTELG _does_ supprt `any()` so all these `EventLoop`s should be the same.
                #expect(el1_1 === el1_2)
                // MTELG _does_ supprt `any()` but this `any()` call went across `group`s.
                #expect(el2_1 !== el2_2)
                // different groups...
                #expect(el1_1 !== el2_1)
                // different groups...
                #expect(el1_1 !== el2_2)

                #expect(el1_1 === MultiThreadedEventLoopGroup.currentEventLoop!)
            }.wait()
        }
    }

    @Test
    func testMultiThreadedEventLoopGroupSupportsStickyAnyImplementation() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 3)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        #expect(throws: Never.self) {
            try group.any().submit {
                let el1 = group.any()
                let el2 = group.any()
                #expect(el1 === el2)  // MTELG _does_ supprt `any()` so all these `EventLoop`s should be the same.
                #expect(el1 === MultiThreadedEventLoopGroup.currentEventLoop!)
            }.wait()
        }
    }

    @Test
    func testAsyncToFutureConversionSuccess() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        let result = try group.next().makeFutureWithTask {
            try await Task.sleep(nanoseconds: 37)
            return "hello from async"
        }.wait()
        #expect("hello from async" == result)
    }

    @Test
    func testAsyncToFutureConversionFailure() throws {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        struct DummyError: Error {}

        #expect(throws: DummyError.self) {
            try group.next().makeFutureWithTask {
                try await Task.sleep(nanoseconds: 37)
                throw DummyError()
            }.wait()
        }
    }

    // Test for possible starvation discussed here: https://github.com/apple/swift-nio/pull/2645#discussion_r1486747118
    @Test
    func testNonStarvation() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        let eventLoop = group.next()
        let stop = try eventLoop.submit { NIOLoopBoundBox(false, eventLoop: eventLoop) }.wait()

        @Sendable
        func reExecuteTask() {
            if !stop.value {
                eventLoop.execute {
                    reExecuteTask()
                }
            }
        }

        eventLoop.execute {
            // SelectableEventLoop runs batches of up to 4096.
            // Submit significantly over that for good measure.
            for _ in (0..<10000) {
                eventLoop.assumeIsolated().execute(reExecuteTask)
            }
        }
        let stopTask = eventLoop.scheduleTask(in: .microseconds(10)) {
            stop.value = true
        }
        try stopTask.futureResult.wait()
    }

    @Test
    func testMixedImmediateAndScheduledTasks() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        let eventLoop = group.next()
        let scheduledTaskMagic = 17
        let scheduledTask = eventLoop.scheduleTask(in: .microseconds(10)) {
            scheduledTaskMagic
        }

        let immediateTaskMagic = 18
        let immediateTask = eventLoop.submit {
            immediateTaskMagic
        }

        let scheduledTaskMagicOut = try scheduledTask.futureResult.wait()
        #expect(scheduledTaskMagicOut == scheduledTaskMagic)

        let immediateTaskMagicOut = try immediateTask.wait()
        #expect(immediateTaskMagicOut == immediateTaskMagic)
    }

    @Test
    func testLotsOfMixedImmediateAndScheduledTasks() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        let eventLoop = group.next()
        struct Counter: Sendable {
            private var _submitCount = NIOLockedValueBox(0)
            var submitCount: Int {
                get { self._submitCount.withLockedValue { $0 } }
                nonmutating set { self._submitCount.withLockedValue { $0 = newValue } }
            }
            private var _scheduleCount = NIOLockedValueBox(0)
            var scheduleCount: Int {
                get { self._scheduleCount.withLockedValue { $0 } }
                nonmutating set { self._scheduleCount.withLockedValue { $0 = newValue } }
            }
        }

        let achieved = Counter()
        var immediateTasks = [EventLoopFuture<Void>]()
        var scheduledTasks = [Scheduled<Void>]()
        for _ in (0..<100_000) {
            if Bool.random() {
                let task = eventLoop.submit {
                    achieved.submitCount += 1
                }
                immediateTasks.append(task)
            }
            if Bool.random() {
                let task = eventLoop.scheduleTask(in: .microseconds(10)) {
                    achieved.scheduleCount += 1
                }
                scheduledTasks.append(task)
            }
        }

        let submitCount = try EventLoopFuture.whenAllSucceed(immediateTasks, on: eventLoop).map({
            _ in
            achieved.submitCount
        }).wait()
        #expect(submitCount == achieved.submitCount)

        let scheduleCount = try EventLoopFuture.whenAllSucceed(
            scheduledTasks.map { $0.futureResult },
            on: eventLoop
        )
        .map({ _ in
            achieved.scheduleCount
        }).wait()
        #expect(scheduleCount == scheduledTasks.count)
    }

    @Test
    func testLotsOfMixedImmediateAndScheduledTasksFromEventLoop() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        let eventLoop = group.next()
        struct Counter: Sendable {
            private var _submitCount = NIOLockedValueBox(0)
            var submitCount: Int {
                get { self._submitCount.withLockedValue { $0 } }
                nonmutating set { self._submitCount.withLockedValue { $0 = newValue } }
            }
            private var _scheduleCount = NIOLockedValueBox(0)
            var scheduleCount: Int {
                get { self._scheduleCount.withLockedValue { $0 } }
                nonmutating set { self._scheduleCount.withLockedValue { $0 = newValue } }
            }
        }

        let achieved = Counter()
        let (immediateTasks, scheduledTasks) = try eventLoop.submit {
            var immediateTasks = [EventLoopFuture<Void>]()
            var scheduledTasks = [Scheduled<Void>]()
            for _ in (0..<100_000) {
                if Bool.random() {
                    let task = eventLoop.submit {
                        achieved.submitCount += 1
                    }
                    immediateTasks.append(task)
                }
                if Bool.random() {
                    let task = eventLoop.scheduleTask(in: .microseconds(10)) {
                        achieved.scheduleCount += 1
                    }
                    scheduledTasks.append(task)
                }
            }
            return (immediateTasks, scheduledTasks)
        }.wait()

        let submitCount = try EventLoopFuture.whenAllSucceed(immediateTasks, on: eventLoop)
            .map({ _ in
                achieved.submitCount
            }).wait()
        #expect(submitCount == achieved.submitCount)

        let scheduleCount = try EventLoopFuture.whenAllSucceed(
            scheduledTasks.map { $0.futureResult },
            on: eventLoop
        )
        .map({ _ in
            achieved.scheduleCount
        }).wait()
        #expect(scheduleCount == scheduledTasks.count)
    }

    @Test
    func testImmediateTasksDontGetStuck() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            #expect(throws: Never.self) {
                try group.syncShutdownGracefully()
            }
        }

        let eventLoop = group.next()
        let testEventLoop = MultiThreadedEventLoopGroup.singleton.any()

        let longWait = TimeAmount.seconds(60)
        let failDeadline = NIODeadline.now() + longWait
        let (immediateTasks, scheduledTask) = try eventLoop.submit {
            // Submit over the 4096 immediate tasks, and some scheduled tasks
            // with expiry deadline in (nearish) future.
            // We want to make sure immediate tasks, even those that don't fit
            // in the first batch, don't get stuck waiting for scheduled task
            // expiry
            let immediateTasks = (0..<5000).map { _ in
                eventLoop.submit {}.hop(to: testEventLoop)
            }
            let scheduledTask = eventLoop.scheduleTask(in: longWait) {
            }

            return (immediateTasks, scheduledTask)
        }.wait()

        // The immediate tasks should all succeed ~immediately.
        // We're testing for a case where the EventLoop gets confused
        // into waiting for the scheduled task expiry to complete
        // some immediate tasks.
        _ = try EventLoopFuture.whenAllSucceed(immediateTasks, on: testEventLoop).wait()
        #expect(.now() < failDeadline)

        scheduledTask.cancel()
    }

    @Test
    func testInEventLoopABAProblem() throws {
        // Older SwiftNIO versions had a bug here, they held onto `pthread_t`s for ever (which is illegal) and then
        // used `pthread_equal(pthread_self(), myPthread)`. `pthread_equal` just compares the pointer values which
        // means there's an ABA problem here. This test checks that we don't suffer from that issue now.
        let allELs: NIOLockedValueBox<[any EventLoop]> = NIOLockedValueBox([])

        for _ in 0..<100 {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 4)
            defer {
                #expect(throws: Never.self) {
                    try group.syncShutdownGracefully()
                }
            }
            for loop in group.makeIterator() {
                try! loop.submit {
                    allELs.withLockedValue { allELs in
                        #expect(loop.inEventLoop)
                        for otherEL in allELs {
                            #expect(
                                !otherEL.inEventLoop,
                                "should only be in \(loop) but turns out also in \(otherEL)"
                            )
                        }
                        allELs.append(loop)
                    }
                }.wait()
            }
        }
    }

    @Test
    func testStructuredConcurrencyMTELGStartStop() async throws {
        let loops = try await MultiThreadedEventLoopGroup.withEventLoopGroup(
            numberOfThreads: 3
        ) { group in
            let loops = Array(group.makeIterator()).map { $0 as! SelectableEventLoop }
            for loop in loops {
                #expect(
                    loop.debugDescription.contains("state = open"),
                    Comment(rawValue: loop.debugDescription)
                )
                #expect(
                    loop.debugDescription.contains("selector = Selector { descriptor = -1 }") == false,
                    Comment(rawValue: loop.debugDescription)
                )
            }
            return loops
        }
        #expect(3 == loops.count)
        for loop in loops {
            #expect(
                loop.debugDescription.contains("state = resourcesReclaimed"),
                Comment(rawValue: loop.debugDescription)
            )
            #expect(loop.debugDescription.contains("selector = Selector { descriptor = -1 }"))
        }
    }

    @Test
    func testStructuredConcurrencyMTELGStartStopUserCannotStopMidWay() async throws {
        let threadCount = try await MultiThreadedEventLoopGroup.withEventLoopGroup(
            numberOfThreads: 3
        ) { group in
            do {
                try await group.shutdownGracefully()
                Issue.record("shutdown worked, it shouldn't have")
            } catch EventLoopError.unsupportedOperation {
                // okay
                return Array(group.makeIterator()).count
            }
            return -1
        }
        #expect(3 == threadCount)
    }

    @Test
    func testStructuredConcurrencyMTELGStartStopCanDoBasicAsyncStuff() async throws {
        let actual = try await MultiThreadedEventLoopGroup.withEventLoopGroup(
            numberOfThreads: 3
        ) { group in
            try await group.any().scheduleTask(in: .milliseconds(10), { "cool" }).futureResult.get()
        }
        #expect("cool" == actual)
    }

    @Test
    func testRegressionSelectableEventLoopDeadlock() throws {
        let iterations = 1_000
        let loop = MultiThreadedEventLoopGroup.singleton.next() as! SelectableEventLoop
        let threadsReadySem = DispatchSemaphore(value: 0)
        let go = DispatchSemaphore(value: 0)

        let scheduleds = NIOThreadPool.singleton.runIfActive(eventLoop: loop) {
            threadsReadySem.signal()
            go.wait()
            var tasks: [Scheduled<()>] = []
            for _ in 0..<iterations {
                tasks.append(loop.scheduleTask(in: .milliseconds(1)) {})
            }
            return tasks
        }

        let descriptions = NIOThreadPool.singleton.runIfActive(eventLoop: loop) {
            threadsReadySem.signal()
            go.wait()
            var descriptions: [String] = []
            for _ in 0..<iterations {
                descriptions.append(loop.debugDescription)
            }
            return descriptions
        }

        threadsReadySem.wait()
        threadsReadySem.wait()
        go.signal()
        go.signal()
        let scheduledsCount = try scheduleds.wait().map { $0.cancel() }.count
        #expect(iterations == scheduledsCount)
        let descriptionsCount = try descriptions.wait().count
        #expect(iterations == descriptionsCount)
    }
}

private final class EventLoopWithPreSucceededFuture: EventLoop {
    var inEventLoop: Bool {
        true
    }

    func execute(_ task: @escaping () -> Void) {
        preconditionFailure("not implemented")
    }

    func submit<T>(_ task: @escaping () throws -> T) -> EventLoopFuture<T> {
        preconditionFailure("not implemented")
    }

    var now: NIODeadline {
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

    // We'd need to use an IUO here in order to use a loop-bound here (self needs to be initialized
    // to create the loop-bound box). That'd require the use of unchecked Sendable. A locked value
    // box is fine, it's only tests.
    private let _succeededVoidFuture: NIOLockedValueBox<EventLoopFuture<Void>?>

    func makeSucceededVoidFuture() -> EventLoopFuture<Void> {
        guard self.inEventLoop, let voidFuture = self._succeededVoidFuture.withLockedValue({ $0 }) else {
            return self.makeSucceededFuture(())
        }
        return voidFuture
    }

    init() {
        self._succeededVoidFuture = NIOLockedValueBox(nil)
        self._succeededVoidFuture.withLockedValue {
            $0 = EventLoopFuture(eventLoop: self, value: ())
        }
    }

    func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping @Sendable (Error?) -> Void) {
        self._succeededVoidFuture.withLockedValue { $0 = nil }
        queue.async {
            callback(nil)
        }
    }
}

private final class EventLoopWithoutPreSucceededFuture: EventLoop {
    var inEventLoop: Bool {
        true
    }

    func execute(_ task: @escaping () -> Void) {
        preconditionFailure("not implemented")
    }

    func submit<T>(_ task: @escaping () throws -> T) -> EventLoopFuture<T> {
        preconditionFailure("not implemented")
    }

    var now: NIODeadline {
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

    func shutdownGracefully(queue: DispatchQueue, _ callback: @Sendable @escaping (Error?) -> Void) {
        queue.async {
            callback(nil)
        }
    }
}

final class EventLoopGroupOf3WithoutAnAnyImplementation: EventLoopGroup {
    private let eventloops = [EmbeddedEventLoop(), EmbeddedEventLoop(), EmbeddedEventLoop()]
    private let nextID = ManagedAtomic<UInt64>(0)

    func next() -> EventLoop {
        self.eventloops[Int(self.nextID.loadThenWrappingIncrement(ordering: .relaxed) % UInt64(self.eventloops.count))]
    }

    func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        let g = DispatchGroup()

        for el in self.eventloops {
            g.enter()
            el.shutdownGracefully(queue: queue) { error in
                #expect(error == nil)
                g.leave()
            }
        }

        g.notify(queue: queue) {
            callback(nil)
        }
    }

    func makeIterator() -> EventLoopIterator {
        .init(self.eventloops)
    }
}
