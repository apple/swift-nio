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


class ChannelLifecycleHandler: ChannelInboundHandler {
    public typealias InboundIn = Any

    public enum ChannelState {
        case unregistered
        case inactive
        case active
    }

    public var currentState: ChannelState
    public var stateHistory: [ChannelState]

    public init() {
        currentState = .unregistered
        stateHistory = [.unregistered]
    }

    public func channelRegistered(ctx: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .unregistered)
        XCTAssertFalse(ctx.channel!.isActive)
        currentState = .inactive
        stateHistory.append(.inactive)
        ctx.fireChannelRegistered()
    }

    public func channelActive(ctx: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .inactive)
        XCTAssertTrue(ctx.channel!.isActive)
        currentState = .active
        stateHistory.append(.active)
        ctx.fireChannelActive()
    }

    public func channelInactive(ctx: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .active)
        XCTAssertFalse(ctx.channel!.isActive)
        currentState = .inactive
        stateHistory.append(.inactive)
        ctx.fireChannelInactive()
    }

    public func channelUnregistered(ctx: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .inactive)
        XCTAssertFalse(ctx.channel!.isActive)
        currentState = .unregistered
        stateHistory.append(.unregistered)
        ctx.fireChannelUnregistered()
    }
}

public class ChannelTests: XCTestCase {
    func testBasicLifecycle() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        var serverAcceptedChannel: Channel? = nil
        let serverLifecycleHandler = ChannelLifecycleHandler()
        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                serverAcceptedChannel = channel
                return channel.pipeline.add(handler: serverLifecycleHandler)
            })).bind(to: "127.0.0.1", on: 0).wait()

        let clientLifecycleHandler = ChannelLifecycleHandler()
        let clientChannel = try ClientBootstrap(group: group)
            .handler(handler: clientLifecycleHandler)
            .connect(to: serverChannel.localAddress!).wait()

        var buffer = clientChannel.allocator.buffer(capacity: 1)
        buffer.write(string: "a")
        try clientChannel.writeAndFlush(data: NIOAny(buffer)).wait()

        // Start shutting stuff down.
        try clientChannel.close().wait()

        // Wait for the close promises. These fire last.
        try EventLoopFuture<Void>.andAll([clientChannel.closeFuture, serverAcceptedChannel!.closeFuture], eventLoop: group.next()).then { _ in
            XCTAssertEqual(clientLifecycleHandler.currentState, .unregistered)
            XCTAssertEqual(serverLifecycleHandler.currentState, .unregistered)
            XCTAssertEqual(clientLifecycleHandler.stateHistory, [.unregistered, .inactive, .active, .inactive, .unregistered])
            XCTAssertEqual(serverLifecycleHandler.stateHistory, [.unregistered, .inactive, .active, .inactive, .unregistered])
        }.wait()
    }

    func testManyManyWrites() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(to: "127.0.0.1", on: 0).wait()

        let clientChannel = try ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait()

        // We're going to try to write loads, and loads, and loads of data. In this case, one more
        // write than the iovecs max.
        for _ in 0...Socket.writevLimitIOVectors {
            var buffer = clientChannel.allocator.buffer(capacity: 1)
            buffer.write(string: "a")
            clientChannel.write(data: NIOAny(buffer), promise: nil)
        }
        try clientChannel.flush().wait()

        // Start shutting stuff down.
        try clientChannel.close().wait()
    }

    func testWritevLotsOfData() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(to: "127.0.0.1", on: 0).wait()

        let clientChannel = try ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait()

        let bufferSize = 1024 * 1024 * 2
        var buffer = clientChannel.allocator.buffer(capacity: bufferSize)
        for _ in 0..<bufferSize {
            buffer.write(staticString: "a")
        }

        var written = 0
        while written <= Int(INT32_MAX) {
            clientChannel.write(data: NIOAny(buffer), promise: nil)
            written += bufferSize
        }

        do {
            _ = try clientChannel.flush().wait()
        } catch let error {
            XCTFail("Error occured: \(error)")
        }

        // Start shutting stuff down.
        try clientChannel.close().wait()
    }

    func testParentsOfSocketChannels() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }

        let childChannelPromise: EventLoopPromise<Channel> = group.next().newPromise()
        let serverChannel = try ServerBootstrap(group: group)
            .option(option: ChannelOptions.Socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .handler(childHandler: ChannelInitializer(initChannel: { channel in
                childChannelPromise.succeed(result: channel)
                return channel.eventLoop.newSucceedFuture(result: ())
            })).bind(to: "127.0.0.1", on: 0).wait()

        let clientChannel = try ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait()

        // Check the child channel has a parent, and that that parent is the server channel.
        childChannelPromise.futureResult.whenComplete {
            switch $0 {
            case .success(let chan):
                XCTAssertTrue(chan.parent === serverChannel)
            case .failure(let err):
                XCTFail("Unexpected error \(err)")
            }
        }
        _ = try childChannelPromise.futureResult.wait()

        // Neither the server nor client channels have parents.
        XCTAssertNil(serverChannel.parent)
        XCTAssertNil(clientChannel.parent)

        // Start shutting stuff down.
        try clientChannel.close().wait()
    }

    private func withPendingWritesManager(_ fn: (PendingWritesManager) throws -> Void) rethrows {
        try withExtendedLifetime(NSObject()) { o in
            var iovecs: [IOVector] = Array(repeating: iovec(), count: Socket.writevLimitIOVectors + 1)
            var managed: [Unmanaged<AnyObject>] = Array(repeating: Unmanaged.passUnretained(o), count: Socket.writevLimitIOVectors + 1)
            /* put a canary value at the end */
            iovecs[iovecs.count - 1] = iovec(iov_base: UnsafeMutableRawPointer(bitPattern: 0xdeadbeef), iov_len: 0xdeadbeef)
            try iovecs.withUnsafeMutableBufferPointer { iovecs in
                try managed.withUnsafeMutableBufferPointer { managed in
                    let pwm = NIO.PendingWritesManager(iovecs: iovecs, storageRefs: managed)
                    XCTAssertTrue(pwm.isEmpty)
                    XCTAssertFalse(pwm.closed)
                    XCTAssertFalse(pwm.isFlushPending)
                    XCTAssertTrue(pwm.isWritable)

                    try fn(pwm)

                    XCTAssertTrue(pwm.isEmpty)
                    XCTAssertFalse(pwm.isFlushPending)
                }
            }
            /* assert that the canary values are still okay, we should definitely have never written those */
            XCTAssertEqual(managed.last!.toOpaque(), Unmanaged.passUnretained(o).toOpaque())
            XCTAssertEqual(0xdeadbeef, Int(bitPattern: iovecs.last!.iov_base))
            XCTAssertEqual(0xdeadbeef, iovecs.last!.iov_len)
        }
    }

    /// A frankenstein testing monster. It asserts that for `PendingWritesManager` `pwm` and `EventLoopPromises` `promises`
    /// the following conditions hold:
    ///  - The 'single write operation' is called `exepectedSingleWritabilities.count` number of times with the respective buffer lenghts in the array.
    ///  - The 'vector write operation' is called `exepectedVectorWritabilities.count` number of times with the respective buffer lenghts in the array.
    ///  - after calling the write operations, the promises have the states in `promiseStates`
    ///
    /// The write operations will all be faked and return the return values provided in `returns`.
    ///
    /// - parameters:
    ///     - pwm: The `PendingWritesManager` to test.
    ///     - promises: The promises for the writes issued.
    ///     - expectedSingleWritabilities: The expected buffer lengths for the calls to the single write operation.
    ///     - expectedVectorWritabilities: The expected buffer lengths for the calls to the vector write operation.
    ///     - returns: The return values of the fakes write operations (both single and vector).
    ///     - promiseStates: The states of the promises _after_ the write operations are done.
    func assertExpectedWritability(pendingWritesManager pwm: PendingWritesManager,
                                   promises: [EventLoopPromise<()>],
                                   expectedSingleWritabilities: [Int]?,
                                   expectedVectorWritabilities: [[Int]]?,
                                   expectedFileWritabilities: [(Int, Int)]?,
                                   returns: [IOResult<Int>],
                                   promiseStates: [[Bool]],
                                   file: StaticString = #file,
                                   line: UInt = #line) -> WriteResult {
        var everythingState = 0
        var singleState = 0
        var multiState = 0
        var fileState = 0
        let (result, _) = try! pwm.triggerAppropriateWriteOperation(singleWriteOperation: { buf in
            defer {
                singleState += 1
                everythingState += 1
            }
            if let expected = expectedSingleWritabilities {
                if expected.count > singleState {
                    XCTAssertGreaterThan(returns.count, everythingState)
                    XCTAssertEqual(expected[singleState], buf.count, "in single write \(singleState) (overall \(everythingState)), \(expected[singleState]) bytes expected but \(buf.count) actual")
                    return returns[everythingState]
                } else {
                    XCTFail("single write call \(singleState) but less than \(expected.count) expected", file: file, line: line)
                    return IOResult.wouldBlock(-1 * (everythingState + 1))
                }
            } else {
                XCTFail("single write called on \(buf) but no single writes expected", file: file, line: line)
                return IOResult.wouldBlock(-1 * (everythingState + 1))
            }
        }, vectorWriteOperation: { ptrs in
            defer {
                multiState += 1
                everythingState += 1
            }
            if let expected = expectedVectorWritabilities {
                if expected.count > multiState {
                    XCTAssertGreaterThan(returns.count, everythingState)
                    XCTAssertEqual(expected[multiState], ptrs.map { $0.iov_len },
                                   "in vector write \(multiState) (overall \(everythingState)), \(expected[multiState]) byte counts expected but \(ptrs.map { $0.iov_len }) actual",
                        file: file, line: line)
                    return returns[everythingState]
                } else {
                    XCTFail("vector write call \(multiState) but less than \(expected.count) expected", file: file, line: line)
                    return IOResult.wouldBlock(-1 * (everythingState + 1))
                }
            } else {
                XCTFail("vector write called on \(ptrs) but no vector writes expected",
                    file: file, line: line)
                return IOResult.wouldBlock(-1 * (everythingState + 1))
            }
        }, fileWriteOperation: { _, start, end in
            defer {
                fileState += 1
                everythingState += 1
            }
            guard let expected = expectedFileWritabilities else {
                XCTFail("file write (\(start), \(end)) but no file writes expected",
                    file: file, line: line)
                return IOResult.wouldBlock(-1 * (everythingState + 1))
            }

            if expected.count > fileState {
                XCTAssertGreaterThan(returns.count, everythingState)
                XCTAssertEqual(expected[fileState].0, start,
                               "in file write \(fileState) (overall \(everythingState)), \(expected[fileState].0) expected as start index but \(start) actual",
                    file: file, line: line)
                XCTAssertEqual(expected[fileState].1, end,
                               "in file write \(fileState) (overall \(everythingState)), \(expected[fileState].1) expected as end index but \(end) actual",
                    file: file, line: line)
                return returns[everythingState]
            } else {
                XCTFail("file write call \(fileState) but less than \(expected.count) expected", file: file, line: line)
                return IOResult.wouldBlock(-1 * (everythingState + 1))
            }
        })
        if everythingState > 0 {
            XCTAssertEqual(promises.count, promiseStates[everythingState - 1].count,
                           "number of promises (\(promises.count)) != number of promise states (\(promiseStates[everythingState - 1].count))",
                file: file, line: line)
            _ = zip(promises, promiseStates[everythingState - 1]).map { p, pState in
                XCTAssertEqual(p.futureResult.fulfilled, pState, "promise states incorrect (\(everythingState) callbacks)", file: file, line: line)
            }

            XCTAssertEqual(everythingState, singleState + multiState + fileState,
                           "odd, calls the single/vector/file writes: \(singleState)/\(multiState)/\(fileState) but overall \(everythingState+1)", file: file, line: line)

            if singleState == 0 {
                XCTAssertNil(expectedSingleWritabilities, "no single writes have been done but we expected some")
            } else {
                XCTAssertEqual(singleState, (expectedSingleWritabilities?.count ?? Int.min), "different number of single writes than expected", file: file, line: line)
            }
            if multiState == 0 {
                XCTAssertNil(expectedVectorWritabilities, "no vector writes have been done but we expected some")
            } else {
                XCTAssertEqual(multiState, (expectedVectorWritabilities?.count ?? Int.min), "different number of vector writes than expected", file: file, line: line)
            }
            if fileState == 0 {
                XCTAssertNil(expectedFileWritabilities, "no file writes have been done but we expected some")
            } else {
                XCTAssertEqual(fileState, (expectedFileWritabilities?.count ?? Int.min), "different number of file writes than expected", file: file, line: line)
            }
        } else {
            XCTAssertEqual(0, returns.count, "no callbacks called but apparently \(returns.count) expected", file: file, line: line)
            XCTAssertNil(expectedSingleWritabilities, "no callbacks called but apparently some single writes expected", file: file, line: line)
            XCTAssertNil(expectedVectorWritabilities, "no callbacks calles but apparently some vector writes expected", file: file, line: line)
            XCTAssertNil(expectedFileWritabilities, "no callbacks calles but apparently some file writes expected", file: file, line: line)

            _ = zip(promises, promiseStates[0]).map { p, pState in
                XCTAssertEqual(p.futureResult.fulfilled, pState, "promise states incorrect (no callbacks)", file: file, line: line)
            }
        }
        return result
    }

    /// Tests that writes of empty buffers work correctly and that we don't accidentally write buffers that haven't been flushed.
    func testPendingWritesEmptyWritesWorkAndWeDontWriteUnflushedThings() {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)

        withPendingWritesManager { pwm in
            buffer.clear()
            let ps: [EventLoopPromise<()>] = (0..<2).map { _ in el.newPromise() }
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])

            XCTAssertFalse(pwm.isEmpty)
            XCTAssertFalse(pwm.isFlushPending)

            pwm.markFlushCheckpoint(promise: nil)

            XCTAssertFalse(pwm.isEmpty)
            XCTAssertTrue(pwm.isFlushPending)

            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])

            var result = assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: [0],
                                                   expectedVectorWritabilities: nil,
                                                   expectedFileWritabilities: nil,
                                                   returns: [.processed(0)],
                                                   promiseStates: [[true, false]])

            XCTAssertFalse(pwm.isEmpty)
            XCTAssertFalse(pwm.isFlushPending)
            XCTAssertEqual(.writtenCompletely, result)

            result = assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: nil,
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: nil,
                                               returns: [],
                                               promiseStates: [[true, false]])
            XCTAssertEqual(WriteResult.nothingToBeWritten, result)

            pwm.markFlushCheckpoint(promise: nil)

            result = assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: [0],
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: nil,
                                               returns: [.processed(0)],
                                               promiseStates: [[true, true]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)
        }
    }

    /// This tests that we do use the vector write operation if we have more than one flushed and still doesn't write unflushed buffers
    func testPendingWritesUsesVectorWriteOperationAndDoesntWriteTooMuch() {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        let emptyBuffer = buffer
        _ = buffer.write(string: "1234")

        withPendingWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<3).map { _ in el.newPromise() }
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            pwm.markFlushCheckpoint(promise: nil)
            _ = pwm.add(data: .byteBuffer(emptyBuffer), promise: ps[2])

            var result = assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: [[4, 4]],
                                                   expectedFileWritabilities: nil,
                                                   returns: [.processed(8)],
                                                   promiseStates: [[true, true, false]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)

            pwm.markFlushCheckpoint(promise: nil)

            result = assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: [0],
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: nil,
                                               returns: [.processed(0)],
                                               promiseStates: [[true, true, true]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)
        }
    }

    /// Tests that we can handle partial writes correctly.
    func testPendingWritesWorkWithPartialWrites() {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        _ = buffer.write(string: "1234")

        withPendingWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<4).map { _ in el.newPromise() }
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[2])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[3])
            pwm.markFlushCheckpoint(promise: nil)

            var result = assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: [[4, 4, 4, 4], [3, 4, 4, 4]],
                                                   expectedFileWritabilities: nil,
                                                   returns: [.processed(1), .wouldBlock(0)],
                promiseStates: [[false, false, false, false], [false, false, false, false]])

            XCTAssertEqual(WriteResult.wouldBlock, result)
            result = assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: nil,
                                               expectedVectorWritabilities: [[3, 4, 4, 4], [4, 4]],
                                               expectedFileWritabilities: nil,
                                               returns: [.processed(7), .wouldBlock(0)],
                                               promiseStates: [[true, true, false, false], [true, true, false, false]]

                                               )
            XCTAssertEqual(WriteResult.wouldBlock, result)

            result = assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: nil,
                                               expectedVectorWritabilities: [[4, 4]],
                                               expectedFileWritabilities: nil,
                                               returns: [.processed(8)],
                                               promiseStates: [[true, true, true, true], [true, true, true, true]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)
        }
    }

    /// Tests that the spin count works for one long buffer if small bits are written one by one.
    func testPendingWritesSpinCountWorksForSingleWrites() {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)

        withPendingWritesManager { pwm in
            let numberOfBytes = Int(pwm.writeSpinCount + 1 /* so one byte remains at the end */)
            buffer.clear()
            buffer.write(bytes: Array<UInt8>(repeating: 0xff, count: numberOfBytes))
            let ps: [EventLoopPromise<()>] = (0..<1).map { _ in el.newPromise() }
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            pwm.markFlushCheckpoint(promise: nil)

            /* below, we'll write 1 byte at a time. So the number of bytes offered should decrease by one.
               The write operation should be repeated until we did it 1 + spin count times and then return `.writtenPartially`.
               After that, one byte will remain */
            var result = assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: Array((2...numberOfBytes).reversed()),
                                                   expectedVectorWritabilities: nil,
                                                   expectedFileWritabilities: nil,
                                                   returns: Array(repeating: .processed(1), count: numberOfBytes),
                                                   promiseStates: Array(repeating: [false], count: numberOfBytes))
            XCTAssertEqual(.writtenPartially, result)

            /* we'll now write the one last byte and assert that all the writes are complete */
            result = assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: [1],
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: nil,
                                               returns: [.processed(1)],
                                               promiseStates: [[true]])
            XCTAssertEqual(.writtenCompletely, result)
        }
    }

    /// Tests that the spin count works if we have many small buffers, which'll be written with the vector write op.
    func testPendingWritesSpinCountWorksForVectorWrites() {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)

        withPendingWritesManager { pwm in
            let numberOfBytes = Int(pwm.writeSpinCount + 1 /* so one byte remains at the end */)
            buffer.clear()
            buffer.write(bytes: [0xff] as [UInt8])
            let ps: [EventLoopPromise<()>] = (0..<numberOfBytes).map { _ in
                let p: EventLoopPromise<()> = el.newPromise()
                _ = pwm.add(data: .byteBuffer(buffer), promise: p)
                return p
            }
            pwm.markFlushCheckpoint(promise: nil)

            /* this will create an `Array` like this (for `numberOfBytes == 4`)
             `[[1, 1, 1, 1], [1, 1, 1], [1, 1], [1]]`
             */
            let expectedVectorWrites = Array((2...numberOfBytes).reversed()).map { n in
                return Array(repeating: 1, count: n)
            }

            /* this will create an `Array` like this (for `numberOfBytes == 4`)
               `[[true, false, false, false], [true, true, false, false], [true, true, true, false]`
            */
            let expectedPromiseStates = Array((2...numberOfBytes).reversed()).map { n in
                Array(repeating: true, count: numberOfBytes - n + 1) + Array(repeating: false, count: n - 1)
            }

            /* below, we'll write 1 byte at a time. So the number of bytes offered should decrease by one.
             The write operation should be repeated until we did it 1 + spin count times and then return `.writtenPartially`.
             After that, one byte will remain */
            var result = assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: expectedVectorWrites,
                                                   expectedFileWritabilities: nil,
                                                   returns: Array(repeating: .processed(1), count: numberOfBytes),
                                                   promiseStates: expectedPromiseStates)
            XCTAssertEqual(.writtenPartially, result)

            /* we'll now write the one last byte and assert that all the writes are complete */
            result = assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: [1],
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: nil,
                                               returns: [.processed(1)],
                                               promiseStates: [Array(repeating: true, count: numberOfBytes)])
            XCTAssertEqual(.writtenCompletely, result)
        }
    }

    /// Test that cancellation of the Channel writes works correctly.
    func testPendingWritesCancellationWorksCorrectly() {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        let emptyBuffer = buffer
        _ = buffer.write(string: "1234")

        withPendingWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<3).map { _ in el.newPromise() }
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            pwm.markFlushCheckpoint(promise: nil)
            _ = pwm.add(data: .byteBuffer(emptyBuffer), promise: ps[2])

            let result = assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: [[4, 4], [2, 4]],
                                                   expectedFileWritabilities: nil,
                                                   returns: [.processed(2), .wouldBlock(0)],
                                                   promiseStates: [[false, false, false], [false, false, false]])
            XCTAssertEqual(WriteResult.wouldBlock, result)

            pwm.failAll(error: ChannelError.operationUnsupported)

            XCTAssertTrue(ps.map { $0.futureResult.fulfilled }.reduce(true) { $0 && $1 })
        }
    }

    /// Test that with a few massive buffers, we don't offer more than we should to `writev` if the individual chunks fit.
    func testPendingWritesNoMoreThanWritevLimitIsWritten() {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator(hookedMalloc: { _ in return UnsafeMutableRawPointer(bitPattern: 0xdeadbeef) },
                                        hookedRealloc: { _, _ in return UnsafeMutableRawPointer(bitPattern: 0xdeadbeef) },
                                        hookedFree: { _ in },
                                        hookedMemcpy: { _, _, _ in })
        /* each buffer is half the writev limit */
        let halfTheWriteVLimit = Socket.writevLimitBytes / 2
        var buffer = alloc.buffer(capacity: halfTheWriteVLimit)
        buffer.moveReaderIndex(to: 0)
        buffer.moveWriterIndex(to: halfTheWriteVLimit)

        withPendingWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<3).map { _ in el.newPromise() }
            /* add 1.5x the writev limit */
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[2])
            pwm.markFlushCheckpoint(promise: nil)

            let result = assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: [[halfTheWriteVLimit, halfTheWriteVLimit], [halfTheWriteVLimit]],
                                                   expectedFileWritabilities: nil,
                                                   returns: [.processed(2 * halfTheWriteVLimit), .processed(halfTheWriteVLimit)],
                                                   promiseStates: [[true, true, false], [true, true, true]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)
        }
    }

    /// Test that with a massive buffers (bigger than writev size), we don't offer more than we should to `writev`.
    func testPendingWritesNoMoreThanWritevLimitIsWrittenInOneMassiveChunk() {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator(hookedMalloc: { _ in return UnsafeMutableRawPointer(bitPattern: 0xdeadbeef) },
                                        hookedRealloc: { _, _ in return UnsafeMutableRawPointer(bitPattern: 0xdeadbeef) },
                                        hookedFree: { _ in },
                                        hookedMemcpy: { _, _, _ in })
        /* each buffer is half the writev limit */
        let biggerThanWriteV = Socket.writevLimitBytes + 23
        var buffer = alloc.buffer(capacity: biggerThanWriteV)
        buffer.moveReaderIndex(to: 0)
        buffer.moveWriterIndex(to: biggerThanWriteV)

        withPendingWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<3).map { _ in el.newPromise() }
            /* add 1.5x the writev limit */
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            buffer.moveWriterIndex(to: 100)
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[2])

            let flushPromise1: EventLoopPromise<()> = el.newPromise()
            pwm.markFlushCheckpoint(promise: flushPromise1)

            let result = assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: [[Socket.writevLimitBytes],
                                                                                 [23],
                                                                                 [Socket.writevLimitBytes],
                                                                                 [23, 100]],
                                                   expectedFileWritabilities: nil,
                                                   returns: [ .processed(Socket.writevLimitBytes),
                                                    /*Xcode*/ .processed(23),
                                                    /*needs*/ .processed(Socket.writevLimitBytes),
                                                    /*help */ .processed(23 + 100)],
                                                   promiseStates: [[false, false, false],
                                                    /*  Xcode   */ [true, false, false],
                                                    /*  needs   */ [true, false, false],
                                                    /*  help    */ [true, true, true]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)
            XCTAssertTrue(flushPromise1.futureResult.fulfilled)

            let emptyFlushPromise: EventLoopPromise<()> = el.newPromise()
            pwm.markFlushCheckpoint(promise: emptyFlushPromise)
        }
    }

    func testPendingWritesFileRegion() {
        let el = EmbeddedEventLoop()
        withPendingWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<2).map { _ in el.newPromise() }

            _ = pwm.add(data: .fileRegion(FileRegion(descriptor: -1, readerIndex: 12, endIndex: 14)), promise: ps[0])
            pwm.markFlushCheckpoint(promise: nil)
            _ = pwm.add(data: .fileRegion(FileRegion(descriptor: -2, readerIndex: 0, endIndex: 2)), promise: ps[1])

            var result = assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: nil,
                                                   expectedFileWritabilities: [(12, 14)],
                                                   returns: [.processed(2)],
                                                   promiseStates: [[true, false]])
            XCTAssertEqual(.writtenCompletely, result)

            result = assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: nil,
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: nil,
                                               returns: [],
                                               promiseStates: [[true, false]])
            XCTAssertEqual(WriteResult.nothingToBeWritten, result)

            pwm.markFlushCheckpoint(promise: nil)

            result = assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: nil,
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: [(0, 2), (1, 2)],
                                               returns: [.processed(1), .processed(1)],
                                               promiseStates: [[true, false], [true, true]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)
        }
    }

    func testPendingWritesEmptyFileRegion() {
        let el = EmbeddedEventLoop()
        withPendingWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<1).map { _ in el.newPromise() }

            _ = pwm.add(data: .fileRegion(FileRegion(descriptor: -1, readerIndex: 99, endIndex: 99)), promise: ps[0])
            pwm.markFlushCheckpoint(promise: nil)

            let result = assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: nil,
                                                   expectedFileWritabilities: [(99, 99)],
                                                   returns: [.processed(0)],
                                                   promiseStates: [[true]])
            XCTAssertEqual(.writtenCompletely, result)
        }
    }

    func testPendingWritesInterleavedBuffersAndFiles() {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        _ = buffer.write(string: "1234")

        withPendingWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<5).map { _ in el.newPromise() }

            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            _ = pwm.add(data: .fileRegion(FileRegion(descriptor: -1, readerIndex: 99, endIndex: 99)), promise: ps[2])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[3])
            _ = pwm.add(data: .fileRegion(FileRegion(descriptor: -1, readerIndex: 0, endIndex: 10)), promise: ps[4])

            pwm.markFlushCheckpoint(promise: nil)

            var result = assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: [[4, 4]],
                                                   expectedFileWritabilities: nil,
                                                   returns: [.processed(8)],
                                                   promiseStates: [[true, true, false, false, false]])
            XCTAssertEqual(.writtenCompletely, result)

            result = assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: nil,
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: [(99, 99)],
                                               returns: [.processed(0)],
                                               promiseStates: [[true, true, true, false, false]])
            XCTAssertEqual(.writtenCompletely, result)

            result = assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: [4, 3, 2, 1],
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: nil,
                                               returns: [.processed(1), .processed(1), .processed(1), .processed(1)],
                                               promiseStates: [[true, true, true, false, false],
                                                               [true, true, true, false, false],
                                                               [true, true, true, false, false],
                                                               [true, true, true, true, false]])
            XCTAssertEqual(.writtenCompletely, result)

            result = assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: nil,
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: [(0, 10), (3, 10), (6, 10)],
                                               returns: [.wouldBlock(3), .processed(3), .wouldBlock(0)],
                                               promiseStates: [[true, true, true, true, false],
                                                               [true, true, true, true, false],
                                                               [true, true, true, true, false]])
            XCTAssertEqual(.wouldBlock, result)

            result = assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: nil,
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: [(6, 10)],
                                               returns: [.processed(4)],
                                               promiseStates: [[true, true, true, true, true]])
            XCTAssertEqual(.writtenCompletely, result)
        }
    }

    func testPendingWritesFlushPromiseWorksWithoutWritePromises() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        _ = buffer.write(string: "1234")

        withPendingWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<2).map { _ in el.newPromise() }

            pwm.markFlushCheckpoint(promise: ps[0])

            /* let's start with no writes and just a promise */
            var result = assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: nil,
                                                   expectedFileWritabilities: nil,
                                                   returns: [],
                                                   promiseStates: [[true, false]])

            /* let's add a few writes but still without any promises */
            _ = pwm.add(data: .byteBuffer(buffer), promise: nil)
            _ = pwm.add(data: .byteBuffer(buffer), promise: nil)
            _ = pwm.add(data: .fileRegion(FileRegion(descriptor: -1, readerIndex: 99, endIndex: 99)), promise: nil)
            _ = pwm.add(data: .byteBuffer(buffer), promise: nil)
            _ = pwm.add(data: .fileRegion(FileRegion(descriptor: -1, readerIndex: 0, endIndex: 10)), promise: nil)

            pwm.markFlushCheckpoint(promise: ps[1])

            result = assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: nil,
                                               expectedVectorWritabilities: [[4, 4]],
                                               expectedFileWritabilities: nil,
                                               returns: [.processed(8)],
                                               promiseStates: [[true, false]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)
            result = assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: nil,
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: [(99, 99)],
                                               returns: [.processed(0)],
                                               promiseStates: [[true, false]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)
            result = assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: [4],
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: nil,
                                               returns: [.processed(4)],
                                               promiseStates: [[true, false]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)
            result = assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: nil,
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: [(0, 10)],
                                               returns: [.processed(10)],
                                               promiseStates: [[true, true]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)
        }
    }

    func testPendingWritesWorksWithManyEmptyWrites() {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        let emptyBuffer = alloc.buffer(capacity: 12)

        withPendingWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<3).map { _ in el.newPromise() }
            _ = pwm.add(data: .byteBuffer(emptyBuffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(emptyBuffer), promise: ps[1])
            pwm.markFlushCheckpoint(promise: nil)
            _ = pwm.add(data: .byteBuffer(emptyBuffer), promise: ps[2])

            var result = assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: [[0, 0]],
                                                   expectedFileWritabilities: nil,
                                                   returns: [.processed(0)],
                                                   promiseStates: [[true, true, false]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)

            pwm.markFlushCheckpoint(promise: nil)

            result = assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: [0],
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: nil,
                                               returns: [.processed(0)],
                                               promiseStates: [[true, true, true]])
            XCTAssertEqual(WriteResult.writtenCompletely, result)
        }
    }

    func testPendingWritesCloseDuringVectorWrite() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        buffer.write(string: "1234")

        try withPendingWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<3).map { _ in el.newPromise() }
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            pwm.markFlushCheckpoint(promise: nil)
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[2])

            ps[0].futureResult.whenComplete { _ in
                pwm.failAll(error: ChannelError.eof)
            }

            let result = assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: [[4, 4]],
                                                   expectedFileWritabilities: nil,
                                                   returns: [.processed(4)],
                                                   promiseStates: [[true, true, true]])
            XCTAssertEqual(WriteResult.closed, result)
            XCTAssertNoThrow(try ps[0].futureResult.wait())
            XCTAssertThrowsError(try ps[1].futureResult.wait())
            XCTAssertThrowsError(try ps[2].futureResult.wait())
        }
    }

    func testPendingWritesMoreThanWritevIOVectorLimit() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        buffer.write(string: "1234")

        withPendingWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0...Socket.writevLimitIOVectors).map { _ in el.newPromise() }
            ps.forEach { p in
                _ = pwm.add(data: .byteBuffer(buffer), promise: p)
            }
            let flushPromise: EventLoopPromise<()> = el.newPromise()
            pwm.markFlushCheckpoint(promise: flushPromise)

            var result = assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: [Array(repeating: 4, count: Socket.writevLimitIOVectors), [4]],
                                                   expectedFileWritabilities: nil,
                                                   returns: [.processed(4 * Socket.writevLimitIOVectors), .wouldBlock(0)],
                                                   promiseStates: [Array(repeating: true, count: Socket.writevLimitIOVectors) + [false],
                                                                   Array(repeating: true, count: Socket.writevLimitIOVectors) + [false]])
            XCTAssertEqual(WriteResult.wouldBlock, result)
            XCTAssertFalse(flushPromise.futureResult.fulfilled)
            result = assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: [4],
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: nil,
                                               returns: [.processed(4)],
                                               promiseStates: [Array(repeating: true, count: Socket.writevLimitIOVectors + 1)])
            XCTAssertEqual(WriteResult.writtenCompletely, result)
            XCTAssertTrue(flushPromise.futureResult.fulfilled)
        }
    }

    func testPendingWritesIsHappyWhenSendfileReturnsWouldBlockButWroteFully() {
        let el = EmbeddedEventLoop()
        withPendingWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<1).map { _ in el.newPromise() }

            _ = pwm.add(data: .fileRegion(FileRegion(descriptor: -1, readerIndex: 0, endIndex: 8192)), promise: ps[0])
            pwm.markFlushCheckpoint(promise: nil)

            let result = assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: nil,
                                                   expectedFileWritabilities: [(0, 8192)],
                                                   returns: [.wouldBlock(8192)],
                                                   promiseStates: [[true]])
            XCTAssertEqual(.writtenCompletely, result)
        }
    }
}
