//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import NIO

func run(identifier: String) {
    measure(identifier: identifier) {
        let dispatchData = ("A" as StaticString).withUTF8Buffer { ptr in
            DispatchData(bytes: UnsafeRawBufferPointer(ptr))
        }
        var buffer = ByteBufferAllocator().buffer(capacity: 7 * 1_000)
        let foundationData = "A".data(using: .utf8)!
        @inline(never)
        func doWrites(buffer: inout ByteBuffer) {
            /* these ones are zero allocations */
            // buffer.writeBytes(foundationData) // see SR-7542
            buffer.writeBytes([0x41])
            buffer.writeBytes("A".utf8)
            buffer.writeString("A")
            buffer.writeStaticString("A")
            buffer.writeInteger(0x41, as: UInt8.self)

            /* those down here should be one allocation each (on Linux) */
            buffer.writeBytes(dispatchData) // see https://bugs.swift.org/browse/SR-9597
        }
        @inline(never)
        func doReads(buffer: inout ByteBuffer) {
            /* these ones are zero allocations */
            let val = buffer.readInteger(as: UInt8.self)
            precondition(val == 0x41, "\(val!)")
            var slice = buffer.readSlice(length: 1)
            let sliceVal = slice!.readInteger(as: UInt8.self)
            precondition(sliceVal == 0x41, "\(sliceVal!)")
            buffer.withUnsafeReadableBytes { ptr in
                precondition(ptr[0] == 0x41)
            }

            /* those down here should be one allocation each */
            let arr = buffer.readBytes(length: 1)
            precondition(arr! == [0x41], "\(arr!)")
            let str = buffer.readString(length: 1)
            precondition(str == "A", "\(str!)")
        }
        for _ in 0 ..< 1_000 {
            doWrites(buffer: &buffer)
            doReads(buffer: &buffer)
        }
        return buffer.readableBytes
    }
}
