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

import CNIOLinux
import NIOCore
import XCTest

@testable import NIOPosix

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// This file constructs POSIX msghdr and UnsafeControlMessageCollection
// throughout, which are unsupported on Windows.
#if !os(Windows)
extension UnsafeControlMessageCollection {
    fileprivate init(controlBytes: UnsafeMutableRawBufferPointer) {
        let msgHdr = msghdr(
            msg_name: nil,
            msg_namelen: 0,
            msg_iov: nil,
            msg_iovlen: 0,
            msg_control: controlBytes.baseAddress,
            msg_controllen: .init(controlBytes.count),
            msg_flags: 0
        )
        self.init(messageHeader: msgHdr)
    }
}

class ControlMessageTests: XCTestCase {
    var encoderBytes: UnsafeMutableRawBufferPointer?
    var encoder: UnsafeOutboundControlBytes!

    override func setUp() {
        self.encoderBytes = UnsafeMutableRawBufferPointer.allocate(
            byteCount: 1000,
            alignment: MemoryLayout<Int>.alignment
        )
        self.encoder = UnsafeOutboundControlBytes(controlBytes: self.encoderBytes!)
    }

    override func tearDown() {
        if let encoderBytes = self.encoderBytes {
            self.encoderBytes = nil
            encoderBytes.deallocate()
        }
    }

    func testEmptyEncode() {
        XCTAssertEqual(self.encoder.validControlBytes.count, 0)
    }

    struct DecodedMessage: Equatable {
        var level: CInt
        var type: CInt
        var payload: CInt
    }

    func testEncodeDecode1() {
        self.encoder.appendControlMessage(level: 1, type: 2, payload: 3)
        let expected = [DecodedMessage(level: 1, type: 2, payload: 3)]
        let encodedBytes = self.encoder.validControlBytes

        let decoder = UnsafeControlMessageCollection(controlBytes: encodedBytes)
        XCTAssertEqual(decoder.count, 1)
        var decoded: [DecodedMessage] = []
        for cmsg in decoder {
            XCTAssertEqual(cmsg.data!.count, MemoryLayout<CInt>.size)
            let payload = ControlMessageParser._readCInt(data: cmsg.data!)
            decoded.append(DecodedMessage(level: cmsg.level, type: cmsg.type, payload: payload))
        }
        XCTAssertEqual(expected, decoded)
    }

    func testEncodeDecode2() {
        self.encoder.appendControlMessage(level: 1, type: 2, payload: 3)
        self.encoder.appendControlMessage(level: 4, type: 5, payload: 6)
        let expected = [
            DecodedMessage(level: 1, type: 2, payload: 3),
            DecodedMessage(level: 4, type: 5, payload: 6),
        ]
        let encodedBytes = self.encoder.validControlBytes

        let decoder = UnsafeControlMessageCollection(controlBytes: encodedBytes)
        XCTAssertEqual(decoder.count, 2)
        var decoded: [DecodedMessage] = []
        for cmsg in decoder {
            XCTAssertEqual(cmsg.data!.count, MemoryLayout<CInt>.size)
            let payload = ControlMessageParser._readCInt(data: cmsg.data!)
            decoded.append(DecodedMessage(level: cmsg.level, type: cmsg.type, payload: payload))
        }
        XCTAssertEqual(expected, decoded)
    }

    #if os(Linux)
    func testFileDescriptorsAcrossMultipleControlMessagesAreTakenOnce() throws {
        try withPipe { readHandle, writeHandle in
            let first = try readHandle.withUnsafeFileDescriptor { try Posix.dup(descriptor: $0) }
            let second = try writeHandle.withUnsafeFileDescriptor { try Posix.dup(descriptor: $0) }
            defer {
                XCTAssertNoThrow(try Posix.close(descriptor: first))
                XCTAssertNoThrow(try Posix.close(descriptor: second))
            }
            encoder.appendControlMessage(level: SOL_SOCKET, type: CInt(SCM_RIGHTS), payload: first)
            encoder.appendControlMessage(level: SOL_SOCKET, type: CInt(SCM_RIGHTS), payload: second)
            var received = UnsafeReceivedControlBytes(controlBytesBuffer: encoderBytes!)
            received.receivedControlMessages = UnsafeControlMessageCollection(
                controlBytes: encoder.validControlBytes
            )
            XCTAssertEqual(try received.takeFileDescriptors(), [first, second])
            XCTAssertNil(received.receivedControlMessages)
            XCTAssertTrue(try received.takeFileDescriptors().isEmpty)
            return [readHandle, writeHandle]
        }
    }

    func testTruncatedControlMessagesCloseEveryReceivedDescriptor() throws {
        try withPipe { readHandle, writeHandle in
            let descriptors = try [readHandle, writeHandle].map { handle in
                try handle.withUnsafeFileDescriptor { try Posix.dup(descriptor: $0) }
            }
            for descriptor in descriptors {
                encoder.appendControlMessage(level: SOL_SOCKET, type: CInt(SCM_RIGHTS), payload: descriptor)
            }
            var received = UnsafeReceivedControlBytes(controlBytesBuffer: encoderBytes!)
            received.receivedControlMessages = UnsafeControlMessageCollection(
                controlBytes: encoder.validControlBytes
            )
            received.receivedMessageFlags = CInt(MSG_CTRUNC)
            XCTAssertThrowsError(try received.takeFileDescriptors()) {
                XCTAssertEqual(($0 as? IOError)?.errnoCode, EMSGSIZE)
            }
            for descriptor in descriptors {
                XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
                XCTAssertEqual(errno, EBADF)
            }
            XCTAssertNil(received.receivedControlMessages)
            return [readHandle, writeHandle]
        }
    }

    func testMalformedDescriptorPayloadClosesCompleteDescriptors() throws {
        try withPipe { readHandle, writeHandle in
            let descriptor = try readHandle.withUnsafeFileDescriptor { try Posix.dup(descriptor: $0) }
            encoder.appendControlMessage(level: SOL_SOCKET, type: CInt(SCM_RIGHTS), payload: descriptor)
            let header = encoderBytes!.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
            header.pointee.cmsg_len += 1
            var received = UnsafeReceivedControlBytes(controlBytesBuffer: encoderBytes!)
            received.receivedControlMessages = UnsafeControlMessageCollection(
                controlBytes: encoder.validControlBytes
            )
            XCTAssertThrowsError(try received.takeFileDescriptors()) {
                XCTAssertEqual(($0 as? IOError)?.errnoCode, EMSGSIZE)
            }
            XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
            return [readHandle, writeHandle]
        }
    }

    func testIgnoredPIDFDIsClosed() throws {
        try withPipe { readHandle, writeHandle in
            let descriptor = try readHandle.withUnsafeFileDescriptor { try Posix.dup(descriptor: $0) }
            encoder.appendControlMessage(level: SOL_SOCKET, type: 4, payload: descriptor)
            var received = UnsafeReceivedControlBytes(controlBytesBuffer: encoderBytes!)
            received.receivedControlMessages = UnsafeControlMessageCollection(
                controlBytes: encoder.validControlBytes
            )
            XCTAssertTrue(try received.takeFileDescriptors().isEmpty)
            XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
            return [readHandle, writeHandle]
        }
    }
    #endif

    private func assertBuffersNonOverlapping(
        _ b1: UnsafeMutableRawBufferPointer,
        _ b2: UnsafeMutableRawBufferPointer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssert(
            (b1.baseAddress! < b2.baseAddress! && (b1.baseAddress! + b1.count) <= b2.baseAddress!)
                || (b2.baseAddress! < b1.baseAddress! && (b2.baseAddress! + b2.count) <= b1.baseAddress!),
            file: (file),
            line: line
        )
    }

    func testStorageIndexing() {
        var storage = UnsafeControlMessageStorage.allocate(msghdrCount: 3)
        defer {
            storage.deallocate()
        }
        // Check size
        XCTAssertEqual(storage.count, 3)
        // Buffers issued should not overlap.
        assertBuffersNonOverlapping(storage[0], storage[1])
        assertBuffersNonOverlapping(storage[0], storage[2])
        assertBuffersNonOverlapping(storage[1], storage[2])
        // Buffers should have a suitable size.
        XCTAssertGreaterThan(storage[0].count, MemoryLayout<cmsghdr>.stride)
        XCTAssertGreaterThan(storage[1].count, MemoryLayout<cmsghdr>.stride)
        XCTAssertGreaterThan(storage[2].count, MemoryLayout<cmsghdr>.stride)
    }
}
#endif
