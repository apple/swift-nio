//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2024 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import NIOConcurrencyHelpers
import NIOEmbedded
import NIOTestUtils
import XCTest

@testable import NIOCore
@testable import NIOPosix

#if os(Linux)
import CNIOLinux
#endif

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

    public func channelRegistered(context: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .unregistered)
        XCTAssertFalse(context.channel.isActive)
        updateState(.registered)
        context.fireChannelRegistered()
    }

    public func channelActive(context: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .registered)
        XCTAssertTrue(context.channel.isActive)
        updateState(.active)
        context.fireChannelActive()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .active)
        XCTAssertFalse(context.channel.isActive)
        updateState(.inactive)
        context.fireChannelInactive()
    }

    public func channelUnregistered(context: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .inactive)
        XCTAssertFalse(context.channel.isActive)
        updateState(.unregistered)
        context.fireChannelUnregistered()
    }
}

final class ChannelTests: XCTestCase {
    func testBasicLifecycle() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverAcceptedChannelPromise = loop.makePromise(of: Channel.self)
        let serverLifecycleHandler = try loop.submit {
            NIOLoopBound(ChannelLifecycleHandler(), eventLoop: loop)
        }.wait()
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: loop)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    serverAcceptedChannelPromise.succeed(channel)
                    return channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(serverLifecycleHandler.value)
                    }
                }.bind(host: "127.0.0.1", port: 0).wait()
        )

        let clientLifecycleHandler = try loop.submit {
            NIOLoopBound(ChannelLifecycleHandler(), eventLoop: loop)
        }.wait()
        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: loop)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(clientLifecycleHandler.value)
                    }
                }
                .connect(to: serverChannel.localAddress!).wait()
        )

        var buffer = clientChannel.allocator.buffer(capacity: 1)
        buffer.writeString("a")
        try clientChannel.writeAndFlush(buffer).wait()

        let serverAcceptedChannel = try serverAcceptedChannelPromise.futureResult.wait()

        // Start shutting stuff down.
        XCTAssertNoThrow(try clientChannel.close().wait())

        // Wait for the close promises. These fire last.
        XCTAssertNoThrow(
            try EventLoopFuture.andAllSucceed(
                [
                    clientChannel.closeFuture,
                    serverAcceptedChannel.closeFuture,
                ],
                on: loop
            ).map {
                XCTAssertEqual(clientLifecycleHandler.value.currentState, .unregistered)
                XCTAssertEqual(serverLifecycleHandler.value.currentState, .unregistered)
                XCTAssertEqual(
                    clientLifecycleHandler.value.stateHistory,
                    [.unregistered, .registered, .active, .inactive, .unregistered]
                )
                XCTAssertEqual(
                    serverLifecycleHandler.value.stateHistory,
                    [.unregistered, .registered, .active, .inactive, .unregistered]
                )
            }.wait()
        )
    }

    func testManyManyWrites() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: 0).wait()
        )

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!).wait()
        )

        // We're going to try to write loads, and loads, and loads of data. In this case, one more
        // write than the iovecs max.
        var buffer = clientChannel.allocator.buffer(capacity: 1)
        for _ in 0..<Socket.writevLimitIOVectors {
            buffer.clear()
            buffer.writeString("a")
            clientChannel.write(buffer, promise: nil)
        }
        buffer.clear()
        buffer.writeString("a")
        try clientChannel.writeAndFlush(buffer).wait()

        // Start shutting stuff down.
        XCTAssertNoThrow(try clientChannel.close().wait())
    }

    func testWritevLotsOfData() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: 0).wait()
        )

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!).wait()
        )

        let bufferSize = 1024 * 1024 * 2
        var buffer = clientChannel.allocator.buffer(capacity: bufferSize)
        for _ in 0..<bufferSize {
            buffer.writeStaticString("a")
        }

        let lotsOfData = Int(Int32.max)
        var written: Int64 = 0
        while written <= lotsOfData {
            clientChannel.write(buffer, promise: nil)
            written += Int64(bufferSize)
        }

        XCTAssertNoThrow(try clientChannel.writeAndFlush(buffer).wait())

        // Start shutting stuff down.
        XCTAssertNoThrow(try clientChannel.close().wait())
    }

    func testParentsOfSocketChannels() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let childChannelPromise = group.next().makePromise(of: Channel.self)
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    childChannelPromise.succeed(channel)
                    return channel.eventLoop.makeSucceededFuture(())
                }.bind(host: "127.0.0.1", port: 0).wait()
        )

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!).wait()
        )

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
        let bufferPool = Pool<PooledBuffer>(maxSize: 16)
        let pwm = NIOPosix.PendingStreamWritesManager(bufferPool: bufferPool)

        XCTAssertTrue(pwm.isEmpty)
        XCTAssertTrue(pwm.isOpen)
        XCTAssertFalse(pwm.isFlushPending)
        XCTAssertTrue(pwm.isWritable)

        try body(pwm)

        XCTAssertTrue(pwm.isEmpty)
        XCTAssertFalse(pwm.isFlushPending)
    }

    /// A frankenstein testing monster. It asserts that for `PendingStreamWritesManager` `pwm` and `EventLoopPromises` `promises`
    /// the following conditions hold:
    ///  - The 'single write operation' is called `exepectedSingleWritabilities.count` number of times with the respective buffer lengths in the array.
    ///  - The 'vector write operation' is called `exepectedVectorWritabilities.count` number of times with the respective buffer lengths in the array.
    ///  - after calling the write operations, the promises have the states in `promiseStates`
    ///
    /// The write operations will all be faked and return the return values provided in `returns`.
    ///
    /// - Parameters:
    ///   - pwm: The `PendingStreamWritesManager` to test.
    ///   - promises: The promises for the writes issued.
    ///   - expectedSingleWritabilities: The expected buffer lengths for the calls to the single write operation.
    ///   - expectedVectorWritabilities: The expected buffer lengths for the calls to the vector write operation.
    ///   - returns: The return values of the fakes write operations (both single and vector).
    ///   - promiseStates: The states of the promises _after_ the write operations are done.
    func assertExpectedWritability(
        pendingWritesManager pwm: PendingStreamWritesManager,
        promises: [EventLoopPromise<Void>],
        expectedSingleWritabilities: [Int]?,
        expectedVectorWritabilities: [[Int]]?,
        expectedFileWritabilities: [(Int, Int)]?,
        returns: [NIOPosix.IOResult<Int>],
        promiseStates: [[Bool]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> OverallWriteResult {
        var everythingState = 0
        var singleState = 0
        var multiState = 0
        var fileState = 0
        let result = try pwm.triggerAppropriateWriteOperations(
            scalarBufferWriteOperation: { buf in
                defer {
                    singleState += 1
                    everythingState += 1
                }
                if let expected = expectedSingleWritabilities {
                    if expected.count > singleState {
                        XCTAssertGreaterThan(returns.count, everythingState)
                        XCTAssertEqual(
                            expected[singleState],
                            buf.count,
                            "in single write \(singleState) (overall \(everythingState)), \(expected[singleState]) bytes expected but \(buf.count) actual"
                        )
                        return returns[everythingState]
                    } else {
                        XCTFail(
                            "single write call \(singleState) but less than \(expected.count) expected",
                            file: (file),
                            line: line
                        )
                        return IOResult.wouldBlock(-1 * (everythingState + 1))
                    }
                } else {
                    XCTFail("single write called on \(buf) but no single writes expected", file: (file), line: line)
                    return IOResult.wouldBlock(-1 * (everythingState + 1))
                }
            },
            vectorBufferWriteOperation: { ptrs in
                defer {
                    multiState += 1
                    everythingState += 1
                }
                if let expected = expectedVectorWritabilities {
                    if expected.count > multiState {
                        XCTAssertGreaterThan(returns.count, everythingState)
                        XCTAssertEqual(
                            expected[multiState],
                            ptrs.map { numericCast($0.iov_len) },
                            "in vector write \(multiState) (overall \(everythingState)), \(expected[multiState]) byte counts expected but \(ptrs.map { $0.iov_len }) actual",
                            file: (file),
                            line: line
                        )
                        return returns[everythingState]
                    } else {
                        XCTFail(
                            "vector write call \(multiState) but less than \(expected.count) expected",
                            file: (file),
                            line: line
                        )
                        return IOResult.wouldBlock(-1 * (everythingState + 1))
                    }
                } else {
                    XCTFail(
                        "vector write called on \(ptrs) but no vector writes expected",
                        file: (file),
                        line: line
                    )
                    return IOResult.wouldBlock(-1 * (everythingState + 1))
                }
            },
            scalarFileWriteOperation: { _, start, end in
                defer {
                    fileState += 1
                    everythingState += 1
                }
                guard let expected = expectedFileWritabilities else {
                    XCTFail(
                        "file write (\(start), \(end)) but no file writes expected",
                        file: (file),
                        line: line
                    )
                    return IOResult.wouldBlock(-1 * (everythingState + 1))
                }

                if expected.count > fileState {
                    XCTAssertGreaterThan(returns.count, everythingState)
                    XCTAssertEqual(
                        expected[fileState].0,
                        start,
                        "in file write \(fileState) (overall \(everythingState)), \(expected[fileState].0) expected as start index but \(start) actual",
                        file: (file),
                        line: line
                    )
                    XCTAssertEqual(
                        expected[fileState].1,
                        end,
                        "in file write \(fileState) (overall \(everythingState)), \(expected[fileState].1) expected as end index but \(end) actual",
                        file: (file),
                        line: line
                    )
                    return returns[everythingState]
                } else {
                    XCTFail(
                        "file write call \(fileState) but less than \(expected.count) expected",
                        file: (file),
                        line: line
                    )
                    return IOResult.wouldBlock(-1 * (everythingState + 1))
                }
            }
        )
        if everythingState > 0 {
            XCTAssertEqual(
                promises.count,
                promiseStates[everythingState - 1].count,
                "number of promises (\(promises.count)) != number of promise states (\(promiseStates[everythingState - 1].count))",
                file: (file),
                line: line
            )
            _ = zip(promises, promiseStates[everythingState - 1]).map { p, pState in
                XCTAssertEqual(
                    p.futureResult.isFulfilled,
                    pState,
                    "promise states incorrect (\(everythingState) callbacks)",
                    file: (file),
                    line: line
                )
            }

            XCTAssertEqual(
                everythingState,
                singleState + multiState + fileState,
                "odd, calls the single/vector/file writes: \(singleState)/\(multiState)/\(fileState) but overall \(everythingState+1)",
                file: (file),
                line: line
            )

            if singleState == 0 {
                XCTAssertNil(expectedSingleWritabilities, "no single writes have been done but we expected some")
            } else {
                XCTAssertEqual(
                    singleState,
                    (expectedSingleWritabilities?.count ?? Int.min),
                    "different number of single writes than expected",
                    file: (file),
                    line: line
                )
            }
            if multiState == 0 {
                XCTAssertNil(expectedVectorWritabilities, "no vector writes have been done but we expected some")
            } else {
                XCTAssertEqual(
                    multiState,
                    (expectedVectorWritabilities?.count ?? Int.min),
                    "different number of vector writes than expected",
                    file: (file),
                    line: line
                )
            }
            if fileState == 0 {
                XCTAssertNil(expectedFileWritabilities, "no file writes have been done but we expected some")
            } else {
                XCTAssertEqual(
                    fileState,
                    (expectedFileWritabilities?.count ?? Int.min),
                    "different number of file writes than expected",
                    file: (file),
                    line: line
                )
            }
        } else {
            XCTAssertEqual(
                0,
                returns.count,
                "no callbacks called but apparently \(returns.count) expected",
                file: (file),
                line: line
            )
            XCTAssertNil(
                expectedSingleWritabilities,
                "no callbacks called but apparently some single writes expected",
                file: (file),
                line: line
            )
            XCTAssertNil(
                expectedVectorWritabilities,
                "no callbacks calles but apparently some vector writes expected",
                file: (file),
                line: line
            )
            XCTAssertNil(
                expectedFileWritabilities,
                "no callbacks calles but apparently some file writes expected",
                file: (file),
                line: line
            )

            _ = zip(promises, promiseStates[0]).map { p, pState in
                XCTAssertEqual(
                    p.futureResult.isFulfilled,
                    pState,
                    "promise states incorrect (no callbacks)",
                    file: (file),
                    line: line
                )
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
            let ps: [EventLoopPromise<Void>] = (0..<2).map { (_: Int) in el.makePromise() }
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])

            XCTAssertFalse(pwm.isEmpty)
            XCTAssertFalse(pwm.isFlushPending)
            XCTAssertEqual(0, pwm.bufferedBytes)

            pwm.markFlushCheckpoint()

            XCTAssertFalse(pwm.isEmpty)
            XCTAssertTrue(pwm.isFlushPending)

            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])

            var result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: [0],
                expectedVectorWritabilities: nil,
                expectedFileWritabilities: nil,
                returns: [.processed(0)],
                promiseStates: [[true, false]]
            )

            XCTAssertFalse(pwm.isEmpty)
            XCTAssertFalse(pwm.isFlushPending)
            XCTAssertEqual(0, pwm.bufferedBytes)
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)

            result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: nil,
                expectedVectorWritabilities: nil,
                expectedFileWritabilities: nil,
                returns: [],
                promiseStates: [[true, false]]
            )
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
            XCTAssertEqual(0, pwm.bufferedBytes)

            pwm.markFlushCheckpoint()

            result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: [0],
                expectedVectorWritabilities: nil,
                expectedFileWritabilities: nil,
                returns: [.processed(0)],
                promiseStates: [[true, true]]
            )
            XCTAssertEqual(0, pwm.bufferedBytes)
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
        }
    }

    /// This tests that we do use the vector write operation if we have more than one flushed and still doesn't write unflushed buffers
    func testPendingWritesUsesVectorWriteOperationAndDoesntWriteTooMuch() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        let emptyBuffer = buffer
        _ = buffer.writeString("1234")

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<3).map { (_: Int) in el.makePromise() }
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            pwm.markFlushCheckpoint()
            XCTAssertEqual(Int64(2 * buffer.readableBytes), pwm.bufferedBytes)
            _ = pwm.add(data: .byteBuffer(emptyBuffer), promise: ps[2])
            XCTAssertEqual(Int64(2 * buffer.readableBytes), pwm.bufferedBytes)

            var result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: nil,
                expectedVectorWritabilities: [[4, 4]],
                expectedFileWritabilities: nil,
                returns: [.processed(8)],
                promiseStates: [[true, true, false]]
            )
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
            XCTAssertEqual(0, pwm.bufferedBytes)

            pwm.markFlushCheckpoint()

            result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: [0],
                expectedVectorWritabilities: nil,
                expectedFileWritabilities: nil,
                returns: [.processed(0)],
                promiseStates: [[true, true, true]]
            )
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
            XCTAssertEqual(0, pwm.bufferedBytes)
        }
    }

    /// Tests that we can handle partial writes correctly.
    func testPendingWritesWorkWithPartialWrites() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        _ = buffer.writeString("1234")
        let totalBytes = Int64(4 * buffer.readableBytes)

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<4).map { (_: Int) in el.makePromise() }
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[2])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[3])
            XCTAssertEqual(totalBytes, pwm.bufferedBytes)
            pwm.markFlushCheckpoint()

            var result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: nil,
                expectedVectorWritabilities: [[4, 4, 4, 4], [3, 4, 4, 4]],
                expectedFileWritabilities: nil,
                returns: [.processed(1), .wouldBlock(0)],
                promiseStates: [[false, false, false, false], [false, false, false, false]]
            )

            XCTAssertEqual(.couldNotWriteEverything, result.writeResult)
            XCTAssertEqual(totalBytes - 1, pwm.bufferedBytes)

            result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: nil,
                expectedVectorWritabilities: [[3, 4, 4, 4], [4, 4]],
                expectedFileWritabilities: nil,
                returns: [.processed(7), .wouldBlock(0)],
                promiseStates: [[true, true, false, false], [true, true, false, false]]

            )
            XCTAssertEqual(.couldNotWriteEverything, result.writeResult)
            XCTAssertEqual(totalBytes - 1 - 7, pwm.bufferedBytes)

            result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: nil,
                expectedVectorWritabilities: [[4, 4]],
                expectedFileWritabilities: nil,
                returns: [.processed(8)],
                promiseStates: [[true, true, true, true], [true, true, true, true]]
            )
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
            XCTAssertEqual(totalBytes - 1 - 7 - 8, pwm.bufferedBytes)
        }
    }

    /// Tests that the spin count works for one long buffer if small bits are written one by one.
    func testPendingWritesSpinCountWorksForSingleWrites() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)

        try withPendingStreamWritesManager { pwm in
            let numberOfBytes = Int(
                1  // first write
                    + pwm.writeSpinCount  // the spins
                    + 1  // so one byte remains at the end
            )
            buffer.clear()
            buffer.writeBytes([UInt8](repeating: 0xff, count: numberOfBytes))
            let ps: [EventLoopPromise<Void>] = (0..<1).map { (_: Int) in el.makePromise() }
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            pwm.markFlushCheckpoint()
            XCTAssertEqual(Int64(numberOfBytes), pwm.bufferedBytes)

            // below, we'll write 1 byte at a time. So the number of bytes offered should decrease by one.
            // The write operation should be repeated until we did it 1 + spin count times and then return `.writtenPartially`.
            // After that, one byte will remain
            var result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: Array((2...numberOfBytes).reversed()),
                expectedVectorWritabilities: nil,
                expectedFileWritabilities: nil,
                returns: Array(repeating: .processed(1), count: numberOfBytes),
                promiseStates: Array(repeating: [false], count: numberOfBytes)
            )
            XCTAssertEqual(.couldNotWriteEverything, result.writeResult)
            XCTAssertEqual(1, pwm.bufferedBytes)

            // we'll now write the one last byte and assert that all the writes are complete
            result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: [1],
                expectedVectorWritabilities: nil,
                expectedFileWritabilities: nil,
                returns: [.processed(1)],
                promiseStates: [[true]]
            )
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
            XCTAssertEqual(0, pwm.bufferedBytes)
        }
    }

    /// Tests that the spin count works if we have many small buffers, which'll be written with the vector write op.
    func testPendingWritesSpinCountWorksForVectorWrites() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)

        try withPendingStreamWritesManager { pwm in
            let numberOfBytes = Int(
                1  // first write
                    + pwm.writeSpinCount  // the spins
                    + 1  // so one byte remains at the end
            )
            buffer.clear()
            buffer.writeBytes([0xff] as [UInt8])
            let ps: [EventLoopPromise<Void>] = (0..<numberOfBytes).map { (_: Int) in
                let p = el.makePromise(of: Void.self)
                _ = pwm.add(data: .byteBuffer(buffer), promise: p)
                return p
            }
            XCTAssertEqual(Int64(numberOfBytes * buffer.readableBytes), pwm.bufferedBytes)
            pwm.markFlushCheckpoint()

            // this will create an `Array` like this (for `numberOfBytes == 4`)
            // `[[1, 1, 1, 1], [1, 1, 1], [1, 1], [1]]`
            let expectedVectorWrites = Array((2...numberOfBytes).reversed()).map { n in
                Array(repeating: 1, count: n)
            }

            // this will create an `Array` like this (for `numberOfBytes == 4`)
            // `[[true, false, false, false], [true, true, false, false], [true, true, true, false]`
            let expectedPromiseStates = Array((2...numberOfBytes).reversed()).map { n in
                Array(repeating: true, count: numberOfBytes - n + 1) + Array(repeating: false, count: n - 1)
            }

            // below, we'll write 1 byte at a time. So the number of bytes offered should decrease by one.
            // The write operation should be repeated until we did it 1 + spin count times and then return `.writtenPartially`.
            // After that, one byte will remain */
            var result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: nil,
                expectedVectorWritabilities: expectedVectorWrites,
                expectedFileWritabilities: nil,
                returns: Array(repeating: .processed(1), count: numberOfBytes),
                promiseStates: expectedPromiseStates
            )
            XCTAssertEqual(.couldNotWriteEverything, result.writeResult)
            XCTAssertEqual(Int64(buffer.readableBytes), pwm.bufferedBytes)

            // we'll now write the one last byte and assert that all the writes are complete
            result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: [1],
                expectedVectorWritabilities: nil,
                expectedFileWritabilities: nil,
                returns: [.processed(1)],
                promiseStates: [Array(repeating: true, count: numberOfBytes)]
            )
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
            XCTAssertEqual(0, pwm.bufferedBytes)
        }
    }

    /// Tests that the spin count works for one long buffer if small bits are written one by one.
    func testPendingWritesCompleteWritesDontConsumeWriteSpinCount() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)

        try withPendingStreamWritesManager { pwm in
            let numberOfWrites = Int(
                1  // first write
                    + pwm.writeSpinCount  // the spins
                    + 1  // so one byte remains at the end
            )
            buffer.clear()
            buffer.writeBytes([UInt8](repeating: 0xff, count: 1))
            let handle = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: -1)
            defer {
                // fake file handle, so don't actually close
                XCTAssertNoThrow(try handle.takeDescriptorOwnership())
            }
            let fileRegion = FileRegion(fileHandle: handle, readerIndex: 0, endIndex: 1)
            let ps: [EventLoopPromise<Void>] = (0..<numberOfWrites).map { _ in el.makePromise() }
            for i in (0..<numberOfWrites) {
                _ = pwm.add(data: i % 2 == 0 ? .byteBuffer(buffer) : .fileRegion(fileRegion), promise: ps[i])
            }
            let totalBytes = (0..<numberOfWrites).map { $0 % 2 == 0 ? buffer.readableBytes : fileRegion.readableBytes }
                .reduce(0, +)
            XCTAssertEqual(Int64(totalBytes), pwm.bufferedBytes)
            pwm.markFlushCheckpoint()

            let expectedPromiseStates = Array((1...numberOfWrites).reversed()).map { n in
                Array(repeating: true, count: numberOfWrites - n + 1) + Array(repeating: false, count: n - 1)
            }
            // below, we'll write 1 byte at a time. So the number of bytes offered should decrease by one.
            // The write operation should be repeated until we did it 1 + spin count times and then return `.writtenPartially`.
            // After that, one byte will remain
            let result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: Array(repeating: 1, count: numberOfWrites / 2),
                expectedVectorWritabilities: nil,
                expectedFileWritabilities: Array(repeating: (0, 1), count: numberOfWrites / 2),
                returns: Array(repeating: .processed(1), count: numberOfWrites),
                promiseStates: expectedPromiseStates
            )

            XCTAssertEqual(0, pwm.bufferedBytes)
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
        }
    }

    /// Test that cancellation of the Channel writes works correctly.
    func testPendingWritesCancellationWorksCorrectly() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        let emptyBuffer = buffer
        _ = buffer.writeString("1234")

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<3).map { (_: Int) in el.makePromise() }
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            let totalBytes = Int64(buffer.readableBytes * 2)
            XCTAssertEqual(totalBytes, pwm.bufferedBytes)
            pwm.markFlushCheckpoint()
            _ = pwm.add(data: .byteBuffer(emptyBuffer), promise: ps[2])
            XCTAssertEqual(totalBytes, pwm.bufferedBytes)

            let result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: nil,
                expectedVectorWritabilities: [[4, 4], [2, 4]],
                expectedFileWritabilities: nil,
                returns: [.processed(2), .wouldBlock(0)],
                promiseStates: [[false, false, false], [false, false, false]]
            )
            XCTAssertEqual(.couldNotWriteEverything, result.writeResult)
            XCTAssertEqual(totalBytes - 2, pwm.bufferedBytes)

            _ = pwm.failAll(error: ChannelError.operationUnsupported)

            XCTAssertTrue(ps.map { $0.futureResult.isFulfilled }.allSatisfy { $0 })
        }
    }

    /// Test that with a few massive buffers, we don't offer more than we should to `writev` if the individual chunks fit.
    func testPendingWritesNoMoreThanWritevLimitIsWritten() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator(
            hookedMalloc: { _ in UnsafeMutableRawPointer(bitPattern: 0xdeadbee)! },
            hookedRealloc: { _, _ in UnsafeMutableRawPointer(bitPattern: 0xdeadbee)! },
            hookedFree: { _ in },
            hookedMemcpy: { _, _, _ in }
        )
        // each buffer is half the writev limit
        let halfTheWriteVLimit = Socket.writevLimitBytes / 2
        var buffer = alloc.buffer(capacity: halfTheWriteVLimit)
        buffer.moveReaderIndex(to: 0)
        buffer.moveWriterIndex(to: halfTheWriteVLimit)

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<3).map { (_: Int) in el.makePromise() }
            // add 1.5x the writev limit
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[2])
            XCTAssertEqual(Int64(buffer.readableBytes * 3), pwm.bufferedBytes)
            pwm.markFlushCheckpoint()

            let result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: [halfTheWriteVLimit],
                expectedVectorWritabilities: [[halfTheWriteVLimit, halfTheWriteVLimit]],
                expectedFileWritabilities: nil,
                returns: [.processed(2 * halfTheWriteVLimit), .processed(halfTheWriteVLimit)],
                promiseStates: [[true, true, false], [true, true, true]]
            )
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
            XCTAssertEqual(0, pwm.bufferedBytes)
        }
    }

    /// Test that with a massive buffers (bigger than writev size), we don't offer more than we should to `writev`.
    func testPendingWritesNoMoreThanWritevLimitIsWrittenInOneMassiveChunk() throws {
        if MemoryLayout<Int>.size == MemoryLayout<Int32>.size {  // skip this test on 32bit system
            return
        }

        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator(
            hookedMalloc: { _ in UnsafeMutableRawPointer(bitPattern: 0xdeadbee)! },
            hookedRealloc: { _, _ in UnsafeMutableRawPointer(bitPattern: 0xdeadbee)! },
            hookedFree: { _ in },
            hookedMemcpy: { _, _, _ in }
        )

        let biggerThanWriteV = Socket.writevLimitBytes + 23
        var buffer = alloc.buffer(capacity: biggerThanWriteV)
        buffer.moveReaderIndex(to: 0)
        buffer.moveWriterIndex(to: biggerThanWriteV)

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<3).map { (_: Int) in el.makePromise() }
            var totalBytes: Int64 = 0

            // add 1.5x the writev limit
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            totalBytes += Int64(buffer.readableBytes * 2)
            XCTAssertEqual(totalBytes, pwm.bufferedBytes)
            buffer.moveWriterIndex(to: 100)
            totalBytes += Int64(buffer.readableBytes)
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[2])
            XCTAssertEqual(totalBytes, pwm.bufferedBytes)

            pwm.markFlushCheckpoint()

            let result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: nil,
                expectedVectorWritabilities: [
                    [Socket.writevLimitBytes],
                    [23],
                    [Socket.writevLimitBytes],
                    [23, 100],
                ],
                expectedFileWritabilities: nil,
                returns: [
                    .processed(Socket.writevLimitBytes),
                    // Xcode
                    .processed(23),
                    // needs
                    .processed(Socket.writevLimitBytes),
                    // help
                    .processed(23 + 100),
                ],
                promiseStates: [
                    [false, false, false],
                    // Xcode
                    [true, false, false],
                    // needs
                    [true, false, false],
                    // help
                    [true, true, true],
                ]
            )
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
            XCTAssertEqual(0, pwm.bufferedBytes)
            pwm.markFlushCheckpoint()
        }
    }

    func testPendingWritesFileRegion() throws {
        let el = EmbeddedEventLoop()
        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<2).map { (_: Int) in el.makePromise() }

            let fh1 = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: -1)
            let fh2 = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: -2)
            let fr1 = FileRegion(fileHandle: fh1, readerIndex: 12, endIndex: 14)
            let fr2 = FileRegion(fileHandle: fh2, readerIndex: 0, endIndex: 2)
            defer {
                // fake descriptors, so shouldn't be closed.
                XCTAssertNoThrow(try fh1.takeDescriptorOwnership())
                XCTAssertNoThrow(try fh2.takeDescriptorOwnership())
            }
            var totalBytes: Int64 = 0
            _ = pwm.add(data: .fileRegion(fr1), promise: ps[0])
            totalBytes += Int64(fr1.readableBytes)
            XCTAssertEqual(totalBytes, pwm.bufferedBytes)
            pwm.markFlushCheckpoint()
            _ = pwm.add(data: .fileRegion(fr2), promise: ps[1])
            totalBytes += Int64(fr2.readableBytes)
            XCTAssertEqual(totalBytes, pwm.bufferedBytes)

            var result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: nil,
                expectedVectorWritabilities: nil,
                expectedFileWritabilities: [(12, 14)],
                returns: [.processed(2)],
                promiseStates: [[true, false]]
            )
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
            totalBytes -= Int64(fr1.readableBytes)
            XCTAssertEqual(totalBytes, pwm.bufferedBytes)

            result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: nil,
                expectedVectorWritabilities: nil,
                expectedFileWritabilities: nil,
                returns: [],
                promiseStates: [[true, false]]
            )
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
            XCTAssertEqual(totalBytes, pwm.bufferedBytes)
            pwm.markFlushCheckpoint()

            result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: nil,
                expectedVectorWritabilities: nil,
                expectedFileWritabilities: [(0, 2), (1, 2)],
                returns: [.processed(1), .processed(1)],
                promiseStates: [[true, false], [true, true]]
            )

            totalBytes -= Int64(fr2.readableBytes)
            XCTAssertEqual(totalBytes, pwm.bufferedBytes)
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
        }
    }

    func testPendingWritesEmptyFileRegion() throws {
        let el = EmbeddedEventLoop()
        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<1).map { (_: Int) in el.makePromise() }

            let fh = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: -1)
            let fr = FileRegion(fileHandle: fh, readerIndex: 99, endIndex: 99)
            defer {
                // fake descriptor, so shouldn't be closed.
                XCTAssertNoThrow(try fh.takeDescriptorOwnership())
            }
            _ = pwm.add(data: .fileRegion(fr), promise: ps[0])
            XCTAssertEqual(0, pwm.bufferedBytes)
            pwm.markFlushCheckpoint()

            let result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: nil,
                expectedVectorWritabilities: nil,
                expectedFileWritabilities: [(99, 99)],
                returns: [.processed(0)],
                promiseStates: [[true]]
            )

            XCTAssertEqual(0, pwm.bufferedBytes)
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
        }
    }

    func testPendingWritesInterleavedBuffersAndFiles() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        _ = buffer.writeString("1234")

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<5).map { (_: Int) in el.makePromise() }

            let fh1 = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: -1)
            let fh2 = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: -1)
            let fr1 = FileRegion(fileHandle: fh1, readerIndex: 99, endIndex: 99)
            let fr2 = FileRegion(fileHandle: fh1, readerIndex: 0, endIndex: 10)
            defer {
                // fake descriptors, so shouldn't be closed.
                XCTAssertNoThrow(try fh1.takeDescriptorOwnership())
                XCTAssertNoThrow(try fh2.takeDescriptorOwnership())
            }

            var totalBytes: Int64 = 0
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            _ = pwm.add(data: .fileRegion(fr1), promise: ps[2])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[3])
            _ = pwm.add(data: .fileRegion(fr2), promise: ps[4])
            totalBytes += Int64(
                buffer.readableBytes + buffer.readableBytes + fr1.readableBytes + buffer.readableBytes
                    + fr2.readableBytes
            )
            XCTAssertEqual(totalBytes, pwm.bufferedBytes)
            pwm.markFlushCheckpoint()

            var result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: [4, 3, 2, 1],
                expectedVectorWritabilities: [[4, 4]],
                expectedFileWritabilities: [(99, 99), (0, 10), (3, 10), (6, 10)],
                returns: [
                    .processed(8), .processed(0), .processed(1), .processed(1), .processed(1), .processed(1),
                    .wouldBlock(3), .processed(3), .wouldBlock(0),
                ],
                promiseStates: [
                    [true, true, false, false, false],
                    [true, true, true, false, false],
                    [true, true, true, false, false],
                    [true, true, true, false, false],
                    [true, true, true, false, false],
                    [true, true, true, true, false],
                    [true, true, true, true, false],
                    [true, true, true, true, false],
                    [true, true, true, true, false],
                ]
            )

            totalBytes -= (4 + 4 + 0 + 4 + 6)
            XCTAssertEqual(totalBytes, pwm.bufferedBytes)
            XCTAssertEqual(.couldNotWriteEverything, result.writeResult)

            result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: nil,
                expectedVectorWritabilities: nil,
                expectedFileWritabilities: [(6, 10)],
                returns: [.processed(4)],
                promiseStates: [[true, true, true, true, true]]
            )

            totalBytes -= 4
            XCTAssertEqual(totalBytes, pwm.bufferedBytes)
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
        }
    }

    func testTwoFlushedNonEmptyWritesFollowedByUnflushedEmpty() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        let emptyBuffer = buffer
        _ = buffer.writeString("1234")

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<3).map { (_: Int) in el.makePromise() }

            pwm.markFlushCheckpoint()
            XCTAssertEqual(0, pwm.bufferedBytes)

            // let's start with no writes and just a flush
            var result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: nil,
                expectedVectorWritabilities: nil,
                expectedFileWritabilities: nil,
                returns: [],
                promiseStates: [[false, false, false]]
            )

            // let's add a few writes but still without any promises
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            XCTAssertEqual(Int64(buffer.readableBytes * 2), pwm.bufferedBytes)
            pwm.markFlushCheckpoint()

            _ = pwm.add(data: .byteBuffer(emptyBuffer), promise: ps[2])
            XCTAssertEqual(Int64(buffer.readableBytes * 2), pwm.bufferedBytes)

            result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: nil,
                expectedVectorWritabilities: [[4, 4]],
                expectedFileWritabilities: nil,
                returns: [.processed(8)],
                promiseStates: [[true, true, false]]
            )
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
            XCTAssertEqual(0, pwm.bufferedBytes)

            pwm.markFlushCheckpoint()

            result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: [0],
                expectedVectorWritabilities: nil,
                expectedFileWritabilities: nil,
                returns: [.processed(0)],
                promiseStates: [[true, true, true]]
            )

            XCTAssertEqual(0, pwm.bufferedBytes)
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
        }
    }

    func testPendingWritesWorksWithManyEmptyWrites() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        let emptyBuffer = alloc.buffer(capacity: 12)

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<3).map { (_: Int) in el.makePromise() }
            _ = pwm.add(data: .byteBuffer(emptyBuffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(emptyBuffer), promise: ps[1])
            XCTAssertEqual(0, pwm.bufferedBytes)
            pwm.markFlushCheckpoint()
            _ = pwm.add(data: .byteBuffer(emptyBuffer), promise: ps[2])
            XCTAssertEqual(0, pwm.bufferedBytes)

            var result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: nil,
                expectedVectorWritabilities: [[0, 0]],
                expectedFileWritabilities: nil,
                returns: [.processed(0)],
                promiseStates: [[true, true, false]]
            )
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
            XCTAssertEqual(0, pwm.bufferedBytes)

            pwm.markFlushCheckpoint()

            result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: [0],
                expectedVectorWritabilities: nil,
                expectedFileWritabilities: nil,
                returns: [.processed(0)],
                promiseStates: [[true, true, true]]
            )

            XCTAssertEqual(0, pwm.bufferedBytes)
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
        }
    }

    func testPendingWritesCloseDuringVectorWrite() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        buffer.writeString("1234")

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<3).map { (_: Int) in el.makePromise() }
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[0])
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[1])
            XCTAssertEqual(Int64(buffer.readableBytes * 2), pwm.bufferedBytes)
            pwm.markFlushCheckpoint()
            _ = pwm.add(data: .byteBuffer(buffer), promise: ps[2])
            XCTAssertEqual(Int64(buffer.readableBytes * 3), pwm.bufferedBytes)

            ps[0].futureResult.assumeIsolated().whenComplete { (_: Result<Void, Error>) in
                _ = pwm.failAll(error: ChannelError.inputClosed)
            }

            let result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: nil,
                expectedVectorWritabilities: [[4, 4]],
                expectedFileWritabilities: nil,
                returns: [.processed(4)],
                promiseStates: [[true, true, true]]
            )

            XCTAssertEqual(0, pwm.bufferedBytes)
            XCTAssertEqual(.writtenCompletely(.closed(nil)), result.writeResult)
            XCTAssertNoThrow(try ps[0].futureResult.wait())
            XCTAssertThrowsError(try ps[1].futureResult.wait())
            XCTAssertThrowsError(try ps[2].futureResult.wait())
        }
    }

    func testPendingWritesMoreThanWritevIOVectorLimit() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)
        buffer.writeString("1234")

        try withPendingStreamWritesManager { pwm in
            var totalBytes: Int64 = 0
            let ps: [EventLoopPromise<Void>] = (0...Socket.writevLimitIOVectors).map { (_: Int) in el.makePromise() }
            for p in ps {
                _ = pwm.add(data: .byteBuffer(buffer), promise: p)
                totalBytes += Int64(buffer.readableBytes)
                XCTAssertEqual(totalBytes, pwm.bufferedBytes)
            }
            pwm.markFlushCheckpoint()

            var result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: [4],
                expectedVectorWritabilities: [Array(repeating: 4, count: Socket.writevLimitIOVectors)],
                expectedFileWritabilities: nil,
                returns: [.processed(4 * Socket.writevLimitIOVectors), .wouldBlock(0)],
                promiseStates: [
                    Array(repeating: true, count: Socket.writevLimitIOVectors) + [false],
                    Array(repeating: true, count: Socket.writevLimitIOVectors) + [false],
                ]
            )
            totalBytes -= Int64(buffer.readableBytes * Socket.writevLimitIOVectors)
            XCTAssertEqual(totalBytes, pwm.bufferedBytes)
            XCTAssertEqual(.couldNotWriteEverything, result.writeResult)

            result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: [4],
                expectedVectorWritabilities: nil,
                expectedFileWritabilities: nil,
                returns: [.processed(4)],
                promiseStates: [Array(repeating: true, count: Socket.writevLimitIOVectors + 1)]
            )
            XCTAssertEqual(0, pwm.bufferedBytes)
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
        }
    }

    func testPendingWritesIsHappyWhenSendfileReturnsWouldBlockButWroteFully() throws {
        let el = EmbeddedEventLoop()
        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<Void>] = (0..<1).map { (_: Int) in el.makePromise() }

            let fh = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: -1)
            let fr = FileRegion(fileHandle: fh, readerIndex: 0, endIndex: 8192)
            defer {
                // fake descriptor, so shouldn't be closed.
                XCTAssertNoThrow(try fh.takeDescriptorOwnership())
            }

            _ = pwm.add(data: .fileRegion(fr), promise: ps[0])
            XCTAssertEqual(Int64(fr.readableBytes), pwm.bufferedBytes)
            pwm.markFlushCheckpoint()

            let result = try assertExpectedWritability(
                pendingWritesManager: pwm,
                promises: ps,
                expectedSingleWritabilities: nil,
                expectedVectorWritabilities: nil,
                expectedFileWritabilities: [(0, 8192)],
                returns: [.wouldBlock(8192)],
                promiseStates: [[true]]
            )

            XCTAssertEqual(0, pwm.bufferedBytes)
            XCTAssertEqual(.writtenCompletely(.open), result.writeResult)
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
                .channelOption(.connectTimeout, value: .milliseconds(10))
                .connect(to: SocketAddress.makeAddressResolvingHost("198.51.100.254", port: 65535)).wait()
            XCTFail()
        } catch let err as ChannelError {
            if case .connectTimeout(_) = err {
                // expected, sadly there is no "if not case"
            } else {
                XCTFail()
            }
        } catch let err as IOError
            where err.errnoCode == ENETDOWN || err.errnoCode == ENETUNREACH || err.errnoCode == ECONNREFUSED
        {
            // we need to accept those too unfortunately
            print("WARNING: \(#function) did not meaningfully test anything, received \(err)")
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
                .connect(to: SocketAddress.makeAddressResolvingHost("198.51.100.254", port: 65535)).wait()
            XCTFail()
        } catch let err as ChannelError {
            if case .connectTimeout(_) = err {
                // expected, sadly there is no "if not case"
            } else {
                XCTFail()
            }
        } catch let err as IOError
            where err.errnoCode == ENETDOWN || err.errnoCode == ENETUNREACH || err.errnoCode == ECONNREFUSED
        {
            // we need to accept those too unfortunately
            print("WARNING: \(#function) did not meaningfully test anything, received \(err)")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testCloseOutput() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let server = try assertNoThrowWithValue(ServerSocket(protocolFamily: .inet))
        defer {
            XCTAssertNoThrow(try server.close())
        }
        try server.bind(to: SocketAddress.makeAddressResolvingHost("127.0.0.1", port: 0))
        try server.listen()

        let shutdownPromise = group.next().makePromise(of: Void.self)
        let receivedPromise = group.next().makePromise(of: ByteBuffer.self)
        let future = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let verificationHandler = ShutdownVerificationHandler(
                        shutdownEvent: .output,
                        promise: shutdownPromise
                    )
                    try channel.pipeline.syncOperations.addHandler(verificationHandler)

                    let byteCountingHandler = ByteCountingHandler(numBytes: 4, promise: receivedPromise)
                    try channel.pipeline.syncOperations.addHandler(byteCountingHandler)
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
        buffer.writeString("1234")

        try channel.writeAndFlush(buffer).wait()
        try channel.close(mode: .output).wait()

        try shutdownPromise.futureResult.wait()
        XCTAssertThrowsError(try channel.writeAndFlush(buffer).wait()) { error in
            XCTAssertEqual(.outputClosed, error as? ChannelError)
        }
        let written = try buffer.withUnsafeReadableBytes { p in
            try accepted.write(pointer: UnsafeRawBufferPointer(rebasing: p.prefix(4)))
        }
        if case .processed(let numBytes) = written {
            XCTAssertEqual(4, numBytes)
        } else {
            XCTFail()
        }

        let received = try receivedPromise.futureResult.wait()
        XCTAssertEqual(received, buffer)
    }

    func testCloseInput() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let server = try assertNoThrowWithValue(ServerSocket(protocolFamily: .inet))
        defer {
            XCTAssertNoThrow(try server.close())
        }
        try server.bind(to: SocketAddress.makeAddressResolvingHost("127.0.0.1", port: 0))
        try server.listen()

        final class VerifyNoReadHandler: ChannelInboundHandler, Sendable {
            typealias InboundIn = ByteBuffer

            public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                XCTFail("Received data: \(data)")
            }
        }

        let promise = group.next().makePromise(of: Void.self)
        let future = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(VerifyNoReadHandler()).flatMapThrowing {
                    let verificationHandler = ShutdownVerificationHandler(
                        shutdownEvent: .input,
                        promise: promise
                    )
                    return try channel.pipeline.syncOperations.addHandler(verificationHandler)
                }
            }
            .channelOption(.allowRemoteHalfClosure, value: true)
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

        try promise.futureResult.wait()

        var buffer = channel.allocator.buffer(capacity: 12)
        buffer.writeString("1234")

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

        let server = try assertNoThrowWithValue(ServerSocket(protocolFamily: .inet))
        defer {
            XCTAssertNoThrow(try server.close())
        }
        try server.bind(to: SocketAddress.makeAddressResolvingHost("127.0.0.1", port: 0))
        try server.listen()

        let shutdownPromise = group.next().makePromise(of: Void.self)
        let future = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let verificationHandler = ShutdownVerificationHandler(
                        shutdownEvent: .input,
                        promise: shutdownPromise
                    )
                    try channel.pipeline.syncOperations.addHandler(verificationHandler)
                }
            }
            .channelOption(.allowRemoteHalfClosure, value: true)
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

        try shutdownPromise.futureResult.wait()

        var buffer = channel.allocator.buffer(capacity: 12)
        buffer.writeString("1234")

        try channel.writeAndFlush(buffer).wait()
    }

    func testInputAndOutputClosedResultsInFullClosure() throws {
        final class PromiseOnChildChannelInitHandler: ChannelInboundHandler, Sendable {
            typealias InboundIn = ByteBuffer
            private let promise: EventLoopPromise<Channel>

            init(promise: EventLoopPromise<Channel>) {
                self.promise = promise
            }

            func channelActive(context: ChannelHandlerContext) {
                self.promise.succeed(context.channel)
                context.fireChannelActive()
            }
        }

        final class ChannelInactiveHandler: ChannelInboundHandler, Sendable {
            typealias InboundIn = ByteBuffer
            private let promise: EventLoopPromise<Void>

            init(promise: EventLoopPromise<Void>) {
                self.promise = promise
            }

            func channelInactive(context: ChannelHandlerContext) {
                self.promise.succeed()
                context.fireChannelActive()
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChildChannelInitPromise: EventLoopPromise<Channel> = group.next().makePromise()
        let serverChildChannelInactivePromise: EventLoopPromise<Void> = group.next().makePromise()
        let serverChannel: Channel = try ServerBootstrap(group: group)
            .childChannelOption(.allowRemoteHalfClosure, value: true)  // Important!
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers(
                    PromiseOnChildChannelInitHandler(promise: serverChildChannelInitPromise),
                    ChannelInactiveHandler(promise: serverChildChannelInactivePromise)
                )
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let clientChannelInactivePromise: EventLoopPromise<Void> = group.next().makePromise()
        let clientChannel = try ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(ChannelInactiveHandler(promise: clientChannelInactivePromise))
            }
            .connect(to: serverChannel.localAddress!)
            .wait()

        XCTAssertNoThrow(try clientChannel.setOption(.allowRemoteHalfClosure, value: true).wait())

        // Ok, the connection is definitely up.
        // Now retrieve the client channel that our server opened for the connection to our client.
        let serverConnectionChildChannel = try serverChildChannelInitPromise.futureResult.wait()

        // First we close the output of the connection channel on the server.
        // This results in the input of the clientChannel being closed.
        XCTAssertNoThrow(try serverConnectionChildChannel.close(mode: .output).wait())
        // Now we close the output of the clientChannel.
        // Given that the the input of the clientChannel is already closed,
        // this should escalate to a full closure of the clientChannel.
        XCTAssertNoThrow(try clientChannel.close(mode: .output).wait())

        // Assert that full closure of client channel occurred by verifying
        // that channelInactive was invoked on the channel.
        XCTAssertNoThrow(try clientChannelInactivePromise.futureResult.wait())

        // Assert that the server child channel becomes inactive now that the
        // client channel has been closed completely.
        XCTAssertNoThrow(try serverChildChannelInactivePromise.futureResult.wait())

        // Additional assertion: trying to close the clientChannel manually
        // should fail as it is closed already.
        XCTAssertThrowsError(try clientChannel.close().wait()) { error in
            if let error = error as? ChannelError {
                XCTAssertEqual(ChannelError.alreadyClosed, error)
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
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

        public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            switch event {
            case let ev as ChannelEvent:
                switch ev {
                case .inputClosed:
                    XCTAssertFalse(inputShutdownEventReceived)
                    inputShutdownEventReceived = true

                    if shutdownEvent == .input {
                        promise.succeed(())
                    }
                case .outputClosed:
                    XCTAssertFalse(outputShutdownEventReceived)
                    outputShutdownEventReceived = true

                    if shutdownEvent == .output {
                        promise.succeed(())
                    }
                }

                fallthrough
            default:
                context.fireUserInboundEventTriggered(event)
            }
        }

        public func waitForEvent() {
            // We always notify it with a success so just force it with !
            try! promise.futureResult.wait()
        }

        public func channelInactive(context: ChannelHandlerContext) {
            switch shutdownEvent {
            case .input:
                XCTAssertTrue(inputShutdownEventReceived)
                XCTAssertFalse(outputShutdownEventReceived)
            case .output:
                XCTAssertFalse(inputShutdownEventReceived)
                XCTAssertTrue(outputShutdownEventReceived)
            }

            promise.succeed(())
        }
    }

    func testWeDontCrashIfChannelReleasesBeforePipeline() throws {
        final class StuffHandler: ChannelInboundHandler, Sendable {
            typealias InboundIn = Never

            let promise: EventLoopPromise<ChannelPipeline>

            init(promise: EventLoopPromise<ChannelPipeline>) {
                self.promise = promise
            }

            func channelRegistered(context: ChannelHandlerContext) {
                self.promise.succeed(context.channel.pipeline)
            }
        }
        weak var weakClientChannel: Channel? = nil
        weak var weakServerChannel: Channel? = nil
        weak var weakServerChildChannel: Channel? = nil

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let promise = group.next().makePromise(of: ChannelPipeline.self)

        try {
            let serverChildChannelPromise = group.next().makePromise(of: Channel.self)
            let serverChannel = try assertNoThrowWithValue(
                ServerBootstrap(group: group)
                    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                    .childChannelInitializer { channel in
                        serverChildChannelPromise.succeed(channel)
                        channel.close(promise: nil)
                        return channel.eventLoop.makeSucceededFuture(())
                    }
                    .bind(host: "127.0.0.1", port: 0).wait()
            )

            let clientChannel = try assertNoThrowWithValue(
                ClientBootstrap(group: group)
                    .channelInitializer {
                        $0.pipeline.addHandler(StuffHandler(promise: promise))
                    }
                    .connect(to: serverChannel.localAddress!).wait()
            )
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
        XCTAssertThrowsError(
            try pipeline.eventLoop.submit { () -> Channel in
                XCTAssertTrue(pipeline.channel is DeadChannel)
                return pipeline.channel
            }.wait().writeAndFlush(()).wait()
        ) { error in
            XCTAssertEqual(.ioOnClosedChannel, error as? ChannelError)
        }

        // Annoyingly it's totally possible to get to this stage and have the channels
        // not yet be entirely freed on the background thread. There is no way we can guarantee
        // that this hasn't happened, so we wait for up to a second to let this happen. If it hasn't
        // happened in one second, we assume it never will.
        assert(weakClientChannel == nil, within: .seconds(1), "weakClientChannel not nil, looks like we leaked it!")
        assert(weakServerChannel == nil, within: .seconds(1), "weakServerChannel not nil, looks like we leaked it!")
        assert(
            weakServerChildChannel == nil,
            within: .seconds(1),
            "weakServerChildChannel not nil, looks like we leaked it!"
        )
    }

    func testAskForLocalAndRemoteAddressesAfterChannelIsClosed() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: 0).wait()
        )

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!).wait()
        )

        // Start shutting stuff down.
        XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        XCTAssertNoThrow(try clientChannel.syncCloseAcceptingAlreadyClosed())

        XCTAssertNoThrow(try serverChannel.closeFuture.wait())
        XCTAssertNoThrow(try clientChannel.closeFuture.wait())

        // Schedule on the EventLoop to ensure we scheduled the cleanup of the cached addresses before.
        XCTAssertNoThrow(
            try group.next().submit {
                for f in [
                    serverChannel.remoteAddress, serverChannel.localAddress, clientChannel.remoteAddress,
                    clientChannel.localAddress,
                ] {
                    XCTAssertNil(f)
                }
            }.wait()
        )

    }

    func testReceiveAddressAfterAccept() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        final class AddressVerificationHandler: ChannelInboundHandler, Sendable {
            typealias InboundIn = Never

            public func channelActive(context: ChannelHandlerContext) {
                XCTAssertNotNil(context.channel.localAddress)
                XCTAssertNotNil(context.channel.remoteAddress)
                context.channel.close(promise: nil)
            }
        }

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { ch in
                    ch.pipeline.addHandler(AddressVerificationHandler())
                }
                .bind(host: "127.0.0.1", port: 0).wait()
        )

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!).wait()
        )

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
            private var context: ChannelHandlerContext!
            private var readCountPromise: EventLoopPromise<Void>!
            private var waitingForReadPromise: EventLoopPromise<Void>?

            func handlerAdded(context: ChannelHandlerContext) {
                self.context = context
                self.readCountPromise = context.eventLoop.makePromise()
            }

            func expectRead(loop: EventLoop) -> EventLoopFuture<Void> {
                loop.assumeIsolated().submit {
                    self.waitingForReadPromise = loop.makePromise()
                }.assumeIsolated().flatMap {
                    self.waitingForReadPromise!.futureResult
                }.nonisolated()
            }

            func channelReadComplete(context: ChannelHandlerContext) {
                self.waitingForReadPromise?.succeed(())
                self.waitingForReadPromise = nil
            }

            func read(context: ChannelHandlerContext) {
                self.reads += 1

                // Allow the first read through.
                if self.reads == 1 {
                    self.context.read()
                }
            }

            func issueDelayedRead() {
                self.context.read()
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let loopBoundDelayer = try loop.next().submit { NIOLoopBound(ReadDelayer(), eventLoop: loop) }.wait()
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers(loopBoundDelayer.value)
                    }
                }
                .bind(host: "127.0.0.1", port: 0).wait()
        )

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!).wait()
        )

        // We send a first write and expect it to arrive.
        var buffer = clientChannel.allocator.buffer(capacity: 12)
        let firstReadFuture = try loop.submit {
            loopBoundDelayer.value.expectRead(loop: loop)
        }.wait()
        buffer.writeStaticString("hello, world")
        XCTAssertNoThrow(try clientChannel.writeAndFlush(buffer).wait())
        XCTAssertNoThrow(try firstReadFuture.wait())

        // We send a second write. This won't arrive immediately.
        XCTAssertNoThrow(try clientChannel.writeAndFlush(buffer).wait())
        let readFuture = try loop.submit {
            loopBoundDelayer.value.expectRead(loop: loop)
        }.wait()
        try serverChannel.eventLoop.scheduleTask(in: .milliseconds(100)) {
            XCTAssertFalse(readFuture.isFulfilled)
        }.futureResult.wait()

        // Ok, now let it proceed.
        XCTAssertNoThrow(
            try loop.submit {
                XCTAssertEqual(loopBoundDelayer.value.reads, 2)
                loopBoundDelayer.value.issueDelayedRead()
            }.wait()
        )

        // The read should go through.
        XCTAssertNoThrow(try readFuture.wait())
    }

    func testNoChannelReadBeforeEOFIfNoAutoRead() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        final class VerifyNoReadBeforeEOFHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            var expectingData: Bool = false

            public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                if !self.expectingData {
                    XCTFail("Received data before we expected it.")
                } else {
                    let data = Self.unwrapInboundIn(data)
                    XCTAssertEqual(data.getString(at: data.readerIndex, length: data.readableBytes), "test")
                }
            }
        }

        let loopBoundVerifyHandler = try loop.submit {
            NIOLoopBound(VerifyNoReadBeforeEOFHandler(), eventLoop: loop)
        }.wait()

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(.autoRead, value: false)
                .childChannelInitializer { ch in
                    ch.eventLoop.makeCompletedFuture {
                        try ch.pipeline.syncOperations.addHandler(loopBoundVerifyHandler.value)
                    }
                }
                .bind(host: "127.0.0.1", port: 0).wait()
        )

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!).wait()
        )
        var buffer = clientChannel.allocator.buffer(capacity: 8)
        buffer.writeString("test")
        try clientChannel.writeAndFlush(buffer).wait()

        // Wait for 100 ms. No data should be delivered.
        usleep(100 * 1000)

        // Now we send close. This should deliver data.
        try loop.flatSubmit {
            loopBoundVerifyHandler.value.expectingData = true
            return clientChannel.close()
        }.wait()
        try serverChannel.close().wait()
    }

    func testCloseInEOFdChannelReadBehavesCorrectly() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        final class VerifyEOFReadOrderingAndCloseInChannelReadHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            private var seenEOF: Bool = false
            private var numberOfChannelReads: Int = 0

            func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
                if case .some(ChannelEvent.inputClosed) = event as? ChannelEvent {
                    self.seenEOF = true
                }
                context.fireUserInboundEventTriggered(event)
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                if self.seenEOF {
                    XCTFail(
                        "Should not be called before seeing the EOF as autoRead is false and we did not call read(), but received \(self.unwrapInboundIn(data))"
                    )
                }
                self.numberOfChannelReads += 1
                let buffer = Self.unwrapInboundIn(data)
                XCTAssertLessThanOrEqual(buffer.readableBytes, 8)
                XCTAssertEqual(1, self.numberOfChannelReads)
                context.close(mode: .all, promise: nil)
            }
        }

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(.autoRead, value: false)
                .childChannelInitializer { ch in
                    ch.eventLoop.makeCompletedFuture {
                        try ch.pipeline.syncOperations.addHandler(VerifyEOFReadOrderingAndCloseInChannelReadHandler())
                    }
                }
                .childChannelOption(.maxMessagesPerRead, value: 1)
                .childChannelOption(.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 8))
                .bind(host: "127.0.0.1", port: 0).wait()
        )

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!).wait()
        )
        var buffer = clientChannel.allocator.buffer(capacity: 8)
        buffer.writeString("01234567")
        for _ in 0..<20 {
            XCTAssertNoThrow(try clientChannel.writeAndFlush(buffer).wait())
        }
        XCTAssertNoThrow(try clientChannel.close().wait())

        // Wait for 100 ms.
        usleep(100 * 1000)
        XCTAssertNoThrow(try serverChannel.close().wait())
    }

    func testCloseInSameReadThatEOFGetsDelivered() throws {
        guard isEarlyEOFDeliveryWorkingOnThisOS else {
            #if os(Linux) || os(Android)
            preconditionFailure("this should only ever be entered on Darwin.")
            #else
            return
            #endif
        }
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

            public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                if !self.didRead {
                    self.didRead = true
                    // closing this here causes an interesting situation:
                    // in readFromSocket we will spin one more iteration until we see the EOF but when we then return
                    // to `BaseSocketChannel.readable0`, we deliver EOF with the channel already deactivated.
                    context.close(mode: .all, promise: self.allDone)
                }
            }
        }

        let allDone = group.next().makePromise(of: Void.self)
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(.autoRead, value: false)
                .childChannelInitializer { ch in
                    ch.eventLoop.makeCompletedFuture {
                        try ch.pipeline.syncOperations.addHandler(CloseWhenWeGetEOFHandler(allDone: allDone))
                    }
                }
                // maxMessagesPerRead is large so that we definitely spin and seen the EOF
                .childChannelOption(.maxMessagesPerRead, value: 10)
                .childChannelOption(.allowRemoteHalfClosure, value: true)
                // that fits the message we prepared
                .childChannelOption(.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 8))
                .bind(host: "127.0.0.1", port: 0).wait()
        )

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!).wait()
        )
        var buf = clientChannel.allocator.buffer(capacity: 16)
        buf.writeStaticString("012345678")
        XCTAssertNoThrow(try clientChannel.writeAndFlush(buf).wait())
        XCTAssertNoThrow(try clientChannel.writeAndFlush(buf).wait())
        XCTAssertNoThrow(try clientChannel.close().wait())  // autoRead=off so this EOF will trigger the channelRead
        XCTAssertNoThrow(try allDone.futureResult.wait())

        XCTAssertNoThrow(try serverChannel.close().wait())
    }

    func testEOFReceivedWithoutReadRequests() throws {
        guard isEarlyEOFDeliveryWorkingOnThisOS else {
            #if os(Linux) || os(Android)
            preconditionFailure("this should only ever be entered on Darwin.")
            #else
            return
            #endif
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        final class ChannelInactiveVerificationHandler: ChannelDuplexHandler, Sendable {
            typealias InboundIn = ByteBuffer
            typealias OutboundIn = ByteBuffer

            private let promise: EventLoopPromise<Void>

            init(_ promise: EventLoopPromise<Void>) {
                self.promise = promise
            }

            public func read(context: ChannelHandlerContext) {
                XCTFail("shouldn't read")
            }

            public func channelInactive(context: ChannelHandlerContext) {
                promise.succeed(())
            }
        }

        let promise = group.next().makePromise(of: Void.self)
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(.autoRead, value: false)
                .childChannelInitializer { ch in
                    ch.pipeline.addHandler(ChannelInactiveVerificationHandler(promise))
                }
                .bind(host: "127.0.0.1", port: 0).wait()
        )

        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!).wait()
        )
        var buffer = clientChannel.allocator.buffer(capacity: 8)
        buffer.writeString("test")
        try clientChannel.writeAndFlush(buffer).wait()
        try clientChannel.close().wait()
        try promise.futureResult.wait()

        try serverChannel.close().wait()
    }

    func testAcceptsAfterCloseDontCauseIssues() throws {
        final class ChannelCollector: Sendable {
            private let channels: NIOLockedValueBox<[ObjectIdentifier: Channel]> = NIOLockedValueBox([:])

            deinit {
                XCTAssertTrue(self.channels.withLockedValue { $0.isEmpty })
            }

            func add(_ channel: Channel) {
                let key = ObjectIdentifier(channel)
                let old = self.channels.withLockedValue { $0.updateValue(channel, forKey: key) }
                assert(old == nil)
            }

            func remove(_ channel: Channel) {
                let removed = self.channels.withLockedValue {
                    $0.removeValue(forKey: ObjectIdentifier(channel))
                }
                XCTAssertTrue(removed != nil)
            }

            func closeAll() -> [EventLoopFuture<Void>] {
                let channels = self.channels.withLockedValue { $0.values }
                return channels.map { channel in
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

            func channelActive(context: ChannelHandlerContext) {
                XCTAssertFalse(self.isActive)
                self.isActive = true
                self.channelCollector.add(context.channel)
                context.fireChannelActive()
            }

            func channelInactive(context: ChannelHandlerContext) {
                XCTAssertTrue(self.isActive)
                self.isActive = false
                self.channelCollector.remove(context.channel)
                context.fireChannelInactive()
            }
        }

        func runTest() throws {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
            defer {
                XCTAssertNoThrow(try group.syncShutdownGracefully())
            }
            let collector = ChannelCollector()
            let serverBoot = ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            CheckActiveHandler(channelCollector: collector)
                        )
                    }
                }
            let listeningChannel = try serverBoot.bind(host: "127.0.0.1", port: 0).wait()
            let clientBoot = ClientBootstrap(group: group)
            XCTAssertNoThrow(try clientBoot.connect(to: listeningChannel.localAddress!).wait().close().wait())
            let closeFutures = collector.closeAll()
            // a stray client
            XCTAssertNoThrow(try clientBoot.connect(to: listeningChannel.localAddress!).wait().close().wait())
            XCTAssertNoThrow(try listeningChannel.close().wait())
            for future in closeFutures {
                do {
                    try future.wait()
                    // No error is okay,
                } catch ChannelError.alreadyClosed {
                    // as well as already closed.
                } catch {
                    XCTFail("unexpected error \(error) received")
                }
            }
        }

        for _ in 0..<20 {
            XCTAssertNoThrow(try runTest())
        }
    }

    func testChannelReadsDoesNotHappenAfterRegistration() throws {
        class SocketThatSucceedsOnSecondConnectForPort123: Socket {
            init(protocolFamily: NIOBSDSocket.ProtocolFamily) throws {
                try super.init(protocolFamily: protocolFamily, type: .stream, setNonBlocking: true)
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
            init(
                hasRegisteredPromise: EventLoopPromise<Void>,
                hasUnregisteredPromise: EventLoopPromise<Void>,
                hasReadPromise: EventLoopPromise<Void>
            ) {
                self.hasRegisteredPromise = hasRegisteredPromise
                self.hasUnregisteredPromise = hasUnregisteredPromise
                self.hasReadPromise = hasReadPromise
            }
            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                XCTAssertEqual(.active, self.state)
                self.state = .read
                self.hasReadPromise.succeed(())
            }
            func channelActive(context: ChannelHandlerContext) {
                XCTAssertEqual(.registered, self.state)
                self.state = .active
            }
            func channelRegistered(context: ChannelHandlerContext) {
                XCTAssertEqual(.start, self.state)
                self.state = .registered
                self.hasRegisteredPromise.succeed(())
            }
            func channelUnregistered(context: ChannelHandlerContext) {
                self.hasUnregisteredPromise.succeed(())
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let serverEL = group.next()
        let clientEL = group.next()
        precondition(serverEL !== clientEL)
        let sc = try SocketChannel(
            socket: SocketThatSucceedsOnSecondConnectForPort123(protocolFamily: .inet),
            eventLoop: clientEL as! SelectableEventLoop
        )

        final class WriteImmediatelyHandler: ChannelInboundHandler, Sendable {
            typealias InboundIn = Any
            typealias OutboundOut = ByteBuffer

            private let writeDonePromise: EventLoopPromise<Void>

            init(writeDonePromise: EventLoopPromise<Void>) {
                self.writeDonePromise = writeDonePromise
            }

            func channelActive(context: ChannelHandlerContext) {
                var buffer = context.channel.allocator.buffer(capacity: 4)
                buffer.writeString("foo")
                context.writeAndFlush(NIOAny(buffer), promise: self.writeDonePromise)
            }
        }

        let serverWriteHappenedPromise = serverEL.next().makePromise(of: Void.self)
        let clientHasRegistered = serverEL.next().makePromise(of: Void.self)
        let clientHasUnregistered = serverEL.next().makePromise(of: Void.self)
        let clientHasRead = serverEL.next().makePromise(of: Void.self)

        let bootstrap = try assertNoThrowWithValue(
            ServerBootstrap(group: serverEL)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(WriteImmediatelyHandler(writeDonePromise: serverWriteHappenedPromise))
                }
                .bind(host: "127.0.0.1", port: 0).wait()
        )

        // This is a bit ugly, we're trying to fabricate a situation that can happen in the real world which is that
        // a socket is readable straight after becoming registered & connected.
        // In here what we're doing is that we flip the order around and connect it first, make sure the server
        // has written something and then on registration something is available to be read. We then 'fake connect'
        // again which our special `Socket` subclass will let succeed.
        _ = try sc.socket.connect(to: bootstrap.localAddress!)
        try serverWriteHappenedPromise.futureResult.wait()
        try sc.eventLoop.submit {
            try sc.pipeline.syncOperations.addHandler(
                ReadDoesNotHappen(
                    hasRegisteredPromise: clientHasRegistered,
                    hasUnregisteredPromise: clientHasUnregistered,
                    hasReadPromise: clientHasRead
                )
            )
        }.flatMap {
            // this will succeed and should not cause the socket to be read even though there'll be something
            // available to be read immediately
            sc.register()
        }.flatMap {
            // this would normally fail but our special Socket subclass will let it succeed.
            sc.connect(to: try! SocketAddress(ipAddress: "127.0.0.1", port: 123))
        }.wait()
        try clientHasRegistered.futureResult.wait()
        try clientHasRead.futureResult.wait()
        try sc.syncCloseAcceptingAlreadyClosed()
        try clientHasUnregistered.futureResult.wait()
    }

    func testAppropriateAndInappropriateOperationsForUnregisteredSockets() throws {
        func checkThatItThrowsInappropriateOperationForState(
            file: StaticString = #filePath,
            line: UInt = #line,
            _ body: () throws -> Void
        ) {
            XCTAssertThrowsError(try body(), file: (file), line: line) { error in
                XCTAssertEqual(.inappropriateOperationForState, error as? ChannelError)
            }
        }
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }

        func withChannel(
            skipDatagram: Bool = false,
            skipStream: Bool = false,
            skipServerSocket: Bool = false,
            file: StaticString = #filePath,
            line: UInt = #line,
            _ body: (Channel) throws -> Void
        ) {
            XCTAssertNoThrow(
                try {
                    let el = elg.next() as! SelectableEventLoop
                    let channels: [Channel] =
                        (skipDatagram
                            ? []
                            : [try DatagramChannel(eventLoop: el, protocolFamily: .inet, protocolSubtype: .default)])
                        // Xcode need help
                        + (skipStream ? [] : [try SocketChannel(eventLoop: el, protocolFamily: .inet)])
                        // Xcode need help
                        + (skipServerSocket
                            ? [] : [try ServerSocketChannel(eventLoop: el, group: elg, protocolFamily: .inet)])
                    for channel in channels {
                        try body(channel)
                        XCTAssertNoThrow(try channel.close().wait(), file: (file), line: line)
                    }
                }(),
                file: (file),
                line: line
            )
        }
        withChannel { channel in
            checkThatItThrowsInappropriateOperationForState {
                try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1234)).wait()
            }
        }
        withChannel { channel in
            XCTAssertThrowsError(try channel.triggerUserOutboundEvent("foo").wait()) { error in
                if let error = error as? ChannelError {
                    XCTAssertEqual(ChannelError.operationUnsupported, error)
                } else {
                    XCTFail("wrong error: \(error)")
                }
            }
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

        withChannel(skipStream: true) { channel in
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
            init(protocolFamily: NIOBSDSocket.ProtocolFamily) throws {
                try super.init(protocolFamily: protocolFamily, type: .stream, setNonBlocking: true)
            }
            override func read(pointer: UnsafeMutableRawBufferPointer) throws -> NIOPosix.IOResult<Int> {
                defer {
                    self.firstReadHappened = true
                }
                XCTAssertGreaterThan(pointer.count, 0)
                if self.firstReadHappened {
                    // this is a copy of the exact error that'd come out of the real Socket.read
                    throw IOError.init(errnoCode: ECONNRESET, reason: "read(descriptor:pointer:size:)")
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
            func channelActive(context: ChannelHandlerContext) {
                XCTAssertEqual(.fresh, self.state)
                self.state = .active
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                XCTAssertEqual(.active, self.state)
                self.state = .read
                var buffer = Self.unwrapInboundIn(data)
                XCTAssertEqual(1, buffer.readableBytes)
                XCTAssertEqual([0xff], buffer.readBytes(length: 1)!)
            }

            func channelReadComplete(context: ChannelHandlerContext) {
                XCTAssertEqual(.read, self.state)
                self.state = .readComplete
            }

            func errorCaught(context: ChannelHandlerContext, error: Error) {
                XCTAssertEqual(.readComplete, self.state)
                self.state = .error
                context.close(promise: nil)
            }

            func channelInactive(context: ChannelHandlerContext) {
                XCTAssertEqual(.error, self.state)
                self.state = .inactive
                self.allDone.succeed(())
            }
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let serverEL = group.next()
        let clientEL = group.next()
        precondition(serverEL !== clientEL)
        let sc = try SocketChannel(
            socket: SocketThatHasTheFirstReadSucceedButFailsTheNextWithECONNRESET(protocolFamily: .inet),
            eventLoop: clientEL as! SelectableEventLoop
        )

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: serverEL)
                .childChannelInitializer { channel in
                    var buffer = channel.allocator.buffer(capacity: 4)
                    buffer.writeString("foo")
                    channel.writeAndFlush(buffer, promise: nil)
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let allDone = clientEL.makePromise(of: Void.self)

        XCTAssertNoThrow(
            try sc.eventLoop.flatSubmit {
                // this is pretty delicate at the moment:
                // `bind` must be _synchronously_ follow `register`, otherwise in our current implementation, `epoll` will
                // send us `EPOLLHUP`. To have it run synchronously, we need to invoke the `flatMap` on the eventloop that the
                // `register` will succeed.

                sc.register().flatMapThrowing {
                    try sc.pipeline.syncOperations.addHandler(VerifyThingsAreRightHandler(allDone: allDone))
                }.flatMap {
                    sc.connect(to: serverChannel.localAddress!)
                }
            }.wait() as Void
        )
        XCTAssertNoThrow(try allDone.futureResult.wait())
        XCTAssertNoThrow(try sc.syncCloseAcceptingAlreadyClosed())
    }

    func testSocketFailingAsyncCorrectlyTearsTheChannelDownAndDoesntCrash() throws {
        // regression test for #302
        enum DummyError: Error { case dummy }
        class SocketFailingAsyncConnect: Socket {
            init() throws {
                try super.init(protocolFamily: .inet, type: .stream, setNonBlocking: true)
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

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group.next())
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let allDone = group.next().makePromise(of: Void.self)
        let cf = try! sc.eventLoop.submit {
            try sc.pipeline.syncOperations.addHandler(VerifyConnectionFailureHandler(allDone: allDone))
            return sc.register().flatMap {
                sc.connect(to: serverChannel.localAddress!)
            }
        }.wait()
        XCTAssertThrowsError(try cf.wait()) { error in
            XCTAssertEqual(.dummy, error as? DummyError)
        }
        XCTAssertNoThrow(try allDone.futureResult.wait())
        XCTAssertNoThrow(try sc.syncCloseAcceptingAlreadyClosed())
    }

    func testSocketErroringSynchronouslyCorrectlyTearsTheChannelDown() throws {
        // regression test for #322
        enum DummyError: Error { case dummy }
        class SocketFailingConnect: Socket {
            init() throws {
                try super.init(protocolFamily: .inet, type: .stream, setNonBlocking: true)
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

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group.next())
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        let allDone = group.next().makePromise(of: Void.self)
        try! sc.eventLoop.submit {
            try sc.pipeline.syncOperations.addHandler(VerifyConnectionFailureHandler(allDone: allDone))
            let f = sc.register().flatMap {
                sc.connect(to: serverChannel.localAddress!)
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
        let serverSock = try Socket(protocolFamily: .inet, type: .stream)
        // we deliberately don't set SO_REUSEADDR
        XCTAssertNoThrow(try serverSock.bind(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)))
        let serverSockAddress = try! serverSock.localAddress()
        XCTAssertNoThrow(try serverSock.close())

        // we're just looping here to get a pretty good chance we're hitting both the synchronous and the asynchronous
        // connect path.
        for _ in 0..<64 {
            XCTAssertThrowsError(try ClientBootstrap(group: group).connect(to: serverSockAddress).wait()) { error in
                XCTAssertEqual(ECONNREFUSED, (error as? IOError).map { $0.errnoCode })
            }
        }
    }

    func testCloseInUnregister() throws {
        enum DummyError: Error { case dummy }
        class SocketFailingClose: Socket {
            init() throws {
                try super.init(protocolFamily: .inet, type: .stream, setNonBlocking: true)
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

        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group.next())
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try serverChannel.syncCloseAcceptingAlreadyClosed())
        }

        XCTAssertNoThrow(
            try sc.eventLoop.flatSubmit {
                sc.register().flatMap {
                    sc.connect(to: serverChannel.localAddress!)
                }
            }.wait() as Void
        )

        XCTAssertThrowsError(
            try sc.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
                let p = sc.eventLoop.makePromise(of: Void.self)
                // this callback must be attached before we call the close
                let f = p.futureResult.map {
                    XCTFail("shouldn't be reached")
                }.flatMapError { err in
                    XCTAssertNotNil(err as? DummyError)
                    return sc.close()
                }
                sc.close(promise: p)
                return f
            }.wait()
        ) { error in
            XCTAssertEqual(.alreadyClosed, error as? ChannelError)
        }
    }

    func testLazyRegistrationWorksForServerSockets() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let server = try assertNoThrowWithValue(
            ServerSocketChannel(
                eventLoop: group.next() as! SelectableEventLoop,
                group: group,
                protocolFamily: .inet
            )
        )
        defer {
            XCTAssertNoThrow(try server.close().wait())
        }
        XCTAssertNoThrow(try server.register().wait())
        XCTAssertNoThrow(
            try server.eventLoop.submit {
                XCTAssertFalse(server.isActive)
            }.wait()
        )
        XCTAssertEqual(0, server.localAddress!.port!)
        XCTAssertNoThrow(try server.bind(to: SocketAddress(ipAddress: "0.0.0.0", port: 0)).wait())
        XCTAssertNotEqual(0, server.localAddress!.port!)
    }

    func testLazyRegistrationWorksForClientSockets() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "localhost", port: 0)
                .wait()
        )

        let client = try SocketChannel(
            eventLoop: group.next() as! SelectableEventLoop,
            protocolFamily: serverChannel.localAddress!.protocol
        )
        defer {
            XCTAssertNoThrow(try client.close().wait())
        }
        XCTAssertNoThrow(try client.register().wait())
        XCTAssertNoThrow(
            try client.eventLoop.submit {
                XCTAssertFalse(client.isActive)
            }.wait()
        )
        XCTAssertNoThrow(try client.connect(to: serverChannel.localAddress!).wait())
        XCTAssertTrue(client.isActive)
        XCTAssertEqual(serverChannel.localAddress!, client.remoteAddress!)
    }

    func testFailedRegistrationOfClientSocket() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .bind(host: "localhost", port: 0)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }
        XCTAssertThrowsError(
            try ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(FailRegistrationAndDelayCloseHandler())
                }
                .connect(to: serverChannel.localAddress!)
                .wait()
        ) { error in
            XCTAssertEqual(.error, error as? FailRegistrationAndDelayCloseHandler.RegistrationFailedError)
        }
    }

    func testFailedRegistrationOfAcceptedSocket() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let serverChannel = try assertNoThrowWithValue(
            ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(FailRegistrationAndDelayCloseHandler())
                }
                .bind(host: "localhost", port: 0).wait()
        )
        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }
        let clientChannel = try assertNoThrowWithValue(
            ClientBootstrap(group: group)
                .connect(to: serverChannel.localAddress!)
                .wait(),
            message:
                "resolver debug info: \(try! resolverDebugInformation(eventLoop: group.next(),host: "localhost", previouslyReceivedResult: serverChannel.localAddress!))"
        )
        XCTAssertNoThrow(try clientChannel.closeFuture.wait() as Void)
    }

    func testFailedRegistrationOfServerSocket() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        XCTAssertThrowsError(
            try ServerBootstrap(group: group)
                .serverChannelInitializer { channel in
                    channel.pipeline.addHandler(FailRegistrationAndDelayCloseHandler())
                }
                .bind(host: "localhost", port: 0)
                .wait()
        ) { error in
            XCTAssertEqual(.error, error as? FailRegistrationAndDelayCloseHandler.RegistrationFailedError)
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
            XCTFail(
                "shouldn't have succeeded, got two server channels on the same port: \(serverChannel1) and \(serverChannel2)"
            )
        } catch let e as IOError where e.errnoCode == EADDRINUSE {
            // OK
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCloseInReadTriggeredByDrainingTheReceiveBufferBecauseOfWriteError() throws {
        final class WriteWhenActiveHandler: ChannelInboundHandler, Sendable {
            typealias InboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            let channelAvailablePromise: EventLoopPromise<Channel>

            init(channelAvailablePromise: EventLoopPromise<Channel>) {
                self.channelAvailablePromise = channelAvailablePromise
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let buffer = Self.unwrapInboundIn(data)
                XCTFail("unexpected read: \(String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))")
            }

            func channelActive(context: ChannelHandlerContext) {
                var buffer = context.channel.allocator.buffer(capacity: 1)
                buffer.writeStaticString("X")
                context.channel.writeAndFlush(buffer).map { [channel = context.channel] in
                    channel
                }.cascade(
                    to: self.channelAvailablePromise
                )
            }
        }

        final class WriteAlwaysFailingSocket: Socket {
            init() throws {
                try super.init(protocolFamily: .inet, type: .stream, setNonBlocking: true)
            }

            override func write(pointer: UnsafeRawBufferPointer) throws -> NIOPosix.IOResult<Int> {
                throw IOError(errnoCode: ETXTBSY, reason: "WriteAlwaysFailingSocket.write fake error")
            }

            override func writev(iovecs: UnsafeBufferPointer<IOVector>) throws -> NIOPosix.IOResult<Int> {
                throw IOError(errnoCode: ETXTBSY, reason: "WriteAlwaysFailingSocket.writev fake error")
            }
        }

        final class MakeChannelInactiveInReadCausedByWriteErrorHandler: ChannelInboundHandler, Sendable {
            typealias InboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            let serverChannel: EventLoopFuture<Channel>
            let allDonePromise: EventLoopPromise<Void>

            init(
                serverChannel: EventLoopFuture<Channel>,
                allDonePromise: EventLoopPromise<Void>
            ) {
                self.serverChannel = serverChannel
                self.allDonePromise = allDonePromise
            }

            func channelActive(context: ChannelHandlerContext) {
                XCTAssert(serverChannel.eventLoop === context.eventLoop)
                let loopBoundContext = context.loopBound
                self.serverChannel.whenSuccess { [channel = context.channel, allDonePromise] serverChannel in
                    // all of the following futures need to complete synchronously for this test to test the correct
                    // thing. Therefore we keep track if we're still on the same stack frame.
                    var inSameStackFrame = true
                    defer {
                        inSameStackFrame = false
                    }

                    XCTAssertTrue(serverChannel.isActive)
                    // we allow auto-read again to make sure that the socket buffer is drained on write error
                    // (cf. https://github.com/apple/swift-nio/issues/593)
                    channel.setOption(.autoRead, value: true).assumeIsolated().flatMap {
                        let context = loopBoundContext.value
                        // let's trigger the write error
                        var buffer = channel.allocator.buffer(capacity: 16)
                        buffer.writeStaticString("THIS WILL FAIL ANYWAY")

                        // this needs to be in a function as otherwise the Swift compiler believes this is throwing
                        func workaroundSR487() {
                            // this test only tests the correct condition if the bytes sent from the other side have already
                            // arrived at the time the write fails. So this is a hack that makes sure they do have arrived.
                            // (https://github.com/apple/swift-nio/issues/657)
                            XCTAssertNoThrow(
                                try veryNasty_blockUntilReadBufferIsNonEmpty(channel: channel)
                            )
                        }
                        workaroundSR487()

                        return context.writeAndFlush(Self.wrapOutboundOut(buffer))
                    }.map {
                        XCTFail("this should have failed")
                    }.whenFailure { error in
                        XCTAssertEqual(
                            ChannelError.ioOnClosedChannel,
                            error as? ChannelError,
                            "unexpected error: \(error)"
                        )
                        XCTAssertTrue(inSameStackFrame)
                        allDonePromise.succeed(())
                    }
                }
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let buffer = Self.unwrapInboundIn(data)
                XCTAssertEqual("X", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
                context.close(promise: nil)
            }
        }

        let singleThreadedELG = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try singleThreadedELG.syncShutdownGracefully())
        }
        let serverChannelAvailablePromise = singleThreadedELG.next().makePromise(of: Channel.self)
        let allDonePromise = singleThreadedELG.next().makePromise(of: Void.self)
        let server = try assertNoThrowWithValue(
            ServerBootstrap(group: singleThreadedELG)
                .childChannelOption(.allowRemoteHalfClosure, value: true)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(
                        WriteWhenActiveHandler(channelAvailablePromise: serverChannelAvailablePromise)
                    )
                }
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try server.close().wait())
        }

        let c = try assertNoThrowWithValue(
            SocketChannel(
                socket: WriteAlwaysFailingSocket(),
                parent: nil,
                eventLoop: singleThreadedELG.next() as! SelectableEventLoop
            )
        )
        XCTAssertNoThrow(try c.setOption(.autoRead, value: false).wait())
        XCTAssertNoThrow(try c.setOption(.allowRemoteHalfClosure, value: true).wait())
        XCTAssertNoThrow(
            try c.pipeline.addHandler(
                MakeChannelInactiveInReadCausedByWriteErrorHandler(
                    serverChannel: serverChannelAvailablePromise.futureResult,
                    allDonePromise: allDonePromise
                )
            ).wait()
        )
        XCTAssertNoThrow(try c.register().wait())
        XCTAssertNoThrow(try c.connect(to: server.localAddress!).wait())

        XCTAssertNoThrow(try allDonePromise.futureResult.wait())
        XCTAssertFalse(c.isActive)
    }

    func testApplyingTwoDistinctSocketOptionsOfSameTypeWorks() throws {
        let singleThreadedELG = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try singleThreadedELG.syncShutdownGracefully())
        }

        let numberOfAcceptedChannel = NIOLockedValueBox(0)
        let acceptedChannels: [EventLoopPromise<Channel>] = [
            singleThreadedELG.next().makePromise(),
            singleThreadedELG.next().makePromise(),
            singleThreadedELG.next().makePromise(),
        ]
        let server = try assertNoThrowWithValue(
            ServerBootstrap(group: singleThreadedELG)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .serverChannelOption(.socketOption(.so_timestamp), value: 1)
                .childChannelOption(.socketOption(.so_keepalive), value: 1)
                .childChannelOption(.tcpOption(.tcp_nodelay), value: 0)
                .childChannelInitializer { channel in
                    acceptedChannels[numberOfAcceptedChannel.withLockedValue { $0 }].succeed(channel)
                    numberOfAcceptedChannel.withLockedValue { $0 += 1 }
                    return channel.eventLoop.makeSucceededFuture(())
                }
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        defer {
            XCTAssertNoThrow(try server.close().wait())
        }
        XCTAssertTrue(try getBoolSocketOption(channel: server, level: .socket, name: .so_reuseaddr))
        XCTAssertTrue(try getBoolSocketOption(channel: server, level: .socket, name: .so_timestamp))

        let client1 = try assertNoThrowWithValue(
            ClientBootstrap(group: singleThreadedELG)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
                .channelOption(.tcpOption(.tcp_nodelay), value: 0)
                .connect(to: server.localAddress!)
                .wait()
        )
        let accepted1 = try assertNoThrowWithValue(acceptedChannels[0].futureResult.wait())
        defer {
            XCTAssertNoThrow(try client1.close().wait())
        }
        let client2 = try assertNoThrowWithValue(
            ClientBootstrap(group: singleThreadedELG)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
                .connect(to: server.localAddress!)
                .wait()
        )
        let accepted2 = try assertNoThrowWithValue(acceptedChannels[0].futureResult.wait())
        defer {
            XCTAssertNoThrow(try client2.close().wait())
        }
        let client3 = try assertNoThrowWithValue(
            ClientBootstrap(group: singleThreadedELG)
                .connect(to: server.localAddress!)
                .wait()
        )
        let accepted3 = try assertNoThrowWithValue(acceptedChannels[0].futureResult.wait())
        defer {
            XCTAssertNoThrow(try client3.close().wait())
        }

        XCTAssertTrue(try getBoolSocketOption(channel: client1, level: .socket, name: .so_reuseaddr))

        XCTAssertFalse(try getBoolSocketOption(channel: client1, level: .tcp, name: .tcp_nodelay))

        XCTAssertTrue(try getBoolSocketOption(channel: accepted1, level: .socket, name: .so_keepalive))

        XCTAssertFalse(try getBoolSocketOption(channel: accepted1, level: .tcp, name: .tcp_nodelay))

        XCTAssertTrue(try getBoolSocketOption(channel: client2, level: .socket, name: .so_reuseaddr))

        XCTAssertTrue(try getBoolSocketOption(channel: client2, level: .tcp, name: .tcp_nodelay))

        XCTAssertTrue(try getBoolSocketOption(channel: accepted2, level: .socket, name: .so_keepalive))

        XCTAssertFalse(try getBoolSocketOption(channel: accepted2, level: .tcp, name: .tcp_nodelay))

        XCTAssertFalse(try getBoolSocketOption(channel: client3, level: .socket, name: .so_reuseaddr))

        XCTAssertTrue(try getBoolSocketOption(channel: client3, level: .tcp, name: .tcp_nodelay))

        XCTAssertTrue(try getBoolSocketOption(channel: accepted3, level: .socket, name: .so_keepalive))

        XCTAssertFalse(try getBoolSocketOption(channel: accepted3, level: .tcp, name: .tcp_nodelay))
    }

    func testUnprocessedOutboundUserEventFailsOnServerSocketChannel() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let channel = try ServerSocketChannel(
            eventLoop: group.next() as! SelectableEventLoop,
            group: group,
            protocolFamily: .inet
        )
        XCTAssertThrowsError(try channel.triggerUserOutboundEvent("event").wait()) { (error: Error) in
            if let error = error as? ChannelError {
                XCTAssertEqual(ChannelError.operationUnsupported, error)
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testAcceptHandlerDoesNotSwallowCloseErrorsWhenQuiescing() {
        // AcceptHandler is a `private class` so I can only implicitly get it by creating the real thing
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let counter = EventCounterHandler()

        struct DummyError: Error {}
        class MakeFirstCloseFailAndDontActuallyCloseHandler: ChannelOutboundHandler {
            typealias OutboundIn = Any

            var closes = 0

            func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
                self.closes += 1
                if self.closes == 1 {
                    promise?.fail(DummyError())
                } else {
                    context.close(mode: mode, promise: promise)
                }
            }
        }

        let channel = try! assertNoThrowWithValue(
            ServerBootstrap(group: group).serverChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        MakeFirstCloseFailAndDontActuallyCloseHandler(),
                        position: .first
                    )
                }
            }.bind(host: "localhost", port: 0).wait()
        )
        defer {
            XCTAssertNoThrow(try channel.close().wait())
        }

        XCTAssertNoThrow(try channel.pipeline.addHandler(counter).wait())

        XCTAssertNoThrow(
            try channel.eventLoop.submit {
                // this will trigger a close (which will fail and also not actually close)
                channel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
            }.wait()
        )
        XCTAssertEqual(["userInboundEventTriggered", "close", "errorCaught"], counter.allTriggeredEvents())
        XCTAssertEqual(1, counter.errorCaughtCalls)
    }

    func _testTCP_NODELAYDefaultValue(
        value: Bool,
        _ socketAddress: SocketAddress,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let singleThreadedELG = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try singleThreadedELG.syncShutdownGracefully(), file: file, line: line)
        }
        let acceptedChannel = singleThreadedELG.next().makePromise(of: Channel.self)
        let server = try assertNoThrowWithValue(
            ServerBootstrap(group: singleThreadedELG)
                .childChannelInitializer { channel in
                    acceptedChannel.succeed(channel)
                    return channel.eventLoop.makeSucceededFuture(())
                }
                .bind(to: socketAddress)
                .wait(),
            file: file,
            line: line
        )
        defer {
            XCTAssertNoThrow(try server.close().wait(), file: file, line: line)
        }

        let client = try assertNoThrowWithValue(
            ClientBootstrap(group: singleThreadedELG)
                .connect(to: server.localAddress!)
                .wait(),
            file: file,
            line: line
        )
        let accepted = try assertNoThrowWithValue(acceptedChannel.futureResult.wait(), file: file, line: line)
        defer {
            XCTAssertNoThrow(try client.close().wait(), file: file, line: line)
        }
        XCTAssertNoThrow(
            XCTAssertEqual(
                try getBoolSocketOption(channel: accepted, level: .tcp, name: .tcp_nodelay),
                value,
                file: file,
                line: line
            ),
            file: file,
            line: line
        )
        XCTAssertNoThrow(
            XCTAssertEqual(
                try getBoolSocketOption(channel: client, level: .tcp, name: .tcp_nodelay),
                value,
                file: file,
                line: line
            ),
            file: file,
            line: line
        )
    }

    func testTCP_NODELAYisOnByDefaultForInetSockets() throws {
        try _testTCP_NODELAYDefaultValue(value: true, SocketAddress(ipAddress: "127.0.0.1", port: 0))
    }

    func testTCP_NODELAYisOnByDefaultForInet6Sockets() throws {
        try XCTSkipUnless(System.supportsIPv6)
        try _testTCP_NODELAYDefaultValue(value: true, SocketAddress(ipAddress: "::1", port: 0))
    }

    func testDescriptionCanBeCalledFromNonEventLoopThreads() {
        // regression test for https://github.com/apple/swift-nio/issues/1141
        let q = DispatchQueue(label: "elsewhere")
        XCTAssertNoThrow(
            try forEachActiveChannelType { channel in
                let g = DispatchGroup()
                q.async(group: g) {
                    // we spin here for a bit and read
                    for _ in 0..<10_000 {
                        // this should trigger TSan if there's an issue.
                        XCTAssert(String(describing: channel).count != 0)
                    }
                }

                // We need to write to BaseSocket's `descriptor` which can only be done by closing the channel.
                XCTAssertNoThrow(try channel.syncCloseAcceptingAlreadyClosed())
                g.wait()
            }
        )
    }

    func testFixedSizeRecvByteBufferAllocatorSizeIsConstant() {
        let actualAllocator = ByteBufferAllocator()
        var allocator = FixedSizeRecvByteBufferAllocator(capacity: 1)
        let b1 = allocator.buffer(allocator: actualAllocator)
        XCTAssertFalse(allocator.record(actualReadBytes: 1024))
        let b2 = allocator.buffer(allocator: actualAllocator)
        XCTAssertEqual(1, b1.capacity)
        XCTAssertEqual(1, b2.capacity)
        XCTAssertEqual(1, allocator.capacity)
    }

    func testCloseInConnectPromise() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        var maybeServer: Channel? = nil
        XCTAssertNoThrow(
            maybeServer = try ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
        guard let server = maybeServer else {
            XCTFail("couldn't bootstrap server")
            return
        }
        defer {
            XCTAssertNoThrow(try server.close().wait())
        }

        for _ in 0..<10 {
            // 10 times so we get a good chance of an asynchronous connect.
            XCTAssertNoThrow(
                try ClientBootstrap(group: group).connect(to: server.localAddress!).flatMap { channel in
                    channel.close()
                }.wait()
            )
        }
    }

    func testWritabilityChangeDuringReentrantFlushNow() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let loop = group.next()
        let becameUnwritable = loop.makePromise(of: Void.self)
        let becameWritable = loop.makePromise(of: Void.self)

        let serverFuture = ServerBootstrap(group: group)
            .childChannelOption(.writeBufferWaterMark, value: ReentrantWritabilityChangingHandler.watermark)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = ReentrantWritabilityChangingHandler(
                        becameUnwritable: becameUnwritable,
                        becameWritable: becameWritable
                    )
                    return try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
            .bind(host: "localhost", port: 0)

        let server: Channel = try assertNoThrowWithValue(try serverFuture.wait())
        defer {
            XCTAssertNoThrow(try server.close().wait())
        }

        let clientFuture = ClientBootstrap(group: group)
            .connect(host: "localhost", port: server.localAddress!.port!)

        let client: Channel = try assertNoThrowWithValue(try clientFuture.wait())
        defer {
            XCTAssertNoThrow(try client.close().wait())
        }

        XCTAssertNoThrow(try becameUnwritable.futureResult.wait())
        XCTAssertNoThrow(try becameWritable.futureResult.wait())
    }

    func testChannelCanReportWritableBufferedBytes() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let server = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "localhost", port: 0)
            .wait()

        let client = try ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .connect(to: server.localAddress!)
            .wait()

        let buffer = client.allocator.buffer(string: "abcd")
        let writeCount = 3

        let promises = (0..<writeCount).map { _ in client.write(buffer) }
        let bufferedAmount = try client.getOption(.bufferedWritableBytes).wait()
        XCTAssertEqual(bufferedAmount, buffer.readableBytes * writeCount)
        client.flush()
        XCTAssertNoThrow(try EventLoopFuture.andAllSucceed(promises, on: client.eventLoop).wait())
        let bufferedAmountAfterFlush = try client.getOption(.bufferedWritableBytes).wait()
        XCTAssertEqual(bufferedAmountAfterFlush, 0)
    }

    func testChannelCanReportWritableBufferedBytesWhenSendBufferWouldBlock() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let server = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "localhost", port: 0)
            .wait()

        let client = try ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.socketOption(.so_sndbuf), value: 8)
            .connect(to: server.localAddress!)
            .wait()

        let buffer = client.allocator.buffer(string: "abcd")
        let writeCount = 20

        var promises = (0..<writeCount).map { _ in client.writeAndFlush(buffer) }
        var bufferedAmount = try client.getOption(.bufferedWritableBytes).wait()
        XCTAssertTrue(bufferedAmount >= 0 && bufferedAmount <= buffer.readableBytes * writeCount)
        promises.append(client.write(buffer))
        bufferedAmount = try client.getOption(.bufferedWritableBytes).wait()
        XCTAssertTrue(
            bufferedAmount >= buffer.readableBytes && bufferedAmount <= buffer.readableBytes * (writeCount + 1)
        )
        client.flush()
        XCTAssertNoThrow(try EventLoopFuture.andAllSucceed(promises, on: client.eventLoop).wait())
        let bufferedAmountAfterFlush = try client.getOption(.bufferedWritableBytes).wait()
        XCTAssertEqual(bufferedAmountAfterFlush, 0)
    }
}

private final class FailRegistrationAndDelayCloseHandler: ChannelOutboundHandler, Sendable {
    enum RegistrationFailedError: Error { case error }

    typealias OutboundIn = Never

    func register(context: ChannelHandlerContext, promise: EventLoopPromise<Void>?) {
        promise!.fail(RegistrationFailedError.error)
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        let loopBoundContext = context.loopBound
        // for extra nastiness, let's delay close. This makes sure the ChannelPipeline correctly retains the Channel
        _ = context.eventLoop.scheduleTask(in: .milliseconds(10)) {
            let context = loopBoundContext.value
            context.close(mode: mode, promise: promise)
        }
    }
}

private class VerifyConnectionFailureHandler: ChannelInboundHandler {
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

    func channelActive(context: ChannelHandlerContext) { XCTFail("should never become active") }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { XCTFail("should never read") }

    func channelReadComplete(context: ChannelHandlerContext) { XCTFail("should never readComplete") }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        XCTFail("pipeline shouldn't be told about connect error")
    }

    func channelRegistered(context: ChannelHandlerContext) {
        XCTAssertEqual(.fresh, self.state)
        self.state = .registered
        context.fireChannelRegistered()
    }

    func channelUnregistered(context: ChannelHandlerContext) {
        XCTAssertEqual(.registered, self.state)
        self.state = .unregistered
        self.allDone.succeed(())
        context.fireChannelUnregistered()
    }
}

final class ReentrantWritabilityChangingHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    static let watermark = ChannelOptions.Types.WriteBufferWaterMark(low: 100, high: 200)

    let becameWritable: EventLoopPromise<Void>
    let becameUnwritable: EventLoopPromise<Void>

    var isWritableCount = 0
    var isNotWritableCount = 0

    init(becameUnwritable: EventLoopPromise<Void>, becameWritable: EventLoopPromise<Void>) {
        self.becameUnwritable = becameUnwritable
        self.becameWritable = becameWritable
    }

    func channelActive(context: ChannelHandlerContext) {
        // We want to enqueue at least two pending writes before flushing. Neither of which
        // should cause writability to change. However, we'll chain a callback off the first
        // write which will make the channel unwritable and a writability change to be
        // emitted. The flush for that write should result in the writability flipping back
        // again.
        let b1 = context.channel.allocator.buffer(repeating: 0, count: 50)
        let loopBoundContext = context.loopBound
        context.write(Self.wrapOutboundOut(b1)).assumeIsolated().whenSuccess { _ in
            let context = loopBoundContext.value
            // We should still be writable.
            XCTAssertTrue(context.channel.isWritable)
            XCTAssertEqual(self.isNotWritableCount, 0)
            XCTAssertEqual(self.isWritableCount, 0)

            // Write again. But now breach high water mark. This should cause us to become
            // unwritable.
            let b2 = context.channel.allocator.buffer(repeating: 0, count: 250)
            context.write(Self.wrapOutboundOut(b2), promise: nil)
            XCTAssertFalse(context.channel.isWritable)
            XCTAssertEqual(self.isNotWritableCount, 1)
            XCTAssertEqual(self.isWritableCount, 0)

            // Now flush. This should lead to us becoming writable again.
            context.flush()
        }

        // Queue another write and flush.
        context.writeAndFlush(Self.wrapOutboundOut(b1), promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            self.isWritableCount += 1
            self.becameWritable.succeed(())
        } else {
            self.isNotWritableCount += 1
            self.becameUnwritable.succeed(())
        }
    }
}

private func veryNasty_blockUntilReadBufferIsNonEmpty(channel: Channel) throws {
    struct ThisIsNotASocketChannelError: Error {}
    guard let channel = channel as? SocketChannel else {
        throw ThisIsNotASocketChannelError()
    }
    try channel.socket.withUnsafeHandle { fd in
        var pollFd: pollfd = .init(fd: fd, events: Int16(POLLIN), revents: 0)
        let nfds =
            try NIOBSDSocket.poll(fds: &pollFd, nfds: 1, timeout: -1)
        XCTAssertEqual(1, nfds)
    }
}
