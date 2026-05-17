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

import Atomics
import NIOConcurrencyHelpers
@_spi(CustomByteBufferAllocator) @testable import NIOCore
import XCTest

// Module-level tracker and hooks (required because C function pointers can't be instance methods)
private final class AllocationTracker {
    struct ReallocCall: @unchecked Sendable {
        let ptr: UnsafeMutableRawPointer?
        let oldSize: Int
        let newSize: Int
    }

    private let _mallocCalls = NIOLockedValueBox<[Int]>([])
    private let _reallocCalls = NIOLockedValueBox<[ReallocCall]>([])
    private let _freeCalls = NIOLockedValueBox<[UnsafeMutableRawPointer]>([])

    var mallocCalls: [Int] {
        self._mallocCalls.withLockedValue { $0 }
    }

    var reallocCalls: [ReallocCall] {
        self._reallocCalls.withLockedValue { $0 }
    }

    var freeCalls: [UnsafeMutableRawPointer] {
        self._freeCalls.withLockedValue { $0 }
    }

    func recordMalloc(size: Int) {
        self._mallocCalls.withLockedValue { $0.append(size) }
    }

    func recordRealloc(ptr: UnsafeMutableRawPointer?, oldSize: Int, newSize: Int) {
        self._reallocCalls.withLockedValue { $0.append(ReallocCall(ptr: ptr, oldSize: oldSize, newSize: newSize)) }
    }

    func recordFree(ptr: UnsafeMutableRawPointer) {
        self._freeCalls.withLockedValue { $0.append(ptr) }
    }

    func reset() {
        self._mallocCalls.withLockedValue { $0.removeAll() }
        self._reallocCalls.withLockedValue { $0.removeAll() }
        self._freeCalls.withLockedValue { $0.removeAll() }
    }
}

// Static tracker instance - tests will reset this in setUp()
// Note: Safe because XCTest runs tests within a class serially, not in parallel
private nonisolated(unsafe) let testTracker = AllocationTracker()

// C-callable function pointers that delegate to the tracker
private func testMallocHook(_ size: Int) -> UnsafeMutableRawPointer? {
    testTracker.recordMalloc(size: size)
    return malloc(size)
}

private func testReallocHook(
    _ ptr: UnsafeMutableRawPointer?,
    _ oldSize: Int,
    _ newSize: Int
) -> UnsafeMutableRawPointer? {
    testTracker.recordRealloc(ptr: ptr, oldSize: oldSize, newSize: newSize)
    return realloc(ptr, newSize)
}

private func testFreeHook(_ ptr: UnsafeMutableRawPointer) {
    testTracker.recordFree(ptr: ptr)
    free(ptr)
}

private func testMemcpyHook(_ dst: UnsafeMutableRawPointer, _ src: UnsafeRawPointer, _ count: Int) {
    _ = memcpy(dst, src, count)
}

class ByteBufferCustomAllocatorTest: XCTestCase {

    override func setUp() {
        super.setUp()
        testTracker.reset()
    }

    private func makeTrackedAllocator() -> ByteBufferAllocator {
        ByteBufferAllocator(
            allocate: testMallocHook,
            reallocate: testReallocHook,
            deallocate: testFreeHook,
            copy: testMemcpyHook
        )
    }

    func testCustomAllocatorReceivesCorrectReallocSizes() {
        let allocator = self.makeTrackedAllocator()

        var buffer = allocator.buffer(capacity: 64)
        XCTAssertEqual(testTracker.mallocCalls.count, 1)
        XCTAssertEqual(testTracker.mallocCalls[0], 64)

        // Write enough data to trigger realloc
        buffer.writeBytes(Array(repeating: UInt8(0x42), count: 64))
        buffer.writeBytes(Array(repeating: UInt8(0x43), count: 1))

        // Should have triggered at least one realloc
        XCTAssertGreaterThan(testTracker.reallocCalls.count, 0)

        // Verify the realloc call had correct old and new sizes
        let firstRealloc = testTracker.reallocCalls[0]
        XCTAssertEqual(firstRealloc.oldSize, 64, "Old size should be original capacity")
        XCTAssertGreaterThan(firstRealloc.newSize, 64, "New size should be larger than old size")
    }

    func testCustomAllocatorReallocReceivesOldSizeOnMultipleGrows() {
        let allocator = self.makeTrackedAllocator()

        var buffer = allocator.buffer(capacity: 16)

        // Trigger multiple reallocs by writing incrementally
        for _ in 0..<10 {
            buffer.writeBytes(Array(repeating: UInt8(0x42), count: 16))
        }

        let reallocCalls = testTracker.reallocCalls
        XCTAssertGreaterThan(reallocCalls.count, 0)

        // Verify each realloc has the previous capacity as old size
        for i in 0..<reallocCalls.count {
            let call = reallocCalls[i]
            if i == 0 {
                XCTAssertEqual(call.oldSize, 16, "First realloc should have initial capacity as old size")
            } else {
                let previousNewSize = reallocCalls[i - 1].newSize
                XCTAssertEqual(
                    call.oldSize,
                    previousNewSize,
                    "Each realloc should receive previous capacity as old size"
                )
            }
            XCTAssertGreaterThan(call.newSize, call.oldSize, "New size should always be larger than old size")
        }
    }

    func testAdoptingExternalMemory() {
        let capacity = 256
        let ptr = malloc(capacity)!

        // Initialize some data in the external memory
        let boundPtr = ptr.bindMemory(to: UInt8.self, capacity: capacity)
        for i in 0..<10 {
            boundPtr[i] = UInt8(i)
        }

        let allocator = self.makeTrackedAllocator()

        var buffer = ByteBuffer(
            takingOwnershipOf: UnsafeMutableRawBufferPointer(start: ptr, count: capacity),
            allocator: allocator
        )

        // No malloc should have been called since we adopted existing memory
        XCTAssertEqual(testTracker.mallocCalls.count, 0)

        // Verify the data is accessible
        XCTAssertEqual(buffer.readableBytes, capacity)
        let readData = buffer.readBytes(length: 10)!
        XCTAssertEqual(readData, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])

        // When buffer is deallocated, free should be called on our pointer
        buffer = ByteBuffer()

        // Verify free was called
        XCTAssertGreaterThan(testTracker.freeCalls.count, 0)
    }

    func testAdoptingExternalMemoryWithCustomIndices() {
        let capacity = 100
        let ptr = malloc(capacity)!

        let boundPtr = ptr.bindMemory(to: UInt8.self, capacity: capacity)
        for i in 0..<capacity {
            boundPtr[i] = UInt8(i % 256)
        }

        let allocator = ByteBufferAllocator()

        var buffer = ByteBuffer(
            takingOwnershipOf: UnsafeMutableRawBufferPointer(start: ptr, count: capacity),
            allocator: allocator,
            readerIndex: 10,
            writerIndex: 50
        )

        XCTAssertEqual(buffer.readerIndex, 10)
        XCTAssertEqual(buffer.writerIndex, 50)
        XCTAssertEqual(buffer.readableBytes, 40)
        XCTAssertEqual(buffer.capacity, 100)

        // Verify the actual byte values are correct
        let readBytes = buffer.readBytes(length: 40)!
        for (index, byte) in readBytes.enumerated() {
            XCTAssertEqual(byte, UInt8((10 + index) % 256), "Byte at offset \(index) should be \((10 + index) % 256)")
        }
    }

    func testWithVeryUnsafeMutableBytesWithStorageManagement() {
        var buffer = ByteBufferAllocator().buffer(capacity: 100)
        buffer.writeString("Hello")

        let result: String? = buffer.withVeryUnsafeMutableBytesWithStorageManagement { pointer, storage in
            // Verify we can mutate the buffer
            pointer.baseAddress!.advanced(by: 5).storeBytes(of: UInt8(ascii: "!"), as: UInt8.self)

            // Verify storage reference is valid
            _ = storage.retain()
            storage.release()

            return String(decoding: UnsafeRawBufferPointer(rebasing: pointer.prefix(6)), as: UTF8.self)
        }

        XCTAssertEqual(result, "Hello!")

        // Verify the buffer was actually mutated
        var readBuffer = buffer
        readBuffer.moveReaderIndex(to: 0)
        readBuffer.moveWriterIndex(to: 6)
        XCTAssertEqual(readBuffer.readString(length: 6), "Hello!")
    }

    func testCustomAllocatorFreeCalled() {
        let allocator = self.makeTrackedAllocator()

        do {
            var buffer = allocator.buffer(capacity: 64)
            buffer.writeString("test")
            XCTAssertEqual(testTracker.mallocCalls.count, 1)
        }

        // Buffer should be deallocated now, free should have been called
        XCTAssertGreaterThan(testTracker.freeCalls.count, 0)
    }
}
