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
        XCTAssertFalse(ctx.channel.isActive)
        currentState = .inactive
        stateHistory.append(.inactive)
        ctx.fireChannelRegistered()
    }

    public func channelActive(ctx: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .inactive)
        XCTAssertTrue(ctx.channel.isActive)
        currentState = .active
        stateHistory.append(.active)
        ctx.fireChannelActive()
    }

    public func channelInactive(ctx: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .active)
        XCTAssertFalse(ctx.channel.isActive)
        currentState = .inactive
        stateHistory.append(.inactive)
        ctx.fireChannelInactive()
    }

    public func channelUnregistered(ctx: ChannelHandlerContext) {
        XCTAssertEqual(currentState, .inactive)
        XCTAssertFalse(ctx.channel.isActive)
        currentState = .unregistered
        stateHistory.append(.unregistered)
        ctx.fireChannelUnregistered()
    }
}

public class ChannelTests: XCTestCase {
    func testBasicLifecycle() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        var serverAcceptedChannel: Channel? = nil
        let serverLifecycleHandler = ChannelLifecycleHandler()
        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                serverAcceptedChannel = channel
                return channel.pipeline.add(handler: serverLifecycleHandler)
            }.bind(host: "127.0.0.1", port: 0).wait()

        let clientLifecycleHandler = ChannelLifecycleHandler()
        let clientChannel = try ClientBootstrap(group: group)
            .channelInitializer({ (channel: Channel) in channel.pipeline.add(handler: clientLifecycleHandler) })
            .connect(to: serverChannel.localAddress!).wait()

        var buffer = clientChannel.allocator.buffer(capacity: 1)
        buffer.write(string: "a")
        try clientChannel.writeAndFlush(NIOAny(buffer)).wait()

        // Start shutting stuff down.
        try clientChannel.close().wait()

        // Wait for the close promises. These fire last.
        try EventLoopFuture<Void>.andAll([clientChannel.closeFuture, serverAcceptedChannel!.closeFuture], eventLoop: group.next()).map {
            XCTAssertEqual(clientLifecycleHandler.currentState, .unregistered)
            XCTAssertEqual(serverLifecycleHandler.currentState, .unregistered)
            XCTAssertEqual(clientLifecycleHandler.stateHistory, [.unregistered, .inactive, .active, .inactive, .unregistered])
            XCTAssertEqual(serverLifecycleHandler.stateHistory, [.unregistered, .inactive, .active, .inactive, .unregistered])
        }.wait()
    }

    func testManyManyWrites() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "127.0.0.1", port: 0).wait()

        let clientChannel = try ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait()

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
        try clientChannel.close().wait()
    }

    func testWritevLotsOfData() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "127.0.0.1", port: 0).wait()

        let clientChannel = try ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait()

        let bufferSize = 1024 * 1024 * 2
        var buffer = clientChannel.allocator.buffer(capacity: bufferSize)
        for _ in 0..<bufferSize {
            buffer.write(staticString: "a")
        }

        var written = 0
        while written <= Int(INT32_MAX) {
            clientChannel.write(NIOAny(buffer), promise: nil)
            written += bufferSize
        }

        try clientChannel.writeAndFlush(NIOAny(buffer)).wait()

        // Start shutting stuff down.
        try clientChannel.close().wait()
    }

    func testParentsOfSocketChannels() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let childChannelPromise: EventLoopPromise<Channel> = group.next().newPromise()
        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                childChannelPromise.succeed(result: channel)
                return channel.eventLoop.newSucceededFuture(result: ())
            }.bind(host: "127.0.0.1", port: 0).wait()

        let clientChannel = try ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait()

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
        try clientChannel.close().wait()
    }

    private func withPendingStreamWritesManager(_ fn: (PendingStreamWritesManager) throws -> Void) rethrows {
        try withExtendedLifetime(NSObject()) { o in
            var iovecs: [IOVector] = Array(repeating: iovec(), count: Socket.writevLimitIOVectors + 1)
            var managed: [Unmanaged<AnyObject>] = Array(repeating: Unmanaged.passUnretained(o), count: Socket.writevLimitIOVectors + 1)
            /* put a canary value at the end */
            iovecs[iovecs.count - 1] = iovec(iov_base: UnsafeMutableRawPointer(bitPattern: 0xdeadbeef)!, iov_len: 0xdeadbeef)
            try iovecs.withUnsafeMutableBufferPointer { iovecs in
                try managed.withUnsafeMutableBufferPointer { managed in
                    let pwm = NIO.PendingStreamWritesManager(iovecs: iovecs, storageRefs: managed)
                    XCTAssertTrue(pwm.isEmpty)
                    XCTAssertTrue(pwm.isOpen)
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
                                   promises: [EventLoopPromise<()>],
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
    func testPendingWritesEmptyWritesWorkAndWeDontWriteUnflushedThings() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator()
        var buffer = alloc.buffer(capacity: 12)

        try withPendingStreamWritesManager { pwm in
            buffer.clear()
            let ps: [EventLoopPromise<()>] = (0..<2).map { (_: Int) in el.newPromise() }
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
            let ps: [EventLoopPromise<()>] = (0..<3).map { (_: Int) in el.newPromise() }
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
            let ps: [EventLoopPromise<()>] = (0..<4).map { (_: Int) in el.newPromise() }
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
            let ps: [EventLoopPromise<()>] = (0..<1).map { (_: Int) in el.newPromise() }
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
            let ps: [EventLoopPromise<()>] = (0..<numberOfBytes).map { (_: Int) in
                let p: EventLoopPromise<()> = el.newPromise()
                _ = pwm.add(data: .byteBuffer(buffer), promise: p)
                return p
            }
            pwm.markFlushCheckpoint()

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
            let ps: [EventLoopPromise<()>] = (0..<numberOfWrites).map { _ in el.newPromise() }
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
            let ps: [EventLoopPromise<()>] = (0..<3).map { (_: Int) in el.newPromise() }
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

            XCTAssertTrue(ps.map { $0.futureResult.fulfilled }.reduce(true) { $0 && $1 })
        }
    }

    /// Test that with a few massive buffers, we don't offer more than we should to `writev` if the individual chunks fit.
    func testPendingWritesNoMoreThanWritevLimitIsWritten() throws {
        let el = EmbeddedEventLoop()
        let alloc = ByteBufferAllocator(hookedMalloc: { _ in return UnsafeMutableRawPointer(bitPattern: 0xdeadbeef)! },
                                        hookedRealloc: { _, _ in return UnsafeMutableRawPointer(bitPattern: 0xdeadbeef)! },
                                        hookedFree: { _ in },
                                        hookedMemcpy: { _, _, _ in })
        /* each buffer is half the writev limit */
        let halfTheWriteVLimit = Socket.writevLimitBytes / 2
        var buffer = alloc.buffer(capacity: halfTheWriteVLimit)
        buffer.moveReaderIndex(to: 0)
        buffer.moveWriterIndex(to: halfTheWriteVLimit)

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<3).map { (_: Int) in el.newPromise() }
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
        let alloc = ByteBufferAllocator(hookedMalloc: { _ in return UnsafeMutableRawPointer(bitPattern: 0xdeadbeef)! },
                                        hookedRealloc: { _, _ in return UnsafeMutableRawPointer(bitPattern: 0xdeadbeef)! },
                                        hookedFree: { _ in },
                                        hookedMemcpy: { _, _, _ in })
        /* each buffer is half the writev limit */
        let biggerThanWriteV = Socket.writevLimitBytes + 23
        var buffer = alloc.buffer(capacity: biggerThanWriteV)
        buffer.moveReaderIndex(to: 0)
        buffer.moveWriterIndex(to: biggerThanWriteV)

        try withPendingStreamWritesManager { pwm in
            let ps: [EventLoopPromise<()>] = (0..<3).map { (_: Int) in el.newPromise() }
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
            let ps: [EventLoopPromise<()>] = (0..<2).map { (_: Int) in el.newPromise() }

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
            let ps: [EventLoopPromise<()>] = (0..<1).map { (_: Int) in el.newPromise() }

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
            let ps: [EventLoopPromise<()>] = (0..<5).map { (_: Int) in el.newPromise() }

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
            let ps: [EventLoopPromise<()>] = (0..<3).map { (_: Int) in el.newPromise() }

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
            let ps: [EventLoopPromise<()>] = (0..<3).map { (_: Int) in el.newPromise() }
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
            let ps: [EventLoopPromise<()>] = (0..<3).map { (_: Int) in el.newPromise() }
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
            let ps: [EventLoopPromise<()>] = (0...Socket.writevLimitIOVectors).map { (_: Int) in el.newPromise() }
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
            let ps: [EventLoopPromise<()>] = (0..<1).map { (_: Int) in el.newPromise() }

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
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
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
        }
    }

    func testGeneralConnectTimeout() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
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
        }
    }
    
    func testCloseOutput() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        
        let server = try ServerSocket(protocolFamily: PF_INET)
        defer {
            XCTAssertNoThrow(try server.close())
        }
        try server.bind(to: SocketAddress.newAddressResolving(host: "127.0.0.1", port: 0))
        try server.listen()
        
        let byteCountingHandler = ByteCountingHandler(numBytes: 4, promise: group.next().newPromise())
        let verificationHandler = ShutdownVerificationHandler(shutdownEvent: .output, promise: group.next().newPromise())
        let future = ClientBootstrap(group: group)
            .channelInitializer { channel in
                return channel.pipeline.add(handler: verificationHandler).then {
                    return channel.pipeline.add(handler: byteCountingHandler)
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
            try accepted.write(pointer: p.baseAddress!.assumingMemoryBound(to: UInt8.self), size: 4)
        }
        switch written {
        case .processed(let numBytes):
            XCTAssertEqual(4, numBytes)
        default:
            XCTFail()
        }
        try byteCountingHandler.assertReceived(buffer: buffer)
    }
    
    func testCloseInput() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        
        let server = try ServerSocket(protocolFamily: PF_INET)
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
                return channel.pipeline.add(handler: VerifyNoReadHandler()).then {
                    return channel.pipeline.add(handler: verificationHandler)
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
       
        try channel.close(mode: .input).wait()
        
        verificationHandler.waitForEvent()
        
        var buffer = channel.allocator.buffer(capacity: 12)
        buffer.write(string: "1234")
        
        let written = try buffer.withUnsafeReadableBytes { p in
            try accepted.write(pointer: p.baseAddress!.assumingMemoryBound(to: UInt8.self), size: 4)
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
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        
        let server = try ServerSocket(protocolFamily: PF_INET)
        defer {
            XCTAssertNoThrow(try server.close())
        }
        try server.bind(to: SocketAddress.newAddressResolving(host: "127.0.0.1", port: 0))
        try server.listen()
        
        let verificationHandler = ShutdownVerificationHandler(shutdownEvent: .input, promise: group.next().newPromise())

        let future = ClientBootstrap(group: group)
            .channelInitializer { channel in
                return channel.pipeline.add(handler: verificationHandler)
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
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "127.0.0.1", port: 0).wait()

        let clientChannel = try ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait()

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

        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let promise: EventLoopPromise<ChannelPipeline> = group.next().newPromise()

        try {
            let serverChildChannelPromise: EventLoopPromise<Channel> = group.next().newPromise()
            let serverChannel = try ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .childChannelInitializer { channel in
                    serverChildChannelPromise.succeed(result: channel)
                    channel.close(promise: nil)
                    return channel.eventLoop.newSucceededFuture(result: ())
                }
                .bind(host: "127.0.0.1", port: 0).wait()

            let clientChannel = try ClientBootstrap(group: group)
                .channelInitializer {
                    $0.pipeline.add(handler: StuffHandler(promise: promise))
                }
                .connect(to: serverChannel.localAddress!).wait()
            weakClientChannel = clientChannel
            weakServerChannel = serverChannel
            weakServerChildChannel = try serverChildChannelPromise.futureResult.wait()
            _ = try? clientChannel.close().wait()
            XCTAssertNoThrow(try serverChannel.close().wait())
        }()
        let pipeline = try promise.futureResult.wait()
        do {
            try pipeline.eventLoop.submit { () -> Channel in
                XCTAssertTrue(pipeline.channel is DeadChannel)
                return pipeline.channel
            }.wait().write(NIOAny(())).wait()
            XCTFail("shouldn't have been reached")
        } catch let e as ChannelError where e == .ioOnClosedChannel {
            // OK
        } catch {
            XCTFail("wrong error \(error) received")
        }
        XCTAssertNil(weakClientChannel, "weakClientChannel not nil, looks like we leaked it!")
        XCTAssertNil(weakServerChannel, "weakServerChannel not nil, looks like we leaked it!")
        XCTAssertNil(weakServerChildChannel, "weakServerChildChannel not nil, looks like we leaked it!")
    }

    func testAskForLocalAndRemoteAddressesAfterChannelIsClosed() throws {
        let group = MultiThreadedEventLoopGroup(numThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .bind(host: "127.0.0.1", port: 0).wait()

        let clientChannel = try ClientBootstrap(group: group)
            .connect(to: serverChannel.localAddress!).wait()


        // Start shutting stuff down.
        try serverChannel.syncCloseAcceptingAlreadyClosed()
        try clientChannel.syncCloseAcceptingAlreadyClosed()

        for f in [ serverChannel.remoteAddress, serverChannel.localAddress, clientChannel.remoteAddress, clientChannel.localAddress ] {
            XCTAssertNil(f)
        }
    }
}
