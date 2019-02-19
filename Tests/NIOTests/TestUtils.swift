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

func withPipe(_ body: (NIO.NIOFileHandle, NIO.NIOFileHandle) -> [NIO.NIOFileHandle]) throws {
    var fds: [Int32] = [-1, -1]
    fds.withUnsafeMutableBufferPointer { ptr in
        XCTAssertEqual(0, pipe(ptr.baseAddress!))
    }
    let readFH = NIOFileHandle(descriptor: fds[0])
    let writeFH = NIOFileHandle(descriptor: fds[1])
    let toClose = body(readFH, writeFH)
    try toClose.forEach { fh in
        XCTAssertNoThrow(try fh.close())
    }
}

func withTemporaryFile<T>(content: String? = nil, _ body: (NIO.NIOFileHandle, String) throws -> T) rethrows -> T {
    let (fd, path) = openTemporaryFile()
    let fileHandle = NIOFileHandle(descriptor: fd)
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
var temporaryDirectory: String {
    get {
#if os(Android)
        return "/data/local/tmp"
#elseif os(Linux)
        return "/tmp"
#else
        if #available(OSX 10.12, *) {
            return FileManager.default.temporaryDirectory.path
        } else {
            return "/tmp"
        }
#endif
    }
}
func createTemporaryDirectory() -> String {
    let template = "\(temporaryDirectory)/.NIOTests-temp-dir_XXXXXX"

    var templateBytes = template.utf8 + [0]
    let templateBytesCount = templateBytes.count
    templateBytes.withUnsafeMutableBufferPointer { ptr in
        ptr.baseAddress!.withMemoryRebound(to: Int8.self, capacity: templateBytesCount) { (ptr: UnsafeMutablePointer<Int8>) in
            let ret = mkdtemp(ptr)
            XCTAssertNotNil(ret)
        }
    }
    templateBytes.removeLast()
    return String(decoding: templateBytes, as: Unicode.UTF8.self)
}

func openTemporaryFile() -> (CInt, String) {
    let template = "\(temporaryDirectory)/niotestXXXXXXX"
    var templateBytes = template.utf8 + [0]
    let templateBytesCount = templateBytes.count
    let fd = templateBytes.withUnsafeMutableBufferPointer { ptr in
        ptr.baseAddress!.withMemoryRebound(to: Int8.self, capacity: templateBytesCount) { (ptr: UnsafeMutablePointer<Int8>) in
            return mkstemp(ptr)
        }
    }
    templateBytes.removeLast()
    return (fd, String(decoding: templateBytes, as: Unicode.UTF8.self))
}

extension Channel {
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

final class ByteCountingHandler : ChannelInboundHandler, RemovableChannelHandler {
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
            self.promise.succeed(buffer)
        }
    }

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var currentBuffer = self.unwrapInboundIn(data)
        buffer.writeBuffer(&currentBuffer)

        if buffer.readableBytes == numBytes {
            promise.succeed(buffer)
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

func assertSetGetOptionOnOpenAndClosed<Option: ChannelOption>(channel: Channel, option: Option, value: Option.Value) throws {
    _ = try channel.setOption(option, value: value).wait()
    _ = try channel.getOption(option).wait()
    try channel.close().wait()
    try channel.closeFuture.wait()

    do {
        _ = try channel.setOption(option, value: value).wait()
    } catch let err as ChannelError where err == .ioOnClosedChannel {
        // expected
    }

    do {
        _ = try channel.getOption(option).wait()
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
    let endTime = NIODeadline.now() + time

    repeat {
        if condition() { return }
        usleep(UInt32(testInterval.nanoseconds / 1000))
    } while (NIODeadline.now() < endTime)

    if !condition() {
        XCTFail(message)
    }
}

func getBoolSocketOption<IntType: SignedInteger>(channel: Channel, level: IntType, name: SocketOptionName,
                                                 file: StaticString = #file, line: UInt = #line) throws -> Bool {
    return try assertNoThrowWithValue(channel.getOption(ChannelOptions.socket(SocketOptionLevel(level),
                                                                                      name)),
                                      file: file,
                                      line: line).wait() != 0
}
