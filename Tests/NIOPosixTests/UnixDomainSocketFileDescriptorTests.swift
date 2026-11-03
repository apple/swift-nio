//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import CNIOLinux
import NIOCore
import XCTest

@testable import NIOPosix

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if !os(Windows)
final class UnixDomainSocketFileDescriptorTests: XCTestCase {
    private final class FirstReadHandler<Value: Sendable>: ChannelInboundHandler {
        typealias InboundIn = Value
        let promise: EventLoopPromise<Value>

        init(promise: EventLoopPromise<Value>) {
            self.promise = promise
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            promise.succeed(unwrapInboundIn(data))
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            if !promise.futureResult.isFulfilled { promise.fail(error) }
            context.close(promise: nil)
        }

        func channelInactive(context: ChannelHandlerContext) {
            if !promise.futureResult.isFulfilled { promise.fail(ChannelError.eof) }
            context.fireChannelInactive()
        }
    }

    private func withReceivingChannel(
        receiveFileDescriptors: Bool = false,
        _ body: (Channel, Socket) throws -> Void
    ) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
        var descriptors: [CInt] = [-1, -1]
        try Posix.socketpair(domain: .unix, type: .stream, protocolSubtype: .default, socketVector: &descriptors)
        let peer = try Socket(socket: descriptors[1], setNonBlocking: false)
        defer { if peer.isOpen { XCTAssertNoThrow(try peer.close()) } }
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(.autoRead, value: false)
            .channelOption(.maxMessagesPerRead, value: 1)
        if receiveFileDescriptors { _ = bootstrap.channelOption(.receiveFileDescriptors, value: true) }
        let channel = try bootstrap.withConnectedSocket(descriptors[0]).wait()
        defer { XCTAssertNoThrow(try channel.syncCloseAcceptingAlreadyClosed()) }
        try body(channel, peer)
    }

    private func firstRead<Value: Sendable>(from channel: Channel, as type: Value.Type) throws -> EventLoopFuture<Value>
    {
        let promise = channel.eventLoop.makePromise(of: Value.self)
        try channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(FirstReadHandler(promise: promise))
        }.wait()
        channel.read()
        return promise.futureResult
    }

    private func waitForRead<Value: Sendable>(_ future: EventLoopFuture<Value>) throws -> Value {
        let completed = expectation(description: "Read completed")
        future.whenComplete { _ in completed.fulfill() }
        wait(for: [completed], timeout: 5)
        guard future.isFulfilled else { throw ChannelError.connectTimeout(.seconds(5)) }
        return try future.wait()
    }

    func testDefaultReadsRemainByteBuffers() throws {
        try withReceivingChannel { channel, peer in
            let read = try firstRead(from: channel, as: ByteBuffer.self)
            var byte: UInt8 = 42
            XCTAssertEqual(try withUnsafeBytes(of: &byte) { try peer.write(pointer: $0) }, .processed(1))
            XCTAssertEqual(try waitForRead(read), ByteBuffer(bytes: [42]))
        }
    }

    func testReceiveOptionRejectsTCPAndPipes() throws {
        func check(_ channel: Channel) throws {
            XCTAssertThrowsError(try channel.setOption(.receiveFileDescriptors, value: true).wait()) {
                XCTAssertEqual($0 as? ChannelError, .operationUnsupported)
            }
            XCTAssertThrowsError(try channel.getOption(.receiveFileDescriptors).wait()) {
                XCTAssertEqual($0 as? ChannelError, .operationUnsupported)
            }
        }
        try withCrossConnectedTCPChannels { channel, _ in try check(channel) }
        try withCrossConnectedPipeChannels { channel, _ in try check(channel) }
    }

    func testReceivedMetadataCannotBeWritten() throws {
        try withReceivingChannel { channel, _ in
            var metadata = AddressedEnvelope<ByteBuffer>.Metadata(ecnState: .transportNotCapable)
            metadata.receivedFileDescriptors = [0]
            let envelope = AddressedEnvelope(
                remoteAddress: try SocketAddress(unixDomainSocketPath: "/ignored"),
                data: ByteBuffer(bytes: [42]),
                metadata: metadata
            )
            XCTAssertThrowsError(try channel.writeAndFlush(envelope).wait()) {
                XCTAssertEqual($0 as? ChannelError, .operationUnsupported)
            }
            XCTAssertTrue(channel.isActive)
        }
    }

    #if os(Linux)
    private func sendDescriptors(_ descriptors: [CInt], to peer: Socket) throws {
        try withUnsafeTemporaryAllocation(
            byteCount: NIOBSDSocketControlMessage.space(payloadSize: descriptors.count * MemoryLayout<CInt>.size),
            alignment: MemoryLayout<cmsghdr>.alignment
        ) { control in
            let header = control.baseAddress!.bindMemory(to: cmsghdr.self, capacity: 1)
            header.pointee.cmsg_level = SOL_SOCKET
            header.pointee.cmsg_type = CInt(SCM_RIGHTS)
            header.pointee.cmsg_len = NIOBSDSocketControlMessage.length(
                payloadSize: descriptors.count * MemoryLayout<CInt>.size
            )
            descriptors.withUnsafeBytes { NIOBSDSocketControlMessage.data(for: header)!.copyMemory(from: $0) }
            var byte: UInt8 = 42
            XCTAssertEqual(
                try withUnsafeBytes(of: &byte) {
                    try peer.sendmsg(pointer: $0, destinationPtr: nil, destinationSize: 0, controlBytes: control)
                },
                .processed(1)
            )
        }
    }

    func testReceiveOptionAndPlainByteEnvelopes() throws {
        try withReceivingChannel { channel, peer in
            XCTAssertFalse(try channel.getOption(.receiveFileDescriptors).wait())
            try channel.setOption(.receiveFileDescriptors, value: true).wait()
            XCTAssertTrue(try channel.getOption(.receiveFileDescriptors).wait())
            let read = try firstRead(from: channel, as: AddressedEnvelope<ByteBuffer>.self)
            var byte: UInt8 = 42
            XCTAssertEqual(try withUnsafeBytes(of: &byte) { try peer.write(pointer: $0) }, .processed(1))
            let envelope = try waitForRead(read)
            XCTAssertEqual(envelope.data, ByteBuffer(bytes: [42]))
            XCTAssertEqual(envelope.metadata?.receivedFileDescriptors, [])
            XCTAssertEqual(envelope.remoteAddress.protocol, .unix)
            try channel.setOption(.receiveFileDescriptors, value: false).wait()
            XCTAssertFalse(try channel.getOption(.receiveFileDescriptors).wait())
        }
    }

    func testReceivesMultipleDescriptorsWithCloseOnExecAndTransfersOwnership() throws {
        for count in [1, 3, 253] {
            try withReceivingChannel { channel, peer in
                try withPipe { readHandle, writeHandle in
                    let original = try writeHandle.withUnsafeFileDescriptor { $0 }
                    _ = try Posix.fcntl(descriptor: original, command: F_SETFD, value: 0)
                    try channel.setOption(.receiveFileDescriptors, value: true).wait()
                    let read = try firstRead(from: channel, as: AddressedEnvelope<ByteBuffer>.self)
                    try sendDescriptors(Array(repeating: original, count: count), to: peer)
                    let envelope = try waitForRead(read)
                    let descriptors = try XCTUnwrap(envelope.metadata?.receivedFileDescriptors)
                    defer {
                        for descriptor in descriptors { XCTAssertNoThrow(try Posix.close(descriptor: descriptor)) }
                    }
                    XCTAssertEqual(envelope.data, ByteBuffer(bytes: [42]))
                    XCTAssertEqual(descriptors.count, count)
                    XCTAssertEqual(Set(descriptors).count, count)
                    try channel.close().wait()
                    for descriptor in descriptors {
                        XCTAssertNotEqual(descriptor, original)
                        XCTAssertNotEqual(
                            try Posix.fcntl(descriptor: descriptor, command: F_GETFD, value: 0) & FD_CLOEXEC,
                            0
                        )
                    }
                    let descriptor = try XCTUnwrap(descriptors.first)
                    var byte: UInt8 = 7
                    XCTAssertEqual(try Posix.write(descriptor: descriptor, pointer: &byte, size: 1), .processed(1))
                    byte = 0
                    XCTAssertEqual(
                        try readHandle.withUnsafeFileDescriptor {
                            try Posix.read(descriptor: $0, pointer: &byte, size: 1)
                        },
                        .processed(1)
                    )
                    XCTAssertEqual(byte, 7)
                    XCTAssertEqual(try Posix.fcntl(descriptor: original, command: F_GETFD, value: 0) & FD_CLOEXEC, 0)
                    return [readHandle, writeHandle]
                }
            }
        }
    }

    func testReceiveOptionCanBeSetOnBootstrap() throws {
        try withReceivingChannel(receiveFileDescriptors: true) { channel, peer in
            XCTAssertTrue(try channel.getOption(.receiveFileDescriptors).wait())
            let read = try firstRead(from: channel, as: AddressedEnvelope<ByteBuffer>.self)
            let descriptor = try peer.withUnsafeHandle { $0 }
            try sendDescriptors([descriptor], to: peer)
            let envelope = try waitForRead(read)
            let descriptors = try XCTUnwrap(envelope.metadata?.receivedFileDescriptors)
            defer { for descriptor in descriptors { XCTAssertNoThrow(try Posix.close(descriptor: descriptor)) } }
            XCTAssertEqual(descriptors.count, 1)
        }
    }

    func testReceiveEOFDoesNotDeliverAnEnvelope() throws {
        try withReceivingChannel { channel, peer in
            try channel.setOption(.receiveFileDescriptors, value: true).wait()
            let read = try firstRead(from: channel, as: AddressedEnvelope<ByteBuffer>.self)
            try peer.close()
            XCTAssertThrowsError(try waitForRead(read)) {
                XCTAssertEqual($0 as? ChannelError, .eof)
            }
        }
    }

    func testKernelTruncationClosesAllDeliveredDescriptors() throws {
        var pair: [CInt] = [-1, -1]
        try Posix.socketpair(domain: .unix, type: .stream, protocolSubtype: .default, socketVector: &pair)
        let receiver = try Socket(socket: pair[0], setNonBlocking: true)
        let peer = try Socket(socket: pair[1], setNonBlocking: false)
        defer {
            XCTAssertNoThrow(try receiver.close())
            XCTAssertNoThrow(try peer.close())
        }
        try sendDescriptors(Array(repeating: pair[1], count: 8), to: peer)
        try withUnsafeTemporaryAllocation(
            byteCount: NIOBSDSocketControlMessage.space(payloadSize: MemoryLayout<CInt>.size),
            alignment: MemoryLayout<cmsghdr>.alignment
        ) { control in
            var received = UnsafeReceivedControlBytes(controlBytesBuffer: control, receiveFlags: CInt(MSG_CMSG_CLOEXEC))
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            var byte: UInt8 = 0
            XCTAssertEqual(
                try withUnsafeMutableBytes(of: &byte) {
                    try receiver.recvmsg(pointer: $0, storage: &address, storageLen: &length, controlBytes: &received)
                },
                .processed(1)
            )
            XCTAssertNotEqual(received.receivedMessageFlags & CInt(MSG_CTRUNC), 0)
            let delivered = try XCTUnwrap(received.receivedControlMessages).flatMap { message -> [CInt] in
                let data = message.data!
                return stride(from: 0, to: data.count, by: MemoryLayout<CInt>.size).map {
                    data.loadUnaligned(fromByteOffset: $0, as: CInt.self)
                }
            }
            XCTAssertFalse(delivered.isEmpty)
            XCTAssertThrowsError(try received.takeFileDescriptors()) {
                XCTAssertEqual(($0 as? IOError)?.errnoCode, EMSGSIZE)
            }
            for descriptor in delivered {
                XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
                XCTAssertEqual(errno, EBADF)
            }
        }
    }
    #else
    func testReceiveOptionRejectsUnsupportedPlatforms() throws {
        try withReceivingChannel { channel, _ in
            XCTAssertThrowsError(try channel.setOption(.receiveFileDescriptors, value: true).wait()) {
                XCTAssertEqual($0 as? ChannelError, .operationUnsupported)
            }
        }
    }
    #endif
}
#endif
