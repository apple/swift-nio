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

import Foundation
@_spi(CustomByteBufferAllocator) import NIOCore
import Testing

#if compiler(>=6.2)
@Suite struct ByteBufferCrashTests {

    @Test func copyBytesToIndexExceedingUInt32Max() async {
        await #expect(processExitsWith: .failure) {
            var buf = ByteBufferAllocator().buffer(capacity: 256)
            buf.writeBytes([UInt8](repeating: 0x41, count: 64))
            let toIndex = Int(UInt32.max) + 1
            try buf.copyBytes(at: 0, to: toIndex, length: 64)
        }
    }

    @Test func writeWithUnsafeMutableBytesCrashesWhenWritingMoreThanUInt32maxBytes() async {
        await #expect(processExitsWith: .failure) {
            var buf = ByteBufferAllocator().buffer(capacity: 0)
            // ask for more capacity then ByteBuffer can provide.
            buf.writeWithUnsafeMutableBytes(minimumWritableBytes: Int(UInt32.max) + 2) { ptr in
                Issue.record("This should not be called")
                // in release without bounds checks, devs can write to
                // larger than 1 here.
                #expect(ptr.count == 1)
                return 1
            }
        }
    }

    @Test func moveReaderIndexTooFar() async {
        await #expect(processExitsWith: .failure) {
            var bb = ByteBuffer()
            bb.writeString("Hello World")
            bb.moveReaderIndex(forwardBy: 32)
        }
    }

    @Test func moveReaderIndexWayTooFar() async {
        await #expect(processExitsWith: .failure) {
            var bb = ByteBuffer()
            bb.writeString("Hello World")
            bb.moveReaderIndex(forwardBy: Int(UInt32.max) + 1)
        }
    }

    @Test func moveWriterIndexTooFar() async {
        await #expect(processExitsWith: .failure) {
            var bb = ByteBuffer()
            bb.reserveCapacity(64)
            bb.moveWriterIndex(forwardBy: 70)
        }
    }

    @Test func moveWriterIndexWayTooFar() async {
        await #expect(processExitsWith: .failure) {
            var bb = ByteBuffer()
            bb.reserveCapacity(64)
            bb.moveWriterIndex(forwardBy: Int(UInt32.max) + 1)
        }
    }

    @Test func setBytesWithMoreThanUInt32maxBytes() async {
        await #expect(processExitsWith: .failure) {
            let sequence = [UInt8](repeating: 0, count: Int(UInt32.max) + 1)
            var bb = ByteBuffer()
            bb.reserveCapacity(64)
            bb.setBytes(sequence, at: bb.writerIndex)
        }
    }

    @Test func setBytesAtIndexAfterUInt32max() async {
        await #expect(processExitsWith: .failure) {
            var bb = ByteBuffer()
            bb.reserveCapacity(64)
            bb.setBytes([1], at: Int(UInt32.max) + 1)
        }
    }

    @Test(
        .disabled(
            "This test is taking too long, as it needs to allocate 4GB of memory. It doesn't work on 32bit machines."
        )
    ) func setBytesWithoutContigiousStorageMoreThanUInt32maxBytes() async {
        await #expect(processExitsWith: .failure) {
            let circularBuffer = CircularBuffer<UInt8>(repeating: 0, count: Int(UInt32.max) + 1)
            var bb = ByteBuffer()
            bb.reserveCapacity(64)
            bb.setBytes(circularBuffer, at: bb.writerIndex)
        }
    }

    @Test func setBytesWithoutContigiousStorageAfterUInt32max() async {
        await #expect(processExitsWith: .failure) {
            let circularBuffer = CircularBuffer<UInt8>(repeating: 0, count: 4)
            var bb = ByteBuffer()
            bb.reserveCapacity(64)
            bb.setBytes(circularBuffer, at: Int(UInt32.max) + 1)
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *)
    @Test func setRawSpanWithMoreThanUInt32maxBytes() async {
        await #expect(processExitsWith: .failure) {
            let count = Int(UInt32.max) + 1
            let sequence = [UInt8](repeating: 0, count: count)
            var bb = ByteBuffer()
            bb.reserveCapacity(64)
            let rawSpan = sequence.span.bytes
            #expect(rawSpan.byteCount == count)
            bb.setBytes(sequence.span.bytes, at: bb.writerIndex)
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *)
    @Test func setRawSpanAfterUInt32max() async {
        await #expect(processExitsWith: .failure) {
            let sequence = [UInt8](repeating: 0, count: 4)
            var bb = ByteBuffer()
            bb.reserveCapacity(64)
            let rawSpan = sequence.span.bytes
            bb.setBytes(rawSpan, at: Int(UInt32.max) + 1)
        }
    }

    @Test func takingOwnershipOfPointerThatsToLarge() async {
        await #expect(processExitsWith: .failure) {
            let capacity = Int(UInt32.max) + 1
            let ptr = malloc(capacity)!

            let allocator = ByteBufferCustomAllocatorTest.makeTrackedAllocator()

            // this should crash
            let buffer = ByteBuffer(
                takingOwnershipOf: UnsafeMutableRawBufferPointer(start: ptr, count: capacity),
                allocator: allocator
            )

            _ = buffer
        }
    }
}
#endif
