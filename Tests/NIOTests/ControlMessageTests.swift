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
    var encoder: UnsafeOutboundControlBytes!
    
    override func setUp() {
        let encoderBytes = UnsafeMutableRawBufferPointer.allocate(byteCount: 1000,
                                                                  alignment: MemoryLayout<Int>.alignment)
        self.encoder = UnsafeOutboundControlBytes(controlBytes: encoderBytes)
    }
    
    func testEmptyEncode() {
        XCTAssertEqual(self.encoder.validControlBytes.count, 0)
    }
    
    func testEncodeDecode1() {
        self.encoder.appendControlMessage(level: 1, type: 2, payload: 3)
        let encodedBytes = self.encoder.validControlBytes
        
        let decoder = UnsafeControlMessageCollection(controlBytes: encodedBytes)
        XCTAssertEqual(decoder.count, 1)
        XCTAssertEqual(decoder.first!.level, 1)
        XCTAssertEqual(decoder.first!.type, 2)
        XCTAssertEqual(decoder.first!.data!.count, MemoryLayout<Int>.size)
    }
    
    func testEncodeDecode2() {
        self.encoder.appendControlMessage(level: 1, type: 2, payload: 3)
        self.encoder.appendControlMessage(level: 4, type: 5, payload: 6)
        let encodedBytes = self.encoder.validControlBytes
        
        let decoder = UnsafeControlMessageCollection(controlBytes: encodedBytes)
        XCTAssertEqual(decoder.count, 2)
        XCTAssertEqual(decoder.first!.level, 1)
        XCTAssertEqual(decoder.first!.type, 2)
        XCTAssertEqual(decoder.first!.data!.count, MemoryLayout<Int>.size)
        XCTAssertEqual(decoder[decoder.index(after: decoder.startIndex)].level, 4)
        XCTAssertEqual(decoder[decoder.index(after: decoder.startIndex)].type, 5)
        XCTAssertEqual(decoder[decoder.index(after: decoder.startIndex)].data!.count, MemoryLayout<Int>.size)

    }
}
