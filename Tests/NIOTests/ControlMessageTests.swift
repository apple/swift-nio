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

fileprivate extension UnsafeControlMessageCollection {
    init(controlBytes: UnsafeMutableRawBufferPointer) {
        let msgHdr = msghdr(msg_name: nil,
                            msg_namelen: 0,
                            msg_iov: nil,
                            msg_iovlen: 0,
                            msg_control: controlBytes.baseAddress,
                            msg_controllen: .init(controlBytes.count),
                            msg_flags: 0)
        self.init(messageHeader: msgHdr)
    }
}

class ControlMessageTests: XCTestCase {
    var encoderBytes: UnsafeMutableRawBufferPointer?
    var encoder: UnsafeOutboundControlBytes!
    
    override func setUp() {
        self.encoderBytes = UnsafeMutableRawBufferPointer.allocate(byteCount: 1000,
                                                                  alignment: MemoryLayout<Int>.alignment)
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
            let payload = ControlMessageReceiver.readCInt(data: cmsg.data!)
            decoded.append(DecodedMessage(level: cmsg.level, type: cmsg.type, payload: payload))
        }
        XCTAssertEqual(expected, decoded)
    }
    
    func testEncodeDecode2() {
        self.encoder.appendControlMessage(level: 1, type: 2, payload: 3)
        self.encoder.appendControlMessage(level: 4, type: 5, payload: 6)
        let expected = [
            DecodedMessage(level: 1, type: 2, payload: 3),
            DecodedMessage(level: 4, type: 5, payload: 6)
        ]
        let encodedBytes = self.encoder.validControlBytes
        
        let decoder = UnsafeControlMessageCollection(controlBytes: encodedBytes)
        XCTAssertEqual(decoder.count, 2)
        var decoded: [DecodedMessage] = []
        for cmsg in decoder {
            XCTAssertEqual(cmsg.data!.count, MemoryLayout<CInt>.size)
            let payload = ControlMessageReceiver.readCInt(data: cmsg.data!)
            decoded.append(DecodedMessage(level: cmsg.level, type: cmsg.type, payload: payload))
        }
        XCTAssertEqual(expected, decoded)
    }
}
