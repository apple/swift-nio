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

import Dispatch
import NIOCore

func run(identifier: String) {
    measure(identifier: identifier) {
        let dispatchData = ("A" as StaticString).withUTF8Buffer { ptr in
            DispatchData(bytes: UnsafeRawBufferPointer(ptr))
        }
        var buffer = ByteBufferAllocator().buffer(capacity: 7 * 1000)
        let foundationData = "A".data(using: .utf8)!
        let substring = Substring("A")
        @inline(never)
        func doWrites(buffer: inout ByteBuffer, dispatchData: DispatchData, substring: Substring) {
            // these ones are zero allocations
            // buffer.writeBytes(foundationData) // see SR-7542
            buffer.writeBytes([0x41])
            buffer.writeBytes("A".utf8)
            buffer.writeString("A")
            buffer.writeStaticString("A")
            buffer.writeInteger(0x41, as: UInt8.self)

            // those down here should be one allocation each (on Linux)
            buffer.writeBytes(dispatchData)  // see https://bugs.swift.org/browse/SR-9597

            // these here are one allocation on all platforms
            buffer.writeSubstring(substring)
        }
        @inline(never)
        func doReads(buffer: inout ByteBuffer) {
            // these ones are zero allocations
            let val = buffer.readInteger(as: UInt8.self)
            precondition(0x41 == val, "\(val!)")
            var slice = buffer.readSlice(length: 1)
            let sliceVal = slice!.readInteger(as: UInt8.self)
            precondition(0x41 == sliceVal, "\(sliceVal!)")
            buffer.withUnsafeReadableBytes { ptr in
                precondition(ptr[0] == 0x41)
            }

            // those down here should be one allocation each
            let arr = buffer.readBytes(length: 1)
            precondition([0x41] == arr!, "\(arr!)")
            let str = buffer.readString(length: 1)
            precondition("A" == str, "\(str!)")
        }
        for _ in 0..<1000 {
            doWrites(buffer: &buffer, dispatchData: dispatchData, substring: substring)
            doReads(buffer: &buffer)
        }
        return buffer.readableBytes
    }
}
