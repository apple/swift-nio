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

import Dispatch
import XCTest

@testable import NIO

func withPipe(_ body: (NIO.FileHandle, NIO.FileHandle) -> [NIO.FileHandle]) throws {
    var fds: [Int32] = [-1, -1]
    fds.withUnsafeMutableBufferPointer { ptr in
        XCTAssertEqual(0, pipe(ptr.baseAddress!))
    }
    let readFH = FileHandle(descriptor: fds[0])
    let writeFH = FileHandle(descriptor: fds[1])
    let toClose = body(readFH, writeFH)
    try toClose.forEach { fh in
        XCTAssertNoThrow(try fh.close())
    }
}

func withTemporaryFile<T>(content: String? = nil, _ body: (NIO.FileHandle, String) throws -> T) rethrows -> T {
    let (fd, path) = openTemporaryFile()
    let fileHandle = FileHandle(descriptor: fd)
    defer {
        XCTAssertNoThrow(try fileHandle.close())
        XCTAssertEqual(0, unlink(path))
    }
    if let content = content {
        try Array(content.utf8).withUnsafeBufferPointer { ptr in
            var toWrite = ptr.count
            var start = ptr.baseAddress!
            while toWrite > 0 {
                let res = try Posix.write(descriptor: fd, pointer: start, size: toWrite)
                switch res {
                case .processed(let written):
                    toWrite -= written
                    start = start + written
                case .wouldBlock:
                    XCTFail("unexpectedly got .wouldBlock from a file")
                    continue
                }
            }
            XCTAssertEqual(0, lseek(fd, 0, SEEK_SET))
        }
    }
    return try body(fileHandle, path)
}

func createTemporaryDirectory() -> String {
    let template = "/tmp/.NIOTests-temp-dir_XXXXXX"
    var templateBytes = template.utf8 + [0]
    let templateBytesCount = templateBytes.count
    templateBytes.withUnsafeMutableBufferPointer { ptr in
        ptr.baseAddress!.withMemoryRebound(to: Int8.self, capacity: templateBytesCount) { (ptr: UnsafeMutablePointer<Int8>) in
            let ret = mkdtemp(ptr)
            XCTAssertNotNil(ret)
        }
    }
    templateBytes.removeLast()
    return String(decoding: templateBytes, as: UTF8.self)
}

func openTemporaryFile() -> (CInt, String) {
    let template = "/tmp/niotestXXXXXXX"
    var templateBytes = template.utf8 + [0]
    let templateBytesCount = templateBytes.count
    let fd = templateBytes.withUnsafeMutableBufferPointer { ptr in
        ptr.baseAddress!.withMemoryRebound(to: Int8.self, capacity: templateBytesCount) { (ptr: UnsafeMutablePointer<Int8>) in
            return mkstemp(ptr)
        }
    }
    templateBytes.removeLast()
    return (fd, String(decoding: templateBytes, as: UTF8.self))
}

internal extension Channel {
    func syncCloseAcceptingAlreadyClosed() throws {
        do {
            try self.close().wait()
        } catch ChannelError.alreadyClosed {
            /* we're happy with this one */
        } catch let e {
            throw e
        }
    }
}

final class ByteCountingHandler : ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let numBytes: Int
    private let promise: EventLoopPromise<ByteBuffer>
    private var buffer: ByteBuffer!

    init(numBytes: Int, promise: EventLoopPromise<ByteBuffer>) {
        self.numBytes = numBytes
        self.promise = promise
    }

    func handlerAdded(ctx: ChannelHandlerContext) {
        buffer = ctx.channel.allocator.buffer(capacity: numBytes)
        if self.numBytes == 0 {
            self.promise.succeed(result: buffer)
        }
    }

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var currentBuffer = self.unwrapInboundIn(data)
        buffer.write(buffer: &currentBuffer)

        if buffer.readableBytes == numBytes {
            promise.succeed(result: buffer)
        }
    }

    func assertReceived(buffer: ByteBuffer) throws {
        let received = try promise.futureResult.wait()
        XCTAssertEqual(buffer, received)
    }
}

final class NonAcceptingServerSocket: ServerSocket {
    private var errors: [Int32]

    init(errors: [Int32]) throws {
        // Reverse so it's cheaper to remove errors.
        self.errors = errors.reversed()
        try super.init(protocolFamily: AF_INET, setNonBlocking: true)
    }

    override func accept(setNonBlocking: Bool) throws -> Socket? {
        if let err = self.errors.last {
            _ = self.errors.removeLast()
            throw IOError(errnoCode: err, function: "accept")
        }
        return nil
    }
}

func assertSetGetOptionOnOpenAndClosed<T: ChannelOption>(channel: Channel, option: T, value: T.OptionType) throws {
    _ = try channel.setOption(option: option, value: value).wait()
    _ = try channel.getOption(option: option).wait()
    try channel.close().wait()
    try channel.closeFuture.wait()

    do {
        _ = try channel.setOption(option: option, value: value).wait()
    } catch let err as ChannelError where err == .ioOnClosedChannel {
        // expected
    }

    do {
        _ = try channel.getOption(option: option).wait()
    } catch let err as ChannelError where err == .ioOnClosedChannel {
        // expected
    }
}

func assertNoThrowWithValue<T>(_ body: @autoclosure () throws -> T, defaultValue: T? = nil, message: String? = nil, file: StaticString = #file, line: UInt = #line) throws -> T {
    do {
        return try body()
    } catch {
        XCTFail("\(message.map { $0 + ": " } ?? "")unexpected error \(error) thrown", file: file, line: line)
        if let defaultValue = defaultValue {
            return defaultValue
        } else {
            throw error
        }
    }
}

func resolverDebugInformation(eventLoop: EventLoop, host: String, previouslyReceivedResult: SocketAddress) throws -> String {
    func printSocketAddress(_ socketAddress: SocketAddress) -> String {
        switch socketAddress {
        case .unixDomainSocket(_):
            return "uds"
        case .v4(let sa):
            var addr = sa.address
            return addr.addressDescription()
        case .v6(let sa):
            var addr = sa.address
            return addr.addressDescription()
        }
    }
    let res = GetaddrinfoResolver(loop: eventLoop, aiSocktype: Posix.SOCK_STREAM, aiProtocol: Posix.IPPROTO_TCP)
    let ipv6Results = try assertNoThrowWithValue(res.initiateAAAAQuery(host: host, port: 0).wait()).map(printSocketAddress)
    let ipv4Results = try assertNoThrowWithValue(res.initiateAQuery(host: host, port: 0).wait()).map(printSocketAddress)

    return """
    when trying to resolve '\(host)' we've got the following results:
    - previous try: \(printSocketAddress(previouslyReceivedResult))
    - all results:
    IPv4: \(ipv4Results)
    IPv6: \(ipv6Results)
    """
}

func assert(_ condition: @autoclosure () -> Bool, within time: TimeAmount, testInterval: TimeAmount? = nil, _ message: String = "condition not satisfied in time", file: StaticString = #file, line: UInt = #line) {
    let testInterval = testInterval ?? TimeAmount.nanoseconds(time.nanoseconds / 5)
    let endTime = DispatchTime.now().uptimeNanoseconds + UInt64(time.nanoseconds)

    repeat {
        if condition() { return }
        usleep(UInt32(testInterval.nanoseconds / 1000))
    } while (DispatchTime.now().uptimeNanoseconds < endTime)

    if !condition() {
        XCTFail(message)
    }
}
