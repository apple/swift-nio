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
import Foundation
import NIOCore
@testable import NIOPosix
import NIOTestUtils

final class PipeChannelTest: XCTestCase {
    var group: MultiThreadedEventLoopGroup! = nil
    var channel: Channel! = nil
    var toChannel: FileHandle! = nil
    var fromChannel: FileHandle! = nil
    var buffer: ByteBuffer! = nil

    var eventLoop: SelectableEventLoop {
        return self.group.next() as! SelectableEventLoop
    }

    override func setUp() {
        self.group = .init(numberOfThreads: 1)

        XCTAssertNoThrow(try withPipe { pipe1Read, pipe1Write in
            try withPipe { pipe2Read, pipe2Write in
                self.toChannel = try pipe1Write.withUnsafeFileDescriptor { fd in
                    FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                }
                self.fromChannel = try pipe2Read.withUnsafeFileDescriptor { fd in
                    FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                }
                try pipe1Read.withUnsafeFileDescriptor { channelIn in
                    try pipe2Write.withUnsafeFileDescriptor { channelOut in
                        let channel = NIOPipeBootstrap(group: self.group)
                            .withPipes(inputDescriptor: channelIn,
                                       outputDescriptor: channelOut)
                        XCTAssertNoThrow(self.channel = try channel.wait())
                    }
                }
                for pipe in [pipe1Read, pipe1Write, pipe2Read, pipe2Write] {
                    XCTAssertNoThrow(try pipe.takeDescriptorOwnership())
                }
                return [] // we may leak the file handles because we take care of closing
            }
            return [] // we may leak the file handles because we take care of closing
        })
        self.buffer = self.channel.allocator.buffer(capacity: 128)
    }

    override func tearDown() {
        self.buffer = nil
        self.toChannel.closeFile()
        self.fromChannel.closeFile()
        self.toChannel = nil
        self.fromChannel = nil
        XCTAssertNoThrow(try self.channel.syncCloseAcceptingAlreadyClosed())
        XCTAssertNoThrow(try self.group.syncShutdownGracefully())
    }

    func testBasicIO() throws {
        class Handler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                context.writeAndFlush(data).whenFailure { error in
                    XCTFail("unexpected error: \(error)")
                }
            }
        }

        XCTAssertTrue(self.channel.isActive)
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(Handler()).wait())
        let longArray = Array(repeating: UInt8(ascii: "x"), count: 200_000)
        for length in [1, 10_000, 100_000, 200_000] {
            let fromChannel = self.fromChannel!

            XCTAssertNoThrow(try self.toChannel.writeBytes(longArray[0 ..< length]))
            let data = try? fromChannel.readBytes(ofExactLength: length)
            XCTAssertEqual(Array(longArray[0 ..< length]), data)
        }
        XCTAssertNoThrow(try self.channel.close().wait())
    }

    func testWriteErrorsCloseChannel() {
        XCTAssertNoThrow(try self.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).wait())
        self.fromChannel.closeFile()
        var buffer = self.channel.allocator.buffer(capacity: 1)
        buffer.writeString("X")
        XCTAssertThrowsError(try self.channel.writeAndFlush(buffer).wait()) { error in
            if let error = error as? IOError {
                XCTAssert([EPIPE, EBADF].contains(error.errnoCode), "unexpected errno: \(error)")
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertNoThrow(try self.channel.closeFuture.wait())
    }

    func testWeDontAcceptRegularFiles() throws {
        try withPipe { pipeIn, pipeOut in
            try withTemporaryFile { fileFH, path in
                try fileFH.withUnsafeFileDescriptor { fileFHDescriptor in
                    try pipeIn.withUnsafeFileDescriptor { pipeInDescriptor in
                        try pipeOut.withUnsafeFileDescriptor { pipeOutDescriptor in
                            XCTAssertThrowsError(try NIOPipeBootstrap(group: self.group)
                                .withPipes(inputDescriptor: fileFHDescriptor,
                                           outputDescriptor: pipeOutDescriptor).wait()) { error in
                                    XCTAssertEqual(ChannelError.operationUnsupported, error as? ChannelError)
                            }
                            XCTAssertThrowsError(try NIOPipeBootstrap(group: self.group)
                                .withPipes(inputDescriptor: pipeInDescriptor,
                                           outputDescriptor: fileFHDescriptor).wait()) { error in
                                    XCTAssertEqual(ChannelError.operationUnsupported, error as? ChannelError)
                            }
                        }
                    }
                }
            }
            return [pipeIn, pipeOut]
        }
    }

    func testWeWorkFineWithASingleFileDescriptor() throws {
        final class EchoHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            typealias OutboundOut = ByteBuffer

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                context.writeAndFlush(data).whenFailure { error in
                    XCTFail("unexpected error: \(error)")
                }
            }
        }
        // We're using a socketpair here and not say a serial line because it's much harder to get a serial line :).
        var socketPair: [CInt] = [-1, -1]
        XCTAssertNoThrow(try socketPair.withUnsafeMutableBufferPointer { socketPairPtr in
            precondition(socketPairPtr.count == 2)
            try Posix.socketpair(domain: .local, type: .stream, protocolSubtype: .default, socketVector: socketPairPtr.baseAddress)
        })
        defer {
            XCTAssertNoThrow(try socketPair.filter { $0 > 0 }.forEach(Posix.close(descriptor:)))
        }

        XCTAssertNoThrow(try "X".withCString { xPtr in
            try Posix.write(descriptor: socketPair[1], pointer: xPtr, size: 1)
        })

        var maybeChannel: Channel? = nil
        XCTAssertNoThrow(maybeChannel = try NIOPipeBootstrap(group: self.group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(EchoHandler())
            }
            .withInputOutputDescriptor(dup(socketPair[0]))
            .wait())
        defer {
            XCTAssertNoThrow(try maybeChannel?.close().wait())
        }

        var spaceForX: UInt8 = 0
        XCTAssertNoThrow(try withUnsafeMutableBytes(of: &spaceForX) { xPtr in
            try Posix.read(descriptor: socketPair[1], pointer: xPtr.baseAddress!, size: xPtr.count)
        })
        XCTAssertEqual(UInt8(ascii: "X"), spaceForX)
    }
}

extension FileHandle {
    func writeBytes(_ bytes: ByteBuffer) throws {
        try self.writeBytes(Array(bytes.readableBytesView))
    }

    func writeBytes(_ bytes: ArraySlice<UInt8>) throws {
        bytes.withUnsafeBytes {
            self.write(Data(bytesNoCopy: .init(mutating: $0.baseAddress!), count: $0.count, deallocator: .none))
        }
    }

    func writeBytes(_ bytes: [UInt8]) throws {
        try self.writeBytes(bytes[...])
    }

    func readBytes(ofExactLength completeLength: Int) throws -> [UInt8] {
        var buffer: [UInt8] = []
        buffer.reserveCapacity(completeLength)
        var remaining = completeLength
        while remaining > 0 {
            buffer.append(contentsOf: self.readData(ofLength: remaining))
            remaining = completeLength - buffer.count
        }
        return buffer
    }
}
