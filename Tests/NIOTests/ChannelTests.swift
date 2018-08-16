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
import NIOConcurrencyHelpers
import Dispatch

class ChannelLifecycleHandler: ChannelInboundHandler {
    public typealias InboundIn = Any

    public enum ChannelState {
        case unregistered
        case registered
        case inactive
        case active
    }

    public var currentState: ChannelState
    public var stateHistory: [ChannelState]

    public init() {
        currentState = .unregistered
        stateHistory = [.unregistered]
    }

    private func updateState(_ state: ChannelState) {
        currentState = state
        stateHistory.append(state)
    }

    public func channelRegistered(ctx: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .unregistered)
        XCTAssertFalse(ctx.channel.isActive)
        updateState(.registered)
        ctx.fireChannelRegistered()
    }

    public func channelActive(ctx: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .registered)
        XCTAssertTrue(ctx.channel.isActive)
        updateState(.active)
        ctx.fireChannelActive()
    }

    public func channelInactive(ctx: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .active)
        XCTAssertFalse(ctx.channel.isActive)
        updateState(.inactive)
        ctx.fireChannelInactive()
    }

    public func channelUnregistered(ctx: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .inactive)
        XCTAssertFalse(ctx.channel.isActive)
        updateState(.unregistered)
        ctx.fireChannelUnregistered()
    }
}

public class ChannelTests: XCTestCase {
    func testBasicLifecycle() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverAcceptedChannelPromise: EventLoopPromise<Channel> = group.next().newPromise()
        let serverLifecycleHandler = ChannelLifecycleHandler()
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                serverAcceptedChannelPromise.succeed(result: channel)
                return channel.pipeline.add(handler: serverLifecycleHandler)
            }.bind(host: "127.0.0.1", port: 0).wait())

        let clientLifecycleHandler = ChannelLifecycleHandler()
        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .channelInitializer({ (channel: Channel) in channel.pipeline.add(handler: clientLifecycleHandler) })
            .connect(to: serverChannel.localAddress!).wait())

        var buffer = clientChannel.allocator.buffer(capacity: 1)
        buffer.write(string: "a")
        try clientChannel.writeAndFlush(NIOAny(buffer)).wait()

        let serverAcceptedChannel = try serverAcceptedChannelPromise.futureResult.wait()

        // Start shutting stuff down.
        XCTAssertNoThrow(try clientChannel.close().wait())

        // Wait for the close promises. These fire last.
        XCTAssertNoThrow(try EventLoopFuture<Void>.andAll([clientChannel.closeFuture,
                                                           serverAcceptedChannel.closeFuture],
                                                          eventLoop: group.next()).map {
            XCTAssertEqual(clientLifecycleHandler.currentState, .unregistered)
            XCTAssertEqual(serverLifecycleHandler.currentState, .unregistered)
            XCTAssertEqual(clientLifecycleHandler.stateHistory, [.unregistered, .registered, .active, .inactive, .unregistered])
            XCTAssertEqual(serverLifecycleHandler.stateHistory, [.unregistered, .registered, .active, .inactive, .unregistered])
        }.wait())
    }

    func testManyManyWrites() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "127.0.0.1", port: 0).wait())

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait())

        // We're going to try to write loads, and loads, and loads of data. In this case, one more
        // write than the iovecs max.
        var buffer = clientChannel.allocator.buffer(capacity: 1)
        for _ in 0..<Socket.writevLimitIOVectors {
            buffer.clear()
            buffer.write(string: "a")
            clientChannel.write(NIOAny(buffer), promise: nil)
        }
        buffer.clear()
        buffer.write(string: "a")
        try clientChannel.writeAndFlush(NIOAny(buffer)).wait()

        // Start shutting stuff down.
        XCTAssertNoThrow(try clientChannel.close().wait())
    }

    func testWritevLotsOfData() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "127.0.0.1", port: 0).wait())

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait())

        let bufferSize = 1024 * 1024 * 2
        var buffer = clientChannel.allocator.buffer(capacity: bufferSize)
        for _ in 0..<bufferSize {
            buffer.write(staticString: "a")
        }
        

        #if arch(arm) // 32-bit, Raspi/AppleWatch/etc
            let lotsOfData = Int(Int32.max / 8)
        #else
            let lotsOfData = Int(Int32.max)
        #endif
        var written = 0
        while written <= lotsOfData {
            clientChannel.write(NIOAny(buffer), promise: nil)
            written += bufferSize
        }

        XCTAssertNoThrow(try clientChannel.writeAndFlush(NIOAny(buffer)).wait())

        // Start shutting stuff down.
        XCTAssertNoThrow(try clientChannel.close().wait())
    }

    func testParentsOfSocketChannels() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let childChannelPromise: EventLoopPromise<Channel> = group.next().newPromise()
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                childChannelPromise.succeed(result: channel)
                return channel.eventLoop.newSucceededFuture(result: ())
            }.bind(host: "127.0.0.1", port: 0).wait())

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait())

        // Check the child channel has a parent, and that that parent is the server channel.
        childChannelPromise.futureResult.map { chan in
                XCTAssertTrue(chan.parent === serverChannel)
        }.whenFailure { err in
                XCTFail("Unexpected error \(err)")
        }
        _ = try childChannelPromise.futureResult.wait()

        // Neither the server nor client channels have parents.
        XCTAssertNil(serverChannel.parent)
        XCTAssertNil(clientChannel.parent)

        // Start shutting stuff down.
        XCTAssertNoThrow(try clientChannel.close().wait())
    }

    private func withPendingStreamWritesManager(_ body: (PendingStreamWritesManager) throws -> Void) rethrows {
        try withExtendedLifetime(NSObject()) { o in
            var iovecs: [IOVector] = Array(repeating: iovec(), count: Socket.writevLimitIOVectors + 1)
            var managed: [Unmanaged<AnyObject>] = Array(repeating: Unmanaged.passUnretained(o), count: Socket.writevLimitIOVectors + 1)
            /* put a canary value at the end */
            iovecs[iovecs.count - 1] = iovec(iov_base: UnsafeMutableRawPointer(bitPattern: 0xdeadbee)!, iov_len: 0xdeadbee)
            try iovecs.withUnsafeMutableBufferPointer { iovecs in
                try managed.withUnsafeMutableBufferPointer { managed in
                    let pwm = NIO.PendingStreamWritesManager(iovecs: iovecs, storageRefs: managed)
                    XCTAssertTrue(pwm.isEmpty)
                    XCTAssertTrue(pwm.isOpen)
                    XCTAssertFalse(pwm.isFlushPending)
                    XCTAssertTrue(pwm.isWritable)

                    try body(pwm)

                    XCTAssertTrue(pwm.isEmpty)
                    XCTAssertFalse(pwm.isFlushPending)
                }
            }
            /* assert that the canary values are still okay, we should definitely have never written those */
            XCTAssertEqual(managed.last!.toOpaque(), Unmanaged.passUnretained(o).toOpaque())
            XCTAssertEqual(0xdeadbee, Int(bitPattern: iovecs.last!.iov_base))
            XCTAssertEqual(0xdeadbee, iovecs.last!.iov_len)
        }
    }

    /// A frankenstein testing monster. It asserts that for `PendingStreamWritesManager` `pwm` and `EventLoopPromises` `promises`
    /// the following conditions hold:
    ///  - The 'single write operation' is called `exepectedSingleWritabilities.count` number of times with the respective buffer lenghts in the array.
    ///  - The 'vector write operation' is called `exepectedVectorWritabilities.count` number of times with the respective buffer lenghts in the array.
    ///  - after calling the write operations, the promises have the states in `promiseStates`
    ///
    /// The write operations will all be faked and return the return values provided in `returns`.
    ///
    /// - parameters:
    ///     - pwm: The `PendingStreamWritesManager` to test.
    ///     - promises: The promises for the writes issued.
    ///     - expectedSingleWritabilities: The expected buffer lengths for the calls to the single write operation.
    ///     - expectedVectorWritabilities: The expected buffer lengths for the calls to the vector write operation.
    ///     - returns: The return values of the fakes write operations (both single and vector).
    ///     - promiseStates: The states of the promises _after_ the write operations are done.
    func assertExpectedWritability(pendingWritesManager pwm: PendingStreamWritesManager,
                                   promises: [EventLoopPromise<Void>],
                                   expectedSingleWritabilities: [Int]?,
                                   expectedVectorWritabilities: [[Int]]?,
                                   expectedFileWritabilities: [(Int, Int)]?,
                                   returns: [IOResult<Int>],
                                   promiseStates: [[Bool]],
                                   file: StaticString = #file,
                                   line: UInt = #line) throws -> OverallWriteResult {
        var everythingState = 0
        var singleState = 0
        var multiState = 0
        var fileState = 0
        let (result, _) = try pwm.triggerAppropriateWriteOperations(scalarBufferWriteOperation: { buf in
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
        }, vectorBufferWriteOperation: { ptrs in
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
        }, scalarFileWriteOperation: { _, start, end in
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
                XCTAssertEqual(p.futureResult.isFulfilled, pState, "promise states incorrect (\(everythingState) callbacks)", file: file, line: line)
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
                XCTAssertEqual(p.futureResult.isFulfilled, pState, "promise states incorrect (no callbacks)", file: file, line: line)
            }
        }
        return result
    }

    /// Tests that writes of empty buffers work correctly and that we don't accidentally write buffers that haven't been flushed.
    func testPendingWritesEmptyWritesWorkAndWeDontWriteUnflushedThings() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)

        try withPendingStreamWritesManager { pwm in
            buffer.clear()
            let ps: [EventLoopPromise<Void>] = (0..<2).map { (_: Int) in el.newPromise() }
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])

            XCTAssertFalse(pwm.isEmpty)
            XCTAssertFalse(pwm.isFlushPending)

            pwm.markFlushCheckpoint()

            XCTAssertFalse(pwm.isEmpty)
            XCTAssertTrue(pwm.isFlushPending)

            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])

            var result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                       promises: ps,
                                                       expectedSingleWritabilities: [0],
                                                       expectedVectorWritabilities: nil,
                                                       expectedFileWritabilities: nil,
                                                       returns: [.processed(0)],
                                                       promiseStates: [[true, false]])

            XCTAssertFalse(pwm.isEmpty)
            XCTAssertFalse(pwm.isFlushPending)
            XCTAssertEqual(.writtenCompletely, result)

            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: nil,
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: nil,
                                               returns: [],
                                               promiseStates: [[true, false]])
            XCTAssertEqual(OverallWriteResult.writtenCompletely, result)

            pwm.markFlushCheckpoint()

            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: [0],
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: nil,
                                               returns: [.processed(0)],
                                               promiseStates: [[true, true]])
            XCTAssertEqual(OverallWriteResult.writtenCompletely, result)
        }
    }

    /// This tests that we do use the vector write operation if we have more than one flushed and still doesn't write unflushed buffers
    func testPendingWritesUsesVectorWriteOperationAndDoesntWriteTooMuch() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        let emptyBuffer = buffer
        _ = buffer.write(string: "1234")

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<3).map { (_: Int) in el.newPromise() }
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            pwm.markFlushCheckpoint()
            _ = pwm.add(data: .byteBuffer(emptyBuffer), promise: ps[2])

            var result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: [[4, 4]],
                                                   expectedFileWritabilities: nil,
                                                   returns: [.processed(8)],
                                                   promiseStates: [[true, true, false]])
            XCTAssertEqual(.writtenCompletely, result)

            pwm.markFlushCheckpoint()

            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: [0],
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: nil,
                                               returns: [.processed(0)],
                                               promiseStates: [[true, true, true]])
            XCTAssertEqual(.writtenCompletely, result)
        }
    }

    /// Tests that we can handle partial writes correctly.
    func testPendingWritesWorkWithPartialWrites() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        _ = buffer.write(string: "1234")

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<4).map { (_: Int) in el.newPromise() }
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[2])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[3])
            pwm.markFlushCheckpoint()

            var result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: [[4, 4, 4, 4], [3, 4, 4, 4]],
                                                   expectedFileWritabilities: nil,
                                                   returns: [.processed(1), .wouldBlock(0)],
                promiseStates: [[false, false, false, false], [false, false, false, false]])

            XCTAssertEqual(.couldNotWriteEverything, result)
            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: nil,
                                               expectedVectorWritabilities: [[3, 4, 4, 4], [4, 4]],
                                               expectedFileWritabilities: nil,
                                               returns: [.processed(7), .wouldBlock(0)],
                                               promiseStates: [[true, true, false, false], [true, true, false, false]]

                                               )
            XCTAssertEqual(.couldNotWriteEverything, result)

            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: nil,
                                               expectedVectorWritabilities: [[4, 4]],
                                               expectedFileWritabilities: nil,
                                               returns: [.processed(8)],
                                               promiseStates: [[true, true, true, true], [true, true, true, true]])
            XCTAssertEqual(.writtenCompletely, result)
        }
    }

    /// Tests that the spin count works for one long buffer if small bits are written one by one.
    func testPendingWritesSpinCountWorksForSingleWrites() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)

        try withPendingStreamWritesManager { pwm in
            let numberOfBytes = Int(1 /* first write */ + pwm.writeSpinCount /* the spins */ + 1 /* so one byte remains at the end */)
            buffer.clear()
            buffer.write(bytes: Array<UInt8>(repeating: 0xff, count: numberOfBytes))
            let ps: [EventLoopPromise<Void>] = (0..<1).map { (_: Int) in el.newPromise() }
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            pwm.markFlushCheckpoint()

            /* below, we'll write 1 byte at a time. So the number of bytes offered should decrease by one.
               The write operation should be repeated until we did it 1 + spin count times and then return `.writtenPartially`.
               After that, one byte will remain */
            var result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: Array((2...numberOfBytes).reversed()),
                                                   expectedVectorWritabilities: nil,
                                                   expectedFileWritabilities: nil,
                                                   returns: Array(repeating: .processed(1), count: numberOfBytes),
                                                   promiseStates: Array(repeating: [false], count: numberOfBytes))
            XCTAssertEqual(.couldNotWriteEverything, result)

            /* we'll now write the one last byte and assert that all the writes are complete */
            result = try assertExpectedWritability(pendingWritesManager: pwm,
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
    func testPendingWritesSpinCountWorksForVectorWrites() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)

        try withPendingStreamWritesManager { pwm in
            let numberOfBytes = Int(1 /* first write */ + pwm.writeSpinCount /* the spins */ + 1 /* so one byte remains at the end */)
            buffer.clear()
            buffer.write(bytes: [0xff] as [UInt8])
            let ps: [EventLoopPromise<Void>] = (0..<numberOfBytes).map { (_: Int) in
                let p: EventLoopPromise<Void> = el.newPromise()
                _ = pwm.add(data: .byteBuffer(buffer), promise: p)
                return p
            }
            pwm.markFlushCheckpoint()

            /* this will create an `Array` like this (for `numberOfBytes == 4`)
             `[[1, 1, 1, 1], [1, 1, 1], [1, 1], [1]]`
             */
            let expectedVectorWrites = Array((2...numberOfBytes).reversed()).map { n in
                Array(repeating: 1, count: n)
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
            var result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: expectedVectorWrites,
                                                   expectedFileWritabilities: nil,
                                                   returns: Array(repeating: .processed(1), count: numberOfBytes),
                                                   promiseStates: expectedPromiseStates)
            XCTAssertEqual(.couldNotWriteEverything, result)

            /* we'll now write the one last byte and assert that all the writes are complete */
            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: [1],
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: nil,
                                               returns: [.processed(1)],
                                               promiseStates: [Array(repeating: true, count: numberOfBytes)])
            XCTAssertEqual(.writtenCompletely, result)
        }
    }

    /// Tests that the spin count works for one long buffer if small bits are written one by one.
    func testPendingWritesCompleteWritesDontConsumeWriteSpinCount() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)

        try withPendingStreamWritesManager { pwm in
            let numberOfWrites = Int(1 /* first write */ + pwm.writeSpinCount /* the spins */ + 1 /* so one byte remains at the end */)
            buffer.clear()
            buffer.write(bytes: Array<UInt8>(repeating: 0xff, count: 1))
            let handle = FileHandle(descriptor: -1)
            defer {
                /* fake file handle, so don't actually close */
                XCTAssertNoThrow(try handle.takeDescriptorOwnership())
            }
            let fileRegion = FileRegion(fileHandle: handle, readerIndex: 0, endIndex: 1)
            let ps: [EventLoopPromise<Void>] = (0..<numberOfWrites).map { _ in el.newPromise() }
            (0..<numberOfWrites).forEach { i in
                _ = pwm.add(data: i % 2 == 0 ? .byteBuffer(buffer) : .fileRegion(fileRegion), promise: ps[i])
            }
            pwm.markFlushCheckpoint()

            let expectedPromiseStates = Array((1...numberOfWrites).reversed()).map { n in
                Array(repeating: true, count: numberOfWrites - n + 1) + Array(repeating: false, count: n - 1)
            }
            /* below, we'll write 1 byte at a time. So the number of bytes offered should decrease by one.
             The write operation should be repeated until we did it 1 + spin count times and then return `.writtenPartially`.
             After that, one byte will remain */
            let result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                       promises: ps,
                                                       expectedSingleWritabilities: Array(repeating: 1, count: numberOfWrites / 2),
                                                       expectedVectorWritabilities: nil,
                                                       expectedFileWritabilities: Array(repeating: (0, 1), count: numberOfWrites / 2),
                                                       returns: Array(repeating: .processed(1), count: numberOfWrites),
                                                       promiseStates: expectedPromiseStates)
            XCTAssertEqual(.writtenCompletely, result)
        }
    }

    /// Test that cancellation of the Channel writes works correctly.
    func testPendingWritesCancellationWorksCorrectly() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        let emptyBuffer = buffer
        _ = buffer.write(string: "1234")

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<3).map { (_: Int) in el.newPromise() }
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            pwm.markFlushCheckpoint()
            _ = pwm.add(data: .byteBuffer(emptyBuffer), promise: ps[2])

            let result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                       promises: ps,
                                                       expectedSingleWritabilities: nil,
                                                       expectedVectorWritabilities: [[4, 4], [2, 4]],
                                                       expectedFileWritabilities: nil,
                                                       returns: [.processed(2), .wouldBlock(0)],
                                                       promiseStates: [[false, false, false], [false, false, false]])
            XCTAssertEqual(.couldNotWriteEverything, result)

            pwm.failAll(error: ChannelError.operationUnsupported, close: true)

            XCTAssertTrue(ps.map { $0.futureResult.isFulfilled }.reduce(true) { $0 && $1 })
        }
    }

    /// Test that with a few massive buffers, we don't offer more than we should to `writev` if the individual chunks fit.
    func testPendingWritesNoMoreThanWritevLimitIsWritten() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator(hookedMalloc: { _ in UnsafeMutableRawPointer(bitPattern: 0xdeadbee)! },
                                        hookedRealloc: { _, _ in UnsafeMutableRawPointer(bitPattern: 0xdeadbee)! },
                                        hookedFree: { _ in },
                                        hookedMemcpy: { _, _, _ in })
        /* each buffer is half the writev limit */
        let halfTheWriteVLimit = Socket.writevLimitBytes / 2
        var buffer = alloc.buffer(capacity: halfTheWriteVLimit)
        buffer.moveReaderIndex(to: 0)
        buffer.moveWriterIndex(to: halfTheWriteVLimit)

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<3).map { (_: Int) in el.newPromise() }
            /* add 1.5x the writev limit */
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[2])
            pwm.markFlushCheckpoint()

            let result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: [halfTheWriteVLimit],
                                                   expectedVectorWritabilities: [[halfTheWriteVLimit, halfTheWriteVLimit]],
                                                   expectedFileWritabilities: nil,
                                                   returns: [.processed(2 * halfTheWriteVLimit), .processed(halfTheWriteVLimit)],
                                                   promiseStates: [[true, true, false], [true, true, true]])
            XCTAssertEqual(.writtenCompletely, result)
        }
    }

    /// Test that with a massive buffers (bigger than writev size), we don't offer more than we should to `writev`.
    func testPendingWritesNoMoreThanWritevLimitIsWrittenInOneMassiveChunk() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator(hookedMalloc: { _ in UnsafeMutableRawPointer(bitPattern: 0xdeadbee)! },
                                        hookedRealloc: { _, _ in UnsafeMutableRawPointer(bitPattern: 0xdeadbee)! },
                                        hookedFree: { _ in },
                                        hookedMemcpy: { _, _, _ in })
        /* each buffer is half the writev limit */
        let biggerThanWriteV = Socket.writevLimitBytes + 23
        var buffer = alloc.buffer(capacity: biggerThanWriteV)
        buffer.moveReaderIndex(to: 0)
        buffer.moveWriterIndex(to: biggerThanWriteV)

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<3).map { (_: Int) in el.newPromise() }
            /* add 1.5x the writev limit */
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            buffer.moveWriterIndex(to: 100)
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[2])

            pwm.markFlushCheckpoint()

            let result = try assertExpectedWritability(pendingWritesManager: pwm,
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
            XCTAssertEqual(.writtenCompletely, result)
            pwm.markFlushCheckpoint()
        }
    }

    func testPendingWritesFileRegion() throws {
        let el = EmbeddedEventLoop()
        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<2).map { (_: Int) in el.newPromise() }

            let fh1 = FileHandle(descriptor: -1)
            let fh2 = FileHandle(descriptor: -2)
            let fr1 = FileRegion(fileHandle: fh1, readerIndex: 12, endIndex: 14)
            let fr2 = FileRegion(fileHandle: fh2, readerIndex: 0, endIndex: 2)
            defer {
                // fake descriptors, so shouldn't be closed.
                XCTAssertNoThrow(try fh1.takeDescriptorOwnership())
                XCTAssertNoThrow(try fh2.takeDescriptorOwnership())
            }
            _ = pwm.add(data: .fileRegion(fr1), promise: ps[0])
            pwm.markFlushCheckpoint()
            _ = pwm.add(data: .fileRegion(fr2), promise: ps[1])

            var result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: nil,
                                                   expectedFileWritabilities: [(12, 14)],
                                                   returns: [.processed(2)],
                                                   promiseStates: [[true, false]])
            XCTAssertEqual(.writtenCompletely, result)

            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: nil,
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: nil,
                                               returns: [],
                                               promiseStates: [[true, false]])
            XCTAssertEqual(.writtenCompletely, result)

            pwm.markFlushCheckpoint()

            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: nil,
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: [(0, 2), (1, 2)],
                                               returns: [.processed(1), .processed(1)],
                                               promiseStates: [[true, false], [true, true]])
            XCTAssertEqual(.writtenCompletely, result)
        }
    }

    func testPendingWritesEmptyFileRegion() throws {
        let el = EmbeddedEventLoop()
        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<1).map { (_: Int) in el.newPromise() }

            let fh = FileHandle(descriptor: -1)
            let fr = FileRegion(fileHandle: fh, readerIndex: 99, endIndex: 99)
            defer {
                // fake descriptor, so shouldn't be closed.
                XCTAssertNoThrow(try fh.takeDescriptorOwnership())
            }
            _ = pwm.add(data: .fileRegion(fr), promise: ps[0])
            pwm.markFlushCheckpoint()

            let result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: nil,
                                                   expectedFileWritabilities: [(99, 99)],
                                                   returns: [.processed(0)],
                                                   promiseStates: [[true]])
            XCTAssertEqual(.writtenCompletely, result)
        }
    }

    func testPendingWritesInterleavedBuffersAndFiles() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        _ = buffer.write(string: "1234")

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<5).map { (_: Int) in el.newPromise() }

            let fh1 = FileHandle(descriptor: -1)
            let fh2 = FileHandle(descriptor: -1)
            let fr1 = FileRegion(fileHandle: fh1, readerIndex: 99, endIndex: 99)
            let fr2 = FileRegion(fileHandle: fh1, readerIndex: 0, endIndex: 10)
            defer {
                // fake descriptors, so shouldn't be closed.
                XCTAssertNoThrow(try fh1.takeDescriptorOwnership())
                XCTAssertNoThrow(try fh2.takeDescriptorOwnership())
            }

            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            _ = pwm.add(data: .fileRegion(fr1), promise: ps[2])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[3])
            _ = pwm.add(data: .fileRegion(fr2), promise: ps[4])

            pwm.markFlushCheckpoint()

            var result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: [4, 3, 2, 1],
                                                   expectedVectorWritabilities: [[4, 4]],
                                                   expectedFileWritabilities: [(99, 99), (0, 10), (3, 10), (6, 10)],
                                                   returns: [.processed(8), .processed(0), .processed(1), .processed(1), .processed(1), .processed(1), .wouldBlock(3), .processed(3), .wouldBlock(0)],
                                                   promiseStates: [[true, true, false, false, false],
                                                                   [true, true, true, false, false],
                                                                   [true, true, true, false, false],
                                                                   [true, true, true, false, false],
                                                                   [true, true, true, false, false],
                                                                   [true, true, true, true, false],
                                                                   [true, true, true, true, false],
                                                                   [true, true, true, true, false],
                                                                   [true, true, true, true, false]])
            XCTAssertEqual(.couldNotWriteEverything, result)

            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: nil,
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: [(6, 10)],
                                               returns: [.processed(4)],
                                               promiseStates: [[true, true, true, true, true]])
            XCTAssertEqual(.writtenCompletely, result)
        }
    }

    func testTwoFlushedNonEmptyWritesFollowedByUnflushedEmpty() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        let emptyBuffer = buffer
        _ = buffer.write(string: "1234")

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<3).map { (_: Int) in el.newPromise() }

            pwm.markFlushCheckpoint()

            /* let's start with no writes and just a flush */
            var result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                       promises: ps,
                                                       expectedSingleWritabilities: nil,
                                                       expectedVectorWritabilities: nil,
                                                       expectedFileWritabilities: nil,
                                                       returns: [],
                                                       promiseStates: [[false, false, false]])

            /* let's add a few writes but still without any promises */
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])

            pwm.markFlushCheckpoint()

            _ = pwm.add(data: .byteBuffer(emptyBuffer), promise: ps[2])


            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: [[4, 4]],
                                                   expectedFileWritabilities: nil,
                                                   returns: [.processed(8)],
                                                   promiseStates: [[true, true, false]])
            XCTAssertEqual(.writtenCompletely, result)

            pwm.markFlushCheckpoint()

            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: [0],
                                                   expectedVectorWritabilities: nil,
                                                   expectedFileWritabilities: nil,
                                                   returns: [.processed(0)],
                                                   promiseStates: [[true, true, true]])
            XCTAssertEqual(.writtenCompletely, result)
        }
    }


    func testPendingWritesWorksWithManyEmptyWrites() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        let emptyBuffer = alloc.buffer(capacity: 12)

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<3).map { (_: Int) in el.newPromise() }
            _ = pwm.add(data: .byteBuffer(emptyBuffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(emptyBuffer), promise: ps[1])
            pwm.markFlushCheckpoint()
            _ = pwm.add(data: .byteBuffer(emptyBuffer), promise: ps[2])

            var result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: [[0, 0]],
                                                   expectedFileWritabilities: nil,
                                                   returns: [.processed(0)],
                                                   promiseStates: [[true, true, false]])
            XCTAssertEqual(.writtenCompletely, result)

            pwm.markFlushCheckpoint()

            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: [0],
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: nil,
                                               returns: [.processed(0)],
                                               promiseStates: [[true, true, true]])
            XCTAssertEqual(.writtenCompletely, result)
        }
    }

    func testPendingWritesCloseDuringVectorWrite() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        buffer.write(string: "1234")

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<3).map { (_: Int) in el.newPromise() }
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            pwm.markFlushCheckpoint()
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[2])

            ps[0].futureResult.whenComplete {
                pwm.failAll(error: ChannelError.inputClosed, close: true)
            }

            let result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: [[4, 4]],
                                                   expectedFileWritabilities: nil,
                                                   returns: [.processed(4)],
                                                   promiseStates: [[true, true, true]])
            XCTAssertEqual(.writtenCompletely, result)
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

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0...Socket.writevLimitIOVectors).map { (_: Int) in el.newPromise() }
            ps.forEach { p in
                _ = pwm.add(data: .byteBuffer(buffer), promise: p)
            }
            pwm.markFlushCheckpoint()

            var result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: [4],
                                                   expectedVectorWritabilities: [Array(repeating: 4, count: Socket.writevLimitIOVectors)],
                                                   expectedFileWritabilities: nil,
                                                   returns: [.processed(4 * Socket.writevLimitIOVectors), .wouldBlock(0)],
                                                   promiseStates: [Array(repeating: true, count: Socket.writevLimitIOVectors) + [false],
                                                                   Array(repeating: true, count: Socket.writevLimitIOVectors) + [false]])
            XCTAssertEqual(.couldNotWriteEverything, result)
            result = try assertExpectedWritability(pendingWritesManager: pwm,
                                               promises: ps,
                                               expectedSingleWritabilities: [4],
                                               expectedVectorWritabilities: nil,
                                               expectedFileWritabilities: nil,
                                               returns: [.processed(4)],
                                               promiseStates: [Array(repeating: true, count: Socket.writevLimitIOVectors + 1)])
            XCTAssertEqual(.writtenCompletely, result)
        }
    }

    func testPendingWritesIsHappyWhenSendfileReturnsWouldBlockButWroteFully() throws {
        let el = EmbeddedEventLoop()
        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<1).map { (_: Int) in el.newPromise() }

            let fh = FileHandle(descriptor: -1)
            let fr = FileRegion(fileHandle: fh, readerIndex: 0, endIndex: 8192)
            defer {
                // fake descriptor, so shouldn't be closed.
                XCTAssertNoThrow(try fh.takeDescriptorOwnership())
            }

            _ = pwm.add(data: .fileRegion(fr), promise: ps[0])
            pwm.markFlushCheckpoint()

            let result = try assertExpectedWritability(pendingWritesManager: pwm,
                                                   promises: ps,
                                                   expectedSingleWritabilities: nil,
                                                   expectedVectorWritabilities: nil,
                                                   expectedFileWritabilities: [(0, 8192)],
                                                   returns: [.wouldBlock(8192)],
                                                   promiseStates: [[true]])
            XCTAssertEqual(.writtenCompletely, result)
        }
    }

    func testSpecificConnectTimeout() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        do {
            // This must throw as 198.51.100.254 is reserved for documentation only
            _ = try ClientBootstrap(group: group)
                .channelOption(ChannelOptions.connectTimeout, value: .milliseconds(10))
                .connect(to: SocketAddress.newAddressResolving(host: "198.51.100.254", port: 65535)).wait()
            XCTFail()
        } catch let err as ChannelError {
            if case .connectTimeout(_) = err {
                // expected, sadly there is no "if not case"
            } else {
                XCTFail()
            }
        } catch let err as IOError where err.errnoCode == ENETDOWN || err.errnoCode == ENETUNREACH {
            // we need to accept those too unfortunately
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testGeneralConnectTimeout() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        do {
            // This must throw as 198.51.100.254 is reserved for documentation only
            _ = try ClientBootstrap(group: group)
                .connectTimeout(.milliseconds(10))
                .connect(to: SocketAddress.newAddressResolving(host: "198.51.100.254", port: 65535)).wait()
            XCTFail()
        } catch let err as ChannelError {
            if case .connectTimeout(_) = err {
                // expected, sadly there is no "if not case"
            } else {
                XCTFail()
            }
        } catch let err as IOError where err.errnoCode == ENETDOWN || err.errnoCode == ENETUNREACH {
            // we need to accept those too unfortunately
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testCloseOutput() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let server = try assertNoThrowWithValue(ServerSocket(protocolFamily: PF_INET))
        defer {
            XCTAssertNoThrow(try server.close())
        }
        try server.bind(to: SocketAddress.newAddressResolving(host: "127.0.0.1", port: 0))
        try server.listen()

        let byteCountingHandler = ByteCountingHandler(numBytes: 4, promise: group.next().newPromise())
        let verificationHandler = ShutdownVerificationHandler(shutdownEvent: .output, promise: group.next().newPromise())
        let future = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.add(handler: verificationHandler).then {
                    channel.pipeline.add(handler: byteCountingHandler)
                }
            }
            .connect(to: try! server.localAddress())
        let accepted = try server.accept()!
        defer {
            XCTAssertNoThrow(try accepted.close())
        }

        let channel = try future.wait()
        defer {
            XCTAssertNoThrow(try channel.close(mode: .all).wait())
        }

        var buffer = channel.allocator.buffer(capacity: 12)
        buffer.write(string: "1234")

        try channel.writeAndFlush(NIOAny(buffer)).wait()
        try channel.close(mode: .output).wait()

        verificationHandler.waitForEvent()
        do {
            try channel.writeAndFlush(NIOAny(buffer)).wait()
            XCTFail()
        } catch let err as ChannelError {
            XCTAssertEqual(ChannelError.outputClosed, err)
        }
        let written = try buffer.withUnsafeReadableBytes { p in
            try accepted.write(pointer: UnsafeRawBufferPointer(rebasing: p.prefix(4)))
        }
        if case .processed(let numBytes) = written {
            XCTAssertEqual(4, numBytes)
        } else {
            XCTFail()
        }
        try byteCountingHandler.assertReceived(buffer: buffer)
    }

    func testCloseInput() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let server = try assertNoThrowWithValue(ServerSocket(protocolFamily: PF_INET))
        defer {
            XCTAssertNoThrow(try server.close())
        }
        try server.bind(to: SocketAddress.newAddressResolving(host: "127.0.0.1", port: 0))
        try server.listen()

        class VerifyNoReadHandler : ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                XCTFail("Received data: \(data)")
            }
        }

        let verificationHandler = ShutdownVerificationHandler(shutdownEvent: .input, promise: group.next().newPromise())
        let future = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.add(handler: VerifyNoReadHandler()).then {
                    channel.pipeline.add(handler: verificationHandler)
                }
            }
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .connect(to: try! server.localAddress())
        let accepted = try server.accept()!
        defer {
            XCTAssertNoThrow(try accepted.close())
        }

        let channel = try future.wait()
        defer {
            XCTAssertNoThrow(try channel.close(mode: .all).wait())
        }

        try channel.close(mode: .input).wait()

        verificationHandler.waitForEvent()

        var buffer = channel.allocator.buffer(capacity: 12)
        buffer.write(string: "1234")

        let written = try buffer.withUnsafeReadableBytes { p in
            try accepted.write(pointer: UnsafeRawBufferPointer(rebasing: p.prefix(4)))
        }

        switch written {
        case .processed(let numBytes):
            XCTAssertEqual(4, numBytes)
        default:
            XCTFail()
        }

        try channel.eventLoop.submit {
            // Dummy task execution to give some time for an actual read to open (which should not happen as we closed the input).
        }.wait()
    }

    func testHalfClosure() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let server = try assertNoThrowWithValue(ServerSocket(protocolFamily: PF_INET))
        defer {
            XCTAssertNoThrow(try server.close())
        }
        try server.bind(to: SocketAddress.newAddressResolving(host: "127.0.0.1", port: 0))
        try server.listen()

        let verificationHandler = ShutdownVerificationHandler(shutdownEvent: .input, promise: group.next().newPromise())

        let future = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.add(handler: verificationHandler)
            }
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .connect(to: try! server.localAddress())
        let accepted = try server.accept()!
        defer {
            XCTAssertNoThrow(try accepted.close())
        }

        let channel = try future.wait()
        defer {
            XCTAssertNoThrow(try channel.close(mode: .all).wait())
        }

        try accepted.shutdown(how: .WR)

        verificationHandler.waitForEvent()

        var buffer = channel.allocator.buffer(capacity: 12)
        buffer.write(string: "1234")

        try channel.writeAndFlush(NIOAny(buffer)).wait()
    }

    enum ShutDownEvent {
        case input
        case output
    }
    private class ShutdownVerificationHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer

        private var inputShutdownEventReceived = false
        private var outputShutdownEventReceived = false

        private let promise: EventLoopPromise<Void>
        private let shutdownEvent: ShutDownEvent

        init(shutdownEvent: ShutDownEvent, promise: EventLoopPromise<Void>) {
            self.promise = promise
            self.shutdownEvent = shutdownEvent
        }

        public func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
            switch event {
            case let ev as ChannelEvent:
                switch ev {
                case .inputClosed:
                    XCTAssertFalse(inputShutdownEventReceived)
                    inputShutdownEventReceived = true

                    if shutdownEvent == .input {
                        promise.succeed(result: ())
                    }
                case .outputClosed:
                    XCTAssertFalse(outputShutdownEventReceived)
                    outputShutdownEventReceived = true

                    if shutdownEvent == .output {
                        promise.succeed(result: ())
                    }
                }

                fallthrough
            default:
                ctx.fireUserInboundEventTriggered(event)
            }
        }

        public func waitForEvent() {
            // We always notify it with a success so just force it with !
            try! promise.futureResult.wait()
        }

        public func channelInactive(ctx: ChannelHandlerContext) {
            switch shutdownEvent {
            case .input:
                XCTAssertTrue(inputShutdownEventReceived)
                XCTAssertFalse(outputShutdownEventReceived)
            case .output:
                XCTAssertFalse(inputShutdownEventReceived)
                XCTAssertTrue(outputShutdownEventReceived)
            }

            promise.succeed(result: ())
        }
    }

    func testRejectsInvalidData() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "127.0.0.1", port: 0).wait())

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait())

        do {
            try clientChannel.writeAndFlush(NIOAny(5)).wait()
            XCTFail("Did not throw")
        } catch ChannelError.writeDataUnsupported {
            // All good
        } catch {
            XCTFail("Got \(error)")
        }
    }

    func testWeDontCrashIfChannelReleasesBeforePipeline() throws {
        final class StuffHandler: ChannelInboundHandler {
            typealias InboundIn = Never

            let promise: EventLoopPromise<ChannelPipeline>

            init(promise: EventLoopPromise<ChannelPipeline>) {
                self.promise = promise
            }

            func channelRegistered(ctx: ChannelHandlerContext) {
                self.promise.succeed(result: ctx.channel.pipeline)
            }
        }
        weak var weakClientChannel: Channel? = nil
        weak var weakServerChannel: Channel? = nil
        weak var weakServerChildChannel: Channel? = nil

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let promise: EventLoopPromise<ChannelPipeline> = group.next().newPromise()

        try {
            let serverChildChannelPromise: EventLoopPromise<Channel> = group.next().newPromise()
            let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .childChannelInitializer { channel in
                    serverChildChannelPromise.succeed(result: channel)
                    channel.close(promise: nil)
                    return channel.eventLoop.newSucceededFuture(result: ())
                }
                .bind(host: "127.0.0.1", port: 0).wait())

            let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
                .channelInitializer {
                    $0.pipeline.add(handler: StuffHandler(promise: promise))
                }
                .connect(to: serverChannel.localAddress!).wait())
            weakClientChannel = clientChannel
            weakServerChannel = serverChannel
            weakServerChildChannel = try serverChildChannelPromise.futureResult.wait()
            clientChannel.close().whenFailure {
                if case let error = $0 as? ChannelError, error != ChannelError.alreadyClosed {
                    XCTFail("unexpected error \($0)")
                }
            }
            serverChannel.close().whenFailure {
                XCTFail("unexpected error \($0)")
            }

            // We need to wait for the close futures to fire before we move on. Before the
            // close promises are hit, the channel can keep a reference to itself alive because it's running
            // background code on the event loop. Completing the close promise should be the last thing the
            // channel will ever do, assuming there is no work holding a ref to it anywhere.
            XCTAssertNoThrow(try clientChannel.closeFuture.wait())
            XCTAssertNoThrow(try serverChannel.closeFuture.wait())
        }()
        let pipeline = try promise.futureResult.wait()
        do {
            try pipeline.eventLoop.submit { () -> Channel in
                XCTAssertTrue(pipeline.channel is DeadChannel)
                return pipeline.channel
            }.wait().writeAndFlush(NIOAny(())).wait()
            XCTFail("shouldn't have been reached")
        } catch let e as ChannelError where e == .ioOnClosedChannel {
            // OK
        } catch {
            XCTFail("wrong error \(error) received")
        }

        // Annoyingly it's totally possible to get to this stage and have the channels
        // not yet be entirely freed on the background thread. There is no way we can guarantee
        // that this hasn't happened, so we wait for up to a second to let this happen. If it hasn't
        // happened in one second, we assume it never will.
        assert(weakClientChannel == nil, within: .seconds(1), "weakClientChannel not nil, looks like we leaked it!")
        assert(weakServerChannel == nil, within: .seconds(1), "weakServerChannel not nil, looks like we leaked it!")
        assert(weakServerChildChannel == nil, within: .seconds(1), "weakServerChildChannel not nil, looks like we leaked it!")
    }

    func testAskForLocalAndRemoteAddressesAfterChannelIsClosed() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "127.0.0.1", port: 0).wait())

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait())

        // Start shutting stuff down.
        XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())

        XCTAssertNoThrow(try serverChannel.closeFuture.wait())
        XCTAssertNoThrow(try clientChannel.closeFuture.wait())

        // Schedule on the EventLoop to ensure we scheduled the cleanup of the cached addresses before.
        XCTAssertNoThrow(try group.next().submit {
            for f in [ serverChannel.remoteAddress, serverChannel.localAddress, clientChannel.remoteAddress, clientChannel.localAddress ] {
                XCTAssertNil(f)
            }
        }.wait())

    }

    func testReceiveAddressAfterAccept() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        class AddressVerificationHandler : ChannelInboundHandler {
            typealias InboundIn = Never

            public func channelActive(ctx: ChannelHandlerContext) {
                XCTAssertNotNil(ctx.channel.localAddress)
                XCTAssertNotNil(ctx.channel.remoteAddress)
                ctx.channel.close(promise: nil)
            }
        }

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { ch in
                ch.pipeline.add(handler: AddressVerificationHandler())
            }
            .bind(host: "127.0.0.1", port: 0).wait())

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait())

        XCTAssertNoThrow(try clientChannel.closeFuture.wait())
        XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
    }

    func testWeDontJamSocketsInANoIOState() throws {
        final class ReadDelayer: ChannelDuplexHandler {
            typealias InboundIn = Any
            typealias InboundOut = Any
            typealias OutboundIn = Any
            typealias OutboundOut = Any

            public var reads = 0
            private var ctx: ChannelHandlerContext!
            private var readCountPromise: EventLoopPromise<Void>!
            private var waitingForReadPromise: EventLoopPromise<Void>?

            func handlerAdded(ctx: ChannelHandlerContext) {
                self.ctx = ctx
                self.readCountPromise = ctx.eventLoop.newPromise()
            }

            public func expectRead(loop: EventLoop) -> EventLoopFuture<Void> {
                return loop.submit {
                    self.waitingForReadPromise = loop.newPromise()
                }.then {
                    self.waitingForReadPromise!.futureResult
                }
            }

            func channelReadComplete(ctx: ChannelHandlerContext) {
                self.waitingForReadPromise?.succeed(result: ())
                self.waitingForReadPromise = nil
            }

            func read(ctx: ChannelHandlerContext) {
                self.reads += 1

                // Allow the first read through.
                if self.reads == 1 {
                    self.ctx.read()
                }
            }

            public func issueDelayedRead() {
                self.ctx.read()
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let readDelayer = ReadDelayer()

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer {
                $0.pipeline.add(handler: readDelayer)
            }
            .bind(host: "127.0.0.1", port: 0).wait())

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait())

        // We send a first write and expect it to arrive.
        var buffer = clientChannel.allocator.buffer(capacity: 12)
        let firstReadPromise = readDelayer.expectRead(loop: serverChannel.eventLoop)
        buffer.write(staticString: "hello, world")
        XCTAssertNoThrow(try clientChannel.writeAndFlush(buffer).wait())
        XCTAssertNoThrow(try firstReadPromise.wait())

        // We send a second write. This won't arrive immediately.
        XCTAssertNoThrow(try clientChannel.writeAndFlush(buffer).wait())
        let readFuture = readDelayer.expectRead(loop: serverChannel.eventLoop)
        try serverChannel.eventLoop.scheduleTask(in: .milliseconds(100)) {
            XCTAssertFalse(readFuture.isFulfilled)
        }.futureResult.wait()

        // Ok, now let it proceed.
        XCTAssertNoThrow(try serverChannel.eventLoop.submit {
            XCTAssertEqual(readDelayer.reads, 2)
            readDelayer.issueDelayedRead()
        }.wait())

        // The read should go through.
        XCTAssertNoThrow(try readFuture.wait())
    }

    func testNoChannelReadBeforeEOFIfNoAutoRead() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        class VerifyNoReadBeforeEOFHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            var expectingData: Bool = false

            public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                if !self.expectingData {
                    XCTFail("Received data before we expected it.")
                } else {
                    let data = self.unwrapInboundIn(data)
                    XCTAssertEqual(data.getString(at: data.readerIndex, length: data.readableBytes), "test")
                }
            }
        }

        let handler = VerifyNoReadBeforeEOFHandler()
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { ch in
                ch.pipeline.add(handler: handler)
            }
            .bind(host: "127.0.0.1", port: 0).wait())

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait())
        var buffer = clientChannel.allocator.buffer(capacity: 8)
        buffer.write(string: "test")
        try clientChannel.writeAndFlush(buffer).wait()

        // Wait for 100 ms. No data should be delivered.
        usleep(100 * 1000);

        // Now we send close. This should deliver data.
        try clientChannel.eventLoop.submit { () -> EventLoopFuture<Void> in
            handler.expectingData = true
            return clientChannel.close()
        }.wait().wait()
        try serverChannel.close().wait()
    }

    func testCloseInEOFdChannelReadBehavesCorrectly() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        class VerifyEOFReadOrderingAndCloseInChannelReadHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            private var seenEOF: Bool = false
            private var numberOfChannelReads: Int = 0

            public func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
                if case .some(ChannelEvent.inputClosed) = event as? ChannelEvent {
                    self.seenEOF = true
                }
                ctx.fireUserInboundEventTriggered(event)
            }

            public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                if self.seenEOF {
                    XCTFail("Should not be called before seeing the EOF as autoRead is false and we did not call read(), but received \(self.unwrapInboundIn(data))")
                }
                self.numberOfChannelReads += 1
                let buffer = self.unwrapInboundIn(data)
                XCTAssertLessThanOrEqual(buffer.readableBytes, 8)
                XCTAssertEqual(1, self.numberOfChannelReads)
                ctx.close(mode: .all, promise: nil)
            }
        }

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { ch in
                ch.pipeline.add(handler: VerifyEOFReadOrderingAndCloseInChannelReadHandler())
            }
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 8))
            .bind(host: "127.0.0.1", port: 0).wait())

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait())
        var buffer = clientChannel.allocator.buffer(capacity: 8)
        buffer.write(string: "01234567")
        for _ in 0..<20 {
            XCTAssertNoThrow(try clientChannel.writeAndFlush(buffer).wait())
        }
        XCTAssertNoThrow(try clientChannel.close().wait())

        // Wait for 100 ms.
        usleep(100 * 1000)
        XCTAssertNoThrow(try serverChannel.close().wait())
    }

    func testCloseInSameReadThatEOFGetsDelivered() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        class CloseWhenWeGetEOFHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            private var didRead: Bool = false
            private let allDone: EventLoopPromise<Void>

            init(allDone: EventLoopPromise<Void>) {
                self.allDone = allDone
            }

            public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                if !self.didRead {
                    self.didRead = true
                    // closing this here causes an interesting situation:
                    // in readFromSocket we will spin one more iteration until we see the EOF but when we then return
                    // to `BaseSocketChannel.readable0`, we deliver EOF with the channel already deactivated.
                    ctx.close(mode: .all, promise: self.allDone)
                }
            }
        }

        let allDone: EventLoopPromise<Void> = group.next().newPromise()
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { ch in
                ch.pipeline.add(handler: CloseWhenWeGetEOFHandler(allDone: allDone))
            }
            // maxMessagesPerRead is large so that we definitely spin and seen the EOF
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 10)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            // that fits the message we prepared
            .childChannelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 8))
            .bind(host: "127.0.0.1", port: 0).wait())

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait())
        var buf = clientChannel.allocator.buffer(capacity: 16)
        buf.write(staticString: "012345678")
        XCTAssertNoThrow(try clientChannel.writeAndFlush(buf).wait())
        XCTAssertNoThrow(try clientChannel.writeAndFlush(buf).wait())
        XCTAssertNoThrow(try clientChannel.close().wait())
        XCTAssertNoThrow(try allDone.futureResult.wait())

        XCTAssertNoThrow(try serverChannel.close().wait())
    }

    func testEOFReceivedWithoutReadRequests() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        class ChannelInactiveVerificationHandler: ChannelDuplexHandler {
            typealias InboundIn = ByteBuffer
            typealias OutboundIn = ByteBuffer

            private let promise: EventLoopPromise<Void>

            init(_ promise: EventLoopPromise<Void>) {
                self.promise = promise
            }

            public func read(ctx: ChannelHandlerContext) {
                XCTFail("shouldn't read")
            }

            public func channelInactive(ctx: ChannelHandlerContext) {
                promise.succeed(result: ())
            }
        }

        let promise: EventLoopPromise<Void> = group.next().newPromise()
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { ch in
                ch.pipeline.add(handler: ChannelInactiveVerificationHandler(promise))
            }
            .bind(host: "127.0.0.1", port: 0).wait())

        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait())
        var buffer = clientChannel.allocator.buffer(capacity: 8)
        buffer.write(string: "test")
        try clientChannel.writeAndFlush(buffer).wait()
        try clientChannel.close().wait()
        try promise.futureResult.wait()

        try serverChannel.close().wait()
    }

    func testAcceptsAfterCloseDontCauseIssues() throws {
        class ChannelCollector {
            let q = DispatchQueue(label: "q")
            let group: EventLoopGroup
            var channels: [ObjectIdentifier: Channel] = [:]

            init(group: EventLoopGroup) {
                self.group = group
            }

            deinit {
                XCTAssertTrue(channels.isEmpty, "\(channels)")
            }

            func add(_ channel: Channel) {
                self.q.sync {
                    assert(self.channels[ObjectIdentifier(channel)] == nil)
                    channels[ObjectIdentifier(channel)] = channel
                }
            }

            func remove(_ channel: Channel) {
                let removed: Channel? = self.q.sync {
                    return self.channels.removeValue(forKey: ObjectIdentifier(channel))
                }
                XCTAssertTrue(removed != nil)
            }

            func closeAll() -> [EventLoopFuture<Void>] {
                return q.sync { self.channels.values }.map { channel in
                    channel.close()
                }
            }
        }

        class CheckActiveHandler: ChannelInboundHandler {
            public typealias InboundIn = Any
            public typealias OutboundOut = Any

            private var isActive = false
            private let channelCollector: ChannelCollector

            init(channelCollector: ChannelCollector) {
                self.channelCollector = channelCollector
            }

            deinit {
                XCTAssertFalse(self.isActive)
            }

            func channelActive(ctx: ChannelHandlerContext) {
                XCTAssertFalse(self.isActive)
                self.isActive = true
                self.channelCollector.add(ctx.channel)
                ctx.fireChannelActive()
            }

            func channelInactive(ctx: ChannelHandlerContext) {
                XCTAssertTrue(self.isActive)
                self.isActive = false
                self.channelCollector.remove(ctx.channel)
                ctx.fireChannelInactive()
            }
        }

        func runTest() throws {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            defer {
                XCTAssertNoThrow(try group.syncShutdownGracefully())
            }
            let collector = ChannelCollector(group: group)
            let serverBoot = ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    return channel.pipeline.add(handler: CheckActiveHandler(channelCollector: collector))
            }
            let listeningChannel = try serverBoot.bind(host: "127.0.0.1", port: 0).wait()
            let clientBoot = ClientBootstrap(group: group)
            XCTAssertNoThrow(try clientBoot.connect(to: listeningChannel.localAddress!).wait().close().wait())
            let closeFutures = collector.closeAll()
            // a stray client
            XCTAssertNoThrow(try clientBoot.connect(to: listeningChannel.localAddress!).wait().close().wait())
            XCTAssertNoThrow(try listeningChannel.close().wait())
            closeFutures.forEach {
                do {
                    try $0.wait()
                } catch let e as ChannelError where e == .alreadyClosed {
                    // ok
                } catch {
                    XCTFail("unexpected error \(error) received")
                }
            }
        }

        for _ in 0..<1000 {
            XCTAssertNoThrow(try runTest())
        }
    }

    func testChannelReadsDoesNotHappenAfterRegistration() throws {
        class SocketThatSucceedsOnSecondConnectForPort123: Socket {
            init(protocolFamily: CInt) throws {
                try super.init(protocolFamily: protocolFamily, type: Posix.SOCK_STREAM, setNonBlocking: true)
            }
            override func connect(to address: SocketAddress) throws -> Bool {
                if address.port == 123 {
                    return true
                } else {
                    return try super.connect(to: address)
                }
            }
        }
        class ReadDoesNotHappen: ChannelInboundHandler {
            typealias InboundIn = Any
            private let hasRegisteredPromise: EventLoopPromise<Void>
            private let hasUnregisteredPromise: EventLoopPromise<Void>
            private let hasReadPromise: EventLoopPromise<Void>
            enum State {
                case start
                case registered
                case active
                case read
            }
            private var state: State = .start
            init(hasRegisteredPromise: EventLoopPromise<Void>, hasUnregisteredPromise: EventLoopPromise<Void>, hasReadPromise: EventLoopPromise<Void>) {
                self.hasRegisteredPromise = hasRegisteredPromise
                self.hasUnregisteredPromise = hasUnregisteredPromise
                self.hasReadPromise = hasReadPromise
            }
            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                XCTAssertEqual(.active, self.state)
                self.state = .read
                self.hasReadPromise.succeed(result: ())
            }
            func channelActive(ctx: ChannelHandlerContext) {
                XCTAssertEqual(.registered, self.state)
                self.state = .active
            }
            func channelRegistered(ctx: ChannelHandlerContext) {
                XCTAssertEqual(.start, self.state)
                self.state = .registered
                self.hasRegisteredPromise.succeed(result: ())
            }
            func channelUnregistered(ctx: ChannelHandlerContext) {
                self.hasUnregisteredPromise.succeed(result: ())
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let serverEL = group.next()
        let clientEL = group.next()
        precondition(serverEL !== clientEL)
        let sc = try SocketChannel(socket: SocketThatSucceedsOnSecondConnectForPort123(protocolFamily: PF_INET), eventLoop: clientEL as! SelectableEventLoop)

        class WriteImmediatelyHandler: ChannelInboundHandler {
            typealias InboundIn = Any
            typealias OutboundOut = ByteBuffer

            private let writeDonePromise: EventLoopPromise<Void>

            init(writeDonePromise: EventLoopPromise<Void>) {
                self.writeDonePromise = writeDonePromise
            }

            func channelActive(ctx: ChannelHandlerContext) {
                var buffer = ctx.channel.allocator.buffer(capacity: 4)
                buffer.write(string: "foo")
                ctx.writeAndFlush(NIOAny(buffer), promise: self.writeDonePromise)
            }
        }

        let serverWriteHappenedPromise: EventLoopPromise<Void> = serverEL.next().newPromise()
        let clientHasRegistered: EventLoopPromise<Void> = serverEL.next().newPromise()
        let clientHasUnregistered: EventLoopPromise<Void> = serverEL.next().newPromise()
        let clientHasRead: EventLoopPromise<Void> = serverEL.next().newPromise()

        let bootstrap = try assertNoThrowWithValue(ServerBootstrap(group: serverEL)
            .childChannelInitializer { channel in
                channel.pipeline.add(handler: WriteImmediatelyHandler(writeDonePromise: serverWriteHappenedPromise))
            }
            .bind(host: "127.0.0.1", port: 0).wait())

        // This is a bit ugly, we're trying to fabricate a situation that can happen in the real world which is that
        // a socket is readable straight after becoming registered & connected.
        // In here what we're doing is that we flip the order around and connect it first, make sure the server
        // has written something and then on registration something is available to be read. We then 'fake connect'
        // again which our special `Socket` subclass will let succeed.
        _ = try sc.selectable.connect(to: bootstrap.localAddress!)
        try serverWriteHappenedPromise.futureResult.wait()
        try sc.pipeline.add(handler: ReadDoesNotHappen(hasRegisteredPromise: clientHasRegistered,
                                                       hasUnregisteredPromise: clientHasUnregistered,
                                                       hasReadPromise: clientHasRead)).then {
                // this will succeed and should not cause the socket to be read even though there'll be something
                // available to be read immediately
                sc.register()
            }.then {
                // this would normally fail but our special Socket subclass will let it succeed.
                sc.connect(to: try! SocketAddress(ipAddress: "127.0.0.1", port: 123))
            }.wait()
        try clientHasRegistered.futureResult.wait()
        try clientHasRead.futureResult.wait()
        try sc.syncCloseAcceptingAlreadyClosed()
        try clientHasUnregistered.futureResult.wait()
    }

    func testAppropriateAndInappropriateOperationsForUnregisteredSockets() throws {
        func checkThatItThrowsInappropriateOperationForState(file: StaticString = #file, line: UInt = #line, _ body: () throws -> Void) {
            do {
                try body()
                XCTFail("didn't throw", file: file, line: line)
            } catch let error as ChannelLifecycleError where error == .inappropriateOperationForState {
                //OK
            } catch {
                XCTFail("unexpected error \(error)", file: file, line: line)
            }
        }
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        func withChannel(skipDatagram: Bool = false, skipStream: Bool = false, skipServerSocket: Bool = false, file: StaticString = #file, line: UInt = #line,  _ body: (Channel) throws -> Void) {
            XCTAssertNoThrow(try {
                let el = elg.next() as! SelectableEventLoop
                let channels: [Channel] = (skipDatagram ? [] : [try DatagramChannel(eventLoop: el, protocolFamily: PF_INET)]) +
                    /* Xcode need help */ (skipStream ? []: [try SocketChannel(eventLoop: el, protocolFamily: PF_INET)]) +
                    /* Xcode need help */ (skipServerSocket ? []: [try ServerSocketChannel(eventLoop: el, group: elg, protocolFamily: PF_INET)])
                for channel in channels {
                    try body(channel)
                    XCTAssertNoThrow(try channel.close().wait(), file: file, line: line)
                }
            }(), file: file, line: line)
        }
        withChannel { channel in
            checkThatItThrowsInappropriateOperationForState {
                try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1234)).wait()
            }
        }
        withChannel { channel in
            checkThatItThrowsInappropriateOperationForState {
                try channel.writeAndFlush("foo").wait()
            }
        }
        withChannel { channel in
            XCTAssertNoThrow(try channel.triggerUserOutboundEvent("foo").wait())
        }
        withChannel { channel in
            XCTAssertFalse(channel.isActive)
        }
        withChannel(skipServerSocket: true) { channel in
            // should probably be changed
            XCTAssertTrue(channel.isWritable)
        }
        withChannel(skipDatagram: true, skipStream: true) { channel in
            // this should probably be the default for all types
            XCTAssertFalse(channel.isWritable)
        }

        withChannel { channel in
            checkThatItThrowsInappropriateOperationForState {
                XCTAssertEqual(0, channel.localAddress?.port ?? 0xffff)
                XCTAssertNil(channel.remoteAddress)
                try channel.bind(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
            }
        }
    }

    func testCloseSocketWhenReadErrorWasReceivedAndMakeSureNoReadCompleteArrives() throws {
        class SocketThatHasTheFirstReadSucceedButFailsTheNextWithECONNRESET: Socket {
            private var firstReadHappened = false
            init(protocolFamily: CInt) throws {
                try super.init(protocolFamily: protocolFamily, type: Posix.SOCK_STREAM, setNonBlocking: true)
            }
            override func read(pointer: UnsafeMutableRawBufferPointer) throws -> IOResult<Int> {
                defer {
                    self.firstReadHappened = true
                }
                XCTAssertGreaterThan(pointer.count, 0)
                if self.firstReadHappened {
                    // this is a copy of the exact error that'd come out of the real Socket.read
                    throw IOError.init(errnoCode: ECONNRESET, function: "read(descriptor:pointer:size:)")
                } else {
                    pointer[0] = 0xff
                    return .processed(1)
                }
            }
        }
        class VerifyThingsAreRightHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            private let allDone: EventLoopPromise<Void>
            enum State {
                case fresh
                case active
                case read
                case error
                case readComplete
                case inactive
            }
            private var state: State = .fresh

            init(allDone: EventLoopPromise<Void>) {
                self.allDone = allDone
            }
            func channelActive(ctx: ChannelHandlerContext) {
                XCTAssertEqual(.fresh, self.state)
                self.state = .active
            }

            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                XCTAssertEqual(.active, self.state)
                self.state = .read
                var buffer = self.unwrapInboundIn(data)
                XCTAssertEqual(1, buffer.readableBytes)
                XCTAssertEqual([0xff], buffer.readBytes(length: 1)!)
            }

            func channelReadComplete(ctx: ChannelHandlerContext) {
                XCTAssertEqual(.read, self.state)
                self.state = .readComplete
            }

            func errorCaught(ctx: ChannelHandlerContext, error: Error) {
                XCTAssertEqual(.readComplete, self.state)
                self.state = .error
                ctx.close(promise: nil)
            }

            func channelInactive(ctx: ChannelHandlerContext) {
                XCTAssertEqual(.error, self.state)
                self.state = .inactive
                self.allDone.succeed(result: ())
            }
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let serverEL = group.next()
        let clientEL = group.next()
        precondition(serverEL !== clientEL)
        let sc = try SocketChannel(socket: SocketThatHasTheFirstReadSucceedButFailsTheNextWithECONNRESET(protocolFamily: PF_INET), eventLoop: clientEL as! SelectableEventLoop)

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: serverEL)
            .childChannelInitializer { channel in
                var buffer = channel.allocator.buffer(capacity: 4)
                buffer.write(string: "foo")
                return channel.write(NIOAny(buffer))
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait())
        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let allDone: EventLoopPromise<Void> = clientEL.newPromise()

        XCTAssertNoThrow(try sc.eventLoop.submit {
            // this is pretty delicate at the moment:
            // `bind` must be _synchronously_ follow `register`, otherwise in our current implementation, `epoll` will
            // send us `EPOLLHUP`. To have it run synchronously, we need to invoke the `then` on the eventloop that the
            // `register` will succeed.

            sc.register().then {
                sc.pipeline.add(handler: VerifyThingsAreRightHandler(allDone: allDone))
            }.then {
                sc.connect(to: serverChannel.localAddress!)
            }
        }.wait().wait() as Void)
        XCTAssertNoThrow(try allDone.futureResult.wait())
        XCTAssertNoThrow(try sc.syncCloseAcceptingAlreadyClosed())
    }

    func testSocketFailingAsyncCorrectlyTearsTheChannelDownAndDoesntCrash() throws {
        // regression test for #302
        enum DummyError: Error { case dummy }
        class SocketFailingAsyncConnect: Socket {
            init() throws {
                try super.init(protocolFamily: PF_INET, type: Posix.SOCK_STREAM, setNonBlocking: true)
            }

            override func connect(to address: SocketAddress) throws -> Bool {
                _ = try super.connect(to: address)
                return false
            }

            override func finishConnect() throws {
                throw DummyError.dummy
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let sc = try SocketChannel(socket: SocketFailingAsyncConnect(), eventLoop: group.next() as! SelectableEventLoop)

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group.next())
            .bind(host: "127.0.0.1", port: 0)
            .wait())
        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let allDone: EventLoopPromise<Void> = group.next().newPromise()
        let cf = try! sc.eventLoop.submit {
            sc.pipeline.add(handler: VerifyConnectionFailureHandler(allDone: allDone)).then {
                sc.register().then {
                    sc.connect(to: serverChannel.localAddress!)
                }
            }
        }.wait()
        do {
            try cf.wait()
            XCTFail("should've thrown")
        } catch DummyError.dummy {
            // ok
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertNoThrow(try allDone.futureResult.wait())
        XCTAssertNoThrow(try sc.syncCloseAcceptingAlreadyClosed())
    }

    func testSocketErroringSynchronouslyCorrectlyTearsTheChannelDown() throws {
        // regression test for #322
        enum DummyError: Error { case dummy }
        class SocketFailingConnect: Socket {
            init() throws {
                try super.init(protocolFamily: PF_INET, type: Posix.SOCK_STREAM, setNonBlocking: true)
            }

            override func connect(to address: SocketAddress) throws -> Bool {
                throw DummyError.dummy
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let sc = try SocketChannel(socket: SocketFailingConnect(), eventLoop: group.next() as! SelectableEventLoop)

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group.next())
            .bind(host: "127.0.0.1", port: 0)
            .wait())
        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let allDone: EventLoopPromise<Void> = group.next().newPromise()
        try! sc.eventLoop.submit {
            let f = sc.pipeline.add(handler: VerifyConnectionFailureHandler(allDone: allDone)).then {
                sc.register().then {
                    sc.connect(to: serverChannel.localAddress!)
                }
            }
            f.whenSuccess {
                XCTFail("Must not succeed")
            }
            f.whenFailure { err in
                XCTAssertEqual(err as? DummyError, .dummy)
            }
            // We can block here because connect must have failed synchronously.
            XCTAssertTrue(f.isFulfilled)
        }.wait() as Void
        XCTAssertNoThrow(try allDone.futureResult.wait())

        XCTAssertNoThrow(try sc.closeFuture.wait())
        XCTAssertNoThrow(try sc.syncCloseAcceptingAlreadyClosed())
    }

    func testConnectWithECONNREFUSEDGetsTheRightError() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let serverSock = try Socket(protocolFamily: PF_INET, type: Posix.SOCK_STREAM)
        // we deliberately don't set SO_REUSEADDR
        XCTAssertNoThrow(try serverSock.bind(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)))
        let serverSockAddress = try! serverSock.localAddress()
        XCTAssertNoThrow(try serverSock.close())

        // we're just looping here to get a pretty good chance we're hitting both the synchronous and the asynchronous
        // connect path.
        for _ in 0..<64 {
            do {
                _ = try ClientBootstrap(group: group).connect(to: serverSockAddress).wait()
                XCTFail("just worked")
            } catch let error as IOError where error.errnoCode == ECONNREFUSED {
                // OK
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testCloseInUnregister() throws {
        enum DummyError: Error { case dummy }
        class SocketFailingClose: Socket {
            init() throws {
                try super.init(protocolFamily: PF_INET, type: Posix.SOCK_STREAM, setNonBlocking: true)
            }

            override func close() throws {
                _ = try? super.close()
                throw DummyError.dummy
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let sc = try SocketChannel(socket: SocketFailingClose(), eventLoop: group.next() as! SelectableEventLoop)

        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group.next())
            .bind(host: "127.0.0.1", port: 0)
            .wait())
        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        XCTAssertNoThrow(try sc.eventLoop.submit {
            sc.register().then {
                sc.connect(to: serverChannel.localAddress!)
            }
        }.wait().wait() as Void)

        do {
            try sc.eventLoop.submit { () -> EventLoopFuture<Void> in
                let p: EventLoopPromise<Void> = sc.eventLoop.newPromise()
                // this callback must be attached before we call the close
                let f = p.futureResult.map {
                    XCTFail("shouldn't be reached")
                }.thenIfError { err in
                    XCTAssertNotNil(err as? DummyError)
                    return sc.close()
                }
                sc.close(promise: p)
                return f
            }.wait().wait()
            XCTFail("shouldn't be reached")
        } catch ChannelError.alreadyClosed {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }

    }

    func testLazyRegistrationWorksForServerSockets() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let server = try assertNoThrowWithValue(ServerSocketChannel(eventLoop: group.next() as! SelectableEventLoop,
                                                                    group: group,
                                                                    protocolFamily: PF_INET))
        defer {
            XCTAssertNoThrow(try server.close().wait())
        }
        XCTAssertNoThrow(try server.register().wait())
        XCTAssertNoThrow(try server.eventLoop.submit {
            XCTAssertFalse(server.isActive)
        }.wait())
        XCTAssertEqual(0, server.localAddress!.port!)
        XCTAssertNoThrow(try server.bind(to: SocketAddress(ipAddress: "0.0.0.0", port: 0)).wait())
        XCTAssertNotEqual(0, server.localAddress!.port!)
    }

    func testLazyRegistrationWorksForClientSockets() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "localhost", port: 0)
            .wait())

        let client = try SocketChannel(eventLoop: group.next() as! SelectableEventLoop,
                                       protocolFamily: serverChannel.localAddress!.protocolFamily)
        defer {
            XCTAssertNoThrow(try client.close().wait())
        }
        XCTAssertNoThrow(try client.register().wait())
        XCTAssertNoThrow(try client.eventLoop.submit {
            XCTAssertFalse(client.isActive)
        }.wait())
        XCTAssertNoThrow(try client.connect(to: serverChannel.localAddress!).wait())
        XCTAssertTrue(client.isActive)
        XCTAssertEqual(serverChannel.localAddress!, client.remoteAddress!)
    }

    func testFailedRegistrationOfClientSocket() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .bind(host: "localhost", port: 0)
            .wait())
        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }
        do {
            let clientChannel = try ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.add(handler: FailRegistrationAndDelayCloseHandler())
                }
                .connect(to: serverChannel.localAddress!)
                .wait()
            XCTFail("shouldn't have reached this but got \(clientChannel)")
        } catch FailRegistrationAndDelayCloseHandler.RegistrationFailedError.error {
            // ok
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testFailedRegistrationOfAcceptedSocket() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.add(handler: FailRegistrationAndDelayCloseHandler())
            }
            .bind(host: "localhost", port: 0).wait())
        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }
        let clientChannel = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!)
            .wait(), message: "resolver debug info: \(try! resolverDebugInformation(eventLoop: group.next(),host: "localhost", previouslyReceivedResult: serverChannel.localAddress!))")
        XCTAssertNoThrow(try clientChannel.closeFuture.wait() as Void)
    }

    func testFailedRegistrationOfServerSocket() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        do {
            let serverChannel = try ServerBootstrap(group: group)
                .serverChannelInitializer { channel in
                    channel.pipeline.add(handler: FailRegistrationAndDelayCloseHandler())
                }
                .bind(host: "localhost", port: 0).wait()
            XCTFail("shouldn't be reached")
            XCTAssertNoThrow(try serverChannel.close().wait())
        } catch FailRegistrationAndDelayCloseHandler.RegistrationFailedError.error {
            // ok
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testTryingToBindOnPortThatIsAlreadyBoundFailsButDoesNotCrash() throws {
        // this is a regression test for #417

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel1 = try! ServerBootstrap(group: group)
            .bind(host: "localhost", port: 0)
            .wait()
        defer {
            XCTAssertNoThrow(try serverChannel1.close().wait())
        }

        do {
            let serverChannel2 = try ServerBootstrap(group: group)
                .bind(to: serverChannel1.localAddress!)
                .wait()
            XCTFail("shouldn't have succeeded, got two server channels on the same port: \(serverChannel1) and \(serverChannel2)")
        } catch let e as IOError where e.errnoCode == EADDRINUSE {
            // OK
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

fileprivate final class FailRegistrationAndDelayCloseHandler: ChannelOutboundHandler {
    enum RegistrationFailedError: Error { case error }

    typealias OutboundIn = Never

    func register(ctx: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        promise!.fail(error: RegistrationFailedError.error)
    }

    func close(ctx: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        /* for extra nastiness, let's delay close. This makes sure the ChannelPipeline correctly retains the Channel */
        _ = ctx.eventLoop.scheduleTask(in: .milliseconds(10)) {
            ctx.close(mode: mode, promise: promise)
        }
    }
}

fileprivate class VerifyConnectionFailureHandler: ChannelInboundHandler {
    typealias InboundIn = Never
    private let allDone: EventLoopPromise<Void>
    enum State {
        case fresh
        case registered
        case unregistered
    }
    private var state: State = .fresh

    init(allDone: EventLoopPromise<Void>) {
        self.allDone = allDone
    }
    deinit { XCTAssertEqual(.unregistered, self.state) }

    func channelActive(ctx: ChannelHandlerContext) { XCTFail("should never become active") }

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) { XCTFail("should never read") }

    func channelReadComplete(ctx: ChannelHandlerContext) { XCTFail("should never readComplete") }

    func errorCaught(ctx: ChannelHandlerContext, error: Error) { XCTFail("pipeline shouldn't be told about connect error") }

    func channelRegistered(ctx: ChannelHandlerContext) {
        XCTAssertEqual(.fresh, self.state)
        self.state = .registered
        ctx.fireChannelRegistered()
    }

    func channelUnregistered(ctx: ChannelHandlerContext) {
        XCTAssertEqual(.registered, self.state)
        self.state = .unregistered
        self.allDone.succeed(result: ())
        ctx.fireChannelUnregistered()
    }
}
